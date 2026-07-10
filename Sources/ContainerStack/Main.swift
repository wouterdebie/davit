import AppKit
import ContainerAPIClient
import ContainerResource
import Foundation
import Logging

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
            // `exec <id>` opens a shell; `exec <id> <command...>` runs that.
            ExecMode.runBlocking(
                containerID: args[2],
                argv: args.count > 3 ? Array(args.dropFirst(3)) : nil)
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
        if args.count >= 2, args[1] == "run" {
            // docker-style single-container run — RunCLI below.
            RunCLI.run(Array(args.dropFirst(2)))
            return
        }
        if args.count >= 2, args[1] == "compose" {
            // Shared parse + dispatch for every compose subcommand — ComposeCLI below.
            ComposeCLI.run(Array(args.dropFirst(2)))
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

/// stdout verbosity for one CLI invocation (compose decision 4 / plan I4b,
/// reused by `davit run` / I6). `quiet` suppresses warnings and step/progress
/// lines but never the final stderr error each mode's `run()` writes on
/// failure; `verbose` adds diagnostics that are otherwise silent. GUI code
/// never touches this — it calls Compose's functions directly with their
/// default (no-op) diagnostic sinks.
enum CLIOutputLevel { case quiet, normal, verbose }

struct CLIOutput {
    let level: CLIOutputLevel
    func say(_ s: String) { if level != .quiet { print(s) } }
    func warn(_ s: String) { if level != .quiet { print("warning: \(s)") } }
    func verbose(_ s: String) { if level == .verbose { print(s) } }
    /// Like `say` but without an added newline — pull's streamed lines carry their own.
    func sayRaw(_ s: String) { if level != .quiet { print(s, terminator: "") } }
    /// Like `say`/`warn` but to stderr — for status/banner lines a caller
    /// whose stdout is reserved for something else (`davit run`'s attached
    /// container log stream) must never mix into that stream.
    func sayErr(_ s: String) { if level != .quiet { FileHandle.standardError.write(Data((s + "\n").utf8)) } }
    func warnErr(_ s: String) { if level != .quiet { FileHandle.standardError.write(Data("warning: \(s)\n".utf8)) } }
}

/// `davit compose <sub>` — shared CLI plumbing for every compose subcommand
/// (plan decision 12): one argv parser covering the common flags, per-
/// subcommand extras, and the file-vs-service positional rule, plus the
/// autodiscovery and .env handling, all in one place. Without a file the
/// compose file is autodiscovered like docker; naming services scopes the
/// command; ${VAR} interpolation reads the file's sibling .env unless
/// --env-file overrides. Usage problems exit 2, runtime failures exit 1.
enum ComposeCLI {
    static let usage = """
    usage: compose <subcommand> [-f <file>] [--env-file <path>] [--profile <name>]... [--verbose|-q|--quiet] [service...]
      subcommands: plan | up [-d|--detach] [--down-on-failure] | down [-v|--volumes] | ps
                   logs [-f|--follow] [--tail <n>] | stop | start | restart | pull
                   exec <service> <command...>
    """

    struct Invocation {
        var subcommand: String
        var file: String? = nil
        var envFile: String? = nil
        var profiles: [String] = []
        var flags: Set<String> = []      // canonical bool flags: "detach", "volumes", "follow", "verbose", "quiet"
        var counts: [String: Int] = [:]  // canonical int flags: "tail"
        var services: [String] = []
        var command: [String] = []       // exec only: everything after the service
    }

    private static let subcommands: Set<String> = [
        "plan", "up", "down", "ps", "logs", "stop", "start", "restart", "pull", "exec",
    ]

    /// Per-subcommand flags, token → canonical name. These shadow the shared
    /// flags: for `logs`, -f means --follow, so its file flag is `--file` only.
    private static let boolFlags: [String: [String: String]] = [
        "up": ["-d": "detach", "--detach": "detach", "--down-on-failure": "down-on-failure"],
        "down": ["-v": "volumes", "--volumes": "volumes"],
        "logs": ["-f": "follow", "--follow": "follow"],
    ]
    private static let intFlags: [String: [String: String]] = [
        "logs": ["--tail": "tail"]
    ]

    /// args = everything after "compose". Exits on usage errors (2, naming the
    /// offending token) and on a path-like positional that doesn't exist (1) —
    /// runs before any async work. Flags take their value as the next token or
    /// inline (`--tail=5`); `--tail all` is docker's spelling for unlimited.
    static func parse(_ args: [String]) -> Invocation {
        func usageExit(_ message: String? = nil) -> Never {
            let prefix = message.map { $0 + "\n" } ?? ""
            FileHandle.standardError.write(Data((prefix + usage + "\n").utf8)); exit(2)
        }
        guard let sub = args.first else { usageExit() }
        guard subcommands.contains(sub) else { usageExit("unknown subcommand: \(sub)") }
        var inv = Invocation(subcommand: sub)
        let bools = boolFlags[sub] ?? [:]
        let ints = intFlags[sub] ?? [:]
        let fileTokens = ["-f", "--file"].filter { bools[$0] == nil && ints[$0] == nil }
        // The file flag may follow a positional (`up web -f x.yml`), so the
        // positional rule below needs to know about it up front.
        let hasFileFlag = args.contains { a in
            fileTokens.contains(a) || fileTokens.contains(where: { a.hasPrefix($0 + "=") })
        }
        var i = 1
        while i < args.count {
            let raw = args[i]
            // --flag=value spelling: split for the flag matching below; the
            // positional branches keep using the untouched token.
            var arg = raw
            var inline: String? = nil
            if raw.hasPrefix("--"), let eq = raw.firstIndex(of: "=") {
                arg = String(raw[..<eq])
                inline = String(raw[raw.index(after: eq)...])
            }
            func value() -> String {
                if let v = inline { return v }
                guard i + 1 < args.count else { usageExit("flag \(arg) needs a value") }
                i += 1
                return args[i]
            }
            if let name = bools[arg] {
                guard inline == nil else { usageExit("flag \(arg) takes no value") }
                inv.flags.insert(name)
            } else if let name = ints[arg] {
                let v = value()
                if v == "all" {
                    inv.counts[name] = nil  // docker's explicit default — unlimited
                } else if let n = Int(v) {
                    inv.counts[name] = n
                } else {
                    usageExit("invalid \(arg) value: \(v)")
                }
            } else if fileTokens.contains(arg) {
                inv.file = (value() as NSString).expandingTildeInPath
            } else if arg == "--env-file" {
                inv.envFile = (value() as NSString).expandingTildeInPath
            } else if arg == "--profile" {
                inv.profiles.append(value())
            } else if arg == "--verbose" {
                guard inline == nil else { usageExit("flag \(arg) takes no value") }
                inv.flags.insert("verbose")
            } else if arg == "-q" || arg == "--quiet" {
                guard inline == nil else { usageExit("flag \(arg) takes no value") }
                inv.flags.insert("quiet")
            } else if raw.hasPrefix("-") {
                usageExit("unknown flag: \(raw)")
            } else if sub == "exec" {
                // exec grammar: the first positional is the service, everything
                // after it is the command verbatim — a later `-f` belongs to
                // the command, not to us (docker parity; no legacy file
                // positional here, exec is new).
                inv.services.append(arg)
                inv.command = Array(args[(i + 1)...])
                break
            } else {
                // Legacy `compose <sub> <file>`: the first positional is the
                // file iff no file flag was given and it looks like a path;
                // path-like but missing is a friendlier error than "no such
                // service".
                let expanded = (arg as NSString).expandingTildeInPath
                if inv.file == nil, inv.services.isEmpty, !hasFileFlag,
                   arg.contains("/") || arg.hasSuffix(".yml") || arg.hasSuffix(".yaml") {
                    guard FileManager.default.fileExists(atPath: expanded) else {
                        FileHandle.standardError.write(Data("compose file not found: \(arg)\n".utf8)); exit(1)
                    }
                    inv.file = expanded
                } else {
                    inv.services.append(arg)
                }
            }
            i += 1
        }
        if sub == "exec", inv.services.count != 1 || inv.command.isEmpty {
            usageExit("exec needs a service and a command")
        }
        if inv.flags.contains("verbose"), inv.flags.contains("quiet") {
            usageExit("--verbose and -q/--quiet are mutually exclusive")
        }
        // COMPOSE_PROFILES is the fallback when no --profile was given (docker v2).
        if inv.profiles.isEmpty, let env = ProcessInfo.processInfo.environment["COMPOSE_PROFILES"] {
            inv.profiles = env.split(separator: ",").map(String.init).filter { !$0.isEmpty }
        }
        return inv
    }

    static func run(_ args: [String]) {
        let inv = parse(args)
        let output = CLIOutput(level:
            inv.flags.contains("verbose") ? .verbose : (inv.flags.contains("quiet") ? .quiet : .normal))
        if output.level == .verbose, !LoggingConfig.explicitlySet {
            LoggingConfig.level = .debug
        }
        let discovered = inv.file == nil
            ? Compose.discoverFile(startingAt: FileManager.default.currentDirectoryPath) : nil
        guard let path = inv.file ?? discovered?.path else {
            FileHandle.standardError.write(Data("no compose file found (looked for compose.yaml, compose.yml, docker-compose.yml, docker-compose.yaml in this and parent directories)\n".utf8)); exit(1)
        }
        let autodiscovered = inv.file == nil
        let discoveryWarning = discovered?.warning
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                let text = try String(contentsOfFile: path, encoding: .utf8)
                let dir = URL(fileURLWithPath: path).deletingLastPathComponent()
                let (environment, envWarnings) = try Compose.effectiveEnvironment(composeDir: dir.path, envFile: inv.envFile)
                for w in envWarnings { output.warn(w) }
                let parsed = try Compose.parse(
                    text: text, projectName: dir.lastPathComponent, baseDir: dir.path, environment: environment)
                // file/project for the subcommands that don't already show them
                // as part of their own output (plan/up handle it inline below).
                func verboseHeader() {
                    output.verbose("file: \(path)")
                    output.verbose("project: \(parsed.project)")
                }
                switch inv.subcommand {
                case "plan", "up":
                    let plan = try parsed.selecting(services: inv.services, activeProfiles: inv.profiles)
                    // plan shows its listing at normal/verbose (that IS the command,
                    // --quiet aside); up only echoes it under --verbose (design I4b:
                    // "up echoes on verbose") — the equivalent `container run` lines
                    // it's followed by are noisy on every routine `up` otherwise.
                    let showPreview = inv.subcommand == "plan" || output.level == .verbose
                    if showPreview {
                        if autodiscovered || output.level == .verbose { output.say("file: \(path)") }
                        output.say("project: \(plan.project)")
                        for v in plan.volumes { output.say("volume: \(v)") }
                        for n in plan.networks { output.say("network: \(n)") }
                        for s in plan.services { output.say("service: \(s.service)\n  \(s.cliPreview)") }
                    }
                    if let w = discoveryWarning { output.warn(w) }
                    for w in plan.warnings { output.warn(w) }
                    if inv.subcommand == "up" {
                        let up: (warnings: [String], reused: Set<String>)
                        let touched = TouchedServices()
                        let createdNetworks = TouchedServices()
                        do {
                            up = try await Compose.up(
                                plan: plan,
                                diagnostic: { output.verbose($0) },
                                onServiceTouched: { touched.insert($0) },
                                onNetworkCreated: { createdNetworks.insert($0) }
                            ) { step, done in
                                if done { output.say("up: \(step.label) done") }
                            }
                        } catch {
                            if inv.flags.contains("down-on-failure") {
                                output.say("up failed — tearing down (--down-on-failure)")
                                // Network/volume full-vs-partial gating is scoped the
                                // same way the up itself was: a whole-project up (no
                                // services named) tears the whole project down
                                // (network/volumes per down's own full-teardown
                                // rule); a service-scoped up leaves networks/volumes
                                // alone. Either way, the actual CONTAINERS torn down
                                // are limited to what THIS up run touched — plan.services
                                // includes already-running services this up reused
                                // untouched, and those must survive the teardown.
                                let teardown = inv.services.isEmpty ? [] : plan.services.map(\.service)
                                do {
                                    let warnings = try await Compose.down(
                                        plan: plan, services: teardown, removeVolumes: false,
                                        limitContainersTo: touched.all,
                                        limitNetworksTo: createdNetworks.all,
                                        diagnostic: { output.verbose($0) }
                                    ) { _, _ in }
                                    for w in warnings { output.warn(w) }
                                    // Surviving reused services may hold hosts
                                    // entries for torn-down containers; re-sync.
                                    for w in await Compose.syncProjectHosts(plan: plan) { output.warn(w) }
                                } catch let teardownError {
                                    let detail = (teardownError as? LocalizedError)?.errorDescription
                                        ?? String(describing: teardownError)
                                    FileHandle.standardError.write(Data("teardown after failed up did not complete cleanly (\(detail))\n".utf8))
                                }
                            }
                            throw error
                        }
                        for w in up.warnings { output.warn(w) }
                        output.say("compose up: ok")
                        if !inv.flags.contains("detach") {
                            // docker-compose behavior: a non-detached up stays
                            // attached to the selected services' logs — reused
                            // containers from now on only, so old runs' output
                            // doesn't replay.
                            output.say("Attaching to logs (Ctrl-C detaches; containers keep running)")
                            try await Compose.logs(plan: plan, skipBacklogFor: up.reused, follow: true)
                        }
                    }
                case "down":
                    verboseHeader()
                    // The whole file, every profile active: teardown must not
                    // strand profile-gated containers (decision 13).
                    let warnings = try await Compose.down(
                        plan: parsed, services: inv.services,
                        removeVolumes: inv.flags.contains("volumes"),
                        diagnostic: { output.verbose($0) }
                    ) { step, done in
                        if done { output.say("down: \(step.label) done") }
                    }
                    for w in warnings { output.warn(w) }
                    output.say("compose down: ok")
                case "logs":
                    verboseHeader()
                    // Like down: the whole file, no profile filter — existing
                    // containers must stay visible even when profile-gated.
                    try await Compose.logs(
                        plan: parsed, services: inv.services,
                        tail: inv.counts["tail"], follow: inv.flags.contains("follow"))
                case "stop", "start", "restart", "pull":
                    verboseHeader()
                    // Docker parity: these scope to EXACTLY the named services
                    // — no dependency closure (stopping web must not stop a db
                    // other services still use; pull adds dependencies only
                    // with --include-deps). Empty = every enabled service.
                    let plan = try parsed.selecting(
                        services: inv.services, activeProfiles: inv.profiles, includeDependencies: false)
                    let sub = inv.subcommand
                    let report: @Sendable (Compose.StepKind, Bool) async -> Void = { step, done in
                        if done { output.say("\(sub): \(step.label) done") }
                    }
                    var warnings: [String] = []
                    switch sub {
                    case "stop": try await Compose.stop(plan: plan, progress: report)
                    case "start": warnings = try await Compose.start(plan: plan, diagnostic: { output.verbose($0) }, progress: report)
                    case "restart": warnings = try await Compose.restart(plan: plan, diagnostic: { output.verbose($0) }, progress: report)
                    default: try await Compose.pull(plan: plan, progress: report, output: { output.sayRaw($0) })
                    }
                    for w in warnings { output.warn(w) }
                    output.say("compose \(sub): ok")
                case "exec":
                    verboseHeader()
                    // Whole-file plan like logs/down — an existing container of
                    // a profile-gated service must stay reachable. Resolution
                    // errors (unknown service, nothing running) exit 1 below;
                    // then the interactive exec path takes over and exits with
                    // the in-container status.
                    let container = try await Compose.runningContainer(plan: parsed, service: inv.services[0])
                    await ExecMode.run(containerID: container, argv: inv.command)
                case "ps":
                    verboseHeader()
                    // Like stop/start: `ps web` lists exactly web (docker parity).
                    let plan = try parsed.selecting(
                        services: inv.services, activeProfiles: inv.profiles, includeDependencies: false)
                    let records = try await Compose.ps(plan: plan)
                    if inv.flags.contains("quiet") {
                        // docker parity: `ps -q` prints bare container IDs (our
                        // IDs are the names), one per line, nothing else.
                        for r in records { print(r.container) }
                        exit(0)
                    }
                    let rows = [["SERVICE", "CONTAINER", "STATE", "PORTS"]]
                        + records.map { [$0.service, $0.container, $0.state, $0.ports] }
                    let widths = (0..<4).map { c in rows.map { $0[c].count }.max() ?? 0 }
                    for row in rows {
                        print(row.enumerated()
                            .map { $0 == 3 ? $1 : $1.padding(toLength: widths[$0], withPad: " ", startingAt: 0) }
                            .joined(separator: "  "))
                    }
                default:
                    FileHandle.standardError.write(Data((usage + "\n").utf8)); exit(2)  // parse() keeps this unreachable
                }
                exit(0)
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                FileHandle.standardError.write(Data("compose \(inv.subcommand) failed: \(message)\n".utf8)); exit(1)
            }
        }
        semaphore.wait()
    }
}

