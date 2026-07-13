import AppKit
import ArgumentParser
import ContainerAPIClient
import ContainerizationError
import ContainerizationOCI
import ContainerPersistence
import ContainerPlugin
import ContainerResource
import ContainerizationExtras
import Foundation
import Logging
import MachineAPIClient
import SystemPackage
import TerminalProgress

// MARK: - Platform install resolution (replaces CLI binary resolution)

/// Locates the container *platform* (container-apiserver + plugins). The app talks
/// to the daemon over XPC via ContainerAPIClient; these binaries are only needed to
/// bootstrap the launchd services. Resolution order:
///   1. User-configured install root (Settings)
///   2. System install (/usr/local — the official pkg)
///   3. A copy vendored inside the app bundle (Contents/Resources/vendor)
enum ContainerBinary {
    static let defaultsKey = "containerInstallRoot"

    static func resolve() -> ResolvedBinary? {
        let custom = UserDefaults.standard.string(forKey: defaultsKey) ?? ""
        var candidates: [(String, ResolvedBinary.Source)] = []
        if !custom.isEmpty { candidates.append((custom, .userConfigured)) }
        candidates.append((PlatformInstaller.managedRoot, .managed))
        candidates.append(("/usr/local", .system))
        // Homebrew keg (`brew install container`) — issue #2.
        candidates.append(("/opt/homebrew/opt/container", .homebrew))
        candidates.append(("/usr/local/opt/container", .homebrew))  // Intel brew prefix
        if let res = Bundle.main.resourceURL {
            candidates.append((res.appendingPathComponent("vendor").path, .bundled))
        }
        for (root, source) in candidates {
            let apiserver = "\(root)/bin/container-apiserver"
            if FileManager.default.isExecutableFile(atPath: apiserver) {
                return ResolvedBinary(installRoot: root, apiserverPath: apiserver, source: source)
            }
        }
        return nil
    }

    /// Must run before any ContainerAPIClient/ContainerPlugin API is touched:
    /// InstallRoot.defaultPath is computed relative to the executable, which is wrong
    /// inside an app bundle. Pin it (and let user config in app root win) via env.
    /// Also the one place swift-log gets bootstrapped (see bootstrapLogging below) —
    /// Main.main() calls this before dispatching to any subcommand or the app.
    static func bootstrapEnvironment() {
        bootstrapLogging()
        guard ProcessInfo.processInfo.environment[InstallRoot.environmentName] == nil,
              let resolved = resolve() else { return }
        setenv(InstallRoot.environmentName, resolved.installRoot, 1)
    }

    /// `LoggingSystem.bootstrap` may run exactly once per process (a second call
    /// traps), so it happens here, unconditionally, before anything can create a
    /// `Logger`. `Backend.log` (below) is a `static let`, lazily initialized on
    /// first access like all Swift globals — since this function runs first in
    /// Main.main() and nothing above it touches `Backend.log`, that first access
    /// always happens after the bootstrap and picks up LoggingConfig.level.
    private static func bootstrapLogging() {
        let raw = ProcessInfo.processInfo.environment["DAVIT_LOG_LEVEL"]
        let (level, ok) = LoggingConfig.parseLevel(raw)
        if !ok {
            FileHandle.standardError.write(Data("DAVIT_LOG_LEVEL: unrecognized level \"\(raw ?? "")\" — using info\n".utf8))
        }
        LoggingConfig.level = level
        // A rejected value falls back to fully-default behavior (as if unset)
        // so --verbose can still bump the level to .debug — only a value that
        // actually parsed counts as the user explicitly choosing a level.
        LoggingConfig.explicitlySet = ok && raw?.isEmpty == false
        LoggingSystem.bootstrap { label in
            var handler = StreamLogHandler.standardError(label: label)
            handler.logLevel = LoggingConfig.level
            return handler
        }
    }
}

/// DAVIT_LOG_LEVEL parsing + the mutable level `bootstrapLogging`'s handler
/// factory reads from. `--verbose` (ComposeCLI) bumps `level` to `.debug` before
/// `Backend.log` is ever created, unless the env var was explicit — factored out
/// of ContainerBinary so it stays pure and selftest-able without re-bootstrapping
/// swift-log (which would trap the process).
enum LoggingConfig {
    nonisolated(unsafe) static var level: Logger.Level = .info
    nonisolated(unsafe) static var explicitlySet = false

    /// nil/empty (unset) → `.info`, no warning; unrecognized → `.info` + `ok: false`
    /// so the caller can warn once. Case-insensitive over swift-log's level names.
    static func parseLevel(_ raw: String?) -> (level: Logger.Level, ok: Bool) {
        guard let raw, !raw.isEmpty else { return (.info, true) }
        switch raw.lowercased() {
        case "trace": return (.trace, true)
        case "debug": return (.debug, true)
        case "info": return (.info, true)
        case "notice": return (.notice, true)
        case "warning": return (.warning, true)
        case "error": return (.error, true)
        case "critical": return (.critical, true)
        default: return (.info, false)
        }
    }
}

struct ResolvedBinary: Equatable {
    enum Source: String {
        case userConfigured = "custom path"
        case managed = "installed by Davit"
        case system = "system install"
        case homebrew = "Homebrew"
        case bundled = "bundled"
    }
    let installRoot: String
    let apiserverPath: String
    let source: Source
    var path: String { apiserverPath }
}

// MARK: - Errors

struct CLIError: LocalizedError, Identifiable {
    let id = UUID()
    let command: String
    let message: String
    let exitCode: Int32

    init(command: String, message: String, exitCode: Int32 = -1) {
        self.command = command
        self.message = message
        self.exitCode = exitCode
    }

    var errorDescription: String? { message }

    static func wrap(_ operation: String, _ error: Error) -> CLIError {
        CLIError(command: operation, message: "\(operation): \(String(describing: error))")
    }
}

// MARK: - Shared config / logging

enum Backend {
    static let log = Logger(label: "dev.wouter.davit")

    static func systemConfig() async throws -> ContainerSystemConfig {
        try await ConfigurationLoader.load(
            configurationFiles: [
                ConfigurationLoader.configurationFile(in: ApplicationRoot.path, of: .appRoot),
                ConfigurationLoader.configurationFile(in: InstallRoot.path, of: .installRoot),
            ])
    }

    static func prettyJSON<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

// MARK: - Typed service API (same facade as before, now XPC-backed)

/// Stops Davit itself initiated (stop/kill/delete/restart buttons, compose
/// down, recreate). Used to tell an expected running->stopped transition from
/// an unexpected one (crash, OOM, external kill) for notifications.
final class ExpectedStops: @unchecked Sendable {
    static let shared = ExpectedStops()
    private let lock = NSLock()
    private var stamps: [String: Date] = [:]

    func mark(_ id: String) {
        lock.lock(); stamps[id] = Date(); lock.unlock()
    }

