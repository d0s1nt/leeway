// LLM Usage — a macOS menu bar app showing rate-limit usage for the LLM
// accounts signed in on this Mac (Claude Code, Codex, Gemini CLI, Grok).
// Build: ./build.sh   (single file, no Xcode project needed)

import AppKit

// MARK: - Model

struct UsageWindow {
    let label: String
    let usedPercent: Double      // 0...100
    let resetsAt: Date?
    var headline = true          // false for secondary figures (e.g. a spend cap) that shouldn't drive the menu bar number
}

struct ProviderStatus {
    let name: String
    let short: String            // menu-bar abbreviation
    var plan: String? = nil
    var windows: [UsageWindow] = []
    var error: String? = nil
    var missing: String? = nil        // the tool isn't installed or signed in on this Mac: left out of the menu, listed in Setup Check
    var link: URL? = nil
    var note: String? = nil
    var fetchedAt: Date = Date()
    var staleSince: Date? = nil       // set when we're showing an older result because the latest refresh failed

    /// Headline figure for the menu bar: the most-used window.
    var headline: Double? { windows.filter(\.headline).map(\.usedPercent).max() }
}

/// Whether the app may renew another tool's expired sign-in. Off by default: renewing means using that tool's
/// own OAuth client and writing the new tokens back into its store, and where refresh tokens are single-use
/// (Claude Code, Codex) a race with the tool itself can sign the user out of it. With this off the app is
/// strictly read-only and asks the user to open the tool, which renews its own sign-in.
var allowTokenRefresh: Bool { UserDefaults.standard.bool(forKey: "refreshTokens") }
/// "Show Remaining": display what's left instead of what's used, the way the vendors' own screens count down.
/// Only the wording, numbers and bar direction change; colours still warn as the allowance runs out.
var showRemaining: Bool { UserDefaults.standard.bool(forKey: "showRemaining") }
func shownPercent(_ used: Double) -> Double { showRemaining ? max(0, 100 - used) : used }
var percentWord: String { showRemaining ? "left" : "used" }
let refreshHint = "or turn on \u{201C}Renew Expired Sign-ins\u{201D} in this menu"

/// Finds a command-line tool wherever it was installed. A menu bar app started by launchd gets a bare PATH,
/// so this also asks the user's login shell for theirs and checks the usual per-user install locations.
enum Tools {
    static let searchPath: [String] = {
        var dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let (code, out) = run("/bin/zsh", ["-lc", "print -r -- $PATH"])
        if code == 0, let line = out.split(separator: "\n").last { dirs += line.split(separator: ":").map(String.init) }
        dirs += [".local/bin", "bin", ".npm-global/bin", ".bun/bin", ".volta/bin", ".cargo/bin", ".deno/bin"].map(home)
        dirs += ["/opt/homebrew/bin", "/usr/local/bin"]
        // Node version managers put global installs under a per-version folder; newest first.
        for root in [home(".nvm/versions/node"), home(".local/share/fnm/node-versions"), home(".asdf/installs/nodejs")] {
            let versions = ((try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []).sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            dirs += versions.flatMap { ["\(root)/\($0)/bin", "\(root)/\($0)/installation/bin"] }
        }
        var seen = Set<String>()
        return dirs.filter { !$0.isEmpty && seen.insert($0).inserted }
    }()
    static func find(_ name: String, extra: [String] = []) -> String? {
        (extra + searchPath).map { "\($0)/\(name)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

protocol Provider {
    var name: String { get }
    var short: String { get }
    func fetch() -> ProviderStatus
}

// MARK: - Helpers

enum HTTPError: Error, CustomStringConvertible {
    case status(Int, String)
    case transport(String)
    case badJSON
    var description: String {
        switch self {
        case .status(let c, let body): return "HTTP \(c): \(body.prefix(140))"
        case .transport(let m): return m
        case .badJSON: return "unexpected response"
        }
    }
}

func http(_ urlString: String, method: String = "GET", headers: [String: String] = [:], body: Data? = nil) throws -> (Int, Data) {
    guard let url = URL(string: urlString) else { throw HTTPError.transport("bad URL") }
    var req = URLRequest(url: url, timeoutInterval: 20)
    req.httpMethod = method
    headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
    req.httpBody = body
    let sem = DispatchSemaphore(value: 0)
    var out: (Int, Data)?
    var err: Error?
    URLSession.shared.dataTask(with: req) { data, resp, e in
        if let e = e { err = e } else { out = ((resp as? HTTPURLResponse)?.statusCode ?? 0, data ?? Data()) }
        sem.signal()
    }.resume()
    sem.wait()
    if let err = err { throw HTTPError.transport(err.localizedDescription) }
    return out!
}

func httpFull(_ urlString: String, method: String = "GET", headers: [String: String] = [:], body: Data? = nil) throws -> (Int, Data, [String: String]) {
    guard let url = URL(string: urlString) else { throw HTTPError.transport("bad URL") }
    var req = URLRequest(url: url, timeoutInterval: 20)
    req.httpMethod = method
    headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
    req.httpBody = body
    let sem = DispatchSemaphore(value: 0)
    var out: (Int, Data, [String: String])?
    var err: Error?
    URLSession.shared.dataTask(with: req) { data, resp, e in
        if let e = e { err = e } else {
            let h = (resp as? HTTPURLResponse)?.allHeaderFields ?? [:]
            var hs: [String: String] = [:]
            for (k, v) in h { hs["\(k)".lowercased()] = "\(v)" }
            out = ((resp as? HTTPURLResponse)?.statusCode ?? 0, data ?? Data(), hs)
        }
        sem.signal()
    }.resume()
    sem.wait()
    if let err = err { throw HTTPError.transport(err.localizedDescription) }
    return out!
}

func json(_ data: Data) throws -> [String: Any] {
    guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw HTTPError.badJSON }
    if ProcessInfo.processInfo.environment["LLMUSAGE_DEBUG"] != nil { debugShape(o) }
    return o
}

let debugShowKeys: Set<String> = ["account_id", "chatgpt_account_id", "user_id", "used_percent", "limit_window_seconds", "reset_at", "reset_after_seconds", "allowed", "limit_reached", "balance", "has_credits", "unlimited", "available_count", "error", "error_description", "subscriptionType", "rateLimitTier", "plan_type", "subscription_tier", "subscription_tier_display", "tier", "requestKind", "modelName", "windowSizeSeconds", "remainingQueries", "totalQueries", "remainingTokens", "totalTokens", "waitTimeSeconds", "cost", "limit", "remaining", "resetAt", "resetsAt", "window", "name", "id", "auth_mode", "plan", "kind", "group", "severity", "is_active", "percent", "display_name", "key", "limit_index",
    "allowance_percent_of_weekly", "used_percent_of_weekly", "id", "name", "tierId", "tierName", "reasonCode", "reasonMessage",
    "userDefinedCloudaicompanionProject", "isDefault", "utilization", "resets_at", "as_of", "window_started_at", "scope", "description"]
/// Prints key names and value types only (plus values for a whitelist of descriptive keys) — never values — so responses can be inspected safely.
func debugShape(_ o: [String: Any], indent: String = "  ") {
    for k in o.keys.sorted() {
        let v = o[k]
        if let d = v as? [String: Any] { print("\(indent)\(k): {"); debugShape(d, indent: indent + "  "); print("\(indent)}") }
        else if let a = v as? [Any] { print("\(indent)\(k): [\(a.count)]"); for (i, e) in a.enumerated() { if let d = e as? [String: Any] { print("\(indent)  -[\(i)]"); debugShape(d, indent: indent + "    ") } } }
        else if v is NSNull { print("\(indent)\(k): null") }
        else if debugShowKeys.contains(k) { print("\(indent)\(k) = \(v!)") }
        else { print("\(indent)\(k): \(type(of: v!))") }
    }
}

func jsonData(_ o: Any) -> Data { try! JSONSerialization.data(withJSONObject: o) }

func iso(_ s: String?) -> Date? {
    guard let s = s else { return nil }
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: s) { return d }
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: s)
}

@discardableResult
func run(_ cmd: String, _ args: [String]) -> (Int32, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: cmd)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return (-1, error.localizedDescription) }
    let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

func home(_ rel: String) -> String { NSHomeDirectory() + "/" + rel }

func jwtExpiry(_ token: String) -> Date? {
    let parts = token.split(separator: ".")
    guard parts.count >= 2 else { return nil }
    var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while b64.count % 4 != 0 { b64 += "=" }
    guard let d = Data(base64Encoded: b64), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
          let exp = o["exp"] as? Double else { return nil }
    return Date(timeIntervalSince1970: exp)
}

