import SwiftUI
import Charts

struct ContainerDetailView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    let containerID: String

    enum Tab: String, CaseIterable {
        case overview = "Overview"
        case logs = "Logs"
        case stats = "Stats"
        case files = "Files"
        case inspect = "Inspect"

        var title: LocalizedStringResource {
            switch self {
            case .overview: "Overview"
            case .logs: "Logs"
            case .stats: "Stats"
            case .files: "Files"
            case .inspect: "Inspect"
            }
        }
    }
    @State private var tab: Tab = {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--pose-tab-stats") { return .stats }
        if args.contains("--pose-tab-files") { return .files }
        return .overview
    }()
    /// Set by the overview OOM banner's "View kernel log" button so the Logs
    /// tab opens straight onto the boot (kernel) log.
    @State private var openLogsOnBoot = false

    private var container: ContainerRecord? {
        state.containers.first { $0.id == containerID }
    }

    var body: some View {
        Group {
            if let container {
                VStack(spacing: 0) {
                    header(container)
                    Divider()
                    tabContent(container)
                }
            } else {
                EmptyState(icon: "shippingbox", title: "Container removed",
                           message: "This container no longer exists.")
            }
        }
        // Name lives in the principal toolbar item; an empty title avoids
        // repeating it inline next to the back button.
        .navigationTitle(Text(verbatim: ""))
        .onAppear {
            if ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("--probe") }) {
                FileHandle.standardError.write(Data("DBG detail-view-shown \(containerID)\n".utf8))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .davitShowBootLog)) { note in
            guard note.object as? String == containerID else { return }
            openLogsOnBoot = true
            tab = .logs
        }
        .onReceive(NotificationCenter.default.publisher(for: .davitShowStdioLog)) { note in
            guard note.object as? String == containerID else { return }
            openLogsOnBoot = false
            tab = .logs
        }
        .toolbar {
            if let container {
                ToolbarItemGroup(placement: .primaryAction) {
                    if state.busyIDs.contains(container.id) {
                        // Wrapped in a disabled button so the spinner shares the
                        // toolbar capsule's metrics instead of floating misaligned.
                        Button {} label: {
                            ProgressView()
                                .controlSize(.small)
                        }
                        .disabled(true)
                    }
                    if container.isRunning {
                        Button { state.stopContainer(container) } label: {
                            Label("Stop", systemImage: "stop.fill")
                        }.help(Text("Stop", comment: "Tooltip for the toolbar button that stops this container."))
                        Button { state.restartContainer(container) } label: {
                            Label("Restart", systemImage: "arrow.clockwise")
                        }.help(Text("Restart", comment: "Tooltip for the toolbar button that restarts this container."))
                        Button { TerminalLauncher.openShell(containerID: container.id) } label: {
                            Label("Terminal", systemImage: "terminal")
                        }.help(Text("Open shell in Terminal", comment: "Tooltip for the toolbar button that opens a container shell in the user's terminal."))
                    } else {
                        Button { state.startContainer(container) } label: {
                            Label("Start", systemImage: "play.fill")
                        }.help(Text("Start", comment: "Tooltip for the toolbar button that starts this container."))
                    }
                    Menu {
                        ContainerActions(container: container)
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                }
            }
        }
    }

    private func header(_ c: ContainerRecord) -> some View {
        // First content row: status dot (pulsing) + name + state pill. The name
        // is here only (nav title is empty, so no "< name" duplicate), and the
        // image shows once in the Overview → General card.
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                StatusDot(color: c.state.color, pulsing: c.isRunning)
                Text(c.id).font(.title3.weight(.semibold))
                StateChip(state: c.state)
                Spacer()
            }
            Picker(selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.title).tag($0) }
            } label: {
                EmptyView()
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 460)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private func tabContent(_ c: ContainerRecord) -> some View {
        switch tab {
        case .overview: ContainerOverviewTab(container: c)
        case .logs: ContainerLogsTab(containerID: c.id, initialBoot: openLogsOnBoot)
        case .stats: ContainerStatsTab(container: c)
        case .files: ContainerFilesTab(container: c)
        case .inspect: InspectTab(kind: "container", id: c.id)
        }
    }
}

// MARK: - Overview tab

struct ContainerOverviewTab: View {
    @EnvironmentObject var state: AppState
    let container: ContainerRecord
    var scrollable = true
    /// The configured default DNS domain (dns.domain), loaded once per show:
    /// with a host resolver domain created, containers answer at id.<domain>.
    @State private var dnsDomain: String?

