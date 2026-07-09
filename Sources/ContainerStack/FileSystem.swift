import ContainerAPIClient
import ContainerResource
import Foundation

/// One entry in a container directory listing.
struct FileEntry: Identifiable, Hashable {
    let name: String
    let isDirectory: Bool
    let isSymlink: Bool
    let size: Int64
    let mtime: Date?
    var id: String { name }

    /// Path joined onto a parent directory (normalizing the trailing slash).
    func path(in dir: String) -> String {
        dir == "/" ? "/\(name)" : "\(dir)/\(name)"
    }
}

extension ContainerService {
    // MARK: exec with captured output

    struct ExecResult {
        let stdout: Data
        let stderr: String
        let exitCode: Int32
        var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
    }

    /// `exec` exceeded its caller-supplied timeout. The process keeps running:
    /// apple/container 1.0.0 and 1.1.0's `ClientProcess.kill` encode the signal as Int64
    /// where the apiserver expects a string (ClientProcess.swift), so a timed-out
    /// process cannot be signalled — it is abandoned and exits on its own or when
    /// the container stops.
    struct ExecTimeout: Swift.Error, LocalizedError {
        let argv: [String]
        let timeout: Duration
        var errorDescription: String? { "exec timed out after \(timeout): \(argv.joined(separator: " "))" }
    }

    /// Runs a command inside the container and captures stdout/stderr. Not a TTY.
    /// With `timeout`, throws `ExecTimeout` once it elapses (see there — the
    /// process is abandoned, not killed).
    static func exec(_ id: String, _ argv: [String], timeout: Duration? = nil, asRoot: Bool = false) async throws -> ExecResult {
        let client = ContainerClient()
        let container = try await client.get(id: id)
        var config = container.configuration.initProcess
        config.executable = argv[0]
        config.arguments = Array(argv.dropFirst())
        config.terminal = false
        config.workingDirectory = "/"
        // /etc/hosts is root:root 644 — a container whose default user is non-root
        // (e.g. the postgres image runs as `postgres`) can't write it as itself.
        if asRoot { config.user = .id(uid: 0, gid: 0) }

        let outPipe = Pipe()
        let errPipe = Pipe()
        let process = try await client.createProcess(
            containerId: id,
            processId: UUID().uuidString.lowercased(),
            configuration: config,
            stdio: [nil, outPipe.fileHandleForWriting, errPipe.fileHandleForWriting])
        try await process.start()
        // Close our copies of the write ends so pipe EOF arrives when the child exits;
        // the daemon holds its own dup'd fds (passed over XPC).
        try? outPipe.fileHandleForWriting.close()
        try? errPipe.fileHandleForWriting.close()

        // Unstructured drains (not async let): they only see EOF once the process
        // exits, so on timeout they must not block the throw at scope exit.
        let outTask = Task { await readToEnd(outPipe.fileHandleForReading) }
        let errTask = Task { await readToEnd(errPipe.fileHandleForReading) }

        let code: Int32
        if let timeout {
            // XPC requests ignore task cancellation, so wait() can't be raced inside
            // a task group (the group would block on the wait child); instead the
            // wait cancels a cancellation-responsive timer when the process exits.
            let timer = Task { try await Task.sleep(for: timeout) }
            let waited = Task {
                defer { timer.cancel() }
                return try await process.wait()
            }
            let expired: Bool
            do { try await timer.value; expired = true } catch { expired = false }
            if expired { throw ExecTimeout(argv: argv, timeout: timeout) }
            code = try await waited.value
        } else {
            code = try await process.wait()
        }
        let outData = await outTask.value
        let errData = await errTask.value
        return ExecResult(stdout: outData, stderr: String(decoding: errData, as: UTF8.self), exitCode: code)
    }

