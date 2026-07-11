import ObjectiveC
import UIKit
import Security
import ParsecSDK
import AVFoundation

struct IdentifiableHostInfo {
    let id: String
    let hostname: String
    let user: UserInfo
    let connections: Int
}

struct IdentifiableUserInfo {
    let id: Int
    let username: String
}

enum APIError: LocalizedError {
    case invalidResponse, server(String), transport(Error)
    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "The server returned an invalid response."
        case .server(let message): return message
        case .transport(let error): return error.localizedDescription
        }
    }
}

enum AuthenticationResult { case authenticated(ClientInfo, Data), twoFactorRequired }

final class ParsecAPIClient {
    private let session: URLSession
    init(session: URLSession = .shared) { self.session = session }

    func authenticate(email: String, password: String, tfa: String = "", completion: @escaping (Result<AuthenticationResult, Error>) -> Void) {
        request(path: "/v1/auth", method: "POST", body: ["email": email, "password": password, "tfa": tfa], token: nil) { data, response, error in
            if let error = error { return completion(.failure(APIError.transport(error))) }
            guard let data = data, let response = response else { return completion(.failure(APIError.invalidResponse)) }
            if response.statusCode == 201, let info = try? JSONDecoder().decode(ClientInfo.self, from: data) {
                completion(.success(.authenticated(info, data)))
            } else if let object = try? JSONSerialization.jsonObject(with: data), let json = object as? [String: Any], json["tfa_required"] as? Bool == true {
                completion(.success(.twoFactorRequired))
            } else {
                completion(.failure(APIError.server(Self.errorMessage(data) ?? "Login failed (HTTP \(response.statusCode)).")))
            }
        }
    }

    func hosts(token: String, completion: @escaping (Result<[IdentifiableHostInfo], Error>) -> Void) {
        request(path: "/v2/hosts?mode=desktop&public=false", token: token) { data, response, error in
            self.decode(data, response, error, as: HostInfoList.self) { result in
                completion(result.map { ($0.data ?? []).map { IdentifiableHostInfo(id: $0.peer_id, hostname: $0.name, user: $0.user, connections: $0.players) } })
            }
        }
    }

    func currentUser(token: String, completion: @escaping (Result<IdentifiableUserInfo, Error>) -> Void) {
        request(path: "/me", token: token) { data, response, error in
            self.decode(data, response, error, as: SelfInfo.self) { result in
                completion(result.map { IdentifiableUserInfo(id: $0.data.id, username: $0.data.name) })
            }
        }
    }

    func friends(token: String, completion: @escaping (Result<[IdentifiableUserInfo], Error>) -> Void) {
        request(path: "/friendships", token: token) { data, response, error in
            self.decode(data, response, error, as: FriendInfoList.self) { result in
                completion(result.map { ($0.data ?? []).map { IdentifiableUserInfo(id: $0.user_id, username: $0.user_name) } })
            }
        }
    }

    private func request(path: String, method: String = "GET", body: [String: String]? = nil, token: String?, completion: @escaping (Data?, HTTPURLResponse?, Error?) -> Void) {
        var request = URLRequest(url: URL(string: "https://kessel-api.parsec.app\(path)")!)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("parsec/150-93b Windows/11 libmatoya/4.0", forHTTPHeaderField: "User-Agent")
        if let token = token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body = body { request.httpBody = try? JSONSerialization.data(withJSONObject: body) }
        session.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async { completion(data, response as? HTTPURLResponse, error) }
        }.resume()
    }

    private func decode<T: Decodable>(_ data: Data?, _ response: HTTPURLResponse?, _ error: Error?, as type: T.Type, completion: (Result<T, Error>) -> Void) {
        if let error = error { return completion(.failure(APIError.transport(error))) }
        guard let data = data, let response = response else { return completion(.failure(APIError.invalidResponse)) }
        guard (200..<300).contains(response.statusCode) else { return completion(.failure(APIError.server(Self.errorMessage(data) ?? "HTTP \(response.statusCode)"))) }
        do { completion(.success(try JSONDecoder().decode(type, from: data))) }
        catch { completion(.failure(APIError.invalidResponse)) }
    }

    private static func errorMessage(_ data: Data) -> String? { return (try? JSONDecoder().decode(ErrorInfo.self, from: data))?.error }
}

enum SessionPersistence: Equatable {
    case keychain, userDefaultsFallback
}

struct StoredSession {
    let info: ClientInfo
    let persistence: SessionPersistence
}

final class SessionStore {
    private let key = GLBDataModel.shared.SessionKeyChainKey
    private let fallbackKey = "OPStoredAuthDataFallback"
    private let warningKey = "OPSessionFallbackWarningShown"
    private let defaults = UserDefaults.standard

    func load() -> StoredSession? {
        if let info = loadFromKeychain() { return StoredSession(info: info, persistence: .keychain) }
        guard let data = defaults.data(forKey: fallbackKey), let info = try? JSONDecoder().decode(ClientInfo.self, from: data) else { return nil }
        if saveToKeychain(data) == errSecSuccess {
            defaults.removeObject(forKey: fallbackKey)
            return StoredSession(info: info, persistence: .keychain)
        }
        return StoredSession(info: info, persistence: .userDefaultsFallback)
    }