func windowLabel(seconds: Int) -> String {
    switch seconds {
    case 604800: return "Weekly"
    case 18000: return "5-hour"
    case 3600: return "Hourly"
    case 86400: return "Daily"
    default:
        if seconds % 86400 == 0 { return "\(seconds / 86400)-day" }
        if seconds % 3600 == 0 { return "\(seconds / 3600)-hour" }
        return "\(seconds / 60)-min"
    }
}

// MARK: - Claude Code (Anthropic OAuth)

struct ClaudeProvider: Provider {
    let name = "Claude"
    let short = "C"
    static let service = "Claude Code-credentials"
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

    func fetch() -> ProviderStatus {
        var st = ProviderStatus(name: name, short: short, link: URL(string: "https://claude.ai/settings/usage"))
        // Read the credential blob Claude Code keeps in the login keychain.
        let (code, blob) = run("/usr/bin/security", ["find-generic-password", "-s", Self.service, "-w"])
        guard code == 0, let data = blob.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              var root = try? json(data), var oauth = root["claudeAiOauth"] as? [String: Any],
              var access = oauth["accessToken"] as? String else {
            st.missing = "No Claude Code sign-in in the keychain. Install Claude Code and run `claude`, and allow keychain access when macOS asks."
            return st
        }
        st.plan = (oauth["subscriptionType"] as? String)?.capitalized
        let expiresAt = (oauth["expiresAt"] as? Double ?? 0) / 1000
        if expiresAt < Date().timeIntervalSince1970 + 120, !allowTokenRefresh {
            st.error = "Claude Code's sign-in has expired. Run `claude` once to renew it, \(refreshHint)."
            return st
        }
        if expiresAt < Date().timeIntervalSince1970 + 120, let refresh = oauth["refreshToken"] as? String {
            // Expired and the user opted in: refresh the same way Claude Code does and write the blob back.
            do {
                let (c, d) = try http("https://console.anthropic.com/v1/oauth/token", method: "POST",
                                      headers: ["Content-Type": "application/json"],
                                      body: jsonData(["grant_type": "refresh_token", "refresh_token": refresh, "client_id": Self.clientID]))
                let o = try json(d)
                guard c == 200, let newAccess = o["access_token"] as? String else {
                    let why = (o["error_description"] as? String) ?? (o["error"] as? String) ?? "HTTP \(c)"
                    st.error = "Claude Code's saved sign-in can't be refreshed (\(why)). Run `claude` in a terminal and sign in again; the desktop app's own session doesn't update this."
                    return st
                }
                access = newAccess
                oauth["accessToken"] = newAccess
                if let r = o["refresh_token"] as? String { oauth["refreshToken"] = r }
                if let e = o["expires_in"] as? Double { oauth["expiresAt"] = Int((Date().timeIntervalSince1970 + e) * 1000) }
                root["claudeAiOauth"] = oauth
                let acct = keychainAccount() ?? NSUserName()
                let newBlob = String(decoding: jsonData(root), as: UTF8.self)
                run("/usr/bin/security", ["add-generic-password", "-U", "-a", acct, "-s", Self.service, "-w", newBlob])
            } catch {
                st.error = "Refresh failed: \(error)"
                return st
            }
        }
        do {
            let (c, d) = try http("https://api.anthropic.com/api/oauth/usage",
                                  headers: ["Authorization": "Bearer \(access)", "anthropic-beta": "oauth-2025-04-20"])
            let o = try json(d)
            guard c == 200 else {
                let msg = ((o["error"] as? [String: Any])?["message"] as? String) ?? String(decoding: d, as: UTF8.self)
                throw HTTPError.status(c, msg)
            }
            if let limits = o["limits"] as? [[String: Any]], !limits.isEmpty {
                for l in limits {
                    guard let pct = l["percent"] as? Double else { continue }
                    let kind = l["kind"] as? String ?? "limit"
                    var label: String
                    switch kind {
                    case "five_hour": label = "5-hour"
                    case "weekly_all": label = "Weekly (all)"
                    case "weekly_scoped":
                        let model = ((l["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String
                        label = "Weekly " + (model ?? "scoped")
                    default: label = kind.replacingOccurrences(of: "_", with: " ").capitalized
                    }
                    st.windows.append(UsageWindow(label: label, usedPercent: pct, resetsAt: iso(l["resets_at"] as? String), headline: kind != "five_hour"))
                }
            } else {
                let order = ["five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet"]
                let labels = ["five_hour": "5-hour", "seven_day": "Weekly (all)", "seven_day_opus": "Weekly Opus", "seven_day_sonnet": "Weekly Sonnet"]
                for k in order {
                    guard let w = o[k] as? [String: Any], let u = w["utilization"] as? Double else { continue }
                    st.windows.append(UsageWindow(label: labels[k] ?? k, usedPercent: u, resetsAt: iso(w["resets_at"] as? String), headline: k != "five_hour"))
                }
            }
            if let bd = o["seven_day_breakdown"] as? [String: Any], let rows = bd["rows"] as? [[String: Any]] {
                let parts = rows.compactMap { r -> String? in
                    guard let n = r["display_name"] as? String, let p = r["percent"] as? Double, p > 0 else { return nil }
                    return "\(n) \(Int(p))%"
                }
                if !parts.isEmpty { st.note = "This week by surface: " + parts.joined(separator: " · ") }
            }
            if st.windows.isEmpty { st.note = "No limit windows reported" }
        } catch { st.error = "\(error)" }
        return st
    }

    private func keychainAccount() -> String? {
        let (_, out) = run("/usr/bin/security", ["find-generic-password", "-s", Self.service])
        guard let r = out.range(of: "\"acct\"<blob>=\"") else { return nil }
        let rest = out[r.upperBound...]
        return rest.split(separator: "\"").first.map(String.init)
    }
}

// MARK: - Codex (ChatGPT account)

struct CodexProvider: Provider {
    let name = "Codex"
    let short = "X"
    static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    let path = home(".codex/auth.json")

    func fetch() -> ProviderStatus {
        var st = ProviderStatus(name: name, short: short, link: URL(string: "https://chatgpt.com/codex/settings/usage"))
        guard let data = FileManager.default.contents(atPath: path), var root = try? json(data),
              var tokens = root["tokens"] as? [String: Any], var access = tokens["access_token"] as? String else {
            st.missing = "No Codex sign-in found. Install the Codex CLI and run `codex` to sign in with ChatGPT."
            return st
        }
        let acct = tokens["account_id"] as? String ?? ""
        if let exp = jwtExpiry(access), exp < Date().addingTimeInterval(120), !allowTokenRefresh {
            st.error = "Codex's sign-in has expired. Run `codex` once to renew it, \(refreshHint)."
            return st
        }
        if let exp = jwtExpiry(access), exp < Date().addingTimeInterval(120), let refresh = tokens["refresh_token"] as? String {
            do {
                let (c, d) = try http("https://auth.openai.com/oauth/token", method: "POST",
                                      headers: ["Content-Type": "application/json"],
                                      body: jsonData(["client_id": Self.clientID, "grant_type": "refresh_token",
                                                      "refresh_token": refresh, "scope": "openid profile email"]))
                let o = try json(d)
                guard c == 200, let a = o["access_token"] as? String else {
                    st.error = "Token expired; run `codex` once to re-authenticate"
                    return st
                }
                access = a
                tokens["access_token"] = a
                if let r = o["refresh_token"] as? String { tokens["refresh_token"] = r }
                if let i = o["id_token"] as? String { tokens["id_token"] = i }
                root["tokens"] = tokens
                root["last_refresh"] = ISO8601DateFormatter().string(from: Date())
                try jsonData(root).write(to: URL(fileURLWithPath: path), options: .atomic)
            } catch { st.error = "Refresh failed: \(error)"; return st }
        }
        do {
            let (c, d) = try http("https://chatgpt.com/backend-api/wham/usage",
                                  headers: ["Authorization": "Bearer \(access)", "ChatGPT-Account-Id": acct, "User-Agent": "codex-cli"])
            guard c == 200 else { throw HTTPError.status(c, String(decoding: d, as: UTF8.self)) }
            let o = try json(d)
            // The endpoint's internal plan names don't all match what ChatGPT calls them.
            let planNames = ["prolite": "Pro 100", "pro": "Pro", "plus": "Plus", "free": "Free", "team": "Team", "business": "Business", "enterprise": "Enterprise", "edu": "Edu", "go": "Go"]
            st.plan = (o["plan_type"] as? String).map { planNames[$0.lowercased()] ?? $0.capitalized }
            // Which ChatGPT account the CLI is signed into matters when the numbers look wrong.
            if let email = o["email"] as? String, !email.isEmpty { st.plan = [st.plan, email].compactMap { $0 }.joined(separator: " · ") }
            if let rl = o["rate_limit"] as? [String: Any] {
                for key in ["primary_window", "secondary_window"] {
                    guard let w = rl[key] as? [String: Any], let used = w["used_percent"] as? Double else { continue }
                    let secs = w["limit_window_seconds"] as? Int ?? 0
                    let reset = (w["reset_at"] as? Double).map { Date(timeIntervalSince1970: $0) }
                    st.windows.append(UsageWindow(label: windowLabel(seconds: secs) + " limit", usedPercent: used, resetsAt: reset))
                }
            }
            var notes: [String] = []
            if let rl = o["rate_limit"] as? [String: Any], rl["limit_reached"] as? Bool == true { notes.append("Limit reached") }
            if let cr = o["credits"] as? [String: Any] {
                if cr["unlimited"] as? Bool == true { notes.append("Unlimited credits") }
                else if cr["has_credits"] as? Bool == true, let bal = cr["balance"] as? String { notes.append("Credits: \(bal)") }
                if cr["overage_limit_reached"] as? Bool == true { notes.append("overage limit reached") }
            }
            if let rc = o["rate_limit_reset_credits"] as? [String: Any], let n = rc["available_count"] as? Int, n > 0 { notes.append("\(n) limit reset\(n == 1 ? "" : "s") available") }
            if let sc = o["spend_control"] as? [String: Any], sc["reached"] as? Bool == true { notes.append("spend control reached") }
            if st.windows.isEmpty { notes.append("No limit windows reported") }
            if !notes.isEmpty { st.note = notes.joined(separator: " · ") }
        } catch { st.error = "\(error)" }
        return st
    }
}

// MARK: - Gemini CLI (Code Assist)

struct GeminiProvider: Provider {
    let name = "Gemini"
    let short = "G"
    /// The Gemini CLI is an "installed app" in Google's OAuth terms, so its client id and secret ship inside the CLI
    /// itself. They are read from the user's own install at runtime rather than copied into this source.
    static let cliOAuthClient: (id: String, secret: String)? = {
        guard let bin = Tools.find("gemini") else { return nil }
        var dir = URL(fileURLWithPath: bin).resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<4 where !FileManager.default.fileExists(atPath: dir.appendingPathComponent("package.json").path) { dir.deleteLastPathComponent() }
        let (_, out) = run("/usr/bin/grep", ["-rhoE", "--include=*.js", #"OAUTH_CLIENT_(ID|SECRET) ?= ?["'][^"']+["']"#, dir.path])
        func value(_ key: String) -> String? {
            guard let line = out.split(separator: "\n").first(where: { $0.hasPrefix("OAUTH_CLIENT_\(key)") }) else { return nil }
            let parts = line.split(whereSeparator: { $0 == "\"" || $0 == "'" })
            return parts.count >= 2 ? String(parts[1]) : nil
        }
        guard let id = value("ID"), let secret = value("SECRET") else { return nil }
        return (id, secret)
    }()
    let path = home(".gemini/oauth_creds.json")
    let endpoint = "https://cloudcode-pa.googleapis.com/v1internal"

    func fetch() -> ProviderStatus {
        var st = ProviderStatus(name: name, short: short, link: URL(string: "https://gemini.google.com"))
        guard let data = FileManager.default.contents(atPath: path), var creds = try? json(data),
              var access = creds["access_token"] as? String else {
            st.missing = "No Gemini CLI sign-in found. Install the Gemini CLI and run `gemini` to sign in."
            return st
        }
        let expiry = (creds["expiry_date"] as? Double ?? 0) / 1000
        if expiry < Date().timeIntervalSince1970 + 120, let refresh = creds["refresh_token"] as? String {
            guard let client = Self.cliOAuthClient else {
                st.error = "Gemini's sign-in has expired. Run `gemini` once to renew it."
                return st
            }
            do {
                let form = "client_id=\(client.id)&client_secret=\(client.secret)&refresh_token=\(refresh)&grant_type=refresh_token"
                let (c, d) = try http("https://oauth2.googleapis.com/token", method: "POST",
                                      headers: ["Content-Type": "application/x-www-form-urlencoded"], body: form.data(using: .utf8))
                let o = try json(d)
                guard c == 200, let a = o["access_token"] as? String else {
                    st.error = "Token expired; run `gemini` once to re-authenticate"
                    return st
                }
                access = a
                creds["access_token"] = a
                if let e = o["expires_in"] as? Double { creds["expiry_date"] = Int((Date().timeIntervalSince1970 + e) * 1000) }
                if let i = o["id_token"] as? String { creds["id_token"] = i }
                // Google doesn't rotate refresh tokens, so a short-lived access token held in memory disturbs nothing.
                // The Gemini CLI's own file is only updated when the user has opted in.
                if allowTokenRefresh { try jsonData(creds).write(to: URL(fileURLWithPath: path), options: .atomic) }
            } catch { st.error = "Refresh failed: \(error)"; return st }
        }
        let headers = ["Authorization": "Bearer \(access)", "Content-Type": "application/json"]
        do {
            var meta: [String: Any] = ["ideType": "IDE_UNSPECIFIED", "platform": "PLATFORM_UNSPECIFIED", "pluginType": "GEMINI"]
            var body: [String: Any] = [:]
            let configured = configuredProject()
            if let p = configured { meta["duetProject"] = p; body["cloudaicompanionProject"] = p }
            body["metadata"] = meta
            let (c1, d1) = try http("\(endpoint):loadCodeAssist", method: "POST", headers: headers, body: jsonData(body))
            guard c1 == 200 else { throw HTTPError.status(c1, String(decoding: d1, as: UTF8.self)) }
            let load = try json(d1)
            let tier = (load["paidTier"] as? [String: Any]) ?? (load["currentTier"] as? [String: Any])
            st.plan = tier?["name"] as? String
            guard let project = (load["cloudaicompanionProject"] as? String) ?? configured else {
                if let inel = (load["ineligibleTiers"] as? [[String: Any]])?.first, let code = inel["reasonCode"] as? String {
                    if code == "RESTRICTED_DASHER_USER" {
                        st.plan = "Workspace account"
                        st.note = "Quota needs a Google Cloud project: add GOOGLE_CLOUD_PROJECT=<id> to ~/.gemini/.env. Click for setup docs."
                        st.link = URL(string: "https://github.com/google-gemini/gemini-cli/blob/main/docs/get-started/authentication.md")
                    } else {
                        st.note = "Not eligible (\(code)); quota unavailable"
                    }
                } else {
                    st.note = "No Code Assist project; quota unavailable"
                }
                return st
            }
            let (c2, d2) = try http("\(endpoint):retrieveUserQuota", method: "POST", headers: headers, body: jsonData(["project": project]))
            guard c2 == 200 else { throw HTTPError.status(c2, String(decoding: d2, as: UTF8.self)) }
            let q = try json(d2)
            for b in (q["buckets"] as? [[String: Any]] ?? []) {
                guard let model = b["modelId"] as? String, let frac = b["remainingFraction"] as? Double else { continue }
                let label = model.replacingOccurrences(of: "gemini-", with: "")
                st.windows.append(UsageWindow(label: label, usedPercent: (1 - frac) * 100, resetsAt: iso(b["resetTime"] as? String)))
            }
            st.windows.sort { $0.label < $1.label }
            if st.windows.isEmpty { st.note = "No quota buckets reported" }
        } catch { st.error = "\(error)" }
        return st
    }
}

extension GeminiProvider {
    /// Same precedence Gemini CLI uses: environment, then ~/.gemini/.env.
    func configuredProject() -> String? {
        let env = ProcessInfo.processInfo.environment
        if let p = env["GOOGLE_CLOUD_PROJECT"] ?? env["GCLOUD_PROJECT"], !p.isEmpty { return p }
        if let text = try? String(contentsOfFile: home(".gemini/.env"), encoding: .utf8) {
            for line in text.split(separator: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces)
                for key in ["GOOGLE_CLOUD_PROJECT=", "GCLOUD_PROJECT="] where t.hasPrefix(key) {
                    let v = t.dropFirst(key.count).trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
                    if !v.isEmpty { return v }
                }
            }
        }
        return nil
    }
}

extension MuseProvider {
    /// Muse logs every refused model call in its session journal. When the subscription quota is
    /// exhausted the server sends no usage snapshot at all, so the 429 text is the only usage signal:
    /// "Subscription quota exhausted. Your usage window resets at 2026-11-02T00:00:00Z."
    func lastQuotaExhausted() -> (Date, Date)? {
        let root = home(".local/share/muse/sessions")
        guard let e = FileManager.default.enumerator(atPath: root) else { return nil }
        let cutoff = Date().addingTimeInterval(-3 * 86400)
        var best: (Date, Date)? = nil
        let re = try! NSRegularExpression(pattern: #"Subscription quota exhausted\. Your usage window resets at ([0-9T:\-]+Z)"#)
        while let rel = e.nextObject() as? String {
            guard rel.hasSuffix("session.jsonl") else { continue }
            let path = root + "/" + rel
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  let mod = attrs[.modificationDate] as? Date, mod > cutoff,
                  let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            let ns = text as NSString
            for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                if let d = iso(ns.substring(with: m.range(at: 1))) {
                    if best == nil || mod > best!.1 { best = (d, mod) }
                }
            }
        }
        return best
    }
}

func agoShort(_ d: Date) -> String { relative(Date().addingTimeInterval(Date().timeIntervalSince(d))) }

// MARK: - Grok Build via the CLI's own agent (JSON-RPC over stdio)
//
// `grok agent stdio` speaks the Agent Client Protocol. The TUI's /usage screen asks it for
// `_x.ai/billing`; we ask the same question, so the app never touches the auth token itself.

final class ACPClient {
    private let proc = Process()
    private let stdin = Pipe()
    private let stdout = Pipe()
    private var buffer = Data()
    private let lock = NSLock()
    private var lines: [String] = []
    private let gotLine = DispatchSemaphore(value: 0)
    private var nextID = 1

    init(binary: String, args: [String], cwd: String) throws {
        proc.executableURL = URL(fileURLWithPath: binary)
        proc.arguments = args
        proc.currentDirectoryURL = URL(fileURLWithPath: cwd)
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = FileHandle.nullDevice
        stdout.fileHandleForReading.readabilityHandler = { [weak self] h in
            guard let self = self else { return }
            // POSIX read: returns whatever is in the pipe right now and can't raise, unlike the NSFileHandle
            // readers (availableData throws an ObjC exception if the pipe is gone; read(upToCount:) blocks for a full count).
            var buf = [UInt8](repeating: 0, count: 1 << 16)
            let n = Darwin.read(h.fileDescriptor, &buf, buf.count)
            guard n > 0 else { return }
            let d = Data(buf[0..<n])
            self.lock.lock()
            self.buffer.append(d)
            while let nl = self.buffer.firstIndex(of: 0x0A) {
                let line = String(decoding: self.buffer[self.buffer.startIndex..<nl], as: UTF8.self)
                self.buffer.removeSubrange(self.buffer.startIndex...nl)
                self.lines.append(line)
                self.gotLine.signal()
            }
            self.lock.unlock()
        }
        try proc.run()
    }

    /// Sends a request and waits for the response with the same id; notifications are skipped.
    func call(_ method: String, _ params: [String: Any], timeout: TimeInterval = 25) -> [String: Any]? {
        let id = nextID; nextID += 1
        let msg: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        guard proc.isRunning else { return nil }
        // The agent can exit between the isRunning check and this write; the legacy write would abort the app.
        guard (try? stdin.fileHandleForWriting.write(contentsOf: jsonData(msg) + Data([0x0A]))) != nil else { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            lock.lock()
            let pending = lines; lines.removeAll()
            lock.unlock()
            for line in pending {
                guard let d = line.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
                if let rid = o["id"] as? Int, rid == id { return o }
            }
            if !proc.isRunning { return nil }
            _ = gotLine.wait(timeout: .now() + 0.5)
        }
        return nil
    }

    func close() {
        stdout.fileHandleForReading.readabilityHandler = nil
        try? stdin.fileHandleForWriting.close()          // EOF: the agent should exit on its own
        let deadline = Date().addingTimeInterval(2)
        while proc.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        if proc.isRunning { proc.terminate() }
        let deadline2 = Date().addingTimeInterval(2)
        while proc.isRunning && Date() < deadline2 { Thread.sleep(forTimeInterval: 0.1) }
        if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
        proc.waitUntilExit()
    }
}

struct GrokProvider: Provider {
    let name = "Grok"
    let short = "K"

    func fetch() -> ProviderStatus {
        var st = ProviderStatus(name: name, short: short, link: URL(string: "https://grok.com/?_s=usage"))
        guard let binary = Tools.find("grok", extra: [home(".grok/bin")]) else { st.missing = "The `grok` command wasn't found. Install the Grok CLI and run `grok login`."; return st }
        guard FileManager.default.fileExists(atPath: home(".grok/auth.json")) else { st.missing = "The Grok CLI is installed but not signed in. Run `grok login`."; return st }
        let client: ACPClient
        do { client = try ACPClient(binary: binary, args: ["agent", "stdio"], cwd: NSTemporaryDirectory()) }
        catch { st.error = "Couldn't start grok agent: \(error.localizedDescription)"; return st }
        defer { client.close() }

        let caps: [String: Any] = ["fs": ["readTextFile": false, "writeTextFile": false], "terminal": false]
        guard client.call("initialize", ["protocolVersion": 1, "clientCapabilities": caps,
                                         "_meta": ["clientType": "llm-usage-menubar", "clientVersion": "1.0"]]) != nil else {
            st.error = "grok agent didn't answer initialize"; return st
        }
        guard let auth = client.call("authenticate", ["methodId": "cached_token"]), auth["error"] == nil else {
            st.error = "Grok session expired; run `grok login`"; return st
        }
        let meta = (auth["result"] as? [String: Any])?["_meta"] as? [String: Any]
        st.plan = meta?["subscription_tier"] as? String

        guard let bill = client.call("_x.ai/billing", [:]), let result = bill["result"] as? [String: Any] else {
            st.error = "No billing answer from grok agent"; return st
        }
        if let tier = result["subscription_tier"] as? String, !tier.isEmpty { st.plan = tier }
        let cfg = (result["config"] as? [String: Any]) ?? [:]
        func val(_ k: String) -> Double { ((cfg[k] as? [String: Any])?["val"] as? Double) ?? (cfg[k] as? Double) ?? 0 }
        let period = cfg["currentPeriod"] as? [String: Any]
        let periodEnd = iso(period?["end"] as? String) ?? iso(cfg["billingPeriodEnd"] as? String)
        let periodType = (period?["type"] as? String ?? "").replacingOccurrences(of: "USAGE_PERIOD_TYPE_", with: "").capitalized
        // Proto-style JSON omits zero-valued fields, so a missing creditUsagePercent means 0%.
        let pct = (cfg["creditUsagePercent"] as? Double) ?? 0
        st.windows.append(UsageWindow(label: periodType.isEmpty ? "Usage limit" : "\(periodType) limit", usedPercent: pct, resetsAt: periodEnd))
        let cap = val("onDemandCap")
        if cap > 0 { st.windows.append(UsageWindow(label: "Pay-as-you-go", usedPercent: val("onDemandUsed") / cap * 100, resetsAt: periodEnd, headline: false)) }
        let prepaid = val("prepaidBalance")
        if prepaid > 0 { st.note = String(format: "Prepaid balance: %.2f", prepaid) }
        return st
    }
}

// MARK: - Muse Code (Meta) via `muse usage --json`

struct MuseProvider: Provider {
    let name = "Muse"
    let short = "M"

    func fetch() -> ProviderStatus {
        var st = ProviderStatus(name: name, short: short, link: URL(string: "https://www.meta.ai"))
        guard let muse = Tools.find("muse") else { st.missing = "The `muse` command wasn't found. Install Muse Code and sign in."; return st }
        if let ad = FileManager.default.contents(atPath: home(".config/muse/auth.json")), let ao = try? json(ad),
           let meta = (ao["providers"] as? [String: Any])?["meta"] as? [String: Any] {
            if let active = meta["subs_active"] as? Bool { st.plan = active ? "Subscribed" : "No subscription" }
        }
        let (code, out) = run(muse, ["usage", "--json"])
        guard let line = out.split(separator: "\n").last(where: { $0.hasPrefix("{") }),
              let data = String(line).data(using: .utf8), let o = try? json(data) else {
            st.error = code == 0 ? "Unexpected output from muse usage" : "muse usage failed: \(out.prefix(100))"
            return st
        }
        guard let allowance = o["allowance"] as? [String: Any] else {
            if let (reset, seen) = lastQuotaExhausted() {
                if reset > Date() {
                    st.windows.append(UsageWindow(label: "Subscription window", usedPercent: 100, resetsAt: reset))
                    st.note = "Quota exhausted — from Muse's last refused request (\(agoShort(seen)) ago)"
                    return st
                } else {
                    st.note = "Window reset \(absolute(reset)); Meta reports usage again after the next Muse prompt"
                    return st
                }
            }
            let reason = (o["reason"] as? String) ?? ""
            st.note = reason == "server_sent_no_usage"
                ? "Power Usage currently unavailable — Meta only reports it after a prompt has run in the current window. Send one message in Muse, then refresh."
                : ((o["hint"] as? String) ?? "No usage data")
            return st
        }
        // The allowance shape isn't documented; read any percent-like numbers and any reset dates.
        func walk(_ d: [String: Any], prefix: String) {
            var pct: Double? = nil
            var reset: Date? = nil
            for (k, v) in d {
                let lk = k.lowercased()
                if let n = v as? Double {
                    if lk.contains("percent") || lk.contains("pct") { pct = lk.contains("remaining") ? 100 - n : n }
                    else if lk.contains("fraction") { pct = (lk.contains("remaining") ? 1 - n : n) * 100 }
                    else if lk.contains("reset") && lk.hasSuffix("ms") { reset = Date(timeIntervalSince1970: n / 1000) }
                    else if lk.contains("reset") { reset = Date(timeIntervalSince1970: n) }
                } else if let s = v as? String, lk.contains("reset") || lk.hasSuffix("_at") || lk.hasSuffix("end") {
                    reset = iso(s) ?? reset
                } else if let sub = v as? [String: Any] {
                    walk(sub, prefix: prefix.isEmpty ? k : "\(prefix) \(k)")
                }
            }
            if pct == nil, let used = (d["used"] as? Double), let limit = (d["limit"] as? Double) ?? (d["total"] as? Double), limit > 0 {
                pct = used / limit * 100
            }
            let label: String
            switch prefix.lowercased() {
            case "": label = "Allowance"
            case "window": label = "5-hour window"
            case "weekly": label = "Weekly"
            default: label = prefix.capitalized
            }
            if let p = pct { st.windows.append(UsageWindow(label: label, usedPercent: p, resetsAt: reset, headline: label != "5-hour window")) }
        }
        let asOf = (allowance["asOfMs"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) } ?? .distantPast
        if let (reset, seen) = lastQuotaExhausted(), seen > asOf, reset > Date() {
            st.windows.append(UsageWindow(label: "Subscription window", usedPercent: 100, resetsAt: reset))
            st.note = "Quota exhausted — from Muse's last refused request (\(agoShort(seen)) ago)"
            if let plan = allowance["tier"] as? String { st.plan = plan }
            return st
        }
        walk(allowance, prefix: "")
        if let plan = (allowance["plan"] as? String) ?? (allowance["tier"] as? String) { st.plan = plan }
        if st.windows.isEmpty { st.note = "Allowance present but no percentage fields recognised" }
        return st
    }
}

// MARK: - Grok Bot (Cursor's desktop agent, sold under the Grok brand; bundle id com.anysphere.sand)
//
// The app keeps the last allowance reading it fetched from cursor.com in its own persistence store:
//   ~/Library/Application Support/Grok Bot/sand-client-persistence/<base32(key)>.blob
//   key = "sand.client.slice.account.<account>.weekly-usage.cache"
//   {schemaVersion:2, value:{kind:"present", reading:{usage:{percentUsed, nextResetMs, grokPlanLabel,
//      isSandTrial, isTeamSeat, hasNonZeroIncludedLimit, onDemand{usedCents,limitCents}}, readAtMs}, expiresAtMs}}
// Reading that file needs no network and no tokens; the figure is as fresh as the app's own last check.
struct GrokBotProvider: Provider {
    let name = "Grok Bot"
    let short = "B"
    static let appPath = "/Applications/Grok Bot.app"
    static let storeDir = home("Library/Application Support/Grok Bot/sand-client-persistence")

    func fetch() -> ProviderStatus {
        var st = ProviderStatus(name: name, short: short, link: URL(string: "https://cursor.com/dashboard"))
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: Self.storeDir) else {
            st.missing = fm.fileExists(atPath: Self.appPath) ? "Grok Bot is installed but hasn't been signed in yet. Open it once." : "The Grok Bot app isn't installed."
            return st
        }
        // One cache per signed-in account; take the most recently written.
        var best: (path: String, mtime: Date)? = nil
        for f in files where f.hasSuffix(".blob") {
            guard let key = base32Decode(String(f.dropLast(5))), key.hasSuffix(".weekly-usage.cache") else { continue }
            let path = Self.storeDir + "/" + f
            let m = ((try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date) ?? .distantPast
            if best == nil || m > best!.mtime { best = (path, m) }
        }
        guard let blob = best, let data = fm.contents(atPath: blob.path), let o = try? json(data),
              let value = o["value"] as? [String: Any] else {
            st.note = "No allowance cached yet — open Grok Bot once so it fetches its usage."
            return st
        }
        guard (value["kind"] as? String) == "present",
              let reading = value["reading"] as? [String: Any], let usage = reading["usage"] as? [String: Any] else {
            st.note = "Grok Bot has no usage reading cached (\(value["kind"] ?? "unknown state"))"
            return st
        }
        let readAt = (reading["readAtMs"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) } ?? blob.mtime
        st.fetchedAt = readAt
        var plan = (usage["grokPlanLabel"] as? String) ?? "Grok Bot"
        if usage["isSandTrial"] as? Bool == true { plan += " (trial)" }
        if usage["isTeamSeat"] as? Bool == true { plan += " · team seat" }
        st.plan = plan
        let reset = (usage["nextResetMs"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
        if let pct = usage["percentUsed"] as? Double {
            st.windows.append(UsageWindow(label: "Included usage", usedPercent: min(max(pct, 0), 100), resetsAt: reset))
        }
        var notes: [String] = []
        if let od = usage["onDemand"] as? [String: Any], let limit = od["limitCents"] as? Double, limit > 0 {
            let used = (od["usedCents"] as? Double) ?? 0
            st.windows.append(UsageWindow(label: "On-demand cap", usedPercent: min(used / limit * 100, 100), resetsAt: nil, headline: false))
            notes.append(String(format: "On-demand spend $%.2f of a $%.2f cap", used / 100, limit / 100))
        }
        // The app refreshes this reading itself; say when it stops being current.
        let running = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.anysphere.sand").isEmpty
        let expires = (value["expiresAtMs"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
        if !running {
            notes.append("Grok Bot isn't running — figures are from its last check \(agoShort(readAt)) ago and update when it's open")
            if Date().timeIntervalSince(readAt) > 3600 { st.staleSince = readAt }
        } else if let e = expires, e < Date() {
            st.staleSince = readAt
            notes.append("Grok Bot's cached reading has expired; it refreshes on its next use")
        } else {
            notes.append("From Grok Bot's own cache, read \(agoShort(readAt)) ago")
        }
        st.note = notes.joined(separator: " · ")
        return st
    }
}

/// RFC 4648 base32 (lower-case, unpadded) → UTF-8 string; Grok Bot names its persistence blobs this way.
func base32Decode(_ s: String) -> String? {
    let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567")
    var map = [Character: UInt32](); for (i, c) in alphabet.enumerated() { map[c] = UInt32(i) }
    var bits: UInt32 = 0, count = 0, out = [UInt8]()
    for ch in s.lowercased() {
        guard let v = map[ch] else { if ch == "=" { break } else { return nil } }
        bits = (bits << 5) | v; count += 5
        if count >= 8 { out.append(UInt8((bits >> UInt32(count - 8)) & 0xFF)); count -= 8 }
    }
    return String(bytes: out, encoding: .utf8)
}

// MARK: - Menu rows (fixed width so long notes never stretch the menu)

let menuWidth: CGFloat = 380
let rowInset: CGFloat = 14

enum Brand {
    static func color(_ short: String) -> NSColor {
        switch short {
        case "C": return NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1)   // Anthropic terracotta
        case "X": return NSColor.labelColor                                         // OpenAI mono
        case "G": return NSColor(srgbRed: 0.26, green: 0.52, blue: 0.96, alpha: 1)   // Gemini blue
        case "K": return NSColor.labelColor                                         // Grok mono
        case "M": return NSColor(srgbRed: 0.02, green: 0.40, blue: 0.87, alpha: 1)   // Meta blue
        case "B": return NSColor.labelColor                                         // Cursor mono (Grok Bot)
        default: return .secondaryLabelColor
        }
    }

    /// Vendor marks bundled as SVG (Contents/Resources/icons/<short>.svg), used as alpha masks.
    static var marks: [String: NSImage] = {
        var out: [String: NSImage] = [:]
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("icons") else { return out }
        for short in ["C", "X", "G", "K", "M", "B"] {
            if let img = NSImage(contentsOf: dir.appendingPathComponent("\(short).svg")) { img.isTemplate = true; out[short] = img }
        }
        return out
    }()

    /// Draws a mark tinted with a colour, resolved at draw time so it follows light/dark appearance.
    static func mark(_ short: String, color: NSColor, size: CGFloat) -> NSImage? {
        guard let src = marks[short] else { return nil }
        return NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            color.setFill(); rect.fill()
            src.draw(in: rect, from: .zero, operation: .destinationIn, fraction: 1)
            return true
        }
    }
    static func usage(_ pct: Double) -> NSColor {
        if pct >= 90 { return .systemRed }
        if pct >= 75 { return .systemOrange }
        return .controlAccentColor
    }
}

func relative(_ d: Date) -> String {
    let secs = Int(d.timeIntervalSinceNow)
    if secs <= 0 { return "now" }
    let m = secs / 60, h = secs / 3600, days = secs / 86400
    if secs < 3600 { return "\(m)m" }
    if secs < 86400 { return "\(h)h \((secs % 3600) / 60)m" }
    return "\(days)d \((secs % 86400) / 3600)h"
}

func absolute(_ d: Date) -> String {
    let f = DateFormatter(); f.dateFormat = "EEE d MMM, HH:mm"; return f.string(from: d)
}

/// A row that opens a link when clicked and closes the menu.
class LinkRowView: NSView {
    var link: URL?
    var highlighted = false { didSet { needsDisplay = true } }
    override func mouseDown(with event: NSEvent) {
        guard let link = link else { return }
        enclosingMenuItem?.menu?.cancelTracking()
        NSWorkspace.shared.open(link)
    }
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        if link != nil {
            addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
        }
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { highlighted = true }
    override func mouseExited(with event: NSEvent) { highlighted = false }
    override func resetCursorRects() { if link != nil { addCursorRect(bounds, cursor: .pointingHand) } }
}

final class HeaderRowView: LinkRowView {
    let status: ProviderStatus
    init(_ st: ProviderStatus) {
        status = st
        super.init(frame: NSRect(x: 0, y: 0, width: menuWidth, height: 28))
        link = st.link
        toolTip = st.link.map { "Open \($0.host ?? "usage page")" }
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        if highlighted {
            NSColor.labelColor.withAlphaComponent(0.06).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 1), xRadius: 5, yRadius: 5).fill()
        }
        if let m = Brand.mark(status.short, color: Brand.color(status.short), size: 15) {
            m.draw(in: NSRect(x: rowInset, y: 6, width: 15, height: 15), from: .zero, operation: .sourceOver, fraction: 1)
        } else {
            Brand.color(status.short).setFill()
            NSBezierPath(ovalIn: NSRect(x: rowInset + 3, y: 10, width: 8, height: 8)).fill()
        }
        let name = NSAttributedString(string: status.name, attributes: [.font: NSFont.boldSystemFont(ofSize: 13), .foregroundColor: NSColor.labelColor])
        name.draw(at: NSPoint(x: rowInset + 21, y: 6))
        var x = rowInset + 21 + name.size().width + 7
        if let plan = status.plan {
            let p = NSAttributedString(string: plan, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
            p.draw(at: NSPoint(x: x, y: 7)); x += p.size().width
        }
        let right: NSAttributedString
        if let since = status.staleSince, status.error == nil {
            right = NSAttributedString(string: "stale · \(relative(Date().addingTimeInterval(Date().timeIntervalSince(since)))) old".replacingOccurrences(of: "now old", with: "just now"), attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.systemOrange])
        } else if status.error != nil {
            right = NSAttributedString(string: "⚠︎ needs attention", attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.systemOrange])
        } else if let h = status.headline {
            right = NSAttributedString(string: String(format: "%.0f%% %@", shownPercent(h), percentWord), attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium), .foregroundColor: Brand.usage(h)])
        } else {
            right = NSAttributedString(string: "no data", attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.tertiaryLabelColor])
        }
        right.draw(at: NSPoint(x: menuWidth - rowInset - right.size().width, y: 7))
    }
}

