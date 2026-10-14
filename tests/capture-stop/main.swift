import Foundation
import ScreenCaptureKit

struct TerminationTestFailure: Error { let message: String }
func check(_ condition: Bool, _ message: String) throws {
    if !condition { throw TerminationTestFailure(message: message) }
}
let tests: [(String, () throws -> Void)] = [
    ("observed userStopped is an intentional termination", {
        let observed = NSError(domain: "com.apple.ScreenCaptureKit.SCStreamErrorDomain", code: -3817)
        try check(observed.domain == SCStreamErrorDomain && observed.code == SCStreamError.Code.userStopped.rawValue,
                  "device error must match the official SDK userStopped code")
        try check(CaptureTermination.failure(for: observed) == nil, "userStopped must not fail a completed capture")
    }),
    ("unexpected capture errors preserve the original failure", {
        let original = NSError(domain: SCStreamErrorDomain, code: -3802,
                               userInfo: [NSLocalizedDescriptionKey: "capture interrupted"])
        let retained = CaptureTermination.failure(for: original) as NSError?
        try check(retained === original, "unexpected failure identity and details must be retained")
    }),
    ("another domain with the same code remains a failure", {
        let original = NSError(domain: "ESCast.HLS", code: -3817)
        try check((CaptureTermination.failure(for: original) as NSError?) === original,
                  "numeric code alone must not suppress an encoder error")
    })
]
var failed = 0
for (name, test) in tests {
    do { try test(); print("PASS: \(name)") }
    catch { failed += 1; print("FAIL: \(name): \(error)") }
}
print("Capture termination: \(tests.count - failed)/\(tests.count) passed")
exit(failed == 0 ? 0 : 1)
