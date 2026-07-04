import SwiftUI

enum SidebarSection: String, Hashable, CaseIterable {
    case dashboard, containers, images, volumes, networks

    var title: String {
        switch self {
        case .dashboard: return "Dashboard"
        case .containers: return "Containers"
        case .images: return "Images"
        case .volumes: return "Volumes"
        case .networks: return "Networks"
        }
    }
    var icon: String {
        switch self {
        case .dashboard: return "gauge.with.dots.needle.50percent"
        case .containers: return "shippingbox"
        case .images: return "square.stack.3d.down.forward"
        case .volumes: return "externaldrive"
        case .networks: return "network"
        }
    }
}

struct MainWindow: View {
    @EnvironmentObject var state: AppState
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
        .task {
            SnapshotDriver.runIfRequested(state: state)
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
        }
    }
}

// MARK: - Onboarding (CLI not installed)

struct OnboardingView: View {
    @EnvironmentObject var state: AppState
    @AppStorage(ContainerBinary.defaultsKey) private var binaryPath = ""
    @State private var installing = false
    @State private var installStage = ""
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
                    ProgressView()
                    Text(installStage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
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
                try await PlatformInstaller.install { stage in
                    Task { @MainActor in installStage = stage }
                }
                installStage = "Starting container services…"
                try await ContainerService.systemStart()
            } catch {
                installError = error.localizedDescription
            }
            installing = false
            await state.refreshAll()
        }
    }
}
