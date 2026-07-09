import ContainerizationOCI
import ContainerizationOS
import Foundation
import Security

/// A saved registry login (credentials live in the login keychain, not here).
struct RegistryLoginRecord: Identifiable, Hashable {
    let hostname: String
    let username: String
    let modified: Date?
    var id: String { hostname }
}

/// Registry credential management, mirroring `container registry login/list/logout`.
/// Credentials are stored in the same login keychain the platform uses, so a
/// login here works for CLI pulls too (and vice-versa).
enum RegistryService {
    /// Same security domain the platform's CLI uses (Constants.keychainID).
    static let keychainDomain = "com.apple.container.registry"

    private static var keychain: KeychainHelper { KeychainHelper(securityDomain: keychainDomain) }

    static func listLogins() -> [RegistryLoginRecord] {
        let infos = (try? keychain.list()) ?? []
        return infos
            .map { RegistryLoginRecord(hostname: $0.hostname, username: $0.username, modified: $0.modifiedDate) }
            .sorted { $0.hostname < $1.hostname }
    }

    /// Validates the credentials against the registry, then saves them. `server`
    /// is the user-facing name (e.g. "docker.io"); it's resolved to the real
    /// registry host for both the check and the keychain key.
    static func login(server rawServer: String, username: String, password: String) async throws {
        let server = Reference.resolveDomain(domain: rawServer.trimmingCharacters(in: .whitespaces))
        let client = RegistryClient(
            host: server,
            scheme: "https",
            authentication: BasicAuthentication(username: username, password: password),
            retryOptions: .init(maxRetries: 3, retryInterval: 300_000_000,
                                shouldRetry: { $0.status.code >= 500 }))
        do {
            try await client.ping()
        } catch {
            throw CLIError(command: "registry login \(server)", message: "authentication failed: \(String(describing: error))")
        }
        do {
            try saveTrustingPlatform(hostname: server, username: username, password: password)
        } catch {
            throw CLIError(command: "registry login \(server)", message: "credentials verified but keychain save failed: \(error.localizedDescription)")
        }
    }

    /// Saves the credential with an ACL that pre-trusts the container platform's
    /// binaries (apiserver, the core-images helper that performs pulls, and the
    /// CLI). Without this, each of those prompts "wants to use your confidential
    /// information" separately — and every re-login resets any Always Allow.
    /// Attributes match KeychainQuery.save exactly so the platform's lookups
    /// keep finding the item.
    static func saveTrustingPlatform(hostname: String, username: String, password: String) throws {
        try? keychain.delete(hostname: hostname)  // replace any existing item

        var query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrSecurityDomain as String: keychainDomain,
            kSecAttrServer as String: hostname,
            kSecAttrAccount as String: username,
            kSecValueData as String: Data(password.utf8),
            kSecAttrSynchronizable as String: false,
        ]
        if let access = platformAccess(label: "container registry \(hostname)") {
            query[kSecAttrAccess as String] = access
        }
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw CLIError(command: "registry login \(hostname)", message: "SecItemAdd failed: \(status)")
        }
    }

    /// ACL trusting Davit plus every platform binary that reads registry
    /// credentials, across all install roots present on this machine.
    /// SecTrustedApplication/SecAccess are deprecated but remain the only way
    /// to pre-authorize other apps on file-based keychain items.
    private static func platformAccess(label: String) -> SecAccess? {
        var apps: [SecTrustedApplication] = []
        var selfApp: SecTrustedApplication?
        if SecTrustedApplicationCreateFromPath(nil, &selfApp) == errSecSuccess, let selfApp {
            apps.append(selfApp)
        }
        var roots = [PlatformInstaller.managedRoot, "/usr/local"]
        if let resolved = ContainerBinary.resolve(), !roots.contains(resolved.installRoot) {
            roots.append(resolved.installRoot)
        }
        let helpers = [
            "bin/container",
            "bin/container-apiserver",
            // Plugin layout: 1.0.0 used libexec/container/plugins, 1.1.0 (and
            // the brew keg) use libexec/container-plugins. Probe both.
            "libexec/container/plugins/container-core-images/bin/container-core-images",
            "libexec/container-plugins/container-core-images/bin/container-core-images",
        ]
        for root in roots {
            for helper in helpers {
                let path = "\(root)/\(helper)"
                guard FileManager.default.isExecutableFile(atPath: path) else { continue }
                var app: SecTrustedApplication?
                if SecTrustedApplicationCreateFromPath(path, &app) == errSecSuccess, let app {
                    apps.append(app)
                }
            }
        }
        var access: SecAccess?
        guard SecAccessCreate(label as CFString, apps as CFArray, &access) == errSecSuccess else { return nil }
        return access
    }

    static func logout(server rawServer: String) throws {
        let server = Reference.resolveDomain(domain: rawServer.trimmingCharacters(in: .whitespaces))
        do {
            try keychain.delete(hostname: server)
        } catch {
            throw CLIError(command: "registry logout \(server)", message: error.localizedDescription)
        }
    }
}