    /// True (and consumes the mark) when the stop was requested in the last
    /// couple of minutes — long enough for a slow graceful stop to complete.
    func consume(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let at = stamps.removeValue(forKey: id) else { return false }
        return Date().timeIntervalSince(at) < 120
    }
}

enum ContainerService {
    // MARK: Listing

    static func listContainers() async throws -> [ContainerRecord] {
        let snapshots = try await ContainerClient().list()
        return snapshots
            .map(ContainerRecord.init(snapshot:))
            // Machine backing containers are infrastructure; they live in the
            // Machines section (the CLI hides them from `container list` too).
            .filter { $0.configuration.labels?["com.apple.container.plugin"] != "machine" }
            // Volume-browser helpers are infrastructure too (see VolumeBrowser).
            .filter { $0.configuration.labels?["com.davit.volume-browser"] == nil }
    }

    static func listImages() async throws -> [ImageRecord] {
        let images = try await ClientImage.list()
        var records: [ImageRecord] = []
        for image in images {
            // Hide infrastructure images (vminit, builder) like the CLI does.
            if isInfraImage(image.reference) { continue }
            records.append(await ImageRecord(client: image))
        }
        return records
    }

    static func isInfraImage(_ reference: String) -> Bool {
        reference.contains("/containerization/vminit") || reference.contains("/container-builder-shim/")
    }

    /// Whether `reference` already resolves to a locally present image AT the
    /// requested platform variant — the same two-step check `ClientImage.fetch`
    /// does internally (reference lookup, then `match.config(for:)` to confirm
    /// the specific platform's config is present) before falling back to a
    /// pull. Used by `davit run --pull never` to fail fast instead of silently
    /// degrading to `missing`'s pull-if-absent behavior. `managementArgs` are
    /// the raw `--platform`/`--os`/`--arch` flags (docker-style, may be empty)
    /// so this matches exactly what the create path would request; only a
    /// `.notFound` from either step means "not present" — any other error
    /// (unreachable registry config, corrupt store, ...) is rethrown rather
    /// than masked as a plain "false".
    static func imageExists(_ reference: String, managementArgs: [String] = []) async throws -> Bool {
        let config = try await Backend.systemConfig()
        do {
            let image = try await ClientImage.get(reference: reference, containerSystemConfig: config)
            let management = try Flags.Management.parse(managementArgs)
            let platform = try DefaultPlatform.resolveWithDefaults(
                platform: management.platform, os: management.os, arch: management.arch, log: Backend.log)
            _ = try await image.config(for: platform)
            return true
        } catch let error as ContainerizationError where error.isCode(.notFound) {
            return false
        }
    }

    static func listNetworks() async throws -> [NetworkRecord] {
        try await NetworkClient().list().map(NetworkRecord.init(resource:))
    }

    static func listVolumes() async throws -> [VolumeRecord] {
        try await ClientVolume.list().map(VolumeRecord.init(configuration:))
    }

    static func stats(for ids: [String]) async throws -> [StatsRecord] {
        let client = ContainerClient()
        return await withTaskGroup(of: StatsRecord?.self) { group in
            for id in ids {
                group.addTask {
                    guard let s = try? await client.stats(id: id) else { return nil }
                    return StatsRecord(stats: s)
                }
            }
            var out: [StatsRecord] = []
            for await record in group {
                if let record { out.append(record) }
            }
            return out
        }
    }

    /// Per-container disk space used (writable layer), in bytes, keyed by id.
    static func containerDiskUsage(for ids: [String]) async -> [String: Int64] {
        let client = ContainerClient()
        return await withTaskGroup(of: (String, Int64)?.self) { group in
            for id in ids {
                group.addTask {
                    guard let bytes = try? await client.diskUsage(id: id) else { return nil }
                    return (id, Int64(bytes))
                }
            }
            var out: [String: Int64] = [:]
            for await entry in group {
                if let (id, bytes) = entry { out[id] = bytes }
            }
            return out
        }
    }

    static func diskUsage() async throws -> DiskUsage {
        let df = try await ClientDiskUsage.get()
        func map(_ u: ResourceUsage) -> DiskUsage.Section {
            DiskUsage.Section(
                total: u.total, active: u.active,
                sizeInBytes: Int64(u.sizeInBytes), reclaimable: Int64(u.reclaimable))
        }
        return DiskUsage(containers: map(df.containers), images: map(df.images), volumes: map(df.volumes))
    }

    // MARK: Container lifecycle

    /// `retainExitCode` hands the bootstrap process to `ComposeExitCodes` so the
    /// init exit code can be awaited later (snapshots don't carry it).
    static func start(_ id: String, retainExitCode: Bool = false) async throws {
        let client = ContainerClient()
        let container = try await client.get(id: id)
        guard container.status != .running else { return }
        let io = try ProcessIO.create(tty: container.configuration.initProcess.terminal, interactive: false, detach: true)
        do {
            // Mirrors apple's own ContainerRun/ContainerStart: the daemon-side
            // ssh-forwarding lookup (RuntimeService.sshAuthSocketHostUrl) only
            // fires when the container's own config has `ssh` set, so handing
            // this along unconditionally is a no-op for every non-ssh container.
            var dynamicEnv: [String: String] = [:]
            if let sshAuthSock = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"] {
                dynamicEnv["SSH_AUTH_SOCK"] = sshAuthSock
            }
            let process = try await client.bootstrap(id: id, stdio: io.stdio, dynamicEnv: dynamicEnv)
            // Register BEFORE start: a fast one-shot can exit — and the
            // apiserver reap its runtime client — before a wait issued
            // afterwards lands, losing the exit code (see ComposeExitCodes).
            if retainExitCode { await ComposeExitCodes.shared.register(id: id, process: process) }
            try await process.start()
            try io.closeAfterStart()
        } catch {
            try? io.close()
            try? await client.stop(id: id)
            throw CLIError.wrap("start \(id)", error)
        }
    }

    /// Defaults mirror the platform's stop options (5s grace, SIGTERM).
    /// Compose down passes stop_grace_period / stop_signal through here; the
    /// signal is a name or number ("SIGUSR1", "USR1", "10") parsed daemon-side.
    static func stop(_ id: String, timeoutSeconds: Int32 = 5, signal: String? = nil) async throws {
        ExpectedStops.shared.mark(id)
        try await ContainerClient().stop(
            id: id, opts: ContainerStopOptions(timeoutInSeconds: timeoutSeconds, signal: signal))
    }

    static func kill(_ id: String) async throws {
        ExpectedStops.shared.mark(id)
        try await ContainerClient().kill(id: id, signal: "KILL")
    }

    static func restart(_ id: String) async throws {
        try? await stop(id)
        try await start(id)
    }

    static func delete(_ id: String, force: Bool) async throws {
        ExpectedStops.shared.mark(id)
        try await ContainerClient().delete(id: id, force: force)
    }

