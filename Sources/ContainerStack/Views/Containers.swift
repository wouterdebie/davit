import SwiftUI
import UniformTypeIdentifiers

// MARK: - Containers list

struct ContainersView: View {
    @EnvironmentObject var state: AppState
    @State private var search = ""
    @State private var showRunSheet = false
    @State private var composePlan: Compose.Plan?
    @State private var composeError: CLIError?
    /// Label key to group the list by ("" = flat). Shared with the Dashboard.
    @AppStorage("containerGroupBy") private var groupBy = ""
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
                // While a detail is pushed (path non-empty) the root is hidden,
                // so keep it as `list`: a transient systemState/containers flip
                // must not swap the NavigationStack root out from under a queued
                // navigation request (issue #17).
                if path.isEmpty && !state.systemState.isRunning && state.initialLoadDone {
                    ServicesStoppedState()
                } else if path.isEmpty && state.containers.isEmpty && state.initialLoadDone {
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

                    let groupKeys = ContainerGrouping.availableKeys(state.containers)
                    if !groupKeys.isEmpty {
                        Menu {
                            Picker("Group by", selection: $groupBy) {
                                Text("None").tag("")
                                Divider()
                                ForEach(groupKeys, id: \.self) { key in
                                    Text(ContainerGrouping.friendlyName(key)).tag(key)
                                }
                            }
                            .pickerStyle(.inline)
                        } label: {
                            Label("Group", systemImage: "rectangle.3.group")
                        }
                        .help("Group containers by a label")
                    }

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
            .onChange(of: state.pendingOpen?.id) { consumePendingOpen() }
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
        ContainerListContent(containers: filtered, groupByKey: groupBy) { path.append($0) }
            .refreshIndicator(state.isRefreshing)
    }

    /// Reveal a container requested from another section (e.g. the Dashboard,
    /// or ⌘K global search).
    private func consumePendingOpen() {
        let target: String
        let clearsPendingOpen: Bool
        if state.pendingOpen?.section == .containers, let id = state.pendingOpen?.id {
            target = id
            clearsPendingOpen = true
        } else if let id = state.pendingContainerOpen {
            target = id
            clearsPendingOpen = false
        } else {
            return
        }
        // Defer the path mutation to the next runloop tick. .onChange/.onAppear
        // run inside SwiftUI's Update.end() transaction, and mutating a
        // NavigationStack-bound path there races NavigationAuthority's request
        // flush — a NavigationColumnState assertion crash on some macOS
        // versions (issue #17).
        DispatchQueue.main.async {
            if clearsPendingOpen { state.pendingOpen = nil } else { state.pendingContainerOpen = nil }
            if path.last != target { path.append(target) }
        }
    }
}

/// Grouping containers by a label value (e.g. a `project` label your tooling
/// sets with `container run --label`). "" means no grouping (flat list).
enum ContainerGrouping {
    /// Label keys presented under the friendly name "Project", in priority order.
    static let projectKeys = ["com.davit.compose.project", "com.docker.compose.project", "project"]

    /// Label keys usable for grouping across these containers, sorted. Drops
    /// platform-internal noise; compose-project keys are kept (shown as "Project").
    static func availableKeys(_ containers: [ContainerRecord]) -> [String] {
        var keys = Set<String>()
        for c in containers { for k in (c.configuration.labels ?? [:]).keys { keys.insert(k) } }
        return keys.filter { !$0.hasPrefix("com.apple.container.") }.sorted()
    }

    static func friendlyName(_ key: String) -> String {
        projectKeys.contains(key) ? "Project" : key
    }

    /// Group by the value of `key`; containers missing it fall into "Ungrouped"
    /// (always last). Group titles sort alphabetically.
    static func groups(_ containers: [ContainerRecord], by key: String)
        -> [(title: String, containers: [ContainerRecord])]
    {
        var byValue: [String: [ContainerRecord]] = [:]
        var ungrouped: [ContainerRecord] = []
        for c in containers {
            if let v = c.configuration.labels?[key], !v.isEmpty { byValue[v, default: []].append(c) }
            else { ungrouped.append(c) }
        }
        var result = byValue.keys.sorted().map { (title: $0, containers: byValue[$0]!) }
        if !ungrouped.isEmpty { result.append((title: "Ungrouped", containers: ungrouped)) }
        return result
    }
}

