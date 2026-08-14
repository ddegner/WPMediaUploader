import Foundation

/// The SSH_ASKPASS helper protocol, extracted from main.swift so the app's
/// most security-sensitive branch is unit-testable with a stubbed lookup.
///
/// ssh(1) execs the app binary with WP_ASKPASS_MODE=1 and expects the secret
/// on stdout; the account name arrives via WP_ASKPASS_KEYCHAIN_ACCOUNT.
enum AskPass {
    static func isAskPassInvocation(environment: [String: String]) -> Bool {
        environment["WP_ASKPASS_MODE"] == "1"
    }

    /// Returns the secret to print (caller exits 0), or nil when the account
    /// is missing, empty, unreadable, or has no stored secret (caller exits
    /// 1 so ssh treats it as a failed prompt — never prints anything else).
    static func response(
        environment: [String: String],
        secretLookup: (String) throws -> String?
    ) -> String? {
        guard isAskPassInvocation(environment: environment),
              let account = environment["WP_ASKPASS_KEYCHAIN_ACCOUNT"],
              !account.isEmpty
        else { return nil }

        return (try? secretLookup(account)) ?? nil
    }
}
