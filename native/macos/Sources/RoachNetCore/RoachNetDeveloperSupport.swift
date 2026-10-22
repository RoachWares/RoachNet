import CryptoKit
import Foundation
import Security

public struct RoachNetSecretRecord: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var label: String
    public var key: String
    public var scope: String
    public var notes: String
    public var createdAt: String
    public var updatedAt: String

    public init(
        id: String,
        label: String,
        key: String,
        scope: String,
        notes: String,
        createdAt: String,
        updatedAt: String
    ) {
        self.id = id
        self.label = label
        self.key = key
        self.scope = scope
        self.notes = notes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct RoachNetSecretTemplate: Identifiable, Hashable, Sendable {
    public let id: String
    public let label: String
    public let key: String
    public let scope: String
    public let notes: String

    public init(id: String, label: String, key: String, scope: String, notes: String) {
        self.id = id
        self.label = label
        self.key = key
        self.scope = scope
        self.notes = notes
    }
}

public enum RoachNetDeveloperPaths {
    public static func workspaceRoot(storagePath: String) -> String {
        URL(fileURLWithPath: storagePath)
            .appendingPathComponent("vault", isDirectory: true)
            .path
    }

    public static func projectsRoot(storagePath: String) -> String {
        URL(fileURLWithPath: workspaceRoot(storagePath: storagePath))
            .appendingPathComponent("projects", isDirectory: true)
            .path
    }

    public static func stateRoot(storagePath: String) -> String {
        URL(fileURLWithPath: workspaceRoot(storagePath: storagePath))
            .appendingPathComponent("secrets", isDirectory: true)
            .path
    }

    public static func roachBrainRoot(storagePath: String) -> String {
        URL(fileURLWithPath: workspaceRoot(storagePath: storagePath))
            .appendingPathComponent("roachbrain", isDirectory: true)
            .path
    }

    public static func secretsCatalogURL(storagePath: String) -> URL {
        URL(fileURLWithPath: stateRoot(storagePath: storagePath))
            .appendingPathComponent("manifest.json")
    }

    public static func roachBrainCatalogURL(storagePath: String) -> URL {
        URL(fileURLWithPath: roachBrainRoot(storagePath: storagePath))
            .appendingPathComponent("memories.json")
    }

    public static func ensureWorkspaceDirectories(storagePath: String) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: URL(fileURLWithPath: projectsRoot(storagePath: storagePath)),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: secretsCatalogURL(storagePath: storagePath).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: roachBrainCatalogURL(storagePath: storagePath).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }
}

public enum RoachNetSecretsCatalogStore {
    public static let suggestedTemplates: [RoachNetSecretTemplate] = [
        .init(
            id: "openai-api-key",
            label: "OpenAI API key",
            key: "OPENAI_API_KEY",
            scope: "AI / Cloud",
            notes:
                "Lets RoachClaw use OpenAI models for coding and as a fallback. They run on OpenAI's servers, not this Mac."
        ),
        .init(
            id: "openrouter-api-key",
            label: "OpenRouter API key",
            key: "OPENROUTER_API_KEY",
            scope: "AI / Cloud",
            notes:
                "Optional. Remote models from several providers with one key, for example as a fallback before a local model is ready."
        ),
        .init(
            id: "anthropic-api-key",
            label: "Anthropic API key",
            key: "ANTHROPIC_API_KEY",
            scope: "AI / Cloud",
            notes: "Optional. Remote Claude models for coding when a local model isn't available or is too slow."
        ),
        .init(
            id: "infisical-client-id",
            label: "Infisical client ID",
            key: "INFISICAL_CLIENT_ID",
            scope: "Secrets / Sync",
            notes: "Optional machine or service identity for syncing RoachNet metadata with Infisical."
        ),
        .init(
            id: "infisical-client-secret",
            label: "Infisical client secret",
            key: "INFISICAL_CLIENT_SECRET",
            scope: "Secrets / Sync",
            notes: "Pairs with the Infisical client ID if you turn on hosted secret sync."
        ),
        .init(
            id: "github-token",
            label: "GitHub Token",
            key: "GITHUB_TOKEN",
            scope: "Dev tools",
            notes: "Used for repo operations and release tooling."
        ),
        .init(
            id: "hugging-face-token",
            label: "Hugging Face token",
            key: "HUGGINGFACE_TOKEN",
            scope: "AI / Models",
            notes: "Lets RoachNet fetch gated model metadata and Spaces from Hugging Face."
        ),
        .init(
            id: "netlify-auth-token",
            label: "Netlify auth token",
            key: "NETLIFY_AUTH_TOKEN",
            scope: "Deployments",
            notes: "Used for site deploys and publishing the RoachNet Apps catalog."
        ),
        .init(
            id: "netlify-site-id",
            label: "Netlify site ID",
            key: "NETLIFY_SITE_ID",
            scope: "Deployments",
            notes: "Optional. Picks the Netlify site for roachnet.org deploys."
        ),
        .init(
            id: "netlify-apps-site-id",
            label: "Netlify Apps site ID",
            key: "NETLIFY_APPS_SITE_ID",
            scope: "Deployments",
            notes: "Optional. Picks the Netlify site for the RoachNet Apps catalog at apps.roachnet.org."
        ),
        .init(
            id: "cloudflare-api-token",
            label: "Cloudflare API token",
            key: "CLOUDFLARE_API_TOKEN",
            scope: "Edge / Infra",
            notes: "Used for DNS and edge routing. The token stays in the Keychain, not in a dotfile."
        ),
        .init(
            id: "cloudflare-account-id",
            label: "Cloudflare account ID",
            key: "CLOUDFLARE_ACCOUNT_ID",
            scope: "Edge / Infra",
            notes: "Pairs with the Cloudflare API token when the project needs Workers, DNS, or storage automation."
        ),
        .init(
            id: "paypal-client-id",
            label: "PayPal client ID",
            key: "PAYPAL_CLIENT_ID",
            scope: "Payments",
            notes: "For donation or checkout pages, without leaving payment credentials in workspace files."
        ),
    ]

