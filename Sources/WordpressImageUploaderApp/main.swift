import Foundation
import SwiftUI

// Support SSH askpass helper mode.
// When ssh(1) needs a password, it execs SSH_ASKPASS and reads stdout.
// We point SSH_ASKPASS at this binary and set WP_ASKPASS_MODE=1.
// The sandbox allows exec of signed app-bundle binaries; shell scripts are blocked.
let launchEnvironment = ProcessInfo.processInfo.environment
if AskPass.isAskPassInvocation(environment: launchEnvironment) {
    if let secret = AskPass.response(
        environment: launchEnvironment,
        secretLookup: KeychainService.getSecret(account:)
    ) {
        print(secret)
        exit(0)
    }
    exit(1)
}

// One-time launch cleanup: clear AVIF scratch left by a prior run. This must
// NOT live in JobRunner.init — SwiftUI re-runs view initializers, constructing
// throwaway JobRunners while a live encode may be writing to this directory.
try? FileManager.default.removeItem(at: AppPaths.avifWorkRootDirectory)

// One-time launch cleanup: askpass secrets are per-ssh-invocation Keychain
// items that a crash or force-quit strands forever (their random account
// names can't be looked up later). No job is running at launch, so every
// surviving askpass item is garbage. Safe here because the askpass helper
// path above exits before reaching this line.
KeychainService.deleteStrandedAskPassSecrets()

WordpressMediaUploaderApp.main()
