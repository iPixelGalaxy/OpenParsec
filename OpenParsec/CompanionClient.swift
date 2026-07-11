import Foundation

enum CompanionCursorState { case sdk, waiting, companion }
enum CompanionRuntime {
    static var cursorState: CompanionCursorState = .sdk
    static var lastEvent: CompanionCursorEvent?
}

struct CompanionCursorEvent: Codable {
    let type: String
    let sequence: UInt64
    let x: Double
    let y: Double
    let displayWidth: Int
    let displayHeight: Int
    let visible: Bool
    let timestamp: TimeInterval
}

struct CompanionMode: Codable {
    let width: Int
    let height: Int
    let refresh: Int
}

private struct CompanionResponse: Codable {
    let type: String? = nil
    let ok: Bool
    let error: String?
    let token: String?
    let modes: [CompanionMode]?
    let current: CompanionMode?
    let cursorEnabled: Bool?
}

final class CompanionClient: NSObject, NetServiceBrowserDelegate, NetServiceDelegate, StreamDelegate {
    private let browser = NetServiceBrowser()
    private var services: [NetService] = []
    private var input: InputStream?, output: OutputStream?, buffer = Data()
    private var outgoing = Data()
    private var pending: ((CompanionResponse) -> Void)?
    private var livenessTimer: Timer?
    private(set) var discoveredName: String?
    private let tokenKey = "OpenParsecCompanionToken"
    private var token: String? { get { UserDefaults.standard.string(forKey: tokenKey) } set { UserDefaults.standard.set(newValue, forKey: tokenKey) } }
    var isPaired: Bool { return token != nil }

    override init() {
        super.init(); browser.delegate = self; browser.searchForServices(ofType: "_openparsec._tcp.", inDomain: "local.")
        livenessTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            guard CompanionRuntime.cursorState == .companion, let event = CompanionRuntime.lastEvent, Date().timeIntervalSince1970 - event.timestamp > 2.5 else { return }
            CompanionRuntime.cursorState = .sdk
            NotificationCenter.default.post(name: .companionCursorUnavailable, object: nil)
        }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        guard !services.contains(where: { $0.name == service.name }) else { return }
        services.append(service); discoveredName = service.name; service.delegate = self; service.resolve(withTimeout: 5)
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) { services.removeAll { $0.name == service.name } }

    func pair(code: String, completion: @escaping (Result<String, Error>) -> Void) {
        send(["type": "pair", "code": code]) { [weak self] response in
            if response.ok, let token = response.token { self?.token = token; SettingsHandler.companionCursorEnabled = true; completion(.success(self?.discoveredName ?? "Mac")) }
            else { completion(.failure(NSError(domain: "OpenParsecCompanion", code: 1, userInfo: [NSLocalizedDescriptionKey: response.error ?? "Pairing failed"]))) }
        }
    }

    func prepareLegacyMode(completion: @escaping () -> Void) {
        CompanionRuntime.cursorState = .sdk
        guard isPaired else { completion(); return }
        command(type: "setMode", extra: ["width": 1920, "height": 1200]) { [weak self] response in
            guard response.ok, SettingsHandler.companionCursorEnabled else { completion(); return }
            self?.subscribeCursor { _ in completion() }
        }
    }

    func setMode(width: Int, height: Int, completion: ((Bool) -> Void)? = nil) { command(type: "setMode", extra: ["width": width, "height": height]) { completion?($0.ok) } }
    func setCursorEnabled(_ enabled: Bool) { if enabled { subscribeCursor { _ in } } else { command(type: "unsubscribeCursor", extra: [:]) { _ in CompanionRuntime.cursorState = .sdk; NotificationCenter.default.post(name: .companionCursorUnavailable, object: nil) } } }
    private func subscribeCursor(completion: @escaping (Bool) -> Void) {
        CompanionRuntime.cursorState = .waiting
        command(type: "subscribeCursor", extra: [:]) { response in
            if !response.ok { CompanionRuntime.cursorState = .sdk; NotificationCenter.default.post(name: .companionCursorUnavailable, object: nil) }
            completion(response.ok)
        }
    }

    private func command(type: String, extra: [String: Any], completion: @escaping (CompanionResponse) -> Void) {
        guard let token = token else { return completion(CompanionResponse(ok: false, error: "Not paired", token: nil, modes: nil, current: nil, cursorEnabled: nil)) }
        var request = extra; request["type"] = type; request["token"] = token; send(request, completion: completion)
    }

    private func send(_ object: [String: Any], completion: @escaping (CompanionResponse) -> Void) {
        guard pending == nil, let data = try? JSONSerialization.data(withJSONObject: object) else { return completion(CompanionResponse(ok: false, error: "Companion busy", token: nil, modes: nil, current: nil, cursorEnabled: nil)) }
        pending = completion
        if output == nil { guard openStreams() else { pending = nil; return completion(CompanionResponse(ok: false, error: "No companion discovered", token: nil, modes: nil, current: nil, cursorEnabled: nil)) } }
        outgoing = data; outgoing.append(10); flushOutput()
    }

    private func openStreams() -> Bool {
        guard let service = services.first else { return false }
        var read: InputStream?, write: OutputStream?
        guard service.getInputStream(&read, outputStream: &write), let readStream = read, let writeStream = write else { return false }
        input = readStream; output = writeStream
        readStream.delegate = self; writeStream.delegate = self
        readStream.schedule(in: .main, forMode: .common); writeStream.schedule(in: .main, forMode: .common)
        readStream.open(); writeStream.open(); return true
    }

    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        if eventCode == .hasSpaceAvailable { flushOutput() }
        else if eventCode == .hasBytesAvailable, let input = input {
            var bytes = [UInt8](repeating: 0, count: 4096); let count = input.read(&bytes, maxLength: bytes.count)
            if count > 0 { buffer.append(contentsOf: bytes.prefix(count)); consumeLines() }
        } else if eventCode == .errorOccurred || eventCode == .endEncountered { closeStreams() }
    }
    private func flushOutput() {
        guard !outgoing.isEmpty, let output = output, output.hasSpaceAvailable else { return }
        let count = outgoing.count
        let written = outgoing.withUnsafeBytes { bytes in output.write(bytes.bindMemory(to: UInt8.self).baseAddress!, maxLength: count) }
        if written > 0 { outgoing.removeFirst(written) }
    }
    private func consumeLines() {
        while let newline = buffer.firstIndex(of: 10) {
            let line = buffer.prefix(upTo: newline); buffer.removeSubrange(...newline)
            if let raw = try? JSONSerialization.jsonObject(with: Data(line)), let object = raw as? [String: Any], object["type"] as? String == "cursorPosition", let event = try? JSONDecoder().decode(CompanionCursorEvent.self, from: Data(line)) {
                CompanionRuntime.lastEvent = event; CompanionRuntime.cursorState = .companion
                NotificationCenter.default.post(name: .companionCursorDidMove, object: event)
            } else if let response = try? JSONDecoder().decode(CompanionResponse.self, from: Data(line)) { let callback = pending; pending = nil; callback?(response) }
        }
    }
    private func closeStreams() { input?.close(); output?.close(); input = nil; output = nil; buffer.removeAll(); outgoing.removeAll(); pending = nil; CompanionRuntime.cursorState = .sdk; NotificationCenter.default.post(name: .companionCursorUnavailable, object: nil) }
}

extension Notification.Name {
    static let companionCursorDidMove = Notification.Name("CompanionCursorDidMove")
    static let companionCursorUnavailable = Notification.Name("CompanionCursorUnavailable")
}