    public static func load(storagePath: String) -> [RoachNetSecretRecord] {
        let url = RoachNetDeveloperPaths.secretsCatalogURL(storagePath: storagePath)
        guard
            let data = try? Data(contentsOf: url),
            let decoded = try? JSONDecoder().decode([RoachNetSecretRecord].self, from: data)
        else {
            return []
        }

        return decoded.sorted { lhs, rhs in
            lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
        }
    }

    public static func save(_ records: [RoachNetSecretRecord], storagePath: String) throws {
        try RoachNetDeveloperPaths.ensureWorkspaceDirectories(storagePath: storagePath)
        let url = RoachNetDeveloperPaths.secretsCatalogURL(storagePath: storagePath)
        let data = try JSONEncoder.pretty.encode(
            records.sorted {
                $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending
            })
        try data.write(to: url, options: [.atomic])
    }
}

public enum RoachNetKeychainSecretStore {
    public static func secretExists(id: String, installPath: String) -> Bool {
        (try? secretValue(id: id, installPath: installPath)) != nil
    }

    public static func secretValue(id: String, installPath: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName(for: installPath),
            kSecAttrAccount as String: id,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw keychainError(status)
        }
    }

    public static func setSecretValue(_ value: String, id: String, installPath: String) throws {
        let service = serviceName(for: installPath)
        let data = Data(value.utf8)

        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id,
        ]

        let updateFields: [String: Any] = [
            kSecValueData as String: data
        ]

        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, updateFields as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }

        if updateStatus != errSecItemNotFound {
            throw keychainError(updateStatus)
        }

        var createQuery = baseQuery
        createQuery[kSecValueData as String] = data
        createQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let createStatus = SecItemAdd(createQuery as CFDictionary, nil)
        guard createStatus == errSecSuccess else {
            throw keychainError(createStatus)
        }
    }

    public static func deleteSecret(id: String, installPath: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName(for: installPath),
            kSecAttrAccount as String: id,
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw keychainError(status)
        }
    }

    private static func serviceName(for installPath: String) -> String {
        let normalizedPath = URL(fileURLWithPath: installPath).standardizedFileURL.path
        let digest = SHA256.hash(data: Data(normalizedPath.utf8))
        let suffix = digest.compactMap { String(format: "%02x", $0) }.joined().prefix(16)
        return "com.roachnet.secret.\(suffix)"
    }

    private static func keychainError(_ status: OSStatus) -> NSError {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "Keychain failure (\(status))"
        return NSError(
            domain: "RoachNetKeychain",
            code: Int(status),
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
