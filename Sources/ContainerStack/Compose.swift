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
            }
        }
    }

    // MARK: parse

    static func parse(text: String, projectName: String, baseDir: String? = nil) throws -> Plan {
        guard let root = try Yams.load(yaml: text) as? [String: Any] else { throw Error.notAMapping }
        guard let services = root["services"] as? [String: Any], !services.isEmpty else { throw Error.noServices }

        var warnings: [String] = []
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
                key: svcName, svc: svc, project: project, declaredNetworks: topNetworks, baseDir: baseDir)
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
        key: String, svc: [String: Any], project: String, declaredNetworks: [String], baseDir: String?
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
            for entry in list { process += ["--env", scalarString(entry)] }
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
                case 3: management += ["--publish", "\(parts[1]):\(parts[2])"]  // host-ip dropped
                default: warnings.append("\(key): port \"\(s)\" — container-only ports need an explicit host port; ignored")
                }
                if parts.count == 3 { warnings.append("\(key): port \(s) — host IP binding not supported, publishing on all interfaces") }
            } else if let m = port as? [String: Any],
                      let target = m["target"] {
                if let published = m["published"] {
                    management += ["--publish", "\(scalarString(published)):\(scalarString(target))"]
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
                if let m = spec as? [String: Any], let raw = m["condition"] as? String {
                    if let parsed = DependsCondition(rawValue: raw) {
                        condition = parsed
                    } else {
                        warnings.append("\(key): depends_on \(dep) condition \"\(raw)\" is unknown — treating as service_started")
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
        return Healthcheck(
            test: test, shellForm: shellForm,
            interval: duration("interval", default: 30),
            timeout: duration("timeout", default: 30),
            retries: (hc["retries"] as? Int) ?? 3,
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
    /// without profiles is always enabled); naming a service explicitly activates
    /// its own profiles (docker v2), but a dependency pulled in by closure whose
    /// profiles all stay inactive is an error. Created volumes/networks are pruned
    /// to what the selected services reference. Empty `services` = every enabled one.
    func selecting(services requested: [String], activeProfiles: [String]) throws -> Compose.Plan {
        let byName = Dictionary(uniqueKeysWithValues: services.map { ($0.service, $0) })
        for name in requested where byName[name] == nil {
            throw Compose.Error.noSuchService(name)
        }
        var active = Set(activeProfiles)
        for name in requested { active.formUnion(byName[name]?.profiles ?? []) }
        func enabled(_ svc: Compose.ServicePlan) -> Bool {
            svc.profiles.isEmpty || svc.profiles.contains(where: active.contains)
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
        var volumeRefs = Set<String>()
        var networkRefs = Set<String>()
        for svc in kept {
            for i in svc.managementArgs.indices where i + 1 < svc.managementArgs.count {
                let value = svc.managementArgs[i + 1]
                if svc.managementArgs[i] == "--mount", value.hasPrefix("type=volume,") {
                    for part in value.split(separator: ",") where part.hasPrefix("source=") {
                        volumeRefs.insert(String(part.dropFirst("source=".count)))
                    }
                } else if svc.managementArgs[i] == "--network" {
                    networkRefs.insert(value)
                }
            }
        }
        return Compose.Plan(
            project: project,
            volumes: volumes.filter(volumeRefs.contains),
            networks: networks.filter(networkRefs.contains),
            services: kept,
            warnings: warnings)
    }
}

// MARK: - Execution

extension Compose {
    enum StepKind: Hashable { case volume(String), network(String), service(String) }

    /// Bring the plan up: create missing named volumes and networks, then create
    /// and start each service in dependency order. Reports each step; stops at
    /// the first failure (already-completed steps stay up, like compose does).
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
        let referenced = Set(plan.services.flatMap { svc in
            svc.managementArgs.indices.compactMap { i in
                svc.managementArgs[i] == "--network" && i + 1 < svc.managementArgs.count
                    ? svc.managementArgs[i + 1] : nil
            }
        })
        for network in referenced.subtracting(plan.networks).subtracting(existingNetworks).sorted() {
            await progress(.network(network), false)
            try await ContainerService.createNetwork(name: network, subnet: nil, internal: false)
            await progress(.network(network), true)
        }

        for svc in plan.services {
            await progress(.service(svc.service), false)
            try await ContainerService.runContainer(
                image: svc.image,
                name: svc.name,
                processArgs: svc.processArgs,
                managementArgs: svc.managementArgs,
                resourceArgs: svc.resourceArgs,
                commandArgs: svc.commandArgs
            )
            await progress(.service(svc.service), true)
        }
    }
}
