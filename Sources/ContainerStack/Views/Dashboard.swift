import SwiftUI
import Charts

struct DashboardView: View {
    @EnvironmentObject var state: AppState
    var scrollable = true

    var body: some View {
        Group {
            if scrollable {
                ScrollView { content }
            } else {
                content
            }
        }
        .navigationTitle("Dashboard")
        .refreshIndicator(state.isRefreshing)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let update = state.availableUpdate {
                UpdateBanner(update: update)
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
                    Text("\(binary.path) (\(binary.source.rawValue))")
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
                    Text(state.systemState.isRunning ? "Stop" : "Start").frame(width: 60)
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
                         value: "\(state.runningContainers.count) running · \(state.containers.count) total")
                CountRow(icon: "square.stack.3d.down.forward.fill", tint: .blue, label: "Images",
                         value: "\(state.images.count) (\(formatBytes(state.images.map(\.totalSize).reduce(0, +))))")
                CountRow(icon: "externaldrive.fill", tint: .purple, label: "Volumes",
                         value: "\(state.volumes.count)")
                CountRow(icon: "network", tint: .teal, label: "Networks",
                         value: "\(state.networks.count)")
            }
        }
    }

    // MARK: Disk usage

    private var diskCard: some View {
        DetailCard(title: "Disk Usage", icon: "internaldrive") {
            if let df = state.diskUsage {
                DiskUsageContent(df: df)
            } else {
                Text("—").foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Running containers

    private var runningCard: some View {
        DetailCard(title: "Running Containers", icon: "play.circle") {
            VStack(spacing: 4) {
                ForEach(state.runningContainers) { c in
                    HStack(spacing: 10) {
                        StatusDot(color: .green, pulsing: true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(c.id).font(.callout.weight(.medium))
                            Text(c.shortImage).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let s = state.latestSample(for: c.id) {
                            Text(String(format: "%.0f%% CPU · %@", s.cpuPercent, formatBytes(s.memoryBytes)))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        Button {
                            TerminalLauncher.openShell(containerID: c.id)
                        } label: {
                            Image(systemName: "terminal")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Open Terminal")
                        Button {
                            state.stopContainer(c)
                        } label: {
                            Image(systemName: "stop.fill")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Stop")
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    // MARK: Aggregate CPU chart

    private var aggregateChart: some View {
        DetailCard(title: "CPU — All Running Containers", icon: "chart.xyaxis.line") {
            let series: [(id: String, samples: [StatsSample])] = state.runningContainers.compactMap { c in
                guard let h = state.statsHistory[c.id], h.count > 1 else { return nil }
                return (c.id, h)
            }
            if series.isEmpty {
                Text("Collecting stats…").font(.callout).foregroundStyle(.secondary)
            } else {
                Chart {
                    ForEach(series, id: \.id) { entry in
                        ForEach(entry.samples) { s in
                            LineMark(
                                x: .value("Time", s.time),
                                y: .value("CPU %", s.cpuPercent),
                                series: .value("Container", entry.id)
                            )
                            .foregroundStyle(by: .value("Container", entry.id))
                            .interpolationMethod(.monotone)
                        }
                    }
                }
                .chartYAxisLabel("%")
                .frame(height: 180)
            }
        }
    }
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
            Text("\(formatBytes(reclaimable)) reclaimable")
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

/// "Update available" banner with in-place download/install progress.
struct UpdateBanner: View {
    @EnvironmentObject var state: AppState
    @StateObject private var installer = UpdateInstaller()
    let update: UpdateInfo

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 26))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text("Davit \(update.version) is available")
                    .font(.headline)
                if let stage = installer.stage {
                    Text(stage).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                } else if let error = installer.errorText {
                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                } else {
                    Text("You're running \(UpdateChecker.currentVersion). The update installs and relaunches in place.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let fraction = installer.fraction, installer.installing {
                    ProgressView(value: fraction).frame(maxWidth: 320)
                }
            }
            Spacer()
            if !installer.installing {
                Button("Release Notes") { NSWorkspace.shared.open(update.releasePageURL) }
                Button("Skip") {
                    UserDefaults.standard.set(update.version, forKey: UpdateChecker.skippedVersionKey)
                    state.availableUpdate = nil
                }
                Button("Install & Relaunch") { installer.install(update) }
                    .buttonStyle(.borderedProminent)
            } else if installer.fraction == nil {
                ProgressView().controlSize(.small)
            }
        }
        .padding(16)
        .background(.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.tint.opacity(0.25)))
    }
}

struct CountRow: View {
    let icon: String
    let tint: Color
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .frame(width: 22)
            Text(label).font(.callout)
            Spacer()
            Text(value).font(.callout).foregroundStyle(.secondary)
        }
    }
}

struct DiskRow: View {
    let label: String
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
