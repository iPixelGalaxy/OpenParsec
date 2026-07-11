import AppKit
import CoreGraphics
import Foundation
import Network

struct DisplayMode: Codable, Hashable {
    let width: Int
    let height: Int
    let refresh: Int
    var title: String { return "\(width)×\(height) @ \(refresh) Hz" }
}

private struct Request: Decodable {
    let type: String
    let code: String?
    let token: String?
    let width: Int?
    let height: Int?
    let enabled: Bool?
}

private struct Response: Encodable {
    let type: String = "response"
    let ok: Bool
    let error: String?
    let token: String?
    let modes: [DisplayMode]?
    let current: DisplayMode?
    let cursorEnabled: Bool?
}

private struct CursorEvent: Encodable {
    let type = "cursorPosition"
    let sequence: UInt64
    let x: Double
    let y: Double
    let displayWidth: Int
    let displayHeight: Int
    let visible: Bool
    let timestamp: TimeInterval
}

final class CursorView: NSView {
    override var isOpaque: Bool { return false }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setStroke(); NSColor.white.setFill()
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 2, y: 29)); path.line(to: NSPoint(x: 2, y: 3)); path.line(to: NSPoint(x: 21, y: 21)); path.line(to: NSPoint(x: 12, y: 21)); path.line(to: NSPoint(x: 17, y: 31)); path.line(to: NSPoint(x: 12, y: 33)); path.line(to: NSPoint(x: 7, y: 22)); path.close()
        path.lineWidth = 2; path.fill(); path.stroke()
    }
}

final class CursorOverlay {
    private let panel: NSPanel
    private var timer: Timer?
    var enabled = false { didSet { enabled ? panel.orderFrontRegardless() : panel.orderOut(nil) } }
    var onPosition: ((Double, Double, Int, Int) -> Void)?
    private var lastPoint = NSPoint(x: -1, y: -1)
    private var lastSent: TimeInterval = 0
    private var testStarted: TimeInterval?

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 48, height: 48), styleMask: .borderless, backing: .buffered, defer: false)
        panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = false; panel.ignoresMouseEvents = true
        panel.level = .floating; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.sharingType = .readOnly; panel.hidesOnDeactivate = false; panel.animationBehavior = .none
        panel.contentView = CursorView(frame: NSRect(x: 0, y: 0, width: 48, height: 48))
        start(); panel.orderOut(nil)
    }

    private func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }
    private func tick() {
        let now = Date.timeIntervalSinceReferenceDate
        var point = NSEvent.mouseLocation
        if let started = testStarted {
            let elapsed = now - started
            if elapsed >= 4 { testStarted = nil; if !enabled { panel.orderOut(nil) } }
            else if let screen = NSScreen.main {
                let positions = [NSPoint(x: screen.frame.midX, y: screen.frame.midY), NSPoint(x: screen.frame.minX + 30, y: screen.frame.maxY - 30), NSPoint(x: screen.frame.maxX - 30, y: screen.frame.maxY - 30), NSPoint(x: screen.frame.maxX - 30, y: screen.frame.minY + 30)]
                point = positions[min(Int(elapsed), positions.count - 1)]
            }
        }
        if enabled || testStarted != nil { panel.orderFrontRegardless(); panel.setFrameOrigin(NSPoint(x: point.x - 2, y: point.y - 33)) }
        guard point != lastPoint || now - lastSent >= 1 else { return }
        lastPoint = point; lastSent = now
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) ?? NSScreen.main else { return }
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        let mode = number.flatMap { CGDisplayCopyDisplayMode(CGDirectDisplayID($0.uint32Value)) }
        let pixelWidth = mode?.pixelWidth ?? Int(screen.frame.width), pixelHeight = mode?.pixelHeight ?? Int(screen.frame.height)
        let x = max(0, min(1, Double((point.x - screen.frame.minX) / screen.frame.width)))
        let y = max(0, min(1, Double((screen.frame.maxY - point.y) / screen.frame.height)))
        onPosition?(x, y, pixelWidth, pixelHeight)
    }
    func test() { testStarted = Date.timeIntervalSinceReferenceDate; panel.orderFrontRegardless() }
}

