import ContainerAPIClient
import ContainerBuild
import ContainerPersistence
import ContainerResource
import ContainerCommands
import ContainerImagesServiceClient
import ContainerizationOCI
import Foundation
import NIO

/// Image builds from a Dockerfile, driving the same BuildKit shim the CLI uses:
/// dial the `buildkit` container over vsock (starting it if needed), stream the
/// build, export an OCI tar, then load + unpack + tag it into the image store.
enum BuildService {

    /// The host architecture ("arm64" | "amd64") — the build sheet's default.
    static var defaultArch: String { Arch.hostArchitecture().rawValue }

    struct Request {
        var contextDir: String
        var dockerfilePath: String        // usually <contextDir>/Dockerfile
        var tag: String                   // e.g. "myapp:latest"
        var buildArgs: [String] = []      // KEY=value
        var labels: [String] = []
        var noCache: Bool = false
        var pull: Bool = false            // re-pull base images
        var target: String = ""           // multi-stage target
        var arch: String = Arch.hostArchitecture().rawValue  // "arm64" | "amd64"
    }

    /// Upstream bug apple/container#735: builds with Dockerfiles ≥16 KiB hang.
    static let maxDockerfileSize = 16 * 1024

    static func build(
        _ request: Request,
        progress: @escaping @Sendable (String) async -> Void
    ) async throws -> String {
        do {
            return try await run(request, progress: progress)
        } catch let e as CLIError {
            throw e
        } catch {
            throw CLIError.wrap("build \(request.tag)", error)
        }
    }

    private static func run(
        _ request: Request,
        progress: @escaping @Sendable (String) async -> Void
    ) async throws -> String {
        let dockerfile = try Data(contentsOf: URL(fileURLWithPath: request.dockerfilePath))
        guard dockerfile.count < maxDockerfileSize else {
            throw CLIError(
                command: "build \(request.tag)",
                message: "Dockerfile is \(dockerfile.count) bytes; the builder currently rejects files over 16 KiB (apple/container#735)")
        }
        let dockerignore = try? Data(contentsOf: URL(fileURLWithPath: request.dockerfilePath + ".dockerignore"))
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: request.contextDir, isDirectory: &isDir), isDir.boolValue else {
            throw CLIError(command: "build \(request.tag)", message: "context directory not found: \(request.contextDir)")
        }
        // The platform's file sync breaks on /tmp contexts (symlink standardization
        // makes COPY fail with a cryptic "not found"); fail clearly instead.
        let resolvedContext = URL(fileURLWithPath: request.contextDir).resolvingSymlinksInPath().path
        if resolvedContext.hasPrefix("/private/tmp/") || resolvedContext.hasPrefix("/tmp/") {
            throw CLIError(
                command: "build \(request.tag)",
                message: "build contexts under /tmp aren't supported by the platform's file sync — move the context to another location (e.g. your home directory)")
        }

        let parsedReference = try Reference.parse(request.tag)
        parsedReference.normalize()
        let imageName = parsedReference.description

        await progress("Connecting to builder…")
        let systemConfig = try await Backend.systemConfig()
        let builder = try await connectBuilder(systemConfig: systemConfig, progress: progress)

        // Export destination inside the builder resource dir (mounted in the shim).
        let health = try await ClientHealthCheck.ping(timeout: .seconds(10))
        let buildID = UUID().uuidString
        let exportDir = health.appRoot
            .appendingPathComponent(Application.BuilderCommand.builderResourceDir)
            .appendingPathComponent(buildID)
        try FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: exportDir) }
        var export = try Builder.BuildExport(from: "type=oci")
        export.destination = exportDir.appendingPathComponent("out.tar")

        let platform = ContainerizationOCI.Platform(arch: request.arch, os: "linux")

        await progress("Building \(imageName)…")
        let config = Builder.BuildConfig(
            buildID: buildID,
            contentStore: RemoteContentStoreClient(),
            buildArgs: request.buildArgs,
            secrets: [:],
            // SSH agent forwarding needs the builder VM to be *created* with
            // ssh forwarding on (BuilderStart.start(ssh:), which is internal);
            // the public builder-start we use can't do it, so leave it off.
            ssh: "",
            contextDir: request.contextDir,
            dockerfile: dockerfile,
            dockerignore: dockerignore,
            labels: request.labels,
            noCache: request.noCache,
            platforms: [platform],
            terminal: nil,
            tags: [imageName],
            target: request.target,
            quiet: false,
            exports: [export],
            cacheIn: [],
            cacheOut: [],
            pull: request.pull,
            containerSystemConfig: systemConfig
        )
        try await builder.build(config)

        await progress("Loading built image…")
        guard let dest = export.destination else {
            throw CLIError(command: "build \(request.tag)", message: "missing export destination")
        }
        let result = try await ClientImage.load(from: dest.path, force: false)
        guard result.rejectedMembers.isEmpty else {
            throw CLIError(command: "build \(request.tag)", message: "built archive contains invalid members")
        }
        for image in result.images {
            try await image.unpack(platform: nil, progressUpdate: { _ in })
            _ = try await image.tag(new: imageName)
        }
        return imageName
    }

    /// Dial the buildkit shim; if it isn't running, start it via the platform's
    /// own builder-start command and retry until the gRPC endpoint answers.
    private static func connectBuilder(
        systemConfig: ContainerSystemConfig,
        progress: @escaping @Sendable (String) async -> Void
    ) async throws -> Builder {
        let client = ContainerClient()
        let deadline = ContinuousClock.now + .seconds(300)
        var startedBuilder = false
        while true {
            do {
                let fh = try await client.dial(id: "buildkit", port: 8088)
                let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
                let builder = try await Builder(socket: fh, group: group, logger: Backend.log)
                _ = try await builder.info()
                return builder
            } catch {
                guard ContinuousClock.now < deadline else {
                    throw CLIError(command: "build", message: "timed out waiting for the builder to start")
                }
                if !startedBuilder {
                    await progress("Starting builder… (pulls the BuildKit image on first use)")
                    var start = try Application.BuilderStart.parse([])
                    try await start.run()
                    startedBuilder = true
                }
                try await Task.sleep(for: .seconds(5))
            }
        }
    }
}