final class UsageRowView: NSView {
    let usage: UsageWindow
    init(_ w: UsageWindow) {
        usage = w
        super.init(frame: NSRect(x: 0, y: 0, width: menuWidth, height: 24))
        if let r = w.resetsAt { toolTip = "Resets \(absolute(r))" }
    }
    required init?(coder: NSCoder) { fatalError() }

    static func resetText(_ d: Date) -> String { "↻ " + relative(d) }

    override func draw(_ dirtyRect: NSRect) {
        let label: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor]
        let num: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.labelColor]
        let dim: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor]

        (usage.label as NSString).draw(in: NSRect(x: rowInset + 21, y: 4, width: 111, height: 16), withAttributes: label)

        let barRect = NSRect(x: rowInset + 136, y: 9, width: 110, height: 6)
        NSColor.labelColor.withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: barRect, xRadius: 3, yRadius: 3).fill()
        let pct = max(0, min(100, usage.usedPercent))
        let shown = shownPercent(pct)
        var fill = barRect; fill.size.width = max(shown > 0 ? 6 : 0, barRect.width * CGFloat(shown / 100))
        if fill.width > 0 {
            Brand.usage(pct).setFill()
            NSBezierPath(roundedRect: fill, xRadius: 3, yRadius: 3).fill()
        }

        let pctStr = NSAttributedString(string: String(format: "%.0f%%", shown), attributes: num)
        pctStr.draw(at: NSPoint(x: rowInset + 254 + (36 - pctStr.size().width), y: 4))

        if let r = usage.resetsAt {
            let t = NSAttributedString(string: Self.resetText(r), attributes: dim)
            t.draw(at: NSPoint(x: menuWidth - rowInset - t.size().width, y: 5))
        }
    }
}

