import ContainerAPIClient
import ContainerResource
import Foundation
import SwiftUI

// View models mapped from ContainerAPIClient / ContainerResource types.
// Kept as plain structs so views stay decoupled from the (unstable) library API.

// MARK: - Containers

struct ContainerRecord: Identifiable, Hashable, Encodable {
    let id: String
    let status: ContainerStatus?
    let configuration: ContainerConfigurationInfo

    var state: ContainerState { ContainerState(rawValue: status?.state.lowercased() ?? "stopped") ?? .unknown }
    var isRunning: Bool { state == .running }
    var imageReference: String { configuration.image?.reference ?? "—" }
    var shortImage: String { ImageRecord.shortName(imageReference) }
    var primaryIPv4: String? {
        status?.networks?.first?.ipv4Address?.split(separator: "/").first.map(String.init)
    }
    var command: String {
        let p = configuration.initProcess
        return (([p?.executable ?? ""] + (p?.arguments ?? [])).joined(separator: " ")).trimmingCharacters(in: .whitespaces)
    }
    var created: Date? { parseISODate(configuration.creationDate) }
    var started: Date? { parseISODate(status?.startedDate) }
}

extension ContainerRecord {
    init(snapshot: ContainerSnapshot) {
        let cfg = snapshot.configuration
        self.id = snapshot.id
        self.status = ContainerStatus(
            state: snapshot.status.rawValue,
            startedDate: snapshot.startedDate.map(isoString),
            networks: snapshot.networks.map { attachment in
                ContainerNetworkStatus(
                    network: attachment.network,
                    hostname: attachment.hostname,
                    ipv4Address: String(describing: attachment.ipv4Address),
                    ipv4Gateway: String(describing: attachment.ipv4Gateway),
                    ipv6Address: attachment.ipv6Address.map { String(describing: $0) },
                    macAddress: attachment.macAddress.map { String(describing: $0) },
                    mtu: attachment.mtu.map(Int.init)
                )
            }
        )
        self.configuration = ContainerConfigurationInfo(
            id: cfg.id,
            creationDate: isoString(cfg.creationDate),
            image: ImageReferenceInfo(reference: cfg.image.reference, digest: cfg.image.digest),
            initProcess: InitProcessInfo(
                executable: cfg.initProcess.executable,
                arguments: cfg.initProcess.arguments,
                environment: cfg.initProcess.environment,
                workingDirectory: cfg.initProcess.workingDirectory,
                terminal: cfg.initProcess.terminal
            ),
            labels: cfg.labels,
            mounts: cfg.mounts.map(MountRecord.init(filesystem:)),
            platform: PlatformRecord(architecture: cfg.platform.architecture, os: cfg.platform.os),
            publishedPorts: cfg.publishedPorts.map { port in
                PublishedPort(
                    containerPort: Int(port.containerPort),
                    hostPort: Int(port.hostPort),
                    hostAddress: String(describing: port.hostAddress),
                    proto: port.proto.rawValue
                )
            },
            resources: ResourceLimits(cpus: cfg.resources.cpus, memoryInBytes: Int64(cfg.resources.memoryInBytes)),
            rosetta: cfg.rosetta,
            readOnly: cfg.readOnly,
            runtimeHandler: cfg.runtimeHandler
        )
    }
}

enum ContainerState: String {
    case running, stopped, stopping, unknown

    var color: Color {
        switch self {
        case .running: return .green
        case .stopping: return .orange
        case .stopped: return .secondary.opacity(0.7)
        case .unknown: return .yellow
        }
    }
    var label: String { rawValue.capitalized }
}

struct ContainerStatus: Hashable, Encodable {
    let state: String
    let startedDate: String?
    let networks: [ContainerNetworkStatus]?
}

struct ContainerNetworkStatus: Hashable, Encodable {
    let network: String?
    let hostname: String?
    let ipv4Address: String?
    let ipv4Gateway: String?
    let ipv6Address: String?
    let macAddress: String?
    let mtu: Int?
}

struct ContainerConfigurationInfo: Hashable, Encodable {
    let id: String?
    let creationDate: String?
    let image: ImageReferenceInfo?
    let initProcess: InitProcessInfo?
    let labels: [String: String]?
    let mounts: [MountRecord]?
    let platform: PlatformRecord?
    let publishedPorts: [PublishedPort]?
    let resources: ResourceLimits?
    let rosetta: Bool?
    let readOnly: Bool?
    let runtimeHandler: String?
}

struct ImageReferenceInfo: Hashable, Encodable {
    let reference: String?
    let digest: String?
}

struct InitProcessInfo: Hashable, Encodable {
    let executable: String?
    let arguments: [String]?
    let environment: [String]?
    let workingDirectory: String?
    let terminal: Bool?
}