final class DisplayController {
    private let display = CGMainDisplayID()
    private(set) var original: CGDisplayMode?
    init() { original = CGDisplayCopyDisplayMode(display) }

    func modes() -> [DisplayMode] {
        let options = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
        let all = (CGDisplayCopyAllDisplayModes(display, options) as? [CGDisplayMode]) ?? []
        let values = all.map { DisplayMode(width: $0.pixelWidth, height: $0.pixelHeight, refresh: Int($0.refreshRate == 0 ? 60 : $0.refreshRate.rounded())) }
        return Array(Set(values)).filter { $0.refresh >= 50 && $0.width >= 1024 }.sorted { ($0.width * $0.height, $0.refresh) > ($1.width * $1.height, $1.refresh) }
    }

    func current() -> DisplayMode? {
        guard let mode = CGDisplayCopyDisplayMode(display) else { return nil }
        return DisplayMode(width: mode.pixelWidth, height: mode.pixelHeight, refresh: Int(mode.refreshRate == 0 ? 60 : mode.refreshRate.rounded()))
    }

    func set(width: Int, height: Int) -> Bool {
        let options = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(display, options) as? [CGDisplayMode] else { return false }
        var candidates = modes.filter { $0.pixelWidth == width && $0.pixelHeight == height }
        if candidates.isEmpty {
            let eligible = modes.filter { $0.pixelWidth <= width && $0.pixelHeight <= height && ($0.refreshRate == 0 || $0.refreshRate >= 50) }
            if let best = eligible.max(by: { $0.pixelWidth * $0.pixelHeight < $1.pixelWidth * $1.pixelHeight }) {
                candidates = eligible.filter { $0.pixelWidth == best.pixelWidth && $0.pixelHeight == best.pixelHeight }
            }
        }
        guard let mode = candidates.min(by: { abs(($0.refreshRate == 0 ? 60 : $0.refreshRate) - 60) < abs(($1.refreshRate == 0 ? 60 : $1.refreshRate) - 60) }) else { return false }
        return CGDisplaySetDisplayMode(display, mode, nil) == .success
    }

    func restore() -> Bool { guard let original = original else { return false }; return CGDisplaySetDisplayMode(display, original, nil) == .success }
}

final class CompanionServer {
    private let display: DisplayController
    private let cursor: CursorOverlay
    private let pairingCode: String
    private var token: String
    private var listener: NWListener?
    private var subscribers: [ObjectIdentifier: NWConnection] = [:]
    private var sequence: UInt64 = 0

    init(display: DisplayController, cursor: CursorOverlay, pairingCode: String) {
        self.display = display; self.cursor = cursor; self.pairingCode = pairingCode
        token = UserDefaults.standard.string(forKey: "CompanionToken") ?? UUID().uuidString
        UserDefaults.standard.set(token, forKey: "CompanionToken")
        cursor.onPosition = { [weak self] x, y, width, height in self?.broadcastCursor(x: x, y: y, width: width, height: height) }
    }

