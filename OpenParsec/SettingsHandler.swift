import Foundation

struct SettingsHandler {
    private static let defaults = UserDefaults.standard
    private static func value<T: RawRepresentable>(_ key: String, default fallback: T) -> T where T.RawValue == Int {
        guard defaults.object(forKey: key) != nil else { return fallback }
        return T(rawValue: defaults.integer(forKey: key)) ?? fallback
    }
    static var resolution: ParsecResolution { get { defaults.string(forKey: "resolution").flatMap(ParsecResolution.init(rawValue:)) ?? .client } set { defaults.set(newValue.rawValue, forKey: "resolution") } }
    static var bitrate: Int { get { defaults.integer(forKey: "bitrate") } set { defaults.set(newValue, forKey: "bitrate") } }
    static var decoder: DecoderPref { get { value("decoder", default: .h264) } set { defaults.set(newValue.rawValue, forKey: "decoder") } }
    static var cursorMode: CursorMode { get { value("cursorMode", default: .touchpad) } set { defaults.set(newValue.rawValue, forKey: "cursorMode") } }
    static var cursorScale: Double { get { defaults.object(forKey: "cursorScale") == nil ? 0.5 : defaults.double(forKey: "cursorScale") } set { defaults.set(newValue, forKey: "cursorScale") } }
    static var mouseSensitivity: Double { get { defaults.object(forKey: "mouseSensitivity") == nil ? 1 : defaults.double(forKey: "mouseSensitivity") } set { defaults.set(newValue, forKey: "mouseSensitivity") } }
    static var noOverlay: Bool { get { defaults.bool(forKey: "noOverlay") } set { defaults.set(newValue, forKey: "noOverlay") } }
    static var hideStatusBar: Bool { get { defaults.object(forKey: "hideStatusBar") == nil ? true : defaults.bool(forKey: "hideStatusBar") } set { defaults.set(newValue, forKey: "hideStatusBar") } }
    static var rightClickPosition: RightClickPosition { get { value("rightClickPosition", default: .firstFinger) } set { defaults.set(newValue.rawValue, forKey: "rightClickPosition") } }
    static var preferredFramesPerSecond: Int { get { defaults.object(forKey: "preferredFramesPerSecond") == nil ? 60 : defaults.integer(forKey: "preferredFramesPerSecond") } set { defaults.set(newValue, forKey: "preferredFramesPerSecond") } }
    static var decoderCompatibility: Bool { get { defaults.bool(forKey: "decoderCompatibility") } set { defaults.set(newValue, forKey: "decoderCompatibility") } }
    static var showKeyboardButton: Bool { get { defaults.object(forKey: "showKeyboardButton") == nil ? true : defaults.bool(forKey: "showKeyboardButton") } set { defaults.set(newValue, forKey: "showKeyboardButton") } }
    static var saveSessionSettings: Bool { get { defaults.object(forKey: "saveSessionSettings") == nil ? true : defaults.bool(forKey: "saveSessionSettings") } set { defaults.set(newValue, forKey: "saveSessionSettings") } }
    static var savedZoomEnabled: Bool { get { defaults.bool(forKey: "savedZoomEnabled") } set { defaults.set(newValue, forKey: "savedZoomEnabled") } }
    static var savedConstantFps: Bool { get { defaults.bool(forKey: "savedConstantFps") } set { defaults.set(newValue, forKey: "savedConstantFps") } }
    static var savedMuted: Bool { get { defaults.bool(forKey: "savedMuted") } set { defaults.set(newValue, forKey: "savedMuted") } }
}