    private func loadFromKeychain() -> ClientInfo? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            if status != errSecItemNotFound { log(status, operation: "load") }
            return nil
        }
        return try? JSONDecoder().decode(ClientInfo.self, from: data)
    }

    @discardableResult
    func save(_ info: ClientInfo) -> SessionPersistence? {
        guard let data = try? JSONEncoder().encode(info) else { return nil }
        let status = saveToKeychain(data)
        if status == errSecSuccess {
            defaults.removeObject(forKey: fallbackKey)
            return .keychain
        }
        log(status, operation: "save")
        defaults.set(data, forKey: fallbackKey)
        return defaults.data(forKey: fallbackKey) == data ? .userDefaultsFallback : nil
    }

    private func saveToKeychain(_ data: Data) -> OSStatus {
        let query = baseQuery()
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            return SecItemAdd(insert as CFDictionary, nil)
        }
        return updateStatus
    }

    func clear() {
        SecItemDelete(baseQuery() as CFDictionary)
        defaults.removeObject(forKey: fallbackKey)
    }

    var shouldShowFallbackWarning: Bool { return !defaults.bool(forKey: warningKey) }
    func acknowledgeFallbackWarning() { defaults.set(true, forKey: warningKey) }

    private func log(_ status: OSStatus, operation: String) {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "Unknown Security error"
        print("Keychain \(operation) failed (\(status)): \(message)")
    }

    private func baseQuery() -> [String: Any] {
        return [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key]
    }
}

final class AppCoordinator {
    let window: UIWindow
    let api = ParsecAPIClient()
    let sessionStore = SessionStore()
    let companion = CompanionClient()
    private(set) var dashboard: DashboardViewController?
    private var fallbackWarningPending = false

    init(window: UIWindow) { self.window = window }
    func start() {
        if let session = sessionStore.load() {
            NetworkHandler.clinfo = session.info
            fallbackWarningPending = session.persistence == .userDefaultsFallback && sessionStore.shouldShowFallbackWarning
            showDashboard()
        } else { showLogin() }
        window.makeKeyAndVisible()
    }
    func showLogin() { window.rootViewController = LoginViewController(coordinator: self); dashboard = nil }
    func showDashboard() { let vc = DashboardViewController(coordinator: self); dashboard = vc; window.rootViewController = vc }
    func showStream() { window.rootViewController = StreamViewController(coordinator: self) }
    func logout() { CParsec.disconnectIfNeeded(); sessionStore.clear(); NetworkHandler.clinfo = nil; showLogin() }
    func notePersistence(_ persistence: SessionPersistence) { fallbackWarningPending = persistence == .userDefaultsFallback && sessionStore.shouldShowFallbackWarning }
    func showFallbackWarningIfNeeded(on controller: UIViewController) {
        guard fallbackWarningPending else { return }
        fallbackWarningPending = false
        sessionStore.acknowledgeFallbackWarning()
        let alert = UIAlertController(title: "Session Storage Warning", message: "This installation cannot access the iOS Keychain. Your login will be remembered using less-secure local app storage instead.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        controller.present(alert, animated: true)
    }
}

class BaseViewController: UIViewController {
    let accent = UIColor(named: "AccentColor") ?? UIColor(red: 0.63, green: 0.25, blue: 1, alpha: 1)
    override func viewDidLoad() { super.viewDidLoad(); view.backgroundColor = UIColor(named: "BackgroundGray") ?? .black }
    func alert(_ title: String, message: String? = nil) { let alert = UIAlertController(title: title, message: message, preferredStyle: .alert); alert.addAction(UIAlertAction(title: "OK", style: .default)); present(alert, animated: true) }
    func button(_ title: String, action: Selector) -> UIButton { let value = UIButton(type: .system); value.setTitle(title, for: .normal); value.setTitleColor(.white, for: .normal); value.backgroundColor = accent; value.layer.cornerRadius = 6; value.heightAnchor.constraint(equalToConstant: 48).isActive = true; value.addTarget(self, action: action, for: .touchUpInside); return value }
}

final class LoginViewController: BaseViewController {
    private unowned let coordinator: AppCoordinator
    private let email = UITextField(), password = UITextField(), spinner = UIActivityIndicatorView(style: .whiteLarge)
    init(coordinator: AppCoordinator) { self.coordinator = coordinator; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() {
        super.viewDidLoad()
        let icon = UIImageView(image: UIImage(named: "IconTransparent")), logo = UIImageView(image: UIImage(named: "LogoShadow"))
        [icon, logo].forEach { $0.contentMode = .scaleAspectFit }
        let brand = UIStackView(arrangedSubviews: [icon, logo]); brand.axis = .horizontal; brand.spacing = 4
        configure(email, placeholder: "Email", secure: false); email.keyboardType = .emailAddress; email.textContentType = .emailAddress
        configure(password, placeholder: "Password", secure: true); password.textContentType = .password
        let login = button("Login", action: #selector(handleLogin))
        let stack = UIStackView(arrangedSubviews: [brand, email, password, login]); stack.axis = NSLayoutConstraint.Axis.vertical; stack.spacing = 10; stack.translatesAutoresizingMaskIntoConstraints = false
        brand.heightAnchor.constraint(equalToConstant: 80).isActive = true
        view.addSubview(stack); view.addSubview(spinner); spinner.translatesAutoresizingMaskIntoConstraints = false
        let responsiveWidth = stack.widthAnchor.constraint(equalTo: view.safeAreaLayoutGuide.widthAnchor, constant: -32); responsiveWidth.priority = UILayoutPriority.defaultHigh; responsiveWidth.isActive = true
        NSLayoutConstraint.activate([stack.centerXAnchor.constraint(equalTo: view.centerXAnchor), stack.centerYAnchor.constraint(equalTo: view.centerYAnchor), stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16), stack.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16), stack.widthAnchor.constraint(lessThanOrEqualToConstant: 400), spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor), spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor)])
    }
    private func configure(_ field: UITextField, placeholder: String, secure: Bool) { field.placeholder = placeholder; field.isSecureTextEntry = secure; field.autocapitalizationType = .none; field.autocorrectionType = .no; field.textColor = .white; field.backgroundColor = UIColor(named: "BackgroundField"); field.layer.cornerRadius = 6; field.setLeftPadding(12); field.heightAnchor.constraint(equalToConstant: 50).isActive = true }
    @objc private func handleLogin() { authenticate(tfa: "") }
    private func authenticate(tfa: String) {
        setLoading(true)
        coordinator.api.authenticate(email: email.text ?? "", password: password.text ?? "", tfa: tfa) { [weak self] result in
            guard let self = self else { return }; self.setLoading(false)
            switch result {
            case .success(.authenticated(let info, _)):
                guard let persistence = self.coordinator.sessionStore.save(info) else { self.alert("Login Failed", message: "Unable to save the session on this device."); return }
                NetworkHandler.clinfo = info
                self.coordinator.notePersistence(persistence)
                self.coordinator.showDashboard()
            case .success(.twoFactorRequired): self.askForTFA()
            case .failure(let error): self.alert("Login Failed", message: error.localizedDescription)
            }
        }
    }
    private func askForTFA() { let prompt = UIAlertController(title: "Two-Factor Authentication", message: "Enter the code from your authenticator app.", preferredStyle: .alert); prompt.addTextField { $0.isSecureTextEntry = true; $0.keyboardType = .numberPad; $0.textContentType = .oneTimeCode }; prompt.addAction(UIAlertAction(title: "Cancel", style: .cancel)); prompt.addAction(UIAlertAction(title: "Enter", style: .default) { [weak self, weak prompt] _ in self?.authenticate(tfa: prompt?.textFields?.first?.text ?? "") }); present(prompt, animated: true) }
    private func setLoading(_ loading: Bool) { view.isUserInteractionEnabled = !loading; loading ? spinner.startAnimating() : spinner.stopAnimating() }
}

