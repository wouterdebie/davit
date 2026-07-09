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
            // usage: compose plan|up [-f <file>] [--env-file <path>] [--profile <name>]... [service...]
            // plan parses + prints (no side effects); up also creates volumes/networks
            // and starts services. Without -f the file is autodiscovered like docker;
            // naming services selects them plus their depends_on closure. ${VAR}
            // interpolation reads the file's sibling .env unless --env-file overrides.
            let usage = "usage: compose plan|up [-f <file>] [--env-file <path>] [--profile <name>]... [service...]\n"
            guard args.count >= 3, args[2] == "plan" || args[2] == "up" else {
                FileHandle.standardError.write(Data(usage.utf8)); exit(2)
            }
            let sub = args[2]
            var file: String?, envFile: String?, profiles: [String] = [], serviceNames: [String] = []
            let hasFileFlag = args.contains("-f") || args.contains("--file")
            var i = 3
            while i < args.count {
                switch args[i] {
                case "-f", "--file":
                    guard i + 1 < args.count else { FileHandle.standardError.write(Data(usage.utf8)); exit(2) }
                    file = (args[i + 1] as NSString).expandingTildeInPath; i += 1
                case "--env-file":
                    guard i + 1 < args.count else { FileHandle.standardError.write(Data(usage.utf8)); exit(2) }
                    envFile = (args[i + 1] as NSString).expandingTildeInPath; i += 1
                case "--profile":
                    guard i + 1 < args.count else { FileHandle.standardError.write(Data(usage.utf8)); exit(2) }
                    profiles.append(args[i + 1]); i += 1
                default:
                    guard !args[i].hasPrefix("-") else {
                        FileHandle.standardError.write(Data("unknown flag: \(args[i])\n\(usage)".utf8)); exit(2)
                    }
                    // Legacy `compose plan|up <file>`: the first positional is the
                    // file iff no -f was given and it looks like a path; path-like
                    // but missing is a friendlier error than "no such service".
                    let expanded = (args[i] as NSString).expandingTildeInPath
                    if file == nil, serviceNames.isEmpty, !hasFileFlag,
                       args[i].contains("/") || args[i].hasSuffix(".yml") || args[i].hasSuffix(".yaml") {
                        guard FileManager.default.fileExists(atPath: expanded) else {
                            FileHandle.standardError.write(Data("compose file not found: \(args[i])\n".utf8)); exit(1)
                        }
                        file = expanded
                    } else {
                        serviceNames.append(args[i])
                    }
                }
                i += 1
            }
            // COMPOSE_PROFILES is the fallback when no --profile was given (docker v2).
            if profiles.isEmpty, let env = ProcessInfo.processInfo.environment["COMPOSE_PROFILES"] {
                profiles = env.split(separator: ",").map(String.init).filter { !$0.isEmpty }
            }
            let discovered = file == nil ? Compose.discoverFile(startingAt: FileManager.default.currentDirectoryPath) : nil
            guard let path = file ?? discovered?.path else {
                FileHandle.standardError.write(Data("no compose file found (looked for compose.yaml, compose.yml, docker-compose.yml, docker-compose.yaml in this and parent directories)\n".utf8)); exit(1)
            }
            let autodiscovered = file == nil
            let discoveryWarning = discovered?.warning
            let requested = serviceNames
            let activeProfiles = profiles
            let envFilePath = envFile
            let semaphore = DispatchSemaphore(value: 0)
            Task.detached {
                do {
                    let text = try String(contentsOfFile: path, encoding: .utf8)
                    let dir = URL(fileURLWithPath: path).deletingLastPathComponent()
                    let environment = try Compose.effectiveEnvironment(composeDir: dir.path, envFile: envFilePath)
                    let plan = try Compose.parse(
                        text: text, projectName: dir.lastPathComponent, baseDir: dir.path, environment: environment)
                        .selecting(services: requested, activeProfiles: activeProfiles)
                    if autodiscovered { print("file: \(path)") }
                    print("project: \(plan.project)")
                    for v in plan.volumes { print("volume: \(v)") }
                    for n in plan.networks { print("network: \(n)") }
                    for s in plan.services { print("service: \(s.service)\n  \(s.cliPreview)") }
                    if let w = discoveryWarning { print("warning: \(w)") }
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
                ports: ["8081:80", "127.0.0.1:9090:90/udp", "[::1]:7443:443", {target: 81, published: 8082, host_ip: 10.0.0.5}]
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
                  web.managementArgs.contains("127.0.0.1:9090:90"),
                  web.managementArgs.contains("[::1]:7443:443"),
                  web.managementArgs.contains("10.0.0.5:8082:81"),
                  web.managementArgs.contains("type=volume,source=data,target=/var/lib/web"),
                  web.managementArgs.contains("type=bind,source=/base/local,target=/mnt/here,readonly")
            else { throw CLIError(command: "selftest", message: "web management wrong: \(web.managementArgs)") }
            guard plan.volumes == ["data"] else { throw CLIError(command: "selftest", message: "volumes wrong: \(plan.volumes)") }
            guard plan.warnings.contains(where: { $0.contains("restart") }),
                  plan.warnings.contains(where: { $0.contains("only tcp") }),
                  !plan.warnings.contains(where: { $0.contains("host IP") })
            else { throw CLIError(command: "selftest", message: "warnings wrong: \(plan.warnings)") }

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

            // explicit zeros mean "unset" (engine behavior); quoted retries accepted, junk warns
            let zeroed = try Compose.parse(
                text: "services: {a: {image: x, healthcheck: {test: echo ok, interval: 0s, timeout: 0s, retries: 0}}}",
                projectName: "z")
            guard let zhc = zeroed.services[0].healthcheck,
                  zhc.interval == 30, zhc.timeout == 30, zhc.retries == 3
            else { throw CLIError(command: "selftest", message: "zero healthcheck values not defaulted: \(String(describing: zeroed.services[0].healthcheck))") }
            let quoted = try Compose.parse(
                text: "services: {a: {image: x, healthcheck: {test: echo ok, retries: \"7\"}}}", projectName: "q")
            guard quoted.services[0].healthcheck?.retries == 7 else {
                throw CLIError(command: "selftest", message: "quoted retries wrong: \(String(describing: quoted.services[0].healthcheck))")
            }
            let badRetries = try Compose.parse(
                text: "services: {a: {image: x, healthcheck: {test: echo ok, retries: seven}}}", projectName: "r")
            guard badRetries.services[0].healthcheck?.retries == 3,
                  badRetries.warnings.contains(where: { $0.contains("not an integer") })
            else { throw CLIError(command: "selftest", message: "bad retries not warned: \(badRetries.warnings)") }

            // depends_on "required: false" isn't supported — must warn, not vanish
            let optional = try Compose.parse(
                text: "services: {a: {image: x, depends_on: {b: {condition: service_started, required: false}}}, b: {image: y}}",
                projectName: "o")
            guard optional.warnings.contains(where: { $0.contains("required: false") }) else {
                throw CLIError(command: "selftest", message: "required: false not warned: \(optional.warnings)")
            }

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
            // "*" activates every profile (docker v2.24+)
            guard try plan.selecting(services: [], activeProfiles: ["*"]).services.count == 5 else {
                throw CLIError(command: "selftest", message: "--profile '*' should enable every profile")
            }
            // GUI import path: gated services drop out with a pointer at the CLI
            let gui = try ComposeImport.parseFiltered(text: yaml, projectName: "ignored", baseDir: nil)
            guard gui.services.map(\.service) == ["db", "init", "cache", "web"],
                  gui.warnings.contains(where: { $0.contains("requires profile debugging") })
            else { throw CLIError(command: "selftest", message: "GUI profile filter wrong: \(gui.services.map(\.service)) \(gui.warnings)") }
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
        await step("compose: file autodiscovery") {
            let fm = FileManager.default
            let root = fm.temporaryDirectory.appendingPathComponent("davit-selftest-discover-\(UUID().uuidString)")
            let nested = root.appendingPathComponent("sub/dir")
            try fm.createDirectory(at: nested, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: root) }
            func write(_ name: String, in dir: URL) throws {
                try "services: {}\n".write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
            }

            if let stray = Compose.discoverFile(startingAt: nested.path, environment: [:]) {
                throw CLIError(command: "selftest", message: "unexpected compose file in empty tree: \(stray.path)")
            }
            // lowest-priority candidate name, in a parent directory, is still found
            try write("docker-compose.yml", in: root)
            guard let parent = Compose.discoverFile(startingAt: nested.path, environment: [:]),
                  parent.path == root.appendingPathComponent("docker-compose.yml").path, parent.warning == nil
            else { throw CLIError(command: "selftest", message: "parent docker-compose.yml not discovered") }
            // candidate order within one directory: docker-compose.yml beats .yaml (docker parity)
            try write("docker-compose.yaml", in: root)
            guard Compose.discoverFile(startingAt: nested.path, environment: [:])?.path
                == root.appendingPathComponent("docker-compose.yml").path
            else { throw CLIError(command: "selftest", message: "docker-compose.yml should beat docker-compose.yaml") }
            // the nearest directory wins over any parent
            try write("compose.yml", in: nested)
            guard Compose.discoverFile(startingAt: nested.path, environment: [:])?.path
                == nested.appendingPathComponent("compose.yml").path
            else { throw CLIError(command: "selftest", message: "nested compose.yml should beat parent files") }
            // both compose.yaml + compose.yml → compose.yaml wins, with a warning
            try write("compose.yaml", in: nested)
            guard let both = Compose.discoverFile(startingAt: nested.path, environment: [:]),
                  both.path == nested.appendingPathComponent("compose.yaml").path,
                  both.warning?.contains("both compose.yaml and compose.yml") == true
            else { throw CLIError(command: "selftest", message: "both-yaml warning missing") }
            // COMPOSE_FILE overrides discovery: absolute, or relative to the start dir
            let absolute = root.appendingPathComponent("custom.yaml").path
            guard Compose.discoverFile(startingAt: nested.path, environment: ["COMPOSE_FILE": absolute])?.path == absolute,
                  Compose.discoverFile(startingAt: nested.path, environment: ["COMPOSE_FILE": "custom.yaml"])?.path
                      == nested.appendingPathComponent("custom.yaml").path
            else { throw CLIError(command: "selftest", message: "COMPOSE_FILE override not honored") }
        }
        await step("compose: .env + interpolation") {
            let fm = FileManager.default
            let dir = fm.temporaryDirectory.appendingPathComponent("davit-selftest-env-\(UUID().uuidString)")
            let altDir = fm.temporaryDirectory.appendingPathComponent("davit-selftest-envalt-\(UUID().uuidString)")
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try fm.createDirectory(at: altDir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: dir); try? fm.removeItem(at: altDir) }
            try """
            # dotenv fixture
            TAG=3.19
            export EXPORTED=yes
            QUOTED="q value"
            SINGLE='s value'
            EMPTY=
              SPACED  =  padded
            SHARED=dotenv
            not a key-value line
            """.write(to: dir.appendingPathComponent(".env"), atomically: true, encoding: .utf8)

            // default <dir>/.env layered under the process env — process wins
            let env = try Compose.effectiveEnvironment(
                composeDir: dir.path, processEnvironment: ["SHARED": "process", "PROC_ONLY": "1"])
            guard env["TAG"] == "3.19", env["EXPORTED"] == "yes",
                  env["QUOTED"] == "q value", env["SINGLE"] == "s value",
                  env["EMPTY"] == "", env["SPACED"] == "padded",
                  env["SHARED"] == "process", env["PROC_ONLY"] == "1"
            else { throw CLIError(command: "selftest", message: "effectiveEnvironment wrong: \(env)") }

            // absent default .env → just the process env; missing explicit file → error
            guard try Compose.effectiveEnvironment(composeDir: altDir.path, processEnvironment: ["A": "b"]) == ["A": "b"] else {
                throw CLIError(command: "selftest", message: "absent default .env should yield the process env")
            }
            do {
                _ = try Compose.effectiveEnvironment(
                    composeDir: dir.path, envFile: altDir.appendingPathComponent("nope.env").path)
                throw CLIError(command: "selftest", message: "missing explicit env file not rejected")
            } catch Compose.Error.envFileNotFound { /* expected */ }
            // --env-file replaces the default .env, it doesn't merge with it
            try "ONLY=here\n".write(to: altDir.appendingPathComponent("alt.env"), atomically: true, encoding: .utf8)
            guard try Compose.effectiveEnvironment(
                composeDir: dir.path, envFile: altDir.appendingPathComponent("alt.env").path,
                processEnvironment: [:]) == ["ONLY": "here"]
            else { throw CLIError(command: "selftest", message: "--env-file override wrong") }

            // interpolation: every string value, resolved before per-key parsing
            let yaml = """
            services:
              app:
                image: alpine:${TAG}
                environment:
                  - PLAIN=$EXPORTED
                  - CURLY=${SHARED}
                  - LITERAL=$$HOME
                  - DEF=${MISSING:-fallback}
                  - COLON_EMPTY=${EMPTY:-fell}
                  - KEEP_EMPTY=${EMPTY-kept}
                  - GONE=${MISSING}${MISSING}
                  - PROC_ONLY
                  - ABSENT_KEY
                command: ["echo", "${EMPTY:-was-empty}"]
            volumes: { $notakey: }
            """
            let plan = try Compose.parse(text: yaml, projectName: "env", environment: env)
            guard plan.services[0].image == "alpine:3.19" else {
                throw CLIError(command: "selftest", message: "image not interpolated: \(plan.services[0].image)")
            }
            guard plan.services[0].processArgs == [
                "--env", "PLAIN=yes", "--env", "CURLY=process", "--env", "LITERAL=$HOME",
                "--env", "DEF=fallback", "--env", "COLON_EMPTY=fell", "--env", "KEEP_EMPTY=",
                "--env", "GONE=", "--env", "PROC_ONLY=1",
            ] else { throw CLIError(command: "selftest", message: "env interpolation wrong: \(plan.services[0].processArgs)") }
            guard plan.services[0].commandArgs == ["echo", "was-empty"] else {
                throw CLIError(command: "selftest", message: "command not interpolated: \(plan.services[0].commandArgs)")
            }
            guard plan.volumes == ["$notakey"] else {
                throw CLIError(command: "selftest", message: "mapping keys must not be interpolated: \(plan.volumes)")
            }
            // unset plain → empty + ONE warning per variable; absent bare KEY → omitted + warning
            guard plan.warnings.filter({ $0.contains("\"MISSING\"") }).count == 1,
                  plan.warnings.contains(where: { $0.contains("ABSENT_KEY is not set — omitted") })
            else { throw CLIError(command: "selftest", message: "interpolation warnings wrong: \(plan.warnings)") }

            // :? / ? — unset (or empty with :) throws; set-but-empty without : passes
            do {
                _ = try Compose.parse(text: "services: {a: {image: \"x:${MISSING:?tag required}\"}}", projectName: "req")
                throw CLIError(command: "selftest", message: ":? unset not rejected")
            } catch Compose.Error.requiredVariable(name: "MISSING", message: "tag required") { /* expected */ }
            do {
                _ = try Compose.parse(text: "services: {a: {image: \"x${EMPTY:?must not be empty}\"}}",
                                      projectName: "req2", environment: ["EMPTY": ""])
                throw CLIError(command: "selftest", message: ":? set-but-empty not rejected")
            } catch Compose.Error.requiredVariable(name: "EMPTY", message: _) { /* expected */ }
            guard try Compose.parse(text: "services: {a: {image: \"x${EMPTY?err}y\"}}",
                                    projectName: "q", environment: ["EMPTY": ""]).services[0].image == "xy"
            else { throw CLIError(command: "selftest", message: "? should accept a set-but-empty variable") }
        }
        await step("compose: up with depends_on conditions") {
            let containers = ["davit-selftest-compose-db", "davit-selftest-compose-init",
                              "davit-selftest-compose-web", "davit-selftest-composef-bad",
                              "davit-selftest-composef-waiter", "davit-selftest-composex-dead",
                              "davit-selftest-composex-waiter"]
            func cleanup() async {
                for c in containers { try? await ContainerService.delete(c, force: true) }
                try? await ContainerService.deleteVolume("davit-selftest-composevol")
            }
            await cleanup()  // leftovers from a previous aborted run

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
            do {
                // up blocks on db's healthcheck until /ready exists — create it from
                // the outside once db is running (the fixture's readiness signal).
                var dbRunning = false
                for _ in 0..<120 {
                    if let db = try? await ContainerService.listContainers().first(where: { $0.id == "davit-selftest-compose-db" }),
                       db.isRunning { dbRunning = true; break }
                    try await Task.sleep(for: .milliseconds(500))
                }
                guard dbRunning else { throw CLIError(command: "selftest", message: "db never started") }
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

                // Fail fast: a dependency that exits mid-wait must abort the up
                // immediately, not after retries × interval of dead probes.
                let exiting = try Compose.parse(text: """
                name: davit-selftest-composex
                services:
                  dead:
                    image: alpine:latest
                    command: ["sleep", "2"]
                    healthcheck: { test: [CMD, "false"], interval: 1s, retries: 30 }
                  waiter:
                    image: alpine:latest
                    command: ["sleep", "300"]
                    depends_on:
                      dead: { condition: service_healthy }
                """, projectName: "ignored")
                do {
                    try await Compose.up(plan: exiting) { _, _ in }
                    throw CLIError(command: "selftest", message: "exited dependency did not fail up")
                } catch Compose.Error.dependencyExited(service: "dead") { /* expected */ }
            } catch {
                upTask.cancel()
                _ = try? await upTask.value
                await cleanup()
                throw error
            }
            await cleanup()
        }
        await step("compose: up recreate + reuse") {
            let names = ["davit-selftest-idem-a", "davit-selftest-idem-b"]
            func cleanup() async {
                for n in names { try? await ContainerService.delete(n, force: true) }
            }
            await cleanup()  // leftovers from a previous aborted run

            let plan = try Compose.parse(text: """
            name: davit-selftest-idem
            services:
              a:
                image: alpine:latest
                command: ["sleep", "300"]
              b:
                image: alpine:latest
                command: ["sleep", "300"]
                depends_on: [a]
            """, projectName: "ignored")
            func record(_ name: String) async throws -> ContainerRecord {
                guard let r = try await ContainerService.listContainers().first(where: { $0.id == name }) else {
                    throw CLIError(command: "selftest", message: "\(name) missing")
                }
                return r
            }
            do {
                try await Compose.up(plan: plan) { _, _ in }
                let a1 = try await record("davit-selftest-idem-a")
                let b1 = try await record("davit-selftest-idem-b")
                guard a1.isRunning, b1.isRunning else {
                    throw CLIError(command: "selftest", message: "fixture not running after first up")
                }

                // Second up reuses both running containers: no error, both service
                // steps reported done, and the creation dates prove no recreate.
                let events = ProgressLog()
                try await Compose.up(plan: plan) { events.append($0, $1) }
                let a2 = try await record("davit-selftest-idem-a")
                let b2 = try await record("davit-selftest-idem-b")
                guard a2.isRunning, b2.isRunning,
                      a2.configuration.creationDate == a1.configuration.creationDate,
                      b2.configuration.creationDate == b1.configuration.creationDate
                else { throw CLIError(command: "selftest", message: "second up did not reuse the running containers") }
                let seen = events.all
                guard seen.contains(where: { $0.0 == .service("a") && $0.1 }),
                      seen.contains(where: { $0.0 == .service("b") && $0.1 })
                else { throw CLIError(command: "selftest", message: "reusing up missing service steps: \(seen)") }

                // Stopped service → recreated; the running one stays untouched.
                // (creationDate has second resolution — sleep so a recreate can't
                // land on the same timestamp.)
                try await ContainerService.stop("davit-selftest-idem-b")
                try await Task.sleep(for: .seconds(1))
                try await Compose.up(plan: plan) { _, _ in }
                let a3 = try await record("davit-selftest-idem-a")
                let b3 = try await record("davit-selftest-idem-b")
                guard a3.isRunning, a3.configuration.creationDate == a1.configuration.creationDate else {
                    throw CLIError(command: "selftest", message: "running service was not left untouched")
                }
                guard b3.isRunning, b3.configuration.creationDate != b1.configuration.creationDate else {
                    throw CLIError(command: "selftest", message: "stopped service was not recreated")
                }

                // A stopped name-colliding container compose never created is
                // recreated cleanly too (identity is the name; no labels to check).
                await cleanup()
                try await ContainerService.runContainer(
                    image: "alpine:latest", name: "davit-selftest-idem-a",
                    processArgs: [], managementArgs: [], resourceArgs: [],
                    commandArgs: ["sleep", "300"])
                try await ContainerService.stop("davit-selftest-idem-a")
                let pre = try await record("davit-selftest-idem-a")
                try await Task.sleep(for: .seconds(1))
                try await Compose.up(plan: plan) { _, _ in }
                let a4 = try await record("davit-selftest-idem-a")
                guard a4.isRunning, a4.configuration.creationDate != pre.configuration.creationDate else {
                    throw CLIError(command: "selftest", message: "colliding stopped container was not recreated")
                }
            } catch {
                await cleanup()
                throw error
            }
            await cleanup()
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