    func start() throws {
        let listener = try NWListener(using: .tcp, on: .any)
        listener.service = NWListener.Service(name: Host.current().localizedName ?? "Mac", type: "_openparsec._tcp")
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: .main); self.listener = listener
    }

    private func accept(_ connection: NWConnection) { connection.start(queue: .main); receive(connection, buffer: Data()) }
    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, _ in
            var pending = buffer; if let data = data { pending.append(data) }
            while let newline = pending.firstIndex(of: 10) {
                let line = pending.prefix(upTo: newline); pending.removeSubrange(...newline)
                if let request = try? JSONDecoder().decode(Request.self, from: line) { self?.handle(request, connection: connection) }
            }
            if !complete { self?.receive(connection, buffer: pending) } else { self?.subscribers.removeValue(forKey: ObjectIdentifier(connection)) }
        }
    }

    private func handle(_ request: Request, connection: NWConnection) {
        if request.type == "pair" {
            guard request.code == pairingCode else { return send(Response(ok: false, error: "Invalid pairing code", token: nil, modes: nil, current: nil, cursorEnabled: nil), to: connection) }
            return send(Response(ok: true, error: nil, token: token, modes: display.modes(), current: display.current(), cursorEnabled: cursor.enabled), to: connection)
        }
        guard request.token == token else { return send(Response(ok: false, error: "Unauthorized", token: nil, modes: nil, current: nil, cursorEnabled: nil), to: connection) }
        switch request.type {
        case "status": send(Response(ok: true, error: nil, token: nil, modes: display.modes(), current: display.current(), cursorEnabled: cursor.enabled), to: connection)
        case "setMode":
            let ok = request.width.flatMap { width in request.height.map { display.set(width: width, height: $0) } } ?? false
            send(Response(ok: ok, error: ok ? nil : "Unsupported display mode", token: nil, modes: nil, current: display.current(), cursorEnabled: cursor.enabled), to: connection)
        case "cursor": cursor.enabled = request.enabled ?? true; send(Response(ok: true, error: nil, token: nil, modes: nil, current: display.current(), cursorEnabled: cursor.enabled), to: connection)
        case "subscribeCursor": subscribers[ObjectIdentifier(connection)] = connection; send(Response(ok: true, error: nil, token: nil, modes: nil, current: display.current(), cursorEnabled: cursor.enabled), to: connection)
        case "unsubscribeCursor": subscribers.removeValue(forKey: ObjectIdentifier(connection)); send(Response(ok: true, error: nil, token: nil, modes: nil, current: display.current(), cursorEnabled: cursor.enabled), to: connection)
        case "restore": let ok = display.restore(); send(Response(ok: ok, error: ok ? nil : "Unable to restore display mode", token: nil, modes: nil, current: display.current(), cursorEnabled: cursor.enabled), to: connection)
        default: send(Response(ok: false, error: "Unknown command", token: nil, modes: nil, current: nil, cursorEnabled: nil), to: connection)
        }
    }

    private func broadcastCursor(x: Double, y: Double, width: Int, height: Int) {
        sequence &+= 1
        let event = CursorEvent(sequence: sequence, x: x, y: y, displayWidth: width, displayHeight: height, visible: true, timestamp: Date().timeIntervalSince1970)
        guard var data = try? JSONEncoder().encode(event) else { return }; data.append(10)
        for connection in subscribers.values { connection.send(content: data, completion: .contentProcessed { _ in }) }
    }

    private func send(_ response: Response, to connection: NWConnection) {
        guard var data = try? JSONEncoder().encode(response) else { return }; data.append(10)
        connection.send(content: data, completion: .contentProcessed { _ in })
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let display = DisplayController(), cursor = CursorOverlay()
    private var server: CompanionServer?, item: NSStatusItem!
    private let pairingCode = String(format: "%06d", Int.random(in: 0...999999))

    func applicationDidFinishLaunching(_ notification: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength); item.button?.title = "OP"
        rebuildMenu()
        server = CompanionServer(display: display, cursor: cursor, pairingCode: pairingCode)
        do { try server?.start() } catch { present(error.localizedDescription) }
    }

    private func rebuildMenu() {
        let menu = NSMenu(); menu.addItem(withTitle: "Pairing code: \(pairingCode)", action: nil, keyEquivalent: "")
        menu.addItem(withTitle: "Current: \(display.current()?.title ?? "Unknown")", action: nil, keyEquivalent: "")
        let cursorItem = menu.addItem(withTitle: cursor.enabled ? "Hide captured overlay" : "Show captured overlay", action: #selector(toggleCursor), keyEquivalent: ""); cursorItem.target = self
        let testCursor = menu.addItem(withTitle: "Test captured overlay", action: #selector(testCursorOverlay), keyEquivalent: ""); testCursor.target = self
        let restore = menu.addItem(withTitle: "Restore original resolution", action: #selector(restoreMode), keyEquivalent: ""); restore.target = self
        menu.addItem(.separator()); let quit = menu.addItem(withTitle: "Quit", action: #selector(quit), keyEquivalent: "q"); quit.target = self
        item.menu = menu
    }
    @objc private func toggleCursor() { cursor.enabled.toggle(); rebuildMenu() }
    @objc private func testCursorOverlay() { cursor.test() }
    @objc private func restoreMode() { _ = display.restore(); rebuildMenu() }
    @objc private func quit() { NSApplication.shared.terminate(nil) }
    private func present(_ message: String) { let alert = NSAlert(); alert.messageText = "OpenParsec Host"; alert.informativeText = message; alert.runModal() }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