private final class AvatarLoader {
    static let shared = AvatarLoader()
    private let cache = NSCache<NSURL, UIImage>()
    func load(userID: Int, completion: @escaping (UIImage?) -> Void) {
        guard let url = URL(string: "https://parsecusercontent.com/cors-resize-image/w=64,h=64,fit=crop,background=white,q=90,f=jpeg/avatars/\(userID)/avatar") else { return completion(nil) }
        if let image = cache.object(forKey: url as NSURL) { return completion(image) }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            let image = data.flatMap(UIImage.init(data:)); if let image = image { self.cache.setObject(image, forKey: url as NSURL) }
            DispatchQueue.main.async { completion(image) }
        }.resume()
    }
}

private enum DashboardPage: Int { case hosts, friends }
final class DashboardViewController: BaseViewController, UITableViewDataSource, UITableViewDelegate {
    private unowned let coordinator: AppCoordinator
    private let table = UITableView(frame: .zero, style: .plain), selector = UISegmentedControl(items: ["Hosts", "Friends"]), spinner = UIActivityIndicatorView(style: .whiteLarge)
    private var hosts: [IdentifiableHostInfo] = [], friends: [IdentifiableUserInfo] = [], me: IdentifiableUserInfo?, page = DashboardPage.hosts
    private var pollTimer: Timer?, connectionPrompt: UIAlertController?
    init(coordinator: AppCoordinator) { self.coordinator = coordinator; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() {
        super.viewDidLoad()
        let logout = UIButton(type: .system); logout.setTitle("Logout", for: .normal); logout.addTarget(self, action: #selector(confirmLogout), for: .touchUpInside)
        let settings = UIButton(type: .system); settings.setTitle("Settings", for: .normal); settings.addTarget(self, action: #selector(showSettings), for: .touchUpInside)
        let refresh = UIButton(type: .system); refresh.setTitle("Refresh", for: .normal); refresh.addTarget(self, action: #selector(refreshAll), for: .touchUpInside)
        let pair = UIButton(type: .system); pair.setTitle("Pair Mac", for: .normal); pair.addTarget(self, action: #selector(pairCompanion), for: .touchUpInside)
        let bar = UIStackView(arrangedSubviews: [logout, refresh, pair, settings]); bar.distribution = .equalSpacing
        selector.selectedSegmentIndex = 0; selector.addTarget(self, action: #selector(changePage), for: .valueChanged)
        table.backgroundColor = .clear; table.separatorColor = UIColor(named: "Shading"); table.dataSource = self; table.delegate = self; table.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        let stack = UIStackView(arrangedSubviews: [bar, table, selector]); stack.axis = NSLayoutConstraint.Axis.vertical; stack.spacing = 8; stack.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(stack); view.addSubview(spinner); spinner.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8), stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12), stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12), stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8), bar.heightAnchor.constraint(equalToConstant: 44), selector.heightAnchor.constraint(equalToConstant: 40), spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor), spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor)])
        refreshAll()
        ParsecBackgroundManager.shared.onShouldReconnect = { [weak self] peer in if let host = self?.hosts.first(where: { $0.id == peer }) { self?.connect(host) } else { self?.refreshAll() } }
    }
    override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); coordinator.showFallbackWarningIfNeeded(on: self) }
    @objc private func changePage() { page = DashboardPage(rawValue: selector.selectedSegmentIndex) ?? .hosts; table.reloadData() }
    @objc private func refreshAll() {
        guard let token = NetworkHandler.clinfo?.session_id else { coordinator.showLogin(); return }
        spinner.startAnimating()
        let group = DispatchGroup(); var firstError: Error?
        group.enter(); coordinator.api.hosts(token: token) { [weak self] result in if case .success(let value) = result { self?.hosts = value } else if case .failure(let error) = result { firstError = error }; group.leave() }
        group.enter(); coordinator.api.currentUser(token: token) { [weak self] result in if case .success(let value) = result { self?.me = value } else if case .failure(let error) = result { firstError = error }; group.leave() }
        group.enter(); coordinator.api.friends(token: token) { [weak self] result in if case .success(let value) = result { self?.friends = value } else if case .failure(let error) = result { firstError = error }; group.leave() }
        group.notify(queue: .main) { [weak self] in self?.spinner.stopAnimating(); self?.table.reloadData(); if let error = firstError { self?.alert("Refresh Failed", message: error.localizedDescription) } }
    }
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { return page == .hosts ? hosts.count : friends.count + (me == nil ? 0 : 1) }
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        cell.backgroundColor = UIColor(named: "BackgroundCard"); cell.textLabel?.textColor = .white; cell.imageView?.image = UIImage(named: "IconTransparent")
        cell.accessoryType = page == .hosts ? .disclosureIndicator : .none
        let userID: Int
        if page == .hosts { let host = hosts[indexPath.row]; userID = host.user.id; cell.textLabel?.text = "\(host.hostname) - \(host.user.name)#\(host.user.id)" }
        else if indexPath.row == 0, let me = me { userID = me.id; cell.textLabel?.text = "You: \(me.username)#\(me.id)" }
        else { let offset = me == nil ? 0 : 1; let friend = friends[indexPath.row - offset]; userID = friend.id; cell.textLabel?.text = "\(friend.username)#\(friend.id)" }
        AvatarLoader.shared.load(userID: userID) { [weak tableView, weak cell] image in guard let tableView = tableView, let cell = cell, tableView.indexPath(for: cell) == indexPath else { return }; cell.imageView?.image = image ?? UIImage(named: "IconTransparent"); cell.setNeedsLayout() }
        return cell
    }
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) { tableView.deselectRow(at: indexPath, animated: true); if page == .hosts { connect(hosts[indexPath.row]) } }
    private func connect(_ host: IdentifiableHostInfo) {
        let screen = UIScreen.main
        ParsecResolution.updateClientResolution(width: Int(screen.nativeBounds.width), height: Int(screen.nativeBounds.height))
        if SettingsHandler.legacyIPadAutoTune {
            SettingsHandler.decoder = .h264
            SettingsHandler.preferredFramesPerSecond = 60
            SettingsHandler.decoderCompatibility = false
            if SettingsHandler.bitrate == 0 || SettingsHandler.bitrate > 15 { SettingsHandler.bitrate = 10 }
            if SettingsHandler.resolution == .client { SettingsHandler.resolution = .r1920x1200_16_10 }
        }
        coordinator.companion.prepareLegacyMode { [weak self] in self?.startParsecConnection(host) }
    }
    private func startParsecConnection(_ host: IdentifiableHostInfo) {
        CParsec.initialize(); var status = CParsec.connect(host.id); pollTimer?.invalidate()
        let prompt = UIAlertController(title: "Connecting to \(host.hostname)...", message: nil, preferredStyle: .alert)
        prompt.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in self?.pollTimer?.invalidate(); CParsec.disconnect(); self?.connectionPrompt = nil })
        connectionPrompt = prompt; present(prompt, animated: true)
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            status = CParsec.getStatus(); if status == PARSEC_CONNECTING { return }; timer.invalidate()
            self?.connectionPrompt?.dismiss(animated: true) { self?.connectionPrompt = nil; if status == PARSEC_OK { self?.coordinator.showStream() } else { CParsec.disconnect(); self?.alert("Connection Failed", message: "Parsec status \(status.rawValue)") } }
        }
    }
    @objc private func pairCompanion() {
        let name = coordinator.companion.discoveredName ?? "No Mac discovered yet"
        let prompt = UIAlertController(title: "Pair Mac Companion", message: "Discovered: \(name)\nEnter the six-digit code shown in the OpenParsec Host menu.", preferredStyle: .alert)
        prompt.addTextField { $0.keyboardType = .numberPad; $0.placeholder = "000000" }
        prompt.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        prompt.addAction(UIAlertAction(title: "Pair", style: .default) { [weak self, weak prompt] _ in
            self?.coordinator.companion.pair(code: prompt?.textFields?.first?.text ?? "") { result in
                switch result { case .success(let value): self?.alert("Companion Paired", message: value); case .failure(let error): self?.alert("Pairing Failed", message: error.localizedDescription) }
            }
        })
        present(prompt, animated: true)
    }
    @objc private func confirmLogout() { let prompt = UIAlertController(title: "Log out?", message: nil, preferredStyle: .alert); prompt.addAction(UIAlertAction(title: "Cancel", style: .cancel)); prompt.addAction(UIAlertAction(title: "Logout", style: .destructive) { [weak self] _ in self?.coordinator.logout() }); present(prompt, animated: true) }
    @objc private func showSettings() { present(UINavigationController(rootViewController: SettingsViewController()), animated: true) }
}

