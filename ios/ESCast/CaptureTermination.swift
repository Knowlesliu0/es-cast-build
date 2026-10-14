import Foundation
import ScreenCaptureKit

enum CaptureTermination {
    static func failure(for error: Error) -> Error? {
        let native = error as NSError
        if native.domain == SCStreamErrorDomain && native.code == SCStreamError.Code.userStopped.rawValue {
            return nil
        }
        return error
    }
}
