import Foundation
import Security

enum KeychainServiceError: Error, LocalizedError {
    case encodingFailed
    case unexpectedData
    case osStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return "Failed to encode secret for Keychain storage."
        case .unexpectedData:
            return "Unexpected data returned from Keychain."
        case let .osStatus(status):
            let message = (SecCopyErrorMessageString(status, nil) as String?) ?? "OSStatus \(status)"
            return "Keychain error: \(message)"
        }
    }
}

struct KeychainService {
    private static let serviceName = "WPMediaUploader"
    private static let legacyServiceName = "WordpressMediaUploader"

    static func setSecret(_ secret: String, account: String) throws {
        guard let data = secret.data(using: .utf8) else {
            throw KeychainServiceError.encodingFailed
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }

        if updateStatus != errSecItemNotFound {
            throw KeychainServiceError.osStatus(updateStatus)
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainServiceError.osStatus(addStatus)
        }
    }

    static func getSecret(account: String) throws -> String? {
        if let secret = try getSecret(account: account, service: serviceName) {
            return secret
        }

        if let secret = try getSecret(account: account, service: legacyServiceName) {
            // Best-effort migration into the new service name.
            try? setSecret(secret, account: account)
            return secret
        }

        return nil
    }

    private static func getSecret(account: String, service: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        if status == errSecItemNotFound {
            return nil
        }

        guard status == errSecSuccess else {
            throw KeychainServiceError.osStatus(status)
        }

        guard let data = item as? Data,
              let secret = String(data: data, encoding: .utf8)
        else {
            throw KeychainServiceError.unexpectedData
        }

        return secret
    }

    /// Deletes every stranded askpass-* secret. Askpass items live only for
    /// the duration of one ssh invocation and are removed by
    /// SSHAuthContext.cleanup(); a crash or force-quit strands them with
    /// random account names nothing can look up, so the app sweeps at launch.
    static func deleteStrandedAskPassSecrets() {
        for currentService in [serviceName, legacyServiceName] {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: currentService,
                kSecReturnAttributes as String: true,
                kSecMatchLimit as String: kSecMatchLimitAll
            ]

            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            guard status == errSecSuccess, let items = result as? [[String: Any]] else { continue }

            for item in items {
                guard let account = item[kSecAttrAccount as String] as? String,
                      account.hasPrefix("askpass-")
                else { continue }
                try? deleteSecret(account: account)
            }
        }
    }

    static func deleteSecret(account: String) throws {
        var firstFailure: OSStatus?
        for currentService in [serviceName, legacyServiceName] {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: currentService,
                kSecAttrAccount as String: account
            ]

            let status = SecItemDelete(query as CFDictionary)
            if status != errSecSuccess, status != errSecItemNotFound, firstFailure == nil {
                firstFailure = status
            }
        }

        if let firstFailure {
            throw KeychainServiceError.osStatus(firstFailure)
        }
    }
}