private enum SettingRow {
    case choice(String, () -> String, [(String, () -> Void)]), slider(String, () -> Double, (Double) -> Void), toggle(String, () -> Bool, (Bool) -> Void)
}

final class SettingsViewController: UITableViewController {
    private var sections: [(String, [SettingRow])] = []
    override func viewDidLoad() {
        super.viewDidLoad(); title = "Settings"; view.backgroundColor = UIColor(named: "BackgroundGray") ?? .black; tableView.backgroundColor = .clear; tableView.register(UITableViewCell.self, forCellReuseIdentifier: "setting")
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(done))
        sections = [
            ("Interactivity", [
                choice("Mouse Movement", current: { SettingsHandler.cursorMode == .touchpad ? "Touchpad" : "Direct" }, values: [("Touchpad", { SettingsHandler.cursorMode = .touchpad }), ("Direct", { SettingsHandler.cursorMode = .direct })]),
                .toggle("Mac Companion Cursor", { SettingsHandler.companionCursorEnabled }, { SettingsHandler.companionCursorEnabled = $0 }),
                choice("Right Click Position", current: { ["First Finger", "Middle", "Second Finger"][SettingsHandler.rightClickPosition.rawValue] }, values: [("First Finger", { SettingsHandler.rightClickPosition = .firstFinger }), ("Middle", { SettingsHandler.rightClickPosition = .middle }), ("Second Finger", { SettingsHandler.rightClickPosition = .secondFinger })]),
                .slider("Cursor Scale", { SettingsHandler.cursorScale }, { SettingsHandler.cursorScale = $0 }),
                .slider("Mouse Sensitivity", { SettingsHandler.mouseSensitivity }, { SettingsHandler.mouseSensitivity = $0 })
            ]),
            ("Graphics", [
                .toggle("Legacy iPad Auto 60", { SettingsHandler.legacyIPadAutoTune }, { SettingsHandler.legacyIPadAutoTune = $0 }),
                choice("Default Resolution", current: { SettingsHandler.resolution.desc }, values: ParsecResolution.resolutions.map { value in (value.desc, { SettingsHandler.resolution = value }) }),
                choice("Display Mode", current: { SettingsHandler.localDisplayMode.title }, values: LocalDisplayMode.allCases.map { value in (value.title, { SettingsHandler.localDisplayMode = value }) }),
                choice("Decoder", current: { SettingsHandler.decoder == .h264 ? "H.264" : "Prefer H.265" }, values: [("H.264", { SettingsHandler.decoder = .h264 }), ("Prefer H.265", { SettingsHandler.decoder = .h265 })]),
                choice("Frame Rate", current: { SettingsHandler.preferredFramesPerSecond == 0 ? "Auto" : "\(SettingsHandler.preferredFramesPerSecond) FPS" }, values: [("Auto", { SettingsHandler.preferredFramesPerSecond = 0 }), ("120 FPS", { SettingsHandler.preferredFramesPerSecond = 120 }), ("60 FPS", { SettingsHandler.preferredFramesPerSecond = 60 }), ("30 FPS", { SettingsHandler.preferredFramesPerSecond = 30 })]),
                .toggle("Decoder Compatibility", { SettingsHandler.decoderCompatibility }, { SettingsHandler.decoderCompatibility = $0 })
            ]),
            ("Misc", [
                .toggle("Never Show Overlay", { SettingsHandler.noOverlay }, { SettingsHandler.noOverlay = $0 }),
                .toggle("Hide Status Bar", { SettingsHandler.hideStatusBar }, { SettingsHandler.hideStatusBar = $0 }),
                .toggle("Show Keyboard Button", { SettingsHandler.showKeyboardButton }, { SettingsHandler.showKeyboardButton = $0 }),
                .toggle("Save Session Settings", { SettingsHandler.saveSessionSettings }, { SettingsHandler.saveSessionSettings = $0 })
            ])
        ]
    }
    private func choice(_ title: String, current: @escaping () -> String, values: [(String, () -> Void)]) -> SettingRow { return .choice(title, current, values) }
    @objc private func done() { dismiss(animated: true) }
    override func numberOfSections(in tableView: UITableView) -> Int { return sections.count + 1 }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { return section < sections.count ? sections[section].0 : nil }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { return section < sections.count ? sections[section].1.count : 1 }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "setting", for: indexPath); cell.backgroundColor = UIColor(named: "BackgroundCard"); cell.textLabel?.textColor = .white; cell.accessoryView = nil; cell.accessoryType = .none
        guard indexPath.section < sections.count else { cell.textLabel?.text = "Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown")"; cell.textLabel?.textAlignment = .center; return cell }
        let row = sections[indexPath.section].1[indexPath.row]
        switch row {
        case .choice(let title, let current, _): cell.textLabel?.text = "\(title): \(current())"; cell.accessoryType = .disclosureIndicator
        case .slider(let title, let current, let setter):
            cell.textLabel?.text = title; let slider = UISlider(frame: CGRect(x: 0, y: 0, width: 150, height: 30)); slider.minimumValue = 0.1; slider.maximumValue = 4; slider.value = Float(current()); slider.addActionHandler { setter(Double($0.value)) }; cell.accessoryView = slider
        case .toggle(let title, let current, let setter):
            cell.textLabel?.text = title; let control = UISwitch(); control.isOn = current(); control.addActionHandler { setter($0.isOn) }; cell.accessoryView = control
        }
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true); guard indexPath.section < sections.count else { return }
        guard case .choice(_, _, let choices) = sections[indexPath.section].1[indexPath.row] else { return }
        let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        choices.forEach { title, action in sheet.addAction(UIAlertAction(title: title, style: .default) { [weak self] _ in action(); self?.tableView.reloadRows(at: [indexPath], with: .none) }) }
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel)); if let popover = sheet.popoverPresentationController { popover.sourceView = tableView.cellForRow(at: indexPath); popover.sourceRect = tableView.cellForRow(at: indexPath)?.bounds ?? .zero }
        present(sheet, animated: true)
    }
}

