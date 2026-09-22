import Foundation
import RightMouseCore

do {
    var total = try runProtocolChecks()
    total += try await runFileEngineChecks()
    total += try runMenuChecks()
    total += try runSettingsChecks()
    total += try runReviewChecks()
    total += try await runTransferRecoveryChecks()
    total += try runStorageFallbackChecks()
    print("PASS: \(total) core fixture checks; real Finder, TCC, signing and multi-volume checks remain separate.")
} catch {
    fputs("FAIL: \(error)\n", stderr)
    exit(1)
}
