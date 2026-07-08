import SwiftUI

enum SidebarSection: String, Hashable, CaseIterable {
    case dashboard, containers, images, volumes, networks, machines

    var title: String {
        switch self {
        case .dashboard: return "Dashboard"
        case .containers: return "Containers"
        case .images: return "Images"
        case .volumes: return "Volumes"
        case .networks: return "Networks"
        case .machines: return "Machines"
        }
    }
    var icon: String {
        switch self {
        case .dashboard: return "gauge.with.dots.needle.50percent"
        case .containers: return "shippingbox"
        case .images: return "square.stack.3d.down.forward"
        case .volumes: return "externaldrive"
        case .networks: return "network"
        case .machines: return "desktopcomputer"
        }
    }
}

struct MainWindow: View {
    @EnvironmentObject var state: AppState
    @Environment(\.openSettings) private var openSettings
    @State private var selection: SidebarSection? = .dashboard

    var body: some View {
        Group {
            if state.cliMissing {
                OnboardingView()
            } else {
                NavigationSplitView {
                    sidebar
                } detail: {
                    detail
                }
            }
        }
        .onChange(of: state.pendingContainerOpen) {
            // A container was clicked from another section (e.g. Dashboard) —
            // switch to Containers, which consumes the intent and pushes detail.
            if state.pendingContainerOpen != nil { selection = .containers }
        }
        .task {
            if ProcessInfo.processInfo.arguments.contains("--probe-dashboard-open") {
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(8))
                    selection = .dashboard
                    try? await Task.sleep(for: .seconds(1))
                    let target = state.runningContainers.first?.id ?? "none"
                    FileHandle.standardError.write(Data("DBG dashboard-click \(target)\n".utf8))
                    state.pendingContainerOpen = target
                    try? await Task.sleep(for: .seconds(3))
                    FileHandle.standardError.write(Data("DBG after-click selection=\(selection.map { $0.rawValue } ?? "nil")\n".utf8))
                }
            }
            SnapshotDriver.runIfRequested(state: state)
            SnapshotDriver.runPoseIfRequested(selection: $selection)
            if ProcessInfo.processInfo.arguments.contains("--pose-compose") {
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(5))
                    selection = .containers
                }
            }
            if ProcessInfo.processInfo.arguments.contains("--pose-settings-registries") {
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(6))
                    openSettings()
                    NSApp.activate(ignoringOtherApps: true)
                    try? await Task.sleep(for: .seconds(2))
                    FileHandle.standardError.write(Data("POSED settings-registries\n".utf8))
                }
            }
            if ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("--probe-recreate") }) {
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(6))
                    selection = .containers
                    try? await Task.sleep(for: .seconds(3))
                    FileHandle.standardError.write(Data("DBG probe: setting recreateTarget to \(state.containers.first?.id ?? "none")\n".utf8))
                    state.recreateTarget = state.containers.first
                    try? await Task.sleep(for: .seconds(3))
                    FileHandle.standardError.write(Data("DBG probe: done\n".utf8))
                }
            }
        }
        // Window-root anchor: sheets attached to the NavigationStack don't
        // present while a navigationDestination is pushed on macOS.
        .sheet(item: $state.recreateTarget) { target in
            RunContainerSheet(recreate: target)
        }
        .alert(item: $state.lastError) { err in
            Alert(
                title: Text("Command Failed"),
                message: Text(err.command.isEmpty ? err.message : "\(err.command)\n\n\(err.message)"),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                Section("Overview") {
                    sidebarRow(.dashboard)
                }
                Section("Resources") {
                    sidebarRow(.containers, badge: state.runningContainers.count)
                    sidebarRow(.images, badge: state.images.count)
                    sidebarRow(.volumes, badge: state.volumes.count)
                    sidebarRow(.networks, badge: state.networks.count)
                    sidebarRow(.machines, badge: state.machines.count)
                }
            }
            .listStyle(.sidebar)

            Divider()
            systemFooter
        }
        .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 300)
    }

    private func sidebarRow(_ section: SidebarSection, badge: Int? = nil) -> some View {
        Label(section.title, systemImage: section.icon)
            .badge(badge.map { $0 > 0 ? Text("\($0)") : nil } ?? nil)
            .tag(section)
    }

    private var systemFooter: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(state.systemState.isRunning ? Color.green : Color.secondary.opacity(0.5))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(state.systemState.isRunning ? "Services running" : "Services stopped")
                    .font(.caption)
                if let binary = state.resolvedBinary {
                    Text(binary.source.rawValue)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button {
                state.toggleSystem()
            } label: {
                if state.busyIDs.contains("system") {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: state.systemState.isRunning ? "stop.circle" : "play.circle")
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(state.systemState.isRunning ? "Stop container services" : "Start container services")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var detail: some View {
        switch selection ?? .dashboard {
        case .dashboard: DashboardView()
        case .containers: ContainersView()
        case .images: ImagesView()
        case .volumes: VolumesView()
        case .networks: NetworksView()
        case .machines: MachinesView()
        }
    }
}

// MARK: - Onboarding (CLI not installed)

struct OnboardingView: View {
    @EnvironmentObject var state: AppState
    @AppStorage(ContainerBinary.defaultsKey) private var binaryPath = ""
    @State private var installing = false
    @State private var installStage = ""
    @State private var installFraction: Double?
    @State private var installError: String?

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "shippingbox.fill")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("Apple container platform not found")
                .font(.title2.weight(.semibold))
            Text("Davit talks directly to Apple's open-source container services.\nInstall them once — no administrator rights needed — and you're set.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            if installing {
                VStack(spacing: 8) {
                    if let fraction = installFraction {
                        ProgressView(value: fraction)
                            .progressViewStyle(.linear)
                            .frame(width: 320)
                    } else {
                        ProgressView()
                    }
                    Text(installStage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .padding(.top, 4)
            } else {
                HStack(spacing: 12) {
                    Button("Install Container Platform") {
                        install()
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Check Again") {
                        Task { await state.refreshAll() }
                    }
                }
                Text("Downloads Apple's signed installer (v\(PlatformInstaller.pinnedVersion), ~180 MB), verifies it,\nand installs into your user Library. You can also use the [official installer](https://github.com/apple/container/releases).")
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.tertiary)
            }

            if let installError {
                Text(installError)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .frame(maxWidth: 420)
            }

            if !installing {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Already installed somewhere unusual? Enter the install root:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("/usr/local", text: $binaryPath)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 340)
                        .onSubmit { Task { await state.refreshAll() } }
                }
                .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func install() {
        installing = true
        installError = nil
        Task {
            do {
                try await PlatformInstaller.install { stage, fraction in
                    Task { @MainActor in
                        installStage = stage
                        installFraction = fraction
                    }
                }
                installStage = "Starting container services…"
                installFraction = nil
                try await ContainerService.systemStart()
            } catch {
                installError = error.localizedDescription
            }
            installing = false
            await state.refreshAll()
        }
    }
}