private final class AdaptiveQualityController {
    private var warmup = 5, samples: [(decode: Float, encode: Float, network: Float, queued: UInt32)] = []
    private var lastPackets: UInt32 = 0, lastRetransmits: UInt32 = 0
    private var testedNative = false
    private let tiers: [ParsecResolution] = [.r1920x1200_16_10, .r1920x1080_16_9, .r1680x1050_16_10, .r1280x800_16_10, .r1280x720_16_9, .r1024x768_4_3]
    var stateText = "Auto 60: warming up"

    func reset() { warmup = 5; samples.removeAll(); lastPackets = 0; lastRetransmits = 0; testedNative = false; stateText = "Auto 60: warming up" }

    func sample(status: ParsecClientStatus, adjust: (ParsecResolution?, Int?) -> Void) {
        guard SettingsHandler.legacyIPadAutoTune else { stateText = "Auto 60: off"; return }
        if warmup > 0 { warmup -= 1; return }
        let metric = status.`self`.metrics.0
        samples.append((metric.decodeLatency, metric.encodeLatency, metric.networkLatency, metric.queuedFrames))
        guard samples.count >= 10 else { stateText = "Auto 60: measuring \(samples.count)/10"; return }
        let decode = samples.map { $0.decode }.sorted(), encode = samples.map { $0.encode }.sorted(), network = samples.map { $0.network }.sorted()
        let p95Index = min(9, Int(Double(samples.count - 1) * 0.95))
        let retransmits = metric.fastRTs &+ metric.slowRTs
        let packetDelta = metric.packetsSent &- lastPackets
        let retransmitDelta = retransmits &- lastRetransmits
        let lossRatio = packetDelta == 0 ? 0 : Float(retransmitDelta) / Float(packetDelta)
        lastPackets = metric.packetsSent; lastRetransmits = retransmits
        let decodeBad = status.decoder.0.index == 0 || decode[p95Index] >= 14 || (samples.map { $0.queued }.max() ?? 0) > 2
        let encodeBad = encode[p95Index] >= 14
        let jitter = network[p95Index] - network[network.count / 2]
        let networkBad = lossRatio > 0.005 || network[network.count / 2] >= 30 || jitter > 15 || status.networkFailure
        samples.removeAll(keepingCapacity: true); warmup = 5
        if networkBad && SettingsHandler.bitrate > 5 {
            let next = SettingsHandler.bitrate > 10 ? 10 : (SettingsHandler.bitrate > 7 ? 7 : 5)
            stateText = "Auto 60: network limited, trying \(next) Mbps"; adjust(nil, next); return
        }
        if decodeBad || encodeBad {
            let pixels = Int(status.decoder.0.width * status.decoder.0.height)
            if let next = tiers.first(where: { $0.width * $0.height < pixels }) {
                stateText = "Auto 60: overloaded, trying \(next.desc)"; adjust(next, nil); return
            }
            stateText = "Auto 60: minimum tier still overloaded"; return
        }
        if !testedNative && status.decoder.0.width <= 1920 && decode[p95Index] < 8 && encode[p95Index] < 8 && !networkBad {
            testedNative = true
            stateText = "Auto 60: testing iPad native resolution"; adjust(.client, nil); return
        }
        stateText = "Auto 60: stable"
    }
}