final class NoteRowView: LinkRowView {
    let text: NSAttributedString
    let textRect: NSRect
    init(_ note: String, color: NSColor = .secondaryLabelColor, link: URL? = nil) {
        let para = NSMutableParagraphStyle(); para.lineBreakMode = .byWordWrapping
        text = NSAttributedString(string: note, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: color, .paragraphStyle: para])
        let width = menuWidth - rowInset * 2 - 21
        let h = ceil(text.boundingRect(with: NSSize(width: width, height: 200), options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
        textRect = NSRect(x: rowInset + 21, y: 4, width: width, height: h)
        super.init(frame: NSRect(x: 0, y: 0, width: menuWidth, height: h + 8))
        self.link = link
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        if highlighted {
            NSColor.labelColor.withAlphaComponent(0.06).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 1), xRadius: 5, yRadius: 5).fill()
        }
        text.draw(with: textRect, options: [.usesLineFragmentOrigin, .usesFontLeading])
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    let providers: [Provider] = allProviders
    var statuses: [ProviderStatus] = []
    var lastUpdate: Date?
    var refreshing = false
    var timer: Timer?
    var backoffUntil: [String: Date] = [:]     // provider short -> don't refetch before this

    func applicationDidFinishLaunching(_ n: Notification) {
        item.autosaveName = statusAutosaveName
        item.button?.image = NSImage(systemSymbolName: "gauge.with.needle", accessibilityDescription: "LLM usage")
        item.button?.imagePosition = .imageLeading
        item.button?.title = "…"
        menu.delegate = self
        item.menu = menu
        rebuildMenu()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func menuWillOpen(_ menu: NSMenu) {
        if let t = lastUpdate, Date().timeIntervalSince(t) < 60 { return }
        refresh()
    }

    @objc func refresh() {
        guard !refreshing else { return }
        refreshing = true
        let provs = providers
        let previous = statuses
        let skip = Set(backoffUntil.filter { $0.value > Date() }.keys)
        DispatchQueue.global(qos: .utility).async {
            let group = DispatchGroup()
            var results = [ProviderStatus?](repeating: nil, count: provs.count)
            let lock = NSLock()
            for (i, p) in provs.enumerated() {
                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    // While a provider is backing off after a 429, reuse what we last showed.
                    let r = skip.contains(p.short) ? (previous.first { $0.short == p.short } ?? p.fetch()) : p.fetch()
                    lock.lock(); results[i] = r; lock.unlock()
                    group.leave()
                }
            }
            group.wait()
            DispatchQueue.main.async {
                self.statuses = results.compactMap { $0 }.map { self.merge($0) }
                self.lastUpdate = Date()
                self.refreshing = false
                self.updateTitle()
                self.rebuildMenu()
                if !UserDefaults.standard.bool(forKey: "setupShown") {
                    UserDefaults.standard.set(true, forKey: "setupShown")
                    self.showSetup()
                }
            }
        }
    }