    static func pruneContainers() async throws {
        let client = ContainerClient()
        for snapshot in try await client.list() where snapshot.status == .stopped {
            try? await client.delete(id: snapshot.id, force: false)
        }
    }

    static func stopAll() async throws {
        let client = ContainerClient()
        for snapshot in try await client.list() where snapshot.status == .running {
            ExpectedStops.shared.mark(snapshot.id)
            try? await client.stop(id: snapshot.id)
        }
    }

    // MARK: Run (create + detached start)

    static func runContainer(
        image: String,
        name: String?,
        processArgs: [String],
        managementArgs: [String],
        resourceArgs: [String],
        commandArgs: [String],
        autoRemove: Bool = false,
        retainExitCode: Bool = false,
        progressUpdate: @escaping ProgressUpdateHandler = { _ in }
    ) async throws {
        do {
            // The run path auto-pulls missing images; stage helper credentials first.
            await DockerCredentialHelpers.refreshCredentials(forReference: image)
            let config = try await Backend.systemConfig()
            let id = Utility.createContainerID(name: name?.isEmpty == true ? nil : name)
            try Utility.validEntityName(id)

            let process = try Flags.Process.parse(processArgs)
            let management = try Flags.Management.parse(managementArgs)
            let resource = try Flags.Resource.parse(resourceArgs)
            let registry = try Flags.Registry.parse([])
            let imageFetch = try Flags.ImageFetch.parse([])

            let (configuration, kernel, initImage) = try await Utility.containerConfigFromFlags(
                id: id,
                image: image,
                arguments: commandArgs,
                process: process,
                management: management,
                resource: resource,
                registry: registry,
                imageFetch: imageFetch,
                containerSystemConfig: config,
                progressUpdate: progressUpdate,
                log: Backend.log
            )

            let client = ContainerClient()
            try await client.create(
                configuration: configuration,
                options: ContainerCreateOptions(autoRemove: autoRemove),
                kernel: kernel,
                initImage: initImage
            )
            try await start(id, retainExitCode: retainExitCode)
        } catch let e as CLIError {
            throw e
        } catch {
            throw CLIError.wrap("run \(image)", error)
        }
    }

    // MARK: Images

    static func pullImage(_ reference: String, progress: @escaping @Sendable ([ProgressUpdateEvent]) async -> Void) async throws {
        do {
            await DockerCredentialHelpers.refreshCredentials(forReference: reference)
            let config = try await Backend.systemConfig()
            _ = try await ClientImage.pull(
                reference: reference,
                containerSystemConfig: config,
                progressUpdate: progress
            )
        } catch {
            throw CLIError.wrap("pull \(reference)", error)
        }
    }

    static func deleteImage(_ name: String) async throws {
        do {
            try await ClientImage.delete(reference: name, garbageCollect: true)
        } catch {
            throw CLIError.wrap("delete image \(name)", error)
        }
    }

    static func pruneImages(all: Bool) async throws {
        do {
            let inUse = Set(try await ContainerClient().list().map { $0.configuration.image.reference })
            for image in try await ClientImage.list() {
                let ref = image.reference
                if isInfraImage(ref) || inUse.contains(ref) { continue }
                try? await ClientImage.delete(reference: ref, garbageCollect: false)
            }
            _ = try await ClientImage.cleanUpOrphanedBlobs()
        } catch {
            throw CLIError.wrap("prune images", error)
        }
    }

    static func tagImage(_ source: String, _ target: String) async throws {
        do {
            let config = try await Backend.systemConfig()
            let image = try await ClientImage.get(reference: source, containerSystemConfig: config)
            let normalized = try ClientImage.normalizeReference(target, containerSystemConfig: config)
            _ = try await image.tag(new: normalized)
        } catch {
            throw CLIError.wrap("tag \(source)", error)
        }
    }

    // MARK: Volumes

    static func createVolume(name: String, size: String?) async throws {
        do {
            var opts: [String: String] = [:]
            if let size, !size.isEmpty { opts["size"] = size }
            _ = try await ClientVolume.create(name: name, driverOpts: opts)
        } catch {
            throw CLIError.wrap("create volume \(name)", error)
        }
    }

    static func deleteVolume(_ name: String) async throws {
        do {
            try await ClientVolume.delete(name: name)
        } catch {
            throw CLIError.wrap("delete volume \(name)", error)
        }
    }

    static func pruneVolumes() async throws {
        let used = usedVolumeNames(in: (try? await ContainerClient().list()) ?? [])
        for volume in try await ClientVolume.list() where !used.contains(volume.name) {
            try? await ClientVolume.delete(name: volume.name)
        }
    }

    static func usedVolumeNames(in snapshots: [ContainerSnapshot]) -> Set<String> {
        var used = Set<String>()
        for snapshot in snapshots {
            for mount in snapshot.configuration.mounts {
                if let name = VolumeRecord.volumeName(fromSource: mount.source) {
                    used.insert(name)
                }
            }
        }
        return used
    }

    // MARK: Networks

    static func createNetwork(name: String, subnet: String?, internal isInternal: Bool) async throws {
        do {
            let cidr: CIDRv4? = try subnet.flatMap { $0.isEmpty ? nil : try CIDRv4($0) }
            let configuration = try NetworkConfiguration(
                name: name,
                mode: isInternal ? .hostOnly : .nat,
                ipv4Subnet: cidr,
                plugin: "container-network-vmnet"
            )
            _ = try await NetworkClient().create(configuration: configuration)
        } catch let e as CLIError {
            throw e
        } catch {
            throw CLIError.wrap("create network \(name)", error)
        }
    }

    static func deleteNetwork(_ name: String) async throws {
        do {
            try await NetworkClient().delete(id: name)
        } catch {
            throw CLIError.wrap("delete network \(name)", error)
        }
    }

    static func pruneNetworks() async throws {
        let snapshots = (try? await ContainerClient().list()) ?? []
        var attached = Set<String>()
        for snapshot in snapshots {
            for net in snapshot.configuration.networks {
                attached.insert(net.network)
            }
        }
        for network in try await NetworkClient().list() where !network.isBuiltin && !attached.contains(network.name) {
            try? await NetworkClient().delete(id: network.name)
        }
    }

    // MARK: System

    static func systemState() async throws -> SystemState {
        do {
            let health = try await ClientHealthCheck.ping(timeout: .seconds(3))
            return .running(version: health.apiServerVersion)
        } catch {
            return .stopped
        }
    }

    static func systemStart() async throws {
        guard let resolved = ContainerBinary.resolve() else {
            throw CLIError(command: "system start", message: "container platform not found — install it from https://github.com/apple/container/releases or vendor it into the app")
        }
        do {
            try await SystemController.start(resolved: resolved)
        } catch let e as CLIError {
            throw e
        } catch {
            throw CLIError.wrap("system start", error)
        }
    }

