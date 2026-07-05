import Foundation
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    // Data
    @Published var containers: [ContainerRecord] = []
    @Published var images: [ImageRecord] = []
    @Published var volumes: [VolumeRecord] = []
    @Published var networks: [NetworkRecord] = []
    @Published var diskUsage: DiskUsage?
    @Published var systemState: SystemState = .unknown
    @Published var cliMissing = false
    @Published var availableUpdate: UpdateInfo?
    @Published var resolvedBinary: ResolvedBinary?

    // Live stats: history per container id
    @Published var statsHistory: [String: [StatsSample]] = [:]
    private var lastRawStats: [String: (cpuUsec: Int64, rx: Int64, tx: Int64, at: Date)] = [:]

    // UI state
    @Published var busyIDs: Set<String> = []
    @Published var recreateTarget: ContainerRecord?
    @Published var lastError: CLIError?
    @Published var isRefreshing = false
    @Published var initialLoadDone = false

    @AppStorage("refreshInterval") var refreshInterval: Double = 4.0

    private var pollTask: Task<Void, Never>?
    private var statsTask: Task<Void, Never>?

    var runningContainers: [ContainerRecord] { containers.filter(\.isRunning) }

    // MARK: Lifecycle

    func checkForUpdates(force: Bool = false) {
        let defaults = UserDefaults.standard
        let last = defaults.object(forKey: UpdateChecker.lastCheckKey) as? Date ?? .distantPast
        guard force || Date().timeIntervalSince(last) > 86_400 else { return }
        defaults.set(Date(), forKey: UpdateChecker.lastCheckKey)
        Task {
            guard let update = try? await UpdateChecker.fetchAvailableUpdate() else { return }
            if !force, defaults.string(forKey: UpdateChecker.skippedVersionKey) == update.version { return }
            availableUpdate = update
        }
    }

    func startPolling() {
        checkForUpdates()
        pollTask?.cancel()
        statsTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshAll()
                let interval = self?.refreshInterval ?? 4.0
                try? await Task.sleep(for: .seconds(interval))
            }
        }
        statsTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshStats()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        statsTask?.cancel()
    }

    // MARK: Refresh

    func refreshAll() async {
        resolvedBinary = ContainerBinary.resolve()
        guard resolvedBinary != nil else {
            cliMissing = true
            initialLoadDone = true
            return
        }
        cliMissing = false
        isRefreshing = true
        defer {
            isRefreshing = false
            initialLoadDone = true
        }

        async let sys = try? ContainerService.systemState()
        systemState = await sys ?? .unknown

        guard systemState.isRunning else {
            containers = []
            statsHistory = [:]
            return
        }

        async let c = try? ContainerService.listContainers()
        async let i = try? ContainerService.listImages()
        async let v = try? ContainerService.listVolumes()
        async let n = try? ContainerService.listNetworks()
        async let d = try? ContainerService.diskUsage()

        let (cs, imgs, vols, nets, df) = await (c, i, v, n, d)
        if let cs { containers = cs.sorted { sortKey($0) < sortKey($1) } }
        if let imgs { images = imgs.sorted { $0.shortNameTag < $1.shortNameTag } }
        if let vols { volumes = vols.sorted { $0.name < $1.name } }
        if let nets { networks = nets.sorted { $0.name < $1.name } }
        if let df { diskUsage = df }
    }

    private func sortKey(_ c: ContainerRecord) -> String {
        (c.isRunning ? "0" : "1") + c.id.lowercased()
    }

    func refreshStats() async {
        guard systemState.isRunning, !runningContainers.isEmpty else { return }
        guard let raw = try? await ContainerService.stats(for: runningContainers.map(\.id)) else { return }
        let now = Date()
        for record in raw {
            let cpuUsec = record.cpuUsageUsec ?? 0
            let rx = record.networkRxBytes ?? 0
            let tx = record.networkTxBytes ?? 0
            var cpuPercent = 0.0
            if let prev = lastRawStats[record.id] {
                let dt = now.timeIntervalSince(prev.at)
                if dt > 0.1 {
                    let deltaUsec = Double(max(0, cpuUsec - prev.cpuUsec))
                    cpuPercent = deltaUsec / (dt * 1_000_000) * 100.0
                }
            }
            lastRawStats[record.id] = (cpuUsec, rx, tx, now)
            let sample = StatsSample(
                time: now,
                cpuPercent: cpuPercent,
                memoryBytes: record.memoryUsageBytes ?? 0,
                memoryLimit: record.memoryLimitBytes ?? 0,
                rxBytes: rx,
                txBytes: tx,
                processes: record.numProcesses ?? 0
            )
            var history = statsHistory[record.id, default: []]
            history.append(sample)
            if history.count > 150 { history.removeFirst(history.count - 150) }
            statsHistory[record.id] = history
        }
        // Drop history for containers that no longer report stats
        let live = Set(raw.map(\.id))
        for key in statsHistory.keys where !live.contains(key) {
            statsHistory[key] = nil
            lastRawStats[key] = nil
        }
    }

    func latestSample(for id: String) -> StatsSample? {
        statsHistory[id]?.last
    }

    // MARK: Actions

    /// Runs an action with per-entity busy tracking and error surfacing, then refreshes.
    func perform(_ id: String, _ action: @escaping () async throws -> Void) {
        busyIDs.insert(id)
        Task {
            do {
                try await action()
            } catch let e as CLIError {
                lastError = e
            } catch {
                lastError = CLIError(command: "", message: error.localizedDescription, exitCode: -1)
            }
            busyIDs.remove(id)
            await refreshAll()
        }
    }

    func startContainer(_ c: ContainerRecord) { perform(c.id) { try await ContainerService.start(c.id) } }
    func stopContainer(_ c: ContainerRecord) { perform(c.id) { try await ContainerService.stop(c.id) } }
    func killContainer(_ c: ContainerRecord) { perform(c.id) { try await ContainerService.kill(c.id) } }
    func restartContainer(_ c: ContainerRecord) { perform(c.id) { try await ContainerService.restart(c.id) } }
    func deleteContainer(_ c: ContainerRecord) {
        perform(c.id) { try await ContainerService.delete(c.id, force: c.isRunning) }
    }

    func toggleSystem() {
        perform("system") {
            if self.systemState.isRunning {
                try await ContainerService.systemStop()
            } else {
                try await ContainerService.systemStart()
            }
        }
    }
}
