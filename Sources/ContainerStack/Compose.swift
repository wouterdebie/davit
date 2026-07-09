import ContainerAPIClient
import Foundation
import Yams

/// Docker Compose import: parse a compose file into a concrete creation plan —
/// named volumes and networks to create, then services as the same four flag
/// arrays the Run sheet feeds `Backend.runContainer`. apple/container has no
/// native compose, so this is pure app-side orchestration. The supported subset
/// is deliberate; everything else surfaces as a warning, never silently.
enum Compose {

    struct ServicePlan: Identifiable, Hashable {
        let service: String          // compose service key
        let name: String             // container name (container_name or <project>-<service>)
        let image: String
        var processArgs: [String]
        var managementArgs: [String]
        var resourceArgs: [String]
        var commandArgs: [String]
        var profiles: [String]       // empty = always enabled
        var healthcheck: Healthcheck?
        var dependsOn: [String: DependsCondition]
        var id: String { service }

        /// Equivalent `container run …` (what Davit performs over XPC).
        var cliPreview: String {
            var argv = ["container", "run", "--detach", "--name", name]
            argv += managementArgs + resourceArgs + processArgs
            argv.append(image)
            argv += commandArgs
            return argv.map(Compose.shellQuote).joined(separator: " ")
        }

        /// Paired `--network` values — the networks this service attaches to.
        var networkRefs: [String] { paired("--network") }

        /// Named-volume sources of `--mount type=volume,…` specs.
        var volumeRefs: [String] {
            paired("--mount").compactMap { spec in
                guard spec.hasPrefix("type=volume,") else { return nil }
                return spec.split(separator: ",").first { $0.hasPrefix("source=") }
                    .map { String($0.dropFirst("source=".count)) }
            }
        }

        private func paired(_ flag: String) -> [String] {
            managementArgs.indices.compactMap { i in
                managementArgs[i] == flag && i + 1 < managementArgs.count ? managementArgs[i + 1] : nil
            }
        }
    }

    struct Plan: Identifiable {
        var id: String { project }
        let project: String
        var volumes: [String]        // named volumes to create (missing ones only — caller filters)
        var networks: [String]       // networks to create
        var services: [ServicePlan]  // in dependency start order
        var warnings: [String]
    }

    /// Parsed healthcheck with docker defaults applied at parse time.
    struct Healthcheck: Hashable {
        let test: [String]           // probe command without the CMD/CMD-SHELL head
        let shellForm: Bool          // string or CMD-SHELL test — runs via /bin/sh -c
        let interval: Double         // seconds (docker default 30)
        let timeout: Double          // seconds (docker default 30)
        let retries: Int             // consecutive failures until unhealthy (default 3)
        let startPeriod: Double      // seconds; failures inside don't count (default 0)

        /// Concrete probe argv for `ContainerService.exec`.
        var argv: [String] { shellForm ? ["/bin/sh", "-c", test.joined(separator: " ")] : test }
    }

    enum DependsCondition: String, Hashable {
        case started = "service_started"
        case healthy = "service_healthy"
        case completedSuccessfully = "service_completed_successfully"
    }

    enum Error: Swift.Error, LocalizedError {
        case notAMapping
        case noServices
        case missingImage(service: String)
        case dependencyCycle([String])
        case unknownDependency(service: String, dependsOn: String)
        case missingHealthcheck(service: String, dependency: String)
        case noSuchService(String)
        case inactiveProfile(service: String, profile: String)
        case envFileNotFound(String)
        case requiredVariable(name: String, message: String)
        case unhealthy(service: String, failures: Int)
        case dependencyExited(service: String)
        case didNotComplete(service: String, exitCode: Int32?)

        var errorDescription: String? {
            switch self {
            case .notAMapping: return "not a compose file (top level is not a mapping)"
            case .noServices: return "no services defined"
            case .missingImage(let s): return "service \"\(s)\" has no image — build: is not supported yet"
            case .dependencyCycle(let names): return "depends_on cycle: \(names.joined(separator: " → "))"
            case .unknownDependency(let s, let d): return "service \"\(s)\" depends on unknown service \"\(d)\""
            case .missingHealthcheck(let s, let d): return "service \"\(s)\" needs \"\(d)\" healthy, but \"\(d)\" has no healthcheck"
            case .noSuchService(let s): return "no such service: \(s)"
            case .inactiveProfile(let s, let p): return "service \"\(s)\" requires profile \"\(p)\" — activate it with --profile \(p)"
            case .envFileNotFound(let p): return "env file not found: \(p)"
            case .requiredVariable(let name, let message):
                return "required variable \"\(name)\" is not set" + (message.isEmpty ? "" : ": \(message)")
            case .unhealthy(let s, let n): return "service \"\(s)\" is unhealthy after \(n) failed probes"
            case .dependencyExited(let s): return "service \"\(s)\" exited before becoming healthy"
            case .didNotComplete(let s, let code):
                return code.map { "service \"\(s)\" didn't complete successfully: exit \($0)" }
                    ?? "service \"\(s)\" wasn't started by this compose up, so its exit code is unknown"
            }
        }
    }

