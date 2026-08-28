import AppKit
import SwiftUI

/// Build an image from a Dockerfile via the platform's BuildKit shim.
struct BuildImageSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var contextDir = ""
    @State private var dockerfile = ""
    @State private var tag = ""
    @State private var buildArgs: [KVPair] = []
    @State private var noCache = false
    @State private var pullBase = false
    @State private var arch = BuildService.defaultArch  // "arm64" | "amd64"

    @State private var working = false
    @State private var progressText = ""
    @State private var errorText: String?
    @State private var builtImage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Build Image").font(.title3.weight(.semibold))

            Form {
                HStack {
                    TextField("Context directory", text: $contextDir)
                        .textFieldStyle(.roundedBorder)
                    Button("Choose…") { chooseContext() }
                }
                HStack {
                    TextField("Dockerfile (e.g. Dockerfile, Dockerfile_t1)", text: $dockerfile)
                        .textFieldStyle(.roundedBorder)
                    Button("Choose…") { chooseDockerfile() }
                }
                TextField("Tag (e.g. myapp:latest)", text: $tag)
                    .textFieldStyle(.roundedBorder)
                Picker("Platform", selection: $arch) {
                    Text("Apple silicon (linux/arm64)").tag("arm64")
                    Text("Intel (linux/amd64)").tag("amd64")
                }
            }
            .formStyle(.columns)

            VStack(alignment: .leading, spacing: 4) {
                Text("Build args").font(.caption).foregroundStyle(.secondary)
                KeyValueEditor(keyPlaceholder: "KEY", valuePlaceholder: "value", pairs: $buildArgs, separator: "=")
            }

            HStack(spacing: 16) {
                Toggle("No cache", isOn: $noCache)
                Toggle("Re-pull base images", isOn: $pullBase)
            }
            .toggleStyle(.checkbox)
            .font(.callout)

            if let builtImage {
                Label("Built \(builtImage)", systemImage: "checkmark.circle.fill")
                    .font(.callout).foregroundStyle(.green)
            }
            if let errorText {
                Text(errorText).font(.caption).foregroundStyle(.red)
                    .textSelection(.enabled).lineLimit(6)
            }

            HStack {
                if working {
                    ProgressView().controlSize(.small)
                    Text(progressText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button(builtImage != nil ? "Close" : "Cancel") { dismiss() }
                Button {
                    build()
                } label: {
                    Text("Build")
                }
                .buttonStyle(.borderedProminent)
                .disabled(contextDir.isEmpty || tag.isEmpty || working || builtImage != nil)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func chooseContext() {
        let panel = NSOpenPanel()
        panel.title = "Choose Build Context"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        contextDir = url.path
        if dockerfile.isEmpty || !FileManager.default.fileExists(atPath: dockerfile) {
            dockerfile = url.appendingPathComponent("Dockerfile").path
        }
        if tag.isEmpty {
            tag = "\(url.lastPathComponent.lowercased()):latest"
        }
    }

    /// Pick any file as the Dockerfile (supports non-default names like
    /// Dockerfile_t1); starts in the context dir when one is set.
    private func chooseDockerfile() {
        let panel = NSOpenPanel()
        panel.title = "Choose Dockerfile"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if !contextDir.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: (contextDir as NSString).expandingTildeInPath)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        dockerfile = url.path
        // Default the context to the Dockerfile's folder if none is set yet.
        if contextDir.isEmpty { contextDir = url.deletingLastPathComponent().path }
    }

    private func build() {
        working = true
        errorText = nil
        progressText = "Starting…"
        let request = BuildService.Request(
            contextDir: (contextDir as NSString).expandingTildeInPath,
            dockerfilePath: dockerfile.isEmpty
                ? (contextDir as NSString).expandingTildeInPath + "/Dockerfile"
                : (dockerfile as NSString).expandingTildeInPath,
            tag: tag,
            buildArgs: buildArgs.filter { !$0.key.isEmpty }.map { "\($0.key)=\($0.value)" },
            noCache: noCache,
            pull: pullBase,
            arch: arch
        )
        Task {
            do {
                let image = try await BuildService.build(request) { text in
                    await MainActor.run { progressText = text }
                }
                builtImage = image
                await state.refreshAll()
            } catch let e as CLIError {
                errorText = e.message
            } catch {
                errorText = error.localizedDescription
            }
            working = false
        }
    }
}