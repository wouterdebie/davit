import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Import a Docker Compose file: pick the services to bring up, preview exactly
/// what will be created (services in start order, volumes, networks, per-service
/// CLI equivalents, and honest warnings for anything unsupported), then create
/// & start them.
struct ComposeImportSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    /// Every service in the file; the picker selects from these.
    let file: Compose.Plan
    /// Services ticked by the user. Their dependencies come along without a tick.
    @State private var picked: Set<String>

    init(file: Compose.Plan) {
        self.file = file
        _picked = State(initialValue: ComposeImport.defaultPicks(file))
    }

    private enum Phase: Equatable {
        case ready
        case running(String)         // current step description
        case failed(String)
        case done
    }
    @State private var phase: Phase = .ready
    @State private var completed: Set<Compose.StepKind> = []
    @State private var runtimeWarnings: [String] = []  // from up's hosts sync

    /// What the ticks bring up, or why they can't be (a dependency is gated
    /// behind a profile nothing ticked activates).
    private var selection: Result<Compose.Plan, Error> {
        Result { try ComposeImport.selection(file, picked: picked) }
    }

    private var plan: Compose.Plan {
        (try? selection.get()) ?? ComposeImport.empty(file)
    }

    /// Services the ticks bring up. While the ticks can't be resolved, just the
    /// ticks, so the one that caused it stays visible (and untickable).
    private var included: Set<String> {
        (try? selection.get()).map { Set($0.services.map(\.service)) } ?? picked
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Import Compose — \(file.project)")
                    .font(.title3.weight(.semibold))
                Text("Untick services you don't want. A ticked service brings its dependencies with it.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !plan.volumes.isEmpty || !plan.networks.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(plan.volumes, id: \.self) { v in
                                chip("externaldrive", v, done: completed.contains(.volume(v)))
                            }
                            ForEach(plan.networks, id: \.self) { n in
                                chip("network", n, done: completed.contains(.network(n)))
                            }
                            Spacer()
                        }
                    }

                    ForEach(file.services) { svc in
                        serviceCard(svc)
                    }

                    if !plan.warnings.isEmpty || !runtimeWarnings.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Label("Not everything in the file is supported", systemImage: "exclamationmark.triangle")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.orange)
                            ForEach(plan.warnings + runtimeWarnings, id: \.self) { w in
                                Text(w).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            .frame(maxHeight: 420)

            if case .failure(let error) = selection {
                Text(ComposeImport.pickError(error))
                    .font(.caption).foregroundStyle(.red)
                    .textSelection(.enabled).lineLimit(4)
            } else if case .failed(let message) = phase {
                Text(message)
                    .font(.caption).foregroundStyle(.red)
                    .textSelection(.enabled).lineLimit(4)
            }

            HStack {
                if case .running(let step) = phase {
                    ProgressView().controlSize(.small)
                    Text(step).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(phase == .done ? "Close" : "Cancel") { dismiss() }
                Button {
                    up()
                } label: {
                    Text(buttonTitle)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isRunning || phase == .done || plan.services.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private var isRunning: Bool { if case .running = phase { return true }; return false }

    /// The tick for a service. A dependency of a ticked service shows ticked but
    /// can't be unticked on its own: untick what needs it instead.
    private func checkbox(_ svc: Compose.ServicePlan, included: Bool) -> some View {
        let dependency = included && !picked.contains(svc.service)
        return Toggle("", isOn: Binding(
            get: { included },
            set: { if $0 { picked.insert(svc.service) } else { picked.remove(svc.service) } }
        ))
        .toggleStyle(.checkbox)
        .labelsHidden()
        .disabled(dependency || isRunning || phase == .done)
    }

    /// Why a service is in or out beyond its own tick, if anything.
    private func pickNote(_ svc: Compose.ServicePlan, included: Bool) -> String? {
        if included && !picked.contains(svc.service) {
            let dependents = plan.services.filter { $0.dependsOn[svc.service] != nil }.map(\.service)
            return "Needed by \(dependents.joined(separator: ", "))"
        }
        if !included && !svc.profiles.isEmpty {
            return "Profile \(svc.profiles.joined(separator: ", "))"
        }
        return nil
    }

    private var buttonTitle: String {
        switch phase {
        case .failed: return "Retry Remaining"
        case .done: return "Done"
        default:
            let n = plan.services.count
            return "Create & Start \(n) Service\(n == 1 ? "" : "s")"
        }
    }

    private func chip(_ icon: String, _ label: String, done: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: done ? "checkmark.circle.fill" : icon)
                .foregroundStyle(done ? .green : .secondary)
            Text(label)
        }
        .font(.caption)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(.quaternary.opacity(0.5), in: Capsule())
    }

    private func serviceCard(_ svc: Compose.ServicePlan) -> some View {
        let included = self.included.contains(svc.service)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                checkbox(svc, included: included)
                HStack(spacing: 8) {
                    Image(systemName: completed.contains(.service(svc.service)) ? "checkmark.circle.fill" : "shippingbox")
                        .foregroundStyle(completed.contains(.service(svc.service)) ? Color.green : Color.accentColor)
                    Text(svc.name).font(.body.weight(.medium))
                    Text(svc.image).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .opacity(included ? 1 : 0.5)
                Spacer()
                if let note = pickNote(svc, included: included) {
                    Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            summaryRow(svc)
                .opacity(included ? 1 : 0.5)
            DisclosureGroup {
                Text(svc.cliPreview)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            } label: {
                Text("Equivalent command").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
    }

    private func summaryRow(_ svc: Compose.ServicePlan) -> some View {
        let ports = pairedValues(svc.managementArgs, flag: "--publish")
        let mounts = pairedValues(svc.managementArgs, flag: "--mount").count
        let envs = pairedValues(svc.processArgs, flag: "--env").count
        return HStack(spacing: 10) {
            if !ports.isEmpty {
                Label(ports.joined(separator: "  "), systemImage: "arrow.left.arrow.right")
            }
            if mounts > 0 { Label("\(mounts) mount\(mounts == 1 ? "" : "s")", systemImage: "externaldrive") }
            if envs > 0 { Label("\(envs) env", systemImage: "list.bullet") }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func pairedValues(_ args: [String], flag: String) -> [String] {
        args.indices.compactMap { i in
            args[i] == flag && i + 1 < args.count ? args[i + 1] : nil
        }
    }

    private func up() {
        phase = .running("Starting…")
        Task {
            do {
                let result = try await Compose.up(plan: plan) { step, done in
                    await MainActor.run {
                        if done {
                            // .waiting is transient — the checkmark grid only keys
                            // on volume/network/service steps.
                            if case .waiting = step {} else if case .building = step {} else { completed.insert(step) }
                        } else {
                            switch step {
                            case .volume(let v): phase = .running("Creating volume \(v)…")
                            case .network(let n): phase = .running("Creating network \(n)…")
                            case .service(let s): phase = .running("Starting \(s)… (pulls the image if needed)")
                            case .building(let s): phase = .running("Building \(s)…")
                            case .waiting(let s, let c):
                                phase = .running("Waiting for \(s) (\(c.replacingOccurrences(of: "service_", with: "")))…")
                            }
                        }
                    }
                }
                runtimeWarnings = result.warnings
                phase = .done
                await state.refreshAll()
            } catch {
                let message = (error as? CLIError)?.message
                    ?? (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                phase = .failed(message)
                await state.refreshAll()
            }
        }
    }
}

// MARK: - File picking + parsing entry point

enum ComposeImport {
    /// Present an open panel, parse the chosen file, and hand back every service
    /// in it (or a user-visible error); the sheet picks from those.
    @MainActor
    static func pickAndParse() -> Result<Compose.Plan, CLIError>? {
        let panel = NSOpenPanel()
        panel.title = "Import Compose File"
        panel.allowedContentTypes = [.yaml]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let dir = url.deletingLastPathComponent()
            // The file's sibling .env participates automatically, like docker.
            let (environment, envWarnings) = try Compose.effectiveEnvironment(composeDir: dir.path)
            var plan = try Compose.parse(
                text: text, projectName: dir.lastPathComponent, baseDir: dir.path, environment: environment)
            plan.warnings = envWarnings + plan.warnings
            return .success(plan)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            return .failure(CLIError(command: "compose import", message: message))
        }
    }

    /// The sheet's initial ticks: what a bare `compose up` brings up, i.e. every
    /// service no profile gates. Gated ones start unticked; ticking one activates
    /// its own profiles, like naming it on the CLI does.
    static func defaultPicks(_ file: Compose.Plan) -> Set<String> {
        Set(file.services.filter { $0.profiles.isEmpty }.map(\.service))
    }

    /// What `picked` brings up: those services plus their depends_on closure,
    /// as `compose up <service>…`. Nothing ticked is nothing, not `selecting`'s
    /// "every enabled service".
    static func selection(_ file: Compose.Plan, picked: Set<String>) throws -> Compose.Plan {
        picked.isEmpty ? empty(file) : try file.selecting(services: picked.sorted(), activeProfiles: [])
    }

    /// A selection error, phrased for ticks rather than CLI flags: the sheet's way
    /// to activate a profile is to tick a service it gates.
    static func pickError(_ error: Error) -> String {
        if case Compose.Error.inactiveProfile(service: let service, profile: let profile) = error {
            return "A ticked service needs \(service), which only runs under profile \(profile). Tick \(service) too."
        }
        return (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }

    /// The file with nothing selected.
    static func empty(_ file: Compose.Plan) -> Compose.Plan {
        var plan = file
        plan.volumes = []
        plan.networks = []
        plan.services = []
        return plan
    }
}