    /// A failed refresh keeps the previous numbers on screen (marked stale) instead of blanking the row,
    /// and a 429 puts that provider on a 15-minute backoff so we stop making it worse.
    func merge(_ fresh: ProviderStatus) -> ProviderStatus {
        guard let err = fresh.error, let old = statuses.first(where: { $0.short == fresh.short }), !old.windows.isEmpty else { return fresh }
        if err.contains("429") { backoffUntil[fresh.short] = Date().addingTimeInterval(15 * 60) }
        var kept = old
        kept.staleSince = old.staleSince ?? old.fetchedAt
        kept.error = nil
        kept.note = "Refresh failed (\(err.prefix(60))) — showing data from \(agoText(kept.staleSince!))"
        return kept
    }

    func updateTitle() {
        let title = NSMutableAttributedString()
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        var worst: Double = 0
        // Compact mode shows only the provider nearest its limit (plus any that needs attention) so the
        // item still fits beside a MacBook notch; the dropdown and tooltip always have the full list.
        let shown: [ProviderStatus] = compact
            ? [statuses.max { ($0.headline ?? -1) < ($1.headline ?? -1) }].compactMap { $0 } + statuses.filter { $0.error != nil && $0.headline == nil }
            : statuses
        for s in shown {
            guard s.missing == nil, s.headline != nil || s.error != nil else { continue }   // providers without numbers stay out of the bar
            if title.length > 0 { title.append(NSAttributedString(string: "  ", attributes: [.font: font])) }
            if let m = Brand.mark(s.short, color: .labelColor, size: 11) {
                let att = NSTextAttachment(); att.image = m
                att.bounds = NSRect(x: 0, y: -1.5, width: 11, height: 11)
                title.append(NSAttributedString(attachment: att))
                title.append(NSAttributedString(string: " ", attributes: [.font: NSFont.systemFont(ofSize: 4)]))
            } else {
                title.append(NSAttributedString(string: s.short, attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
            }
            if let h = s.headline {
                worst = max(worst, h)
                let color: NSColor = h >= 90 ? .systemRed : (h >= 75 ? .systemOrange : .labelColor)
                title.append(NSAttributedString(string: String(format: "%.0f", shownPercent(h)), attributes: [.font: font, .foregroundColor: color]))
            } else {
                title.append(NSAttributedString(string: "!", attributes: [.font: font, .foregroundColor: NSColor.systemOrange]))
            }
        }
        item.button?.attributedTitle = title.length > 0 ? title : NSAttributedString(string: "LLM")
        let step = worst >= 90 ? "100" : worst >= 67 ? "67" : worst >= 33 ? "50" : worst > 0 ? "33" : "0"
        item.button?.image = NSImage(systemSymbolName: "gauge.with.dots.needle.bottom.\(step)percent", accessibilityDescription: "LLM usage")
            ?? NSImage(systemSymbolName: "gauge.with.needle", accessibilityDescription: "LLM usage")
        item.button?.toolTip = statuses.filter { $0.missing == nil }.map { s in
            s.headline.map { String(format: "%@: %.0f%% %@", s.name, shownPercent($0), percentWord) } ?? "\(s.name): no data"
        }.joined(separator: "\n")

        logPlacement()
    }

    /// Writes where macOS put the status item to ~/Library/Logs/LLMUsage.log, for diagnosing a hidden item.
    func logPlacement() {
        var lines = ["\(Date()) visible=\(item.isVisible) length=\(item.length) titleWidth=\(item.button?.attributedTitle.size().width ?? -1) agent=\(launchedByAgent) xpc=\(ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] ?? "-")"]
        if let w = item.button?.window {
            lines.append("  item window frame=\(w.frame) onScreen=\(w.screen?.localizedName ?? "none") occluded=\(!w.occlusionState.contains(.visible))")
        } else { lines.append("  item has no window") }
        for sc in NSScreen.screens {
            var l = "  screen \(sc.localizedName) frame=\(sc.frame)"
            if #available(macOS 12.0, *) {
                l += " notchLeft=\(sc.auxiliaryTopLeftArea.map { "\($0)" } ?? "-") notchRight=\(sc.auxiliaryTopRightArea.map { "\($0)" } ?? "-")"
            }
            lines.append(l)
        }
        appendLog(lines.joined(separator: "\n") + "\n")
    }

    /// Appends to ~/Library/Logs/LLMUsage.log. Diagnostics must never take the app down: only the throwing
    /// FileHandle APIs are used (the legacy ones raise ObjC exceptions Swift can't catch — that crashed us once),
    /// every failure is swallowed, and the file is trimmed when it passes ~256 KB.
    func appendLog(_ text: String) {
        let path = home("Library/Logs/LLMUsage.log")
        let fm = FileManager.default
        guard let data = text.data(using: .utf8) else { return }
        do {
            if let size = (try? fm.attributesOfItem(atPath: path))?[.size] as? Int, size > 256 * 1024,
               let old = fm.contents(atPath: path) {
                try old.suffix(64 * 1024).write(to: URL(fileURLWithPath: path), options: .atomic)
            }
            if !fm.fileExists(atPath: path) { try data.write(to: URL(fileURLWithPath: path), options: .atomic); return }
            let h = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
            defer { try? h.close() }
            try h.seekToEnd()
            try h.write(contentsOf: data)
        } catch {
            // Logging is best-effort.
        }
    }

    func rebuildMenu() {
        menu.removeAllItems()
        if statuses.isEmpty {
            menu.addItem(withTitle: refreshing ? "Loading usage…" : "No data yet", action: nil, keyEquivalent: "")
        }
        let missing = statuses.filter { $0.missing != nil }
        if !statuses.isEmpty && missing.count == statuses.count {
            let mi = NSMenuItem(); mi.view = NoteRowView("None of the supported AI tools are set up on this Mac yet. Choose Setup Check below to see what LLM Usage looks for."); menu.addItem(mi)
            menu.addItem(.separator())
        }
        for s in statuses where s.missing == nil {
            let header = NSMenuItem(); header.view = HeaderRowView(s); menu.addItem(header)
            for w in s.windows { let mi = NSMenuItem(); mi.view = UsageRowView(w); menu.addItem(mi) }
            if let e = s.error { let mi = NSMenuItem(); mi.view = NoteRowView("⚠︎ " + e, color: .systemOrange, link: s.link); menu.addItem(mi) }
            if let n = s.note { let mi = NSMenuItem(); mi.view = NoteRowView(n, link: s.link); menu.addItem(mi) }
            menu.addItem(.separator())
        }
        let u = NSMenuItem(title: refreshing ? "Refreshing…" : (lastUpdate.map { "Updated \(agoText($0))" } ?? "Not updated yet"), action: nil, keyEquivalent: "")
        u.isEnabled = false
        menu.addItem(u)
        let r = NSMenuItem(title: "Refresh Now", action: #selector(refresh), keyEquivalent: "r")
        r.target = self
        menu.addItem(r)
        let setup = NSMenuItem(title: missing.isEmpty ? "Setup Check…" : "Setup Check… (\(missing.count) not set up)", action: #selector(showSetup), keyEquivalent: "")
        setup.target = self
        setup.toolTip = missing.isEmpty ? "What LLM Usage found on this Mac" : "Not set up: " + missing.map(\.name).joined(separator: ", ")
        menu.addItem(setup)
        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.toolTip = "Starts at login and relaunches automatically if it ever crashes"
        login.target = self
        login.state = LoginAgent.isEnabled ? .on : .off
        menu.addItem(login)
        let c = NSMenuItem(title: "Compact Menu Bar", action: #selector(toggleCompact), keyEquivalent: "")
        c.target = self
        c.state = compact ? .on : .off
        c.toolTip = "Show only the provider closest to its limit, so the item fits beside the notch"
        menu.addItem(c)
        let sr = NSMenuItem(title: "Show Remaining", action: #selector(toggleRemaining), keyEquivalent: "")
        sr.target = self
        sr.state = showRemaining ? .on : .off
        sr.toolTip = "Show what's left instead of what's used, like the vendors' own usage screens"
        menu.addItem(sr)
        let rt = NSMenuItem(title: "Renew Expired Sign-ins", action: #selector(toggleRefresh), keyEquivalent: "")
        rt.target = self
        rt.state = allowTokenRefresh ? .on : .off
        rt.toolTip = "Off: read-only. On: renews Claude Code and Codex sign-ins when they expire and saves them back"
        menu.addItem(rt)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit LLM Usage", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    func agoText(_ d: Date) -> String {
        let secs = Int(Date().timeIntervalSince(d))
        if secs < 60 { return "just now" }
        if secs < 3600 { return "\(secs / 60) min ago" }
        return "at " + { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: d) }()
    }

    @objc func openLink(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { NSWorkspace.shared.open(url) }
    }

    /// Menu bar shows one provider (the most used) instead of all of them. On by default: six logos don't fit beside a notch.
    var compact: Bool {
        get { UserDefaults.standard.object(forKey: "compact") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "compact") }
    }
    @objc func toggleCompact() { compact.toggle(); updateTitle(); rebuildMenu() }

    /// What was found on this Mac, one line per provider. Also printed by `--setup`.
    static func setupReport(_ statuses: [ProviderStatus]) -> String {
        var lines: [String] = []
        for s in statuses {
            if let m = s.missing { lines.append("○  \(s.name): not set up. \(m)") }
            else if let e = s.error { lines.append("⚠︎  \(s.name): found, but \(e)") }
            else if s.windows.isEmpty { lines.append("●  \(s.name): found\(s.plan.map { " (\($0))" } ?? ""), no usage figures yet. \(s.note ?? "")") }
            else { lines.append("✓  \(s.name): working\(s.plan.map { " (\($0))" } ?? "")") }
        }
        let found = statuses.filter { $0.missing == nil }.count
        lines.append("")
        lines.append(found == 0
            ? "LLM Usage shows usage for AI coding tools that are signed in on this Mac. Set one up, then choose Refresh Now."
            : "Tools that aren't set up are left out of the menu. LLM Usage only reads what these tools already keep on this Mac; by default it changes nothing.")
        return lines.joined(separator: "\n")
    }

    @objc func showSetup() {
        let a = NSAlert()
        a.messageText = "LLM Usage setup check"
        a.informativeText = statuses.isEmpty ? "Still loading. Try again in a few seconds." : Self.setupReport(statuses)
        a.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }

    @objc func toggleRemaining() {
        UserDefaults.standard.set(!showRemaining, forKey: "showRemaining")
        updateTitle(); rebuildMenu()
    }

    @objc func toggleRefresh() {
        if !allowTokenRefresh {
            let a = NSAlert()
            a.messageText = "Renew expired sign-ins?"
            a.informativeText = "LLM Usage will renew Claude Code and Codex sign-ins when they expire, using each tool's own sign-in service, and save the new tokens where that tool keeps them. Those tokens are single-use, so if the tool renews at the same moment you may have to sign in to it again. Leave this off to keep LLM Usage strictly read-only."
            a.addButton(withTitle: "Turn On"); a.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        UserDefaults.standard.set(!allowTokenRefresh, forKey: "refreshTokens")
        rebuildMenu(); refresh()
    }

    @objc func toggleLogin() {
        do {
            if LoginAgent.isEnabled { LoginAgent.disable() } else { try LoginAgent.enable() }
        } catch {
            let a = NSAlert(); a.messageText = "Couldn't change login item"; a.informativeText = "\(error)"; a.runModal()
        }
        rebuildMenu()
    }
}

if let i = CommandLine.arguments.firstIndex(of: "--login"), i + 1 < CommandLine.arguments.count {
    // `--login on|off`: toggle Launch at Login from the command line.
    do {
        switch CommandLine.arguments[i + 1] {
        case "on": try LoginAgent.enable()
        case "off": LoginAgent.disable()
        default: break   // "status"
        }
        print("Launch at Login: \(LoginAgent.isEnabled ? "enabled" : "disabled"), launchd job \(LoginAgent.isLoaded ? "loaded" : "not loaded")")
        exit(0)
    } catch { print("Failed: \(error)"); exit(1) }
}

if let i = CommandLine.arguments.firstIndex(of: "--render-marks"), i + 1 < CommandLine.arguments.count {
    // Writes each bundled mark as a 64px PNG (black on transparent) for a visual check.
    let dir = CommandLine.arguments[i + 1]
    print("marks loaded: \(Brand.marks.keys.sorted())")
    for (short, _) in Brand.marks {
        guard let img = Brand.mark(short, color: .black, size: 64),
              let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { print("\(short): render failed"); continue }
        try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("mark-\(short).png"))
    }
    exit(0)
}

/// Display order in the menu bar and the dropdown.
let allProviders: [Provider] = [ClaudeProvider(), CodexProvider(), GeminiProvider(), GrokProvider(), GrokBotProvider(), MuseProvider()]

if CommandLine.arguments.contains("--setup") {
    // Headless version of the Setup Check window.
    print(AppDelegate.setupReport(allProviders.map { $0.fetch() }))
    exit(0)
}

if CommandLine.arguments.contains("--print") {
    // Headless check: fetch every provider (or just the letters/names given, e.g. `--print B M`) and print what the menu would show.
    let only = Set(CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("--") }.map { $0.uppercased() })
    for p in allProviders where only.isEmpty || only.contains(p.short.uppercased()) || only.contains(p.name.uppercased()) {
        let s = p.fetch()
        print("[\(s.name)] plan=\(s.plan ?? "-") headline=\(s.headline.map { String(format: "%.0f%%", $0) } ?? "-")")
        for w in s.windows { print("   \(w.label): \(String(format: "%.0f", w.usedPercent))% \(w.resetsAt.map(UsageRowView.resetText) ?? "")") }
        if let m = s.missing { print("   not set up: \(m)") }
        if let e = s.error { print("   ERROR: \(e)") }
        if let n = s.note { print("   note: \(n)") }
    }
    exit(0)
}

// macOS fills the menu bar from the right and drops whatever doesn't fit beside a MacBook notch; a new item
// lands leftmost, i.e. first to go. Claim a slot well inside the right-hand area unless the user has dragged
// the item somewhere themselves (⌘-drag), which macOS stores under this same key.
/// "Launch at Login" is a classic launchd agent at ~/Library/LaunchAgents/<bundle id>.plist: RunAtLoad
/// starts it at login and KeepAlive relaunches it after a crash (a clean Quit, exit 0, stays quit).
/// An SMAppService agent was tried first, but launchd pins those to a code requirement that, for an ad-hoc
/// signed app, is the binary's hash: every rebuild made launchd refuse to spawn it (exit 78, EX_CONFIG) in a loop.
/// Set in Info.plist by build.sh (BUNDLE_ID); also the launchd label and the defaults domain.
let bundleID = Bundle.main.bundleIdentifier ?? "llm-usage"

enum LoginAgent {
    static let label = bundleID
    static let plistPath = home("Library/LaunchAgents/\(label).plist")
    static var domain: String { "gui/\(getuid())" }
    static var target: String { "\(domain)/\(label)" }
    static var isEnabled: Bool { FileManager.default.fileExists(atPath: plistPath) }
    static var isLoaded: Bool { run("/bin/launchctl", ["print", target]).0 == 0 }
    @discardableResult static func launchctl(_ args: [String]) -> (Int32, String) { run("/bin/launchctl", args) }

    static func enable() throws {
        guard let exe = Bundle.main.executablePath else { return }
        let plist: [String: Any] = [
            "Label": label, "ProgramArguments": [exe], "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false], "ProcessType": "Interactive", "ThrottleInterval": 5,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try FileManager.default.createDirectory(atPath: home("Library/LaunchAgents"), withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: plistPath), options: .atomic)
        launchctl(["enable", target])
        if isLoaded { launchctl(["kickstart", target]) }
        else {
            let (c, out) = launchctl(["bootstrap", domain, plistPath])
            if c != 0 { throw NSError(domain: "LoginAgent", code: Int(c), userInfo: [NSLocalizedDescriptionKey: out.trimmingCharacters(in: .whitespacesAndNewlines)]) }
        }
    }
    /// Stops launching at login and crash-relaunching. The job stays loaded until logout, so this copy keeps running.
    static func disable() {
        try? FileManager.default.removeItem(atPath: plistPath)
        launchctl(["disable", target])
    }
}
let launchedByAgent = ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == LoginAgent.label
let headlessRun = ["--print", "--setup", "--login", "--render-marks"].contains { CommandLine.arguments.contains($0) }

// Single instance. The launchd-managed copy is the one that must survive, so it displaces any other;
// a manual launch defers to a running copy. Exit 0 so launchd doesn't count it as a crash.
if !headlessRun {
    let me = ProcessInfo.processInfo.processIdentifier
    let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).filter { $0.processIdentifier != me }
    if !others.isEmpty {
        if launchedByAgent { others.forEach { $0.terminate() }; Thread.sleep(forTimeInterval: 0.5) }
        else { exit(0) }
    }
}

// A manual launch (e.g. `open` after a rebuild) while the agent is enabled hands over to a launchd-managed copy,
// so the keep-alive covers whatever is running. Rate-limited in case the agent detection is ever wrong.
if !launchedByAgent && !headlessRun && LoginAgent.isEnabled {
    let key = "lastAgentHandover"
    let last = UserDefaults.standard.object(forKey: key) as? Date ?? .distantPast
    if Date().timeIntervalSince(last) > 600 {
        UserDefaults.standard.set(Date(), forKey: key)
        if LoginAgent.isLoaded { LoginAgent.launchctl(["kickstart", LoginAgent.target]) } else { try? LoginAgent.enable() }
    }
}

let statusAutosaveName = "LLMUsage"
let positionKey = "NSStatusItem Preferred Position \(statusAutosaveName)"
if UserDefaults.standard.object(forKey: positionKey) == nil { UserDefaults.standard.set(330, forKey: positionKey) }

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