    var body: some View {
        Group {
            if scrollable {
                ScrollView { content.thinScrollers() }
            } else {
                content
            }
        }
        .task {
            let domain = (try? await Backend.systemConfig())?.dns.domain
            // Only show the hint when the host can actually resolve it.
            if let domain, DNSDomainService.list().contains(domain) {
                dnsDomain = domain
            }
        }
        .task(id: container.id) {
            // Learn why a stopped container died (OOM), even if it happened
            // while Davit wasn't running.
            state.checkStopReasonIfNeeded(container.id)
        }
    }

    private var content: some View {
            VStack(spacing: 14) {
                if !container.isRunning, let reason = state.stopReasons[container.id] {
                    switch reason {
                    case .outOfMemory(let process): oomBanner(process: process)
                    case .rosettaIncompatible(let vectorType): rosettaBanner(vectorType: vectorType)
                    }
                }

                DetailCard(title: "General", icon: "info.circle") {
                    InfoRow(label: "ID", value: container.id, monospaced: true, copyable: true)
                    InfoRow(label: "Image", value: container.imageReference, monospaced: true, copyable: true)
                    if !container.command.isEmpty {
                        InfoRow(label: "Command", value: container.command, monospaced: true)
                    }
                    InfoRow(label: "Platform", value: container.configuration.platform?.display ?? "—")
                    InfoRow(label: "Created", value: absoluteAndRelative(container.created))
                    if container.isRunning {
                        InfoRow(label: "Started", value: absoluteAndRelative(container.started))
                    }
                    if let res = container.configuration.resources {
                        InfoRow(label: "Resources",
                                value: String(localized: "\(res.cpus ?? 0) CPUs · \(formatBytes(res.memoryInBytes)) memory",
                                             comment: "Resource summary — the first value is the CPU count, the second is the memory limit."))
                    }
                }

                if let nets = container.status?.networks, !nets.isEmpty {
                    DetailCard(title: "Network", icon: "network") {
                        ForEach(nets, id: \.self) { net in
                            if let ip = net.ipv4Address {
                                InfoRow(label: "IPv4", value: ip, monospaced: true, copyable: true)
                            }
                            if let gw = net.ipv4Gateway {
                                InfoRow(label: "Gateway", value: gw, monospaced: true)
                            }
                            if let mac = net.macAddress {
                                InfoRow(label: "MAC", value: mac, monospaced: true)
                            }
                            if let host = net.hostname {
                                InfoRow(label: "Hostname", value: host, monospaced: true)
                            }
                            InfoRow(label: "Network", value: net.network ?? "default")
                        }
                        if let domain = dnsDomain, !domain.isEmpty {
                            InfoRow(label: "DNS name", value: "\(container.id).\(domain)", monospaced: true, copyable: true)
                        }
                    }
                }

                if let ports = container.configuration.publishedPorts, !ports.isEmpty {
                    DetailCard(title: "Published Ports", icon: "arrow.left.arrow.right") {
                        ForEach(ports, id: \.self) { port in
                            HStack {
                                Text(port.display)
                                    .font(.system(.callout, design: .monospaced))
                                Spacer()
                                Button("Open in Browser") {
                                    NSWorkspace.shared.open(URL(string: "http://localhost:\(port.hostPort ?? 0)")!)
                                }
                                .controlSize(.small)
                            }
                        }
                    }
                }

                if let mounts = container.configuration.mounts, !mounts.isEmpty {
                    DetailCard(title: "Mounts", icon: "externaldrive") {
                        ForEach(mounts, id: \.self) { m in
                            HStack(spacing: 8) {
                                Text(m.kindLabel)
                                    .font(.caption.weight(.medium))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.purple.opacity(0.12), in: Capsule())
                                    .foregroundStyle(.purple)
                                Text(verbatim: "\(m.displaySource) → \(m.destination ?? "—")")
                                    .font(.system(.callout, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }

                if let env = container.configuration.initProcess?.environment, !env.isEmpty {
                    DetailCard(title: "Environment", icon: "list.bullet.rectangle") {
                        ForEach(env, id: \.self) { e in
                            Text(e)
                                .font(.system(.callout, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                }

                if let labels = container.configuration.labels, !labels.isEmpty {
                    DetailCard(title: "Labels", icon: "tag") {
                        ForEach(labels.sorted(by: { $0.key < $1.key }), id: \.key) { k, v in
                            InfoRow(rawLabel: k, value: v, monospaced: true)
                        }
                    }
                }
            }
            .padding(16)
    }

    private func absoluteAndRelative(_ date: Date?) -> String {
        guard let date else { return "—" }
        return "\(date.formatted(date: .abbreviated, time: .shortened)) (\(relativeDate(date)))"
    }

    /// Shown when a stopped container was OOM-killed against its own memory
    /// limit — the common "why did it just die?" case (see the kernel log).
    private func oomBanner(process: String?) -> some View {
        let limit = container.configuration.resources?.memoryInBytes ?? 0
        return stopBanner(
            icon: "memorychip",
            title: "Stopped: out of memory",
            message: oomMessage(process: process, limit: limit)
        ) {
            Button("Edit & Recreate…") { state.recreateTarget = container }
                .controlSize(.small)
            Button("View kernel log") {
                NotificationCenter.default.post(name: .davitShowBootLog, object: container.id)
            }
            .controlSize(.small)
        }
    }

    /// Four sentences because the process name and the limit are both optional;
    /// gluing the pieces would leave translators with sentence fragments.
    private func oomMessage(process: String?, limit: Int64) -> Text {
        switch (process, limit > 0) {
        case let (process?, true):
            return Text("“\(process)” exceeded this container's memory limit of \(formatBytes(limit)) and was killed by the kernel. Give it more memory and recreate it.",
                        comment: "Why the container stopped — the first value is the killed process, the second is the memory limit.")
        case let (process?, false):
            return Text("“\(process)” exceeded this container's memory limit and was killed by the kernel. Give it more memory and recreate it.",
                        comment: "Why the container stopped — the value is the killed process.")
        case (nil, true):
            return Text("A process exceeded this container's memory limit of \(formatBytes(limit)) and was killed by the kernel. Give it more memory and recreate it.",
                        comment: "Why the container stopped — the value is the memory limit.")
        case (nil, false):
            return Text("A process exceeded this container's memory limit and was killed by the kernel. Give it more memory and recreate it.")
        }
    }

    /// Shown when an amd64 image failed under Rosetta because Rosetta is too
    /// old for the aux-vector entry the guest passes (see issue #14). Fixed by
    /// updating macOS (Rosetta ships with the OS) or using an arm64 image.
    private func rosettaBanner(vectorType: String?) -> some View {
        stopBanner(
            icon: "cpu",
            title: "Stopped: Rosetta couldn't run this image",
            message: rosettaMessage(vectorType)
        ) {
            Button("Open Software Update") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Software-Update-Settings.extension")!)
            }
            .controlSize(.small)
            Button("View log") {
                NotificationCenter.default.post(name: .davitShowStdioLog, object: container.id)
            }
            .controlSize(.small)
        }
    }

    private func rosettaMessage(_ vectorType: String?) -> Text {
        if let vectorType {
            return Text("This amd64 image needs a newer Rosetta than your macOS provides (auxiliary vector type \(vectorType)). Rosetta ships with macOS, so a software update usually fixes it; otherwise run an arm64 image.",
                        comment: "Why the container stopped — the value is the kernel auxiliary vector type Rosetta did not support.")
        }
        return Text("This amd64 image needs a newer Rosetta than your macOS provides. Rosetta ships with macOS, so a software update usually fixes it; otherwise run an arm64 image.")
    }

    /// Shared orange "here's why it stopped" banner shell.
    private func stopBanner<Actions: View>(
        icon: String, title: LocalizedStringKey, message: Text, @ViewBuilder actions: () -> Actions
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                message
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) { actions() }
                    .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.orange.opacity(0.35)))
    }
}

extension Notification.Name {
    /// Overview banner -> detail view: jump to the Logs tab showing boot logs.
    static let davitShowBootLog = Notification.Name("davitShowBootLog")
    /// Overview banner -> detail view: jump to the Logs tab (process/stdio log).
    static let davitShowStdioLog = Notification.Name("davitShowStdioLog")
}

// MARK: - Logs tab

struct ContainerLogsTab: View {
    let containerID: String
    var machine = false
    @StateObject private var streamer = LogStreamer()
    @State private var follow = true
    @State private var bootLogs: Bool
    @State private var tailCount = 500

    init(containerID: String, machine: Bool = false, initialBoot: Bool = false) {
        self.containerID = containerID
        self.machine = machine
        self._bootLogs = State(initialValue: initialBoot)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Toggle("Follow", isOn: $follow)
                    .toggleStyle(.checkbox)
                Toggle("Boot log", isOn: $bootLogs)
                    .toggleStyle(.checkbox)
                Picker("Tail", selection: $tailCount) {
                    Text(verbatim: "200").tag(200)
                    Text(verbatim: "500").tag(500)
                    Text(verbatim: "2000").tag(2000)
                    Text("All").tag(0)
                }
                .pickerStyle(.menu)
                .fixedSize()
                Spacer()
                if streamer.isRunning {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.mini)
                        Text("streaming", comment: "Live log status: new lines keep arriving.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(streamer.lines.joined(separator: "\n"), forType: .string)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .controlSize(.small)
                Button {
                    restart()
                } label: {
                    Label("Reload", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            Divider()

            if streamer.lines.isEmpty && !streamer.isRunning {
                EmptyState(icon: "text.alignleft", title: "No log output",
                           message: "Nothing in the log yet.")
            } else {
                ConsoleView(lines: streamer.lines, autoScroll: follow)
            }
        }
        .onAppear { restart() }
        .onDisappear { streamer.stop() }
        .onChange(of: bootLogs) { restart() }
        .onChange(of: follow) { restart() }
        .onChange(of: tailCount) { restart() }
    }

    private func restart() {
        streamer.start(source: machine ? .machine(containerID) : .container(containerID),
                       boot: bootLogs, follow: follow, tail: tailCount)
    }
}

// MARK: - Stats tab

struct ContainerStatsTab: View {
    @EnvironmentObject var state: AppState
    let statsID: String
    let isRunning: Bool
    let cpusAllocated: Int
    private let isMachine: Bool
    var scrollable = true

    init(container: ContainerRecord, scrollable: Bool = true) {
        self.statsID = container.id
        self.isRunning = container.isRunning
        self.cpusAllocated = Int(container.configuration.resources?.cpus ?? 0)
        self.isMachine = false
        self.scrollable = scrollable
    }

    /// Machines chart the stats of their backing container.
    init(machine: MachineRecord, backing: String) {
        self.statsID = backing
        self.isRunning = machine.isRunning
        self.cpusAllocated = machine.cpus
        self.isMachine = true
    }

    private var history: [StatsSample] { state.statsHistory[statsID] ?? [] }
    private var latest: StatsSample? { history.last }

    var body: some View {
        if !isRunning {
            EmptyState(icon: "chart.xyaxis.line", title: "Not running",
                       message: isMachine
                        ? "Start the machine to see live resource usage."
                        : "Start the container to see live resource usage.")
        } else if history.count < 2 {
            VStack(spacing: 10) {
                ProgressView()
                Text("Collecting stats…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if scrollable {
            ScrollView { statsContent.thinScrollers() }
        } else {
            statsContent
        }
    }

    private var statsContent: some View {
                VStack(spacing: 14) {
                    HStack(spacing: 14) {
                        StatTile(title: "CPU",
                                 value: (latest?.cpuPercent ?? 0).formatted(.number.precision(.fractionLength(1))) + "%",
                                 subtitle: String(localized: "\(cpusAllocated) CPUs allocated",
                                                  comment: "Stats tile subtitle — the value is the number of CPUs assigned to the container."))
                        StatTile(title: "Memory",
                                 value: formatBytes(latest?.memoryBytes),
                                 subtitle: String(localized: "limit \(formatBytes(latest?.memoryLimit))",
                                                  comment: "Stats tile subtitle — the value is the container's memory limit."))
                        StatTile(title: "Disk",
                                 value: formatBytes(latest?.diskUsageBytes),
                                 subtitle: "↓\(rate(latest?.diskReadRate)) ↑\(rate(latest?.diskWriteRate))")
                        StatTile(title: "Network",
                                 value: "↓ \(formatBytes(latest?.rxBytes))",
                                 subtitle: "↑ \(formatBytes(latest?.txBytes))")
                        StatTile(title: "Processes",
                                 value: "\(latest?.processes ?? 0)",
                                 subtitle: String(localized: "running",
                                                  comment: "Stats tile subtitle: the number above is the count of running processes."))
                    }

                    DetailCard(title: "CPU Usage", icon: "cpu") { cpuChart }
                    DetailCard(title: "Memory Usage", icon: "memorychip") { memoryChart }
                    DetailCard(title: "Disk I/O", icon: "internaldrive") { diskChart }
                }
                .padding(16)
    }

    /// Each chart styles its `ForEach` rather than the marks inside it: applied
    /// per sample, a gradient and stroke style get built for every point in the
    /// history on each 2s stats tick.
    private var cpuChart: some View {
        let valueLabel = LocalizedStringResource("CPU %",
                                                 comment: "Chart value label: CPU usage in percent of one core; % is the unit.")
        return Chart {
            ForEach(history) { sample in
                LineMark(x: .value("Time", sample.time), y: .value(valueLabel, sample.cpuPercent))
            }
            .interpolationMethod(.monotone)

            ForEach(history) { sample in
                AreaMark(x: .value("Time", sample.time), y: .value(valueLabel, sample.cpuPercent))
            }
            .interpolationMethod(.monotone)
            .foregroundStyle(.linearGradient(
                colors: [.accentColor.opacity(0.25), .clear],
                startPoint: .top, endPoint: .bottom))
        }
        .chartYAxisLabel { Text(verbatim: "%") }
        .chartYScale(domain: 0...max(10, (history.map(\.cpuPercent).max() ?? 10) * 1.2))
        .frame(height: 160)
    }

    private var memoryChart: some View {
        Chart {
            ForEach(history) { sample in
                LineMark(x: .value("Time", sample.time),
                         y: .value("MB", Double(sample.memoryBytes) / 1_048_576))
            }
            .interpolationMethod(.monotone)
            .foregroundStyle(.purple)

            ForEach(history) { sample in
                AreaMark(x: .value("Time", sample.time),
                         y: .value("MB", Double(sample.memoryBytes) / 1_048_576))
            }
            .interpolationMethod(.monotone)
            .foregroundStyle(.linearGradient(
                colors: [.purple.opacity(0.25), .clear],
                startPoint: .top, endPoint: .bottom))
        }
        .chartYAxisLabel("MB")
        .frame(height: 160)
    }

    private var diskChart: some View {
        // A chart series identifier, not UI text: the legend uses the values.
        let seriesKey = "dir"
        let readLabel = String(localized: "Read", comment: "Disk I/O chart legend: read throughput.")
        let writeLabel = String(localized: "Write", comment: "Disk I/O chart legend: write throughput.")
        return Chart {
            ForEach(history) { sample in
                LineMark(x: .value("Time", sample.time),
                         y: .value("KB/s", sample.diskReadRate / 1024),
                         series: .value(seriesKey, readLabel))
            }
            .foregroundStyle(.orange)
            .interpolationMethod(.monotone)

            ForEach(history) { sample in
                LineMark(x: .value("Time", sample.time),
                         y: .value("KB/s", sample.diskWriteRate / 1024),
                         series: .value(seriesKey, writeLabel))
            }
            .foregroundStyle(.teal)
            .interpolationMethod(.monotone)
        }
        .chartForegroundStyleScale([readLabel: Color.orange, writeLabel: Color.teal])
        .chartYAxisLabel("KB/s")
        // Explicit floor so an idle container draws flat zero lines instead of
        // an empty-looking plot.
        .chartYScale(domain: 0...max(
            10,
            (history.map { max($0.diskReadRate, $0.diskWriteRate) }.max() ?? 0) / 1024 * 1.2))
        .frame(height: 160)
    }

    /// Compact per-second rate label, e.g. "1.2 MB/s".
    private func rate(_ bytesPerSec: Double?) -> String {
        formatBytes(Int64(bytesPerSec ?? 0)) + "/s"
    }
}

struct StatTile: View {
    let title: LocalizedStringKey
    let value: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(value).font(.system(.title2, design: .rounded).weight(.semibold))
            Text(subtitle).font(.caption).foregroundStyle(.tertiary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Inspect tab (shared with images/networks/volumes)

struct InspectTab: View {
    let kind: String
    let id: String
    @State private var json: String = ""
    @State private var loading = true

    var body: some View {
        Group {
            if loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // GeometryReader pins short JSON top-leading: a two-axis
                // ScrollView otherwise centers content smaller than the
                // viewport (machine inspects are short; containers never
                // showed it because their JSON always fills the screen).
                GeometryReader { geo in
                    ScrollView([.vertical, .horizontal]) {
                        Text(json)
                            .font(.system(size: 11.5, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(12)
                            .frame(minWidth: geo.size.width,
                                   minHeight: geo.size.height,
                                   alignment: .topLeading)
                    }
                }
                .background(Color(nsColor: .textBackgroundColor))
            }
        }
        .task(id: id) {
            loading = true
            json = (try? await ContainerService.inspectRaw(kind, id))
                ?? String(localized: "Failed to inspect \(id)",
                          comment: "Placeholder shown when the inspect JSON could not be read — the value is the resource id.")
            loading = false
        }
        .toolbar {
            ToolbarItem {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(json, forType: .string)
                } label: {
                    Label("Copy JSON", systemImage: "doc.on.doc")
                }
                .disabled(loading)
            }
        }
    }
}

