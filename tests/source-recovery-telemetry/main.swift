import Foundation

do {
    try SourceRecoveryTelemetryTests().testRecoverySeparatesRawCallbackFromValidVideoAndDetachesWriter()
    print("PASS: raw callbacks, valid recovery, writer detachment, and single diagnostic events")
} catch {
    print("FAIL: source recovery telemetry: \(error)")
    exit(1)
}
