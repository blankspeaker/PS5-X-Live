import Cocoa
import CryptoKit
import Darwin
import Security

// X Livestream API (https://docs.x.com/livestream-api/broadcasts/go-live).
// POST /2/broadcasts publishes a source. 201 is a new RUNNING broadcast.
// 200 means that source already has a live broadcast, returned unchanged,
// so a retry rejoins instead of opening a second stream.
// Video must be arriving: X ends a broadcast with TIMED_OUT if none shows up within 5 minutes.

enum GoLiveResult {
    case created(id: String, share: String?)
    case rejoined(id: String, share: String?)
    case retry(String)
    case failed(String)
}

enum XLive {
    static let redirect = "http://127.0.0.1:17351/callback"
    // tweet.write is not required to go live, and requesting a scope the app
    // has not enabled makes X show "You weren't able to give access to the App."
    static let scopes = "broadcast.read broadcast.write offline.access users.read"
    static var log: (String) -> Void = { _ in }
    private(set) static var signedIn = false

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 30
        c.timeoutIntervalForResource = 40
        return URLSession(configuration: c)
    }()

    static func restoreSession() {
        signedIn = !Store.secret("x-refresh-token").isEmpty
    }

    static func signOut() {
        Store.setSecret("x-refresh-token", "", label: "PS5 X Live X refresh token")
        Store.setSecret("x-access-token", "", label: "PS5 X Live X access token")
        Store.tokenExpiry = 0
        signedIn = false
    }

    /// Opens the browser and blocks until X redirects back, or the wait times out.
    /// Call off the main thread. Returns a short status string with no tokens.
    static func signIn() -> String {
        let client = Store.xClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !client.isEmpty else { return "Add an X Client ID in Settings first" }
        let verifier = randomToken(32)
        let challenge = pkceChallenge(verifier)
        let state = randomToken(24)
        // Open x.com directly. The twitter.com address redirects and rewrites
        // spaces in the scope as "+", which X then treats as a bad scope.
        let query = [
            "response_type=code",
            "client_id=\(formEncode(client))",
            "redirect_uri=\(formEncode(redirect))",
            "scope=\(formEncode(scopes))",
            "state=\(formEncode(state))",
            "code_challenge=\(formEncode(challenge))",
            "code_challenge_method=S256",
        ].joined(separator: "&")
        guard let url = URL(string: "https://x.com/i/oauth2/authorize?\(query)") else {
            return "Couldn't build the X sign-in URL"
        }
        guard let code = awaitCallback(expectedState: state, timeout: 180, open: url) else {
            return "X refused access. In the app's User authentication settings, set permissions to Read and write, and set the callback to exactly \(redirect). The app must allow these scopes: \(scopes)."
        }
        do {
            let bundle = try exchange(form: [
                ("grant_type", "authorization_code"),
                ("code", code),
                ("redirect_uri", redirect),
                ("code_verifier", verifier),
                ("client_id", client),
            ])
            try store(bundle)
            rememberUsername()
            log("X account signed in")
            return Store.xUser.isEmpty ? "Signed in" : "Signed in as @\(Store.xUser)"
        } catch {
            return error.localizedDescription
        }
    }

    static func publish(title: String, announce: Bool, streamKey: String) -> GoLiveResult {
        let key = streamKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return .failed("Stream key missing") }
        let chosen = chooseTitle(twitch: twitchBroadcastTitle(), fallback: title)
        log("X title: \(chosen.isEmpty ? "(none)" : chosen)")
        do {
            let token = try accessToken()
            var source = try resolveSource(token: token, key: key)
            let first = try postLive(token: token, source: source, title: chosen, announce: announce)
            if case .failed = first, lastStatus == 404 {
                Store.xSourceId = ""
                Store.xSourceKeyTag = ""
                source = try resolveSource(token: token, key: key)
                return try finish(postLive(token: token, source: source, title: chosen, announce: announce),
                                   token: token, source: source)
            }
            if case .rejoined(let id, _) = first {
                return try retitle(first, token: token, source: source, title: chosen, announce: announce, id: id)
            }
            return try finish(first, token: token, source: source)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// A rejoin keeps the old title. End that broadcast and start another so the PS5 title is the one X shows.
    private static func retitle(_ first: GoLiveResult, token: String, source: String, title: String, announce: Bool, id: String) throws -> GoLiveResult {
        let wanted = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty, let current = currentTitle(token: token, id: id), current != wanted else {
            return try finish(first, token: token, source: source)
        }
        log("X title is \"\(current)\"; ending that broadcast so \"\(wanted)\" can replace it")
        guard endBroadcast(token: token, id: id) else {
            return try finish(first, token: token, source: source)
        }
        return try finish(postLive(token: token, source: source, title: wanted, announce: announce),
                           token: token, source: source)
    }

    /// Login from a channel name or a twitch.tv URL. Empty when it isn't a Twitch channel.
    static func twitchLogin(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("https://") { s.removeFirst(8) }
        else if s.hasPrefix("http://") { s.removeFirst(7) }
        if s.hasPrefix("www.") { s.removeFirst(4) }
        if s.hasPrefix("m.") { s.removeFirst(2) }
        if let range = s.range(of: "twitch.tv/") { s = String(s[range.upperBound...]) }
        if s.hasPrefix("@") { s.removeFirst() }
        s = s.split(separator: "/").first.map(String.init) ?? s
        s = s.split(separator: "?").first.map(String.init) ?? s
        let login = s.lowercased()
        let ok = !login.isEmpty && login.count <= 25 && login.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
        return ok ? login : nil
    }

    /// The PS5 title wins. The Settings title is only used when Twitch has none.
    static func chooseTitle(twitch: String?, fallback: String) -> String {
        let fromPS5 = twitch?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let spare = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        return String((fromPS5.isEmpty ? spare : fromPS5).prefix(200))
    }

    /// The title currently set on the Twitch channel, which is what the PS5 broadcast screen writes.
    private static func twitchBroadcastTitle() -> String? {
        guard let login = twitchLogin(Store.channel) else { return nil }
        let query = "query($login:String!){user(login:$login){broadcastSettings{title}}}"
        let payload: [String: Any] = ["query": query, "variables": ["login": login]]
        guard let body = try? JSONSerialization.data(withJSONObject: payload),
              let url = URL(string: "https://gql.twitch.tv/gql") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 8
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("kimne78kx3ncx6brgo4mv6wki5h1ko", forHTTPHeaderField: "Client-ID")
        req.httpBody = body
        let (status, data) = perform(req)
        guard status == 200,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let user = (root["data"] as? [String: Any])?["user"] as? [String: Any],
              let settings = user["broadcastSettings"] as? [String: Any],
              let title = settings["title"] as? String else { return nil }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Pure helpers (covered by --selftest)

    static func pkceChallenge(_ verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded()
    }

    static func matchingSource(want: String, pairs: [(id: String, key: String)]) -> String? {
        let needle = want.trimmingCharacters(in: .whitespacesAndNewlines)
        return pairs.first { sameSecret($0.key.trimmingCharacters(in: .whitespacesAndNewlines), needle) }?.id
    }

    static func interpret(status: Int, body: Data) -> GoLiveResult {
        let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        let data = (root["data"] as? [String: Any]) ?? root
        let id = (data["id"] as? String) ?? (data["broadcast_id"] as? String) ?? ""
        let share = data["share_url"] as? String
        switch status {
        case 201 where !id.isEmpty:
            return .created(id: id, share: share)
        case 200 where !id.isEmpty:
            return .rejoined(id: id, share: share)
        case 409:
            return .retry(problem(root))
        case 0, 429, 500, 502, 503, 504:
            return .retry(problem(root))
        default:
            return .failed(problem(root))
        }
    }

    static func selfTest() -> Bool {
        var ok = true
        func check(_ name: String, _ pass: Bool) {
            if !pass { ok = false; print("FAIL \(name)") }
        }
        let challenge = pkceChallenge("abc")
        check("pkce charset", challenge.range(of: "[+/=]", options: .regularExpression) == nil && !challenge.isEmpty)
        check("pkce stable", challenge == pkceChallenge("abc"))
        let created = #"{"data":{"id":"b1","broadcast_id":"b1","state":"RUNNING","share_url":"https://x.com/i/broadcasts/b1"}}"#
        if case .created(let id, let share) = interpret(status: 201, body: Data(created.utf8)) {
            check("created id", id == "b1" && share == "https://x.com/i/broadcasts/b1")
        } else { check("created", false) }
        let rejoined = #"{"data":{"id":"b2","state":"RUNNING"}}"#
        if case .rejoined(let id, _) = interpret(status: 200, body: Data(rejoined.utf8)) {
            check("rejoined", id == "b2")
        } else { check("rejoined", false) }
        if case .retry = interpret(status: 409, body: Data(#"{"detail":"encoder has not connected"}"#.utf8)) {
        } else { check("conflict retries", false) }
        if case .retry = interpret(status: 503, body: Data()) {
        } else { check("503 retries", false) }
        if case .failed = interpret(status: 403, body: Data(#"{"detail":"not eligible"}"#.utf8)) {
        } else { check("403 fails", false) }
        check("match", matchingSource(want: "live_abc", pairs: [("1", "other"), ("2", "live_abc")]) == "2")
        check("no match", matchingSource(want: "nope", pairs: [("1", "other")]) == nil)
        check("twitch login", twitchLogin("https://www.twitch.tv/Octodad") == "octodad")
        check("twitch login bare", twitchLogin("@octodad") == "octodad")
        check("prefer twitch title", chooseTitle(twitch: "From PS5", fallback: "Settings") == "From PS5")
        check("fallback title", chooseTitle(twitch: "  ", fallback: "Settings") == "Settings")
        if ok { print("ok") }
        return ok
    }

    // MARK: - Token

    private static func accessToken() throws -> String {
        let cached = Store.secret("x-access-token")
        if signedIn, !cached.isEmpty, Store.tokenExpiry > Date().timeIntervalSince1970 + 60 {
            return cached
        }
        let refresh = Store.secret("x-refresh-token")
        guard !refresh.isEmpty else {
            signedIn = false
            throw XFail("Sign in to X in Settings")
        }
        let bundle = try exchange(form: [
            ("grant_type", "refresh_token"),
            ("refresh_token", refresh),
            ("client_id", Store.xClientID),
        ])
        try store(bundle)
        return Store.secret("x-access-token")
    }

    private static func exchange(form fields: [(String, String)]) throws -> (access: String, refresh: String?, expires: Int) {
        var req = URLRequest(url: URL(string: "https://api.x.com/2/oauth2/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let secret = Store.xClientSecret
        if !secret.isEmpty {
            let raw = "\(Store.xClientID):\(secret)"
            let basic = Data(raw.utf8).base64EncodedString()
            req.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = formBody(fields)
        let (status, data) = perform(req)
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard status == 200, let access = root["access_token"] as? String, !access.isEmpty else {
            if status == 400 || status == 401 {
                signOut()
                throw XFail("X sign-in expired. Sign in again in Settings.")
            }
            throw XFail(problem(root))
        }
        let refresh = root["refresh_token"] as? String
        let expires = (root["expires_in"] as? Int) ?? (root["expires_in"] as? Double).map { Int($0) } ?? 7200
        return (access, refresh, expires)
    }

    private static func store(_ bundle: (access: String, refresh: String?, expires: Int)) throws {
        guard !bundle.access.isEmpty else { throw XFail("X didn't return an access token") }
        Store.setSecret("x-access-token", bundle.access, label: "PS5 X Live X access token")
        if let refresh = bundle.refresh, !refresh.isEmpty {
            Store.setSecret("x-refresh-token", refresh, label: "PS5 X Live X refresh token")
        }
        Store.tokenExpiry = Date().timeIntervalSince1970 + Double(bundle.expires)
        signedIn = !Store.secret("x-refresh-token").isEmpty
        guard signedIn else { throw XFail("X didn't return a refresh token. Enable offline.access on the app and sign in again.") }
    }

    private static func rememberUsername() {
        guard let token = try? accessToken() else { return }
        var req = URLRequest(url: URL(string: "https://api.x.com/2/users/me?user.fields=username")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (status, data) = perform(req)
        guard status == 200,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let user = root["data"] as? [String: Any],
              let name = user["username"] as? String, !name.isEmpty else { return }
        Store.xUser = name
    }

    // MARK: - Broadcasts

    private static var lastStatus = 0

    private static func finish(_ result: GoLiveResult, token: String, source: String) throws -> GoLiveResult {
        guard case .retry(let detail) = result, lastStatus == 409 else { return result }
        if let live = findRunning(token: token, source: source) {
            return .rejoined(id: live.id, share: live.share)
        }
        let folded = detail.lowercased()
        if folded.contains("encoder") || folded.contains("connect") || folded.contains("video") {
            return .retry(detail)
        }
        return .failed(detail)
    }

    private static func postLive(token: String, source: String, title: String, announce: Bool) throws -> GoLiveResult {
        var body: [String: Any] = ["source_id": source]
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { body["title"] = String(trimmed.prefix(200)) }
        if !announce { body["should_not_tweet"] = true }
        var req = URLRequest(url: URL(string: "https://api.x.com/2/broadcasts")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (status, data) = perform(req)
        lastStatus = status
        return interpret(status: status, body: data)
    }

    private static func resolveSource(token: String, key: String) throws -> String {
        let tag = keyTag(key)
        if Store.xSourceKeyTag == tag, !Store.xSourceId.isEmpty {
            if let remote = streamKey(token: token, id: Store.xSourceId), sameSecret(remote, key) {
                return Store.xSourceId
            }
        }
        let ids = try sourceIDs(token: token)
        var pairs: [(id: String, key: String)] = []
        for id in ids {
            if let remote = streamKey(token: token, id: id) { pairs.append((id, remote)) }
        }
        guard let id = matchingSource(want: key, pairs: pairs) else {
            throw XFail("No X source matches the stream key in Settings")
        }
        Store.xSourceId = id
        Store.xSourceKeyTag = tag
        return id
    }

    private static func sourceIDs(token: String) throws -> [String] {
        let (status, root) = get("/2/sources", token: token)
        guard status == 200 else { throw XFail(problem(root)) }
        let rows = root["data"] as? [[String: Any]] ?? []
        let ids = rows.compactMap { $0["id"] as? String }.filter { !$0.isEmpty }
        guard !ids.isEmpty else { throw XFail("No X sources on this account. Create one in X Live Studio.") }
        return ids
    }

    private static func currentTitle(token: String, id: String) -> String? {
        guard let escaped = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        let (status, root) = get("/2/broadcasts/\(escaped)?broadcast.fields=title", token: token)
        guard status == 200, let data = root["data"] as? [String: Any] else { return nil }
        let title = (data["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? nil : title
    }

    private static func endBroadcast(token: String, id: String) -> Bool {
        guard let escaped = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://api.x.com/2/broadcasts/\(escaped)/state") else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(#"{"state":"END"}"#.utf8)
        let (status, _) = perform(req)
        return status == 200
    }

    private static func streamKey(token: String, id: String) -> String? {
        guard let escaped = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        let (status, root) = get("/2/sources/\(escaped)/stream_key", token: token)
        guard status == 200, let data = root["data"] as? [String: Any] else { return nil }
        let key = (data["stream_key"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return key.isEmpty ? nil : key
    }

    private static func findRunning(token: String, source: String) -> (id: String, share: String?)? {
        var page = ""
        for _ in 0..<5 {
            var path = "/2/broadcasts?broadcast.fields=source_id,state,share_url"
            if !page.isEmpty, let token = page.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
                path += "&pagination_token=\(token)"
            }
            let (status, root) = get(path, token: token)
            guard status == 200 else { return nil }
            let rows = root["data"] as? [[String: Any]] ?? []
            for row in rows {
                let state = (row["state"] as? String) ?? ""
                let sourceID = (row["source_id"] as? String) ?? ""
                let id = (row["id"] as? String) ?? (row["broadcast_id"] as? String) ?? ""
                if state == "RUNNING", sourceID == source, !id.isEmpty {
                    return (id, row["share_url"] as? String)
                }
            }
            let meta = root["meta"] as? [String: Any]
            guard let next = meta?["next_token"] as? String, !next.isEmpty else { return nil }
            page = next
        }
        return nil
    }

    // MARK: - HTTP

    private static func get(_ path: String, token: String) -> (Int, [String: Any]) {
        var req = URLRequest(url: URL(string: "https://api.x.com" + path)!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (status, data) = perform(req)
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return (status, root)
    }

    private static func perform(_ req: URLRequest) -> (Int, Data) {
        var result: (Int, Data) = (0, Data())
        let sem = DispatchSemaphore(value: 0)
        session.dataTask(with: req) { data, resp, _ in
            result = ((resp as? HTTPURLResponse)?.statusCode ?? 0, data ?? Data())
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 35)
        return result
    }

    private static func problem(_ json: [String: Any]) -> String {
        if let errors = json["errors"] as? [[String: Any]] {
            let msgs = errors.compactMap { $0["message"] as? String }
            if !msgs.isEmpty { return msgs.joined(separator: "; ") }
        }
        if let detail = json["detail"] as? String, !detail.isEmpty { return detail }
        if let title = json["title"] as? String, !title.isEmpty { return title }
        if let error = json["error_description"] as? String, !error.isEmpty { return error }
        if let error = json["error"] as? String, !error.isEmpty { return error }
        return "X API request failed"
    }

    private static func formBody(_ fields: [(String, String)]) -> Data {
        fields.map { formEncode($0.0) + "=" + formEncode($0.1) }.joined(separator: "&").data(using: .utf8) ?? Data()
    }

    private static func formEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    private static func keyTag(_ key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func sameSecret(_ a: String, _ b: String) -> Bool {
        let da = Array(a.utf8), db = Array(b.utf8)
        guard da.count == db.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<da.count { diff |= da[i] ^ db[i] }
        return diff == 0
    }

    private static func randomToken(_ bytes: Int) -> String {
        var buf = [UInt8](repeating: 0, count: bytes)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes, &buf)
        return Data(buf).base64URLEncoded()
    }

    /// Listens on 127.0.0.1:17351, opens the browser, and returns the authorization code.
    private static func awaitCallback(expectedState: String, timeout: TimeInterval, open url: URL) -> String? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(17351)).bigEndian
        guard inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr) == 1 else { return nil }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 4) == 0 else { return nil }
        DispatchQueue.main.async { NSWorkspace.shared.open(url) }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let remain = Int32(deadline.timeIntervalSinceNow * 1000)
            if remain <= 0 { break }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            if poll(&pfd, 1, remain) <= 0 { break }
            let client = accept(fd, nil, nil)
            if client < 0 { continue }
            defer { close(client) }
            var nosig: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &nosig, socklen_t(MemoryLayout<Int32>.size))
            let req = readHTTP(client)
            if requestDenied(req) {
                writeHTTP(client, "X sign-in was cancelled. You can close this window.")
                return nil
            }
            let code = authorizationCode(req, expectedState: expectedState)
            writeHTTP(client, code == nil
                ? "Sign-in didn't match. You can close this window and try again."
                : "PS5 X Live is signed in. You can close this window.")
            if let code { return code }
        }
        return nil
    }

    private static func readHTTP(_ client: Int32) -> String {
        var buf = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 2048)
        let deadline = Date().addingTimeInterval(2)
        while buf.count < 8192, Date() < deadline {
            var pfd = pollfd(fd: client, events: Int16(POLLIN), revents: 0)
            if poll(&pfd, 1, 200) <= 0 { break }
            let n = read(client, &chunk, chunk.count)
            if n <= 0 { break }
            buf.append(contentsOf: chunk[..<Int(n)])
            if buf.contains(13), let text = String(bytes: buf, encoding: .utf8), text.contains("\r\n\r\n") {
                return text
            }
        }
        return String(bytes: buf, encoding: .utf8) ?? ""
    }

    private static func writeHTTP(_ client: Int32, _ page: String) {
        let body = "<!doctype html><meta charset=utf-8><title>PS5 X Live</title><p>\(page)</p>"
        let resp = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        _ = resp.withCString { write(client, $0, strlen($0)) }
    }

    private static func requestDenied(_ request: String) -> Bool {
        guard let line = request.split(separator: "\r\n", maxSplits: 1).first else { return false }
        return line.contains("error=")
    }

    private static func authorizationCode(_ request: String, expectedState: String) -> String? {
        guard let line = request.split(separator: "\r\n", maxSplits: 1).first,
              line.hasPrefix("GET ") else { return nil }
        let parts = line.split(separator: " ")
        guard parts.count >= 2,
              let url = URL(string: "http://127.0.0.1" + parts[1]),
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        let state = items.first { $0.name == "state" }?.value ?? ""
        let code = items.first { $0.name == "code" }?.value ?? ""
        guard state == expectedState, !code.isEmpty else { return nil }
        return code
    }
}

private struct XFail: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

private extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
