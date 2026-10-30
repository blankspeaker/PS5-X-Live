import Cocoa
import Security

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

    static var key: String {
        get {
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
        set {
            let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                       kSecAttrService as String: keyService,
                                       kSecAttrAccount as String: account]
            SecItemDelete(base as CFDictionary)
            guard !newValue.isEmpty else { return }
            var add = base
            add[kSecValueData as String] = Data(newValue.utf8)
            add[kSecAttrLabel as String] = "PS5 X Live stream key"
            SecItemAdd(add as CFDictionary, nil)
        }
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

final class SettingsWindow: NSWindowController {
    let channel = NSTextField()
    let server = NSTextField()
    let key = NSSecureTextField()
    let xUser = NSTextField()
    var onSave: (() -> Void)?

    convenience init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 200),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "PS5 X Live"
        self.init(window: w)
        channel.placeholderString = "channel or twitch.tv URL"
        server.placeholderString = "rtmps://"
        key.placeholderString = "Stream key"
        xUser.placeholderString = "Optional"
        for f in [channel, server, key, xUser] as [NSTextField] { f.widthAnchor.constraint(equalToConstant: 300).isActive = true }

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Twitch channel"), channel],
            [NSTextField(labelWithString: "Server URL"), server],
            [NSTextField(labelWithString: "Stream key"), key],
            [NSTextField(labelWithString: "X username"), xUser],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 10
        grid.columnSpacing = 10

        let save = NSButton(title: "Save", target: self, action: #selector(save))
        save.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [cancel, save])

        let stack = NSStackView(views: [grid, buttons])
        stack.orientation = .vertical
        stack.alignment = .trailing
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        w.contentView = stack
        w.center()
    }

    func present() {
        channel.stringValue = Store.channel
        server.stringValue = Store.server
        key.stringValue = Store.key
        xUser.stringValue = Store.xUser
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
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
        window?.close()
        onSave?()
        onSave = nil
    }

    @objc func cancel() { onSave = nil; window?.close() }
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
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 400),
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
                ("6. Go live on X", [
                    link("X Live Studio") { Links.liveStudio }, link("Your X Profile") { Links.xProfile }]),
                ("When done: on the PS5 set DNS Settings back to Automatic", []),
                ("Help", [
                    link("README") { Links.readme }, link("Report an Issue") { Links.issues }]),
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
                ("6. Go live on X", [
                    link("X Live Studio") { Links.liveStudio }, link("Your X Profile") { Links.xProfile }]),
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

    func applicationDidFinishLaunching(_ n: Notification) {
        let m = NSMenu()
        m.autoenablesItems = false
        statusLine.isEnabled = false
        m.addItem(statusLine)
        lanLine.isEnabled = false
        m.addItem(lanLine)
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
        m.addItem(.separator())
        m.addItem(NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ","))
        m.addItem(NSMenuItem(title: "Setup Guide…", action: #selector(openGuide), keyEquivalent: ""))
        m.addItem(NSMenuItem(title: "Open Log", action: #selector(openLog), keyEquivalent: ""))
        m.addItem(NSMenuItem(title: "Open X Live Studio", action: #selector(openStudio), keyEquivalent: ""))
        m.addItem(NSMenuItem(title: "Help", action: #selector(openHelp), keyEquivalent: ""))
        m.addItem(NSMenuItem(title: "About / Licenses", action: #selector(openAbout), keyEquivalent: ""))
        m.addItem(.separator())
        m.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        m.items.forEach { if $0.action != nil { $0.target = self } }
        item.menu = m
        apply("idle")
        refresh()
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
        // LAN-mode DNS runs the whole time the app is open, independent of the relay.
        ensureDNS()
        Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.ensureDNS() }
        guide.openSettings = { [weak self] in self?.openSettings() }
        guide.startRelay = { [weak self] in self?.start() }
        if !Store.complete { guide.present() }
    }

    func refresh() {
        DispatchQueue.global().async {
            let s = relay(["status"]).1
            DispatchQueue.main.async { self.apply(s) }
        }
    }

    func apply(_ s: String) {
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
        startItem.isEnabled = s == "idle"
        stopItem.isEnabled = s != "idle"
        syncMode()
    }

    func syncMode() {
        modeTwitch.state = Store.lanMode ? .off : .on
        modeLan.state = Store.lanMode ? .on : .off
        lanLine.isHidden = !Store.lanMode
        twitchWarn.isHidden = Store.lanMode
        copyIP.isHidden = !Store.lanMode
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
        DispatchQueue.global().async {
            relay(["stop"])
            if m == "lan" { relay(["dns-start"], env: ["PS5XL_LAN_IP": lanIP()]) } else { relay(["dns-stop"]) }
            DispatchQueue.main.async {
                Store.mode = m; self.cachedIP = ""; self.syncMode(); self.guide.rebuild()
                if !Store.complete { self.settings.present() }
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

    @objc func start() {
        if !Store.lanMode && !confirmTwitchRisk() { return }
        guard checkTools() else { return }
        guard Store.complete else {
            settings.onSave = { [weak self] in self?.start() }
            return settings.present()
        }
        var env = ["PS5XL_MODE": Store.mode, "PS5XL_SERVER": Store.server, "PS5XL_KEY": Store.key]
        if Store.lanMode { env["PS5XL_LAN_IP"] = lanIP() } else { env["PS5XL_CHANNEL"] = Store.channel }
        apply("waiting")
        if Store.lanMode { ensureDNS() }
        DispatchQueue.global().async { relay(["start"], env: env); self.refresh() }
    }

    @objc func stop() { DispatchQueue.global().async { relay(["stop"]); self.refresh() } }
    @objc func openSettings() { settings.present() }
    @objc func openLog() {
        if !FileManager.default.fileExists(atPath: logPath) { FileManager.default.createFile(atPath: logPath, contents: nil) }
        NSWorkspace.shared.open(URL(fileURLWithPath: logPath))
    }
    @objc func openGuide() { guide.present() }
    @objc func openAbout() { about.present() }
    @objc func openStudio() { openURL(Links.liveStudio) }
    @objc func openHelp() { openURL(Links.readme) }
    @objc func quit() { relay(["stop"]); relay(["dns-stop"]); NSApp.terminate(nil) }
}

// MARK: - Entry

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