    static func systemStop() async throws {
        do {
            try await SystemController.stop()
        } catch {
            throw CLIError.wrap("system stop", error)
        }
    }

    static func properties() async throws -> String {
        let config = try await Backend.systemConfig()
        return Backend.prettyJSON(config)
    }

    // MARK: Inspection

    /// A built image layer for the detail view: size, digest, and the
    /// Dockerfile-ish command that produced it (from the config history).
    struct ImageLayer: Identifiable {
        let index: Int
        let sizeBytes: Int64
        let digest: String
        let createdBy: String?
        var id: Int { index }
    }

    /// Layers of an image for the host platform, zipped with the non-empty
    /// history entries (empty_layer history items are metadata-only and have
    /// no matching layer blob).
    static func imageLayers(_ reference: String) async throws -> [ImageLayer] {
        do {
            let config = try await Backend.systemConfig()
            let image = try await ClientImage.get(reference: reference, containerSystemConfig: config)
            let platform = ContainerizationOCI.Platform(
                arch: Arch.hostArchitecture().rawValue, os: "linux")
            let manifest = try await image.manifest(for: platform)
            let history = (try? await image.config(for: platform))?.history ?? []
            // Pair each real layer with the next non-empty history command,
            // in order. History has extra empty_layer entries (ENV, CMD, …).
            let commands = history.filter { $0.emptyLayer != true }.map(\.createdBy)
            return manifest.layers.enumerated().map { i, layer in
                ImageLayer(
                    index: i,
                    sizeBytes: layer.size,
                    digest: layer.digest,
                    createdBy: i < commands.count ? commands[i] : nil)
            }
        } catch {
            throw CLIError.wrap("image layers \(reference)", error)
        }
    }

    static func inspectRaw(_ kind: String, _ id: String) async throws -> String {
        switch kind {
        case "container":
            let snapshot = try await ContainerClient().get(id: id)
            return Backend.prettyJSON(snapshot)
        case "image":
            let config = try await Backend.systemConfig()
            let image = try await ClientImage.get(reference: id, containerSystemConfig: config)
            let index = try? await image.index()
            struct Inspect: Encodable {
                let description: ImageDescription
                let index: ContainerizationOCI.Index?
            }
            return Backend.prettyJSON(Inspect(description: image.description, index: index))
        case "machine":
            let snapshot = try await MachineClient().inspect(id: id)
            return Backend.prettyJSON(snapshot)
        case "network":
            let network = try await NetworkClient().get(id: id)
            return Backend.prettyJSON(network.configuration)
        case "volume":
            let volume = try await ClientVolume.inspect(id)
            return Backend.prettyJSON(VolumeRecord(configuration: volume))
        default:
            return "{}"
        }
    }
}

// MARK: - System service bootstrap (what `container system start/stop` does, in-process)

enum SystemController {
    static let apiServerLabel = "com.apple.container.apiserver"
    static let labelPrefix = "com.apple.container."

    static func start(resolved: ResolvedBinary) async throws {
        let appRoot = ApplicationRoot.path
        try? ConfigurationLoader.copyConfigurationToReadOnly(to: appRoot)

        // Resolve symlinks: launchd + amfid validate signatures against the real path.
        let apiserverPath = try FilePath(resolved.apiserverPath).resolvingSymlinks()

        let apiServerDataPath = appRoot.appending(FilePath.Component("apiserver"))
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: apiServerDataPath.string), withIntermediateDirectories: true)

        var env = PluginLoader.filterEnvironment()
        env[ApplicationRoot.environmentName] = appRoot.string
        env[InstallRoot.environmentName] = resolved.installRoot

        let plist = LaunchPlist(
            label: apiServerLabel,
            arguments: [apiserverPath.string, "start"],
            environment: env,
            limitLoadToSessionType: [.Aqua, .Background, .System],
            runAtLoad: true,
            machServices: [apiServerLabel]
        )
        let plistPath = apiServerDataPath.appending(FilePath.Component("apiserver.plist"))
        try plist.encode().write(to: URL(fileURLWithPath: plistPath.string))
        try ServiceManager.register(plistPath: plistPath.string)

        _ = try await ClientHealthCheck.ping(timeout: .seconds(20))

        // Make sure the init filesystem and default kernel exist (non-interactive).
        let config = try await Backend.systemConfig()
        await ensureInitImage(config: config)
        try await ensureKernel(config: config)
    }

    static func stop() async throws {
        let domain = try ServiceManager.getDomainString()
        let fullLabel = "\(domain)/\(apiServerLabel)"

        if (try? await ClientHealthCheck.ping(timeout: .seconds(3))) != nil {
            try? await ContainerService.stopAll()
            // give containers a moment to exit before tearing the daemon down
            for _ in 0..<10 {
                let running = (try? await ContainerClient().list())?.contains { $0.status == .running } ?? false
                if !running { break }
                try? await Task.sleep(for: .seconds(1))
            }
            try? ServiceManager.deregister(fullServiceLabel: fullLabel)
        }

        try ServiceManager.enumerate()
            .filter { $0.hasPrefix(labelPrefix) && $0 != apiServerLabel }
            .forEach { try? ServiceManager.deregister(fullServiceLabel: "\(domain)/\($0)") }
    }

    private static func ensureInitImage(config: ContainerSystemConfig) async {
        let reference = config.vminit.image
        if (try? await ClientImage.get(reference: reference, containerSystemConfig: config)) != nil { return }
        _ = try? await ClientImage.pull(reference: reference, containerSystemConfig: config)
    }

    private static func ensureKernel(config: ContainerSystemConfig) async throws {
        if (try? await ClientKernel.getDefaultKernel(for: .current)) != nil { return }
        // Download the recommended kernel archive and install it (mirrors --enable-kernel-install).
        let (tempURL, _) = try await URLSession.shared.download(from: config.kernel.url)
        let tarPath = tempURL.path + ".tar.zst"
        try? FileManager.default.moveItem(atPath: tempURL.path, toPath: tarPath)
        defer { try? FileManager.default.removeItem(atPath: tarPath) }
        try await ClientKernel.installKernelFromTar(
            tarFile: tarPath,
            kernelFilePath: config.kernel.binaryPath,
            platform: .current,
            force: true
        )
    }
}

// MARK: - Terminal integration (self-exec: no CLI involved)