/// `davit run [flags] IMAGE [COMMAND...]` — docker-style single-container run
/// (plan I6). Flags strictly precede IMAGE (docker convention); a bare `--`
/// also ends flag parsing, docker-style. Recognized flags route into the same
/// four arg arrays `ContainerService.runContainer` hands to Apple's
/// `Flags.Process/Management/Resource` parsers — this layer only decides
/// which bucket a token belongs to and whether it consumes a value (the
/// parsers themselves handle repeats and validation); everything after IMAGE
/// is the command argv, never parsed. `-d`/`--rm`/`--pull`/`-i`/`--verbose`/
/// `--quiet` are Davit's own grammar, handled before the routing table is
/// consulted. Usage problems exit 2, runtime failures exit 1 (ComposeCLI's
/// convention).
enum RunCLI {
    enum Bucket { case process, management, resource }

    /// flag token → (bucket, takesValue). Both spellings of a flag route to
    /// the same bucket; the RAW token (not a canonical name) is what actually
    /// gets appended to that bucket's argv, since Flags.Process/Management/
    /// Resource parse the real docker spelling themselves. `--name` is
    /// handled as its own branch below (not here) — its value is needed
    /// up front to resolve the container's name before create.
    static let routing: [String: (bucket: Bucket, takesValue: Bool)] = [
        // process
        "-e": (.process, true), "--env": (.process, true),
        "--env-file": (.process, true),
        "-t": (.process, false), "--tty": (.process, false),
        "-u": (.process, true), "--user": (.process, true),
        "--uid": (.process, true), "--gid": (.process, true),
        "-w": (.process, true), "--workdir": (.process, true),
        "--ulimit": (.process, true),
        // resource
        "-c": (.resource, true), "--cpus": (.resource, true),
        "-m": (.resource, true), "--memory": (.resource, true),
        // management
        "-p": (.management, true), "--publish": (.management, true),
        "-v": (.management, true), "--volume": (.management, true),
        "--mount": (.management, true),
        "--tmpfs": (.management, true),
        "--network": (.management, true),
        "--entrypoint": (.management, true),
        "-l": (.management, true), "--label": (.management, true),
        "--platform": (.management, true),
        "--arch": (.management, true),
        "--os": (.management, true),
        "--cap-add": (.management, true),
        "--cap-drop": (.management, true),
        "--init": (.management, false),
        "--read-only": (.management, false),
        "--shm-size": (.management, true),
        "--dns": (.management, true),
        "--dns-search": (.management, true),
        "--dns-option": (.management, true),
        "--no-dns": (.management, false),
        "--rosetta": (.management, false),
        "--virtualization": (.management, false),
        "--ssh": (.management, false),
        // --cidfile is NOT routed here: unlike apple's own ContainerRun/
        // ContainerCreate, Davit's create path (`Backend.runContainer` →
        // `Utility.containerConfigFromFlags`) never reads
        // `Flags.Management.cidfile` — writing the file is done by the CLI
        // command layer itself. It's intercepted below (like --name) so
        // `execute()` can write it after the container is actually created.
    ]

    /// Real `docker run` flags this platform has no equivalent for. Naming
    /// them explicitly (rather than falling through to "unknown flag") gives
    /// a docker-parity script an actionable message instead of a bare syntax
    /// error, so it fails loudly instead of silently losing the setting.
    static let unsupported: Set<String> = [
        "--restart", "--add-host", "--privileged", "--hostname", "-h", "--domainname",
        "--mac-address", "--gpus", "--device", "--device-cgroup-rule", "--link",
        "--pid", "--ipc", "--uts", "--userns", "--security-opt", "--sysctl",
        "--group-add", "--isolation", "--cgroup-parent", "--volumes-from",
        "--stop-signal", "--stop-timeout", "--expose", "-P", "--publish-all",
        "--log-driver", "--log-opt", "-a", "--attach",
        "--health-cmd", "--health-interval", "--health-retries", "--health-timeout",
        "--health-start-period", "--no-healthcheck",
        "--memory-swap", "--memory-reservation", "--memory-swappiness", "--kernel-memory",
        "--cpu-shares", "--cpuset-cpus", "--cpuset-mems", "--cpu-quota", "--cpu-period",
        "--cpu-rt-runtime", "--cpu-rt-period", "--oom-kill-disable", "--oom-score-adj",
        "--pids-limit", "--blkio-weight", "--blkio-weight-device",
        "--device-read-bps", "--device-write-bps", "--device-read-iops", "--device-write-iops",
    ]

    static let usage = """
    usage: run [flags] IMAGE [COMMAND...]
      -d, --detach                  run detached; prints the container name (docker prints the ID; name==id here)
      --rm                          remove the container once it stops
      --pull missing|always|never   image pull policy (default: missing)
      --verbose | -q, --quiet       per-run diagnostics (mutually exclusive)
      --help                        show this usage and exit
      flags must precede IMAGE (docker-style); `--` also ends flag parsing
      docker-style flags: -e/--env, --env-file, -t/--tty, -u/--user, --uid, --gid,
        -w/--workdir, --ulimit, -c/--cpus, -m/--memory, --name, -p/--publish,
        -v/--volume, --mount, --tmpfs, --network, --entrypoint, -l/--label,
        --platform, --arch, --os, --cap-add, --cap-drop, --init, --read-only,
        --shm-size, --dns, --dns-search, --dns-option, --no-dns, --rosetta,
        --virtualization, --ssh, --cidfile
      -i/--interactive and docker flags with no platform mapping (--restart,
      --privileged, --add-host, --hostname, --gpus, ...) are rejected — see README
    """

    struct Invocation {
        var image = ""
        var command: [String] = []
        var process: [String] = []
        var management: [String] = []
        var resource: [String] = []
        var name: String? = nil
        var cidfile: String? = nil
        var detach = false
        var autoRemove = false
        var pullPolicy = "missing"
        var verbose = false
        var quiet = false
    }

    /// Thrown by the pure `parseArgs` below instead of exiting the process —
    /// keeps the routing logic selftest-able. `message == nil` prints the
    /// bare usage line only (e.g. no IMAGE given at all). `isHelp` marks
    /// `--help`: a success path (usage to stdout, exit 0), not a usage error.
    struct ParseError: Error, Equatable {
        let message: String?
        var isHelp: Bool = false
    }

