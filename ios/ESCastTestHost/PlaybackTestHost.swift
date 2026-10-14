import SwiftUI

// ScreenCaptureKit's iOS SDK is device-only. This host loads the production
// PlaybackModel for simulator tests without substituting a mock player model.
@main
struct PlaybackTestHost: App {
    var body: some Scene {
        WindowGroup { Text("ES Cast playback regression tests") }
    }
}