    // MARK: discovery

    /// Docker-style compose file autodiscovery. `COMPOSE_FILE` (single path,
    /// absolute or relative to `dir`) wins and is trusted as-is — a bad path
    /// surfaces when the file is read. Otherwise each directory from `dir` up
    /// to / is tried for the candidate names in docker's order; when both
    /// compose.yaml and compose.yml exist in the winning directory,
    /// compose.yaml wins with a warning (docker parity).
    static func discoverFile(
        startingAt dir: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> (path: String, warning: String?)? {
        if let override = environment["COMPOSE_FILE"], !override.isEmpty {
            let expanded = (override as NSString).expandingTildeInPath
            let path = expanded.hasPrefix("/")
                ? expanded
                : URL(fileURLWithPath: dir).appendingPathComponent(expanded).standardizedFileURL.path
            return (path, nil)
        }
        let candidates = ["compose.yaml", "compose.yml", "docker-compose.yml", "docker-compose.yaml"]
        var url = URL(fileURLWithPath: dir).standardizedFileURL
        while true {
            let present = candidates.filter { FileManager.default.fileExists(atPath: url.appendingPathComponent($0).path) }
            if let winner = present.first {
                let warning = present.contains("compose.yaml") && present.contains("compose.yml")
                    ? "both compose.yaml and compose.yml exist in \(url.path) — using compose.yaml"
                    : nil
                return (url.appendingPathComponent(winner).path, warning)
            }
            if url.path == "/" { return nil }
            url.deleteLastPathComponent()
        }
    }

    // MARK: environment + interpolation

    /// KEY=VALUE dotenv subset: whitespace trimmed, blank and #-comment lines
    /// skipped, optional `export ` prefix, one matching pair of single or
    /// double quotes stripped from the value — no escape processing beyond that.
    private static func parseDotEnv(text: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in text.split(separator: "\n") {
            var entry = line.trimmingCharacters(in: .whitespaces)
            if entry.isEmpty || entry.hasPrefix("#") { continue }
            if entry.hasPrefix("export ") { entry = String(entry.dropFirst("export ".count)) }
            guard let eq = entry.firstIndex(of: "=") else { continue }
            let key = entry[..<eq].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            var value = entry[entry.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2,
               (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            out[key] = value
        }
        return out
    }

    /// The environment interpolation sees: `<composeDir>/.env` (or an explicit
    /// env file) layered under the process environment — process wins (docker
    /// precedence). A missing default `.env` is simply absent; a missing
    /// explicit file is an error.
    static func effectiveEnvironment(
        composeDir: String,
        envFile: String? = nil,
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> [String: String] {
        let path = envFile ?? URL(fileURLWithPath: composeDir).appendingPathComponent(".env").path
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            if envFile != nil { throw Error.envFileNotFound(path) }
            return processEnvironment
        }
        return parseDotEnv(text: text).merging(processEnvironment) { _, process in process }
    }

    /// Replaces `${VAR}` in every string VALUE of the loaded YAML tree (never
    /// mapping keys), so the per-key parsing only ever sees resolved values.
    private static func interpolate(
        _ node: Any, environment: [String: String], warned: inout Set<String>, warnings: inout [String]
    ) throws -> Any {
        switch node {
        case let s as String:
            return try substitute(s, environment: environment, warned: &warned, warnings: &warnings)
        case let map as [String: Any]:
            var out = map
            for (k, v) in map { out[k] = try interpolate(v, environment: environment, warned: &warned, warnings: &warnings) }
            return out
        case let list as [Any]:
            return try list.map { try interpolate($0, environment: environment, warned: &warned, warnings: &warnings) }
        default:
            return node
        }
    }

    /// Compose substitution grammar: `$VAR`, `${VAR}`, `${VAR:-def}`,
    /// `${VAR-def}`, `${VAR:?err}`, `${VAR?err}`, `$$` → literal `$`; the `:`
    /// variants treat set-but-empty as unset. Unset plain substitution → empty
    /// string plus one warning per variable. Single pass, single level — a
    /// default is taken literally, nested `${…}` inside it is not expanded.
    private static func substitute(
        _ s: String, environment: [String: String], warned: inout Set<String>, warnings: inout [String]
    ) throws -> String {
        guard s.contains("$") else { return s }
        func nameStart(_ c: Character) -> Bool { c == "_" || ("A"..."Z").contains(c) || ("a"..."z").contains(c) }
        func nameChar(_ c: Character) -> Bool { nameStart(c) || ("0"..."9").contains(c) }
        func lookup(_ name: String) -> String {
            if let value = environment[name] { return value }
            if warned.insert(name).inserted {
                warnings.append("variable \"\(name)\" is not set — substituting an empty string")
            }
            return ""
        }
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            guard s[i] == "$", s.index(after: i) < s.endIndex else {
                out.append(s[i]); i = s.index(after: i); continue
            }
            let next = s.index(after: i)
            if s[next] == "$" {                                    // $$ → literal $
                out.append("$")
                i = s.index(after: next)
            } else if s[next] == "{" {
                guard let close = s[s.index(after: next)...].firstIndex(of: "}") else {
                    out += s[i...]                                 // unterminated ${… — literal
                    break
                }
                let body = s[s.index(after: next)..<close]
                var j = body.startIndex
                while j < body.endIndex, nameChar(body[j]) { j = body.index(after: j) }
                let name = String(body[..<j])
                let rest = body[j...]
                let emptyIsUnset = rest.hasPrefix(":")
                let op = emptyIsUnset ? rest.dropFirst() : rest
                let value = environment[name].flatMap { emptyIsUnset && $0.isEmpty ? nil : $0 }
                if name.isEmpty {
                    out += s[i...close]                            // "${}" and friends — literal
                } else if rest.isEmpty {                           // ${VAR}
                    out += lookup(name)
                } else if op.hasPrefix("-") {                      // ${VAR-def} / ${VAR:-def}
                    out += value ?? String(op.dropFirst())
                } else if op.hasPrefix("?") {                      // ${VAR?err} / ${VAR:?err}
                    guard let value else {
                        throw Error.requiredVariable(name: name, message: String(op.dropFirst()))
                    }
                    out += value
                } else {
                    warnings.append("\"${\(body)}\" is not a supported substitution — left as-is")
                    out += s[i...close]
                }
                i = s.index(after: close)
            } else if nameStart(s[next]) {                         // bare $VAR
                var j = s.index(after: next)
                while j < s.endIndex, nameChar(s[j]) { j = s.index(after: j) }
                out += lookup(String(s[next..<j]))
                i = j
            } else {
                out.append("$")                                    // $ before a non-name char — literal
                i = next
            }
        }
        return out
    }

    // MARK: parse

    static func parse(
        text: String, projectName: String, baseDir: String? = nil,
        environment: [String: String] = [:]
    ) throws -> Plan {
        guard let loaded = try Yams.load(yaml: text) as? [String: Any] else { throw Error.notAMapping }

        var warnings: [String] = []
        // Interpolate before any per-key parsing, so ports, volumes, durations
        // and commands below only ever see resolved values.
        var warnedUnset = Set<String>()
        guard let root = try interpolate(
            loaded, environment: environment, warned: &warnedUnset, warnings: &warnings) as? [String: Any]
        else { throw Error.notAMapping }
        guard let services = root["services"] as? [String: Any], !services.isEmpty else { throw Error.noServices }

        if root["version"] != nil { /* informational only in modern compose; ignore silently */ }
        for key in root.keys where !["services", "volumes", "networks", "version", "name"].contains(key) {
            warnings.append("top-level \"\(key)\" is ignored")
        }
        let project = (root["name"] as? String) ?? projectName

        let topVolumes = (root["volumes"] as? [String: Any]).map { Array($0.keys) } ?? []
        let topNetworks = (root["networks"] as? [String: Any]).map { Array($0.keys) } ?? []

        var plans: [String: ServicePlan] = [:]
        for (svcName, svcAny) in services {
            guard let svc = svcAny as? [String: Any] else {
                warnings.append("service \"\(svcName)\" is not a mapping — skipped")
                continue
            }
            let (plan, svcWarnings) = try parseService(
                key: svcName, svc: svc, project: project, declaredNetworks: topNetworks,
                baseDir: baseDir, environment: environment)
            plans[svcName] = plan
            warnings += svcWarnings
        }
        guard !plans.isEmpty else { throw Error.noServices }

        // depends_on → start order (topological). Conditions are honored at up time.
        let ordered = try topoSort(
            services: plans.keys.sorted(),
            dependsOn: plans.mapValues { $0.dependsOn.keys.sorted() })

        // service_healthy requires the dependency to define a healthcheck (docker parity).
        for svcName in ordered {
            for (dep, condition) in (plans[svcName]?.dependsOn ?? [:]).sorted(by: { $0.key < $1.key })
            where condition == .healthy && plans[dep]?.healthcheck == nil {
                throw Error.missingHealthcheck(service: svcName, dependency: dep)
            }
        }

        return Plan(
            project: project,
            volumes: topVolumes.sorted(),
            networks: topNetworks.sorted(),
            services: ordered.compactMap { plans[$0] },
            warnings: warnings
        )
    }

    // MARK: service

    private static func parseService(
        key: String, svc: [String: Any], project: String, declaredNetworks: [String],
        baseDir: String?, environment: [String: String]
    ) throws -> (ServicePlan, warnings: [String]) {
        var warnings: [String] = []

        guard let image = svc["image"] as? String, !image.isEmpty else {
            throw Error.missingImage(service: key)
        }
        let name = (svc["container_name"] as? String) ?? "\(project)-\(key)"

        var process: [String] = []
        var management: [String] = []
        var resource: [String] = []

        // environment: map or list form
        switch svc["environment"] {
        case let map as [String: Any]:
            for (k, v) in map.sorted(by: { $0.key < $1.key }) {
                process += ["--env", "\(k)=\(scalarString(v))"]
            }
        case let list as [Any]:
            // KEY=VALUE passes through; a bare KEY resolves from the effective
            // environment (docker parity) or is omitted with a warning.
            for entry in list {
                let s = scalarString(entry)
                if s.contains("=") {
                    process += ["--env", s]
                } else if let value = environment[s] {
                    process += ["--env", "\(s)=\(value)"]
                } else {
                    warnings.append("\(key): environment variable \(s) is not set — omitted")
                }
            }
        case nil: break
        default: warnings.append("\(key): unrecognized environment format — ignored")
        }

        if let user = svc["user"] as? String { process += ["--user", user] }
        if let workdir = svc["working_dir"] as? String { process += ["--workdir", workdir] }

        // ports: "H:C[/proto]" short form or long form mappings
        for port in svc["ports"] as? [Any] ?? [] {
            if let s = port as? String {
                var spec = s
                if let slash = spec.firstIndex(of: "/") {
                    let proto = spec[spec.index(after: slash)...]
                    if proto != "tcp" { warnings.append("\(key): port \(s) — only tcp is supported, publishing as tcp") }
                    spec = String(spec[..<slash])
                }
                let parts = spec.split(separator: ":").map(String.init)
                switch parts.count {
                case 2: management += ["--publish", "\(parts[0]):\(parts[1])"]
                case 3...: management += ["--publish", spec]  // IP:host:container — the IP may itself contain colons ("[::1]"), pass through verbatim
                default: warnings.append("\(key): port \"\(s)\" — container-only ports need an explicit host port; ignored")
                }
            } else if let m = port as? [String: Any],
                      let target = m["target"] {
                if let published = m["published"] {
                    var spec = "\(scalarString(published)):\(scalarString(target))"
                    if let ip = m["host_ip"] { spec = "\(scalarString(ip)):\(spec)" }
                    management += ["--publish", spec]
                } else {
                    warnings.append("\(key): port target \(scalarString(target)) has no published port — ignored")
                }
            }
        }

        // volumes: short "src:dst[:ro]" or long form
        for vol in svc["volumes"] as? [Any] ?? [] {
            if let s = vol as? String {
                var parts = s.split(separator: ":").map(String.init)
                var readonly = false
                if parts.count == 3 {
                    readonly = parts[2].split(separator: ",").contains("ro")
                    parts.removeLast()
                }
                guard parts.count == 2 else {
                    warnings.append("\(key): volume \"\(s)\" — anonymous volumes not supported; ignored")
                    continue
                }
                management += ["--mount", mountSpec(source: parts[0], target: parts[1], readonly: readonly, baseDir: baseDir)]
            } else if let m = vol as? [String: Any],
                      let type = m["type"] as? String, let target = m["target"] as? String {
                let source = m["source"] as? String ?? ""
                let readonly = (m["read_only"] as? Bool) ?? false
                switch type {
                case "bind", "volume" where !source.isEmpty:
                    management += ["--mount", mountSpec(source: source, target: target, readonly: readonly, baseDir: baseDir)]
                case "tmpfs":
                    management += ["--tmpfs", target]
                default:
                    warnings.append("\(key): volume type \"\(type)\" not supported — ignored")
                }
            }
        }

        // networks: list or map form; "default" means the platform default (no flag)
        var networkRefs: [String] = []
        switch svc["networks"] {
        case let list as [Any]: networkRefs = list.map { scalarString($0) }
        case let map as [String: Any]: networkRefs = map.keys.sorted()
        case nil: break
        default: warnings.append("\(key): unrecognized networks format — ignored")
        }
        for net in networkRefs where net != "default" {
            if !declaredNetworks.contains(net) {
                warnings.append("\(key): network \"\(net)\" not declared top-level — will be created")
            }
            management += ["--network", net]
        }
        if networkRefs.filter({ $0 != "default" }).count > 1 {
            warnings.append("\(key): multiple networks — the platform attaches all, but cross-network aliasing is not supported")
        }

        // resources: v2 keys or v3 deploy.resources.limits
        if let cpus = svc["cpus"] { resource += ["--cpus", scalarString(cpus)] }
        if let mem = svc["mem_limit"] { resource += ["--memory", scalarString(mem)] }
        if let deploy = svc["deploy"] as? [String: Any],
           let resources = deploy["resources"] as? [String: Any],
           let limits = resources["limits"] as? [String: Any] {
            if let cpus = limits["cpus"] { resource += ["--cpus", scalarString(cpus)] }
            if let mem = limits["memory"] { resource += ["--memory", scalarString(mem)] }
        }

        // command: string or list
        var command: [String] = []
        switch svc["command"] {
        case let s as String: command = shellSplit(s)
        case let list as [Any]: command = list.map { scalarString($0) }
        case nil: break
        default: warnings.append("\(key): unrecognized command format — ignored")
        }

        // depends_on: list form (→ started) or map with condition
        var deps: [String: DependsCondition] = [:]
        switch svc["depends_on"] {
        case let list as [Any]:
            for entry in list { deps[scalarString(entry)] = .started }
        case let map as [String: Any]:
            for (dep, spec) in map.sorted(by: { $0.key < $1.key }) {
                var condition = DependsCondition.started
                if let m = spec as? [String: Any] {
                    if let raw = m["condition"] as? String {
                        if let parsed = DependsCondition(rawValue: raw) {
                            condition = parsed
                        } else {
                            warnings.append("\(key): depends_on \(dep) condition \"\(raw)\" is unknown — treating as service_started")
                        }
                    }
                    if (m["required"] as? Bool) == false {
                        warnings.append("\(key): depends_on \(dep) \"required: false\" is not supported — dependency treated as required")
                    }
                }
                deps[dep] = condition
            }
        case nil: break
        default: break
        }

        // profiles: list of strings; filtering happens in Plan.selecting
        var profiles: [String] = []
        switch svc["profiles"] {
        case let list as [Any]: profiles = list.map { scalarString($0) }
        case nil: break
        default: warnings.append("\(key): unrecognized profiles format — ignored")
        }

        var healthcheck: Healthcheck? = nil
        switch svc["healthcheck"] {
        case let hc as [String: Any]: healthcheck = parseHealthcheck(key: key, hc: hc, warnings: &warnings)
        case nil: break
        default: warnings.append("\(key): unrecognized healthcheck format — ignored")
        }

        // Everything we understand is handled above; name the rest honestly.
        let handled: Set<String> = [
            "image", "container_name", "environment", "user", "working_dir", "ports",
            "volumes", "networks", "cpus", "mem_limit", "deploy", "command", "depends_on",
            "profiles", "healthcheck",
        ]
        for k in svc.keys.sorted() where !handled.contains(k) {
            warnings.append("\(key): \"\(k)\" is not supported — ignored")
        }

        let plan = ServicePlan(
            service: key, name: name, image: image,
            processArgs: process, managementArgs: management,
            resourceArgs: resource, commandArgs: command,
            profiles: profiles, healthcheck: healthcheck, dependsOn: deps)
        return (plan, warnings)
    }

    /// nil (no probe) for `disable: true`, `test: NONE`, or an unusable test.
    private static func parseHealthcheck(key: String, hc: [String: Any], warnings: inout [String]) -> Healthcheck? {
        if (hc["disable"] as? Bool) == true { return nil }
        var test: [String] = []
        var shellForm = false
        switch hc["test"] {
        case let s as String:
            test = [s]; shellForm = true
        case let list as [Any]:
            let parts = list.map { scalarString($0) }
            switch parts.first {
            case "NONE": return nil
            case "CMD": test = Array(parts.dropFirst())
            case "CMD-SHELL": test = Array(parts.dropFirst()); shellForm = true
            default:
                warnings.append("\(key): healthcheck test must start with CMD, CMD-SHELL or NONE — ignored")
                return nil
            }
        default:
            warnings.append("\(key): healthcheck has no test — ignored")
            return nil
        }
        if test.isEmpty {
            warnings.append("\(key): healthcheck test is empty — ignored")
            return nil
        }
        func duration(_ field: String, default def: Double) -> Double {
            guard let raw = hc[field] else { return def }
            if let seconds = parseDuration(scalarString(raw)) { return seconds }
            warnings.append("\(key): healthcheck \(field) \"\(scalarString(raw))\" is not a duration — using default")
            return def
        }
        var retries = 3
        if let raw = hc["retries"] {
            if let n = (raw as? Int) ?? Int(scalarString(raw)) {
                retries = n
            } else {
                warnings.append("\(key): healthcheck retries \"\(scalarString(raw))\" is not an integer — using default")
            }
        }
        // The engine treats zero interval/timeout/retries as "unset" — same here,
        // so an explicit `interval: 0s` can't turn the prober into a hot loop.
        let interval = duration("interval", default: 30)
        let timeout = duration("timeout", default: 30)
        return Healthcheck(
            test: test, shellForm: shellForm,
            interval: interval > 0 ? interval : 30,
            timeout: timeout > 0 ? timeout : 30,
            retries: retries > 0 ? retries : 3,
            startPeriod: duration("start_period", default: 0))
    }

    // MARK: helpers

    private static func mountSpec(source: String, target: String, readonly: Bool, baseDir: String?) -> String {
        let isBind = source.hasPrefix("/") || source.hasPrefix("~") || source.hasPrefix("./") || source.hasPrefix("../")
        var src = isBind ? (source as NSString).expandingTildeInPath : source
        if isBind, !src.hasPrefix("/") {
            // Compose resolves relative binds against the compose file's directory.
            src = URL(fileURLWithPath: baseDir ?? FileManager.default.currentDirectoryPath)
                .appendingPathComponent(src).standardizedFileURL.path
        }
        var spec = "type=\(isBind ? "bind" : "volume"),source=\(src),target=\(target)"
        if readonly { spec += ",readonly" }
        return spec
    }

    /// Kahn topological sort over depends_on; deterministic (sorted) tie-breaks.
    private static func topoSort(services: [String], dependsOn: [String: [String]]) throws -> [String] {
        for (svc, deps) in dependsOn {
            for d in deps where !dependsOn.keys.contains(d) && !services.contains(d) {
                throw Error.unknownDependency(service: svc, dependsOn: d)
            }
        }
        var remaining = Set(services)
        var ordered: [String] = []
        while !remaining.isEmpty {
            let ready = remaining
                .filter { svc in (dependsOn[svc] ?? []).allSatisfy { !remaining.contains($0) } }
                .sorted()
            if ready.isEmpty { throw Error.dependencyCycle(remaining.sorted()) }
            ordered += ready
            remaining.subtract(ready)
        }
        return ordered
    }

    private static func scalarString(_ v: Any) -> String {
        if let b = v as? Bool { return b ? "true" : "false" }
        return String(describing: v)
    }

    /// Go-style duration ("300ms", "5s", "1m30s", "2h") → seconds.
    static func parseDuration(_ s: String) -> Double? {
        let multipliers: [String: Double] = ["ms": 0.001, "s": 1, "m": 60, "h": 3600]
        var total = 0.0
        var number = ""
        var unit = ""
        for ch in s {
            if ch.isNumber || ch == "." {
                if !unit.isEmpty {
                    guard let n = Double(number), let m = multipliers[unit] else { return nil }
                    total += n * m
                    number = ""; unit = ""
                }
                number.append(ch)
            } else if !number.isEmpty {
                unit.append(ch)
            } else {
                return nil
            }
        }
        guard let n = Double(number), let m = multipliers[unit] else { return nil }
        return total + n * m
    }

    /// Minimal shell-style splitter for compose string commands (quotes honored).
    static func shellSplit(_ s: String) -> [String] {
        var out: [String] = []
        var current = ""
        var quote: Character? = nil
        var started = false
        for ch in s {
            if let q = quote {
                if ch == q { quote = nil } else { current.append(ch) }
            } else if ch == "\"" || ch == "'" {
                quote = ch; started = true
            } else if ch == " " || ch == "\t" {
                if started { out.append(current); current = ""; started = false }
            } else {
                current.append(ch); started = true
            }
        }
        if started { out.append(current) }
        return out
    }

    static func shellQuote(_ s: String) -> String {
        if s.isEmpty { return "''" }
        if s.range(of: "^[A-Za-z0-9._:/=@,+-]+$", options: .regularExpression) != nil { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// MARK: - Selection

extension Compose.Plan {
    /// Docker-style service selection: the named services plus their transitive
    /// depends_on closure, kept in start order. Profiles filter first (a service
    /// without profiles is always enabled; profile `"*"` activates every one);
    /// naming a service explicitly activates its own profiles (docker v2), but a
    /// dependency pulled in by closure whose profiles all stay inactive is an
    /// error. Created volumes/networks are pruned to what the selected services
    /// reference. Empty `services` = every enabled one.
    func selecting(services requested: [String], activeProfiles: [String]) throws -> Compose.Plan {
        let byName = Dictionary(uniqueKeysWithValues: services.map { ($0.service, $0) })
        for name in requested where byName[name] == nil {
            throw Compose.Error.noSuchService(name)
        }
        var active = Set(activeProfiles)
        for name in requested { active.formUnion(byName[name]?.profiles ?? []) }
        func enabled(_ svc: Compose.ServicePlan) -> Bool {
            svc.profiles.isEmpty || active.contains("*") || svc.profiles.contains(where: active.contains)
        }

        var selected = Set<String>()
        var queue = requested.isEmpty ? services.filter(enabled).map(\.service) : requested
        while let name = queue.popLast() {
            guard !selected.contains(name), let svc = byName[name] else { continue }
            if !enabled(svc) {
                throw Compose.Error.inactiveProfile(service: name, profile: svc.profiles.first ?? "?")
            }
            selected.insert(name)
            queue += svc.dependsOn.keys.sorted()
        }

        let kept = services.filter { selected.contains($0.service) }
        let volumeRefs = Set(kept.flatMap(\.volumeRefs))
        let networkRefs = Set(kept.flatMap(\.networkRefs))
        return Compose.Plan(
            project: project,
            volumes: volumes.filter(volumeRefs.contains),
            networks: networks.filter(networkRefs.contains),
            services: kept,
            warnings: warnings)
    }
}

// MARK: - Exit codes

/// In-process registry of init-process exit codes. Snapshots carry no exit code,
/// so `service_completed_successfully` needs the bootstrap handle captured at
/// start time: `ContainerService.start(_:retainExitCode:)` registers it here and
/// `Compose.up` awaits the code. Only covers containers started by this process.
actor ComposeExitCodes {
    static let shared = ComposeExitCodes()

    private var waits: [String: Task<Int32?, Never>] = [:]
    private var order: [String] = []  // registration order, for eviction

    /// Watches the process until it exits. Entries are capped (oldest dropped)
    /// and displaced tasks are cancelled — best effort only: the underlying XPC
    /// wait ignores cancellation, so a cancelled task still lives until its
    /// process exits; it just stops being tracked here.
    func register(id: String, process: ClientProcess) {
        waits[id]?.cancel()
        waits[id] = Task { try? await process.wait() }
        order.removeAll { $0 == id }
        order.append(id)
        if order.count > 64 { waits.removeValue(forKey: order.removeFirst())?.cancel() }
    }

    /// Blocks until the process exits. nil when the id was never registered
    /// (started outside this process, or evicted) or the wait itself failed.
    func exitCode(for id: String) async -> Int32? {
        guard let wait = waits[id] else { return nil }
        return await wait.value
    }
}

// MARK: - Execution

extension Compose {
    enum StepKind: Hashable {
        case volume(String), network(String), service(String)
        case waiting(service: String, condition: String)

        /// Human-readable form for CLI progress lines.
        var label: String {
            switch self {
            case .volume(let v): return "volume \(v)"
            case .network(let n): return "network \(n)"
            case .service(let s): return "service \(s)"
            case .waiting(let s, let c): return "waiting \(s) (\(c))"
            }
        }
    }

    /// Bring the plan up: create missing named volumes and networks, then create
    /// and start each service in dependency order, honoring depends_on conditions
    /// before each start (service_healthy probes the dependency's healthcheck,
    /// service_completed_successfully awaits its retained exit code). A same-named
    /// container that is already running is reused untouched (docker "Running");
    /// a stopped one is force-deleted and recreated from the plan — the file wins.
    /// Reports each step; stops at the first failure (already-completed steps stay
    /// up, like compose does).
    static func up(
        plan: Plan,
        progress: @escaping @Sendable (StepKind, _ done: Bool) async -> Void
    ) async throws {
        let existingVolumes = Set((try? await ContainerService.listVolumes())?.map(\.name) ?? [])
        for volume in plan.volumes where !existingVolumes.contains(volume) {
            await progress(.volume(volume), false)
            try await ContainerService.createVolume(name: volume, size: nil)
            await progress(.volume(volume), true)
        }

        let existingNetworks = Set((try? await ContainerService.listNetworks())?.map(\.name) ?? [])
        for network in plan.networks where !existingNetworks.contains(network) {
            await progress(.network(network), false)
            try await ContainerService.createNetwork(name: network, subnet: nil, internal: false)
            await progress(.network(network), true)
        }
        // Undeclared networks referenced by services (we warned) — create those too.
        let referenced = Set(plan.services.flatMap(\.networkRefs))
        for network in referenced.subtracting(plan.networks).subtracting(existingNetworks).sorted() {
            await progress(.network(network), false)
            try await ContainerService.createNetwork(name: network, subnet: nil, internal: false)
            await progress(.network(network), true)
        }

        // Only services something waits on with service_completed_successfully
        // need their init exit code retained (registration happens at start time).
        let needsExitCode = Set(plan.services.flatMap { svc in
            svc.dependsOn.compactMap { $0.value == .completedSuccessfully ? $0.key : nil }
        })
        let byService = Dictionary(uniqueKeysWithValues: plan.services.map { ($0.service, $0) })

        // Container names present before this up (name → running). One snapshot
        // is enough: each service is visited once, and a container this up just
        // created is never looked up again. A failed list = nothing preexists.
        let preexisting = Dictionary(uniqueKeysWithValues:
            ((try? await ContainerService.listContainers()) ?? []).map { ($0.id, $0.isRunning) })

        for svc in plan.services {
            // Already running under the target name → reuse as-is; its own
            // dependencies were satisfied when it started, so skip the waits too.
            if preexisting[svc.name] == true {
                await progress(.service(svc.service), false)
                await progress(.service(svc.service), true)
                continue
            }

            for (dep, condition) in svc.dependsOn.sorted(by: { $0.key < $1.key }) where condition != .started {
                guard let depPlan = byService[dep] else { continue }  // parse rejects unknown deps
                await progress(.waiting(service: dep, condition: condition.rawValue), false)
                switch condition {
                case .healthy:
                    guard let hc = depPlan.healthcheck else {
                        throw Error.missingHealthcheck(service: svc.service, dependency: dep)
                    }
                    try await waitHealthy(service: dep, container: depPlan.name, healthcheck: hc)
                case .completedSuccessfully:
                    // The registry only knows containers started by this process,
                    // i.e. earlier in this same up (snapshots carry no exit code).
                    let code = await ComposeExitCodes.shared.exitCode(for: depPlan.name)
                    guard code == 0 else { throw Error.didNotComplete(service: dep, exitCode: code) }
                case .started:
                    break
                }
                await progress(.waiting(service: dep, condition: condition.rawValue), true)
            }

            await progress(.service(svc.service), false)
            if preexisting[svc.name] == false {
                // Exists but not running (stopped, or created-but-start-failed) —
                // recreate from the current plan rather than diffing config.
                try await ContainerService.delete(svc.name, force: true)
            }
            try await ContainerService.runContainer(
                image: svc.image,
                name: svc.name,
                processArgs: svc.processArgs,
                managementArgs: svc.managementArgs,
                resourceArgs: svc.resourceArgs,
                commandArgs: svc.commandArgs,
                retainExitCode: needsExitCode.contains(svc.service)
            )
            await progress(.service(svc.service), true)
        }
    }

    /// Probes `container` with its healthcheck until healthy — the first exit-0
    /// probe, even inside start_period — or unhealthy after `retries` consecutive
    /// countable failures (failures before start_period has elapsed don't count).
    /// Fails fast when the container stops (docker parity: no point probing a
    /// dead dependency). Bounded by start_period + retries × (interval + timeout).
    static func waitHealthy(service: String, container: String, healthcheck hc: Healthcheck) async throws {
        let started = ContinuousClock.now
        var failures = 0
        while true {
            // A probe exceeding its timeout counts as failed but keeps running in
            // the container: apple/container 1.0.0 can't signal exec processes
            // (see ContainerService.ExecTimeout), so it's abandoned, not killed.
            let result = try? await ContainerService.exec(container, hc.argv, timeout: .seconds(hc.timeout))
            if result?.exitCode == 0 { return }
            if let records = try? await ContainerService.listContainers(),
               records.first(where: { $0.id == container })?.isRunning != true {
                throw Error.dependencyExited(service: service)
            }
            if started.duration(to: .now) >= .seconds(hc.startPeriod) {
                failures += 1
                if failures >= hc.retries { throw Error.unhealthy(service: service, failures: failures) }
            }
            try await Task.sleep(for: .seconds(hc.interval))
        }
    }
}
