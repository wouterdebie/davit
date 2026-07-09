import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Import a Docker Compose file: preview exactly what will be created (services
/// in start order, volumes, networks, per-service CLI equivalents, and honest
/// warnings for anything unsupported), then create & start the stack.
struct ComposeImportSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    let plan: Compose.Plan

    private enum Phase: Equatable {
        case ready
        case running(String)         // current step description
        case failed(String)
        case done
    }
    @State private var phase: Phase = .ready
    @State private var completed: Set<Compose.StepKind> = []
    @State private var runtimeWarnings: [String] = []  // from up's hosts sync

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Import Compose — \(plan.project)")
                .font(.title3.weight(.semibold))

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !plan.volumes.isEmpty || !plan.networks.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(plan.volumes, id: \.self) { v in
                                chip("externaldrive", v, done: completed.contains(.volume(v)))
                            }
                            ForEach(plan.networks, id: \.self) { n in
                                chip("network", n, done: completed.contains(.network(n)))
                            }
                            Spacer()
                        }
                    }

                    ForEach(plan.services) { svc in
                        serviceCard(svc)
                    }

                    if !plan.warnings.isEmpty || !runtimeWarnings.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Label("Not everything in the file is supported", systemImage: "exclamationmark.triangle")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.orange)
                            ForEach(plan.warnings + runtimeWarnings, id: \.self) { w in
                                Text(w).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            .frame(maxHeight: 420)

            if case .failed(let message) = phase {
                Text(message)
                    .font(.caption).foregroundStyle(.red)
                    .textSelection(.enabled).lineLimit(4)
            }

            HStack {
                if case .running(let step) = phase {
                    ProgressView().controlSize(.small)
                    Text(step).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(phase == .done ? "Close" : "Cancel") { dismiss() }
                Button {
                    up()
                } label: {
                    Text(buttonTitle)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isRunning || phase == .done)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private var isRunning: Bool { if case .running = phase { return true }; return false }

    private var buttonTitle: String {
        switch phase {
        case .failed: return "Retry Remaining"
        case .done: return "Done"
        default:
            let n = plan.services.count
            return "Create & Start \(n) Service\(n == 1 ? "" : "s")"
        }
    }

    private func chip(_ icon: String, _ label: String, done: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: done ? "checkmark.circle.fill" : icon)
                .foregroundStyle(done ? .green : .secondary)
            Text(label)
        }
        .font(.caption)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(.quaternary.opacity(0.5), in: Capsule())
    }

    private func serviceCard(_ svc: Compose.ServicePlan) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: completed.contains(.service(svc.service)) ? "checkmark.circle.fill" : "shippingbox")
                    .foregroundStyle(completed.contains(.service(svc.service)) ? Color.green : Color.accentColor)
                Text(svc.name).font(.body.weight(.medium))
                Text(svc.image).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
            }
            summaryRow(svc)
            DisclosureGroup {
                Text(svc.cliPreview)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            } label: {
                Text("Equivalent command").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
    }

    private func summaryRow(_ svc: Compose.ServicePlan) -> some View {
        let ports = pairedValues(svc.managementArgs, flag: "--publish")
        let mounts = pairedValues(svc.managementArgs, flag: "--mount").count
        let envs = pairedValues(svc.processArgs, flag: "--env").count
        return HStack(spacing: 10) {
            if !ports.isEmpty {
                Label(ports.joined(separator: "  "), systemImage: "arrow.left.arrow.right")
            }
            if mounts > 0 { Label("\(mounts) mount\(mounts == 1 ? "" : "s")", systemImage: "externaldrive") }
            if envs > 0 { Label("\(envs) env", systemImage: "list.bullet") }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func pairedValues(_ args: [String], flag: String) -> [String] {
        args.indices.compactMap { i in
            args[i] == flag && i + 1 < args.count ? args[i + 1] : nil
        }
    }

    private func up() {
        phase = .running("Starting…")
        Task {
            do {
                let result = try await Compose.up(plan: plan) { step, done in
                    await MainActor.run {
                        if done {
                            // .waiting is transient — the checkmark grid only keys
                            // on volume/network/service steps.
                            if case .waiting = step {} else { completed.insert(step) }
                        } else {
                            switch step {
                            case .volume(let v): phase = .running("Creating volume \(v)…")
                            case .network(let n): phase = .running("Creating network \(n)…")
                            case .service(let s): phase = .running("Starting \(s)… (pulls the image if needed)")
                            case .waiting(let s, let c):
                                phase = .running("Waiting for \(s) (\(c.replacingOccurrences(of: "service_", with: "")))…")
                            }
                        }
                    }
                }
                runtimeWarnings = result.warnings
                phase = .done
                await state.refreshAll()
            } catch {
                let message = (error as? CLIError)?.message
                    ?? (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                phase = .failed(message)
                await state.refreshAll()
            }
        }
    }
}

// MARK: - File picking + parsing entry point

enum ComposeImport {
    /// Present an open panel, parse the chosen file, and hand back a plan
    /// (or a user-visible error).
    @MainActor
    static func pickAndParse() -> Result<Compose.Plan, CLIError>? {
        let panel = NSOpenPanel()
        panel.title = "Import Compose File"
        panel.allowedContentTypes = [.yaml]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let dir = url.deletingLastPathComponent()
            // The file's sibling .env participates automatically, like docker.
            let (environment, envWarnings) = try Compose.effectiveEnvironment(composeDir: dir.path)
            var plan = try parseFiltered(
                text: text, projectName: dir.lastPathComponent, baseDir: dir.path, environment: environment)
            plan.warnings = envWarnings + plan.warnings
            return .success(plan)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            return .failure(CLIError(command: "compose import", message: message))
        }
    }

    /// Parse for the GUI import: the sheet has no profile picker (v1), so
    /// profile-gated services are excluded like docker's default and surfaced
    /// as info warnings pointing at the CLI.
    static func parseFiltered(
        text: String, projectName: String, baseDir: String?, environment: [String: String] = [:]
    ) throws -> Compose.Plan {
        let parsed = try Compose.parse(text: text, projectName: projectName, baseDir: baseDir, environment: environment)
        var plan = try parsed.selecting(services: [], activeProfiles: [])
        let kept = Set(plan.services.map(\.service))
        for svc in parsed.services where !kept.contains(svc.service) {
            let profile = svc.profiles.first ?? "?"
            plan.warnings.append("service \(svc.service) requires profile \(profile) — import via CLI --profile \(profile)")
        }
        return plan
    }
}