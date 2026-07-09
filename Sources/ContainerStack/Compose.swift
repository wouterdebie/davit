import ContainerAPIClient
import Foundation
import TerminalProgress
import Yams

/// Docker Compose import: parse a compose file into a concrete creation plan —
/// named volumes and networks to create, then services as the same four flag
/// arrays the Run sheet feeds `Backend.runContainer`. apple/container has no
/// native compose, so this is pure app-side orchestration. The supported subset
/// is deliberate; everything else surfaces as a warning, never silently.
enum Compose {
    /// Ownership label stamped on every container this compose path creates.
    /// Identity by name alone is not enough: without this, `up` would delete
    /// or adopt a user's unrelated container that happens to share a name.
    static let projectLabel = "com.davit.compose.project"


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
        var stopGracePeriod: Double? // seconds; nil = platform stop default
        var stopSignal: String?      // signal name or number — the daemon parses it
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
        var externalVolumes: Set<String>   // declared `external:` — down leaves them alone
        var externalNetworks: Set<String>
        var services: [ServicePlan]  // in dependency start order
        var allServices: [ServicePlan]  // every service in the file, regardless of selection/profiles — hosts sync must cover unselected running containers too
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
        case invalidServiceName(String)
        case missingImage(service: String)
        case dependencyCycle([String])
        case unknownDependency(service: String, dependsOn: String)
        case missingHealthcheck(service: String, dependency: String)
        case noSuchService(String)
        case serviceNotRunning(String)
        case inactiveProfile(service: String, profile: String)
        case envFileNotFound(String)
        case requiredVariable(name: String, message: String)
        case unhealthy(service: String, failures: Int)
        case dependencyExited(service: String)
        case didNotComplete(service: String, exitCode: Int32?)
        case foreignContainer(name: String)