struct MountRecord: Hashable, Encodable {
    let destination: String?
    let source: String?
    let kind: String
    let volumeName: String?

    init(filesystem fs: Filesystem) {
        self.destination = fs.destination
        self.source = fs.source
        // enum case label, e.g. "block(format: ...)" → "block", "virtiofs" → "virtiofs"
        let label = String(describing: fs.type)
        let caseName = label.split(separator: "(").first.map(String.init) ?? "mount"
        self.volumeName = VolumeRecord.volumeName(fromSource: fs.source)
        switch caseName {
        case "virtiofs": self.kind = "bind"
        case "block": self.kind = self.volumeName != nil ? "volume" : "block"
        default: self.kind = caseName
        }
    }

    var kindLabel: String { kind }
    var displaySource: String { volumeName ?? source ?? "—" }
}

struct PlatformRecord: Hashable, Encodable {
    let architecture: String?
    let os: String?
    var display: String { "\(os ?? "?")/\(architecture ?? "?")" }
}

struct PublishedPort: Hashable, Encodable {
    let containerPort: Int?
    let hostPort: Int?
    let hostAddress: String?
    let proto: String?

    var display: String {
        "\(hostAddress ?? "0.0.0.0"):\(hostPort ?? 0) → \(containerPort ?? 0)/\(proto ?? "tcp")"
    }
    var shortDisplay: String { "\(hostPort ?? 0):\(containerPort ?? 0)" }
}

struct ResourceLimits: Hashable, Encodable {
    let cpus: Int?
    let memoryInBytes: Int64?
}

// MARK: - Images

struct ImageRecord: Identifiable, Hashable, Encodable {
    struct Variant: Hashable, Encodable {
        let display: String
        let size: Int64
    }

    let id: String
    let name: String
    let digest: String?
    let totalSize: Int64
    let platforms: [String]
    let variants: [Variant]

    var shortNameTag: String { Self.shortName(name) }
    var created: Date? { nil }  // creation date is not exposed by the image store API

    /// "docker.io/library/alpine:latest" → "alpine:latest"
    static func shortName(_ ref: String) -> String {
        var s = ref
        for prefix in ["docker.io/library/", "docker.io/"] where s.hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count))
        }
        return s
    }

    func matchesReference(_ ref: String) -> Bool {
        !Self.referenceAliases(for: name).isDisjoint(with: Self.referenceAliases(for: ref))
    }

    private static func referenceAliases(for ref: String) -> Set<String> {
        let ref = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ref.isEmpty else { return [] }

        var aliases: Set<String> = []
        func add(_ value: String) {
            guard !value.isEmpty else { return }
            aliases.insert(value)
            aliases.insert(withImplicitLatestTag(value))
        }

        add(ref)

        let short = shortName(ref)
        add(short)

        if short.hasPrefix("library/") {
            add(String(short.dropFirst("library/".count)))
        }

        return aliases
    }

    private static func withImplicitLatestTag(_ ref: String) -> String {
        guard !ref.contains("@") else { return ref }
        let lastSlash = ref.lastIndex(of: "/")
        if let lastColon = ref.lastIndex(of: ":"), lastSlash == nil || lastColon > lastSlash! {
            return ref
        }
        return "\(ref):latest"
    }

    var repository: String {
        let base = shortNameTag.split(separator: ":").dropLast().joined(separator: ":")
        return base.isEmpty ? shortNameTag : base
    }
    var tag: String {
        let parts = shortNameTag.split(separator: ":")
        return parts.count > 1 ? String(parts.last!) : "latest"
    }
}

extension ImageRecord {
    init(client image: ClientImage) async {
        let index = try? await image.index()
        var variants: [Variant] = []
        for manifest in index?.manifests ?? [] {
            guard let platform = manifest.platform, platform.os != "unknown" else { continue }
            variants.append(Variant(display: "\(platform.os)/\(platform.architecture)", size: manifest.size))
        }
        var seen = Set<String>()
        let platforms = variants.map(\.display).filter { seen.insert($0).inserted }
        let totalSize = (try? await ClientImage.getFullImageSize(image: image)) ?? 0
        self.init(
            id: image.digest,
            name: image.reference,
            digest: image.digest,
            totalSize: totalSize,
            platforms: platforms,
            variants: variants
        )
    }
}

extension ImageRecord {
    enum Compatibility: Hashable {
        case unknown
        case native
        case amd64RequiresRosetta
        case otherCrossArch
    }

    func compatibility(hostArch: String) -> Compatibility {
        guard !variants.isEmpty else { return .unknown }
        let nativeDisplay = "linux/\(hostArch)"
        if platforms.contains(nativeDisplay) { return .native }
        if hostArch == "arm64" && platforms.contains("linux/amd64") {
            return .amd64RequiresRosetta
        }
        return .otherCrossArch
    }
}

