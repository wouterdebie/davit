import ContainerAPIClient
import ContainerCommands
import ContainerPersistence
import Foundation
import MachineAPIClient

/// A container machine (micro VM) as shown in the UI.
struct MachineRecord: Identifiable, Hashable {
    let id: String
    let statusRaw: String
    let imageReference: String
    let ipAddress: String?
    let cpus: Int
    let memoryBytes: UInt64
    let diskSize: UInt64?
    let createdISO: String?
    let startedISO: String?
    let platform: String
    let homeMount: String
    let containerId: String?
    var isDefault: Bool

    var isRunning: Bool { statusRaw == "running" }
    var created: Date? { parseISODate(createdISO) }
    var dnsName: String { "\(id.lowercased()).machine" }
}

/// Container machines (micro VMs) via the machine-apiserver plugin,
/// mirroring `container machine list/create/stop/delete/set-default`.
enum MachineService {

    static func list() async throws -> [MachineRecord] {
        do {
            let client = MachineClient()
            let snapshots = try await client.list()
            let defaultID = try? await client.getDefault()
            let iso = ISO8601DateFormatter()
            return snapshots.map { snap in
                MachineRecord(
                    id: snap.id,
                    statusRaw: snap.status.rawValue,
                    imageReference: snap.configuration.image.reference,
                    ipAddress: snap.ipAddress,
                    cpus: snap.bootConfig.cpus,
                    memoryBytes: snap.bootConfig.memory.toUInt64(unit: .bytes),
                    diskSize: snap.diskSize,
                    createdISO: snap.createdDate.map { iso.string(from: $0) },
                    startedISO: snap.startedDate.map { iso.string(from: $0) },
                    platform: "\(snap.platform.os)/\(snap.platform.architecture)",
                    homeMount: snap.bootConfig.homeMount.rawValue,
                    containerId: snap.containerId,
                    isDefault: snap.id == defaultID
                )
            }
            .sorted { $0.id < $1.id }
        } catch {
            throw CLIError.wrap("machine list", error)
        }
    }

    /// Create (pulling the image if needed) and boot a machine — the same path
    /// as `container machine create <image> --name <name>`.
    static func create(
        image: String,
        name: String,
        cpus: Int?,
        memory: String?,
        setDefault: Bool,
        progress: @escaping @Sendable (String) async -> Void
    ) async throws {
        do {
            try Utility.validEntityName(name)
            await DockerCredentialHelpers.refreshCredentials(forReference: image)
            let systemConfig = try await Backend.systemConfig()
            let bootConfig = try systemConfig.machine.with(
                [
                    "cpus": cpus.map { "\($0)" },
                    "memory": memory?.isEmpty == true ? nil : memory,
                ].compactMapValues { $0 })

            await progress("Fetching image…")
            let management = try Flags.MachineManagement.parse([])
            let registry = try Flags.Registry.parse([])
            let imageFetch = try Flags.ImageFetch.parse([])
            let (config, resources) = try await MachineClient.machineConfigFromFlags(
                id: name,
                image: image,
                management: management,
                registry: registry,
                imageFetch: imageFetch,
                containerSystemConfig: systemConfig,
                progressUpdate: { _ in }
            )
            let client = MachineClient()
            await progress("Creating machine…")
            try await client.create(configuration: config, resources: resources, bootConfig: bootConfig)
            if setDefault {
                try await client.setDefault(id: name)
            }
            await progress("Booting…")
            _ = try await client.boot(id: name)
        } catch let e as CLIError {
            throw e
        } catch {
            throw CLIError.wrap("machine create \(name)", error)
        }
    }

    static func boot(_ id: String) async throws {
        do { _ = try await MachineClient().boot(id: id) } catch { throw CLIError.wrap("machine boot \(id)", error) }
    }

    static func stop(_ id: String) async throws {
        do { try await MachineClient().stop(id: id) } catch { throw CLIError.wrap("machine stop \(id)", error) }
    }

    static func delete(_ id: String) async throws {
        do { try await MachineClient().delete(id: id) } catch { throw CLIError.wrap("machine delete \(id)", error) }
    }

    /// Raw snapshot JSON for the Inspect tab.
    static func inspectJSON(_ id: String) async throws -> String {
        do {
            let snapshot = try await MachineClient().inspect(id: id)
            return Backend.prettyJSON(snapshot)
        } catch {
            throw CLIError.wrap("machine inspect \(id)", error)
        }
    }

    static func setDefault(_ id: String) async throws {
        do { try await MachineClient().setDefault(id: id) } catch { throw CLIError.wrap("machine set-default \(id)", error) }
    }
}