/// Terminal apps Davit can open shells in. Which are shown in Settings depends
/// on what's installed; "System Default" opens the .command through LaunchServices
/// (whatever the user's .command handler is — the pre-picker behavior).
enum TerminalApp: String, CaseIterable, Identifiable {
    case systemDefault = "default"
    case terminal = "com.apple.Terminal"
    case iterm = "com.googlecode.iterm2"
    case ghostty = "com.mitchellh.ghostty"
    case wezterm = "com.github.wez.wezterm"
    case kitty = "net.kovidgoyal.kitty"
    case alacritty = "org.alacritty"
    case warp = "dev.warp.Warp-Stable"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .systemDefault: return "System Default"
        case .terminal: return "Terminal"
        case .iterm: return "iTerm2"
        case .ghostty: return "Ghostty"
        case .wezterm: return "WezTerm"
        case .kitty: return "kitty"
        case .alacritty: return "Alacritty"
        case .warp: return "Warp"
        }
    }

    var appURL: URL? {
        guard self != .systemDefault else { return nil }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: rawValue)
    }

    var isInstalled: Bool { self == .systemDefault || appURL != nil }

    static var installed: [TerminalApp] { allCases.filter(\.isInstalled) }

    static let defaultsKey = "preferredTerminal"
    static var preferred: TerminalApp {
        let raw = UserDefaults.standard.string(forKey: defaultsKey) ?? ""
        let choice = TerminalApp(rawValue: raw) ?? .systemDefault
        return choice.isInstalled ? choice : .systemDefault
    }
}

enum TerminalLauncher {
    /// Opens an interactive shell into a container in the user's preferred
    /// terminal (Settings → General). The generated .command re-invokes the
    /// Davit binary in `exec` mode, which attaches a TTY through the XPC API
    /// (see ExecMode in Main.swift).
    static func openShell(containerID: String) {
        open(title: "container: \(containerID)", command: "exec", id: containerID)
    }

    /// Login shell into a container machine (davit machine exec over XPC).
    static func openMachineShell(machineID: String) {
        open(title: "machine: \(machineID)", command: "machine exec", id: machineID)
    }

    private static func open(title: String, command: String, id: String) {
        let selfPath = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let escaped = id.replacingOccurrences(of: "'", with: "'\\''")
        let script = """
        #!/bin/sh
        clear
        printf '\\033]0;%s\\007' '\(title)'
        exec '\(selfPath)' \(command) '\(escaped)'
        """
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Davit", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("shell-\(id).command")
        try? script.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        open(commandFile: url, in: TerminalApp.preferred)
    }

    private static func open(commandFile url: URL, in terminal: TerminalApp) {
        switch terminal {
        case .systemDefault:
            NSWorkspace.shared.open(url)
        case .terminal, .iterm, .warp:
            // These register as .command handlers — open the file with the app.
            guard let appURL = terminal.appURL else { NSWorkspace.shared.open(url); return }
            NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
        case .ghostty, .wezterm, .kitty, .alacritty:
            // No .command association; exec their bundled CLI so it works whether
            // or not the app is already running (OpenConfiguration.arguments are
            // ignored for running apps).
            guard let appURL = terminal.appURL else { NSWorkspace.shared.open(url); return }
            let binDir = appURL.appendingPathComponent("Contents/MacOS")
            let invocation: [String]
            switch terminal {
            case .ghostty: invocation = [binDir.appendingPathComponent("ghostty").path, "-e", url.path]
            case .wezterm: invocation = [binDir.appendingPathComponent("wezterm-gui").path, "start", "--", url.path]
            case .kitty: invocation = [binDir.appendingPathComponent("kitty").path, url.path]
            case .alacritty: invocation = [binDir.appendingPathComponent("alacritty").path, "-e", url.path]
            default: invocation = []
            }
            guard let exe = invocation.first, FileManager.default.isExecutableFile(atPath: exe) else {
                NSWorkspace.shared.open(url); return
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: exe)
            process.arguments = Array(invocation.dropFirst())
            try? process.run()
        }
    }
}

// MARK: - Log streaming (FileHandle-based, replaces `container logs -f`)

final class LogStreamer: ObservableObject, @unchecked Sendable {
    @Published var lines: [String] = []
    @Published var isRunning = false

    private let maxLines: Int
    private var handle: FileHandle?
    private var task: Task<Void, Never>?

    init(maxLines: Int = 5000) {
        self.maxLines = maxLines
    }

    /// What to stream logs from — containers and machines expose the same
    /// [stdio, boot] FileHandle pair.
    enum Source {
        case container(String)
        case machine(String)
    }

    func start(containerID: String, boot: Bool, follow: Bool, tail: Int) {
        start(source: .container(containerID), boot: boot, follow: follow, tail: tail)
    }

    func start(source: Source, boot: Bool, follow: Bool, tail: Int) {
        stop()
        lines = []
        isRunning = true
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let handles: [FileHandle]
                switch source {
                case .container(let id): handles = try await ContainerClient().logs(id: id)
                case .machine(let id): handles = try await MachineClient().logs(id: id)
                }
                guard handles.count > (boot ? 1 : 0) else {
                    await self.finish(error: "no log stream available")
                    return
                }
                let fh = boot ? handles[1] : handles[0]
                await MainActor.run { self.handle = fh }
                let initial = Self.readTail(fh: fh, maxLines: tail > 0 ? tail : Int.max)
                await self.append(initial)
                if follow {
                    self.follow(fh: fh)
                } else {
                    await self.finish(error: nil)
                }
            } catch {
                await self.finish(error: "failed to open logs: \(error)")
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        handle?.readabilityHandler = nil
        try? handle?.close()
        handle = nil
        if isRunning { isRunning = false }
    }

    private func follow(fh: FileHandle) {
        _ = try? fh.seekToEnd()
        fh.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(data: data, encoding: .utf8) ?? ""
            let newLines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            Task { @MainActor [weak self] in
                self?.appendOnMain(newLines)
            }
        }
    }

    /// Reads the last `maxLines` lines of a log file without loading the whole file.
    static func readTail(fh: FileHandle, maxLines: Int) -> [String] {
        guard let size = try? fh.seekToEnd(), size > 0 else { return [] }
        var offset = size
        var buffer = Data()
        var lines: [String] = []
        while offset > 0 && lines.count < maxLines && buffer.count < 4_000_000 {
            let readSize = min(65536, offset)
            offset -= readSize
            try? fh.seek(toOffset: offset)
            buffer.insert(contentsOf: fh.readData(ofLength: Int(readSize)), at: 0)
            if let chunk = String(data: buffer, encoding: .utf8) {
                lines = chunk.components(separatedBy: .newlines).filter { !$0.isEmpty }
            }
        }
        return Array(lines.suffix(maxLines))
    }

    @MainActor
    private func appendOnMain(_ new: [String]) {
        lines.append(contentsOf: new)
        if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
    }

    private func append(_ new: [String]) async {
        await MainActor.run { self.appendOnMain(new) }
    }

    private func finish(error: String?) async {
        await MainActor.run {
            if let error { self.lines.append("⚠︎ \(error)") }
            self.isRunning = false
        }
    }

    deinit {
        handle?.readabilityHandler = nil
        try? handle?.close()
    }
}

// MARK: - Pull progress (replaces streamed CLI output)

