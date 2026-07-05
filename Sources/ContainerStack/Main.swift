import AppKit
import ContainerAPIClient
import ContainerResource
import Foundation

/// Entry point. Normally launches the SwiftUI app; `davit exec <container-id>`
/// instead attaches an interactive TTY shell to a container over the XPC API —
/// this is what the "Open Terminal" .command file invokes, so no `container`
/// CLI is needed anywhere.
@main
enum Main {
    /// Held for the process lifetime in harness modes to block App Nap, which
    /// otherwise defers scene materialization for bundled apps launched from a
    /// background shell (the window never appears, the harness never runs).
    nonisolated(unsafe) static var activityToken: NSObjectProtocol?

    static func main() {
        ContainerBinary.bootstrapEnvironment()
        let args = CommandLine.arguments
        if args.contains(where: { $0.hasPrefix("--snapshot") || $0.hasPrefix("--probe") }) {
            activityToken = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled],
                reason: "headless UI harness")
        }
        if args.count >= 3, args[1] == "exec" {
            ExecMode.runBlocking(containerID: args[2])
            return
        }
        if args.count >= 2, args[1] == "selftest" {
            SelfTest.runBlocking()
            return
        }
        if args.count >= 3, args[1] == "platform", args[2] == "install" || args[2] == "remove" {
            let action = args[2]
            let semaphore = DispatchSemaphore(value: 0)
            Task.detached {
                do {
                    if action == "install" {
                        let lastDecile = Atomic(-1)
                        try await PlatformInstaller.install { stage, fraction in
                            if let fraction {
                                let decile = Int(fraction * 10)
                                if decile > lastDecile.value {
                                    lastDecile.value = decile
                                    print(stage)
                                }
                            } else {
                                print(stage)
                            }
                        }
                        print("platform install: ok — \(PlatformInstaller.managedRoot)")
                    } else {
                        try PlatformInstaller.removeManaged()
                        print("platform remove: ok")
                    }
                    exit(0)
                } catch {
                    FileHandle.standardError.write(Data("platform \(action) failed: \(error)\n".utf8))
                    exit(1)
                }
            }
            semaphore.wait()
            return
        }
        if args.count >= 3, args[1] == "update", args[2] == "check" || args[2] == "install" {
            let action = args[2]
            let semaphore = DispatchSemaphore(value: 0)
            Task.detached {
                do {
                    print("current version: \(UpdateChecker.currentVersion)")
                    guard let update = try await UpdateChecker.fetchAvailableUpdate() else {
                        print("up to date")
                        exit(0)
                    }
                    print("available: \(update.version) — \(update.downloadURL)")
                    if action == "install" {
                        try await UpdateInstaller.performInstall(update, relaunch: false) { stage, _ in
                            print(stage)
                        }
                        print("update install: ok")
                    }
                    exit(0)
                } catch {
                    FileHandle.standardError.write(Data("update \(action) failed: \(error)\n".utf8))
                    exit(1)
                }
            }
            semaphore.wait()
            return
        }
        if args.count >= 3, args[1] == "system", args[2] == "start" || args[2] == "stop" {
            let action = args[2]
            let semaphore = DispatchSemaphore(value: 0)
            Task.detached {
                do {
                    if action == "start" {
                        try await ContainerService.systemStart()
                    } else {
                        try await ContainerService.systemStop()
                    }
                    print("system \(action): ok")
                    exit(0)
                } catch {
                    FileHandle.standardError.write(Data("system \(action) failed: \(error)\n".utf8))
                    exit(1)
                }
            }
            semaphore.wait()
            return
        }
        ContainerStackApp.main()
    }
}

