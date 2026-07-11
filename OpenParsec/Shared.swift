import Foundation

struct GLBData { let SessionKeyChainKey = "OPStoredAuthData" }
final class GLBDataModel { static let shared = GLBData() }

extension String {
    static func fromBuffer(_ ptr: UnsafeMutablePointer<CChar>, length: Int) -> String {
        return NSString(bytes: ptr, length: length, encoding: String.Encoding.utf8.rawValue)! as String
    }
}

final class StreamState {
    static let shared = StreamState()
    var onChange: (() -> Void)?
    var resolutionX = 0 { didSet { notify() } }
    var resolutionY = 0 { didSet { notify() } }
    var bitrate = 0 { didSet { notify() } }
    var constantFps = false { didSet { notify() } }
    var output = "none" { didSet { notify() } }
    var displayConfigs: [ParsecDisplayConfig] = [] { didSet { notify() } }
    private func notify() { DispatchQueue.main.async { self.onChange?() } }
}

enum DataManager { static let model = StreamState.shared }

final class CursorPositionHelper {
    static func toHost(_ xp: Int, _ yp: Int) -> (Int, Int) {
        let xh = CParsec.hostWidth, yh = CParsec.hostHeight, xc = CParsec.clientWidth, yc = CParsec.clientHeight
        let tc = yc / xc, th = yh / xh
        let xa: Float, ya: Float
        if th < tc { xa = Float(xp) * xh / xc; ya = (Float(yp) - 0.5 * (yc - xc * th)) * xh / xc }
        else { ya = Float(yp) * yh / yc; xa = (Float(xp) - 0.5 * (xc - yc / th)) * yh / yc }
        return (Int(ParsecSDKBridge.clamp(xa, minValue: 0, maxValue: xh)), Int(ParsecSDKBridge.clamp(ya, minValue: 0, maxValue: yh)))
    }
    static func toClient(_ xa: Int, _ ya: Int) -> (Int, Int) {
        let xh = CParsec.hostWidth, yh = CParsec.hostHeight, xc = CParsec.clientWidth, yc = CParsec.clientHeight
        let tc = yc / xc, th = yh / xh
        let xp: Float, yp: Float
        if th < tc { xp = Float(xa) * xc / xh; yp = Float(ya) * xc / xh + 0.5 * (yc - xc * th) }
        else { yp = Float(ya) * yc / yh; xp = (Float(xa) - 0.5 * (xc - yc / th)) * yh / yc }
        return (Int(ParsecSDKBridge.clamp(xp, minValue: 0, maxValue: xc)), Int(ParsecSDKBridge.clamp(yp, minValue: 0, maxValue: yc)))
    }
}
