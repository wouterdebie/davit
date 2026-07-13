import SwiftUI

struct SettingsView: View {
    private enum Tab { case general, platform, registries, about }
    // Harness: `--pose-settings-registries` lands on the Registries tab for screenshots.
    @State private var tab: Tab =
        ProcessInfo.processInfo.arguments.contains("--pose-settings-registries") ? .registries : .general

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(Tab.general)
            SystemSettings()
                .tabItem { Label("Platform", systemImage: "wrench.and.screwdriver") }
                .tag(Tab.platform)
            RegistrySettings()
                .tabItem { Label("Registries", systemImage: "key") }
                .tag(Tab.registries)
            AboutSettings()
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(Tab.about)
        }
        // Compact height when posing for screenshots — the registries list is short.
        .frame(width: 560, height: ProcessInfo.processInfo.arguments.contains("--pose-settings-registries") ? 400 : 600)
    }
}

// MARK: - General (app-level settings)

struct GeneralSettings: View {
    @EnvironmentObject var state: AppState
    @AppStorage(ContainerBinary.defaultsKey) private var binaryPath = ""
    @AppStorage("refreshInterval") private var refreshInterval = 4.0
    @AppStorage("keepInDock") private var keepInDock = false
    @AppStorage(TerminalApp.defaultsKey) private var preferredTerminal = TerminalApp.systemDefault.rawValue

