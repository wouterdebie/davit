import SwiftUI

// MARK: - Volumes

struct VolumesView: View {
    @EnvironmentObject var state: AppState
    @State private var search = ""
    @State private var showCreateSheet = false
    @State private var browsing: VolumeRecord?

    private var filtered: [VolumeRecord] {
        guard !search.isEmpty else { return state.volumes }
        return state.volumes.filter { $0.name.lowercased().contains(search.lowercased()) }
    }

    /// Volume names referenced by any container mount.
    private var usedVolumeNames: Set<String> {
        var used = Set<String>()
        for c in state.containers {
            for m in c.configuration.mounts ?? [] {
                if let name = m.volumeName {
                    used.insert(name)
                }
            }
        }
        return used
    }

    var body: some View {
        NavigationStack {
            Group {
                if !state.systemState.isRunning && state.initialLoadDone {
                    ServicesStoppedState()
                } else if state.volumes.isEmpty && state.initialLoadDone {
                    EmptyState(
                        icon: "externaldrive",
                        title: "No volumes",
                        message: "Volumes provide persistent storage for containers.",
                        actionLabel: "Create Volume…"
                    ) { showCreateSheet = true }
                } else {
                    list
                }
            }
            .navigationTitle("Volumes")
            .searchable(text: $search, placement: .toolbar, prompt: "Filter volumes")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        showCreateSheet = true
                    } label: {
                        Label("Create Volume", systemImage: "plus")
                    }
                    Menu {
                        Button("Prune Unused Volumes", role: .destructive) {
                            state.perform("volumes") { try await ContainerService.pruneVolumes() }
                        }
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                }
            }
            .sheet(isPresented: $showCreateSheet) { CreateVolumeSheet() }
            .sheet(item: $browsing) { VolumeBrowserSheet(volume: $0) }
        }
    }

    private var list: some View {
        VolumeListContent(volumes: filtered, usedNames: usedVolumeNames, browse: { browsing = $0 })
            .refreshIndicator(state.isRefreshing)
    }
}

struct VolumeListContent: View {
    @EnvironmentObject var state: AppState
    let volumes: [VolumeRecord]
    let usedNames: Set<String>
    var scrollable = true
    var browse: (VolumeRecord) -> Void = { _ in }

    var body: some View {
        CardList(items: volumes, scrollable: scrollable) { volume in
            HoverRow(action: { browse(volume) }) {
                VolumeRow(volume: volume, inUse: usedNames.contains(volume.name))
            }
            .contextMenu {
                Button("Browse Files…") { browse(volume) }
                Button("Copy Source Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(volume.source ?? "", forType: .string)
                }
                Button("Reveal in Finder") {
                    if let src = volume.source {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: src)])
                    }
                }
                Divider()
                Button("Delete", role: .destructive) {
                    state.perform(volume.id) { try await ContainerService.deleteVolume(volume.name) }
                }
            }
        }
    }
}

struct VolumeRow: View {
    @EnvironmentObject var state: AppState
    let volume: VolumeRecord
    let inUse: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "externaldrive.fill")
                .foregroundStyle(.purple)
                .font(.title3)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(volume.name).font(.body.weight(.medium))
                    if inUse {
                        Text("in use")
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.green.opacity(0.12), in: Capsule())
                            .foregroundStyle(.green)
                    }
                }
                Text([volume.format, volume.sizeInBytes.map { "max \(formatBytes($0))" }].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Text(relativeDate(volume.created))
                .font(.caption)
                .foregroundStyle(.tertiary)
            if state.busyIDs.contains(volume.id) {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.vertical, 5)
    }
}

// MARK: - Networks

struct NetworksView: View {
    @EnvironmentObject var state: AppState
    @State private var search = ""
    @State private var showCreateSheet = false

    private var filtered: [NetworkRecord] {
        guard !search.isEmpty else { return state.networks }
        return state.networks.filter { $0.name.lowercased().contains(search.lowercased()) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if !state.systemState.isRunning && state.initialLoadDone {
                    ServicesStoppedState()
                } else {
                    list
                }
            }
            .navigationTitle("Networks")
            .searchable(text: $search, placement: .toolbar, prompt: "Filter networks")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        showCreateSheet = true
                    } label: {
                        Label("Create Network", systemImage: "plus")
                    }
                    Menu {
                        Button("Prune Unused Networks", role: .destructive) {
                            state.perform("networks") { try await ContainerService.pruneNetworks() }
                        }
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                }
            }
            .sheet(isPresented: $showCreateSheet) { CreateNetworkSheet() }
        }
    }

    private var list: some View {
        NetworkListContent(networks: filtered)
            .refreshIndicator(state.isRefreshing)
    }
}

struct NetworkListContent: View {
    @EnvironmentObject var state: AppState
    let networks: [NetworkRecord]
    var scrollable = true

    var body: some View {
        CardList(items: networks, scrollable: scrollable) { network in
            HoverRow {
                NetworkRow(network: network)
            }
            .contextMenu {
                if let subnet = network.subnet {
                    Button("Copy Subnet (\(subnet))") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(subnet, forType: .string)
                    }
                }
                if !network.isBuiltin {
                    Divider()
                    Button("Delete", role: .destructive) {
                        state.perform(network.id) { try await ContainerService.deleteNetwork(network.name) }
                    }
                }
            }
        }
    }
}

struct NetworkRow: View {
    @EnvironmentObject var state: AppState
    let network: NetworkRecord

    private var attachedCount: Int {
        state.containers.filter { c in
            c.status?.networks?.contains { $0.network == network.name } ?? false
        }.count
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "network")
                .foregroundStyle(.teal)
                .font(.title3)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(network.name).font(.body.weight(.medium))
                    if network.isBuiltin {
                        Text("built-in")
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.secondary.opacity(0.15), in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                }
                Text([network.subnet, network.mode]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if attachedCount > 0 {
                Text("\(attachedCount) container\(attachedCount == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if state.busyIDs.contains(network.id) {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.vertical, 5)
    }
}


/// Browse a volume's contents by mounting it into a throwaway helper container
/// and reusing the Files tab. The helper is created on appear and deleted on
/// dismiss.
struct VolumeBrowserSheet: View {
    @Environment(\.dismiss) private var dismiss
    let volume: VolumeRecord

    @State private var helperID: String?
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Volume: \(volume.name)").font(.title3.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding(16)
            Divider()
            Group {
                if let error {
                    EmptyState(icon: "exclamationmark.triangle", title: "Couldn't open volume", message: error)
                } else if let helperID {
                    ContainerFilesTab(
                        containerID: helperID, isRunning: true,
                        notRunningMessage: "The helper container stopped.")
                } else {
                    VStack(spacing: 8) {
                        ProgressView()
                        Text("Mounting volume…").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(width: 640, height: 520)
        .task {
            do { helperID = try await VolumeBrowser.open(volumeName: volume.name) }
            catch { self.error = (error as? CLIError)?.message ?? error.localizedDescription }
        }
        .onDisappear {
            if let helperID { Task { await VolumeBrowser.close(helperID) } }
        }
    }
}
