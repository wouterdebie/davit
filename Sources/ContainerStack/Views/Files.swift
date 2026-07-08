import AppKit
import SwiftUI

/// Browse, download, upload and delete files inside a running container.
struct ContainerFilesTab: View {
    @EnvironmentObject var state: AppState
    let container: ContainerRecord

    @State private var path = "/"
    @State private var entries: [FileEntry] = []
    @State private var loading = false
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        if !container.isRunning {
            EmptyState(icon: "folder", title: "Container not running",
                       message: "Start the container to browse its files.")
        } else {
            VStack(spacing: 0) {
                toolbar
                Divider()
                content
            }
            .task(id: path) { await load() }
        }
    }

    // MARK: toolbar + breadcrumb

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button {
                navigateUp()
            } label: {
                Image(systemName: "chevron.up")
            }
            .disabled(path == "/")
            .help("Parent directory")

            breadcrumb

            Spacer()

            if busy { ProgressView().controlSize(.small) }
            Button { Task { await upload() } } label: {
                Label("Upload", systemImage: "square.and.arrow.up")
            }
            .help("Upload files here")
            Button { Task { await load() } } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var breadcrumb: some View {
        let segments = pathSegments()
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(Array(segments.enumerated()), id: \.offset) { idx, seg in
                    Button(seg.label) { path = seg.path }
                        .buttonStyle(.plain)
                        .foregroundStyle(idx == segments.count - 1 ? Color.primary : Color.secondary)
                    if idx < segments.count - 1 {
                        Text("/").foregroundStyle(.tertiary)
                    }
                }
            }
            .font(.system(.callout, design: .monospaced))
        }
    }

    private func pathSegments() -> [(label: String, path: String)] {
        var result: [(String, String)] = [("/", "/")]
        var acc = ""
        for part in path.split(separator: "/") {
            acc += "/\(part)"
            result.append((String(part), acc))
        }
        return result
    }

    // MARK: content

    @ViewBuilder
    private var content: some View {
        if loading && entries.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error {
            EmptyState(icon: "exclamationmark.triangle", title: "Can't read this directory", message: error)
        } else if entries.isEmpty {
            EmptyState(icon: "folder", title: "Empty", message: "Nothing in \(path).")
        } else {
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(entries) { entry in
                        FileRow(
                            entry: entry,
                            onOpen: { open(entry) },
                            onDownload: { Task { await download(entry) } })
                            .contextMenu { rowMenu(entry) }
                    }
                }
                .padding(8)
            }
        }
    }

    @ViewBuilder
    private func rowMenu(_ entry: FileEntry) -> some View {
        if entry.isDirectory {
            Button("Open") { open(entry) }
        } else {
            Button("Download…") { Task { await download(entry) } }
        }
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(entry.path(in: path), forType: .string)
        }
        Divider()
        Button("Delete", role: .destructive) { Task { await delete(entry) } }
    }

    // MARK: actions

    private func open(_ entry: FileEntry) {
        guard entry.isDirectory || entry.isSymlink else { return }
        path = entry.path(in: path)
    }

    private func navigateUp() {
        guard path != "/" else { return }
        let parent = (path as NSString).deletingLastPathComponent
        path = parent.isEmpty ? "/" : parent
    }

    private func load() async {
        loading = true
        error = nil
        do {
            entries = try await ContainerService.listDirectory(container.id, path: path)
        } catch let e as CLIError {
            error = e.message
            entries = []
        } catch {
            self.error = error.localizedDescription
            entries = []
        }
        loading = false
    }

    private func download(_ entry: FileEntry) async {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = entry.name
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        busy = true
        defer { busy = false }
        do {
            try await ContainerService.downloadFile(container.id, containerPath: entry.path(in: path), to: dest)
        } catch let e as CLIError {
            state.lastError = e
        } catch {
            state.lastError = CLIError(command: "download", message: error.localizedDescription)
        }
    }

    private func upload() async {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        busy = true
        defer { busy = false }
        for url in panel.urls {
            do {
                try await ContainerService.uploadFile(container.id, hostURL: url, toDirectory: path)
            } catch let e as CLIError {
                state.lastError = e
            } catch {
                state.lastError = CLIError(command: "upload", message: error.localizedDescription)
            }
        }
        await load()
    }

    private func delete(_ entry: FileEntry) async {
        let alert = NSAlert()
        alert.messageText = "Delete “\(entry.name)”?"
        alert.informativeText = "This permanently removes it from the container filesystem."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        busy = true
        defer { busy = false }
        do {
            try await ContainerService.deletePath(container.id, path: entry.path(in: path))
            await load()
        } catch let e as CLIError {
            state.lastError = e
        } catch {
            state.lastError = CLIError(command: "delete", message: error.localizedDescription)
        }
    }
}

private struct FileRow: View {
    let entry: FileEntry
    let onOpen: () -> Void
    let onDownload: () -> Void
    @State private var hovering = false

    private var isNavigable: Bool { entry.isDirectory || entry.isSymlink }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(entry.isDirectory ? Color.accentColor : (entry.isSymlink ? .teal : .secondary))
                .frame(width: 20)
            Text(entry.name)
                .fontWeight(entry.isDirectory ? .medium : .regular)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 12)
            if !entry.isDirectory && entry.size > 0 {
                Text(formatBytes(entry.size))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            if let mtime = entry.mtime {
                Text(relativeDate(mtime))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(width: 84, alignment: .trailing)
            }
            trailingAffordance
                .frame(width: 22)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .background(
            hovering ? AnyShapeStyle(.primary.opacity(0.06)) : AnyShapeStyle(.clear),
            in: RoundedRectangle(cornerRadius: 7))
        .onHover { hovering = $0 }
        // Directories open on double-click; files download on double-click.
        .onTapGesture(count: 2) { isNavigable ? onOpen() : onDownload() }
        .help(isNavigable ? "Open \(entry.name)" : "Double-click to download")
    }

    @ViewBuilder
    private var trailingAffordance: some View {
        if isNavigable {
            // Chevron signals "you can go in here"; also opens on a single click.
            Button(action: onOpen) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        } else {
            // Always-visible download so it's discoverable; brightens on hover.
            Button(action: onDownload) {
                Image(systemName: "arrow.down.circle")
                    .foregroundStyle(hovering ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .help("Download")
        }
    }

    private var icon: String {
        if entry.isSymlink { return "arrowshape.turn.up.right.fill" }
        return entry.isDirectory ? "folder.fill" : "doc.text"
    }
}
