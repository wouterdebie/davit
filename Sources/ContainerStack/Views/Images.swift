import SwiftUI

struct ImagesView: View {
    @EnvironmentObject var state: AppState
    @State private var search = ""
    @State private var showPullSheet = false
    @State private var showBuildSheet = false
    @State private var runFromImage: ImageRecord?
    @State private var pullLatestTarget: ImageRecord?
    @State private var path: [ImageRecord] = []

    private var filtered: [ImageRecord] {
        guard !search.isEmpty else { return state.images }
        return state.images.filter { $0.name.lowercased().contains(search.lowercased()) }
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if !state.systemState.isRunning && state.initialLoadDone {
                    ServicesStoppedState()
                } else if state.images.isEmpty && state.initialLoadDone {
                    EmptyState(
                        icon: "square.stack.3d.down.forward",
                        title: "No images",
                        message: "Pull an image from a registry to get started.",
                        actionLabel: "Pull Image…"
                    ) { showPullSheet = true }
                } else {
                    list
                }
            }
            .navigationTitle("Images")
            .navigationDestination(for: ImageRecord.self) { image in
                ImageDetailView(imageID: image.id)
            }
            .searchable(text: $search, placement: .toolbar, prompt: "Filter images")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        showPullSheet = true
                    } label: {
                        Label("Pull Image", systemImage: "arrow.down.circle")
                    }
                    .help("Pull an image from a registry")

                    Button {
                        showBuildSheet = true
                    } label: {
                        Label("Build Image", systemImage: "hammer")
                    }
                    .help("Build an image from a Dockerfile")

                    Menu {
                        Button("Prune Unused Images", role: .destructive) {
                            state.perform("images") { try await ContainerService.pruneImages(all: true) }
                        }
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                }
            }
            .sheet(isPresented: $showPullSheet) { PullImageSheet() }
        }
        // Separate node from the pull sheet — same-node sheets shadow each other.
        .sheet(item: $runFromImage) { image in
            RunContainerSheet(prefilledImage: image.name)
        }
        // Third and fourth anchor nodes for the same reason.
        .background(EmptyView().sheet(isPresented: $showBuildSheet) { BuildImageSheet() })
        .background(EmptyView().sheet(item: $pullLatestTarget) { image in
            PullImageSheet(prefilledReference: image.name)
        })
    }

    private var list: some View {
        ImageListContent(images: filtered, open: { path.append($0) }, run: { runFromImage = $0 },
                         pullLatest: { pullLatestTarget = $0 })
            .refreshIndicator(state.isRefreshing)
    }
}

struct ImageListContent: View {
    @EnvironmentObject var state: AppState
    let images: [ImageRecord]
    var scrollable = true
    let open: (ImageRecord) -> Void
    let run: (ImageRecord) -> Void
    var pullLatest: (ImageRecord) -> Void = { _ in }

    var body: some View {
        CardList(items: images, scrollable: scrollable) { image in
            HoverRow(action: { open(image) }) {
                ImageRow(image: image)
            }
            .contextMenu {
                Button("Run…") { run(image) }
                Button("Pull Latest") { pullLatest(image) }
                Button("Copy Reference") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(image.name, forType: .string)
                }
                Divider()
                Button("Delete", role: .destructive) {
                    state.perform(image.id) { try await ContainerService.deleteImage(image.name) }
                }
            }
        }
    }
}

struct ImageRow: View {
    @EnvironmentObject var state: AppState
    let image: ImageRecord

    private var inUse: Bool {
        state.containers.contains { $0.imageReference == image.name }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.stack.3d.down.forward.fill")
                .foregroundStyle(.tint)
                .font(.title3)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(image.repository).font(.body.weight(.medium))
                    Text(image.tag)
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.secondary.opacity(0.15), in: Capsule())
                        .foregroundStyle(.secondary)
                    if inUse {
                        Text("in use")
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.green.opacity(0.12), in: Capsule())
                            .foregroundStyle(.green)
                    }
                }
                Text(image.platforms.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(formatBytes(image.totalSize)).font(.callout).foregroundStyle(.secondary)
                Text(relativeDate(image.created)).font(.caption).foregroundStyle(.tertiary)
            }

            if state.busyIDs.contains(image.id) {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.vertical, 5)
    }
}

// MARK: - Image detail

struct ImageDetailView: View {
    @EnvironmentObject var state: AppState
    let imageID: String

    enum Tab: String, CaseIterable {
        case overview = "Overview"
        case layers = "Layers"
        case inspect = "Inspect"
    }
    @State private var tab: Tab = .overview
    @State private var showRunSheet = false
    @State private var showTagSheet = false
    @State private var showPullLatest = false

    private var image: ImageRecord? { state.images.first { $0.id == imageID } }

