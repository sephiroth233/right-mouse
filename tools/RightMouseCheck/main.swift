import Foundation
import RightMouseCore

do {
    var total = try runProtocolChecks()
    total += try runLocalFinderRequestChecks()
    total += try await runFileEngineChecks()
    total += try runMenuChecks()
    total += try runMenuCustomizationChecks()
    total += try runSettingsChecks()
    total += try runReviewChecks()
    total += try await runTransferRecoveryChecks()
    total += try runStorageFallbackChecks()
    total += try runRecentDestinationChecks()
    total += try await runTransferFailureChecks()
    total += try runDiagnosticChecks()
    total += try await runStagingRetentionChecks()
    total += try runConfigurationLimitChecks()
    total += try runRecoveryEvidenceChecks()
    total += try runStorageSeparationChecks()
    total += try await runStagingRecoveryChecks()
    total += try await runRaceChecks()
    print("PASS: \(total) core fixture checks; real Finder, TCC, signing and multi-volume checks remain separate.")
} catch {
    fputs("FAIL: \(error)\n", stderr)
    exit(1)
}
