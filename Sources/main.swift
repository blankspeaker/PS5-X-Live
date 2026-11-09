import Cocoa
import Security
import ServiceManagement

// MARK: - Settings

enum Store {
    static let service = (Bundle.main.bundleIdentifier ?? "app.ps5xlive") + ".streamkey"
    static let account = "x-stream-key"
    static var defaults: UserDefaults {
        if let suite = ProcessInfo.processInfo.environment["PS5XL_DEFAULTS_SUITE"] {
            return UserDefaults(suiteName: suite) ?? .standard
        }
        return .standard
    }
    static var keyService: String {
        ProcessInfo.processInfo.environment["PS5XL_DEFAULTS_SUITE"].map { service + "." + $0 } ?? service
    }

    static var mode: String {
        get { defaults.string(forKey: "mode") ?? "lan" }  // LAN is the recommended default (Twitch Relay is opt-in)
        set { defaults.set(newValue, forKey: "mode") }
    }
    static var lanMode: Bool { mode == "lan" }

    // "Also send to Twitch" simulcast (LAN mode only). Off by default for new installs.
    static var simulcast: Bool {
        get { defaults.bool(forKey: "simulcastTwitch") }
        set { defaults.set(newValue, forKey: "simulcastTwitch") }
    }

    static var channel: String {
        get { defaults.string(forKey: "twitchChannel") ?? "" }
        set { defaults.set(newValue, forKey: "twitchChannel") }
    }
    static var server: String {
        get { defaults.string(forKey: "serverURL") ?? "" }
        set { defaults.set(newValue, forKey: "serverURL") }
    }

    static var xUser: String {
        get { defaults.string(forKey: "xUsername") ?? "" }
        set { defaults.set(newValue, forKey: "xUsername") }
    }

    /// Left on by Start Relay and cleared by Stop Relay. Survives quit and reboot.
    static var relayWanted: Bool {
        get { defaults.bool(forKey: "relayWanted") }
        set { defaults.set(newValue, forKey: "relayWanted") }
    }
    static var autoLive: Bool {
        get { defaults.object(forKey: "autoLive") == nil ? true : defaults.bool(forKey: "autoLive") }
        set { defaults.set(newValue, forKey: "autoLive") }
    }
    static var announce: Bool {
        get { defaults.object(forKey: "announcePost") == nil ? true : defaults.bool(forKey: "announcePost") }
        set { defaults.set(newValue, forKey: "announcePost") }
    }
    static var liveTitle: String {
        get { defaults.string(forKey: "liveTitle") ?? "" }
        set { defaults.set(newValue, forKey: "liveTitle") }
    }
    static var xClientID: String {
        get { defaults.string(forKey: "xClientID") ?? "" }
        set { defaults.set(newValue, forKey: "xClientID") }
    }
    static var xSourceId: String {
        get { defaults.string(forKey: "xSourceId") ?? "" }
        set { defaults.set(newValue, forKey: "xSourceId") }
    }
    static var xSourceKeyTag: String {
        get { defaults.string(forKey: "xSourceKeyTag") ?? "" }
        set { defaults.set(newValue, forKey: "xSourceKeyTag") }
    }
    static var shareURL: String {
        get { defaults.string(forKey: "xShareURL") ?? "" }
        set { defaults.set(newValue, forKey: "xShareURL") }
    }
    static var tokenExpiry: Double {
        get { defaults.double(forKey: "xTokenExpiry") }
        set { defaults.set(newValue, forKey: "xTokenExpiry") }
    }
    static var xClientSecret: String {
        get { secret("x-client-secret") }
        set { setSecret("x-client-secret", newValue, label: "PS5 X Live X client secret") }
    }

    static var key: String {
        get { secret(account) }
        set { setSecret(account, newValue, label: "PS5 X Live stream key") }
    }

    static func secret(_ account: String) -> String {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: keyService,
                                kSecAttrAccount as String: account,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let d = out as? Data else { return "" }
        return String(data: d, encoding: .utf8) ?? ""
    }

    static func setSecret(_ account: String, _ value: String, label: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: keyService,
                                   kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrLabel as String] = label
        SecItemAdd(add as CFDictionary, nil)
    }

    // LAN mode receives the PS5's own broadcast, so it needs no Twitch channel.
    static var complete: Bool { !server.isEmpty && !key.isEmpty && (lanMode || !channel.isEmpty) }
}

// MARK: - Relay script

let scriptPath = Bundle.main.path(forResource: "ps5xlive-relay", ofType: "sh") ?? ""
let logPath = NSHomeDirectory() + "/Library/Logs/PS5-X-Live.log"
enum Links {
    static let repo = "https://github.com/blankspeaker/PS5-X-Live"
    static let readme = repo + "#readme"
    static let issues = repo + "/issues"
    static let homebrew = "https://brew.sh"
    static let streamlink = "https://streamlink.github.io"
    static let ffmpeg = "https://ffmpeg.org"
    static let twitchSignup = "https://www.twitch.tv/signup"
    static let twitchActivate = "https://www.twitch.tv/activate"
    static let ps5Broadcast = "https://www.playstation.com/en-us/support/games/ps5-stream-gameplay-broadcast/"
    static let liveStudio = "https://x.com/i/live-studio"
    static let sources = "https://x.com/i/live-studio/sources"
    static let console = "https://console.x.com"
    static let notices = repo + "/blob/main/THIRD_PARTY_NOTICES.md"
    static let loginItems = "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
    static var xProfile: String? { Store.xUser.isEmpty ? nil : "https://x.com/" + Store.xUser }
    static var twitchChannel: String? { Store.channel.isEmpty ? nil : Store.channel }
}