    var body: some View {
        Group {
            if let image {
                VStack(spacing: 0) {
                    header(image)
                    Divider()
                    switch tab {
                    case .overview: overview(image)
                    case .layers: ImageLayersTab(reference: image.name)
                    case .inspect: InspectTab(kind: "image", id: image.name)
                    }
                }
            } else {
                EmptyState(icon: "square.stack.3d.down.forward", title: "Image removed",
                           message: "This image no longer exists.")
            }
        }
        .navigationTitle(image?.shortNameTag ?? "Image")
        .toolbar {
            if let image {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        showRunSheet = true
                    } label: {
                        Label("Run", systemImage: "play.fill")
                    }
                    .help("Run a container from this image")
                    Menu {
                        Button("Pull Latest") { showPullLatest = true }
                        Button("Tag…") { showTagSheet = true }
                        Divider()
                        Button("Delete Image", role: .destructive) {
                            state.perform(image.id) { try await ContainerService.deleteImage(image.name) }
                        }
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                }
            }
        }
        .sheet(isPresented: $showRunSheet) {
            RunContainerSheet(prefilledImage: image?.name ?? "")
        }
        .background(EmptyView().sheet(isPresented: $showPullLatest) {
            PullImageSheet(prefilledReference: image?.name)
        })
        .sheet(isPresented: $showTagSheet) {
            if let image { TagImageSheet(source: image.name) }
        }
    }

    private func header(_ img: ImageRecord) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 14) {
                Image(systemName: "square.stack.3d.down.forward.fill")
                    .font(.title)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text(img.shortNameTag).font(.title2.weight(.semibold))
                    Text("\(formatBytes(img.totalSize)) · \(img.platforms.count) platform variant\(img.platforms.count == 1 ? "" : "s")")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 240)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private func overview(_ img: ImageRecord) -> some View {
        ScrollView {
            VStack(spacing: 14) {
                DetailCard(title: "General", icon: "info.circle") {
                    InfoRow(label: "Reference", value: img.name, monospaced: true, copyable: true)
                    if let digest = img.digest {
                        InfoRow(label: "Digest", value: digest, monospaced: true, copyable: true)
                    }
                    InfoRow(label: "Created", value: relativeDate(img.created))
                    InfoRow(label: "Total size", value: formatBytes(img.totalSize))
                }

                if !img.variants.isEmpty {
                    DetailCard(title: "Platform Variants", icon: "cpu") {
                        ForEach(Array(img.variants.enumerated()), id: \.offset) { _, v in
                            HStack {
                                Text(v.display)
                                    .font(.system(.callout, design: .monospaced))
                                Spacer()
                                Text(formatBytes(v.size))
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                let users = state.containers.filter { $0.imageReference == img.name }
                if !users.isEmpty {
                    DetailCard(title: "Used By", icon: "shippingbox") {
                        ForEach(users) { c in
                            HStack(spacing: 8) {
                                StatusDot(color: c.state.color)
                                Text(c.id).font(.callout)
                                Spacer()
                                StateChip(state: c.state)
                            }
                        }
                    }
                }
            }
            .padding(16)
        }
    }
}

// MARK: - Tag sheet

struct TagImageSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    let source: String
    @State private var target = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Tag Image").font(.title3.weight(.semibold))
            Text(source).font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
            TextField("new-name:tag", text: $target)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Tag") {
                    let t = target
                    state.perform("tag") { try await ContainerService.tagImage(source, t) }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(target.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}


/// Layers of an image (host platform): size, the command that made each, and
/// the digest. The topmost layers are the most-recently-added.
struct ImageLayersTab: View {
    let reference: String
    @State private var layers: [ContainerService.ImageLayer]?
    @State private var error: String?

    var body: some View {
        Group {
            if let error {
                EmptyState(icon: "exclamationmark.triangle", title: "Couldn't read layers", message: error)
            } else if let layers {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("\(layers.count) layer\(layers.count == 1 ? "" : "s")")
                                .font(.headline)
                            Spacer()
                            Text("total \(formatBytes(layers.reduce(0) { $0 + $1.sizeBytes }))")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(layers) { layer in
                            DetailCard(title: "", icon: "square.3.layers.3d.down.right") {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Text("Layer \(layer.index + 1)").font(.body.weight(.medium))
                                        Spacer()
                                        Text(formatBytes(layer.sizeBytes)).foregroundStyle(.secondary)
                                    }
                                    if let cmd = layer.createdBy, !cmd.isEmpty {
                                        Text(prettyCommand(cmd))
                                            .font(.system(.caption, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                            .textSelection(.enabled)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    Text(layer.digest)
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundStyle(.tertiary)
                                        .textSelection(.enabled)
                                        .lineLimit(1).truncationMode(.middle)
                                }
                            }
                        }
                    }
                    .padding(16)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: reference) {
            do { layers = try await ContainerService.imageLayers(reference) }
            catch { self.error = (error as? CLIError)?.message ?? error.localizedDescription }
        }
    }

    /// buildkit history commands are prefixed with a shell wrapper; strip the
    /// common "/bin/sh -c #(nop) " and "/bin/sh -c " noise for readability.
    private func prettyCommand(_ raw: String) -> String {
        var c = raw
        for prefix in ["/bin/sh -c #(nop) ", "/bin/sh -c "] {
            if c.hasPrefix(prefix) { c = String(c.dropFirst(prefix.count)); break }
        }
        return c.trimmingCharacters(in: .whitespaces)
    }
}
