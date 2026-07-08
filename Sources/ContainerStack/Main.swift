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
        if args.contains(where: { $0.hasPrefix("--snapshot") || $0.hasPrefix("--probe") || $0.hasPrefix("--pose") }) {
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
        if args.count >= 3, args[1] == "login-item" {
            do {
                switch args[2] {
                case "enable": try LoginItem.setEnabled(true)
                case "disable": try LoginItem.setEnabled(false)
                default: break
                }
                print("login-item enabled: \(LoginItem.isEnabled)")
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("login-item \(args[2]) failed: \(error)\n".utf8))
                exit(1)
            }
        }
        if args.count >= 2, args[1] == "registry" {
            let sub = args.count >= 3 ? args[2] : "list"
            let semaphore = DispatchSemaphore(value: 0)
            Task.detached {
                do {
                    switch sub {
                    case "list":
                        for r in RegistryService.listLogins() { print("\(r.hostname)\t\(r.username)") }
                    case "login":
                        // usage: registry login <server> <username>   (password on stdin)
                        guard args.count >= 5 else {
                            FileHandle.standardError.write(Data("usage: registry login <server> <username> (password via stdin)\n".utf8)); exit(2)
                        }
                        let pw = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        try await RegistryService.login(server: args[3], username: args[4], password: pw)
                        print("registry login: ok")
                    case "logout":
                        guard args.count >= 4 else {
                            FileHandle.standardError.write(Data("usage: registry logout <server>\n".utf8)); exit(2)
                        }
                        try RegistryService.logout(server: args[3])
                        print("registry logout: ok")
                    default:
                        FileHandle.standardError.write(Data("unknown registry subcommand: \(sub)\n".utf8)); exit(2)
                    }
                    exit(0)
                } catch {
                    FileHandle.standardError.write(Data("registry \(sub) failed: \(error)\n".utf8)); exit(1)
                }
            }
            semaphore.wait()
            return
        }
        if args.count >= 2, args[1] == "compose" {
            // usage: compose plan <file>   (parse + print, no side effects)
            //        compose up <file>     (create volumes/networks, run services)
            guard args.count >= 4, args[2] == "plan" || args[2] == "up" else {
                FileHandle.standardError.write(Data("usage: compose plan|up <file>\n".utf8)); exit(2)
            }
            let sub = args[2]
            let path = (args[3] as NSString).expandingTildeInPath
            let semaphore = DispatchSemaphore(value: 0)
            Task.detached {
                do {
                    let text = try String(contentsOfFile: path, encoding: .utf8)
                    let dir = URL(fileURLWithPath: path).deletingLastPathComponent()
                    let plan = try Compose.parse(text: text, projectName: dir.lastPathComponent, baseDir: dir.path)
                    print("project: \(plan.project)")
                    for v in plan.volumes { print("volume: \(v)") }
                    for n in plan.networks { print("network: \(n)") }
                    for s in plan.services { print("service: \(s.service)\n  \(s.cliPreview)") }
                    for w in plan.warnings { print("warning: \(w)") }
                    if sub == "up" {
                        try await Compose.up(plan: plan) { step, done in
                            if done { print("up: \(step) done") }
                        }
                        print("compose up: ok")
                    }
                    exit(0)
                } catch {
                    let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                    FileHandle.standardError.write(Data("compose \(sub) failed: \(message)\n".utf8)); exit(1)
                }
            }
            semaphore.wait()
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
        await step("file browser: list → upload → download → delete") {
            let name = "davit-fs-test"
            try? await ContainerService.delete(name, force: true)
            try await ContainerService.runContainer(
                image: "alpine:latest", name: name,
                processArgs: [], managementArgs: [], resourceArgs: [],
                commandArgs: ["sleep", "120"])
            defer { Task { try? await ContainerService.delete(name, force: true) } }

            // list /: expect standard dirs (etc, bin, ...)
            let root = try await ContainerService.listDirectory(name, path: "/")
            guard root.contains(where: { $0.name == "etc" && $0.isDirectory }) else {
                throw CLIError(command: "selftest", message: "/ listing missing etc dir: \(root.map(\.name))")
            }
            // upload a host file into /tmp, then list it back
            let localURL = FileManager.default.temporaryDirectory.appendingPathComponent("davit-fs-\(UUID().uuidString).txt")
            try "hello from davit\n".write(to: localURL, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: localURL) }
            try await ContainerService.uploadFile(name, hostURL: localURL, toDirectory: "/tmp")
            let uploaded = localURL.lastPathComponent
            let tmp = try await ContainerService.listDirectory(name, path: "/tmp")
            guard let entry = tmp.first(where: { $0.name == uploaded }) else {
                throw CLIError(command: "selftest", message: "uploaded file not found in /tmp")
            }
            guard entry.size == 17 else {
                throw CLIError(command: "selftest", message: "wrong size after upload: \(entry.size) (want 17)")
            }
            // download it back and verify contents
            let backURL = FileManager.default.temporaryDirectory.appendingPathComponent("davit-fs-back-\(UUID().uuidString).txt")
            defer { try? FileManager.default.removeItem(at: backURL) }
            try await ContainerService.downloadFile(name, containerPath: "/tmp/\(uploaded)", to: backURL)
            let content = try String(contentsOf: backURL, encoding: .utf8)
            guard content == "hello from davit\n" else {
                throw CLIError(command: "selftest", message: "download content mismatch: \(content.debugDescription)")
            }
            // delete it inside the container
            try await ContainerService.deletePath(name, path: "/tmp/\(uploaded)")
            let after = try await ContainerService.listDirectory(name, path: "/tmp")
            guard !after.contains(where: { $0.name == uploaded }) else {
                throw CLIError(command: "selftest", message: "file still present after delete")
            }
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
        await step("compose: parse subset + ordering + cycle rejection") {
            let yaml = """
            name: davit-selftest
            services:
              web:
                image: nginx:latest
                ports: ["8081:80", "127.0.0.1:9090:90/udp"]
                environment: [MODE=x]
                depends_on: [db]
                volumes: [data:/var/lib/web, ./local:/mnt/here:ro]
                restart: always
              db:
                image: redis:alpine
                container_name: my-db
                environment: { A: "1", B: two }
                command: redis-server --appendonly yes
                mem_limit: 128m
                cpus: 1
            volumes: { data: }
            """
            let plan = try Compose.parse(text: yaml, projectName: "ignored", baseDir: "/base")
            guard plan.project == "davit-selftest" else { throw CLIError(command: "selftest", message: "project name wrong: \(plan.project)") }
            guard plan.services.map(\.service) == ["db", "web"] else {
                throw CLIError(command: "selftest", message: "depends_on order wrong: \(plan.services.map(\.service))")
            }
            let db = plan.services[0], web = plan.services[1]
            guard db.name == "my-db", web.name == "davit-selftest-web" else {
                throw CLIError(command: "selftest", message: "names wrong: \(db.name), \(web.name)")
            }
            guard db.processArgs == ["--env", "A=1", "--env", "B=two"] else {
                throw CLIError(command: "selftest", message: "env map wrong: \(db.processArgs)")
            }
            guard db.resourceArgs == ["--cpus", "1", "--memory", "128m"] else {
                throw CLIError(command: "selftest", message: "resources wrong: \(db.resourceArgs)")
            }
            guard db.commandArgs == ["redis-server", "--appendonly", "yes"] else {
                throw CLIError(command: "selftest", message: "command split wrong: \(db.commandArgs)")
            }
            guard web.managementArgs.contains("8081:80"),
                  web.managementArgs.contains("9090:90"),
                  web.managementArgs.contains("type=volume,source=data,target=/var/lib/web"),
                  web.managementArgs.contains("type=bind,source=/base/local,target=/mnt/here,readonly")
            else { throw CLIError(command: "selftest", message: "web management wrong: \(web.managementArgs)") }
            guard plan.volumes == ["data"] else { throw CLIError(command: "selftest", message: "volumes wrong: \(plan.volumes)") }
            guard plan.warnings.contains(where: { $0.contains("restart") }),
                  plan.warnings.contains(where: { $0.contains("only tcp") })
            else { throw CLIError(command: "selftest", message: "expected warnings missing: \(plan.warnings)") }

            do {
                _ = try Compose.parse(text: "services: {a: {image: x, depends_on: [b]}, b: {image: y, depends_on: [a]}}", projectName: "c")
                throw CLIError(command: "selftest", message: "cycle not rejected")
            } catch Compose.Error.dependencyCycle { /* expected */ }
        }
        await step("registry: list + reject bad credentials") {
            _ = RegistryService.listLogins()  // must not throw
            do {
                try await RegistryService.login(server: "docker.io", username: "davit-selftest-nouser", password: "definitely-invalid-\(UUID().uuidString)")
                throw CLIError(command: "selftest", message: "bad credentials were accepted")
            } catch let e as CLIError where e.command.hasPrefix("registry login") {
                // expected: authentication rejected
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