func openURL(_ s: String?) { if let s, let u = URL(string: s) { NSWorkspace.shared.open(u) } }
let brewCommand = "brew install streamlink ffmpeg"
func copyBrewCommand() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(brewCommand, forType: .string)
}

@discardableResult
func relay(_ args: [String], env extra: [String: String] = [:]) -> (Int32, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/bash")
    p.arguments = [scriptPath] + args
    var env = ProcessInfo.processInfo.environment
    env.merge(extra) { $1 }
    p.environment = env
    let out = Pipe()
    p.standardOutput = out
    p.standardError = out
    do { try p.run() } catch { return (1, "") }
    p.waitUntilExit()
    let s = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return (p.terminationStatus, s.trimmingCharacters(in: .whitespacesAndNewlines))
}

func lanIP() -> String {
    let ip = relay(["lanip"]).1.trimmingCharacters(in: .whitespacesAndNewlines)
    return ip.isEmpty ? "unavailable" : ip
}

func normalizeChannel(_ s: String) -> String? {
    let (code, out) = relay(["normalize", s])
    return code == 0 && !out.isEmpty ? out : nil
}

struct Tool { let name: String; let ok: Bool; let version: String; let bundled: Bool }

/// Asks the relay script which ffmpeg / streamlink it will use (bundled first, Homebrew fallback).
func checkComponents() -> [Tool] {
    let out = relay(["selfcheck"]).1
    return [("ffmpeg", "FFmpeg"), ("streamlink", "Streamlink")].map { key, title in
        let f = out.split(separator: "\n").map { $0.split(separator: " ").map(String.init) }.first { $0.first == key } ?? []
        let ok = f.count >= 3 && f[1] == "ok"
        return Tool(name: title, ok: ok, version: ok ? f[2] : "", bundled: f.count >= 4 && f[3] == "bundled")
    }
}

func missingTools() -> [String] { checkComponents().filter { !$0.ok }.map(\.name) }

// MARK: - Settings window

/// Menu-bar apps are not key by default, so text fields ignore typing and Command-V.
final class KeyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class SettingsWindow: NSWindowController, NSWindowDelegate {
    let channel = NSTextField()
    let server = NSTextField()
    let key = NSSecureTextField()
    let xUser = NSTextField()
    let liveTitle = NSTextField()
    let clientID = NSTextField()
    let clientSecret = NSSecureTextField()
    let xAuthStatus = NSTextField(labelWithString: "Not signed in")
    var onSave: (() -> Void)?
    var onAccount: (() -> Void)?
    private var signingIn = false

