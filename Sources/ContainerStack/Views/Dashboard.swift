import SwiftUI
import Charts

enum AggregateMetric: String, CaseIterable, Identifiable {
    case cpu = "CPU"
    case memory = "Memory"
    case diskIO = "Disk I/O"
    var id: String { rawValue }

    /// The segmented control's label; `rawValue` is the chart series title.
    var title: LocalizedStringResource {
        switch self {
        case .cpu: "CPU"
        case .memory: "Memory"
        case .diskIO: "Disk I/O"
        }
    }

    var axisLabel: String {
        switch self {
        case .cpu: return "%"
        case .memory: return "MB"
        case .diskIO: return "KB/s"
        }
    }
    func value(_ s: StatsSample) -> Double {
        switch self {
        case .cpu: return s.cpuPercent
        case .memory: return Double(s.memoryBytes) / 1_048_576
        case .diskIO: return (s.diskReadRate + s.diskWriteRate) / 1024
        }
    }
}

struct DashboardView: View {
    @EnvironmentObject var state: AppState
    var scrollable = true
    @State private var aggMetric: AggregateMetric = .cpu
    /// Shared with the Containers view — groups the running list by a label.
    @AppStorage("containerGroupBy") private var groupBy = ""

    var body: some View {
        Group {
            if scrollable {
                ScrollView { content.thinScrollers() }
            } else {
                content
            }
        }
        .navigationTitle("Dashboard")
        .refreshIndicator(state.isRefreshing)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            if state.systemState.isRunning && state.kernelMissing {
                KernelMissingBanner()
            }
            systemCard

            if state.systemState.isRunning {
                HStack(alignment: .top, spacing: 16) {
                    countsCard
                    diskCard
                }

                if !state.runningContainers.isEmpty {
                    runningCard
                    aggregateChart
                }
            }
        }
        .padding(18)
        .frame(maxWidth: 900, alignment: .leading)
        .frame(maxWidth: .infinity)
    }

    // MARK: System status

    private var systemCard: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(state.systemState.isRunning ? Color.green.opacity(0.15) : Color.secondary.opacity(0.1))
                    .frame(width: 52, height: 52)
                Image(systemName: state.systemState.isRunning ? "checkmark.circle.fill" : "pause.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(state.systemState.isRunning ? .green : .secondary)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(state.systemState.isRunning ? "Container services running" : "Container services stopped")
                    .font(.headline)
                if case .running(let version) = state.systemState, let version {
                    Text(version).font(.caption).foregroundStyle(.secondary)
                } else if !state.systemState.isRunning {
                    Text("Start services to manage containers").font(.caption).foregroundStyle(.secondary)
                }
                if let binary = state.resolvedBinary {
                    Text(verbatim: "\(binary.path) (\(binary.label))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Button {
                state.toggleSystem()
            } label: {
                if state.busyIDs.contains("system") {
                    ProgressView().controlSize(.small).frame(width: 60)
                } else {
                    Text(state.systemState.isRunning ? "Stop" : "Start",
                         comment: "Button that stops or starts the container platform services.")
                        .frame(width: 60)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(state.systemState.isRunning ? .red.opacity(0.85) : .green)
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: Resource counts

    private var countsCard: some View {
        DetailCard(title: "Resources", icon: "square.grid.2x2") {
            VStack(spacing: 10) {
                CountRow(icon: "shippingbox.fill", tint: .green, label: "Containers",
                         value: Text("\(state.runningContainers.count) running · \(state.containers.count) total",
                                     comment: "Resource summary — the first number is running containers, the second is the total."))
                CountRow(icon: "square.stack.3d.down.forward.fill", tint: .blue, label: "Images",
                         value: Text(verbatim: "\(state.images.count) (\(formatBytes(state.images.map(\.totalSize).reduce(0, +))))"))
                CountRow(icon: "externaldrive.fill", tint: .purple, label: "Volumes",
                         value: Text(verbatim: "\(state.volumes.count)"))
                CountRow(icon: "network", tint: .teal, label: "Networks",
                         value: Text(verbatim: "\(state.networks.count)"))
            }
        }
    }

    // MARK: Disk usage

    private var diskCard: some View {
        DetailCard(title: "Disk Usage", icon: "internaldrive") {
            if let df = state.diskUsage {
                DiskUsageContent(df: df)
            } else {
                Text(verbatim: "—").foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Running containers

    private var runningCard: some View {
        DetailCard(title: "Running Containers", icon: "play.circle") {
            VStack(alignment: .leading, spacing: 2) {
                let key = ContainerGrouping.availableKeys(state.runningContainers).contains(groupBy) ? groupBy : ""
                if key.isEmpty {
                    ForEach(state.runningContainers) { c in
                        DashboardContainerRow(container: c)
                    }
                } else {
                    ForEach(ContainerGrouping.groups(state.runningContainers, by: key), id: \.title) { group in
                        // Glance view: group actions, but no collapse/focus.
                        GroupHeader(title: group.title, count: group.containers.count,
                                    containers: group.containers, showActions: true)
                        ForEach(group.containers) { c in
                            DashboardContainerRow(container: c)
                        }
                    }
                }
            }
        }
    }

    // MARK: Aggregate CPU chart

    private var aggregateChart: some View {
        DetailCard(title: "All Running Containers", icon: "chart.xyaxis.line") {
            HStack {
                Spacer()
                Picker(selection: $aggMetric) {
                    ForEach(AggregateMetric.allCases) { Text($0.title).tag($0) }
                } label: {
                    EmptyView()
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 320)
                Spacer()
            }
            .padding(.bottom, 4)

            let series: [(id: String, samples: [StatsSample])] = state.runningContainers.compactMap { c in
                guard let h = state.statsHistory[c.id], h.count > 1 else { return nil }
                return (c.id, h.decimated(to: Self.pointsPerSeries))
            }
            if series.isEmpty {
                Text("Collecting stats…").font(.callout).foregroundStyle(.secondary)
            } else {
                let ids = series.map(\.id)
                let colors = ids.indices.map { Self.seriesPalette[$0 % Self.seriesPalette.count] }
                Chart {
                    ForEach(Array(series.enumerated()), id: \.element.id) { idx, entry in
                        marks(for: entry, color: Self.seriesPalette[idx % Self.seriesPalette.count])
                    }
                }
                .chartForegroundStyleScale(domain: ids, range: colors)
                .chartYAxisLabel(aggMetric.axisLabel)
                .frame(height: 180)
            }
        }
    }

    /// One container's line and its gradient fill.
    ///
    /// The styling hangs off each `ForEach` rather than off the marks inside
    /// it: applied per sample, every point allocates its own gradient and
    /// stroke style, and with a handful of containers that dominated the
    /// dashboard's layout cost.
    @ChartContentBuilder
    private func marks(for entry: (id: String, samples: [StatsSample]), color: Color) -> some ChartContent {
        // Gradient fill under each container's line, matching the
        // per-container Stats charts' look.
        ForEach(entry.samples) { s in
            AreaMark(
                x: .value("Time", s.time),
                y: .value(aggMetric.rawValue, aggMetric.value(s)),
                series: .value("Container", entry.id),
                // Each container's fill goes 0 -> its own value so the line
                // tops its area; without this AreaMarks stack (fill sits above
                // the line) while LineMarks don't, which mismatches them.
                stacking: .unstacked
            )
        }
        .interpolationMethod(.monotone)
        .foregroundStyle(.linearGradient(
            colors: [color.opacity(0.28), color.opacity(0.02)],
            startPoint: .top, endPoint: .bottom))

        ForEach(entry.samples) { s in
            LineMark(
                x: .value("Time", s.time),
                y: .value(aggMetric.rawValue, aggMetric.value(s)),
                series: .value("Container", entry.id)
            )
        }
        .foregroundStyle(by: .value("Container", entry.id))
        .interpolationMethod(.monotone)
        .lineStyle(StrokeStyle(lineWidth: 2))
    }

    /// Distinct per-container series colors; index 0 (blue) matches the CPU accent
    /// so a single-container chart reads like the per-container Stats chart.
    static let seriesPalette: [Color] = [.blue, .purple, .green, .orange, .pink, .teal, .indigo, .red]

    /// Points drawn per container. The card is 180pt tall and under 900pt wide,
    /// so the full 150-sample history is finer than the plot can show — and it
    /// is drawn once per running container on every 2s stats tick.
    static let pointsPerSeries = 60
}

/// Split out of DashboardView.diskCard: the combined expression exceeded the
/// type-checker budget on older Swift compilers (CI).
struct DiskUsageContent: View {
    @EnvironmentObject var state: AppState
    let df: DiskUsage

    private var maxSize: Int64 {
        let sizes: [Int64] = [
            df.images?.sizeInBytes ?? 0,
            df.containers?.sizeInBytes ?? 0,
            df.volumes?.sizeInBytes ?? 0,
            1,
        ]
        return sizes.max() ?? 1
    }

    private var reclaimable: Int64 {
        (df.images?.reclaimable ?? 0) + (df.containers?.reclaimable ?? 0) + (df.volumes?.reclaimable ?? 0)
    }

    var body: some View {
        VStack(spacing: 10) {
            DiskRow(label: "Images", section: df.images, tint: .blue, maxSize: maxSize)
            DiskRow(label: "Containers", section: df.containers, tint: .green, maxSize: maxSize)
            DiskRow(label: "Volumes", section: df.volumes, tint: .purple, maxSize: maxSize)
            if reclaimable > 0 {
                Divider()
                cleanupRow
            }
        }
    }

    private var cleanupRow: some View {
        HStack {
            Text("\(formatBytes(reclaimable)) reclaimable",
                 comment: "Disk cleanup row — the value is the amount of disk space that pruning can free.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Menu("Clean Up…") {
                Button("Prune Stopped Containers") {
                    state.perform("prune") { try await ContainerService.pruneContainers() }
                }
                Button("Prune Unused Images") {
                    state.perform("prune") { try await ContainerService.pruneImages(all: true) }
                }
                Button("Prune Unused Volumes") {
                    state.perform("prune") { try await ContainerService.pruneVolumes() }
                }
            }
            .fixedSize()
        }
    }
}

/// Shown when services run but no default guest kernel is configured, so
/// containers can't start (issue #16 — usually a daemon started outside Davit).
/// One click downloads + installs the recommended kernel.
struct KernelMissingBanner: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "cpu")
                .font(.system(size: 26))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text("No guest kernel configured")
                    .font(.headline)
                Text("The VM that runs your containers needs a Linux kernel, and none is set for this Mac. Containers won't start until one is installed.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if state.configuringKernel {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Installing…").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Button("Configure Kernel") { state.configureKernel() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.orange.opacity(0.30)))
    }
}


/// A running-container row on the Dashboard. Clicking the row reveals the
/// container's detail (via AppState.pendingContainerOpen); the trailing
/// terminal/stop buttons keep their own actions.
struct DashboardContainerRow: View {
    @EnvironmentObject var state: AppState
    let container: ContainerRecord
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            StatusDot(color: .green, pulsing: true)
            VStack(alignment: .leading, spacing: 1) {
                Text(container.id).font(.callout.weight(.medium))
                Text(container.shortImage).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let s = state.latestSample(for: container.id) {
                Text("\(s.cpuPercent.formatted(.number.precision(.fractionLength(0))))% CPU · \(formatBytes(s.memoryBytes)) · \(formatBytes(s.diskUsageBytes)) disk",
                     comment: "Live row summary — the first value is CPU usage, then memory, then disk usage.")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Button {
                TerminalLauncher.openShell(containerID: container.id)
            } label: {
                Image(systemName: "terminal")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(Text("Open Terminal", comment: "Tooltip for the button that opens a shell in the container."))
            Button {
                state.stopContainer(container)
            } label: {
                Image(systemName: "stop.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(Text("Stop", comment: "Tooltip for the button that stops this container."))
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .background(
            hovering ? AnyShapeStyle(.primary.opacity(0.055)) : AnyShapeStyle(.clear),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .onHover { hovering = $0 }
        .onTapGesture { state.pendingContainerOpen = container.id }
        .help(Text("Open \(container.id)", comment: "Tooltip for a container row — the value is the container name."))
    }
}

struct CountRow: View {
    let icon: String
    let tint: Color
    let label: LocalizedStringKey
    let value: Text

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .frame(width: 22)
            Text(label).font(.callout)
            Spacer()
            value.font(.callout).foregroundStyle(.secondary)
        }
    }
}

struct DiskRow: View {
    let label: LocalizedStringKey
    let section: DiskUsage.Section?
    let tint: Color
    let maxSize: Int64

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label).font(.callout)
                Spacer()
                Text(formatBytes(section?.sizeInBytes))
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                let total = Double(section?.sizeInBytes ?? 0)
                let reclaimable = Double(section?.reclaimable ?? 0)
                // bar length ∝ size vs the largest section; solid = in-use, faded = reclaimable
                let barFraction = total / Double(maxSize)
                let usedFraction = total > 0 ? max(0, (total - reclaimable) / total) * barFraction : 0
                ZStack(alignment: .leading) {
                    Capsule().fill(tint.opacity(0.12))
                    Capsule().fill(tint.opacity(0.4))
                        .frame(width: max(4, geo.size.width * barFraction))
                    Capsule().fill(tint)
                        .frame(width: max(2, geo.size.width * usedFraction))
                }
            }
            .frame(height: 5)
        }
    }
}
