import ContainerAPIClient
import ContainerCommands
import ContainerPersistence
import ContainerResource
import ContainerizationOS
import Foundation
import MachineAPIClient
import SystemPackage

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
            // container 1.3 replaced Utility.validEntityName (throwing) with
            // ManagedContainer.nameValid (Bool).
            guard ManagedContainer.nameValid(name) else {
                throw CLIError(command: "machine create", message: "\"\(name)\" is not a valid machine name (letters, digits, and . _ - only)")
            }
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

    /// Update boot config (`container machine set`); takes effect after the
    /// machine is stopped and booted again.
    static func setConfig(_ id: String, cpus: Int?, memory: String?, homeMount: String?) async throws {
        do {
            let snapshot = try await MachineClient().inspect(id: id)
            let updated = try snapshot.bootConfig.with(
                [
                    "cpus": cpus.map { "\($0)" },
                    "memory": memory?.isEmpty == true ? nil : memory,
                    "home-mount": homeMount,
                ].compactMapValues { $0 })
            try await MachineClient().setConfig(id: id, bootConfig: updated)
        } catch {
            throw CLIError.wrap("machine set \(id)", error)
        }
    }

    /// Interactive login shell into a machine over the XPC API — the same
    /// process `container machine run -n <id>` creates: the machine-init
    /// binary with `-s` resolves the provisioned user's login shell.
    static func execShell(machineID: String) async throws -> Int32 {
        let client = MachineClient()
        var snapshot = try await client.inspect(id: machineID)
        if snapshot.status.rawValue != "running" {
            snapshot = try await client.boot(id: machineID)
        }
        guard let containerId = snapshot.containerId else {
            throw CLIError(command: "machine exec \(machineID)", message: "machine has no backing container")
        }

        let executablePath = FilePath("/\(MachineBundle.sbinDirectory)").appending(MachineBundle.initFile).string
        // Mirror MachineRun's cwd logic: land in the mounted home when we can.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let cwd: String
        if snapshot.bootConfig.homeMount != .none, FileManager.default.currentDirectoryPath.hasPrefix(home) {
            cwd = FileManager.default.currentDirectoryPath
        } else {
            cwd = snapshot.configuration.home
        }

        let config = ProcessConfiguration(
            executable: executablePath,
            arguments: ["-s"],
            environment: [
                "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
                "TERM=xterm-256color",
            ],
            workingDirectory: cwd,
            terminal: true,
            user: snapshot.configuration.user,
            supplementalGroups: []
        )
        let io = try ProcessIO.create(tty: true, interactive: true, detach: false)
        defer { try? io.close() }
        let process = try await ContainerClient().createProcess(
            containerId: containerId,
            processId: UUID().uuidString.lowercased(),
            configuration: config,
            stdio: io.stdio
        )
        return try await io.handleProcess(process: process, log: Backend.log)
    }

    static func setDefault(_ id: String) async throws {
        do { try await MachineClient().setDefault(id: id) } catch { throw CLIError.wrap("machine set-default \(id)", error) }
    }
}