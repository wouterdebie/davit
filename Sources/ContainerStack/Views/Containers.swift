import SwiftUI

// MARK: - Containers list

struct ContainersView: View {
    @EnvironmentObject var state: AppState
    @State private var search = ""
    @State private var showRunSheet = false
    @State private var composePlan: Compose.Plan?
    @State private var composeError: CLIError?
    @State private var path: [String] = []

    private var filtered: [ContainerRecord] {
        guard !search.isEmpty else { return state.containers }
        let q = search.lowercased()
        return state.containers.filter {
            $0.id.lowercased().contains(q) || $0.imageReference.lowercased().contains(q)
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if !state.systemState.isRunning && state.initialLoadDone {
                    ServicesStoppedState()
                } else if state.containers.isEmpty && state.initialLoadDone {
                    EmptyState(
                        icon: "shippingbox",
                        title: "No containers",
                        message: "Run a container from an image to get started.",
                        actionLabel: "Run Container…"
                    ) { showRunSheet = true }
                } else {
                    list
                }
            }
            .navigationTitle("Containers")
            .navigationDestination(for: String.self) { id in
                ContainerDetailView(containerID: id)
            }
            .searchable(text: $search, placement: .toolbar, prompt: "Filter containers")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        showRunSheet = true
                    } label: {
                        Label("Run Container", systemImage: "plus")
                    }
                    .help("Run a new container")

                    Menu {
                        Button("Import Compose File…") {
                            switch ComposeImport.pickAndParse() {
                            case .success(let plan): composePlan = plan
                            case .failure(let error): composeError = error
                            case nil: break
                            }
                        }
                        Divider()
                        Button("Stop All Running") {
                            state.perform("all-containers") { try await ContainerService.stopAll() }
                        }
                        .disabled(state.runningContainers.isEmpty)
                        Divider()
                        Button("Delete Stopped Containers…", role: .destructive) {
                            state.perform("all-containers") { try await ContainerService.pruneContainers() }
                        }
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                }
            }
            .sheet(isPresented: $showRunSheet) {
                RunContainerSheet()
            }
            .onChange(of: state.pendingContainerOpen) { consumePendingOpen() }
            .onAppear { consumePendingOpen() }
        }
        // Separate node from the run sheet — two .sheet on one node shadow each other.
        .sheet(item: $composePlan) { plan in
            ComposeImportSheet(plan: plan)
        }
        .task {
            // Harness: `--pose-compose <file>` opens the import sheet on that file.
            let args = ProcessInfo.processInfo.arguments
            if let i = args.firstIndex(of: "--pose-compose"), i + 1 < args.count {
                try? await Task.sleep(for: .seconds(2))
                let url = URL(fileURLWithPath: args[i + 1])
                if let text = try? String(contentsOf: url, encoding: .utf8) {
                    let dir = url.deletingLastPathComponent()
                    let environment = (try? Compose.effectiveEnvironment(composeDir: dir.path))?.environment
                        ?? ProcessInfo.processInfo.environment  // .env may throw (${X:?}); degrade to process env, not empty
                    composePlan = try? ComposeImport.parseFiltered(
                        text: text, projectName: dir.lastPathComponent, baseDir: dir.path,
                        environment: environment)
                    try? await Task.sleep(for: .seconds(1))
                    FileHandle.standardError.write(Data("POSED compose\n".utf8))
                }
            }
        }
        .alert("Can't import compose file", isPresented: .init(
            get: { composeError != nil }, set: { if !$0 { composeError = nil } }
        )) {
            Button("OK") { composeError = nil }
        } message: {
            Text(composeError?.message ?? "")
        }
        .task {
            if ProcessInfo.processInfo.arguments.contains("--probe-recreate-detail")
                || ProcessInfo.processInfo.arguments.contains("--pose-detail") {
                // `--pose-container <id>` picks which container to pose; default first.
                let args = ProcessInfo.processInfo.arguments
                let wanted = args.firstIndex(of: "--pose-container").flatMap { i in
                    i + 1 < args.count ? args[i + 1] : nil
                }
                for _ in 0..<20 {
                    let target = wanted.flatMap { id in state.containers.first { $0.id == id } }
                        ?? state.containers.first
                    if let target {
                        path.append(target.id)
                        FileHandle.standardError.write(Data("DBG probe: pushed detail \(target.id)\n".utf8))
                        break
                    }
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }
    }

    private var list: some View {
        ContainerListContent(containers: filtered) { path.append($0) }
            .refreshIndicator(state.isRefreshing)
    }

    /// Reveal a container requested from another section (e.g. the Dashboard).
    private func consumePendingOpen() {
        guard let id = state.pendingContainerOpen else { return }
        state.pendingContainerOpen = nil
        if path.last != id { path.append(id) }
    }
}

