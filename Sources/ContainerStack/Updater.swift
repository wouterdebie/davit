import AppKit
import Foundation

// MARK: - Update checking (GitHub Releases is the feed)

struct UpdateInfo: Equatable {
    let version: String        // "0.1.2"
    let downloadURL: URL       // the Davit-*.zip asset
    let releasePageURL: URL
}

enum UpdateChecker {
    static let repo = "wouterdebie/davit"
    static let lastCheckKey = "lastUpdateCheck"
    static let skippedVersionKey = "skippedUpdateVersion"

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    /// Returns the latest release if it is newer than the running version.
    static func fetchAvailableUpdate() async throws -> UpdateInfo? {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw CLIError(command: "update check", message: "GitHub API returned HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String,
              let htmlURL = (obj["html_url"] as? String).flatMap(URL.init(string:)),
              let assets = obj["assets"] as? [[String: Any]]
        else {
            throw CLIError(command: "update check", message: "unexpected GitHub API response")
        }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard isNewer(version, than: currentVersion) else { return nil }
        guard let asset = assets.first(where: {
            let name = $0["name"] as? String ?? ""
            return name.hasPrefix("Davit-") && name.hasSuffix(".zip")
        }), let urlString = asset["browser_download_url"] as? String, let url = URL(string: urlString) else {
            return nil  // release exists but has no app asset (e.g. still uploading)
        }
        return UpdateInfo(version: version, downloadURL: url, releasePageURL: htmlURL)
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}

// MARK: - Update installation (download → verify → atomic swap → relaunch)

@MainActor
final class UpdateInstaller: ObservableObject {
    @Published var stage: String?
    @Published var fraction: Double?
    @Published var errorText: String?
    @Published var installing = false

    func install(_ info: UpdateInfo, relaunch: Bool = true) {
        guard !installing else { return }
        installing = true
        errorText = nil
        Task {
            do {
                try await Self.performInstall(info, relaunch: relaunch) { [weak self] stage, fraction in
                    Task { @MainActor in
                        self?.stage = stage
                        self?.fraction = fraction
                    }
                }
            } catch {
                self.errorText = error.localizedDescription
                self.stage = nil
            }
            self.installing = false
        }
    }

    /// The full update flow; also used headless via `Davit update install`.
    /// nonisolated: statics on a @MainActor class inherit isolation, which
    /// deadlocks headless mode (main thread blocked on a semaphore).
    nonisolated static func performInstall(
        _ info: UpdateInfo,
        relaunch: Bool,
        progress: @escaping @Sendable (String, Double?) -> Void
    ) async throws {
        let fm = FileManager.default
        let bundleURL = Bundle.main.bundleURL

        // Self-replacement needs a real, writable install location.
        guard bundleURL.pathExtension == "app" else {
            throw CLIError(command: "update", message: "not running from an app bundle — update manually")
        }
        guard !bundleURL.path.contains("/AppTranslocation/") else {
            await MainActor.run { NSWorkspace.shared.open(info.releasePageURL) }
            throw CLIError(command: "update", message: "app is running translocated — move Davit.app to /Applications first")
        }
        guard fm.isWritableFile(atPath: bundleURL.deletingLastPathComponent().path) else {
            await MainActor.run { NSWorkspace.shared.open(info.releasePageURL) }
            throw CLIError(command: "update", message: "no write permission for \(bundleURL.deletingLastPathComponent().path)")
        }

        let work = fm.temporaryDirectory.appendingPathComponent("davit-update-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        progress("Downloading Davit \(info.version)…", 0)
        let zipPath = work.appendingPathComponent("update.zip")
        try await PlatformInstaller.downloadWithProgress(from: info.downloadURL, to: zipPath) { fraction, mb, totalMB in
            if let totalMB {
                progress(String(format: "Downloading Davit \(info.version)… %.0f of %.0f MB", mb, totalMB), fraction)
            } else {
                progress(String(format: "Downloading Davit \(info.version)… %.0f MB", mb), nil)
            }
        }

        progress("Extracting…", nil)
        try await PlatformInstaller.runTool("/usr/bin/ditto", ["-x", "-k", zipPath.path, work.path])
        let newApp = work.appendingPathComponent("Davit.app")
        guard fm.fileExists(atPath: newApp.path) else {
            throw CLIError(command: "update", message: "downloaded archive did not contain Davit.app")
        }

        progress("Verifying signature…", nil)
        try await PlatformInstaller.runTool("/usr/bin/codesign", ["--verify", "--strict", "--deep", newApp.path])
        // If the running app has a team identifier, the update must match it.
        let currentTeam = try await teamIdentifier(of: bundleURL.path)
        let newTeam = try await teamIdentifier(of: newApp.path)
        if let currentTeam, currentTeam != newTeam {
            throw CLIError(command: "update", message: "signature team mismatch (running: \(currentTeam), update: \(newTeam ?? "none"))")
        }

        progress("Installing…", nil)
        let backup = fm.temporaryDirectory.appendingPathComponent("Davit-previous-\(UUID().uuidString).app")
        try fm.moveItem(at: bundleURL, to: backup)
        do {
            try fm.moveItem(at: newApp, to: bundleURL)
        } catch {
            // Roll back so the user still has a working app.
            try? fm.moveItem(at: backup, to: bundleURL)
            throw CLIError(command: "update", message: "could not install update: \(error.localizedDescription)")
        }
        try? fm.removeItem(at: backup)

        progress("Installed \(info.version)", nil)
        if relaunch {
            progress("Relaunching…", nil)
            let script = "sleep 1; /usr/bin/open \"\(bundleURL.path)\""
            let relauncher = Process()
            relauncher.executableURL = URL(fileURLWithPath: "/bin/sh")
            relauncher.arguments = ["-c", script]
            try? relauncher.run()
            try? await Task.sleep(for: .milliseconds(300))
            await MainActor.run { NSApp.terminate(nil) }
        }
    }

    private nonisolated static func teamIdentifier(of path: String) async throws -> String? {
        let out = try await PlatformInstaller.runTool("/usr/bin/codesign", ["-dv", "--verbose=2", path])
        for line in out.components(separatedBy: "\n") where line.hasPrefix("TeamIdentifier=") {
            let value = String(line.dropFirst("TeamIdentifier=".count))
            return value == "not set" ? nil : value
        }
        return nil
    }
}