    convenience init() {
        let w = KeyWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "PS5 X Live"
        self.init(window: w)
        w.delegate = self
        channel.placeholderString = "channel or twitch.tv URL"
        server.placeholderString = "rtmps://"
        key.placeholderString = "Stream key"
        xUser.placeholderString = "Filled in when you sign in"
        liveTitle.placeholderString = "Used only if the PS5 title can't be read"
        clientID.placeholderString = "From your X app"
        clientSecret.placeholderString = "Blank for a public client"
        for f in [channel, server, key, xUser, liveTitle, clientID, clientSecret] as [NSTextField] {
            f.widthAnchor.constraint(equalToConstant: 320).isActive = true
            f.isEditable = true
            f.isSelectable = true
            f.refusesFirstResponder = false
        }
        let pasteID = NSButton(title: "Paste", target: self, action: #selector(pasteClientID))
        let pasteSecret = NSButton(title: "Paste", target: self, action: #selector(pasteClientSecret))
        for b in [pasteID, pasteSecret] { b.bezelStyle = .rounded; b.controlSize = .small }
        let idRow = NSStackView(views: [clientID, pasteID])
        let secretRow = NSStackView(views: [clientSecret, pasteSecret])
        idRow.spacing = 8
        secretRow.spacing = 8

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Twitch channel"), channel],
            [NSTextField(labelWithString: "Server URL"), server],
            [NSTextField(labelWithString: "Stream key"), key],
            [NSTextField(labelWithString: "X username"), xUser],
            [NSTextField(labelWithString: "Fallback title"), liveTitle],
            [NSTextField(labelWithString: "X Client ID"), idRow],
            [NSTextField(labelWithString: "X Client Secret"), secretRow],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 10
        grid.columnSpacing = 10
        grid.setContentHuggingPriority(.required, for: .vertical)
        grid.setContentCompressionResistancePriority(.required, for: .vertical)

        let hint = NSTextField(wrappingLabelWithString: "OAuth 2.0, not the API Key. In User authentication settings: permissions Read and write, callback exactly \(XLive.redirect), scopes \(XLive.scopes). A mismatch is the “weren’t able to give access” page.")
        hint.preferredMaxLayoutWidth = 460
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hint.setContentHuggingPriority(.required, for: .vertical)

        let signIn = NSButton(title: "Sign in to X", target: self, action: #selector(signIn))
        let signOut = NSButton(title: "Sign out", target: self, action: #selector(signOut))
        let copyCallback = NSButton(title: "Copy callback URL", target: self, action: #selector(copyCallback))
        let accountButtons = NSStackView(views: [signIn, signOut, copyCallback, xAuthStatus])
        accountButtons.spacing = 8
        accountButtons.alignment = .centerY

        let save = NSButton(title: "Save", target: self, action: #selector(save))
        save.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        let buttonGap = NSView()
        buttonGap.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [buttonGap, cancel, save])
        buttons.spacing = 8

        let stack = NSStackView(views: [grid, hint, accountButtons, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.distribution = .fill
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.setHuggingPriority(.required, for: .horizontal)
        stack.setHuggingPriority(.required, for: .vertical)
        for row in [hint, accountButtons, buttons] {
            row.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true
        }
        w.contentView = stack
        w.setContentSize(stack.fittingSize)
        w.center()
    }

    func present() {
        channel.stringValue = Store.channel
        server.stringValue = Store.server
        key.stringValue = Store.key
        xUser.stringValue = Store.xUser
        liveTitle.stringValue = Store.liveTitle
        clientID.stringValue = Store.xClientID
        clientSecret.stringValue = Store.xClientSecret
        xAuthStatus.stringValue = XLive.signedIn
            ? (Store.xUser.isEmpty ? "Signed in" : "Signed in as @\(Store.xUser)")
            : "Not signed in"
        // Accessory apps ignore Command-V until they become a normal foreground app.
        if let stack = window?.contentView as? NSStackView {
            window?.setContentSize(stack.fittingSize)
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(clientID)
    }

    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async {
            if !NSApp.windows.contains(where: { $0.isVisible }) {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    @objc func pasteClientID() { pasteClipboard(into: clientID, name: "Client ID") }
    @objc func pasteClientSecret() { pasteClipboard(into: clientSecret, name: "Client Secret") }

    func pasteClipboard(into field: NSTextField, name: String) {
        let text = (NSPasteboard.general.string(forType: .string) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            xAuthStatus.stringValue = "Clipboard is empty. Copy the \(name) first."
            NSSound.beep()
            return
        }
        field.stringValue = text
        window?.makeFirstResponder(field)
        xAuthStatus.stringValue = "Pasted \(name) (\(text.count) characters)"
    }

    func fail(_ msg: String, _ field: NSTextField) {
        NSSound.beep()
        let a = NSAlert(); a.messageText = msg
        a.beginSheetModal(for: window!) { _ in self.window?.makeFirstResponder(field) }
    }

    @objc func save() {
        guard let ch = normalizeChannel(channel.stringValue) else { return fail("Invalid Twitch channel", channel) }
        var srv = server.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        while srv.hasSuffix("/") { srv.removeLast() }
        guard srv.hasPrefix("rtmps://") || srv.hasPrefix("rtmp://") else { return fail("Invalid server URL", server) }
        let k = key.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { return fail("Stream key required", key) }
        Store.channel = ch
        Store.server = srv
        Store.key = k
        var u = xUser.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = u.range(of: "x.com/") ?? u.range(of: "twitter.com/") { u = String(u[r.upperBound...]) }
        u = String(u.drop(while: { $0 == "@" }).prefix(while: { $0.isLetter || $0.isNumber || $0 == "_" }))
        Store.xUser = u
        Store.liveTitle = liveTitle.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        Store.xClientID = clientID.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        Store.xClientSecret = clientSecret.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        window?.close()
        onSave?()
        onSave = nil
    }

    @objc func cancel() { onSave = nil; window?.close() }

    @objc func copyCallback() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(XLive.redirect, forType: .string)
    }

    @objc func signIn() {
        guard !signingIn else { return }
        let id = clientID.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard id.count >= 15 else {
            return fail("Client ID looks incomplete (\(id.count) characters). Paste the full OAuth 2.0 Client ID.", clientID)
        }
        signingIn = true
        Store.xClientID = id
        Store.xClientSecret = clientSecret.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        xAuthStatus.stringValue = "Waiting for X in your browser…"
        DispatchQueue.global().async {
            let msg = XLive.signIn()
            DispatchQueue.main.async {
                self.signingIn = false
                self.xAuthStatus.stringValue = msg
                if XLive.signedIn { self.xUser.stringValue = Store.xUser }
                else if msg.hasPrefix("X refused") {
                    let a = NSAlert()
                    a.messageText = "X refused access"
                    a.informativeText = msg
                    a.runModal()
                }
                self.onAccount?()
            }
        }
    }

    @objc func signOut() {
        XLive.signOut()
        xAuthStatus.stringValue = "Signed out"
        onAccount?()
    }
}

// MARK: - Setup guide

final class GuideWindow: NSWindowController {
    var actions: [() -> Void] = []
    var dynamic: [(NSButton, () -> String?)] = []
    var openSettings: () -> Void = {}
    let componentsRow = NSStackView()
    lazy var fallbackButtons: [NSButton] = [
        link("Homebrew") { Links.homebrew }, button("Copy brew command") { copyBrewCommand() },
        link("FFmpeg") { Links.ffmpeg }, link("Streamlink") { Links.streamlink }]

    func refreshComponents() {
        componentsRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        componentsRow.spacing = 12
        let spinner = NSProgressIndicator(); spinner.style = .spinning; spinner.controlSize = .small
        spinner.startAnimation(nil); componentsRow.addArrangedSubview(spinner)
        DispatchQueue.global().async {
            let tools = checkComponents()
            DispatchQueue.main.async {
                self.componentsRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
                for t in tools {
                    let img = NSImageView(image: NSImage(systemSymbolName: t.ok ? "checkmark.circle.fill" : "xmark.circle.fill",
                                                         accessibilityDescription: nil)!)
                    img.contentTintColor = t.ok ? .systemGreen : .systemRed
                    let label = NSTextField(labelWithString: t.ok ? "\(t.name) \(t.version)" + (t.bundled ? "" : " (Homebrew)") : t.name)
                    let pair = NSStackView(views: [img, label]); pair.spacing = 4
                    self.componentsRow.addArrangedSubview(pair)
                }
                if tools.contains(where: { !$0.ok }) {
                    self.fallbackButtons.forEach { self.componentsRow.addArrangedSubview($0) }
                }
            }
        }
    }
    var startRelay: () -> Void = {}

    convenience init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "PS5 X Live Setup"
        self.init(window: w)
    }

    func button(_ title: String, _ action: @escaping () -> Void) -> NSButton {
        let b = NSButton(title: title, target: self, action: #selector(tap(_:)))
        b.bezelStyle = .rounded
        b.tag = actions.count
        actions.append(action)
        return b
    }

    func link(_ title: String, _ url: @escaping () -> String?) -> NSButton {
        let b = button(title) { openURL(url()) }
        dynamic.append((b, url))
        return b
    }

    @objc func tap(_ b: NSButton) { actions[b.tag]() }

    func rebuild() { actions = []; dynamic = []; build() }

    func macIPLabel() -> NSView {
        let l = NSTextField(labelWithString: "Mac IP: …")
        DispatchQueue.global().async { let ip = lanIP(); DispatchQueue.main.async { l.stringValue = "Mac IP: \(ip)" } }
        return l
    }

    func macIPButton() -> NSButton {
        let b = button("Copy Mac IP") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(lanIP(), forType: .string) }
        return b
    }

    func build() {
        let steps: [(String, [NSView])]
        if Store.lanMode {
            steps = [
                ("1. Components", [componentsRow]),
                ("2. Create a source in X Live Studio", [
                    link("X Live Studio") { Links.liveStudio }, link("Manage Sources") { Links.sources }]),
                ("3. Paste the RTMP URL and stream key", [
                    button("Settings…") { [weak self] in self?.openSettings() }]),
                ("4. On the PS5, set Primary DNS to this Mac", [macIPLabel(), macIPButton()]),
                ("    Settings → Network → Settings → Set Up Internet Connection →", []),
                ("    your network → Advanced → DNS Settings → Manual", []),
                ("    Primary DNS = the Mac IP above, Secondary DNS = 0.0.0.0", []),
                ("5. Start LAN mode, then broadcast to Twitch on the PS5", [
                    button("Start Relay") { [weak self] in self?.startRelay() }]),
                ("    Optional: turn on \"Also send to Twitch\" in the menu to simulcast to your own Twitch channel", []),
                ("6. Sign in with the OAuth 2.0 Client ID, not the API Key", [
                    link("Developer Console") { Links.console },
                    button("Settings…") { [weak self] in self?.openSettings() },
                    link("Your X Profile") { Links.xProfile }]),
                ("    Permissions: Read and write. Callback exactly http://127.0.0.1:17351/callback.", []),
                ("    Paste the Client ID and Client Secret, then Sign in to X. A running broadcast is rejoined.", []),
                ("    Open at Login and Start Relay stay on across reboots until you choose Stop Relay.", []),
                ("When done: on the PS5 set DNS Settings back to Automatic", []),
                ("Help", [
                    link("README") { Links.readme }, link("Report an Issue") { Links.issues },
                    link("Login Items") { Links.loginItems }]),
            ]
        } else {
            steps = [
                ("⚠ Twitch Relay restreams Twitch — use at your own risk (may violate Twitch's Terms of Service)", []),
                ("1. Components", [componentsRow]),
                ("2. Broadcast from the PS5 to Twitch", [
                    link("Twitch Sign Up") { Links.twitchSignup }, link("Twitch Activate") { Links.twitchActivate },
                    link("PS5 Broadcast Help") { Links.ps5Broadcast }]),
                ("3. Create a source in X Live Studio", [
                    link("X Live Studio") { Links.liveStudio }, link("Manage Sources") { Links.sources }]),
                ("4. Paste the RTMP URL and stream key", [
                    button("Settings…") { [weak self] in self?.openSettings() }]),
                ("5. Start the relay", [
                    button("Start Relay") { [weak self] in self?.startRelay() },
                    link("Your Twitch Channel") { Links.twitchChannel }]),
                ("6. Sign in with the OAuth 2.0 Client ID, not the API Key", [
                    link("Developer Console") { Links.console },
                    button("Settings…") { [weak self] in self?.openSettings() },
                    link("Your X Profile") { Links.xProfile }]),
                ("    Permissions: Read and write. Callback exactly http://127.0.0.1:17351/callback.", []),
                ("    Paste the Client ID and Client Secret, then Sign in to X. A running broadcast is rejoined.", []),
                ("    Open at Login and Start Relay stay on across reboots until you choose Stop Relay.", []),
                ("Help", [
                    link("README") { Links.readme }, link("Report an Issue") { Links.issues },
                    link("Login Items") { Links.loginItems }]),
            ]
        }
        let rows: [NSView] = steps.map { title, buttons -> NSView in
            let indent = title.hasPrefix("    ")
            let label = NSTextField(labelWithString: title)
            label.font = indent ? .systemFont(ofSize: NSFont.smallSystemFontSize)
                                 : .boldSystemFont(ofSize: NSFont.systemFontSize)
            if indent { label.textColor = .secondaryLabelColor }
            if buttons.isEmpty { return label }
            let row = NSStackView(views: buttons)
            row.spacing = 8
            let v = NSStackView(views: [label, row])
            v.orientation = .vertical
            v.alignment = .leading
            v.spacing = 6
            return v
        }
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        window?.contentView = stack
    }

    func present() {
        rebuild()
        for (b, url) in dynamic { b.isEnabled = url() != nil }
        refreshComponents()
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - About / Licenses

final class AboutWindow: NSWindowController {
    var actions: [() -> Void] = []
    convenience init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 180),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "About PS5 X Live"
        self.init(window: w)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.widthAnchor.constraint(equalToConstant: 64).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 64).isActive = true
        let title = NSTextField(labelWithString: "PS5 X Live \(version)")
        title.font = .boldSystemFont(ofSize: 15)
        let res = Bundle.main.resourcePath ?? ""
        let buttons = NSStackView(views: [
            button("Third-Party Notices") {
                let f = URL(fileURLWithPath: res + "/THIRD_PARTY_NOTICES.md")
                let te = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
                NSWorkspace.shared.open([f], withApplicationAt: te, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
            },
            button("License Files") { NSWorkspace.shared.open(URL(fileURLWithPath: res + "/ThirdPartyLicenses")) },
            button("Source Code") { openURL(Links.repo) },
        ])
        let views: [NSView] = [icon, title, NSTextField(labelWithString: "MIT License"), buttons]
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        w.contentView = stack
    }
    func button(_ t: String, _ a: @escaping () -> Void) -> NSButton {
        let b = NSButton(title: t, target: self, action: #selector(tap(_:))); b.tag = actions.count; actions.append(a); return b
    }
    @objc func tap(_ b: NSButton) { actions[b.tag]() }
    func present() {
        window?.center(); NSApp.activate(ignoringOtherApps: true); window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Menu bar app

final class App: NSObject, NSApplicationDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let statusLine = NSMenuItem(title: "Idle", action: nil, keyEquivalent: "")
    let lanLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let twitchWarn = NSMenuItem(title: "⚠ Twitch Relay: use at your own risk (may violate Twitch ToS)", action: nil, keyEquivalent: "")
    let twitchLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let xLine = NSMenuItem(title: "X: idle", action: nil, keyEquivalent: "")
    lazy var broadcastItem = NSMenuItem(title: "Open Current Broadcast", action: #selector(openBroadcast), keyEquivalent: "")
    lazy var alsoTwitch = NSMenuItem(title: "Also send to Twitch", action: #selector(toggleSimulcast), keyEquivalent: "")
    lazy var autoLiveItem = NSMenuItem(title: "Auto go live on X", action: #selector(toggleAutoLive), keyEquivalent: "")
    lazy var announceItem = NSMenuItem(title: "Post when going live", action: #selector(toggleAnnounce), keyEquivalent: "")
    lazy var loginItem = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
    lazy var modeTwitch = NSMenuItem(title: "Mode: Twitch Relay", action: #selector(setTwitch), keyEquivalent: "")
    lazy var modeLan = NSMenuItem(title: "Mode: Direct from PS5 (LAN) — recommended", action: #selector(setLan), keyEquivalent: "")
    lazy var copyIP = NSMenuItem(title: "Copy Mac IP for PS5", action: #selector(copyLanIP), keyEquivalent: "")
    var cachedIP = ""
    lazy var startItem = NSMenuItem(title: "Start Relay", action: #selector(start), keyEquivalent: "")
    lazy var stopItem = NSMenuItem(title: "Stop Relay", action: #selector(stop), keyEquivalent: "")
    let settings = SettingsWindow()
    let guide = GuideWindow()
    lazy var about = AboutWindow()
    var state = ""
    var awaySince: Date?
    var goLiveOk = false
    var goLiveBusy = false
    var goLiveQuietUntil = Date.distantPast

    func applicationDidFinishLaunching(_ n: Notification) {
        installEditMenu()
        let m = NSMenu()
        m.autoenablesItems = false
        statusLine.isEnabled = false
        m.addItem(statusLine)
        lanLine.isEnabled = false
        m.addItem(lanLine)
        twitchLine.isEnabled = false
        m.addItem(twitchLine)
        xLine.isEnabled = false
        m.addItem(xLine)
        twitchWarn.isEnabled = false
        m.addItem(twitchWarn)
        m.addItem(.separator())
        m.addItem(startItem)
        m.addItem(stopItem)
        m.addItem(.separator())
        modeTwitch.target = self; modeLan.target = self
        m.addItem(modeLan)      // LAN presented first (recommended)
        m.addItem(modeTwitch)
        copyIP.target = self
        m.addItem(copyIP)
        alsoTwitch.target = self
        m.addItem(alsoTwitch)
        m.addItem(autoLiveItem)
        m.addItem(announceItem)
        m.addItem(loginItem)
        m.addItem(.separator())
        m.addItem(NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ","))
        m.addItem(NSMenuItem(title: "Setup Guide…", action: #selector(openGuide), keyEquivalent: ""))
        m.addItem(NSMenuItem(title: "Open Log", action: #selector(openLog), keyEquivalent: ""))
        m.addItem(NSMenuItem(title: "Open X Live Studio", action: #selector(openStudio), keyEquivalent: ""))
        m.addItem(broadcastItem)
        m.addItem(NSMenuItem(title: "Help", action: #selector(openHelp), keyEquivalent: ""))
        m.addItem(NSMenuItem(title: "About / Licenses", action: #selector(openAbout), keyEquivalent: ""))
        m.addItem(.separator())
        m.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        m.items.forEach { if $0.action != nil { $0.target = self } }
        item.menu = m
        XLive.log = { appLog($0) }
        XLive.restoreSession()
        settings.onAccount = { [weak self] in
            self?.goLiveOk = false
            self?.goLiveQuietUntil = .distantPast
            self?.noteStream(self?.state ?? "idle")
        }
        apply("idle")
        syncLogin()
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
        // LAN-mode DNS runs the whole time the app is open, independent of the relay.
        ensureDNS()
        Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.ensureDNS() }
        guide.openSettings = { [weak self] in self?.openSettings() }
        guide.startRelay = { [weak self] in self?.start() }
        if !Store.complete { guide.present() }
        if Store.relayWanted { begin(restoring: true) }
        else { refresh() }
    }

    /// Command-V only works if the app has an Edit menu. Status-item apps do not get one.
    func installEditMenu() {
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let quitItem = appMenu.addItem(withTitle: "Quit PS5 X Live", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        appItem.submenu = appMenu
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        let main = NSMenu()
        main.addItem(appItem)
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    func refresh() {
        DispatchQueue.global().async {
            let s = relay(["status"]).1
            let tw = (Store.lanMode && Store.simulcast) ? relay(["twitch-status"]).1 : ""
            DispatchQueue.main.async {
                self.apply(s)
                self.applyTwitch(tw)
                self.noteStream(s)
                self.syncLogin()
            }
        }
    }
    func applyTwitch(_ t: String) {
        guard Store.lanMode && Store.simulcast else { twitchLine.isHidden = true; return }
        switch t {
        case "sending": twitchLine.title = "Twitch: sending"
        case "error": twitchLine.title = "Twitch: error (retrying)"
        case "starting": twitchLine.title = "Twitch: starting…"
        default: twitchLine.title = "Twitch: idle"
        }
        twitchLine.isHidden = false
    }

    func apply(_ s: String) {
        startItem.isEnabled = s == "idle"
        stopItem.isEnabled = s != "idle" || Store.relayWanted
        guard s != state else { return }
        state = s
        let symbol: String
        var tint: NSColor?
        switch s {
        case "relaying": statusLine.title = "Relaying to X"; symbol = "dot.radiowaves.left.and.right"; tint = .systemRed
        case "waiting": statusLine.title = Store.lanMode ? "Waiting for PS5" : "Waiting for Twitch"; symbol = "dot.radiowaves.left.and.right"; tint = .systemOrange
        default: statusLine.title = "Idle"; symbol = "gamecontroller"
        }
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "PS5 X Live")
        img?.isTemplate = tint == nil
        item.button?.image = img
        item.button?.contentTintColor = tint
        syncMode()
    }

    func syncMode() {
        modeTwitch.state = Store.lanMode ? .off : .on
        modeLan.state = Store.lanMode ? .on : .off
        lanLine.isHidden = !Store.lanMode
        twitchWarn.isHidden = Store.lanMode
        copyIP.isHidden = !Store.lanMode
        alsoTwitch.isHidden = !Store.lanMode
        alsoTwitch.state = Store.simulcast ? .on : .off
        autoLiveItem.state = Store.autoLive ? .on : .off
        announceItem.state = Store.announce ? .on : .off
        broadcastItem.isEnabled = !Store.shareURL.isEmpty
        twitchLine.isHidden = !(Store.lanMode && Store.simulcast)
        if Store.lanMode {
            // Overrides are active only while the relay runs; idle means the PS5 reaches Twitch normally.
            if state == "idle" {
                lanLine.title = "DNS: Twitch passthrough"
            } else if cachedIP.isEmpty {
                lanLine.title = "DNS: Redirecting PS5 → X"
                DispatchQueue.global().async { let ip = lanIP(); DispatchQueue.main.async { self.cachedIP = ip; if self.state != "idle" { self.lanLine.title = "DNS: Redirecting PS5 → X  (\(ip))" } } }
            } else {
                lanLine.title = "DNS: Redirecting PS5 → X  (\(cachedIP))"
            }
        }
    }

    /// Starts the bundled DNS server when in LAN mode. Idempotent and safe to call repeatedly;
    /// the relay script restarts DNS on its own if it crashes.
    func ensureDNS() {
        guard Store.lanMode else { return }
        DispatchQueue.global().async { relay(["dns-start"], env: ["PS5XL_LAN_IP": lanIP()]) }
    }
    func stopDNS() { DispatchQueue.global().async { relay(["dns-stop"]) } }

    func switchMode(_ m: String) {
        guard Store.mode != m else { return }
        let resume = Store.relayWanted
        DispatchQueue.global().async {
            relay(["stop"])
            if m == "lan" { relay(["dns-start"], env: ["PS5XL_LAN_IP": lanIP()]) } else { relay(["dns-stop"]) }
            DispatchQueue.main.async {
                Store.mode = m; self.cachedIP = ""; self.goLiveOk = false; self.syncMode(); self.guide.rebuild()
                if !Store.complete { self.settings.present() }
                else if resume { self.begin(restoring: true) }
                else if Store.lanMode { self.guide.present() }
            }
        }
    }
    /// Always-shown risk confirmation for the Twitch Relay method. Returns true to proceed.
    func confirmTwitchRisk() -> Bool {
        let a = NSAlert()
        a.messageText = "Twitch Relay — use at your own risk"
        a.informativeText = "Restreaming Twitch feeds may violate Twitch's Terms of Service."
        a.addButton(withTitle: "Continue")
        a.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return a.runModal() == .alertFirstButtonReturn
    }
    @objc func toggleAutoLive() {
        Store.autoLive.toggle()
        goLiveOk = false
        goLiveQuietUntil = .distantPast
        syncMode()
        noteStream(state)
    }
    @objc func toggleAnnounce() {
        Store.announce.toggle()
        syncMode()
    }
    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let a = NSAlert()
            a.messageText = "Couldn't change Open at Login"
            a.informativeText = error.localizedDescription
            a.runModal()
        }
        syncLogin()
        if SMAppService.mainApp.status == .requiresApproval {
            let a = NSAlert()
            a.messageText = "Approve Open at Login"
            a.informativeText = "macOS is waiting for you to allow PS5 X Live in System Settings → General → Login Items."
            a.addButton(withTitle: "Open Login Items")
            a.addButton(withTitle: "OK")
            if a.runModal() == .alertFirstButtonReturn { openURL(Links.loginItems) }
        }
    }
    func syncLogin() {
        let status = SMAppService.mainApp.status
        loginItem.state = status == .enabled ? .on : .off
        loginItem.title = status == .requiresApproval ? "Open at Login (approval needed)" : "Open at Login"
    }

    func xStatus(_ title: String) {
        xLine.title = title.count > 80 ? String(title.prefix(77)) + "…" : title
    }

    /// When the PS5's video is actually flowing, publish on X. POST /2/broadcasts
    /// returns the source's current live broadcast (rejoin) or starts a new one.
    func noteStream(_ s: String) {
        let up = s == "relaying"
        if up {
            awaySince = nil
            guard Store.autoLive else {
                if !goLiveOk { xStatus("X: auto go live is off") }
                return
            }
            guard XLive.signedIn else {
                xStatus("X: sign in to go live")
                return
            }
            if goLiveOk { return }
            considerGoLive()
        } else {
            if awaySince == nil { awaySince = Date() }
            if let t = awaySince, Date().timeIntervalSince(t) >= 20 { goLiveOk = false }
            guard !goLiveOk else { return }
            if !XLive.signedIn { xStatus("X: not signed in") }
            else if !Store.autoLive { xStatus("X: auto go live is off") }
            else if Store.relayWanted { xStatus("X: waiting for the PS5") }
            else { xStatus("X: idle") }
        }
    }

    func considerGoLive() {
        guard !goLiveBusy, Date() >= goLiveQuietUntil else { return }
        goLiveBusy = true
        xStatus("X: going live…")
        let title = Store.liveTitle
        let announce = Store.announce
        DispatchQueue.global().async {
            let result = XLive.publish(title: title, announce: announce, streamKey: Store.key)
            DispatchQueue.main.async {
                self.goLiveBusy = false
                switch result {
                case .created(let id, let share):
                    self.goLiveOk = true
                    Store.shareURL = share ?? ""
                    self.xStatus("X: live")
                    appLog("X live: started broadcast \(id)")
                case .rejoined(let id, let share):
                    self.goLiveOk = true
                    if let share, !share.isEmpty { Store.shareURL = share }
                    self.xStatus("X: rejoined")
                    appLog("X live: rejoined broadcast \(id)")
                case .retry(let msg):
                    self.goLiveQuietUntil = Date().addingTimeInterval(12)
                    self.xStatus("X: " + msg)
                    appLog("X live: retry \(msg)")
                case .failed(let msg):
                    self.goLiveQuietUntil = Date().addingTimeInterval(45)
                    self.xStatus("X: " + msg)
                    appLog("X live: \(msg)")
                }
                self.broadcastItem.isEnabled = !Store.shareURL.isEmpty
            }
        }
    }

    @objc func toggleSimulcast() {
        Store.simulcast.toggle()
        let on = Store.simulcast
        DispatchQueue.global().async {
            relay([on ? "twitch-on" : "twitch-off"])
            DispatchQueue.main.async { self.syncMode(); self.refresh() }
        }
    }
    @objc func setTwitch() { if confirmTwitchRisk() { switchMode("twitch") } }
    @objc func setLan() { switchMode("lan") }
    @objc func copyLanIP() { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(cachedIP.isEmpty ? lanIP() : cachedIP, forType: .string) }

    func checkTools() -> Bool {
        let missing = missingTools()
        guard !missing.isEmpty else { return true }
        let a = NSAlert()
        a.messageText = "Missing " + missing.joined(separator: " and ")
        a.informativeText = brewCommand
        a.addButton(withTitle: "Copy Command")
        a.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn {
            copyBrewCommand()
        }
        return false
    }

    @objc func start() { begin(restoring: false) }

    /// `restoring` skips the Twitch warning and the missing-tool alert. Start Relay
    /// already confirmed those, and the choice is what we bring back after a reboot.
    func begin(restoring: Bool) {
        if !restoring && !Store.lanMode && !confirmTwitchRisk() { return }
        if restoring {
            if !missingTools().isEmpty {
                appLog("relay not restored: a bundled tool is missing")
                return
            }
        } else if !checkTools() {
            return
        }
        guard Store.complete else {
            if !restoring {
                settings.onSave = { [weak self] in self?.start() }
                settings.present()
            }
            return
        }
        Store.relayWanted = true
        if restoring { appLog("restoring relay (left on)") }
        var env = ["PS5XL_MODE": Store.mode, "PS5XL_SERVER": Store.server, "PS5XL_KEY": Store.key]
        if Store.lanMode { env["PS5XL_LAN_IP"] = lanIP() } else { env["PS5XL_CHANNEL"] = Store.channel }
        apply("waiting")
        if Store.lanMode { ensureDNS() }
        DispatchQueue.global().async {
            if Store.lanMode { relay([Store.simulcast ? "twitch-on" : "twitch-off"]) }
            relay(["start"], env: env); self.refresh()
        }
    }

    @objc func stop() {
        Store.relayWanted = false
        goLiveOk = false
        DispatchQueue.global().async { relay(["stop"]); self.refresh() }
    }
    @objc func openSettings() { settings.present() }
    @objc func openLog() {
        if !FileManager.default.fileExists(atPath: logPath) { FileManager.default.createFile(atPath: logPath, contents: nil) }
        NSWorkspace.shared.open(URL(fileURLWithPath: logPath))
    }
    @objc func openGuide() { guide.present() }
    @objc func openAbout() { about.present() }
    @objc func openStudio() { openURL(Links.liveStudio) }
    @objc func openBroadcast() { openURL(Store.shareURL) }
    @objc func openHelp() { openURL(Links.readme) }
    /// Quit stops the processes. relayWanted stays set, so the next launch turns the relay back on.
    @objc func quit() { relay(["stop"]); relay(["dns-stop"]); NSApp.terminate(nil) }
}

private let appLogLock = NSLock()
func appLog(_ message: String) {
    appLogLock.lock()
    defer { appLogLock.unlock() }
    let stamp = ISO8601DateFormatter().string(from: Date())
    var text = message.replacingOccurrences(of: #"Bearer [A-Za-z0-9%._\-]+"#, with: "Bearer ***", options: .regularExpression)
    let key = Store.key
    if !key.isEmpty { text = text.replacingOccurrences(of: key, with: "***") }
    let line = stamp + " " + text + "\n"
    if let handle = FileHandle(forWritingAtPath: logPath) {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        try? handle.close()
    } else {
        FileManager.default.createFile(atPath: logPath, contents: Data(line.utf8))
    }
}

// MARK: - Entry

if CommandLine.arguments.contains("--selftest") {
    exit(XLive.selfTest() ? 0 : 1)
}

// `--import DIR` reads twitch_channel, x_ingest_url and x_stream_key files from DIR
// into the app's settings and Keychain, then exits. Useful for scripted setup.
let args = CommandLine.arguments
if let i = args.firstIndex(of: "--import"), i + 1 < args.count {
    let dir = (args[i + 1] as NSString).expandingTildeInPath
    func read(_ f: String) -> String {
        ((try? String(contentsOfFile: dir + "/" + f, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    if let ch = normalizeChannel(read("twitch_channel")) { Store.channel = ch }
    var srv = read("x_ingest_url")
    while srv.hasSuffix("/") { srv.removeLast() }
    if srv.hasPrefix("rtmps://") || srv.hasPrefix("rtmp://") { Store.server = srv }
    let k = read("x_stream_key"); if !k.isEmpty { Store.key = k }
    let u = read("x_username"); if !u.isEmpty { Store.xUser = u }
    print(Store.complete ? "imported" : "incomplete")
    exit(Store.complete ? 0 : 1)
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