struct ContainerListContent: View {
    let containers: [ContainerRecord]
    var scrollable = true
    let open: (String) -> Void

    var body: some View {
        CardList(items: containers, scrollable: scrollable) { container in
            HoverRow(action: { open(container.id) }) {
                ContainerRow(container: container)
            }
            .contextMenu { ContainerActions(container: container, includeOpen: false) }
        }
    }
}

struct ContainerRow: View {
    @EnvironmentObject var state: AppState
    let container: ContainerRecord

    var body: some View {
        HStack(spacing: 12) {
            StatusDot(color: container.state.color, pulsing: container.isRunning)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(container.id)
                        .font(.body.weight(.medium))
                    if let ports = container.configuration.publishedPorts, !ports.isEmpty {
                        Text(ports.map(\.shortDisplay).joined(separator: ", "))
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.blue.opacity(0.12), in: Capsule())
                            .foregroundStyle(.blue)
                    }
                }
                Text(container.shortImage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if container.isRunning, let sample = state.latestSample(for: container.id) {
                HStack(spacing: 14) {
                    MiniStat(label: "CPU", value: String(format: "%.0f%%", sample.cpuPercent))
                    MiniStat(label: "MEM", value: formatBytes(sample.memoryBytes))
                    if let ip = container.primaryIPv4 {
                        MiniStat(label: "IP", value: ip)
                    }
                }
            } else if !container.isRunning {
                Text(relativeDate(container.created))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            if state.busyIDs.contains(container.id) {
                ProgressView().controlSize(.small)
            } else {
                quickAction
            }
        }
        .padding(.vertical, 5)
    }

    @ViewBuilder
    private var quickAction: some View {
        if container.isRunning {
            Button {
                state.stopContainer(container)
            } label: {
                Image(systemName: "stop.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Stop")
        } else {
            Button {
                state.startContainer(container)
            } label: {
                Image(systemName: "play.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.green)
            .help("Start")
        }
    }
}

struct MiniStat: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(label).font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
            Text(value).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Shared action set (context menus + toolbars)

struct ContainerActions: View {
    @EnvironmentObject var state: AppState
    let container: ContainerRecord
    var includeOpen = true

    var body: some View {
        if container.isRunning {
            Button("Stop") { state.stopContainer(container) }
            Button("Restart") { state.restartContainer(container) }
            Button("Kill") { state.killContainer(container) }
            Button("Open Terminal") { TerminalLauncher.openShell(containerID: container.id) }
            if let port = container.configuration.publishedPorts?.first?.hostPort {
                Button("Open localhost:\(String(port)) in Browser") {
                    NSWorkspace.shared.open(URL(string: "http://localhost:\(port)")!)
                }
            }
        } else {
            Button("Start") { state.startContainer(container) }
        }
        Button("Edit & Recreate…") { state.recreateTarget = container }
        Toggle("Start when Davit Opens", isOn: Binding(
            get: { state.isAutoStart(container.id) },
            set: { _ in state.toggleAutoStart(container.id) }
        ))
        Divider()
        Button("Copy ID") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(container.id, forType: .string)
        }
        if let ip = container.primaryIPv4 {
            Button("Copy IP (\(ip))") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(ip, forType: .string)
            }
        }
        Divider()
        Button(container.isRunning ? "Force Delete" : "Delete", role: .destructive) {
            state.deleteContainer(container)
        }
    }
}
