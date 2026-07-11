import Foundation

enum CompanionRuntime { static var cursorCaptured = false }

struct CompanionMode: Codable {
    let width: Int
    let height: Int
    let refresh: Int
}

private struct CompanionResponse: Codable {
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
    private(set) var discoveredName: String?
    private let tokenKey = "OpenParsecCompanionToken"
    private var token: String? { get { UserDefaults.standard.string(forKey: tokenKey) } set { UserDefaults.standard.set(newValue, forKey: tokenKey) } }
    var isPaired: Bool { return token != nil }

    override init() { super.init(); browser.delegate = self; browser.searchForServices(ofType: "_openparsec._tcp.", inDomain: "local.") }

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
        CompanionRuntime.cursorCaptured = false
        guard isPaired else { completion(); return }
        command(type: "setMode", extra: ["width": 1920, "height": 1200]) { [weak self] response in
            if response.ok { self?.setCursorEnabled(SettingsHandler.companionCursorEnabled) }; completion()
        }
    }

    func setMode(width: Int, height: Int, completion: ((Bool) -> Void)? = nil) { command(type: "setMode", extra: ["width": width, "height": height]) { completion?($0.ok) } }
    func setCursorEnabled(_ enabled: Bool) { command(type: "cursor", extra: ["enabled": enabled]) { response in CompanionRuntime.cursorCaptured = response.ok && enabled } }

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
            if let response = try? JSONDecoder().decode(CompanionResponse.self, from: line) { let callback = pending; pending = nil; callback?(response) }
        }
    }
    private func closeStreams() { input?.close(); output?.close(); input = nil; output = nil; buffer.removeAll(); outgoing.removeAll(); pending = nil }
}
