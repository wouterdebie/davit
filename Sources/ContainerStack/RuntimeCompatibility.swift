import ContainerAPIClient
import Foundation

enum RosettaCheck {
    private static let probePaths = [
        "/Library/Apple/usr/libexec/oah/libRosettaRuntime",
        "/Library/Apple/usr/libexec/oah/RosettaLinux/rosetta",
    ]

    // Intentionally uncached; Rosetta can be installed while Davit is running.
    static func isInstalled() -> Bool {
        let fm = FileManager.default
        return probePaths.contains { fm.fileExists(atPath: $0) }
    }
}

enum HostPlatform {
    static let arch: String = Arch.hostArchitecture().rawValue
}