@MainActor
final class PullProgressModel: ObservableObject {
    @Published var lines: [String] = []
    @Published var isRunning = false
    @Published var succeeded: Bool?

    private var task: Task<Void, Never>?
    private var currentDescription = ""

    func start(reference: String) {
        task?.cancel()
        lines = []
        succeeded = nil
        isRunning = true
        task = Task {
            do {
                try await ContainerService.pullImage(reference) { [weak self] events in
                    await self?.consume(events)
                }
                self.lines.append("✓ pull complete")
                self.succeeded = true
            } catch {
                self.lines.append("✗ \(error.localizedDescription)")
                self.succeeded = false
            }
            self.isRunning = false
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        isRunning = false
    }

    private func consume(_ events: [ProgressUpdateEvent]) {
        for event in events {
            switch event {
            case .setDescription(let text):
                if text != currentDescription {
                    currentDescription = text
                    lines.append(text)
                }
            case .setSubDescription(let text):
                lines.append("  \(text)")
            default:
                break
            }
        }
        if lines.count > 500 { lines.removeFirst(lines.count - 500) }
    }
}

// MARK: - System configuration store (writes ~/.config/container/config.toml)

/// Edits the container platform's user configuration. Values layer as:
/// user config (~/.config/container/config.toml) → install defaults
/// (<installRoot>/etc/container/config.toml) → code defaults. On save, only keys
/// that differ from the defaults are written, `[plugin.*]` sections in an existing
/// user file are preserved verbatim, and the result is validated by the real
/// loader before being published to the app root.
enum SystemConfigStore {
    struct Snapshot {
        /// section → key → scalar (from JSON encoding of ContainerSystemConfig)
        var effective: [String: [String: Any]]
        var defaults: [String: [String: Any]]
    }

    static var homeConfigPath: FilePath {
        ConfigurationLoader.configurationFile(.home)
    }

    static func load() async throws -> Snapshot {
        let effective = try await Backend.systemConfig()
        let defaults: ContainerSystemConfig
        do {
            defaults = try await ConfigurationLoader.load(
                configurationFiles: [ConfigurationLoader.configurationFile(in: InstallRoot.path, of: .installRoot)])
        } catch {
            defaults = ContainerSystemConfig()
        }
        return Snapshot(effective: try dictionary(of: effective), defaults: try dictionary(of: defaults))
    }

    /// Persist `edited` (full effective values): diffs against defaults, writes TOML,
    /// validates, publishes to the app root so client-side loads pick it up immediately.
    static func save(edited: [String: [String: Any]], defaults: [String: [String: Any]]) async throws {
        var toml = "# User overrides for Apple's container platform.\n# Managed by Davit — edits made here are preserved only for [plugin.*] sections.\n"
        var wroteAny = false
        for section in edited.keys.sorted() {
            guard let values = edited[section] else { continue }
            let defaultValues = defaults[section] ?? [:]
            var lines: [String] = []
            for key in values.keys.sorted() {
                let value = values[key]!
                if value is NSNull { continue }
                if let def = defaultValues[key], scalarEqual(def, value) { continue }
                guard let rendered = tomlScalar(value) else { continue }
                lines.append("\(key) = \(rendered)")
            }
            if !lines.isEmpty {
                toml += "\n[\(section)]\n" + lines.joined(separator: "\n") + "\n"
                wroteAny = true
            }
        }

        // Preserve [plugin.*] sections from the existing user file.
        let path = homeConfigPath.string
        if let existing = try? String(contentsOfFile: path, encoding: .utf8) {
            let pluginBlocks = pluginSections(in: existing)
            if !pluginBlocks.isEmpty {
                toml += "\n" + pluginBlocks.joined(separator: "\n") + "\n"
                wroteAny = true
            }
        }

        let fm = FileManager.default
        if !wroteAny {
            // No overrides at all: remove the user file so defaults fully apply.
            try? fm.removeItem(atPath: path)
        } else {
            // Validate through the real loader before committing.
            let tempPath = fm.temporaryDirectory.appendingPathComponent("davit-config-\(UUID().uuidString).toml").path
            try toml.write(toFile: tempPath, atomically: true, encoding: .utf8)
            defer { try? fm.removeItem(atPath: tempPath) }
            do {
                _ = try await ConfigurationLoader.load(configurationFiles: [FilePath(tempPath)])
            } catch {
                throw CLIError(command: "save settings", message: "invalid configuration: \(error)")
            }
            try fm.createDirectory(
                atPath: homeConfigPath.removingLastComponent().string, withIntermediateDirectories: true)
            try toml.write(toFile: path, atomically: true, encoding: .utf8)
        }

        // Publish to <appRoot>/config/config.toml (normally done at service start).
        try ConfigurationLoader.copyConfigurationToReadOnly()
    }

    // MARK: helpers

    private static func dictionary(of config: ContainerSystemConfig) throws -> [String: [String: Any]] {
        let data = try JSONEncoder().encode(config)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        return obj.mapValues { $0 as? [String: Any] ?? [:] }
    }

    private static func scalarEqual(_ a: Any, _ b: Any) -> Bool {
        (a as? NSObject)?.isEqual(b) ?? false
    }

    private static func tomlScalar(_ value: Any) -> String? {
        switch value {
        case let n as NSNumber:
            // NSNumber bridges bools too; distinguish via the ObjC type encoding.
            if String(cString: n.objCType) == "c" { return n.boolValue ? "true" : "false" }
            if n.doubleValue == n.doubleValue.rounded() { return "\(n.int64Value)" }
            return "\(n.doubleValue)"
        case let s as String:
            let escaped = s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        default:
            return nil
        }
    }

    private static func pluginSections(in toml: String) -> [String] {
        var blocks: [String] = []
        var current: [String] = []
        var inPlugin = false
        for line in toml.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                if inPlugin, !current.isEmpty { blocks.append(current.joined(separator: "\n")) }
                inPlugin = trimmed.hasPrefix("[plugin.") || trimmed.hasPrefix("[plugin]")
                current = inPlugin ? [line] : []
            } else if inPlugin {
                current.append(line)
            }
        }
        if inPlugin, !current.isEmpty { blocks.append(current.joined(separator: "\n")) }
        return blocks
    }
}

// MARK: - In-app platform installer

/// Downloads Apple's signed installer package for the container platform, extracts
/// its payload into an app-managed install root (no admin rights required, unlike
/// the official installer), verifies code signatures, and activates it. The managed
/// root then hosts the launchd services exactly like a /usr/local install.
enum PlatformInstaller {
    /// Must match the ContainerAPIClient version this app links (Package.swift pin).
    static let pinnedVersion = "1.1.0"

