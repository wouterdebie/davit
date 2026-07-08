import Foundation
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    // Data
    @Published var containers: [ContainerRecord] = []
    @Published var images: [ImageRecord] = []
    @Published var volumes: [VolumeRecord] = []
    @Published var networks: [NetworkRecord] = []
    @Published var machines: [MachineRecord] = []
    @Published var diskUsage: DiskUsage?
    @Published var systemState: SystemState = .unknown
    @Published var cliMissing = false
    @Published var availableUpdate: UpdateInfo?
    @Published var resolvedBinary: ResolvedBinary?

    // Live stats: history per container id
    @Published var statsHistory: [String: [StatsSample]] = [:]
    private var lastRawStats: [String: (cpuUsec: Int64, blockRead: Int64, blockWrite: Int64, at: Date)] = [:]
    // Per-container disk space, refreshed on a slower cadence than the 2s poll.
    private var diskUsageCache: [String: Int64] = [:]
    private var diskUsageTick = 0

    // UI state
    @Published var busyIDs: Set<String> = []
    @Published var recreateTarget: ContainerRecord?
    /// Cross-view intent: a container to reveal in the Containers detail view
    /// (e.g. clicked from the Dashboard). Consumed by ContainersView.
    @Published var pendingContainerOpen: String?
    @Published var lastError: CLIError?
    @Published var isRefreshing = false
    @Published var initialLoadDone = false

    @AppStorage("refreshInterval") var refreshInterval: Double = 4.0

    /// Containers to start when Davit launches (app feature; the platform has
    /// no restart policies). With "Open Davit at login" this gives
    /// containers-at-login.
    @Published var autoStartContainers: Set<String> =
        Set(UserDefaults.standard.stringArray(forKey: AppState.autoStartKey) ?? [])
    static let autoStartKey = "autoStartContainers"
    private var autoStartDone = false

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
                await self?.performAutoStartIfNeeded()
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

    // MARK: Auto-start

    func isAutoStart(_ id: String) -> Bool { autoStartContainers.contains(id) }

    func toggleAutoStart(_ id: String) {
        if autoStartContainers.contains(id) {
            autoStartContainers.remove(id)
        } else {
            autoStartContainers.insert(id)
        }
        UserDefaults.standard.set(Array(autoStartContainers).sorted(), forKey: Self.autoStartKey)
    }

    /// Once per app launch, after the first refresh: bring the services up if
    /// needed and start every marked container that isn't running. Stale IDs
    /// (containers since deleted) are pruned from the set.
    private func performAutoStartIfNeeded() async {
        guard !autoStartDone else { return }
        autoStartDone = true
        guard !autoStartContainers.isEmpty else { return }

        if !systemState.isRunning {
            try? await ContainerService.systemStart()
            await refreshAll()
            guard systemState.isRunning else { return }
        }

        let existing = Set(containers.map(\.id))
        let stale = autoStartContainers.subtracting(existing)
        if !stale.isEmpty {
            autoStartContainers.subtract(stale)
            UserDefaults.standard.set(Array(autoStartContainers).sorted(), forKey: Self.autoStartKey)
        }

        let toStart = containers.filter { autoStartContainers.contains($0.id) && !$0.isRunning }
        guard !toStart.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            for container in toStart {
                group.addTask { try? await ContainerService.start(container.id) }
            }
        }
        await refreshAll()
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
        async let m = try? MachineService.list()

        let (cs, imgs, vols, nets, df) = await (c, i, v, n, d)
        machines = (await m) ?? []
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
        let ids = runningContainers.map(\.id)
        guard let raw = try? await ContainerService.stats(for: ids) else { return }
        let now = Date()

        // Disk space changes slowly and is costlier to compute, so refresh it
        // every ~10s (every 5th 2s tick) and carry the value forward otherwise.
        diskUsageTick += 1
        if diskUsageTick % 5 == 1 {
            let usage = await ContainerService.containerDiskUsage(for: ids)
            for (id, bytes) in usage { diskUsageCache[id] = bytes }
        }

        for record in raw {
            let cpuUsec = record.cpuUsageUsec ?? 0
            let blockRead = record.blockReadBytes ?? 0
            let blockWrite = record.blockWriteBytes ?? 0
            var cpuPercent = 0.0
            var diskReadRate = 0.0
            var diskWriteRate = 0.0
            if let prev = lastRawStats[record.id] {
                let dt = now.timeIntervalSince(prev.at)
                if dt > 0.1 {
                    cpuPercent = Double(max(0, cpuUsec - prev.cpuUsec)) / (dt * 1_000_000) * 100.0
                    diskReadRate = Double(max(0, blockRead - prev.blockRead)) / dt
                    diskWriteRate = Double(max(0, blockWrite - prev.blockWrite)) / dt
                }
            }
            lastRawStats[record.id] = (cpuUsec, blockRead, blockWrite, now)
            let sample = StatsSample(
                time: now,
                cpuPercent: cpuPercent,
                memoryBytes: record.memoryUsageBytes ?? 0,
                memoryLimit: record.memoryLimitBytes ?? 0,
                rxBytes: record.networkRxBytes ?? 0,
                txBytes: record.networkTxBytes ?? 0,
                diskReadRate: diskReadRate,
                diskWriteRate: diskWriteRate,
                diskUsageBytes: diskUsageCache[record.id] ?? 0,
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
            diskUsageCache[key] = nil
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