    /// Pure routing core: no I/O, no `exit()` — selftest calls this directly.
    /// `parse(_:)` below is the process-exiting shell `run()` actually uses.
    static func parseArgs(_ args: [String]) throws -> Invocation {
        var args = args
        var inv = Invocation()
        var i = 0
        while i < args.count {
            let raw = args[i]
            if raw == "--" {
                i += 1
                break
            }
            var arg = raw
            var inline: String? = nil
            if raw.hasPrefix("--"), let eq = raw.firstIndex(of: "=") {
                arg = String(raw[..<eq])
                inline = String(raw[raw.index(after: eq)...])
            }
            func value() throws -> String {
                if let v = inline { return v }
                guard i + 1 < args.count else { throw ParseError(message: "flag \(arg) needs a value") }
                i += 1
                return args[i]
            }
            if arg == "-d" || arg == "--detach" {
                guard inline == nil else { throw ParseError(message: "flag \(arg) takes no value") }
                inv.detach = true
            } else if arg == "--rm" {
                guard inline == nil else { throw ParseError(message: "flag \(arg) takes no value") }
                inv.autoRemove = true
            } else if arg == "--pull" {
                let v = try value()
                guard ["missing", "always", "never"].contains(v) else {
                    throw ParseError(message: "invalid --pull value: \(v) (want missing|always|never)")
                }
                inv.pullPolicy = v
            } else if arg == "-i" || arg == "--interactive" {
                throw ParseError(message: "interactive runs aren't supported; start detached, then `Davit exec <name>`")
            } else if arg == "--name" {
                let v = try value()
                inv.name = v
                inv.management.append(contentsOf: [arg, v])
            } else if arg == "--cidfile" {
                // Intercepted rather than routed (unlike apple's own CLI,
                // Davit's create path never reads Flags.Management.cidfile) —
                // execute() writes it itself once the container exists.
                inv.cidfile = try value()
            } else if arg == "--verbose" {
                guard inline == nil else { throw ParseError(message: "flag \(arg) takes no value") }
                inv.verbose = true
            } else if arg == "-q" || arg == "--quiet" {
                guard inline == nil else { throw ParseError(message: "flag \(arg) takes no value") }
                inv.quiet = true
            } else if arg == "--help" {
                guard inline == nil else { throw ParseError(message: "flag \(arg) takes no value") }
                throw ParseError(message: nil, isHelp: true)
            } else if unsupported.contains(arg) {
                let hint = arg == "-h" ? "; for help, use --help" : ""
                throw ParseError(message: "docker flag \(arg) has no equivalent on this platform (apple/container doesn't support it) — remove it or adjust the parity script\(hint)")
            } else if let route = routing[arg] {
                if route.takesValue {
                    let v = try value()
                    switch route.bucket {
                    case .process: inv.process.append(contentsOf: [arg, v])
                    case .management: inv.management.append(contentsOf: [arg, v])
                    case .resource: inv.resource.append(contentsOf: [arg, v])
                    }
                } else {
                    guard inline == nil else { throw ParseError(message: "flag \(arg) takes no value") }
                    switch route.bucket {
                    case .process: inv.process.append(arg)
                    case .management: inv.management.append(arg)
                    case .resource: inv.resource.append(arg)
                    }
                }
            } else if raw.hasPrefix("-"), !raw.hasPrefix("--"), raw.count > 2,
                      raw.dropFirst().allSatisfy({ "dtiq".contains($0) }) {
                // Docker's clustered short flags (`-it`, `-ti`, `-dit`, ...) —
                // expand into individual tokens and splice them back into the
                // stream so each one re-dispatches through the branches
                // above. Docker users overwhelmingly type `-it`, not `-i -t`
                // separately; this is in particular what surfaces the
                // tailored `-i` rejection instead of a bare "unknown flag:
                // -it". Any letter outside {d,t,i,q} (Davit's only no-value
                // short flags) falls through to the plain unknown-flag error
                // below, naming the whole cluster.
                args.replaceSubrange(i...i, with: raw.dropFirst().map { "-\($0)" })
                continue
            } else if raw.hasPrefix("-"), raw != "-" {
                throw ParseError(message: "unknown flag: \(raw)")
            } else {
                inv.image = raw
                i += 1
                break
            }
            i += 1
        }
        if inv.image.isEmpty {
            guard i < args.count else { throw ParseError(message: nil) }
            inv.image = args[i]
            i += 1
        }
        inv.command = i < args.count ? Array(args[i...]) : []
        if inv.verbose, inv.quiet {
            throw ParseError(message: "--verbose and -q/--quiet are mutually exclusive")
        }
        return inv
    }

    /// `parseArgs` wrapped for real CLI use: usage problems print to stderr
    /// and exit 2, naming the offending token where there is one. `--help` is
    /// the one success path: usage to stdout, exit 0 (general CLI convention
    /// docker itself follows — a well-known flag must never look like a
    /// syntax error).
    static func parse(_ args: [String]) -> Invocation {
        do {
            return try parseArgs(args)
        } catch let error as ParseError {
            if error.isHelp {
                print(usage); exit(0)
            }
            let prefix = error.message.map { $0 + "\n" } ?? ""
            FileHandle.standardError.write(Data((prefix + usage + "\n").utf8)); exit(2)
        } catch {
            FileHandle.standardError.write(Data((usage + "\n").utf8)); exit(2)
        }
    }

    /// Resolves the container name, applies `--pull`, and creates+starts the
    /// container — everything `run()` needs that a selftest can also drive
    /// directly (no `exit()` in here, unlike `run()` itself). Returns the
    /// resolved name (mirrors `Backend.runContainer`'s own id computation:
    /// an empty --name value is treated like "not given", random id — same
    /// as the GUI Run sheet). `retainExitCode` (foreground runs only, set by
    /// `run()`) registers the init process with `ComposeExitCodes` so the
    /// caller can propagate the container's own exit code once it stops.
    static func execute(
        _ inv: Invocation, output: CLIOutput = CLIOutput(level: .normal), retainExitCode: Bool = false
    ) async throws -> String {
        let resolvedName = Utility.createContainerID(name: (inv.name?.isEmpty == true) ? nil : inv.name)

        // docker parity: refuse up front rather than silently clobbering
        // another run's cidfile (or one left behind by a container that's
        // still around) — mirrors docker's client-side cidfile.go check.
        let cidfile = (inv.cidfile?.isEmpty == false) ? inv.cidfile : nil
        if let cidfile, FileManager.default.fileExists(atPath: cidfile) {
            throw CLIError(command: "run", message: "container ID file found, make sure the other container isn't running or delete \(cidfile)")
        }

        switch inv.pullPolicy {
        case "always":
            output.verbose("pulling \(inv.image) (--pull always)")
            try await ContainerService.pullImage(inv.image) { _ in }
        case "never":
            guard try await ContainerService.imageExists(inv.image, managementArgs: inv.management) else {
                throw CLIError(command: "run", message: "image not present locally and --pull never was given: \(inv.image)")
            }
        default:
            break  // "missing" (default): the create path's own fetch-if-absent already covers this
        }

        output.verbose("resolved name: \(resolvedName)")
        do {
            try await ContainerService.runContainer(
                image: inv.image,
                name: resolvedName,
                processArgs: inv.process,
                managementArgs: inv.management,
                resourceArgs: inv.resource,
                commandArgs: inv.command,
                autoRemove: inv.autoRemove,
                retainExitCode: retainExitCode
            )
        } catch {
            // create succeeded but start failed (port conflict etc.): with
            // --rm, a container that never ran must not survive to block the
            // name — daemon autoRemove only reaps STOPPED containers, and the
            // foreground path strips it anyway. Without --rm docker leaves the
            // created container behind; we match that.
            if inv.autoRemove {
                try? await ContainerService.delete(resolvedName, force: true)
            }
            throw error
        }

        // Apple's own ContainerRun writes this right after bootstrap starts,
        // with the same 0644/create-only semantics; erroring here (rather
        // than silently swallowing a write failure) matches "cidfile accepted
        // means cidfile honored" — and, like apple's own catch block around
        // this same step, a write failure tears the just-created container
        // back down rather than leaving an orphaned running container behind
        // a "run failed" message.
        if let cidfile {
            let ok = FileManager.default.createFile(
                atPath: cidfile, contents: Data(resolvedName.utf8), attributes: [.posixPermissions: 0o644])
            guard ok else {
                try? await ContainerService.delete(resolvedName, force: true)
                throw CLIError(command: "run", message: "failed to write cidfile at \(cidfile)")
            }
        }
        return resolvedName
    }