    private static func readToEnd(_ handle: FileHandle) async -> Data {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let data = (try? handle.readToEnd()) ?? Data()
                cont.resume(returning: data)
            }
        }
    }

    // MARK: directory listing

    /// Lists a directory inside the container. Uses `stat` (rich: type/size/mtime)
    /// with an `ls` fallback for images that lack coreutils/busybox stat.
    static func listDirectory(_ id: String, path: String) async throws -> [FileEntry] {
        // `$1` = path; iterate visible + dotfiles, emit "type|size|mtime|name".
        let statScript = """
        cd "$1" 2>/dev/null || exit 7
        for e in * .[!.]* ..?*; do
          [ -e "$e" ] || [ -L "$e" ] || continue
          stat -c '%F|%s|%Y|%n' "$e" 2>/dev/null
        done
        """
        let result = try await exec(id, ["/bin/sh", "-c", statScript, "davit", path])
        if result.exitCode == 7 {
            throw CLIError(command: "list \(path)", message: "not a directory or not accessible")
        }
        if result.exitCode == 0, !result.stdout.isEmpty {
            let entries = parseStat(result.stdoutString)
            if !entries.isEmpty { return sortEntries(entries) }
        }
        // Fallback: `ls -1Ap` (names only; dirs get a trailing slash).
        let ls = try await exec(id, ["/bin/sh", "-c", "cd \"$1\" 2>/dev/null || exit 7; ls -1Ap", "davit", path])
        if ls.exitCode == 7 {
            throw CLIError(command: "list \(path)", message: "not a directory or not accessible")
        }
        guard ls.exitCode == 0 else {
            let msg = ls.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw CLIError(command: "list \(path)", message: msg.isEmpty ? "could not list directory (minimal image?)" : msg)
        }
        return sortEntries(parseLs(ls.stdoutString))
    }

    private static func parseStat(_ text: String) -> [FileEntry] {
        var out: [FileEntry] = []
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 4 else { continue }
            let type = parts[0].lowercased()
            let name = parts[3]
            if name == "." || name == ".." { continue }
            out.append(FileEntry(
                name: name,
                isDirectory: type.contains("directory"),
                isSymlink: type.contains("symbolic link"),
                size: Int64(parts[1]) ?? 0,
                mtime: Double(parts[2]).map { Date(timeIntervalSince1970: $0) }))
        }
        return out
    }

    private static func parseLs(_ text: String) -> [FileEntry] {
        var out: [FileEntry] = []
        for raw in text.split(separator: "\n") {
            var name = String(raw)
            if name == "./" || name == "../" || name.isEmpty { continue }
            let isDir = name.hasSuffix("/")
            if isDir { name.removeLast() }
            let isLink = name.hasSuffix("@")
            if isLink { name.removeLast() }
            out.append(FileEntry(name: name, isDirectory: isDir, isSymlink: isLink, size: 0, mtime: nil))
        }
        return out
    }

    private static func sortEntries(_ entries: [FileEntry]) -> [FileEntry] {
        entries.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    // MARK: transfer + mutate

    /// Copies a file out of the container to a host path.
    static func downloadFile(_ id: String, containerPath: String, to hostURL: URL) async throws {
        do {
            try await ContainerClient().copyOut(id: id, source: containerPath, destination: hostURL.path)
        } catch {
            throw CLIError.wrap("download \(containerPath)", error)
        }
    }

    /// Copies a host file into a container directory.
    static func uploadFile(_ id: String, hostURL: URL, toDirectory dir: String) async throws {
        let dest = dir == "/" ? "/\(hostURL.lastPathComponent)" : "\(dir)/\(hostURL.lastPathComponent)"
        do {
            try await ContainerClient().copyIn(id: id, source: hostURL.path, destination: dest)
        } catch {
            throw CLIError.wrap("upload \(hostURL.lastPathComponent)", error)
        }
    }

    /// Deletes a path inside the container. `path` is passed as an argument (not
    /// interpolated into the script) so names can't break out of the command.
    static func deletePath(_ id: String, path: String) async throws {
        let result = try await exec(id, ["/bin/sh", "-c", "rm -rf -- \"$1\"", "davit", path])
        guard result.exitCode == 0 else {
            let msg = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw CLIError(command: "delete \(path)", message: msg.isEmpty ? "delete failed (exit \(result.exitCode))" : msg)
        }
    }
}