struct ContainerListContent: View {
    let containers: [ContainerRecord]
    var scrollable = true
    var groupByKey: String = ""     // "" = flat list
    let open: (String) -> Void

    /// Persisted collapsed group ids ("<key>\n<value>"), newline-joined.
    @AppStorage("collapsedContainerGroups") private var collapsedRaw = ""

    /// Only group when the selected key is actually present, else fall back flat.
    private var effectiveKey: String {
        ContainerGrouping.availableKeys(containers).contains(groupByKey) ? groupByKey : ""
    }

    var body: some View {
        if effectiveKey.isEmpty {
            CardList(items: containers, scrollable: scrollable) { row($0) }
        } else if scrollable {
            ScrollView { grouped }
        } else {
            grouped
        }
    }

    private var grouped: some View {
        let collapsed = Set(collapsedRaw.split(separator: "\n").map(String.init))
        return LazyVStack(alignment: .leading, spacing: 2) {
            ForEach(ContainerGrouping.groups(containers, by: effectiveKey), id: \.title) { group in
                let gid = "\(effectiveKey)\n\(group.title)"
                let isCollapsed = collapsed.contains(gid)
                GroupHeader(
                    title: group.title, count: group.containers.count,
                    containers: group.containers, isCollapsed: isCollapsed,
                    onToggle: { toggleCollapse(gid) })
                if !isCollapsed {
                    ForEach(group.containers) { row($0) }
                }
            }
        }
        .padding(10)
    }

    private func toggleCollapse(_ id: String) {
        var set = Set(collapsedRaw.split(separator: "\n").map(String.init))
        if set.contains(id) { set.remove(id) } else { set.insert(id) }
        collapsedRaw = set.sorted().joined(separator: "\n")
    }

    @ViewBuilder private func row(_ container: ContainerRecord) -> some View {
        HoverRow(action: { open(container.id) }) {
            ContainerRow(container: container)
        }
        .contextMenu { ContainerActions(container: container, includeOpen: false) }
    }
}

/// Section header for a grouped list: title + count pill. With `onToggle` set
/// it becomes interactive — a collapse chevron and a group-actions menu
/// (start/stop/restart every container in the group). Plain (Dashboard) when
/// no toggle is provided.
struct GroupHeader: View {
    @EnvironmentObject var state: AppState
    let title: String
    let count: Int
    var containers: [ContainerRecord] = []
    var isCollapsed = false
    var onToggle: (() -> Void)? = nil

    private var running: [ContainerRecord] { containers.filter(\.isRunning) }
    private var stopped: [ContainerRecord] { containers.filter { !$0.isRunning } }

    var body: some View {
        HStack(spacing: 6) {
            if let onToggle {
                Button(action: onToggle) {
                    HStack(spacing: 6) {
                        Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                            .font(.caption2).foregroundStyle(.secondary).frame(width: 10)
                        titleLabel
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                groupMenu
            } else {
                titleLabel
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 2)
    }

    private var titleLabel: some View {
        HStack(spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold))
            Text("\(count)")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(.secondary.opacity(0.15), in: Capsule())
        }
    }

    private var groupMenu: some View {
        Menu {
            Button("Start All") { stopped.forEach { state.startContainer($0) } }
                .disabled(stopped.isEmpty)
            Button("Stop All") { running.forEach { state.stopContainer($0) } }
                .disabled(running.isEmpty)
            Button("Restart All") { running.forEach { state.restartContainer($0) } }
                .disabled(running.isEmpty)
        } label: {
            Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Actions for every container in “\(title)”")
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
        Button("Export Filesystem…") { exportFilesystem() }
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

    /// Export the container's filesystem to a tar archive the user picks.
    private func exportFilesystem() {
        let panel = NSSavePanel()
        panel.title = "Export Container Filesystem"
        panel.nameFieldStringValue = "\(container.id).tar"
        panel.allowedContentTypes = [.init(filenameExtension: "tar") ?? .data]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        state.exportContainer(container, to: url)
    }
}