    var body: some View {
        Form {
            Section("Container Platform") {
                TextField("Install root (blank = auto-detect, e.g. /usr/local)", text: $binaryPath)
                    .textFieldStyle(.roundedBorder)
                    // Match the Platform tab (and the app convention picked
                    // after the HN "types from the right" report): input text
                    // is leading-aligned everywhere.
                    .multilineTextAlignment(.leading)
                if let binary = state.resolvedBinary {
                    LabeledContent("Resolved") {
                        Text("\(binary.path) — \(binary.source.rawValue)")
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                } else {
                    Text("Container platform (container-apiserver) not found").foregroundStyle(.red)
                }
            }
            if state.resolvedBinary?.source == .managed {
                Section("Command Line") {
                    ShellCommandRow()
                }
            }
            Section("Appearance") {
                Toggle("Keep in Dock when the window is closed", isOn: $keepInDock)
                Text("Off: closing the window leaves Davit only in the menu bar, like other menu bar utilities.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Terminal") {
                Picker("Open shells in", selection: $preferredTerminal) {
                    ForEach(TerminalApp.installed) { app in
                        Text(app.displayName).tag(app.rawValue)
                    }
                }
                Text("Used by \u{201C}Open Terminal\u{201D} on containers. Only installed terminals are listed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Startup") {
                LoginItemToggle()
            }
            Section("Refresh") {
                Slider(value: $refreshInterval, in: 2...15, step: 1) {
                    Text("Refresh every \(Int(refreshInterval))s")
                }
                Text("Live stats always refresh every 2 seconds while containers run.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .onChange(of: binaryPath) {
            Task { await state.refreshAll() }
        }
    }
}

/// "Open at Login" via SMAppService — the app registers itself as a macOS
/// login item. Reflects the live system state so it stays correct if the user
/// toggles it in System Settings > General > Login Items.
struct LoginItemToggle: View {
    @State private var enabled = LoginItem.isEnabled
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Open Davit at login", isOn: Binding(
                get: { enabled },
                set: { newValue in
                    do {
                        try LoginItem.setEnabled(newValue)
                        enabled = LoginItem.isEnabled
                        errorText = nil
                    } catch {
                        errorText = error.localizedDescription
                        enabled = LoginItem.isEnabled
                    }
                }
            ))
            Text("Launches Davit to the menu bar when you log in, so container services are ready.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let errorText {
                Text(errorText).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            enabled = LoginItem.isEnabled
        }
    }
}

/// Installs/removes the `container` shell command for Davit-managed platforms.
struct ShellCommandRow: View {
    @EnvironmentObject var state: AppState
    @State private var status = ShellCommandInstaller.status
    @State private var working = false
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch status {
            case .installed:
                LabeledContent("`container` command") {
                    Button("Remove from /usr/local/bin") { run { try await ShellCommandInstaller.uninstall() } }
                        .disabled(working)
                }
                Text("Installed at /usr/local/bin/container, pointing at the Davit-managed platform.")
                    .font(.caption).foregroundStyle(.secondary)
            case .notInstalled:
                LabeledContent("`container` command") {
                    Button("Install in /usr/local/bin…") {
                        guard let root = state.resolvedBinary?.installRoot else { return }
                        run { try await ShellCommandInstaller.install(managedRoot: root) }
                    }
                    .disabled(working)
                }
                Text("Adds the `container` CLI to your shell, wired to the Davit-managed platform. Asks for administrator authorization once.")
                    .font(.caption).foregroundStyle(.secondary)
            case .foreignBinary:
                Text("/usr/local/bin/container already exists (system install) — nothing to do.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let errorText {
                Text(errorText).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
        }
    }

    private func run(_ action: @escaping () async throws -> Void) {
        working = true
        errorText = nil
        Task {
            do {
                try await action()
            } catch {
                // "User canceled" comes back from osascript when the auth dialog is dismissed
                let message = error.localizedDescription
                if !message.contains("-128") { errorText = message }
            }
            status = ShellCommandInstaller.status
            working = false
        }
    }
}

// MARK: - Platform settings editor (writes ~/.config/container/config.toml)

@MainActor
final class SystemConfigModel: ObservableObject {
    // Curated fields
    @Published var containerCpus = ""
    @Published var containerMemory = ""
    @Published var registryDomain = ""
    @Published var dnsDomain = ""
    @Published var buildCpus = ""
    @Published var buildMemory = ""
    @Published var buildRosetta = false
    @Published var buildImage = ""
    @Published var kernelURL = ""
    @Published var kernelBinaryPath = ""
    @Published var vminitImage = ""
    @Published var machineCpus = ""
    @Published var machineMemory = ""

    @Published var defaultHints: [String: String] = [:]
    @Published var loaded = false
    @Published var saving = false
    @Published var statusMessage: String?
    @Published var errorMessage: String?
    @Published var rawJSON = ""

    private var snapshot: SystemConfigStore.Snapshot?

    func load() async {
        errorMessage = nil
        do {
            let snap = try await SystemConfigStore.load()
            snapshot = snap
            let e = snap.effective
            containerCpus = string(e, "container", "cpus")
            containerMemory = string(e, "container", "memory")
            registryDomain = string(e, "registry", "domain")
            dnsDomain = string(e, "dns", "domain")
            buildCpus = string(e, "build", "cpus")
            buildMemory = string(e, "build", "memory")
            buildRosetta = (e["build"]?["rosetta"] as? NSNumber)?.boolValue ?? false
            buildImage = string(e, "build", "image")
            kernelURL = string(e, "kernel", "url")
            kernelBinaryPath = string(e, "kernel", "binaryPath")
            vminitImage = string(e, "vminit", "image")
            machineCpus = string(e, "machine", "cpus")
            machineMemory = string(e, "machine", "memory")
            var hints: [String: String] = [:]
            for (section, values) in snap.defaults {
                for (key, value) in values {
                    if value is NSNull { continue }
                    let text = (value as? NSNumber).map { n -> String in
                        String(cString: n.objCType) == "c" ? (n.boolValue ? "on" : "off") : "\(n)"
                    } ?? "\(value)"
                    hints["\(section).\(key)"] = text
                }
            }
            defaultHints = hints
            rawJSON = (try? await ContainerService.properties()) ?? ""
            loaded = true
        } catch {
            errorMessage = "Could not load configuration: \(error.localizedDescription)"
        }
    }

    func save() async {
        guard var edited = snapshot?.effective, let defaults = snapshot?.defaults else { return }
        errorMessage = nil
        statusMessage = nil

        func setInt(_ section: String, _ key: String, _ text: String) -> Bool {
            guard let n = Int(text.trimmingCharacters(in: .whitespaces)), n > 0 else {
                errorMessage = "\(section).\(key) must be a positive integer (got “\(text)”)"
                return false
            }
            edited[section, default: [:]][key] = NSNumber(value: n)
            return true
        }
        func setString(_ section: String, _ key: String, _ text: String) {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                edited[section]?[key] = NSNull()
            } else {
                edited[section, default: [:]][key] = trimmed
            }
        }

        guard setInt("container", "cpus", containerCpus),
              setInt("build", "cpus", buildCpus),
              setInt("machine", "cpus", machineCpus) else { return }
        setString("container", "memory", containerMemory)
        setString("registry", "domain", registryDomain)
        setString("dns", "domain", dnsDomain)
        setString("build", "memory", buildMemory)
        edited["build", default: [:]]["rosetta"] = NSNumber(booleanLiteral: buildRosetta)
        setString("build", "image", buildImage)
        setString("kernel", "url", kernelURL)
        setString("kernel", "binaryPath", kernelBinaryPath)
        setString("vminit", "image", vminitImage)
        setString("machine", "memory", machineMemory)

        saving = true
        do {
            try await SystemConfigStore.save(edited: edited, defaults: defaults)
            statusMessage = "Saved. Container defaults, registry and DNS apply to new operations immediately; builder, kernel, machine and init-image changes apply after a service restart."
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
        saving = false
    }

    func hint(_ path: String) -> String? {
        defaultHints[path]
    }

    private func string(_ dict: [String: [String: Any]], _ section: String, _ key: String) -> String {
        guard let value = dict[section]?[key], !(value is NSNull) else { return "" }
        if let n = value as? NSNumber { return "\(n)" }
        return "\(value)"
    }
}

struct SystemSettings: View {
    @EnvironmentObject var state: AppState
    @StateObject private var model = SystemConfigModel()

    var body: some View {
        VStack(spacing: 0) {
            if !model.loaded {
                Spacer()
                if let error = model.errorMessage {
                    EmptyState(icon: "wrench.and.screwdriver", title: "Configuration unavailable", message: error)
                } else {
                    ProgressView()
                }
                Spacer()
            } else {
                Form {
                    Section("Defaults for New Containers") {
                        SteppedCountField(label: "CPUs", hint: model.hint("container.cpus"), text: $model.containerCpus)
                        LabeledField(label: "Memory", hint: model.hint("container.memory"), text: $model.containerMemory, width: 120)
                    }
                    Section("Registry & DNS") {
                        LabeledField(label: "Default registry", hint: model.hint("registry.domain"), text: $model.registryDomain)
                        LabeledField(label: "Local DNS domain", hint: model.hint("dns.domain") ?? "none", text: $model.dnsDomain)
                        DNSDomainsRow(defaultDomain: $model.dnsDomain)
                    }
                    Section("Builder") {
                        SteppedCountField(label: "CPUs", hint: model.hint("build.cpus"), text: $model.buildCpus)
                        LabeledField(label: "Memory", hint: model.hint("build.memory"), text: $model.buildMemory, width: 120)
                        Toggle("Rosetta (x86-64 builds)", isOn: $model.buildRosetta)
                    }
                    Section("Advanced") {
                        LabeledField(label: "Builder image", hint: model.hint("build.image"), text: $model.buildImage, width: 300)
                        LabeledField(label: "Kernel URL", hint: model.hint("kernel.url"), text: $model.kernelURL, width: 300)
                        LabeledField(label: "Kernel binary path", hint: model.hint("kernel.binaryPath"), text: $model.kernelBinaryPath, width: 300)
                        LabeledField(label: "Init image (vminit)", hint: model.hint("vminit.image"), text: $model.vminitImage, width: 300)
                        SteppedCountField(label: "Machine CPUs", hint: model.hint("machine.cpus"), text: $model.machineCpus)
                        LabeledField(label: "Machine memory", hint: model.hint("machine.memory"), text: $model.machineMemory, width: 120)
                    }
                    Section {
                        DisclosureGroup("Effective configuration (JSON)") {
                            // No inner ScrollView: the settings form already
                            // scrolls, and a scrollbar-in-a-scrollbar is worse
                            // than a long section. Expand to full content size.
                            Text(model.rawJSON)
                                .font(.system(size: 10.5, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .formStyle(.grouped)

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    if let status = model.statusMessage {
                        Label(status, systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                    if let error = model.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                    HStack {
                        Text("Overrides are written to ~/.config/container/config.toml")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Spacer()
                        Button("Restart Services") {
                            state.perform("system") {
                                try await ContainerService.systemStop()
                                try await ContainerService.systemStart()
                            }
                        }
                        .disabled(!state.systemState.isRunning || state.busyIDs.contains("system"))
                        Button {
                            Task { await model.save() }
                        } label: {
                            if model.saving {
                                ProgressView().controlSize(.small).frame(width: 40)
                            } else {
                                Text("Save").frame(width: 40)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.saving)
                    }
                }
                .padding(12)
            }
        }
        .task { await model.load() }
    }
}

// MARK: - Settings form controls (macOS System Settings-style rows)

/// Label on the left, visibly bordered text field on the right — so the row
/// clearly reads as editable, unlike a bare TextField in a grouped Form.
/// The platform default is shown in parentheses behind the label.
struct LabeledField: View {
    let label: String
    var hint: String? = nil
    @Binding var text: String
    var width: CGFloat = 200

    var body: some View {
        LabeledContent {
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: width)
                // Leading, not trailing: trailing-aligned fields read as if they
                // "type from the right" (HN: lelandfe) and macOS inputs are LTR.
                .multilineTextAlignment(.leading)
        } label: {
            FieldLabel(label: label, hint: hint)
        }
    }
}

struct FieldLabel: View {
    let label: String
    let hint: String?

    var body: some View {
        HStack(spacing: 5) {
            Text(label)
            if let hint {
                Text("(\(hint))")
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }
}

/// Numeric count with a stepper, System Settings-style.
struct SteppedCountField: View {
    let label: String
    var hint: String? = nil
    @Binding var text: String
    var range: ClosedRange<Int> = 1...64

    var body: some View {
        LabeledContent {
            HStack(spacing: 6) {
                TextField("", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 52)
                    .multilineTextAlignment(.center)
                Stepper("", value: intBinding, in: range)
                    .labelsHidden()
            }
        } label: {
            FieldLabel(label: label, hint: hint)
        }
    }

    private var intBinding: Binding<Int> {
        Binding(
            get: { Int(text) ?? range.lowerBound },
            set: { text = "\($0)" }
        )
    }
}

// MARK: - About

struct AboutSettings: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "shippingbox.fill")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
            Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Davit")
                .font(.title2.weight(.semibold))
            Text("A native UI for Apple's container platform")
                .foregroundStyle(.secondary)
            if case .running(let version) = state.systemState, let version {
                Text(version).font(.caption).foregroundStyle(.tertiary)
            }
            Text("Version \(UpdateChecker.currentVersion)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Check for Updates…") {
                UserDefaults.standard.removeObject(forKey: UpdateChecker.skippedVersionKey)
                state.checkForUpdates(force: true)
            }
            if let update = state.availableUpdate {
                Text("Davit \(update.version) is available — see the Dashboard to install.")
                    .font(.caption)
                    .foregroundStyle(.tint)
            }
            Divider().frame(width: 200)
            Link("apple/container on GitHub", destination: URL(string: "https://github.com/apple/container")!)
                .font(.callout)
            Link("davit.app", destination: URL(string: "https://davit.app")!)
                .font(.callout)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}


/// Host-side local DNS domains (`container system dns`): an /etc/resolver
/// entry per domain so `web.<domain>` resolves from the Mac. Creating and
/// deleting write to /etc/resolver, so they ask for admin once.
struct DNSDomainsRow: View {
    @Binding var defaultDomain: String
    @State private var domains: [String] = DNSDomainService.list()
    @State private var newDomain = ""
    @State private var working = false
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if domains.isEmpty {
                Text("No host DNS domains. Create one (e.g. \u{201C}test\u{201D}) and containers become reachable at \u{201C}name.test\u{201D} from your Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(domains, id: \.self) { domain in
                HStack {
                    Text(domain).font(.system(.body, design: .monospaced))
                    if domain == defaultDomain {
                        Text("default")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.15), in: Capsule())
                            .foregroundStyle(Color.accentColor)
                    }
                    Spacer()
                    if domain != defaultDomain {
                        Button("Make Default") { defaultDomain = domain }
                            .controlSize(.small)
                            .help("Containers join this domain (saved with these settings)")
                    }
                    Button("Delete") { run { try await DNSDomainService.delete(domain) } }
                        .controlSize(.small)
                }
            }
            HStack {
                TextField("New domain (e.g. test)", text: $newDomain)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                Button("Create\u{2026}") {
                    let domain = newDomain.trimmingCharacters(in: .whitespaces)
                    run {
                        try await DNSDomainService.create(domain)
                        await MainActor.run {
                            newDomain = ""
                            if defaultDomain.isEmpty { defaultDomain = domain }
                        }
                    }
                }
                .disabled(newDomain.trimmingCharacters(in: .whitespaces).isEmpty || working)
                if working { ProgressView().controlSize(.small) }
            }
            Text("Creating or deleting a domain asks for administrator authorization (it writes /etc/resolver).")
                .font(.caption)
                .foregroundStyle(.tertiary)
            if let errorText {
                Text(errorText).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
        }
    }

    private func run(_ action: @escaping () async throws -> Void) {
        working = true
        errorText = nil
        Task {
            do {
                try await action()
            } catch {
                // "User canceled" comes back from osascript when the auth dialog is dismissed
                let text = (error as? CLIError)?.message ?? error.localizedDescription
                if !text.contains("User canceled") { errorText = text }
            }
            domains = DNSDomainService.list()
            working = false
        }
    }
}