        var errorDescription: String? {
            switch self {
            case .notAMapping: return "not a compose file (top level is not a mapping)"
            case .noServices: return "no services defined"
            case .invalidServiceName(let s):
                return "service name \(s.debugDescription) is invalid — only [a-zA-Z0-9._-] is allowed"
            case .missingImage(let s): return "service \"\(s)\" has no image — build: is not supported yet"
            case .foreignContainer(let n):
                return "container \"\(n)\" exists but was not created by this compose project (missing \(Compose.projectLabel) label) — delete or rename it, then run up again"
            case .dependencyCycle(let names): return "depends_on cycle: \(names.joined(separator: " → "))"
            case .unknownDependency(let s, let d): return "service \"\(s)\" depends on unknown service \"\(d)\""
            case .missingHealthcheck(let s, let d): return "service \"\(s)\" needs \"\(d)\" healthy, but \"\(d)\" has no healthcheck"
            case .noSuchService(let s): return "no such service: \(s)"
            case .serviceNotRunning(let s): return "service \"\(s)\" has no running container"
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
        for line in text.split(whereSeparator: \.isNewline) {
            // .whitespacesAndNewlines: CRLF files otherwise leave a trailing
            // \r in every value and defeat the quote stripping below.
            var entry = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if entry.isEmpty || entry.hasPrefix("#") { continue }
            if entry.hasPrefix("export ") { entry = String(entry.dropFirst("export ".count)) }
            guard let eq = entry.firstIndex(of: "=") else { continue }
            let key = entry[..<eq].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            var value = entry[entry.index(after: eq)...].trimmingCharacters(in: .whitespacesAndNewlines)
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
                // Depth-aware close scan: "${VAR:-${OTHER}}" must close at the
                // matching brace, not the first one, or set-case values grow a
                // stray "}" (nested defaults inside are still taken literally).
                var depth = 1
                var scan = s.index(after: next)
                var closeFound: String.Index?
                while scan < s.endIndex {
                    if s[scan] == "{" { depth += 1 }
                    if s[scan] == "}" {
                        depth -= 1
                        if depth == 0 { closeFound = scan; break }
                    }
                    scan = s.index(after: scan)
                }
                guard let close = closeFound else {
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
                } else if op.hasPrefix("+") {                      // ${VAR+alt} / ${VAR:+alt}
                    out += value != nil ? String(op.dropFirst()) : ""
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
        // Same charset rule as service keys: the project name is written into
        // the managed /etc/hosts block and used in container names.
        guard project.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil else {
            throw Error.invalidServiceName(project)
        }

        // Top-level declarations; `external: true` marks a resource someone else
        // manages — down never deletes those (up still creates missing ones, a
        // pre-existing divergence from docker's must-preexist rule).
        func declared(_ key: String) -> (names: [String], external: Set<String>) {
            guard let map = root[key] as? [String: Any] else { return ([], []) }
            let external = map.compactMap { name, spec in
                ((spec as? [String: Any])?["external"] as? Bool) == true ? name : nil
            }
            return (Array(map.keys), Set(external))
        }
        let (topVolumes, externalVolumes) = declared("volumes")
        let (topNetworks, externalNetworks) = declared("networks")

        var plans: [String: ServicePlan] = [:]
        for (svcName, svcAny) in services {
            // Docker's service-name charset. Beyond parity this protects the
            // managed /etc/hosts block: names end up as line content there,
            // and whitespace (or a quoted-key newline) would break out of it.
            guard svcName.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil else {
                throw Error.invalidServiceName(svcName)
            }
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

        let orderedPlans = ordered.compactMap { plans[$0] }
        return Plan(
            project: project,
            volumes: topVolumes.sorted(),
            networks: topNetworks.sorted(),
            externalVolumes: externalVolumes,
            externalNetworks: externalNetworks,
            services: orderedPlans,
            allServices: orderedPlans,
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
        // container_name reaches the same /etc/hosts lines as service keys;
        // docker rejects these charsets too.
        guard name.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil else {
            throw Error.invalidServiceName(name)
        }

        var process: [String] = []
        var management: [String] = []
        var resource: [String] = []

        // env_file: string, list, or {path, required} entries — paths resolve
        // against the compose file's directory; contents load through the
        // dotenv parser and are NOT interpolated — a deliberate deviation:
        // compose v2 expands ${VAR} inside env-file values (single-quoted
        // ones excepted), here every value passes through literally. Later
        // files override earlier ones; environment: below overrides them
        // all. A missing file is an error unless the entry says
        // `required: false`.
        var envFileSpecs: [(path: String, required: Bool)] = []
        func envFileSpec(_ entry: Any) {
            if let m = entry as? [String: Any] {
                if let p = m["path"] as? String, !p.isEmpty {
                    envFileSpecs.append((p, (m["required"] as? Bool) ?? true))
                } else {
                    warnings.append("\(key): env_file entry without a path — ignored")
                }
            } else {
                let s = scalarString(entry)
                if s.isEmpty {
                    warnings.append("\(key): empty env_file entry — ignored")
                } else {
                    envFileSpecs.append((s, true))
                }
            }
        }
        switch svc["env_file"] {
        case nil: break
        case let list as [Any]: for entry in list { envFileSpec(entry) }
        case let other?: envFileSpec(other)  // string or {path, required}
        }
        var fileEnv: [String: String] = [:]
        for (path, required) in envFileSpecs {
            let expanded = (path as NSString).expandingTildeInPath
            let resolved = expanded.hasPrefix("/")
                ? expanded
                : URL(fileURLWithPath: baseDir ?? FileManager.default.currentDirectoryPath)
                    .appendingPathComponent(expanded).standardizedFileURL.path
            guard let text = try? String(contentsOfFile: resolved, encoding: .utf8) else {
                if required { throw Error.envFileNotFound(resolved) }
                continue
            }
            fileEnv.merge(parseDotEnv(text: text)) { _, later in later }
        }

        // environment: map or list form; its keys beat env_file entries
        var explicitEnv: [String] = []
        var explicitKeys = Set<String>()
        switch svc["environment"] {
        case let map as [String: Any]:
            for (k, v) in map.sorted(by: { $0.key < $1.key }) {
                explicitEnv += ["--env", "\(k)=\(scalarString(v))"]
                explicitKeys.insert(k)
            }
        case let list as [Any]:
            // KEY=VALUE passes through; a bare KEY resolves from the effective
            // environment (docker parity), falls back to an env_file value, or
            // is omitted with a warning.
            for entry in list {
                let s = scalarString(entry)
                if let eq = s.firstIndex(of: "=") {
                    explicitEnv += ["--env", s]
                    explicitKeys.insert(String(s[..<eq]))
                } else if let value = environment[s] {
                    explicitEnv += ["--env", "\(s)=\(value)"]
                    explicitKeys.insert(s)
                } else if fileEnv[s] == nil {
                    warnings.append("\(key): environment variable \(s) is not set — omitted")
                }
            }
        case nil: break
        default: warnings.append("\(key): unrecognized environment format — ignored")
        }
        for k in fileEnv.keys.sorted() where !explicitKeys.contains(k) {
            process += ["--env", "\(k)=\(fileEnv[k] ?? "")"]
        }
        process += explicitEnv

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
                    if let ip = m["host_ip"] {
                        let host = scalarString(ip)
                        // IPv6 host addresses need brackets or the platform's
                        // publish parser rejects the whole spec.
                        let bracketed = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
                        spec = "\(bracketed):\(spec)"
                    }
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

        // entrypoint: the platform takes a single executable string where
        // docker takes a full argv — approximate the list form by passing the
        // head as --entrypoint and PREPENDING the rest to the command argv;
        // the resulting in-container argv matches docker's entrypoint +
        // command (and, like docker, an entrypoint override suppresses the
        // image CMD unless command: is set). A string form is shell-split
        // first, so a single word maps to --entrypoint verbatim. Docker's
        // empty "clear the image entrypoint" form can't be expressed.
        var entrypoint: [String] = []
        switch svc["entrypoint"] {
        case let s as String:
            entrypoint = shellSplit(s)
            if entrypoint.isEmpty { warnings.append("\(key): entrypoint is empty — ignored") }
        case let list as [Any]:
            entrypoint = list.map { scalarString($0) }
            if entrypoint.isEmpty { warnings.append("\(key): entrypoint is empty — ignored") }
        case nil: break
        default: warnings.append("\(key): unrecognized entrypoint format — ignored")
        }
        if let head = entrypoint.first {
            management += ["--entrypoint", head]
            command = Array(entrypoint.dropFirst()) + command
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

        // stop_grace_period / stop_signal: applied by down/stop, not at run time
        var stopGrace: Double? = nil
        if let raw = svc["stop_grace_period"] {
            if let seconds = parseDuration(scalarString(raw)) {
                stopGrace = seconds
            } else {
                warnings.append("\(key): stop_grace_period \"\(scalarString(raw))\" is not a duration — using the default")
            }
        }
        let stopSignal = svc["stop_signal"].map(scalarString)

        // Everything we understand is handled above; name the rest honestly.
        let handled: Set<String> = [
            "image", "container_name", "environment", "env_file", "user", "working_dir",
            "ports", "volumes", "networks", "cpus", "mem_limit", "deploy", "command",
            "entrypoint", "depends_on", "profiles", "healthcheck", "stop_grace_period",
            "stop_signal",
        ]
        for k in svc.keys.sorted() where !handled.contains(k) {
            warnings.append("\(key): \"\(k)\" is not supported — ignored")
        }

        management += ["--label", "\(Compose.projectLabel)=\(project)"]

        let plan = ServicePlan(
            service: key, name: name, image: image,
            processArgs: process, managementArgs: management,
            resourceArgs: resource, commandArgs: command,
            profiles: profiles, healthcheck: healthcheck, dependsOn: deps,
            stopGracePeriod: stopGrace, stopSignal: stopSignal)
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
    /// `includeDependencies: false` keeps EXACTLY the named services — docker's
    /// scoping for stop/start/restart/pull/ps, where pulling in a dependency
    /// would stop a db that other services still use.
    func selecting(
        services requested: [String], activeProfiles: [String], includeDependencies: Bool = true
    ) throws -> Compose.Plan {
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
            if includeDependencies { queue += svc.dependsOn.keys.sorted() }
        }

        let kept = services.filter { selected.contains($0.service) }
        let volumeRefs = Set(kept.flatMap(\.volumeRefs))
        let networkRefs = Set(kept.flatMap(\.networkRefs))
        return Compose.Plan(
            project: project,
            volumes: volumes.filter(volumeRefs.contains),
            networks: networks.filter(networkRefs.contains),
            externalVolumes: externalVolumes,
            externalNetworks: externalNetworks,
            services: kept,
            allServices: allServices,
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
    ///
    /// Call BEFORE starting the process: register returns only once the
    /// watcher task is executing, so its wait request is on the wire before
    /// the caller's start request. A wait issued after start races a fast
    /// one-shot — the apiserver reaps the runtime client the moment the init
    /// process exits, and a wait arriving after that errors, losing the code.
    /// (Waits are valid from bootstrap on; they don't need a started process.)
    func register(id: String, process: ClientProcess) async {
        waits[id]?.cancel()
        await withCheckedContinuation { started in
            waits[id] = Task {
                started.resume()
                return try? await process.wait()
            }
        }
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
    /// up, like compose does). Once every service is up — reused ones included —
    /// the project's /etc/hosts entries are re-synced (syncProjectHosts below).
    /// Returns the sync warnings plus the set of services that were reused
    /// untouched — the CLI's log attach skips those containers' backlog, like
    /// docker only replays history for containers the up actually created.
    static func up(
        plan: Plan,
        progress: @escaping @Sendable (StepKind, _ done: Bool) async -> Void
    ) async throws -> (warnings: [String], reused: Set<String>) {
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

        // Containers present before this up. One snapshot is enough: each
        // service is visited once, and a container this up just created is
        // never looked up again. A failed list = nothing preexists.
        let preexisting = Dictionary(uniqueKeysWithValues:
            ((try? await ContainerService.listContainers()) ?? []).map { ($0.id, $0) })

        var reused = Set<String>()
        for svc in plan.services {
            // Ownership gate: a preexisting container is only compose's to
            // reuse or replace when it carries this project's label. Anything
            // else under the target name is the user's — refuse loudly rather
            // than delete it (stopped) or adopt and root-patch it (running).
            if let record = preexisting[svc.name], !owns(record, project: plan.project) {
                throw Error.foreignContainer(name: svc.name)
            }
            // Already running under the target name (and ours) → reuse as-is;
            // its dependencies were satisfied when it started, so skip the waits.
            if preexisting[svc.name]?.isRunning == true {
                reused.insert(svc.service)
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
            if let record = preexisting[svc.name], !record.isRunning {
                // Ours, but not running (stopped, or created-but-start-failed) —
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

        return (await syncProjectHosts(plan: plan), reused)
    }

    /// Compose service names never resolve from inside containers on this
    /// platform: the gateway DNS forwards to the macOS resolver (NXDOMAIN for
    /// service and container names alike) and the apiserver's table is
    /// loopback-only, so cross-service dialing works by IP only — and IPs
    /// change on recreate. After up/start/restart, every RUNNING project
    /// container therefore gets a managed block in its /etc/hosts mapping
    /// each project container's service and container name — including its
    /// own — to the current IP, cross-patching both directions (a running db
    /// learns a recreated migrator's new IP and vice versa). Managed lines
    /// carry a `# davit-compose` suffix; the rewrite filters the previous
    /// block out and writes back into the same file (same inode — never mv),
    /// then appends the fresh entries, one /bin/sh invocation per container.
    /// The whole PROJECT is covered regardless of what the caller selected
    /// (plan.allServices): a scoped `up web` must not erase the entries of a
    /// still-running unselected service, and that service needs web's new IP.
    /// A container that can't be patched (no usable /bin/sh, read-only
    /// /etc/hosts) yields a warning, never a failure. Containers recreated
    /// behind compose's back keep stale entries until the next up/start.
    /// True when the record was created by THIS compose project.
    static func owns(_ record: ContainerRecord, project: String) -> Bool {
        record.configuration.labels?[projectLabel] == project
    }

    static func syncProjectHosts(plan: Plan) async -> [String] {
        let records = Dictionary(uniqueKeysWithValues:
            ((try? await ContainerService.listContainers()) ?? []).map { ($0.id, $0) })
        let entries: [(service: String, name: String, ip: String)] = plan.allServices.compactMap { svc in
            guard let record = records[svc.name], record.isRunning, let ip = record.primaryIPv4,
                  owns(record, project: plan.project)  // never root-patch a container we don't own
            else { return nil }
            return (svc.service, svc.name, ip)
        }
        guard !entries.isEmpty else { return [] }
        let block = entries.map { "\($0.ip) \($0.service) \($0.name) # davit-compose" }.joined(separator: "\n")
        // grep exit 1 just means every line was managed; anything above means
        // grep itself failed and the file must be left alone. The block comes
        // in as $1 so no hosts content is ever shell-interpolated.
        let script = """
        keep=$(grep -v ' # davit-compose$' /etc/hosts); [ $? -le 1 ] || exit 9
        printf '%s\\n' "$keep" "$1" > /etc/hosts
        """
        var warnings: [String] = []
        for entry in entries {
            // asRoot: /etc/hosts is root:root 644 — containers whose default user
            // is non-root (e.g. the postgres image runs as `postgres`) can't write
            // it as themselves.
            let result = try? await ContainerService.exec(
                entry.name, ["/bin/sh", "-c", script, "davit", block], timeout: .seconds(30), asRoot: true)
            if result?.exitCode != 0 {
                // A one-shot can exit between the snapshot and the exec — an
                // exited container needs no entries, so only a still-running
                // one that can't be patched is worth a warning.
                let live = (try? await ContainerService.listContainers()) ?? []
                guard live.first(where: { $0.id == entry.name })?.isRunning == true else { continue }
                warnings.append("service \(entry.service): could not update /etc/hosts (no /bin/sh in this image?) — service names won't resolve there")
            }
        }
        return warnings
    }

    /// Tear the plan down: stop each existing container in reverse dependency
    /// order — honoring stop_grace_period / stop_signal — then force-delete it
    /// (a failed stop warns and the delete still runs; down must not strand
    /// the rest of the project behind one wedged container).
    /// Naming `services` scopes the teardown to exactly those (no dependency
    /// closure: deleting a dependency out from under the services still using
    /// it would surprise); only a FULL project down also deletes the declared
    /// non-external networks and, with `removeVolumes`, the declared
    /// non-external volumes. Missing containers skip silently, so down is
    /// idempotent. Returns warnings (e.g. a network still in use elsewhere).
    static func down(
        plan: Plan,
        services requested: [String] = [],
        removeVolumes: Bool = false,
        progress: @escaping @Sendable (StepKind, _ done: Bool) async -> Void
    ) async throws -> [String] {
        let known = Set(plan.services.map(\.service))
        for name in requested where !known.contains(name) { throw Error.noSuchService(name) }
        let selected = requested.isEmpty ? known : Set(requested)
        var warnings: [String] = []

        let records = Dictionary(uniqueKeysWithValues:
            try await ContainerService.listContainers().map { ($0.id, $0) })
        for svc in plan.services.reversed() where selected.contains(svc.service) {
            guard let record = records[svc.name] else { continue }  // never created
            guard owns(record, project: plan.project) else {
                warnings.append("service \(svc.service): container \"\(svc.name)\" was not created by this project — left alone")
                continue
            }
            let running = record.isRunning
            await progress(.service(svc.service), false)
            if running {
                // A stop that fails must not abort the teardown — the force-
                // delete below removes the container either way (docker keeps
                // going too); the user just gets told it wasn't graceful.
                do { try await stopContainer(svc) } catch {
                    let detail = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                    warnings.append("service \(svc.service): stop failed (\(detail)) — deleting by force")
                }
            }
            try await ContainerService.delete(svc.name, force: true)
            await progress(.service(svc.service), true)
        }

        // Networks and volumes only fall with the whole project: a service-
        // scoped down must not pull shared infrastructure from under the rest.
        guard requested.isEmpty else { return warnings }

        let networks = Set((try? await ContainerService.listNetworks())?.map(\.name) ?? [])
        for network in plan.networks where !plan.externalNetworks.contains(network) && networks.contains(network) {
            await progress(.network(network), false)
            do {
                try await ContainerService.deleteNetwork(network)
                await progress(.network(network), true)
            } catch {
                warnings.append("network \(network) not removed — still in use")
            }
        }
        if removeVolumes {
            let volumes = Set((try? await ContainerService.listVolumes())?.map(\.name) ?? [])
            for volume in plan.volumes where !plan.externalVolumes.contains(volume) && volumes.contains(volume) {
                await progress(.volume(volume), false)
                do {
                    try await ContainerService.deleteVolume(volume)
                    await progress(.volume(volume), true)
                } catch {
                    warnings.append("volume \(volume) not removed — still in use")
                }
            }
        }
        return warnings
    }

    /// stop_grace_period / stop_signal → the platform stop call. Unset grace =
    /// the platform's stop default (5s, SIGTERM), same as the app's Stop
    /// button. Clamped: a day is plenty. Shared by down, stop and restart.
    private static func stopContainer(_ svc: ServicePlan) async throws {
        let grace = Int32(min(svc.stopGracePeriod ?? 5, 86_400).rounded())
        try await ContainerService.stop(svc.name, timeoutSeconds: grace, signal: svc.stopSignal)
    }

    /// Stop the plan's existing containers in reverse dependency order with
    /// the same grace/signal handling as down, but keep them around for a
    /// later start. Never-created services skip silently and already-stopped
    /// containers still report their step (the desired state holds), so stop
    /// is idempotent like docker's.
    static func stop(
        plan: Plan,
        progress: @escaping @Sendable (StepKind, _ done: Bool) async -> Void
    ) async throws {
        let existing = Dictionary(uniqueKeysWithValues:
            try await ContainerService.listContainers().map { ($0.id, $0.isRunning) })
        for svc in plan.services.reversed() {
            guard let running = existing[svc.name] else { continue }  // never created
            await progress(.service(svc.service), false)
            if running { try await stopContainer(svc) }
            await progress(.service(svc.service), true)
        }
    }

    /// Start the plan's existing containers in dependency order. Fire-and-
    /// forget like docker's start: no healthcheck or completion waits — up is
    /// the command that honors depends_on conditions. A service that was
    /// never created is a warning (start never creates, that's up's job);
    /// already-running containers are left alone. Once everything is running
    /// the project's /etc/hosts entries are re-synced (a start after a stop
    /// can hand out fresh IPs). Returns the warnings.
    static func start(
        plan: Plan,
        progress: @escaping @Sendable (StepKind, _ done: Bool) async -> Void
    ) async throws -> [String] {
        var warnings: [String] = []
        let existing = Set(try await ContainerService.listContainers().map(\.id))
        for svc in plan.services {
            guard existing.contains(svc.name) else {
                warnings.append("service \(svc.service) has no container — run up")
                continue
            }
            await progress(.service(svc.service), false)
            try await ContainerService.start(svc.name)
            await progress(.service(svc.service), true)
        }
        warnings += await syncProjectHosts(plan: plan)
        return warnings
    }

    /// stop then start, each per its own rules (including start's hosts
    /// re-sync). The stop pass runs silent so every service reports exactly
    /// one step pair — read as "restarted" — once it is running again.
    static func restart(
        plan: Plan,
        progress: @escaping @Sendable (StepKind, _ done: Bool) async -> Void
    ) async throws -> [String] {
        try await stop(plan: plan) { _, _ in }
        return try await start(plan: plan, progress: progress)
    }

    /// Pull each plan service's image, one after the other, writing a
    /// `pull: <image>` header plus coarse progress lines. A cached image is
    /// silent between header and done — the daemon streams nothing for it.
    static func pull(
        plan: Plan,
        progress: @escaping @Sendable (StepKind, _ done: Bool) async -> Void,
        output: @escaping @Sendable (String) -> Void = { print($0, terminator: "") }
    ) async throws {
        for svc in plan.services {
            await progress(.service(svc.service), false)
            output("pull: \(svc.image)\n")
            let tracker = PullTracker()
            try await ContainerService.pullImage(svc.image) { events in
                for line in tracker.consume(events) { output("  \(line)\n") }
            }
            await progress(.service(svc.service), true)
        }
    }

    /// Reduces a pull's progress event stream to coarse text lines: stage
    /// descriptions deduplicated (like PullProgressModel — though the image
    /// pull route only ever streams counters, see the adapter in the client
    /// library), byte counters folded into at most one line per completed
    /// decile, or one per 32 MiB while the total is still unknown.
    private final class PullTracker: @unchecked Sendable {
        private let lock = NSLock()
        private var description = ""
        private var completed: Int64 = 0
        private var total: Int64 = 0
        private var lastBucket = 0

        func consume(_ events: [ProgressUpdateEvent]) -> [String] {
            lock.lock(); defer { lock.unlock() }
            var lines: [String] = []
            for event in events {
                switch event {
                case .setDescription(let text):
                    if !text.isEmpty, text != description {
                        description = text
                        lines.append(text)
                    }
                case .addSize(let n): completed += n
                case .addTotalSize(let n): total += n
                default: break
                }
            }
            let mb = Double(completed) / 1_048_576
            let bucket = total > 0 ? Int(Double(completed) / Double(total) * 10) : Int(mb / 32)
            if bucket > lastBucket, completed > 0 {
                lastBucket = bucket
                if total >= 1_048_576 {
                    lines.append(String(format: "downloaded %d%% (%.1f of %.1f MB)", min(bucket, 10) * 10, mb, Double(total) / 1_048_576))
                } else if total > 0 {
                    // Sub-MB totals happen when most blobs already sit in the
                    // content store — the percentage is the honest part.
                    lines.append("downloaded \(min(bucket, 10) * 10)%")
                } else {
                    lines.append(String(format: "downloaded %.1f MB", mb))
                }
            }
            return lines
        }
    }

    /// Printable `compose ps` row — the CLI aligns these into columns.
    struct PSRecord: Hashable {
        let service: String
        let container: String
        let state: String
        let ports: String
    }

    /// Live status per plan service, matched by the plan's container names:
    /// existing containers only, running or not — never-created services are
    /// omitted (docker parity).
    static func ps(plan: Plan) async throws -> [PSRecord] {
        let byId = Dictionary(uniqueKeysWithValues: try await ContainerService.listContainers().map { ($0.id, $0) })
        return plan.services.compactMap { svc in
            guard let record = byId[svc.name] else { return nil }
            let ports = (record.configuration.publishedPorts ?? []).map {
                "\($0.hostAddress ?? "0.0.0.0"):\($0.hostPort ?? 0)->\($0.containerPort ?? 0)/\($0.proto ?? "tcp")"
            }
            return PSRecord(
                service: svc.service, container: svc.name, state: record.state.rawValue,
                ports: ports.isEmpty ? "-" : ports.joined(separator: ", "))
        }
    }

    /// Resolves a service to its container name for exec: the service must be
    /// in the plan and its container must exist and be running — clear errors
    /// otherwise. Callers pass the unselected plan (like logs/down) so an
    /// existing container of a profile-gated service stays reachable.
    static func runningContainer(plan: Plan, service: String) async throws -> String {
        guard let svc = plan.services.first(where: { $0.service == service }) else {
            throw Error.noSuchService(service)
        }
        let records = try await ContainerService.listContainers()
        guard records.first(where: { $0.id == svc.name })?.isRunning == true else {
            throw Error.serviceNotRunning(service)
        }
        return svc.name
    }

    /// Streams existing project containers' stdout logs, each line prefixed
    /// `<container>  | ` with the prefix column aligned across containers.
    /// Naming `services` scopes the output to exactly those (no dependency
    /// closure — docker parity); never-created containers are skipped. `tail`
    /// limits the backlog per container (nil = everything); services in
    /// `skipBacklogFor` show none at all — up's attach passes its reused set,
    /// so only containers that up actually created replay history (docker
    /// behavior). With `follow` the backlog is followed by a readability
    /// handler per container printing new lines as they arrive, and the call
    /// never returns — Ctrl-C ends the process (the containers keep running).
    /// `output` receives whole prefixed lines (stdout by default) so the
    /// selftest can capture the non-follow path.
    static func logs(
        plan: Plan,
        services requested: [String] = [],
        tail: Int? = nil,
        skipBacklogFor: Set<String> = [],
        follow: Bool = false,
        output: @escaping @Sendable (String) -> Void = { FileHandle.standardOutput.write(Data($0.utf8)) }
    ) async throws {
        let known = Set(plan.services.map(\.service))
        for name in requested where !known.contains(name) { throw Error.noSuchService(name) }
        let selected = requested.isEmpty ? known : Set(requested)

        // Log lines bypass print's stdio buffer — flush it so any headers the
        // CLI printed earlier stay ahead of them when stdout is a pipe.
        fflush(stdout)

        let existing = Set(try await ContainerService.listContainers().map(\.id))
        let targets = plan.services.filter { selected.contains($0.service) && existing.contains($0.name) }
        let width = targets.map(\.name.count).max() ?? 0
        var streams: [(prefix: String, name: String, handle: FileHandle, backlog: Bool)] = []
        for svc in targets {
            // Index 0 is the stdio log, 1 the boot log (LogStreamer convention);
            // a container deleted since the snapshot just drops out. The fds
            // come dup'd from XPC with closeOnDealloc off — close what we
            // don't keep or every call leaks the boot-log descriptor.
            guard let handles = try? await ContainerClient().logs(id: svc.name), !handles.isEmpty else { continue }
            for extra in handles.dropFirst() { try? extra.close() }
            let prefix = svc.name.padding(toLength: width, withPad: " ", startingAt: 0) + "  | "
            streams.append((prefix, svc.name, handles[0], !skipBacklogFor.contains(svc.service)))
        }

        for stream in streams {
            // Remember the end of file before the backwards tail read, so the
            // follow handler below resumes exactly where the backlog ended.
            let end = (try? stream.handle.seekToEnd()) ?? 0
            let maxLines = stream.backlog ? (tail.map { max(0, $0) } ?? Int.max) : 0
            for line in LogStreamer.readTail(fh: stream.handle, maxLines: maxLines) {
                output(stream.prefix + line + "\n")
            }
            try? stream.handle.seek(toOffset: end)
        }

        guard follow, !streams.isEmpty else {
            for stream in streams { try? stream.handle.close() }
            return
        }
        let printer = LinePrinter(output: output)
        for stream in streams {
            stream.handle.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                printer.emit(prefix: stream.prefix, key: stream.name, data: data)
            }
        }
        // Follow until Ctrl-C — or until every followed container has exited,
        // matching docker compose (a stack of one-shot jobs must not hang a
        // script forever after the jobs finish). Poll cheaply; log FDs keep
        // delivering the tail while we wait, and one final grace tick lets the
        // readability handlers drain buffered output before returning.
        let names = Set(streams.map(\.name))
        while true {
            try await Task.sleep(for: .seconds(2))
            let records = (try? await ContainerService.listContainers()) ?? []
            let anyRunning = records.contains { names.contains($0.id) && $0.isRunning }
            if !anyRunning {
                try await Task.sleep(for: .seconds(1))
                for stream in streams { stream.handle.readabilityHandler = nil; try? stream.handle.close() }
                return
            }
        }
    }

    /// Serializes prefixed log writes from the per-container readability
    /// handlers (they fire on independent dispatch queues) and holds each
    /// stream's trailing partial line until its newline arrives.
    private final class LinePrinter: @unchecked Sendable {
        private let lock = NSLock()
        private var partial: [String: Data] = [:]
        private let output: @Sendable (String) -> Void

        init(output: @escaping @Sendable (String) -> Void) { self.output = output }

        func emit(prefix: String, key: String, data: Data) {
            lock.lock(); defer { lock.unlock() }
            var buffer = partial[key, default: Data()]
            buffer.append(data)
            while let nl = buffer.firstIndex(of: 0x0A) {
                var line = buffer.subdata(in: buffer.startIndex..<nl)
                if line.last == 0x0D { line.removeLast() }
                if !line.isEmpty, let text = String(data: line, encoding: .utf8) {
                    output(prefix + text + "\n")
                }
                buffer.removeSubrange(buffer.startIndex...nl)
            }
            partial[key] = buffer
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
        var abandoned = 0
        while true {
            // A probe exceeding its timeout counts as failed but keeps running in
            // the container: apple/container 1.0.0 can't signal exec processes
            // (see ContainerService.ExecTimeout), so it's abandoned, not killed.
            // Cap the abandoned pile: each one pins a process in the guest and
            // pipe FDs in the app, so a hung probe command must fail the wait
            // rather than accumulate an unbounded backlog.
            let result = try? await ContainerService.exec(container, hc.argv, timeout: .seconds(hc.timeout))
            if result == nil {  // timed out (abandoned in-guest) or exec failed outright
                abandoned += 1
                if abandoned >= 3 {
                    throw Error.unhealthy(service: service, failures: max(failures, abandoned))
                }
            }
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