/// `davit selftest` — exercises the XPC-backed service layer end to end against
/// the live daemon: lists, volume create/delete, container run/stop/start/delete.
enum SelfTest {
    static func runBlocking() {
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            await run()
            semaphore.signal()
        }
        semaphore.wait()
    }

    static func run() async {
        var failures = 0
        func step(_ name: String, _ body: () async throws -> Void) async {
            do {
                try await body()
                print("PASS \(name)")
            } catch {
                failures += 1
                print("FAIL \(name): \(error)")
            }
        }

        await step("system state") {
            let state = try await ContainerService.systemState()
            guard state.isRunning else { throw CLIError(command: "selftest", message: "services not running") }
        }
        await step("list containers/images/volumes/networks/df") {
            _ = try await ContainerService.listContainers()
            _ = try await ContainerService.listImages()
            _ = try await ContainerService.listVolumes()
            _ = try await ContainerService.listNetworks()
            _ = try await ContainerService.diskUsage()
        }
        await step("volume create+delete") {
            try await ContainerService.createVolume(name: "davit-selftest-vol", size: nil)
            let names = try await ContainerService.listVolumes().map(\.name)
            guard names.contains("davit-selftest-vol") else { throw CLIError(command: "selftest", message: "volume missing after create") }
            try await ContainerService.deleteVolume("davit-selftest-vol")
        }
        await step("container run→stats→stop→start→delete") {
            try await ContainerService.runContainer(
                image: "alpine:latest",
                name: "davit-selftest",
                processArgs: ["--env", "DAVIT=1"],
                managementArgs: [],
                resourceArgs: ["--cpus", "1", "--memory", "256m"],
                commandArgs: ["sleep", "120"]
            )
            let running = try await ContainerService.listContainers().first { $0.id == "davit-selftest" }
            guard running?.isRunning == true else { throw CLIError(command: "selftest", message: "container not running after run") }
            let stats = try await ContainerService.stats(for: ["davit-selftest"])
            guard !stats.isEmpty else { throw CLIError(command: "selftest", message: "no stats") }
            try await ContainerService.stop("davit-selftest")
            try await ContainerService.start("davit-selftest")
            try await ContainerService.stop("davit-selftest")
            try await ContainerService.delete("davit-selftest", force: true)
        }
        await step("recreate prefill reconstruction") {
            try await ContainerService.runContainer(
                image: "alpine:latest",
                name: "davit-recreate-test",
                processArgs: ["--env", "FOO=bar"],
                managementArgs: [],
                resourceArgs: [],
                commandArgs: ["sleep", "99"]
            )
            guard let record = try await ContainerService.listContainers().first(where: { $0.id == "davit-recreate-test" }) else {
                throw CLIError(command: "selftest", message: "recreate-test container missing")
            }
            let prefill = await ContainerService.recreatePrefill(for: record)
            try? await ContainerService.stop("davit-recreate-test")
            try await ContainerService.delete("davit-recreate-test", force: true)
            guard prefill.commandArgs == ["sleep", "99"] else {
                throw CLIError(command: "selftest", message: "commandArgs reconstruction wrong: \(prefill.commandArgs)")
            }
            guard prefill.customEnv == ["FOO=bar"] else {
                throw CLIError(command: "selftest", message: "customEnv reconstruction wrong: \(prefill.customEnv)")
            }
        }
        await step("config store round-trip") {
            let snap = try await SystemConfigStore.load()
            var edited = snap.effective
            edited["dns", default: [:]]["domain"] = "davit-selftest.test"
            try await SystemConfigStore.save(edited: edited, defaults: snap.defaults)

            let reloaded = try await SystemConfigStore.load()
            guard reloaded.effective["dns"]?["domain"] as? String == "davit-selftest.test" else {
                throw CLIError(command: "selftest", message: "saved override not visible after reload")
            }
            // Revert: saving pure effective==defaults removes the override file again.
            var reverted = reloaded.effective
            reverted["dns"]?["domain"] = NSNull()
            try await SystemConfigStore.save(edited: reverted, defaults: reloaded.defaults)
            let final = try await SystemConfigStore.load()
            guard final.effective["dns"]?["domain"] == nil || final.effective["dns"]?["domain"] is NSNull else {
                throw CLIError(command: "selftest", message: "override not removed on revert")
            }
        }
        await step("inspect container JSON") {
            guard let first = try await ContainerService.listContainers().first else { return }
            let json = try await ContainerService.inspectRaw("container", first.id)
            guard json.contains("\"id\"") else { throw CLIError(command: "selftest", message: "bad inspect output") }
        }

        print(failures == 0 ? "SELFTEST OK" : "SELFTEST FAILED (\(failures))")
        exit(failures == 0 ? 0 : 1)
    }
}

/// Tiny lock-protected box for progress dedup in headless installs.
final class Atomic: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Int
    init(_ value: Int) { _value = value }
    var value: Int {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); defer { lock.unlock() }; _value = newValue }
    }
}

enum ExecMode {
    static func runBlocking(containerID: String) {
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            await run(containerID: containerID)
            semaphore.signal()
        }
        semaphore.wait()
    }

    static func run(containerID: String) async {
        do {
            let client = ContainerClient()
            let container = try await client.get(id: containerID)
            guard container.status == .running else {
                FileHandle.standardError.write(Data("container \(containerID) is not running\n".utf8))
                exit(1)
            }

            // Base the exec process on the container's init process (env, user, cwd),
            // the same way `container exec` does.
            var config = container.configuration.initProcess
            config.executable = "/bin/sh"
            config.arguments = ["-c", "command -v bash >/dev/null 2>&1 && exec bash || exec sh"]
            config.terminal = true
            config.environment.append("TERM=xterm-256color")

            let io = try ProcessIO.create(tty: true, interactive: true, detach: false)
            defer { try? io.close() }

            let process = try await client.createProcess(
                containerId: containerID,
                processId: UUID().uuidString.lowercased(),
                configuration: config,
                stdio: io.stdio
            )
            let code = try await io.handleProcess(process: process, log: Backend.log)
            exit(code)
        } catch {
            FileHandle.standardError.write(Data("exec failed: \(error)\n".utf8))
            exit(1)
        }
    }
}
