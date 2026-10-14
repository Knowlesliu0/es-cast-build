import Foundation

var failures = 0
func expect(_ actual: LiveRelayCaptureGate.Decision, _ expected: LiveRelayCaptureGate.Decision,
            _ label: String) {
    if actual != expected {
        failures += 1
        print("FAIL: \(label): expected \(expected), got \(actual)")
    } else { print("PASS: \(label)") }
}

let first = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
let second = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
var waiting = LiveRelayCaptureGate()
expect(waiting.update(active: false, ready: false, sessionID: nil, pickerBusy: false), .wait,
       "arming before picker does not cancel itself")
expect(waiting.update(active: false, ready: false, sessionID: nil, pickerBusy: true), .wait,
       "picker remains pending")
expect(waiting.update(active: false, ready: false, sessionID: nil, pickerBusy: false),
       .stop("picker_cancelled"), "picker cancellation releases the armed consumer")
expect(waiting.update(active: true, ready: true, sessionID: first, pickerBusy: false), .wait,
       "cancelled capture cannot start later from a delayed callback")

var running = LiveRelayCaptureGate()
expect(running.update(active: true, ready: false, sessionID: nil, pickerBusy: false), .wait,
       "partial published state has no capture identity yet")
expect(running.update(active: true, ready: false, sessionID: first, pickerBusy: false), .wait,
       "consumer waits for the same source to finalize live fragments")
expect(running.update(active: true, ready: true, sessionID: first, pickerBusy: false), .start(first),
       "the current ready capture starts exactly once")
expect(running.update(active: true, ready: true, sessionID: first, pickerBusy: false), .wait,
       "repeated readiness must not create another player")
expect(running.update(active: true, ready: false, sessionID: first, pickerBusy: false),
       .stop("capture_not_ready"), "source failure stops playback instead of looping old media")
expect(running.update(active: true, ready: true, sessionID: first, pickerBusy: false), .wait,
       "failed capture never silently resumes")

var replaced = LiveRelayCaptureGate()
expect(replaced.update(active: true, ready: true, sessionID: first, pickerBusy: false), .start(first),
       "first capture binds its identity")
expect(replaced.update(active: true, ready: true, sessionID: second, pickerBusy: false),
       .stop("capture_session_changed"), "a new capture cannot inherit the retired consumer")

var stopped = LiveRelayCaptureGate()
expect(stopped.update(active: true, ready: true, sessionID: first, pickerBusy: false), .start(first),
       "a fresh arm can start the source again")
expect(stopped.update(active: false, ready: false, sessionID: first, pickerBusy: true),
       .stop("capture_stopped"), "capture shutdown stops the consumer before encoder drain")

var identityLost = LiveRelayCaptureGate()
expect(identityLost.update(active: true, ready: false, sessionID: first, pickerBusy: false), .wait,
       "an unready source still owns its identity")
expect(identityLost.update(active: true, ready: false, sessionID: nil, pickerBusy: false),
       .stop("capture_session_changed"), "lost capture identity cannot keep an armed player")

print("Live relay lifecycle: \(16 - failures)/16 passed")
if failures > 0 { exit(1) }