// MARK: - Networks

struct NetworkRecord: Identifiable, Hashable, Encodable {
    let id: String
    let name: String
    let isBuiltin: Bool
    let createdISO: String?
    let subnet: String?
    let mode: String?

    var created: Date? { parseISODate(createdISO) }

    init(resource: NetworkResource) {
        self.id = resource.id
        self.name = resource.name
        self.isBuiltin = resource.isBuiltin
        self.createdISO = isoString(resource.creationDate)
        self.subnet = resource.configuration.ipv4Subnet.map { String(describing: $0) }
        self.mode = String(describing: resource.configuration.mode)
    }
}

// MARK: - Volumes

struct VolumeRecord: Identifiable, Hashable, Encodable {
    let id: String
    let name: String
    let createdISO: String?
    let format: String?
    let source: String?
    let sizeInBytes: Int64?

    var created: Date? { parseISODate(createdISO) }

    init(configuration: VolumeConfiguration) {
        self.id = configuration.name
        self.name = configuration.name
        self.createdISO = isoString(configuration.creationDate)
        self.format = configuration.format
        self.source = configuration.source
        self.sizeInBytes = nil
    }

    /// Volumes are backed by "<appRoot>/volumes/<name>/volume.img"; extract <name>.
    static func volumeName(fromSource source: String?) -> String? {
        guard let source else { return nil }
        let parts = source.split(separator: "/").map(String.init)
        guard let i = parts.lastIndex(of: "volumes"), i + 1 < parts.count,
              parts.last?.hasSuffix(".img") == true else { return nil }
        return parts[i + 1]
    }
}

// MARK: - Stats

struct StatsRecord: Identifiable, Hashable {
    let id: String
    let cpuUsageUsec: Int64?
    let memoryUsageBytes: Int64?
    let memoryLimitBytes: Int64?
    let networkRxBytes: Int64?
    let networkTxBytes: Int64?
    let blockReadBytes: Int64?
    let blockWriteBytes: Int64?
    let numProcesses: Int?

    init(stats: ContainerStats) {
        self.id = stats.id
        self.cpuUsageUsec = stats.cpuUsageUsec.map(Int64.init)
        self.memoryUsageBytes = stats.memoryUsageBytes.map(Int64.init)
        self.memoryLimitBytes = stats.memoryLimitBytes.map(Int64.init)
        self.networkRxBytes = stats.networkRxBytes.map(Int64.init)
        self.networkTxBytes = stats.networkTxBytes.map(Int64.init)
        self.blockReadBytes = stats.blockReadBytes.map(Int64.init)
        self.blockWriteBytes = stats.blockWriteBytes.map(Int64.init)
        self.numProcesses = stats.numProcesses.map(Int.init)
    }
}

/// A processed stats sample with derived CPU percentage.
struct StatsSample: Identifiable, Hashable {
    let id = UUID()
    let time: Date
    let cpuPercent: Double
    let memoryBytes: Int64
    let memoryLimit: Int64
    let rxBytes: Int64
    let txBytes: Int64
    /// Disk I/O throughput in bytes/second, derived from block-I/O deltas.
    let diskReadRate: Double
    let diskWriteRate: Double
    /// Disk space consumed by the container (writable layer). Refreshed on a
    /// slower cadence than the 2s stats poll and carried forward between refreshes.
    let diskUsageBytes: Int64
    let processes: Int

    var memoryPercent: Double {
        memoryLimit > 0 ? Double(memoryBytes) / Double(memoryLimit) * 100 : 0
    }
}

// MARK: - System

struct DiskUsage: Hashable {
    struct Section: Hashable {
        let total: Int?
        let active: Int?
        let sizeInBytes: Int64?
        let reclaimable: Int64?
    }
    let containers: Section?
    let images: Section?
    let volumes: Section?
}

enum SystemState: Equatable {
    case running(version: String?)
    case stopped
    case unknown

    var isRunning: Bool { if case .running = self { return true }; return false }
}

// MARK: - Helpers

private let isoFractional: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()
private let isoPlain: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}()

func parseISODate(_ s: String?) -> Date? {
    guard let s else { return nil }
    return isoPlain.date(from: s) ?? isoFractional.date(from: s)
}

func isoString(_ date: Date) -> String {
    isoPlain.string(from: date)
}

func formatBytes(_ bytes: Int64?) -> String {
    guard let bytes, bytes > 0 else { return "0 B" }
    let fmt = ByteCountFormatter()
    fmt.countStyle = .file
    return fmt.string(fromByteCount: bytes)
}

func relativeDate(_ date: Date?) -> String {
    guard let date else { return "—" }
    let fmt = RelativeDateTimeFormatter()
    fmt.unitsStyle = .abbreviated
    return fmt.localizedString(for: date, relativeTo: Date())
}