    static var managedRoot: String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("dev.wouter.davit/platform/\(pinnedVersion)").path
    }

    static var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: managedRoot + "/bin/container-apiserver")
    }

    /// progress: stage text + download fraction (nil while not downloading / size unknown)
    static func install(progress: @escaping @Sendable (String, Double?) -> Void) async throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("davit-install-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        progress("Downloading container \(pinnedVersion)…", 0)
        let url = URL(string: "https://github.com/apple/container/releases/download/\(pinnedVersion)/container-\(pinnedVersion)-installer-signed.pkg")!
        let pkgPath = work.appendingPathComponent("container.pkg")
        try await downloadWithProgress(from: url, to: pkgPath) { fraction, receivedMB, totalMB in
            if let totalMB {
                progress(String(format: "Downloading container \(pinnedVersion)… %.0f of %.0f MB", receivedMB, totalMB), fraction)
            } else {
                progress(String(format: "Downloading container \(pinnedVersion)… %.0f MB", receivedMB), nil)
            }
        }

        progress("Extracting installer payload…", nil)
        let expanded = work.appendingPathComponent("expanded")
        try await runTool("/usr/sbin/pkgutil", ["--expand-full", pkgPath.path, expanded.path])
        guard let payload = findPayload(in: expanded) else {
            throw CLIError(command: "platform install", message: "could not locate Payload in the installer package")
        }

        progress("Verifying code signatures…", nil)
        let stagedAPIServer = payload.appendingPathComponent("bin/container-apiserver").path
        guard fm.isExecutableFile(atPath: stagedAPIServer) else {
            throw CLIError(command: "platform install", message: "payload is missing bin/container-apiserver")
        }
        try await runTool("/usr/bin/codesign", ["--verify", "--strict", stagedAPIServer])

        progress("Installing to Application Support…", nil)
        // Clear quarantine so launchd can execute the extracted binaries.
        _ = try? await runTool("/usr/bin/xattr", ["-dr", "com.apple.quarantine", payload.path])
        let root = managedRoot
        if fm.fileExists(atPath: root) { try fm.removeItem(atPath: root) }
        try fm.createDirectory(atPath: (root as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try fm.copyItem(atPath: payload.path, toPath: root)

        guard isInstalled else {
            throw CLIError(command: "platform install", message: "installation completed but bin/container-apiserver is not executable")
        }
        // Point resolution at the managed root before any library API caches paths.
        setenv(InstallRoot.environmentName, root, 1)
        progress("Installed to \(root)", nil)
    }

    /// Streams a download to disk, reporting (fraction?, receivedMB, totalMB?) as it goes.
    static func downloadWithProgress(
        from url: URL,
        to destination: URL,
        report: @escaping @Sendable (Double?, Double, Double?) -> Void
    ) async throws {
        let (bytes, response) = try await URLSession.shared.bytes(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw CLIError(command: "platform install", message: "download failed: HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        let total = response.expectedContentLength  // -1 when unknown
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }

        var buffer = Data()
        buffer.reserveCapacity(1 << 17)
        var received: Int64 = 0
        var lastReported: Int64 = 0
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 1 << 17 {
                try handle.write(contentsOf: buffer)
                received += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                // report every ~2 MB to keep UI updates cheap
                if received - lastReported >= 1 << 21 {
                    lastReported = received
                    let mb = Double(received) / 1_048_576
                    if total > 0 {
                        report(Double(received) / Double(total), mb, Double(total) / 1_048_576)
                    } else {
                        report(nil, mb, nil)
                    }
                }
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            received += Int64(buffer.count)
        }
        let mb = Double(received) / 1_048_576
        report(1.0, mb, total > 0 ? Double(total) / 1_048_576 : mb)
    }

    /// Removes the managed install (containers/images are unaffected — they live in
    /// the shared app root under com.apple.container).
    static func removeManaged() throws {
        try FileManager.default.removeItem(atPath: managedRoot)
    }

    private static func findPayload(in dir: URL) -> URL? {
        let fm = FileManager.default
        let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: [.isDirectoryKey])
        while let item = enumerator?.nextObject() as? URL {
            if item.lastPathComponent == "Payload",
               (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
               fm.fileExists(atPath: item.appendingPathComponent("bin").path) {
                return item
            }
        }
        return nil
    }

    /// Minimal runner for system tools (pkgutil/codesign/xattr/osascript) — not the
    /// container CLI. Output goes to a temp file rather than a pipe: some of these
    /// tools spawn XPC helpers (e.g. CSExattrCryptoService) that inherit a pipe's
    /// write end and outlive the tool, so pipe-EOF never arrives and reads hang.
    /// File-backed output + termination-driven completion has no such failure mode.
    @discardableResult
    static func runTool(_ path: String, _ args: [String]) async throws -> String {
        let fm = FileManager.default
        let outURL = fm.temporaryDirectory.appendingPathComponent("davit-tool-\(UUID().uuidString).out")
        fm.createFile(atPath: outURL.path, contents: nil)
        let outHandle = try FileHandle(forWritingTo: outURL)
        defer {
            try? outHandle.close()
            try? fm.removeItem(at: outURL)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        process.standardOutput = outHandle
        process.standardError = outHandle
        process.standardInput = FileHandle.nullDevice

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { _ in cont.resume() }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                cont.resume(throwing: error)
            }
        }

        let output = (try? String(contentsOf: outURL, encoding: .utf8)) ?? ""
        if process.terminationStatus != 0 {
            throw CLIError(
                command: ([path] + args).joined(separator: " "),
                message: output.trimmingCharacters(in: .whitespacesAndNewlines),
                exitCode: process.terminationStatus)
        }
        return output
    }
}

// MARK: - Shell command installer (`container` in /usr/local/bin)

/// Mimics the system install's shell experience for a Davit-managed platform:
/// writes a wrapper at /usr/local/bin/container that pins CONTAINER_INSTALL_ROOT
/// to the managed root and execs the real CLI. A plain symlink would be wrong —
/// the CLI derives its install root from the (unresolved) executable path and
/// would look for plugins under /usr/local. Requires one admin authorization.
enum ShellCommandInstaller {
    static let wrapperPath = "/usr/local/bin/container"
    private static let marker = "installed by Davit (dev.wouter.davit)"

    enum Status {
        case installed          // our wrapper is in place
        case foreignBinary      // a real system install (or something else) owns the path
        case notInstalled
    }

    static var status: Status {
        guard FileManager.default.fileExists(atPath: wrapperPath) else { return .notInstalled }
        guard let content = try? String(contentsOfFile: wrapperPath, encoding: .utf8) else { return .foreignBinary }
        return content.contains(marker) ? .installed : .foreignBinary
    }

    static func install(managedRoot: String) async throws {
        // Version-agnostic: the managed root is versioned (platform/<x.y.z>),
        // so a wrapper pinned to one version strands the CLI on every Davit
        // platform upgrade. Resolve the newest installed version at exec time
        // instead (numeric per-component sort; only roots with a CLI count).
        let base = (managedRoot as NSString).deletingLastPathComponent
        let wrapper = """
        #!/bin/sh
        # \(marker) — runs the container CLI from the newest Davit-managed platform install
        base="\(base)"
        v=$(ls "$base" 2>/dev/null | sort -t. -k1,1n -k2,2n -k3,3n | while read -r c; do
          [ -x "$base/$c/bin/container" ] && echo "$c"
        done | tail -1)
        if [ -z "$v" ]; then
          echo "davit wrapper: no managed container platform under $base — reinstall from Davit's settings" >&2
          exit 1
        fi
        export CONTAINER_INSTALL_ROOT="$base/$v"
        exec "$base/$v/bin/container" "$@"
        """
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("davit-container-wrapper")
        try wrapper.write(to: temp, atomically: true, encoding: .utf8)
        try await runPrivileged("mkdir -p /usr/local/bin && install -m 0755 \(shellQuote(temp.path)) \(shellQuote(wrapperPath))")
        try? FileManager.default.removeItem(at: temp)
    }

    static func uninstall() async throws {
        guard status == .installed else { return }
        try await runPrivileged("rm -f \(shellQuote(wrapperPath))")
    }

    static func runPrivileged(_ command: String) async throws {
        // osascript presents the standard macOS authorization dialog.
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        try await PlatformInstaller.runTool(
            "/usr/bin/osascript",
            ["-e", "do shell script \"\(escaped)\" with administrator privileges"]
        )
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// MARK: - Recreate support (containers are immutable; edit = replace)

extension ContainerService {
    struct RecreatePrefill {
        /// What the user originally passed after the image (entrypoint/CMD subtracted).
        var commandArgs: [String] = []
        /// Env vars that aren't part of the image config (i.e. user-supplied).
        var customEnv: [String] = []
    }

    /// Reconstructs user-level run inputs from a container's resolved init process,
    /// by comparing against the image's entrypoint/cmd/env.
    static func recreatePrefill(for record: ContainerRecord) async -> RecreatePrefill {
        var prefill = RecreatePrefill()
        let full = [record.configuration.initProcess?.executable].compactMap { $0 }
            + (record.configuration.initProcess?.arguments ?? [])
        let recordEnv = record.configuration.initProcess?.environment ?? []

        guard let reference = record.configuration.image?.reference,
              let config = try? await Backend.systemConfig(),
              let image = try? await ClientImage.get(reference: reference, containerSystemConfig: config),
              let platform = record.configuration.platform,
              let ociImage = try? await image.config(for: ContainerizationOCI.Platform(
                  arch: platform.architecture ?? "arm64", os: platform.os ?? "linux"))
        else {
            // Can't resolve the image config — fall back to the full command and env.
            prefill.commandArgs = full
            prefill.customEnv = recordEnv
            return prefill
        }

        let entrypoint = ociImage.config?.entrypoint ?? []
        let cmd = ociImage.config?.cmd ?? []
        if !entrypoint.isEmpty, full.count >= entrypoint.count, Array(full.prefix(entrypoint.count)) == entrypoint {
            let rest = Array(full.dropFirst(entrypoint.count))
            prefill.commandArgs = rest == cmd ? [] : rest
        } else {
            prefill.commandArgs = full == cmd ? [] : full
        }

        let imageEnv = Set(ociImage.config?.env ?? [])
        prefill.customEnv = recordEnv.filter { !imageEnv.contains($0) }
        return prefill
    }
}


// MARK: - Local DNS domains (host -> container name resolution)

/// Wraps the platform's local DNS domains (`container system dns`): an
/// /etc/resolver entry per domain, so `web.<domain>` resolves from the host.
/// Listing is unprivileged (public client API); create/delete write to
/// /etc/resolver and therefore run the platform CLI once with admin rights.
enum DNSDomainService {
    static func list() -> [String] {
        HostDNSResolver().listDomains().map(\.pqdn)
    }

    static func create(_ domain: String) async throws {
        guard domain.range(of: "^[A-Za-z0-9.-]+$", options: .regularExpression) != nil else {
            throw CLIError(command: "dns create", message: "invalid domain name: \(domain)")
        }
        guard let cli = cliPath() else {
            throw CLIError(command: "dns create", message: "container CLI not found in the resolved platform install")
        }
        try await ShellCommandInstaller.runPrivileged("\(shellQuote(cli)) system dns create \(shellQuote(domain))")
    }

    static func delete(_ domain: String) async throws {
        guard let cli = cliPath() else {
            throw CLIError(command: "dns delete", message: "container CLI not found in the resolved platform install")
        }
        try await ShellCommandInstaller.runPrivileged("\(shellQuote(cli)) system dns delete \(shellQuote(domain))")
    }

    private static func cliPath() -> String? {
        guard let root = ContainerBinary.resolve()?.installRoot else { return nil }
        let path = "\(root)/bin/container"
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}


// MARK: - Container stop notifications

import UserNotifications

/// Posts a macOS notification when a container stops without Davit having
/// asked it to (crash, OOM kill, external stop). Opt-in via Settings.
enum StopNotifier {
    static let defaultsKey = "notifyUnexpectedStops"

    static var enabled: Bool { UserDefaults.standard.bool(forKey: defaultsKey) }

    /// Requests authorization once, on first enable. Safe to call repeatedly.
    static func requestAuthorization() {
        guard Bundle.main.bundleIdentifier != nil else { return }  // headless/dev
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func notifyStopped(_ id: String) {
        guard enabled, Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = "Container stopped"
        content.body = "\(id) stopped unexpectedly."
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "container-stopped-\(id)-\(UUID().uuidString)",
            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}


// MARK: - Volume browsing (mount into a throwaway container)

/// Volumes have no filesystem API of their own, so browsing one means mounting
/// it into a tiny helper container and reusing the exec/copy file operations.
/// The helper is labeled infrastructure and cleaned up when the sheet closes.
enum VolumeBrowser {
    static let mountPoint = "/volume"
    static let helperImage = "docker.io/library/alpine:latest"

    /// Create + start a helper with the volume mounted at /volume; returns its id.
    static func open(volumeName: String) async throws -> String {
        do {
            let id = "davit-volume-\(volumeName)-\(UUID().uuidString.prefix(6))".lowercased()
            try await ContainerService.runContainer(
                image: helperImage,
                name: id,
                processArgs: [],
                managementArgs: [
                    "--mount", "type=volume,source=\(volumeName),target=\(mountPoint)",
                    "--label", "com.davit.volume-browser=\(volumeName)",
                ],
                resourceArgs: ["--cpus", "1", "--memory", "256m"],
                commandArgs: ["sleep", "86400"]
            )
            return id
        } catch let e as CLIError {
            throw e
        } catch {
            throw CLIError.wrap("browse volume \(volumeName)", error)
        }
    }

    static func close(_ helperID: String) async {
        try? await ContainerService.delete(helperID, force: true)
    }
}
