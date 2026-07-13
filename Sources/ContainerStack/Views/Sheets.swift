import SwiftUI

// MARK: - Run container sheet

struct RunContainerSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    var prefilledImage: String = ""
    /// When set, the sheet edits this container's config and replaces it on Run.
    var recreate: ContainerRecord? = nil
    var scrollable = true

    @State private var originalCommandArgs: [String] = []
    @State private var originalCommandDisplay = ""

    @State private var image = ""
    @State private var name = ""
    @State private var command = ""
    @State private var ports: [KVPair] = []      // key = host port, value = container port
    @State private var envVars: [KVPair] = []
    @State private var volumeMounts: [KVPair] = []  // key = volume name or host path, value = container path
    @State private var network = "default"
    @State private var cpus = ""
    @State private var memory = ""
    @State private var running = false
    @State private var progressText = ""
    @State private var errorText: String?
    @State private var rosettaInstalled = RosettaCheck.isInstalled()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(recreate == nil ? "Run Container" : "Recreate Container").font(.title3.weight(.semibold))
                if let recreate {
                    Text("replaces “\(recreate.id)”")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)

            Divider()

            if scrollable {
                ScrollView { formContent }
            } else {
                formContent
            }

            Divider()

            HStack {
                if let errorText {
                    Text(errorText)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .lineLimit(3)
                        .textSelection(.enabled)
                } else if running {
                    ProgressView().controlSize(.small)
                    Text(progressText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                Button {
                    run()
                } label: {
                    if running {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(recreate == nil ? "Run" : "Recreate")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(image.isEmpty || running || runBlockedByRosetta)
            }
            .padding(16)
        }
        .frame(width: 560, height: 680)
        .onAppear {
            refreshRosettaStatus()
            image = prefilledImage
            if network.isEmpty || !state.networks.contains(where: { $0.name == network }) {
                network = state.networks.first?.name ?? "default"
            }
            if let source = recreate {
                prefill(from: source)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshRosettaStatus()
        }
    }

    private func prefill(from source: ContainerRecord) {
        image = source.imageReference
        name = source.id
        for port in source.configuration.publishedPorts ?? [] {
            let proto = (port.proto ?? "tcp") == "tcp" ? "" : "/\(port.proto!)"
            ports.append(KVPair(key: "\(port.hostPort ?? 0)", value: "\(port.containerPort ?? 0)\(proto)"))
        }
        for mount in source.configuration.mounts ?? [] {
            volumeMounts.append(KVPair(key: mount.volumeName ?? mount.source ?? "", value: mount.destination ?? ""))
        }
        if let res = source.configuration.resources {
            if let c = res.cpus { cpus = "\(c)" }
            if let m = res.memoryInBytes {
                memory = m % (1 << 30) == 0 ? "\(m >> 30)g" : "\(m >> 20)m"
            }
        }
        if let net = source.status?.networks?.first?.network { network = net }

        // Command + custom env need the image config; reconstructed off-thread.
        Task {
            let prefill = await ContainerService.recreatePrefill(for: source)
            originalCommandArgs = prefill.commandArgs
            originalCommandDisplay = prefill.commandArgs.joined(separator: " ")
            command = originalCommandDisplay
            for entry in prefill.customEnv {
                let parts = entry.split(separator: "=", maxSplits: 1).map(String.init)
                envVars.append(KVPair(key: parts.first ?? "", value: parts.count > 1 ? parts[1] : ""))
            }
        }
    }

    private var formContent: some View {
        VStack(spacing: 14) {
            DetailCard(title: "Image", icon: "square.stack.3d.down.forward") {
                HStack(spacing: 8) {
                    TextField("nginx:latest", text: $image)
                        .textFieldStyle(.roundedBorder)
                    if !state.images.isEmpty {
                        Menu {
                            ForEach(state.images) { img in
                                Button(img.shortNameTag) { image = img.name }
                            }
                        } label: {
                            Image(systemName: "chevron.up.chevron.down")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .help("Choose a local image")
                    }
                }
                TextField("Container name (optional)", text: $name)
                    .textFieldStyle(.roundedBorder)
                TextField("Command override (optional, e.g. sleep infinity)", text: $command)
                    .textFieldStyle(.roundedBorder)
            }

            if compatibility == .amd64RequiresRosetta {
                compatibilityCard
            }

            DetailCard(title: "Ports", icon: "arrow.left.arrow.right") {
                KeyValueEditor(keyPlaceholder: "Host port", valuePlaceholder: "Container port", pairs: $ports)
            }
            DetailCard(title: "Environment", icon: "list.bullet.rectangle") {
                KeyValueEditor(keyPlaceholder: "KEY", valuePlaceholder: "value", pairs: $envVars, separator: "=")
            }
            DetailCard(title: "Mounts", icon: "externaldrive") {
                KeyValueEditor(keyPlaceholder: "Volume name or host path", valuePlaceholder: "Container path", pairs: $volumeMounts)
            }

            DetailCard(title: "Resources & Network", icon: "cpu") {
                HStack(alignment: .firstTextBaseline, spacing: 18) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("CPUs").font(.caption).foregroundStyle(.secondary)
                        TextField("4", text: $cpus)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 60)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Memory").font(.caption).foregroundStyle(.secondary)
                        TextField("1gb", text: $memory)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Network").font(.caption).foregroundStyle(.secondary)
                        Picker("", selection: $network) {
                            ForEach(state.networks) { net in
                                Text(net.name).tag(net.name)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    Spacer()
                }
            }

            DetailCard(title: "Command line", icon: "terminal") {
                HStack(alignment: .top, spacing: 8) {
                    Text(cliPreview)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(cliPreview, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Copy command")
                }
                Text("Davit runs this over the API — the equivalent `container` command, for reference.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(16)
    }

    // MARK: Compatibility (amd64-only image on Apple silicon)

    private var selectedImage: ImageRecord? {
        guard !image.isEmpty else { return nil }
        return state.images.first { $0.matchesReference(image) }
    }

    private var compatibility: ImageRecord.Compatibility {
        selectedImage?.compatibility(hostArch: HostPlatform.arch) ?? .unknown
    }

    private var runBlockedByRosetta: Bool {
        compatibility == .amd64RequiresRosetta && !rosettaInstalled
    }

    private func refreshRosettaStatus() {
        rosettaInstalled = RosettaCheck.isInstalled()
    }

    @ViewBuilder
    private var compatibilityCard: some View {
        let installed = rosettaInstalled
        let tint: Color = installed ? .orange : .red
        let icon = installed ? "exclamationmark.triangle" : "xmark.octagon"
        DetailCard(title: "Compatibility", icon: icon) {
            VStack(alignment: .leading, spacing: 8) {
                if installed {
                    Text("This image only ships `linux/amd64`. It will run under Rosetta translation on Apple silicon.")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(tint)
                    Text("Davit is passing `--arch amd64` automatically. Performance will be lower than a native `arm64` image.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("This image only ships `linux/amd64` and Rosetta isn't installed.")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(tint)
                    Text("Install Rosetta with `softwareupdate --install-rosetta --agree-to-license`, then try again.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(
                                "softwareupdate --install-rosetta --agree-to-license",
                                forType: .string)
                        } label: {
                            Label("Copy Install Command", systemImage: "doc.on.doc")
                        }
                        Button {
                            let url = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
                            NSWorkspace.shared.open(url)
                        } label: {
                            Label("Open Terminal", systemImage: "terminal")
                        }
                    }
                    .controlSize(.small)
                    .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The four flag groups the form produces, shared by run() and the CLI preview.
    private struct RunArgs { var process: [String]; var management: [String]; var resource: [String]; var command: [String] }

    private func buildArgs() -> RunArgs {
        var processArgs: [String] = []
        for e in envVars where !e.key.isEmpty {
            processArgs += ["--env", "\(e.key)=\(e.value)"]
        }

        var managementArgs: [String] = []
        for p in ports where !p.key.isEmpty && !p.value.isEmpty {
            managementArgs += ["--publish", "\(p.key):\(p.value)"]
        }
        for m in volumeMounts where !m.key.isEmpty && !m.value.isEmpty {
            if m.key.hasPrefix("/") || m.key.hasPrefix("~") {
                let src = (m.key as NSString).expandingTildeInPath
                managementArgs += ["--mount", "type=bind,source=\(src),target=\(m.value)"]
            } else {
                managementArgs += ["--mount", "type=volume,source=\(m.key),target=\(m.value)"]
            }
        }
        if network != "default" && !network.isEmpty { managementArgs += ["--network", network] }
        if compatibility == .amd64RequiresRosetta {
            // Pin amd64-only images so the platform selects the Rosetta path.
            managementArgs += ["--arch", "amd64"]
        }

        var resourceArgs: [String] = []
        if !cpus.isEmpty { resourceArgs += ["--cpus", cpus] }
        if !memory.isEmpty { resourceArgs += ["--memory", memory] }

        let commandArgs: [String]
        if !originalCommandDisplay.isEmpty, command == originalCommandDisplay {
            commandArgs = originalCommandArgs  // exact args, no whitespace re-splitting
        } else {
            commandArgs = command.isEmpty ? [] : command.split(separator: " ").map(String.init)
        }
        return RunArgs(process: processArgs, management: managementArgs, resource: resourceArgs, command: commandArgs)
    }

    /// The equivalent `container run …` for what the form will do. Davit actually
    /// runs this over XPC — this is shown so you can see (and copy) the CLI form.
    private var cliPreview: String {
        let a = buildArgs()
        var argv = ["container", "run", "--detach"]
        if !name.isEmpty { argv += ["--name", name] }
        argv += a.management + a.resource + a.process
        argv.append(image.isEmpty ? "<image>" : image)
        argv += a.command
        return argv.map(Self.shellQuote).joined(separator: " ")
    }

    private static func shellQuote(_ s: String) -> String {
        if s.isEmpty { return "''" }
        if s.range(of: "^[A-Za-z0-9._:/=@,+-]+$", options: .regularExpression) != nil { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func run() {
        running = true
        errorText = nil
        progressText = "Creating container… (pulls the image on first run)"

        let args = buildArgs()
        let processArgs = args.process
        let managementArgs = args.management
        let resourceArgs = args.resource
        let commandArgs = args.command
        let containerName = name
        let replacing = recreate

        Task {
            do {
                let sameName = replacing?.id == containerName
                if let replacing, sameName {
                    // Same name: must clear it first (names are unique, no rename API).
                    try? await ContainerService.stop(replacing.id)
                    try await ContainerService.delete(replacing.id, force: true)
                }
                try await ContainerService.runContainer(
                    image: image,
                    name: containerName.isEmpty ? nil : containerName,
                    processArgs: processArgs,
                    managementArgs: managementArgs,
                    resourceArgs: resourceArgs,
                    commandArgs: commandArgs,
                    progressUpdate: { events in
                        // Image-fetch phase: surface the platform's own
                        // descriptions ("Fetching image…", layer counts) live.
                        await MainActor.run {
                            for event in events {
                                switch event {
                                case .setDescription(let text): progressText = text
                                case .setSubDescription(let text): progressText = text
                                default: break
                                }
                            }
                        }
                    }
                )
                await MainActor.run { progressText = "Starting…" }
                if let replacing, !sameName {
                    // Rename: the new container is up, now retire the old one.
                    try? await ContainerService.stop(replacing.id)
                    try await ContainerService.delete(replacing.id, force: true)
                }
                await state.refreshAll()
                dismiss()
            } catch let e as CLIError {
                errorText = e.message
            } catch {
                errorText = error.localizedDescription
            }
            running = false
        }
    }
}

// MARK: - Pull image sheet

struct PullImageSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = PullProgressModel()
    /// Set to re-pull an existing image's tag; the pull starts immediately.
    var prefilledReference: String? = nil
    @State private var reference = ""
    @State private var started = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Pull Image").font(.title3.weight(.semibold))
                Spacer()
            }
            .padding(20)
            Divider()

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    TextField("Image reference (e.g. nginx:latest, ghcr.io/org/app:tag)", text: $reference)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { pull() }
                        .disabled(model.isRunning)
                    Button {
                        pull()
                    } label: {
                        if model.isRunning {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Pull")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(reference.isEmpty || model.isRunning)
                }
                Text("Try: nginxdemos/hello (open it in your browser) · alpine · postgres · redis · node")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                if started {
                    ConsoleView(lines: model.lines)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
                }
            }
            .padding(16)

            Divider()
            HStack {
                if let ok = model.succeeded {
                    Label(ok ? "Pull complete" : "Pull failed",
                          systemImage: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(ok ? .green : .red)
                        .font(.callout)
                }
                Spacer()
                Button(model.succeeded == true ? "Done" : "Close") {
                    model.cancel()
                    dismiss()
                }
            }
            .padding(16)
        }
        .frame(width: 560, height: started ? 480 : 220)
        .task {
            if let prefilledReference, !started {
                reference = prefilledReference
                pull()
            }
        }
        .onChange(of: model.succeeded) {
            if model.succeeded == true {
                Task { await state.refreshAll() }
            }
        }
        .onDisappear { model.cancel() }
    }

    private func pull() {
        guard !reference.isEmpty else { return }
        started = true
        model.start(reference: reference)
    }
}

// MARK: - Create volume sheet

struct CreateVolumeSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var size = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Create Volume").font(.title3.weight(.semibold))
            TextField("Volume name", text: $name)
                .textFieldStyle(.roundedBorder)
            TextField("Max size (optional, e.g. 10G — default 512G)", text: $size)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Create") {
                    let n = name, s = size
                    state.perform("volume-create") { try await ContainerService.createVolume(name: n, size: s.isEmpty ? nil : s) }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

// MARK: - Create network sheet

struct CreateNetworkSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var subnet = ""
    @State private var isInternal = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Create Network").font(.title3.weight(.semibold))
            TextField("Network name", text: $name)
                .textFieldStyle(.roundedBorder)
            TextField("Subnet (optional, e.g. 192.168.100.0/24)", text: $subnet)
                .textFieldStyle(.roundedBorder)
            Toggle("Internal (host-only, no outbound access)", isOn: $isInternal)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Create") {
                    let n = name, s = subnet, i = isInternal
                    state.perform("network-create") {
                        try await ContainerService.createNetwork(name: n, subnet: s.isEmpty ? nil : s, internal: i)
                    }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