    static func run(_ args: [String]) {
        let inv = parse(args)
        let output = CLIOutput(level: inv.quiet ? .quiet : (inv.verbose ? .verbose : .normal))
        if output.level == .verbose, !LoggingConfig.explicitlySet {
            LoggingConfig.level = .debug
        }
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                // Foreground --rm: don't hand removal to the daemon, which
                // reaps an auto-remove container the instant its init process
                // exits — a fast one-shot can race that reap against the log
                // attach below and lose all output (docker run --rm always
                // shows it). Create non-removing instead and delete it
                // ourselves once the attach is done; still gone afterwards,
                // same as docker, just sequenced so the logs are never lost.
                let deferRemoval = inv.autoRemove && !inv.detach
                var createInv = inv
                if deferRemoval { createInv.autoRemove = false }

                // retainExitCode only matters for the attach path below (a
                // detached run never waits on it) — always requesting it
                // there lets a foreground run propagate the container's own
                // exit code (docker parity) instead of always exiting 0.
                let resolvedName = try await execute(createInv, output: output, retainExitCode: !inv.detach)

                if inv.detach {
                    // The primary, script-parsed output of `-d` (docker parity)
                    // — printed unconditionally, --quiet notwithstanding, same
                    // as docker itself never suppresses the printed ID.
                    print(resolvedName)
                    exit(0)
                }

                // Attach: stream this one container's logs, no prefix (I6
                // design) — reuses compose's per-stream follow core so the
                // tail/readability-handler/exit-detection logic isn't
                // duplicated. Ctrl-C only detaches: signals can't be
                // forwarded to the guest process on this platform (no exec
                // signal delivery), so the container keeps running — a
                // documented divergence from docker, not a bug. Banner and
                // the no-stream warning go to stderr — stdout here is
                // reserved for the container's own log content, so
                // `davit run img cmd | consumer` never sees status noise
                // ahead of (or interleaved with) real output.
                output.sayErr("Attaching to logs (Ctrl-C detaches; container keeps running)")
                var sigintSource: DispatchSourceSignal?
                if deferRemoval {
                    // Removal is deferred to after the attach; Ctrl-C ends the
                    // process before that line runs, so the container would
                    // silently outlive --rm. Can't forward signals to the guest
                    // on this platform — be honest instead of silent.
                    signal(SIGINT, SIG_IGN)
                    let src = DispatchSource.makeSignalSource(signal: SIGINT)
                    src.setEventHandler {
                        FileHandle.standardError.write(Data(
                            "\ndetached — container \(resolvedName) keeps running and will NOT be auto-removed (--rm removal runs after the attach): remove it later with `container delete \(resolvedName)`\n".utf8))
                        exit(130)
                    }
                    src.resume()
                    sigintSource = src
                }
                if let handle = await Compose.openLogHandle(resolvedName) {
                    // Best-effort: a follow error must not skip the exit-code
                    // fetch / --rm cleanup below.
                    try? await Compose.followLogStreams(
                        [Compose.LogStream(prefix: "", name: resolvedName, handle: handle, backlog: true)],
                        tail: nil, follow: true,
                        output: { FileHandle.standardOutput.write(Data($0.utf8)) }
                    )
                } else {
                    output.warnErr("no log stream available for \(resolvedName)")
                }

                // followLogStreams only returns once the container has
                // stopped, so the registered wait (retainExitCode above)
                // resolves immediately here.
                let exitCode = await ComposeExitCodes.shared.exitCode(for: resolvedName) ?? 0
                sigintSource?.cancel()
                if deferRemoval {
                    try? await ContainerService.delete(resolvedName, force: true)
                }
                exit(exitCode)
            } catch {
                let message = (error as? CLIError)?.message
                    ?? (error as? LocalizedError)?.errorDescription
                    ?? String(describing: error)
                FileHandle.standardError.write(Data("run failed: \(message)\n".utf8)); exit(1)
            }
        }
        semaphore.wait()
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
        await step("log level: DAVIT_LOG_LEVEL parsing") {
            // Pure — LoggingSystem.bootstrap itself traps if called twice, so
            // this exercises the parsing function bootstrapLogging() uses
            // rather than re-bootstrapping the process' actual logger.
            guard LoggingConfig.parseLevel(nil) == (.info, true) else {
                throw CLIError(command: "selftest", message: "unset DAVIT_LOG_LEVEL should default to info")
            }
            guard LoggingConfig.parseLevel("") == (.info, true) else {
                throw CLIError(command: "selftest", message: "empty DAVIT_LOG_LEVEL should default to info")
            }
            let cases: [(String, Logger.Level)] = [
                ("trace", .trace), ("DEBUG", .debug), ("Info", .info), ("notice", .notice),
                ("WARNING", .warning), ("error", .error), ("Critical", .critical),
            ]
            for (raw, expected) in cases {
                guard LoggingConfig.parseLevel(raw) == (expected, true) else {
                    throw CLIError(command: "selftest", message: "DAVIT_LOG_LEVEL=\(raw) parsed wrong: \(LoggingConfig.parseLevel(raw))")
                }
            }
            guard LoggingConfig.parseLevel("bogus") == (.info, false) else {
                throw CLIError(command: "selftest", message: "invalid DAVIT_LOG_LEVEL should fall back to info and flag ok=false")
            }
        }
        await step("run: pure routing (RunCLI.parseArgs)") {
            // Pure — no exit(), no async work; RunCLI.parse() is the process-
            // exiting shell around this that a live CLI round-trip covers.
            let full = try RunCLI.parseArgs([
                "--env", "FOO=bar", "--cpus", "2", "--name", "x", "-p", "80:80",
                "alpine", "echo", "hi",
            ])
            guard full.process == ["--env", "FOO=bar"] else {
                throw CLIError(command: "selftest", message: "process bucket wrong: \(full.process)")
            }
            guard full.resource == ["--cpus", "2"] else {
                throw CLIError(command: "selftest", message: "resource bucket wrong: \(full.resource)")
            }
            guard full.management == ["--name", "x", "-p", "80:80"] else {
                throw CLIError(command: "selftest", message: "management bucket wrong: \(full.management)")
            }
            guard full.name == "x", full.image == "alpine", full.command == ["echo", "hi"] else {
                throw CLIError(command: "selftest", message: "name/image/command wrong: \(full.name ?? "nil") \(full.image) \(full.command)")
            }

            // Boolean flags in each bucket append just the flag token, no value.
            let bools = try RunCLI.parseArgs(["-t", "--init", "--rosetta", "alpine"])
            guard bools.process == ["-t"], bools.management == ["--init", "--rosetta"], bools.image == "alpine", bools.command.isEmpty else {
                throw CLIError(command: "selftest", message: "boolean routing wrong: \(bools.process) \(bools.management) \(bools.image) \(bools.command)")
            }

            // Davit-side flags never reach the bucket arrays.
            let davit = try RunCLI.parseArgs(["-d", "--rm", "--pull", "always", "--verbose", "alpine"])
            guard davit.detach, davit.autoRemove, davit.pullPolicy == "always", davit.verbose,
                  davit.process.isEmpty, davit.management.isEmpty, davit.resource.isEmpty
            else { throw CLIError(command: "selftest", message: "Davit-side flag parsing wrong: \(davit)") }

            // `--flag=value` inline spelling.
            let inline = try RunCLI.parseArgs(["--cpus=2", "--name=foo", "alpine"])
            guard inline.resource == ["--cpus", "2"], inline.management == ["--name", "foo"], inline.name == "foo" else {
                throw CLIError(command: "selftest", message: "inline =value wrong: \(inline.resource) \(inline.management) \(inline.name ?? "nil")")
            }

            // `--` ends flag parsing early; the very next token is IMAGE even
            // if it looks like a flag.
            let dashdash = try RunCLI.parseArgs(["--env", "A=1", "--", "--not-a-flag", "arg2"])
            guard dashdash.process == ["--env", "A=1"], dashdash.image == "--not-a-flag", dashdash.command == ["arg2"] else {
                throw CLIError(command: "selftest", message: "-- termination wrong: \(dashdash.process) \(dashdash.image) \(dashdash.command)")
            }

            // Everything after IMAGE is verbatim command argv — never parsed,
            // even flag-shaped or explicitly-unsupported-looking tokens.
            let postImage = try RunCLI.parseArgs(["alpine", "--restart", "always", "-e", "X=1"])
            guard postImage.image == "alpine", postImage.command == ["--restart", "always", "-e", "X=1"],
                  postImage.process.isEmpty, postImage.management.isEmpty
            else { throw CLIError(command: "selftest", message: "post-IMAGE argv was reparsed: \(postImage.command)") }

            // Unknown flag.
            do {
                _ = try RunCLI.parseArgs(["--bogus", "alpine"])
                throw CLIError(command: "selftest", message: "unknown flag not rejected")
            } catch let e as RunCLI.ParseError {
                guard e.message == "unknown flag: --bogus" else {
                    throw CLIError(command: "selftest", message: "unknown flag message wrong: \(e.message ?? "nil")")
                }
            }

            // -i/--interactive hard error.
            do {
                _ = try RunCLI.parseArgs(["-i", "alpine"])
                throw CLIError(command: "selftest", message: "-i not rejected")
            } catch let e as RunCLI.ParseError {
                guard e.message?.contains("interactive runs aren't supported") == true else {
                    throw CLIError(command: "selftest", message: "-i message wrong: \(e.message ?? "nil")")
                }
            }

            // Docker flags with no platform mapping.
            do {
                _ = try RunCLI.parseArgs(["--restart", "always", "alpine"])
                throw CLIError(command: "selftest", message: "--restart not rejected")
            } catch let e as RunCLI.ParseError {
                guard e.message?.contains("--restart") == true, e.message?.contains("no equivalent") == true else {
                    throw CLIError(command: "selftest", message: "--restart message wrong: \(e.message ?? "nil")")
                }
            }

            // A value-taking flag at argv end.
            do {
                _ = try RunCLI.parseArgs(["--name"])
                throw CLIError(command: "selftest", message: "trailing --name without a value not rejected")
            } catch let e as RunCLI.ParseError {
                guard e.message == "flag --name needs a value" else {
                    throw CLIError(command: "selftest", message: "trailing-value message wrong: \(e.message ?? "nil")")
                }
            }

            // Bare `run` (no IMAGE at all): usage only, no message.
            do {
                _ = try RunCLI.parseArgs([])
                throw CLIError(command: "selftest", message: "empty argv not rejected")
            } catch let e as RunCLI.ParseError {
                guard e.message == nil else {
                    throw CLIError(command: "selftest", message: "empty-argv error should carry no message: \(e.message ?? "nil")")
                }
            }

            // --verbose and --quiet are mutually exclusive.
            do {
                _ = try RunCLI.parseArgs(["--verbose", "--quiet", "alpine"])
                throw CLIError(command: "selftest", message: "--verbose --quiet combo not rejected")
            } catch let e as RunCLI.ParseError {
                guard e.message?.contains("mutually exclusive") == true else {
                    throw CLIError(command: "selftest", message: "verbose/quiet message wrong: \(e.message ?? "nil")")
                }
            }

            // Invalid --pull value.
            do {
                _ = try RunCLI.parseArgs(["--pull", "sometimes", "alpine"])
                throw CLIError(command: "selftest", message: "invalid --pull value not rejected")
            } catch let e as RunCLI.ParseError {
                guard e.message?.contains("invalid --pull value") == true else {
                    throw CLIError(command: "selftest", message: "--pull message wrong: \(e.message ?? "nil")")
                }
            }

            // --cidfile is intercepted, not routed into the management bucket
            // (review fix: apple's create path never reads
            // Flags.Management.cidfile, so leaving it there silently
            // dropped it — execute() now writes it itself).
            let cid = try RunCLI.parseArgs(["--cidfile", "/tmp/davit-selftest.cid", "--name", "x", "alpine"])
            guard cid.cidfile == "/tmp/davit-selftest.cid", cid.management == ["--name", "x"] else {
                throw CLIError(command: "selftest", message: "--cidfile routing wrong: cidfile=\(cid.cidfile ?? "nil") management=\(cid.management)")
            }

            // Docker's clustered short flags (review fix): `-it`/`-ti`/`-dit`
            // must surface the tailored -i rejection, not a bare "unknown
            // flag". A cluster with no `i` (`-dt`) expands and routes as if
            // written separately.
            for cluster in ["-it", "-ti", "-dit", "-tid"] {
                do {
                    _ = try RunCLI.parseArgs([cluster, "alpine"])
                    throw CLIError(command: "selftest", message: "\(cluster) not rejected as interactive")
                } catch let e as RunCLI.ParseError {
                    guard e.message?.contains("interactive runs aren't supported") == true else {
                        throw CLIError(command: "selftest", message: "\(cluster) message wrong: \(e.message ?? "nil")")
                    }
                }
            }
            let dtCluster = try RunCLI.parseArgs(["-dt", "alpine"])
            guard dtCluster.detach, dtCluster.process == ["-t"] else {
                throw CLIError(command: "selftest", message: "-dt cluster expansion wrong: detach=\(dtCluster.detach) process=\(dtCluster.process)")
            }
            // A cluster with an unrecognized letter still falls through to
            // the plain unknown-flag error, naming the whole token.
            do {
                _ = try RunCLI.parseArgs(["-itx", "alpine"])
                throw CLIError(command: "selftest", message: "-itx not rejected")
            } catch let e as RunCLI.ParseError {
                guard e.message == "unknown flag: -itx" else {
                    throw CLIError(command: "selftest", message: "-itx message wrong: \(e.message ?? "nil")")
                }
            }

            // --help is a success path: usage only, no error message.
            do {
                _ = try RunCLI.parseArgs(["--help"])
                throw CLIError(command: "selftest", message: "--help did not throw")
            } catch let e as RunCLI.ParseError {
                guard e.isHelp, e.message == nil else {
                    throw CLIError(command: "selftest", message: "--help parse result wrong: isHelp=\(e.isHelp) message=\(e.message ?? "nil")")
                }
            }

            // -h (docker's "hostname", no equivalent here) hints at --help
            // rather than just declaring itself unsupported.
            do {
                _ = try RunCLI.parseArgs(["-h", "myhost", "alpine"])
                throw CLIError(command: "selftest", message: "-h not rejected")
            } catch let e as RunCLI.ParseError {
                guard e.message?.contains("--help") == true else {
                    throw CLIError(command: "selftest", message: "-h message missing --help hint: \(e.message ?? "nil")")
                }
            }
        }
        await step("run: live run with --name/--env/--publish/--label, then --rm one-shot") {
            let name = "davit-selftest-run"
            try? await ContainerService.delete(name, force: true)
            defer { Task { try? await ContainerService.delete(name, force: true) } }

            let inv = try RunCLI.parseArgs([
                "--name", name, "--env", "FOO=bar", "--publish", "18080:80",
                "--label", "team=davit", "alpine:latest", "sleep", "120",
            ])
            _ = try await RunCLI.execute(inv)

            let record = try await ContainerService.listContainers().first { $0.id == name }
            guard record?.isRunning == true else {
                throw CLIError(command: "selftest", message: "run: container not running after run")
            }
            guard record?.configuration.initProcess?.environment?.contains("FOO=bar") == true else {
                throw CLIError(command: "selftest", message: "run: --env not applied: \(record?.configuration.initProcess?.environment ?? [])")
            }
            guard record?.configuration.labels?["team"] == "davit" else {
                throw CLIError(command: "selftest", message: "run: --label not applied: \(record?.configuration.labels ?? [:])")
            }
            guard let port = record?.configuration.publishedPorts?.first, port.hostPort == 18080, port.containerPort == 80 else {
                throw CLIError(command: "selftest", message: "run: --publish not applied: \(record?.configuration.publishedPorts ?? [])")
            }
            try await ContainerService.delete(name, force: true)

            // --rm one-shot: the container must be gone once it exits, no
            // manual cleanup — poll rather than sleep a fixed amount.
            let rmName = "davit-selftest-run-rm"
            try? await ContainerService.delete(rmName, force: true)
            let rmInv = try RunCLI.parseArgs(["--name", rmName, "--rm", "alpine:latest", "true"])
            _ = try await RunCLI.execute(rmInv)
            var gone = false
            for _ in 0..<30 {
                if try await ContainerService.listContainers().first(where: { $0.id == rmName }) == nil {
                    gone = true
                    break
                }
                try await Task.sleep(for: .seconds(1))
            }
            guard gone else {
                try? await ContainerService.delete(rmName, force: true)
                throw CLIError(command: "selftest", message: "run: --rm container still present 30s after a one-shot exit")
            }
        }
        await step("run: --cidfile write + refuse-if-exists (review fix)") {
            let name = "davit-selftest-cidfile"
            try? await ContainerService.delete(name, force: true)
            defer { Task { try? await ContainerService.delete(name, force: true) } }

            let cidPath = FileManager.default.temporaryDirectory
                .appendingPathComponent("davit-selftest-\(UUID().uuidString).cid").path
            defer { try? FileManager.default.removeItem(atPath: cidPath) }

            let inv = try RunCLI.parseArgs(["--name", name, "--cidfile", cidPath, "alpine:latest", "sleep", "60"])
            let resolved = try await RunCLI.execute(inv)
            guard resolved == name else {
                throw CLIError(command: "selftest", message: "resolved name mismatch: \(resolved)")
            }
            guard let written = try? String(contentsOfFile: cidPath, encoding: .utf8), written == name else {
                throw CLIError(command: "selftest", message: "cidfile content wrong: \(String(describing: try? String(contentsOfFile: cidPath, encoding: .utf8)))")
            }
            try await ContainerService.delete(name, force: true)

            // docker parity: refuse rather than overwrite an existing
            // cidfile — and refuse BEFORE creating anything.
            let otherName = "davit-selftest-cidfile-2"
            try? await ContainerService.delete(otherName, force: true)
            defer { Task { try? await ContainerService.delete(otherName, force: true) } }
            var refused = false
            do {
                let dupInv = try RunCLI.parseArgs(["--name", otherName, "--cidfile", cidPath, "alpine:latest", "true"])
                _ = try await RunCLI.execute(dupInv)
            } catch let e as CLIError {
                guard e.message.contains("container ID file") else { throw e }
                refused = true
            }
            guard refused else {
                throw CLIError(command: "selftest", message: "run should have refused an already-existing cidfile")
            }
            guard try await ContainerService.listContainers().first(where: { $0.id == otherName }) == nil else {
                throw CLIError(command: "selftest", message: "cidfile refusal happened after create — container exists anyway")
            }
        }
        await step("run: retainExitCode propagates the container's own exit code (review fix)") {
            let name = "davit-selftest-exitcode"
            try? await ContainerService.delete(name, force: true)
            defer { Task { try? await ContainerService.delete(name, force: true) } }

            let inv = try RunCLI.parseArgs(["--name", name, "alpine:latest", "sh", "-c", "exit 7"])
            _ = try await RunCLI.execute(inv, retainExitCode: true)

            // Not a poll: exitCode(for:) awaits the registered process.wait(),
            // resolving once the init process (already running/exiting) stops.
            let code = await ComposeExitCodes.shared.exitCode(for: name)
            guard code == 7 else {
                throw CLIError(command: "selftest", message: "retained exit code wrong: \(String(describing: code))")
            }
            try await ContainerService.delete(name, force: true)
        }
        await step("run: imageExists rethrows non-notFound errors, masks only .notFound (review fix)") {
            // A malformed --platform value must surface as the real parse
            // error, not be swallowed into a bare "false" the way a blanket
            // catch would (masking a real problem as "image missing").
            var rethrew = false
            do {
                _ = try await ContainerService.imageExists("alpine:latest", managementArgs: ["--platform", "not-a-real-platform"])
            } catch {
                rethrew = true
            }
            guard rethrew else {
                throw CLIError(command: "selftest", message: "imageExists should have rethrown the bad --platform value, not returned a bool")
            }

            // A genuinely missing reference still resolves to false — the
            // intended `--pull never` fast-fail path, not a thrown error.
            let missing = try await ContainerService.imageExists("davit-selftest-does-not-exist:latest")
            guard missing == false else {
                throw CLIError(command: "selftest", message: "imageExists should be false for a nonexistent reference")
            }

            // The common case: alpine:latest is present locally by now
            // (earlier steps already ran it) at the host's default platform.
            let present = try await ContainerService.imageExists("alpine:latest")
            guard present else {
                throw CLIError(command: "selftest", message: "imageExists should be true for a present reference")
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

            // Service names outside docker's charset are rejected (they'd also
            // corrupt the managed /etc/hosts block — its lines carry them).
            do {
                _ = try Compose.parse(text: "services: {\"bad name\": {image: x}}", projectName: "n")
                throw CLIError(command: "selftest", message: "invalid service name not rejected")
            } catch Compose.Error.invalidServiceName("bad name") { /* expected */ }
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
            // stop/start/restart/pull/ps scoping: EXACTLY the named services,
            // no closure (docker parity) — but auto-activation still applies,
            // and the full service list stays available for the hosts sync.
            let exact = try plan.selecting(services: ["web"], activeProfiles: [], includeDependencies: false)
            guard exact.services.map(\.service) == ["web"],
                  exact.allServices.map(\.service) == plan.services.map(\.service)
            else { throw CLIError(command: "selftest", message: "exact selection wrong: \(exact.services.map(\.service))") }
            guard try plan.selecting(services: ["debug"], activeProfiles: [], includeDependencies: false)
                .services.map(\.service) == ["debug"]
            else { throw CLIError(command: "selftest", message: "exact selection should auto-activate the named service's profile") }
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
        await step("compose: interpolation edge cases (nested braces, :+, CRLF .env)") {
            // Nested default with the outer variable SET: must close at the
            // matching brace, no trailing "}" corruption.
            var warned: [String] = []
            func interp(_ text: String, env: [String: String]) throws -> String {
                let plan = try Compose.parse(
                    text: "services: {a: {image: alpine, environment: {V: \"\(text)\"}}}",
                    projectName: "t", environment: env)
                let arg = plan.services[0].processArgs
                guard let i = arg.firstIndex(of: "--env"), i + 1 < arg.count else {
                    throw CLIError(command: "selftest", message: "no env arg for \(text)")
                }
                warned = plan.warnings
                return String(arg[i + 1].dropFirst(2))  // strip "V="
            }
            guard try interp("${VAR:-${OTHER}}", env: ["VAR": "x"]) == "x" else {
                throw CLIError(command: "selftest", message: "nested default corrupted a set value")
            }
            guard try interp("${VAR:-${OTHER}}", env: ["OTHER": "o"]) == "${OTHER}" else {
                throw CLIError(command: "selftest", message: "unset nested default should stay literal")
            }
            guard try interp("${D:+--verbose}", env: ["D": "1"]) == "--verbose",
                  try interp("${D:+--verbose}", env: [:]) == ""
            else { throw CLIError(command: "selftest", message: ":+ operator wrong") }
            _ = warned  // reserved for future warning assertions

            let fm = FileManager.default
            // Cross-file env_file precedence: a file redefining X then
            // referencing it must see its OWN value (compose-go), not an
            // earlier file's.
            let xDir = fm.temporaryDirectory.appendingPathComponent("davit-selftest-xfile-\(UUID().uuidString)")
            try fm.createDirectory(at: xDir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: xDir) }
            try "X=one\n".write(to: xDir.appendingPathComponent("a.env"), atomically: true, encoding: .utf8)
            try "X=two\nY=${X}\n".write(to: xDir.appendingPathComponent("b.env"), atomically: true, encoding: .utf8)
            let xPlan = try Compose.parse(
                text: "services: {s: {image: alpine, env_file: [a.env, b.env]}}",
                projectName: "x", baseDir: xDir.path)
            guard xPlan.services[0].processArgs.contains("Y=two") else {
                throw CLIError(command: "selftest", message: "cross-file env_file precedence wrong: \(xPlan.services[0].processArgs)")
            }

            // Inline comments: quoted values end at the close quote (rest
            // dropped, single-quote stays literal); unquoted cut at " #".
            let cDir = fm.temporaryDirectory.appendingPathComponent("davit-selftest-cmt-\(UUID().uuidString)")
            try fm.createDirectory(at: cDir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: cDir) }
            try "PASS='p$wd' # login\nPRICE=10 # in $USD\n".write(
                to: cDir.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
            let cEnv = try Compose.effectiveEnvironment(composeDir: cDir.path, processEnvironment: [:])
            guard cEnv.environment["PASS"] == "p$wd", cEnv.environment["PRICE"] == "10" else {
                throw CLIError(command: "selftest", message: "inline comment handling wrong: \(cEnv.environment)")
            }

            // CRLF .env: values must not keep a trailing \r; quotes must strip.
            let crlfDir = fm.temporaryDirectory.appendingPathComponent("davit-selftest-crlf-\(UUID().uuidString)")
            try fm.createDirectory(at: crlfDir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: crlfDir) }
            try "A=plain\r\nB=\"quoted\"\r\n".write(
                to: crlfDir.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
            let env = try Compose.effectiveEnvironment(composeDir: crlfDir.path, processEnvironment: [:]).environment
            guard env["A"] == "plain", env["B"] == "quoted" else {
                throw CLIError(command: "selftest", message: "CRLF .env parsed wrong: \(env)")
            }
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
            A=1
            B=${A}2
            HOMEPATH="${HOME}/test"
            HOMELITERAL='${HOME}/test'
            REF=${SHARED}
            not a key-value line
            """.write(to: dir.appendingPathComponent(".env"), atomically: true, encoding: .utf8)

            // default <dir>/.env layered under the process env — process wins
            let (env, envWarnings) = try Compose.effectiveEnvironment(
                composeDir: dir.path,
                processEnvironment: ["SHARED": "process", "PROC_ONLY": "1", "HOME": "/Users/tester"])
            guard env["TAG"] == "3.19", env["EXPORTED"] == "yes",
                  env["QUOTED"] == "q value", env["SINGLE"] == "s value",
                  env["EMPTY"] == "", env["SPACED"] == "padded",
                  env["SHARED"] == "process", env["PROC_ONLY"] == "1"
            else { throw CLIError(command: "selftest", message: "effectiveEnvironment wrong: \(env)") }
            guard envWarnings.isEmpty else {
                throw CLIError(command: "selftest", message: "unexpected dotenv warnings: \(envWarnings)")
            }
            // left-to-right self-reference within the same file: A defined
            // above, B references it on the very next line
            guard env["B"] == "12" else {
                throw CLIError(command: "selftest", message: "dotenv self-reference wrong: \(env["B"] ?? "nil")")
            }
            // user's exact scenario: double/unquoted interpolates at load time,
            // single-quoted stays literal (docker parity)
            guard env["HOMEPATH"] == "/Users/tester/test" else {
                throw CLIError(command: "selftest", message: "dotenv interpolation wrong: \(env["HOMEPATH"] ?? "nil")")
            }
            guard env["HOMELITERAL"] == "${HOME}/test" else {
                throw CLIError(command: "selftest", message: "single-quoted dotenv value was interpolated: \(env["HOMELITERAL"] ?? "nil")")
            }
            // process environment wins the lookup over this file's own
            // same-named entry, even when referenced from a later line
            guard env["REF"] == "process" else {
                throw CLIError(command: "selftest", message: "process-env-wins lookup wrong: \(env["REF"] ?? "nil")")
            }

            // absent default .env → just the process env; missing explicit file → error
            guard try Compose.effectiveEnvironment(composeDir: altDir.path, processEnvironment: ["A": "b"]).environment == ["A": "b"] else {
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
                processEnvironment: [:]).environment == ["ONLY": "here"]
            else { throw CLIError(command: "selftest", message: "--env-file override wrong") }
            // ${X:?msg} inside a .env value throws just like YAML substitution
            let reqDir = fm.temporaryDirectory.appendingPathComponent("davit-selftest-envreq-\(UUID().uuidString)")
            try fm.createDirectory(at: reqDir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: reqDir) }
            try "NEEDED=${MISSING:?must be set}\n".write(
                to: reqDir.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
            do {
                _ = try Compose.effectiveEnvironment(composeDir: reqDir.path, processEnvironment: [:])
                throw CLIError(command: "selftest", message: ".env :? unset not rejected")
            } catch Compose.Error.requiredVariable(name: "MISSING", message: "must be set") { /* expected */ }

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
        await step("compose: env_file + entrypoint") {
            let fm = FileManager.default
            let dir = fm.temporaryDirectory.appendingPathComponent("davit-selftest-envfile-\(UUID().uuidString)")
            try fm.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: dir) }
            try """
            BASE=one
            SHARED=base
            INTERP=${BASE}-two
            RAW=${NOT_INTERPOLATED}
            """.write(to: dir.appendingPathComponent("base.env"), atomically: true, encoding: .utf8)
            try """
            SHARED=later
            EXTRA=two
            OVERLAP=file
            FALLBACK=fromfile
            CROSS=${BASE}-cross
            """.write(to: dir.appendingPathComponent("sub/more.env"), atomically: true, encoding: .utf8)

            // All three entry forms; precedence: earlier files < later files <
            // environment:. File contents ARE interpolated at load time now
            // (docker parity — INTERP self-references BASE within the same
            // file); an unset reference still warns instead of throwing (RAW).
            // CROSS (in the later file) self-references BASE (defined in the
            // earlier file) — compose-go parity, the confirmed review-fix
            // regression: each env_file's lookup layers under every earlier
            // file's already-parsed values, not just that file's own. A bare
            // environment KEY unset in the effective env falls back to the
            // env_file value without a warning.
            let plan = try Compose.parse(text: """
            services:
              app:
                image: alpine
                env_file:
                  - base.env
                  - path: sub/more.env
                  - { path: missing.env, required: false }
                environment: [OVERLAP=explicit, FALLBACK]
            """, projectName: "envfile", baseDir: dir.path)
            guard plan.services[0].processArgs == [
                "--env", "BASE=one", "--env", "CROSS=one-cross", "--env", "EXTRA=two", "--env", "FALLBACK=fromfile",
                "--env", "INTERP=one-two", "--env", "RAW=", "--env", "SHARED=later",
                "--env", "OVERLAP=explicit",
            ] else { throw CLIError(command: "selftest", message: "env_file merge wrong: \(plan.services[0].processArgs)") }
            guard plan.warnings.count == 1, plan.warnings[0].contains("\"NOT_INTERPOLATED\"") else {
                throw CLIError(command: "selftest", message: "env_file interpolation warning wrong: \(plan.warnings)")
            }
            // string form; missing file without required: false is an error
            let single = try Compose.parse(
                text: "services: {app: {image: alpine, env_file: base.env}}",
                projectName: "envfile", baseDir: dir.path)
            guard single.services[0].processArgs == [
                "--env", "BASE=one", "--env", "INTERP=one-two", "--env", "RAW=", "--env", "SHARED=base",
            ] else { throw CLIError(command: "selftest", message: "env_file string form wrong: \(single.services[0].processArgs)") }
            do {
                _ = try Compose.parse(
                    text: "services: {app: {image: alpine, env_file: nope.env}}",
                    projectName: "envfile", baseDir: dir.path)
                throw CLIError(command: "selftest", message: "missing env_file not rejected")
            } catch Compose.Error.envFileNotFound(let p) {
                guard p.hasSuffix("/nope.env") else {
                    throw CLIError(command: "selftest", message: "env_file path not resolved against the compose dir: \(p)")
                }
            }

            // entrypoint: string → --entrypoint (shell-split, so a multi-word
            // string behaves like the list form); list → head + argv prepend;
            // empty → warning, ignored. cliPreview shows the exact flags.
            let entry = try Compose.parse(text: """
            services:
              s: {image: x, entrypoint: /entry.sh}
              multi: {image: x, entrypoint: /entry.sh --flag}
              l:
                image: x
                entrypoint: [/bin/sh, -c, "echo hi"]
                command: [more]
              e: {image: x, entrypoint: ""}
              el: {image: x, entrypoint: []}
            """, projectName: "entry")
            let byName = Dictionary(uniqueKeysWithValues: entry.services.map { ($0.service, $0) })
            // Every service also carries the ownership label; compare with it
            // stripped so this step stays about entrypoint mapping.
            func flags(_ svc: Compose.ServicePlan?) -> [String] {
                var args = svc?.managementArgs ?? []
                while let i = args.firstIndex(of: "--label"), i + 1 < args.count,
                      args[i + 1].hasPrefix(Compose.projectLabel + "=") {
                    args.removeSubrange(i...(i + 1))
                }
                return args
            }
            guard flags(byName["s"]) == ["--entrypoint", "/entry.sh"], byName["s"]?.commandArgs == [],
                  flags(byName["multi"]) == ["--entrypoint", "/entry.sh"], byName["multi"]?.commandArgs == ["--flag"],
                  flags(byName["l"]) == ["--entrypoint", "/bin/sh"], byName["l"]?.commandArgs == ["-c", "echo hi", "more"]
            else { throw CLIError(command: "selftest", message: "entrypoint mapping wrong: \(entry.services)") }
            guard byName["s"]?.cliPreview == "container run --detach --name entry-s --entrypoint /entry.sh --label com.davit.compose.project=entry x",
                  byName["l"]?.cliPreview == "container run --detach --name entry-l --entrypoint /bin/sh --label com.davit.compose.project=entry x -c 'echo hi' more"
            else { throw CLIError(command: "selftest", message: "entrypoint cliPreview wrong: \(byName["l"]?.cliPreview ?? "")") }
            guard flags(byName["e"]) == [], flags(byName["el"]) == [],
                  entry.warnings.filter({ $0.contains("entrypoint is empty") }).count == 2,
                  !entry.warnings.contains(where: { $0.contains("not supported") })
            else { throw CLIError(command: "selftest", message: "empty entrypoint warnings wrong: \(entry.warnings)") }
        }
        await step("compose: stop keys + external declarations") {
            let yaml = """
            services:
              a:
                image: x
                stop_grace_period: 1m30s
                stop_signal: SIGUSR1
              b:
                image: y
                stop_grace_period: soonish
            volumes:
              keep: { external: true }
              mine:
            networks:
              theirs: { external: true }
              ours:
            """
            let plan = try Compose.parse(text: yaml, projectName: "stops")
            let a = plan.services.first { $0.service == "a" }!
            let b = plan.services.first { $0.service == "b" }!
            guard a.stopGracePeriod == 90, a.stopSignal == "SIGUSR1" else {
                throw CLIError(command: "selftest", message: "stop keys wrong: \(String(describing: a.stopGracePeriod)) \(String(describing: a.stopSignal))")
            }
            // Unparsable grace falls back to the default with a warning; the new
            // keys must not surface as "not supported". Only one warning expected.
            guard b.stopGracePeriod == nil, b.stopSignal == nil,
                  plan.warnings.count == 1,
                  plan.warnings[0].contains("stop_grace_period"), plan.warnings[0].contains("not a duration")
            else { throw CLIError(command: "selftest", message: "stop-key warnings wrong: \(plan.warnings)") }
            guard plan.volumes == ["keep", "mine"], plan.externalVolumes == ["keep"],
                  plan.networks == ["ours", "theirs"], plan.externalNetworks == ["theirs"]
            else { throw CLIError(command: "selftest", message: "external declarations wrong: \(plan.volumes) \(plan.externalVolumes) \(plan.networks) \(plan.externalNetworks)") }
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
                _ = try await upTask.value

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
                    _ = try await Compose.up(plan: failing) { _, _ in }
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
                    _ = try await Compose.up(plan: exiting) { _, _ in }
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
                _ = try await Compose.up(plan: plan) { _, _ in }
                let a1 = try await record("davit-selftest-idem-a")
                let b1 = try await record("davit-selftest-idem-b")
                guard a1.isRunning, b1.isRunning else {
                    throw CLIError(command: "selftest", message: "fixture not running after first up")
                }

                // Second up reuses both running containers: no error, both service
                // steps reported done, and the creation dates prove no recreate.
                let events = ProgressLog()
                _ = try await Compose.up(plan: plan) { events.append($0, $1) }
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
                _ = try await Compose.up(plan: plan) { _, _ in }
                let a3 = try await record("davit-selftest-idem-a")
                let b3 = try await record("davit-selftest-idem-b")
                guard a3.isRunning, a3.configuration.creationDate == a1.configuration.creationDate else {
                    throw CLIError(command: "selftest", message: "running service was not left untouched")
                }
                guard b3.isRunning, b3.configuration.creationDate != b1.configuration.creationDate else {
                    throw CLIError(command: "selftest", message: "stopped service was not recreated")
                }

                // A name-colliding container compose never created (no project
                // label) is the user's: up must REFUSE, not delete or adopt it.
                await cleanup()
                try await ContainerService.runContainer(
                    image: "alpine:latest", name: "davit-selftest-idem-a",
                    processArgs: [], managementArgs: [], resourceArgs: [],
                    commandArgs: ["sleep", "300"])
                try await ContainerService.stop("davit-selftest-idem-a")
                let pre = try await record("davit-selftest-idem-a")
                do {
                    _ = try await Compose.up(plan: plan) { _, _ in }
                    throw CLIError(command: "selftest", message: "up did not refuse a foreign stopped container")
                } catch Compose.Error.foreignContainer(let n) {
                    guard n == "davit-selftest-idem-a" else {
                        throw CLIError(command: "selftest", message: "foreign refusal named wrong container: \(n)")
                    }
                }
                let a4 = try await record("davit-selftest-idem-a")
                guard !a4.isRunning, a4.configuration.creationDate == pre.configuration.creationDate else {
                    throw CLIError(command: "selftest", message: "foreign container was touched by refused up")
                }

                // Same for a RUNNING foreign container: refused, not adopted.
                try await ContainerService.start("davit-selftest-idem-a")
                do {
                    _ = try await Compose.up(plan: plan) { _, _ in }
                    throw CLIError(command: "selftest", message: "up did not refuse a foreign running container")
                } catch Compose.Error.foreignContainer { /* expected */ }
            } catch {
                await cleanup()
                throw error
            }
            await cleanup()
        }
        await step("compose: service-name hosts sync") {
            // admin is deliberately OUTSIDE migrator's dependency closure: a
            // scoped up must still patch it (new migrator IP) and must not
            // erase its entries from the others' managed blocks.
            let names = ["davit-selftest-hosts-db", "davit-selftest-hosts-migrator",
                         "davit-selftest-hosts-admin"]
            func cleanup() async {
                for n in names { try? await ContainerService.delete(n, force: true) }
            }
            await cleanup()  // leftovers from a previous aborted run

            let plan = try Compose.parse(text: """
            name: davit-selftest-hosts
            services:
              db:
                image: alpine:latest
                command: ["sleep", "600"]
              migrator:
                image: alpine:latest
                command: ["sleep", "600"]
                depends_on: [db]
              admin:
                image: alpine:latest
                command: ["sleep", "600"]
            """, projectName: "ignored")
            func record(_ name: String) async throws -> ContainerRecord {
                guard let r = try await ContainerService.listContainers().first(where: { $0.id == name }) else {
                    throw CLIError(command: "selftest", message: "\(name) missing")
                }
                return r
            }
            func ip(_ name: String) async throws -> String {
                guard let ip = try await record(name).primaryIPv4 else {
                    throw CLIError(command: "selftest", message: "\(name) has no IPv4")
                }
                return ip
            }
            func resolved(_ host: String, in container: String) async throws -> String {
                let result = try await ContainerService.exec(container, ["getent", "hosts", host])
                guard result.exitCode == 0,
                      let first = result.stdoutString.split(whereSeparator: \.isWhitespace).first else {
                    throw CLIError(command: "selftest", message: "getent hosts \(host) in \(container) failed (exit \(result.exitCode)): \(result.stderr)")
                }
                return String(first)
            }
            do {
                let up = try await Compose.up(plan: plan) { _, _ in }
                guard up.warnings.isEmpty else {
                    throw CLIError(command: "selftest", message: "hosts sync warned on alpine: \(up.warnings)")
                }
                let dbIP = try await ip(names[0])
                let migratorIP = try await ip(names[1])
                let adminIP = try await ip(names[2])
                guard try await resolved("db", in: names[1]) == dbIP,
                      try await resolved("migrator", in: names[0]) == migratorIP,
                      try await resolved("admin", in: names[0]) == adminIP
                else { throw CLIError(command: "selftest", message: "service names not cross-resolved after up") }

                // The user scenario: recreate only the migrator. The selected up
                // must reuse the running db yet still patch its hosts with the
                // migrator's new IP (and give the fresh migrator db's entry).
                let dbCreated = try await record(names[0]).configuration.creationDate
                try await ContainerService.delete(names[1], force: true)
                _ = try await Compose.up(plan: plan.selecting(services: ["migrator"], activeProfiles: [])) { _, _ in }
                guard try await record(names[0]).configuration.creationDate == dbCreated else {
                    throw CLIError(command: "selftest", message: "selected up recreated the running db")
                }
                let newIP = try await ip(names[1])
                guard try await resolved("migrator", in: names[0]) == newIP,
                      try await resolved("db", in: names[1]) == dbIP
                else { throw CLIError(command: "selftest", message: "hosts not re-synced after selected up") }
                // The unselected admin: its entries survive in the others'
                // blocks (the rewrite covers the whole project, not just the
                // selection), it learns the new migrator IP, and the fresh
                // migrator gets an admin entry too.
                guard try await resolved("admin", in: names[0]) == adminIP,
                      try await resolved("migrator", in: names[2]) == newIP,
                      try await resolved("admin", in: names[1]) == adminIP
                else { throw CLIError(command: "selftest", message: "unselected service's hosts entries lost after selected up") }
                // The rewrite replaces, never accumulates: exactly one managed
                // migrator line in db, carrying the new IP (old line gone).
                let hosts = try await ContainerService.exec(names[0], ["cat", "/etc/hosts"]).stdoutString
                let managed = hosts.split(separator: "\n").filter { $0.hasSuffix("# davit-compose") && $0.contains(" migrator ") }
                guard managed.count == 1, managed[0].hasPrefix("\(newIP) ") else {
                    throw CLIError(command: "selftest", message: "managed migrator lines in db wrong: \(managed)")
                }
            } catch {
                await cleanup()
                throw error
            }
            await cleanup()
        }
        await step("compose: up → ps → down") {
            let names = ["davit-selftest-updown-one", "davit-selftest-updown-two"]
            func cleanup() async {
                for n in names { try? await ContainerService.delete(n, force: true) }
                try? await ContainerService.deleteNetwork("davit-selftest-updown-net")
                try? await ContainerService.deleteVolume("davit-selftest-updown-vol")
            }
            await cleanup()  // leftovers from a previous aborted run

            let plan = try Compose.parse(text: """
            name: davit-selftest-updown
            services:
              one:
                image: alpine:latest
                command: ["sleep", "300"]
                volumes: [davit-selftest-updown-vol:/data]
                networks: [davit-selftest-updown-net]
              two:
                image: alpine:latest
                command: ["sleep", "300"]
                depends_on: [one]
            volumes: { davit-selftest-updown-vol: }
            networks: { davit-selftest-updown-net: }
            """, projectName: "ignored")
            func haveNetwork() async throws -> Bool {
                try await ContainerService.listNetworks().map(\.name).contains("davit-selftest-updown-net")
            }
            func haveVolume() async throws -> Bool {
                try await ContainerService.listVolumes().map(\.name).contains("davit-selftest-updown-vol")
            }
            do {
                _ = try await Compose.up(plan: plan) { _, _ in }
                let rows = try await Compose.ps(plan: plan)
                guard rows.map(\.service) == ["one", "two"],
                      rows.map(\.container) == names,
                      rows.allSatisfy({ $0.state == "running" })
                else { throw CLIError(command: "selftest", message: "ps after up wrong: \(rows)") }

                // Service-scoped down: exactly that container falls; the declared
                // network and volume (and the other service) stay untouched.
                let scoped = try await Compose.down(plan: plan, services: ["two"]) { _, _ in }
                guard scoped.isEmpty, try await Compose.ps(plan: plan).map(\.service) == ["one"],
                      try await haveNetwork(), try await haveVolume()
                else { throw CLIError(command: "selftest", message: "scoped down removed too much") }
                do {
                    _ = try await Compose.down(plan: plan, services: ["nope"]) { _, _ in }
                    throw CLIError(command: "selftest", message: "down with unknown service not rejected")
                } catch Compose.Error.noSuchService("nope") { /* expected */ }

                // Full down (reusing one, recreating two first): containers gone in
                // reverse dependency order, declared network gone, volume KEPT.
                _ = try await Compose.up(plan: plan) { _, _ in }
                let events = ProgressLog()
                _ = try await Compose.down(plan: plan) { events.append($0, $1) }
                let seen = events.all
                guard let twoDone = seen.firstIndex(where: { $0.0 == .service("two") && $0.1 }),
                      let oneDone = seen.firstIndex(where: { $0.0 == .service("one") && $0.1 }),
                      twoDone < oneDone
                else { throw CLIError(command: "selftest", message: "down order wrong: \(seen)") }
                guard try await Compose.ps(plan: plan).isEmpty,
                      try await !haveNetwork(), try await haveVolume()
                else { throw CLIError(command: "selftest", message: "full down should remove containers + network, keep the volume") }

                // Idempotent: a second down finds nothing and stays silent.
                guard try await Compose.down(plan: plan, progress: { _, _ in }).isEmpty else {
                    throw CLIError(command: "selftest", message: "second down should be a warning-free no-op")
                }

                // down -v also removes the declared volume.
                _ = try await Compose.up(plan: plan) { _, _ in }
                _ = try await Compose.down(plan: plan, removeVolumes: true) { _, _ in }
                guard try await Compose.ps(plan: plan).isEmpty,
                      try await !haveNetwork(), try await !haveVolume()
                else { throw CLIError(command: "selftest", message: "down -v should remove the declared volume too") }
            } catch {
                await cleanup()
                throw error
            }
            await cleanup()
        }
        await step("compose: --down-on-failure teardown primitives") {
            // I3 fixture: a starts fine; b's image can never resolve, so up
            // fails partway through with a already running — exactly the
            // situation --down-on-failure exists for. The flag's CLI-level
            // orchestration (Main.swift ComposeCLI.run) just composes these
            // two calls: default (no flag) leaves a running; with the flag
            // it also runs the down below. (The flag parsing/print/rethrow
            // itself is exercised by a CLI round-trip, not here — the CLI
            // dispatcher exits the process on completion.)
            let names = ["davit-selftest-dof-a", "davit-selftest-dof-b"]
            func cleanup() async {
                for n in names { try? await ContainerService.delete(n, force: true) }
            }
            await cleanup()  // leftovers from a previous aborted run

            let plan = try Compose.parse(text: """
            name: davit-selftest-dof
            services:
              a:
                image: alpine:latest
                command: ["sleep", "600"]
              b:
                image: davit-selftest-nonexistent-tag:does-not-exist
            """, projectName: "ignored")

            do {
                var upFailed = false
                do {
                    _ = try await Compose.up(plan: plan) { _, _ in }
                } catch {
                    upFailed = true
                }
                guard upFailed else {
                    throw CLIError(command: "selftest", message: "up with an unresolvable image did not fail")
                }
                let a1 = try await ContainerService.listContainers().first { $0.id == "davit-selftest-dof-a" }
                guard a1?.isRunning == true else {
                    throw CLIError(command: "selftest", message: "default (no flag) up should leave a running after b fails")
                }

                // What --down-on-failure does next: a whole-project down
                // (no services named), same as the CLI teardown path when
                // the failed up wasn't itself scoped to specific services.
                _ = try await Compose.down(plan: plan, removeVolumes: false) { _, _ in }
                guard try await Compose.ps(plan: plan).isEmpty else {
                    throw CLIError(command: "selftest", message: "teardown after failed up should leave no project containers")
                }
            } catch {
                await cleanup()
                throw error
            }
            await cleanup()
        }
        await step("compose: --down-on-failure spares reused services (I5 review fix)") {
            // Regression for the confirmed review finding: a whole-project
            // --down-on-failure teardown must not destroy services a PRIOR
            // up already had running and this up merely reused. a, b come up
            // healthy first; a second up against a plan that also adds c
            // (unresolvable image) reuses a/b untouched and fails on c —
            // onServiceTouched must report only "c", and a down scoped via
            // limitContainersTo: touched must leave a/b running.
            let names = ["davit-selftest-dof2-a", "davit-selftest-dof2-b"]
            func cleanup() async {
                for n in names { try? await ContainerService.delete(n, force: true) }
            }
            await cleanup()  // leftovers from a previous aborted run

            let basePlan = try Compose.parse(text: """
            name: davit-selftest-dof2
            services:
              a:
                image: alpine:latest
                command: ["sleep", "600"]
              b:
                image: alpine:latest
                command: ["sleep", "600"]
            """, projectName: "ignored")
            let extendedPlan = try Compose.parse(text: """
            name: davit-selftest-dof2
            services:
              a:
                image: alpine:latest
                command: ["sleep", "600"]
              b:
                image: alpine:latest
                command: ["sleep", "600"]
              c:
                image: davit-selftest-nonexistent-tag:does-not-exist
            """, projectName: "ignored")

            do {
                _ = try await Compose.up(plan: basePlan) { _, _ in }
                for n in ["davit-selftest-dof2-a", "davit-selftest-dof2-b"] {
                    let record = try await ContainerService.listContainers().first { $0.id == n }
                    guard record?.isRunning == true else {
                        throw CLIError(command: "selftest", message: "\(n) should be running before the second up")
                    }
                }

                let touched = TouchedServices()
                var upFailed = false
                do {
                    _ = try await Compose.up(plan: extendedPlan, onServiceTouched: { touched.insert($0) }) { _, _ in }
                } catch {
                    upFailed = true
                }
                guard upFailed else {
                    throw CLIError(command: "selftest", message: "up with an unresolvable image did not fail")
                }
                guard touched.all == ["c"] else {
                    throw CLIError(command: "selftest", message: "onServiceTouched should report only [\"c\"], got \(touched.all.sorted())")
                }

                _ = try await Compose.down(
                    plan: extendedPlan, removeVolumes: false, limitContainersTo: touched.all
                ) { _, _ in }

                for n in ["davit-selftest-dof2-a", "davit-selftest-dof2-b"] {
                    let record = try await ContainerService.listContainers().first { $0.id == n }
                    guard record?.isRunning == true else {
                        throw CLIError(command: "selftest", message: "\(n) (reused, untouched by the failed up) should survive a scoped teardown")
                    }
                }
                guard try await ContainerService.listContainers().first(where: { $0.id == "davit-selftest-dof2-c" }) == nil else {
                    throw CLIError(command: "selftest", message: "c should not exist after the failed up")
                }
            } catch {
                await cleanup()
                throw error
            }
            await cleanup()
        }
        await step("compose: logs (non-follow)") {
            let names = ["davit-selftest-logs-a", "davit-selftest-logs-longer"]
            func cleanup() async {
                for n in names { try? await ContainerService.delete(n, force: true) }
            }
            await cleanup()  // leftovers from a previous aborted run

            let plan = try Compose.parse(text: """
            name: davit-selftest-logs
            services:
              a:
                image: alpine:latest
                command: ["/bin/sh", "-c", "echo davit-logs-alpha1; echo davit-logs-alpha2; sleep 300"]
              longer:
                image: alpine:latest
                command: ["/bin/sh", "-c", "echo davit-logs-beta; sleep 300"]
            """, projectName: "ignored")
            func capture(services: [String] = [], tail: Int? = nil, skip: Set<String> = []) async throws -> String {
                let sink = OutputLog()
                try await Compose.logs(plan: plan, services: services, tail: tail, skipBacklogFor: skip) { sink.append($0) }
                return sink.text
            }
            do {
                _ = try await Compose.up(plan: plan) { _, _ in }
                // The echoes reach the daemon's log files asynchronously — poll
                // the real read path until both services' lines are visible.
                var all = ""
                for _ in 0..<60 {
                    all = try await capture()
                    if all.contains("davit-logs-alpha2"), all.contains("davit-logs-beta") { break }
                    try await Task.sleep(for: .milliseconds(500))
                }
                // The prefix column is aligned across containers: the shorter
                // name is padded to the longer one's width.
                let pad = String(repeating: " ", count: "davit-selftest-logs-longer".count - "davit-selftest-logs-a".count)
                guard all.contains("davit-selftest-logs-a\(pad)  | davit-logs-alpha1"),
                      all.contains("davit-selftest-logs-a\(pad)  | davit-logs-alpha2"),
                      all.contains("davit-selftest-logs-longer  | davit-logs-beta")
                else { throw CLIError(command: "selftest", message: "prefixed log lines missing: \(all.debugDescription)") }

                // --tail limits the backlog per container; naming a service
                // scopes the output to it (and re-aligns the prefix column).
                let tailed = try await capture(services: ["a"], tail: 1)
                guard tailed.contains("davit-selftest-logs-a  | davit-logs-alpha2"),
                      !tailed.contains("davit-logs-alpha1"), !tailed.contains("davit-logs-beta")
                else { throw CLIError(command: "selftest", message: "tail/scope wrong: \(tailed.debugDescription)") }

                // skipBacklogFor drops a service's backlog wholesale — up's
                // attach passes its reused set so old runs don't replay.
                let skipped = try await capture(skip: ["a"])
                guard !skipped.contains("davit-logs-alpha1"), !skipped.contains("davit-logs-alpha2"),
                      skipped.contains("davit-logs-beta")
                else { throw CLIError(command: "selftest", message: "skipBacklogFor wrong: \(skipped.debugDescription)") }
                do {
                    _ = try await capture(services: ["nope"])
                    throw CLIError(command: "selftest", message: "logs with unknown service not rejected")
                } catch Compose.Error.noSuchService("nope") { /* expected */ }
            } catch {
                await cleanup()
                throw error
            }
            await cleanup()
        }
        await step("compose: stop/start/restart + pull") {
            let names = ["davit-selftest-life-one", "davit-selftest-life-two"]
            func cleanup() async {
                for n in names { try? await ContainerService.delete(n, force: true) }
            }
            await cleanup()  // leftovers from a previous aborted run

            let plan = try Compose.parse(text: """
            name: davit-selftest-life
            services:
              one:
                image: alpine:latest
                command: ["sleep", "300"]
              two:
                image: alpine:latest
                command: ["sleep", "300"]
                depends_on: [one]
            """, projectName: "ignored")
            func running(_ name: String) async throws -> Bool? {
                try await ContainerService.listContainers().first { $0.id == name }?.isRunning
            }
            do {
                _ = try await Compose.up(plan: plan) { _, _ in }

                // exec resolution: service → running container name; unknown
                // services are clear errors (the exec round-trip itself is
                // covered by the file-browser step's ContainerService.exec).
                guard try await Compose.runningContainer(plan: plan, service: "one") == names[0] else {
                    throw CLIError(command: "selftest", message: "exec resolution wrong")
                }
                do {
                    _ = try await Compose.runningContainer(plan: plan, service: "nope")
                    throw CLIError(command: "selftest", message: "exec with unknown service not rejected")
                } catch Compose.Error.noSuchService("nope") { /* expected */ }

                // Docker parity: naming a service scopes stop/start to EXACTLY
                // it — the dependency stays up (a shared dep must not fall
                // with one consumer), and the scoped start brings it back.
                let scoped = try plan.selecting(services: ["two"], activeProfiles: [], includeDependencies: false)
                guard scoped.services.map(\.service) == ["two"] else {
                    throw CLIError(command: "selftest", message: "scoped selection wrong: \(scoped.services.map(\.service))")
                }
                try await Compose.stop(plan: scoped) { _, _ in }
                guard try await running(names[0]) == true, try await running(names[1]) == false else {
                    throw CLIError(command: "selftest", message: "scoped stop touched the dependency")
                }
                _ = try await Compose.start(plan: scoped) { _, _ in }
                guard try await running(names[1]) == true else {
                    throw CLIError(command: "selftest", message: "scoped start did not restart the service")
                }

                // stop: reverse dependency order; containers stay, ps shows stopped
                let stopEvents = ProgressLog()
                try await Compose.stop(plan: plan) { stopEvents.append($0, $1) }
                let stopSeen = stopEvents.all
                guard let twoStopped = stopSeen.firstIndex(where: { $0.0 == .service("two") && $0.1 }),
                      let oneStopped = stopSeen.firstIndex(where: { $0.0 == .service("one") && $0.1 }),
                      twoStopped < oneStopped
                else { throw CLIError(command: "selftest", message: "stop order wrong: \(stopSeen)") }
                let stopped = try await Compose.ps(plan: plan)
                guard stopped.map(\.service) == ["one", "two"], stopped.allSatisfy({ $0.state == "stopped" })
                else { throw CLIError(command: "selftest", message: "ps after stop wrong: \(stopped)") }

                // exec against a stopped (or never-created) service is a clear error
                do {
                    _ = try await Compose.runningContainer(plan: plan, service: "one")
                    throw CLIError(command: "selftest", message: "exec on a stopped service not rejected")
                } catch Compose.Error.serviceNotRunning("one") { /* expected */ }

                // second stop: idempotent no-op on already-stopped containers
                try await Compose.stop(plan: plan) { _, _ in }

                // start: dependency order, no healthcheck waits, both running again
                let startEvents = ProgressLog()
                let startWarnings = try await Compose.start(plan: plan) { startEvents.append($0, $1) }
                let startSeen = startEvents.all
                guard startWarnings.isEmpty,
                      let oneStarted = startSeen.firstIndex(where: { $0.0 == .service("one") && $0.1 }),
                      let twoStarted = startSeen.firstIndex(where: { $0.0 == .service("two") && $0.1 }),
                      oneStarted < twoStarted
                else { throw CLIError(command: "selftest", message: "start order/warnings wrong: \(startSeen) \(startWarnings)") }
                guard try await running(names[0]) == true, try await running(names[1]) == true else {
                    throw CLIError(command: "selftest", message: "containers not running after start")
                }

                // restart: exactly one step pair per service, both running after
                let restartEvents = ProgressLog()
                let restartWarnings = try await Compose.restart(plan: plan) { restartEvents.append($0, $1) }
                guard restartWarnings.isEmpty,
                      restartEvents.all.filter({ $0.0 == .service("one") && $0.1 }).count == 1,
                      restartEvents.all.filter({ $0.0 == .service("two") && $0.1 }).count == 1,
                      try await running(names[0]) == true, try await running(names[1]) == true
                else { throw CLIError(command: "selftest", message: "restart did not leave both running: \(restartEvents.all)") }

                // start with a never-created container: warning, the rest untouched
                try await ContainerService.delete(names[1], force: true)
                let missingWarnings = try await Compose.start(plan: plan) { _, _ in }
                guard missingWarnings.contains(where: { $0.contains("two has no container") }),
                      try await running(names[0]) == true
                else { throw CLIError(command: "selftest", message: "missing-container start warning wrong: \(missingWarnings)") }

                // pull: per-image header + done step; the stage lines between
                // them depend on the daemon's cache state, so don't assert them
                let single = try plan.selecting(services: ["one"], activeProfiles: [])
                let sink = OutputLog()
                let pullEvents = ProgressLog()
                try await Compose.pull(
                    plan: single,
                    progress: { pullEvents.append($0, $1) },
                    output: { sink.append($0) })
                guard sink.text.contains("pull: alpine:latest"),
                      pullEvents.all.contains(where: { $0.0 == .service("one") && $0.1 })
                else { throw CLIError(command: "selftest", message: "pull output wrong: \(sink.text.debugDescription) \(pullEvents.all)") }
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

/// Lock-protected sink for captured compose log output in the selftest.
final class OutputLog: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""
    func append(_ s: String) { lock.lock(); buffer += s; lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return buffer }
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

/// Lock-protected accumulator of service names an `up` actually (re)created
/// this invocation, fed by Compose.up's `onServiceTouched` callback. A
/// `--down-on-failure` teardown intersects against this so it never tears
/// down a service the up merely found already running and reused.
final class TouchedServices: @unchecked Sendable {
    private let lock = NSLock()
    private var names = Set<String>()
    func insert(_ name: String) { lock.lock(); names.insert(name); lock.unlock() }
    var all: Set<String> { lock.lock(); defer { lock.unlock() }; return names }
}

enum ExecMode {
    static func runBlocking(containerID: String, argv: [String]? = nil) {
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            await run(containerID: containerID, argv: argv)
            semaphore.signal()
        }
        semaphore.wait()
    }

    /// Attaches an interactive exec to a running container: `argv` runs as
    /// given, nil opens the default shell (bash when present, else sh). A TTY
    /// is allocated only when stdin is one — raw mode on a pipe would fail,
    /// and this way scripted invocations just stream (docker's -T behavior,
    /// applied automatically).
    static func run(containerID: String, argv: [String]? = nil) async {
        do {
            let client = ContainerClient()
            let container = try await client.get(id: containerID)
            guard container.status == .running else {
                FileHandle.standardError.write(Data("container \(containerID) is not running\n".utf8))
                exit(1)
            }

            // Base the exec process on the container's init process (env, user, cwd),
            // the same way `container exec` does.
            let tty = isatty(STDIN_FILENO) == 1
            var config = container.configuration.initProcess
            if let argv {
                config.executable = argv[0]
                config.arguments = Array(argv.dropFirst())
            } else {
                config.executable = "/bin/sh"
                config.arguments = ["-c", "command -v bash >/dev/null 2>&1 && exec bash || exec sh"]
            }
            config.terminal = tty
            if tty { config.environment.append("TERM=xterm-256color") }

            let io = try ProcessIO.create(tty: tty, interactive: true, detach: false)
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
