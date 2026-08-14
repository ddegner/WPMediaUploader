import Foundation

enum ProfileValidationContext {
    case editor
    case execution
}

enum ProfileValidation {
    static func firstError(
        for profile: ServerProfile,
        password: String?,
        context: ProfileValidationContext
    ) -> String? {
        if context == .editor, profile.name.trimmed.isEmpty {
            return "Profile name is required"
        }

        if profile.host.trimmed.isEmpty {
            return "Host is required"
        }

        if profile.username.trimmed.isEmpty {
            return "Username is required"
        }

        if profile.port <= 0 {
            return "Port must be greater than 0"
        }

        if profile.wpRootPath.trimmed.isEmpty {
            return "WordPress root path is required"
        }

        if profile.remoteStagingRoot.trimmed.isEmpty {
            return "Remote staging root is required"
        }

        if profile.authType == .password {
            guard let password, !password.trimmed.isEmpty else {
                if context == .execution {
                    return "Password auth selected, but no password is stored in Keychain"
                }
                return "Password is required"
            }
        }

        if profile.authType == .sshKey,
           let keyPath = profile.keyPath,
           !keyPath.trimmed.isEmpty
        {
            if let keyBookmarkData = profile.keyBookmarkData {
                do {
                    let access = try SecurityScopedFileAccess.start(
                        path: keyPath,
                        bookmarkData: keyBookmarkData,
                        purpose: "SSH key file"
                    )
                    access.stop()
                } catch {
                    return error.localizedDescription
                }
            } else if !FileManager.default.fileExists(atPath: keyPath) {
                return "SSH key file not found at \(keyPath)"
            }
        }

        return nil
    }

    static func canSave(profile: ServerProfile, password: String) -> Bool {
        firstError(for: profile, password: password, context: .editor) == nil
    }
}