final class StreamViewController: BaseViewController {
    private unowned let coordinator: AppCoordinator
    private let renderer = ParsecViewController(), menu = UIStackView(), metrics = UILabel(), menuButton = UIButton(type: .system), keyboardButton = UIButton(type: .system)
    private var timer: Timer?, muted = false, zoomed = false
    private let adaptiveQuality = AdaptiveQualityController()
    init(coordinator: AppCoordinator) { self.coordinator = coordinator; super.init(nibName: nil, bundle: nil); if SettingsHandler.saveSessionSettings { muted = SettingsHandler.savedMuted; zoomed = SettingsHandler.savedZoomEnabled; DataManager.model.constantFps = SettingsHandler.savedConstantFps } }
    required init?(coder: NSCoder) { fatalError() }
    override var prefersStatusBarHidden: Bool { return SettingsHandler.hideStatusBar }
    override var childForHomeIndicatorAutoHidden: UIViewController? { return renderer }
    @available(iOS 14.0, *)
    override var childViewControllerForPointerLock: UIViewController? { return renderer }
    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation { return .landscapeRight }
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .black
        addChild(renderer); renderer.view.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(renderer.view); renderer.didMove(toParent: self)
        NSLayoutConstraint.activate([renderer.view.topAnchor.constraint(equalTo: view.topAnchor), renderer.view.bottomAnchor.constraint(equalTo: view.bottomAnchor), renderer.view.leadingAnchor.constraint(equalTo: view.leadingAnchor), renderer.view.trailingAnchor.constraint(equalTo: view.trailingAnchor)])
        menuButton.setImage(UIImage(named: "IconTransparent"), for: .normal); styleOverlayButton(menuButton); menuButton.addTarget(self, action: #selector(toggleMenu), for: .touchUpInside); menuButton.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(menuButton)
        keyboardButton.setTitle("Keyboard", for: .normal); keyboardButton.setTitleColor(.white, for: .normal); styleOverlayButton(keyboardButton); keyboardButton.addTarget(self, action: #selector(toggleKeyboard), for: .touchUpInside); keyboardButton.translatesAutoresizingMaskIntoConstraints = false; keyboardButton.isHidden = !SettingsHandler.showKeyboardButton; view.addSubview(keyboardButton)
        metrics.textColor = .white; metrics.font = .systemFont(ofSize: 11); metrics.numberOfLines = 0
        menu.axis = .vertical; menu.spacing = 4; menu.backgroundColor = (UIColor(named: "BackgroundPrompt") ?? .darkGray).withAlphaComponent(0.9); menu.layer.cornerRadius = 6; menu.translatesAutoresizingMaskIntoConstraints = false; menu.isHidden = true; view.addSubview(menu)
        menu.addArrangedSubview(metrics)
        [("Mute", #selector(toggleMute)), ("Stream Resolution", #selector(selectResolution)), ("Display Mode", #selector(selectDisplayMode)), ("Bitrate", #selector(selectBitrate)), ("Retest Auto 60", #selector(retestAutoQuality)), ("Host Display", #selector(selectDisplay)), ("Constant FPS", #selector(toggleConstantFPS)), ("Zoom", #selector(toggleZoom)), ("Disconnect", #selector(disconnect))].forEach { menu.addArrangedSubview(menuItem($0.0, $0.1)) }
        NSLayoutConstraint.activate([menuButton.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12), menuButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12), menuButton.widthAnchor.constraint(equalToConstant: 48), menuButton.heightAnchor.constraint(equalToConstant: 48), keyboardButton.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12), keyboardButton.topAnchor.constraint(equalTo: menuButton.bottomAnchor, constant: 8), menu.leadingAnchor.constraint(equalTo: menuButton.trailingAnchor, constant: 8), menu.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12), menu.widthAnchor.constraint(equalToConstant: 220)])
        updateDeviceNativeResolution(); CParsec.applyConfig(); CParsec.setMuted(muted); renderer.setDisplayMode(SettingsHandler.localDisplayMode); renderer.setZoomEnabled(zoomed); hideOverlayIfNeeded(); getHostData()
        renderer.onKeyboardVisibilityChanged = { [weak self] visible in self?.keyboardButton.isSelected = visible }
        ParsecBackgroundManager.shared.onShouldDisconnect = { NotificationCenter.default.post(name: .parsecBackgroundDisconnect, object: nil) }
        if #available(iOS 15.0, *) {
            PictureInPictureManager.shared.onPiPStopped = {
                if UIApplication.shared.applicationState != .active {
                    ParsecBackgroundManager.shared.markForReconnect()
                    NotificationCenter.default.post(name: .parsecBackgroundDisconnect, object: nil)
                }
            }
            PictureInPictureManager.shared.onPiPStartFailed = {
                if UIApplication.shared.applicationState != .active {
                    ParsecBackgroundManager.shared.markForReconnect()
                    NotificationCenter.default.post(name: .parsecBackgroundDisconnect, object: nil)
                }
            }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(backgroundDisconnect), name: .parsecBackgroundDisconnect, object: nil)
        DataManager.model.onChange = { [weak self] in guard let self = self else { return }; self.renderer.updateStreamSize(width: DataManager.model.decoderWidth, height: DataManager.model.decoderHeight); if !self.menu.isHidden { self.updateMetrics() } }
        timer = Timer.scheduledTimer(timeInterval: 1, target: self, selector: #selector(checkStatus), userInfo: nil, repeats: true)
    }
    deinit { timer?.invalidate(); NotificationCenter.default.removeObserver(self); DataManager.model.onChange = nil }
    private func menuItem(_ title: String, _ action: Selector) -> UIButton { let button = UIButton(type: .system); button.setTitle(title, for: .normal); button.contentHorizontalAlignment = .left; button.setTitleColor(title == "Disconnect" ? .red : .white, for: .normal); button.heightAnchor.constraint(equalToConstant: 34).isActive = true; button.addTarget(self, action: action, for: .touchUpInside); return button }
    private func styleOverlayButton(_ button: UIButton) { button.backgroundColor = (UIColor(named: "BackgroundPrompt") ?? .darkGray).withAlphaComponent(0.78); button.layer.cornerRadius = 8; button.clipsToBounds = true; button.adjustsImageWhenHighlighted = true }
    @objc private func toggleMenu() { menu.isHidden.toggle(); menuButton.backgroundColor = (UIColor(named: "BackgroundPrompt") ?? .darkGray).withAlphaComponent(menu.isHidden ? 0.65 : 0.95); if !menu.isHidden { getHostData(); updateMetrics() } }
    private func hideOverlayIfNeeded() { if SettingsHandler.noOverlay { menuButton.isHidden = true; keyboardButton.isHidden = true } }
    @objc private func toggleMute() { muted.toggle(); CParsec.setMuted(muted); if SettingsHandler.saveSessionSettings { SettingsHandler.savedMuted = muted } }
    @objc private func toggleZoom() { zoomed.toggle(); renderer.setZoomEnabled(zoomed); if SettingsHandler.saveSessionSettings { SettingsHandler.savedZoomEnabled = zoomed } }
    @objc private func toggleKeyboard() { renderer.setKeyboardVisible(!renderer.keyboardVisible) }
    @objc private func toggleConstantFPS() { DataManager.model.constantFps.toggle(); CParsec.updateHostVideoConfig(); if SettingsHandler.saveSessionSettings { SettingsHandler.savedConstantFps = DataManager.model.constantFps } }
    @objc private func selectResolution(_ sender: UIButton) { showChoices(title: "Stream Resolution", source: sender, choices: ParsecResolution.resolutions.map { value in (value.desc, { SettingsHandler.resolution = value; self.updateDeviceNativeResolution(); DataManager.model.resolutionX = value.width; DataManager.model.resolutionY = value.height; DataManager.model.resolutionFeedback = "Requesting \(value.desc)…"; if value != .host { self.coordinator.companion.setMode(width: value.width, height: value.height) { applied in if applied { DataManager.model.resolutionFeedback = "Companion applied \(value.desc)" } } }; CParsec.updateHostVideoConfig(); self.getHostData() }) }) }
    @objc private func selectDisplayMode(_ sender: UIButton) { showChoices(title: "Display Mode", source: sender, choices: LocalDisplayMode.allCases.map { value in (value.title, { self.renderer.setDisplayMode(value) }) }) }
    @objc private func selectBitrate(_ sender: UIButton) { showChoices(title: "Bitrate", source: sender, choices: ParsecResolution.bitrates.map { value in ("\(value) Mbps", { SettingsHandler.bitrate = value; DataManager.model.bitrate = value; CParsec.updateHostVideoConfig() }) }) }
    @objc private func retestAutoQuality() { adaptiveQuality.reset(); SettingsHandler.legacyIPadAutoTune = true; SettingsHandler.bitrate = 10; DataManager.model.bitrate = 10; coordinator.companion.setMode(width: 1920, height: 1200); CParsec.updateHostVideoConfig() }
    @objc private func selectDisplay(_ sender: UIButton) { var choices: [(String, () -> Void)] = [("Auto", { DataManager.model.output = "none"; CParsec.updateHostVideoConfig() })]; choices += DataManager.model.displayConfigs.map { display in ("\(display.name) \(display.adapterName)", { DataManager.model.output = display.id; CParsec.updateHostVideoConfig() }) }; showChoices(title: "Display", source: sender, choices: choices) }
    private func showChoices(title: String, source: UIView, choices: [(String, () -> Void)]) { let sheet = UIAlertController(title: title, message: nil, preferredStyle: .actionSheet); choices.forEach { name, action in sheet.addAction(UIAlertAction(title: name, style: .default) { _ in action() }) }; sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel)); if let popover = sheet.popoverPresentationController { popover.sourceView = source; popover.sourceRect = source.bounds }; present(sheet, animated: true) }
    private func getHostData() { let data = Data(); CParsec.sendUserData(type: .getVideoConfig, message: data); CParsec.sendUserData(type: .getAdapterInfo, message: data) }
    private func updateDeviceNativeResolution() { let screen = view.window?.screen ?? UIScreen.main; let bounds = view.bounds.isEmpty ? screen.bounds : view.bounds; ParsecResolution.updateClientResolution(width: Int(bounds.width * screen.nativeScale), height: Int(bounds.height * screen.nativeScale)) }
    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) { super.viewWillTransition(to: size, with: coordinator); coordinator.animate(alongsideTransition: nil) { [weak self] _ in guard let self = self else { return }; self.updateDeviceNativeResolution(); if SettingsHandler.resolution == .client { DataManager.model.resolutionX = SettingsHandler.resolution.width; DataManager.model.resolutionY = SettingsHandler.resolution.height; CParsec.updateHostVideoConfig(); self.getHostData() } } }
    private func updateMetrics(_ status: ParsecClientStatus? = nil) {
        var current = status ?? ParsecClientStatus(); if status == nil && CParsec.getStatusEx(&current) != PARSEC_OK { return }
        var decoder = current.decoder.0
        let decoderName = String.fromBuffer(&decoder.name.0, length: 16).trimmingCharacters(in: .controlCharacters)
        let metric = current.`self`.metrics.0
        let feedback = DataManager.model.resolutionFeedback.map { "\n\($0)" } ?? ""
        metrics.text = String(format: "Decode %.2f ms  Encode %.2f ms\nNetwork %.2f ms  %.2f Mbps\nQueue %u  Retransmit %u/%u\nActual %d x %d %@ %@\n%@%@", metric.decodeLatency, metric.encodeLatency, metric.networkLatency, metric.bitrate, metric.queuedFrames, metric.fastRTs, metric.slowRTs, decoder.width, decoder.height, decoder.h265 ? "H.265" : "H.264", decoderName, adaptiveQuality.stateText, feedback)
    }
    @objc private func checkStatus() {
        var status = ParsecClientStatus(); let value = CParsec.getStatusEx(&status)
        if value != PARSEC_OK { disconnectWithMessage("Disconnected (code \(value.rawValue))"); return }
        adaptiveQuality.sample(status: status) { resolution, bitrate in
            if let bitrate = bitrate { SettingsHandler.bitrate = bitrate; DataManager.model.bitrate = bitrate }
            if let resolution = resolution {
                SettingsHandler.resolution = resolution; DataManager.model.resolutionX = resolution.width; DataManager.model.resolutionY = resolution.height
                self.coordinator.companion.setMode(width: resolution.width, height: resolution.height) { applied in DataManager.model.resolutionFeedback = applied ? "Companion applied \(resolution.desc)" : "macOS requires a paired OpenParsec Host Companion" }
            }
            CParsec.updateHostVideoConfig()
        }
        if !menu.isHidden { updateMetrics(status) }
    }
    @objc private func backgroundDisconnect() { if #available(iOS 15, *), PictureInPictureManager.shared.isPiPActive { return }; ParsecBackgroundManager.shared.markForReconnect(); disconnectInternal() }
    @objc private func disconnect() { ParsecBackgroundManager.shared.disableAutoReconnect(); disconnectInternal() }
    private func disconnectWithMessage(_ text: String) { timer?.invalidate(); let prompt = UIAlertController(title: text, message: nil, preferredStyle: .alert); prompt.addAction(UIAlertAction(title: "Close", style: .default) { [weak self] _ in self?.disconnectInternal() }); present(prompt, animated: true) }
    private func disconnectInternal() { timer?.invalidate(); if #available(iOS 15, *) { PictureInPictureManager.shared.teardown() }; CParsec.disconnect(); renderer.glkView.cleanUp(); coordinator.showDashboard() }
}

extension UITextField { func setLeftPadding(_ value: CGFloat) { leftView = UIView(frame: CGRect(x: 0, y: 0, width: value, height: 1)); leftViewMode = .always } }
private var controlClosureKey: UInt8 = 0
private final class ControlClosure: NSObject { let block: () -> Void; init(_ block: @escaping () -> Void) { self.block = block }; @objc func invoke() { block() } }
extension UISlider { func addActionHandler(_ handler: @escaping (UISlider) -> Void) { let closure = ControlClosure { [weak self] in if let self = self { handler(self) } }; objc_setAssociatedObject(self, &controlClosureKey, closure, .OBJC_ASSOCIATION_RETAIN_NONATOMIC); addTarget(closure, action: #selector(ControlClosure.invoke), for: .valueChanged) } }
extension UISwitch { func addActionHandler(_ handler: @escaping (UISwitch) -> Void) { let closure = ControlClosure { [weak self] in if let self = self { handler(self) } }; objc_setAssociatedObject(self, &controlClosureKey, closure, .OBJC_ASSOCIATION_RETAIN_NONATOMIC); addTarget(closure, action: #selector(ControlClosure.invoke), for: .valueChanged) } }
extension Notification.Name { static let parsecBackgroundDisconnect = Notification.Name("ParsecBackgroundDisconnect") }
