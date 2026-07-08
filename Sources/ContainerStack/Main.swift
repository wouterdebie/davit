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
        if args.count >= 3, args[1] == "stats" {
            // debug: raw stats samples for any container id (incl. machine backings)
            let id = args[2]
            let semaphore = DispatchSemaphore(value: 0)
            Task.detached {
                for _ in 0..<3 {
                    if let record = try? await ContainerService.stats(for: [id]).first {
                        print("cpuUsec=\(record.cpuUsageUsec.map(String.init) ?? "nil") mem=\(record.memoryUsageBytes.map(String.init) ?? "nil") limit=\(record.memoryLimitBytes.map(String.init) ?? "nil") rx=\(record.networkRxBytes.map(String.init) ?? "nil") tx=\(record.networkTxBytes.map(String.init) ?? "nil") blockR=\(record.blockReadBytes.map(String.init) ?? "nil") blockW=\(record.blockWriteBytes.map(String.init) ?? "nil") pids=\(record.numProcesses.map(String.init) ?? "nil")")
                    } else {
                        print("no stats for \(id)")
                    }
                    try? await Task.sleep(for: .seconds(2))
                }
                exit(0)
            }
            semaphore.wait()
            return
        }
        if args.count >= 3, args[1] == "pull" {
            let reference = args[2]
            let semaphore = DispatchSemaphore(value: 0)
            Task.detached {
                do {
                    try await ContainerService.pullImage(reference) { _ in }
                    print("pull: ok — \(reference)")
                    exit(0)
                } catch {
                    let message = (error as? CLIError)?.message ?? String(describing: error)
                    FileHandle.standardError.write(Data("pull failed: \(message)\n".utf8)); exit(1)
                }
            }
            semaphore.wait()
            return
        }
        if args.count >= 2, args[1] == "machine" {
            // usage: machine list | machine create <image> <name> | machine stop|boot|delete <name>
            let sub = args.count >= 3 ? args[2] : "list"
            if sub == "exec" {
                guard args.count >= 4 else {
                    FileHandle.standardError.write(Data("usage: machine exec <name>\n".utf8)); exit(2)
                }
                let semaphore = DispatchSemaphore(value: 0)
                Task.detached {
                    do {
                        let code = try await MachineService.execShell(machineID: args[3])
                        exit(code)
                    } catch {
                        let message = (error as? CLIError)?.message ?? String(describing: error)
                        FileHandle.standardError.write(Data("machine exec failed: \(message)\n".utf8)); exit(1)
                    }
                }
                semaphore.wait()
                return
            }
            let semaphore = DispatchSemaphore(value: 0)
            Task.detached {
                do {
                    switch sub {
                    case "list":
                        for m in try await MachineService.list() {
                            print("\(m.id)\t\(m.statusRaw)\t\(m.imageReference)\t\(m.ipAddress ?? "-")\t\(m.cpus)cpu\t\(m.isDefault ? "default" : "")")
                        }
                    case "create":
                        guard args.count >= 5 else {
                            FileHandle.standardError.write(Data("usage: machine create <image> <name>\n".utf8)); exit(2)
                        }
                        try await MachineService.create(
                            image: args[3], name: args[4], cpus: nil, memory: nil,
                            setDefault: false, progress: { print($0) })
                        print("machine create: ok")
                    case "set":
                        // machine set <name> [cpus=N] [memory=SIZE] [home-mount=rw|ro|none]
                        guard args.count >= 5 else {
                            FileHandle.standardError.write(Data("usage: machine set <name> key=value...\n".utf8)); exit(2)
                        }
                        var cpus: Int?, memory: String?, homeMount: String?
                        for kv in args[4...] {
                            let parts = kv.split(separator: "=", maxSplits: 1).map(String.init)
                            guard parts.count == 2 else { continue }
                            switch parts[0] {
                            case "cpus": cpus = Int(parts[1])
                            case "memory": memory = parts[1]
                            case "home-mount": homeMount = parts[1]
                            default: break
                            }
                        }
                        try await MachineService.setConfig(args[3], cpus: cpus, memory: memory, homeMount: homeMount)
                        print("machine set: ok")
                    case "boot", "stop", "delete":
                        guard args.count >= 4 else {
                            FileHandle.standardError.write(Data("usage: machine \(sub) <name>\n".utf8)); exit(2)
                        }
                        switch sub {
                        case "boot": try await MachineService.boot(args[3])
                        case "stop": try await MachineService.stop(args[3])
                        default: try await MachineService.delete(args[3])
                        }
                        print("machine \(sub): ok")
                    default:
                        FileHandle.standardError.write(Data("unknown machine subcommand: \(sub)\n".utf8)); exit(2)
                    }
                    exit(0)
                } catch {
                    let message = (error as? CLIError)?.message ?? String(describing: error)
                    FileHandle.standardError.write(Data("machine \(sub) failed: \(message)\n".utf8)); exit(1)
                }
            }
            semaphore.wait()
            return
        }
        if args.count >= 2, args[1] == "build" {
            // usage: build -t <tag> [-f <dockerfile>] [--no-cache] <context-dir>
            var tag: String?, file: String?, noCache = false, context: String?
            var i = 2
            while i < args.count {
                switch args[i] {
                case "-t", "--tag": if i + 1 < args.count { tag = args[i + 1]; i += 1 }
                case "-f", "--file": if i + 1 < args.count { file = args[i + 1]; i += 1 }
                case "--no-cache": noCache = true
                default: context = args[i]
                }
                i += 1
            }
            guard let tag, let context else {
                FileHandle.standardError.write(Data("usage: build -t <tag> [-f <dockerfile>] [--no-cache] <context-dir>\n".utf8)); exit(2)
            }
            let contextDir = (context as NSString).expandingTildeInPath
            let dockerfile = file.map { ($0 as NSString).expandingTildeInPath } ?? "\(contextDir)/Dockerfile"
            let request = BuildService.Request(
                contextDir: contextDir, dockerfilePath: dockerfile, tag: tag, noCache: noCache)
            let semaphore = DispatchSemaphore(value: 0)
            Task.detached {
                do {
                    let image = try await BuildService.build(request) { print($0) }
                    print("build: ok — \(image)")
                    exit(0)
                } catch {
                    let message = (error as? CLIError)?.message ?? String(describing: error)
                    FileHandle.standardError.write(Data("build failed: \(message)\n".utf8)); exit(1)
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
                            if done { print("up: \(step.label) done") }
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
        await step("compose: profiles + healthchecks + depends_on conditions + selection") {
            let yaml = """
            name: sel
            services:
              web:
                image: nginx
                depends_on:
                  db: { condition: service_healthy }
                  init: { condition: service_completed_successfully }
                volumes: [webdata:/data]
                networks: [front]
              db:
                image: postgres
                healthcheck:
                  test: ["CMD", "pg_isready", "-q"]
                  interval: 1m30s
                  timeout: 500ms
                  retries: 5
                  start_period: 10s
                volumes: [dbdata:/var/lib/db]
                networks: [back]
              init:
                image: alpine
                healthcheck: { disable: true }
              cache:
                image: redis
                healthcheck: { test: [NONE] }
                depends_on:
                  db: { condition: service_wobbly }
              debug:
                image: busybox
                profiles: [debugging]
                depends_on: [cache]
            volumes: { webdata: , dbdata: , unused: }
            networks: { front: , back: , spare: }
            """
            let plan = try Compose.parse(text: yaml, projectName: "ignored")
            guard plan.services.map(\.service) == ["db", "init", "cache", "web", "debug"] else {
                throw CLIError(command: "selftest", message: "topo order wrong: \(plan.services.map(\.service))")
            }
            let db = plan.services[0], cache = plan.services[2], web = plan.services[3], debug = plan.services[4]
            guard web.dependsOn == ["db": .healthy, "init": .completedSuccessfully] else {
                throw CLIError(command: "selftest", message: "conditions wrong: \(web.dependsOn)")
            }
            guard cache.dependsOn == ["db": .started],
                  plan.warnings.contains(where: { $0.contains("service_wobbly") })
            else { throw CLIError(command: "selftest", message: "unknown condition not downgraded: \(cache.dependsOn) \(plan.warnings)") }
            guard let hc = db.healthcheck, hc.argv == ["pg_isready", "-q"], !hc.shellForm,
                  hc.interval == 90, hc.timeout == 0.5, hc.retries == 5, hc.startPeriod == 10
            else { throw CLIError(command: "selftest", message: "healthcheck wrong: \(String(describing: db.healthcheck))") }
            guard plan.services[1].healthcheck == nil, cache.healthcheck == nil,
                  !plan.warnings.contains(where: { $0.contains("healthcheck") })
            else { throw CLIError(command: "selftest", message: "disable/NONE should be nil and silent: \(plan.warnings)") }
            guard debug.profiles == ["debugging"] else {
                throw CLIError(command: "selftest", message: "profiles wrong: \(debug.profiles)")
            }

            // string test → shell form; docker defaults; bad duration falls back with a warning
            let defaulted = try Compose.parse(
                text: "services: {a: {image: x, healthcheck: {test: echo ok, interval: nope}}}", projectName: "d")
            guard let ahc = defaulted.services[0].healthcheck, ahc.shellForm,
                  ahc.argv == ["/bin/sh", "-c", "echo ok"],
                  ahc.interval == 30, ahc.timeout == 30, ahc.retries == 3, ahc.startPeriod == 0,
                  defaulted.warnings.contains(where: { $0.contains("not a duration") })
            else { throw CLIError(command: "selftest", message: "healthcheck defaults wrong: \(String(describing: defaulted.services[0].healthcheck)) \(defaulted.warnings)") }

            // selection: dependency closure in start order, volumes/networks pruned
            let sel = try plan.selecting(services: ["web"], activeProfiles: [])
            guard sel.services.map(\.service) == ["db", "init", "web"],
                  sel.volumes == ["dbdata", "webdata"], sel.networks == ["back", "front"]
            else { throw CLIError(command: "selftest", message: "selection wrong: \(sel.services.map(\.service)) \(sel.volumes) \(sel.networks)") }
            // empty selection = all enabled; profile-gated debug drops out, unreferenced volume pruned
            let all = try plan.selecting(services: [], activeProfiles: [])
            guard all.services.map(\.service) == ["db", "init", "cache", "web"], !all.volumes.contains("unused") else {
                throw CLIError(command: "selftest", message: "profile filter wrong: \(all.services.map(\.service)) \(all.volumes)")
            }
            guard try plan.selecting(services: [], activeProfiles: ["debugging"]).services.count == 5 else {
                throw CLIError(command: "selftest", message: "--profile debugging should enable debug")
            }
            // naming a gated service auto-activates its own profile
            let named = try plan.selecting(services: ["debug"], activeProfiles: [])
            guard named.services.map(\.service) == ["db", "cache", "debug"] else {
                throw CLIError(command: "selftest", message: "auto-activation wrong: \(named.services.map(\.service))")
            }

            do {
                _ = try plan.selecting(services: ["nope"], activeProfiles: [])
                throw CLIError(command: "selftest", message: "unknown service not rejected")
            } catch Compose.Error.noSuchService("nope") { /* expected */ }
            do {
                _ = try Compose.parse(
                    text: "services: {a: {image: x, depends_on: {b: {condition: service_healthy}}}, b: {image: y}}",
                    projectName: "m")
                throw CLIError(command: "selftest", message: "missing healthcheck not rejected")
            } catch Compose.Error.missingHealthcheck(service: "a", dependency: "b") { /* expected */ }
            let gated = try Compose.parse(
                text: "services: {a: {image: x, depends_on: [g]}, g: {image: y, profiles: [p]}}", projectName: "g")
            do {
                _ = try gated.selecting(services: ["a"], activeProfiles: [])
                throw CLIError(command: "selftest", message: "inactive-profile dependency not rejected")
            } catch Compose.Error.inactiveProfile(service: "g", profile: "p") { /* expected */ }
            guard try gated.selecting(services: ["a"], activeProfiles: ["p"]).services.map(\.service) == ["g", "a"] else {
                throw CLIError(command: "selftest", message: "--profile p should unlock the gated dependency")
            }
        }
        await step("compose: up with depends_on conditions") {
            let containers = ["davit-selftest-compose-db", "davit-selftest-compose-init",
                              "davit-selftest-compose-web", "davit-selftest-composef-bad",
                              "davit-selftest-composef-waiter"]
            for c in containers { try? await ContainerService.delete(c, force: true) }
            try? await ContainerService.deleteVolume("davit-selftest-composevol")
            defer {
                Task {
                    for c in containers { try? await ContainerService.delete(c, force: true) }
                    try? await ContainerService.deleteVolume("davit-selftest-composevol")
                }
            }

            let yaml = """
            name: davit-selftest-compose
            services:
              db:
                image: alpine:latest
                command: ["sleep", "300"]
                volumes: [davit-selftest-composevol:/data]
                healthcheck: { test: [CMD-SHELL, test -f /ready], interval: 1s, retries: 20 }
              init:
                image: alpine:latest
                command: ["true"]
              web:
                image: alpine:latest
                command: ["sleep", "300"]
                depends_on:
                  db: { condition: service_healthy }
                  init: { condition: service_completed_successfully }
            volumes: { davit-selftest-composevol: }
            """
            let plan = try Compose.parse(text: yaml, projectName: "ignored")
            let events = ProgressLog()
            let upTask = Task { try await Compose.up(plan: plan) { events.append($0, $1) } }

            // up blocks on db's healthcheck until /ready exists — create it from
            // the outside once db is running (the fixture's readiness signal).
            var dbRunning = false
            for _ in 0..<120 {
                if let db = try? await ContainerService.listContainers().first(where: { $0.id == "davit-selftest-compose-db" }),
                   db.isRunning { dbRunning = true; break }
                try await Task.sleep(for: .milliseconds(500))
            }
            guard dbRunning else {
                upTask.cancel()
                throw CLIError(command: "selftest", message: "db never started")
            }
            _ = try await ContainerService.exec("davit-selftest-compose-db", ["touch", "/ready"])
            try await upTask.value

            let web = try await ContainerService.listContainers().first { $0.id == "davit-selftest-compose-web" }
            guard web?.isRunning == true else { throw CLIError(command: "selftest", message: "web not running after up") }
            let seen = events.all
            func index(_ step: Compose.StepKind, _ done: Bool) -> Int? {
                seen.firstIndex { $0.0 == step && $0.1 == done }
            }
            guard let dbHealthy = index(.waiting(service: "db", condition: "service_healthy"), true),
                  let initDone = index(.waiting(service: "init", condition: "service_completed_successfully"), true),
                  let webStart = index(.service("web"), false),
                  dbHealthy < webStart, initDone < webStart
            else { throw CLIError(command: "selftest", message: "waiting steps missing or out of order: \(seen)") }

            // Failure path: a probe that never succeeds must fail the dependent's up.
            let failing = try Compose.parse(text: """
            name: davit-selftest-composef
            services:
              bad:
                image: alpine:latest
                command: ["sleep", "300"]
                healthcheck: { test: [CMD, "false"], interval: 1s, retries: 2 }
              waiter:
                image: alpine:latest
                command: ["sleep", "300"]
                depends_on:
                  bad: { condition: service_healthy }
            """, projectName: "ignored")
            do {
                try await Compose.up(plan: failing) { _, _ in }
                throw CLIError(command: "selftest", message: "unhealthy dependency did not fail up")
            } catch Compose.Error.unhealthy(service: "bad", failures: _) { /* expected */ }
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

/// Lock-protected accumulator of compose progress events for the selftest.
/// (File scope on purpose: declaring it inside the step closure trips a bogus
/// "will never be executed" SIL diagnostic elsewhere in the file.)
final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(Compose.StepKind, Bool)] = []
    func append(_ step: Compose.StepKind, _ done: Bool) { lock.lock(); items.append((step, done)); lock.unlock() }
    var all: [(Compose.StepKind, Bool)] { lock.lock(); defer { lock.unlock() }; return items }
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
