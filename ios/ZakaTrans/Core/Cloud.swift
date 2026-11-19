import Foundation
import CryptoKit
import UIKit

/// 与自家后端通信。豆包凭据只在服务端，客户端连上游的资格都没有。
///
/// 每个请求都带签名：method + path + reqid + ts + nonce + body hash，
/// 用账号 token 做 HMAC。改一个字节签名就对不上，重发一次也会被 nonce 拦掉。
@MainActor
final class Cloud: ObservableObject {
    static let shared = Cloud()

    private override init() {
        super.init()
        // 冷启动第一帧就把登录态认下来：本地有 token 就直接进主界面，
        // 不再先显示一个转圈的检查页等异步结果。
        loggedIn = !(Keychain.get("account_token") ?? "").isEmpty
    }

    static let baseURL = "https://api.xingyans.com"

    /// 余额对内是 token，对外全部显示积分（1 元 = 10 积分，1400 积分 = 100 万 token）
    @Published private(set) var balanceTokens: Int64 = 0
    @Published private(set) var balanceCredits: Double = 0
    @Published private(set) var todayUsedCredits: Double = 0
    @Published private(set) var loggedIn = false
    @Published private(set) var lastError: String?

    @Published private(set) var profile: Profile?

    var minStartCredits: Double = 2.8
    private var minStartTokens: Int64 = 2000

    struct Profile: Codable, Equatable {
        var id: String
        var email: String
        var display_name: String
        var provider: String
        var created_at: Int64

        var displayName: String {
            if !display_name.isEmpty { return display_name }
            if !email.isEmpty { return String(email.split(separator: "@").first ?? "") }
            return "Zaka 用户"
        }
        var initials: String {
            let n = displayName
            return n.isEmpty ? "Z" : String(n.prefix(1)).uppercased()
        }
    }

    private var token: String {
        get { Keychain.get("account_token") ?? "" }
        set { Keychain.set(newValue, for: "account_token") }
    }

    private(set) var accountID: String = Keychain.get("account_id") ?? ""

    var hasAccount: Bool { !token.isEmpty }

    // MARK: - 启动

    /// 已登录就直接刷新；没登录就停在登录页，不再偷偷用设备号建号。
    func bootstrap() async {
        guard !token.isEmpty else {
            loggedIn = false
            return
        }
        // 冷启动不等网络：本地有 token 就先认成已登录，界面立刻出来，
        // 余额/资料在后面补。之前是等 /v1/me 回来才放行，弱网下要干等好几秒。
        loggedIn = true
        // 余额/资料在后面补，不挡界面
        Task { _ = await self.refresh() }
    }

    // MARK: - Sign in with Apple

    /// 用苹果返回的 identityToken 换我们自己的账号 token。
    /// 老设备号账号会在服务端自动绑定，余额一分不动。
    func loginWithApple(identityToken: String, fullName: String?) async throws {
        var body: [String: Any] = [
            "identity_token": identityToken,
            "device_id": Keychain.deviceID(),
            "platform": "ios",
            "model": UIDevice.current.model,
            "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0",
        ]
        if let fullName, !fullName.isEmpty { body["full_name"] = fullName }

        let data = try await rawRequest(path: "/v1/auth/apple", body: body, auth: false)
        guard let dict = data as? [String: Any],
              let t = dict["token"] as? String else {
            throw CloudError.server("登录失败，请重试")
        }
        token = t
        accountID = dict["account_id"] as? String ?? ""
        Keychain.set(accountID, for: "account_id")
        balanceTokens = (dict["balance"] as? NSNumber)?.int64Value ?? 0
        balanceCredits = (dict["balance_credits"] as? NSNumber)?.doubleValue ?? 0
        if let p = dict["profile"] as? [String: Any] {
            profile = Profile(
                id: p["id"] as? String ?? accountID,
                email: p["email"] as? String ?? "",
                display_name: p["display_name"] as? String ?? "",
                provider: p["provider"] as? String ?? "apple",
                created_at: (p["created_at"] as? NSNumber)?.int64Value ?? 0
            )
        }
        loggedIn = true
        lastError = nil
        // 引擎层（ObjC）要拿它连识别服务
        UserDefaults.standard.set(t, forKey: "zt_account_token")
        UserDefaults.standard.set(Self.baseURL, forKey: "zt_base_url")
        await refresh()
    }

    func logout() {
        token = ""
        Keychain.set("", for: "account_token")
        UserDefaults.standard.removeObject(forKey: "zt_account_token")
        accountID = ""
        profile = nil
        balanceTokens = 0
        balanceCredits = 0
        loggedIn = false
    }

    // MARK: - 余额

    @discardableResult
    func refresh() async -> Bool {
        guard !token.isEmpty else { return false }
        do {
            let data = try await request(path: "/v1/me")
            if let d = data as? [String: Any] {
                balanceTokens = (d["balance"] as? NSNumber)?.int64Value ?? balanceTokens
                balanceCredits = (d["balance_credits"] as? NSNumber)?.doubleValue ?? balanceCredits
                todayUsedCredits = (d["today_used"] as? NSNumber)?.doubleValue ?? 0
                minStartTokens = (d["min_start_balance"] as? NSNumber)?.int64Value ?? 2000
                minStartCredits = (d["min_start_credits"] as? NSNumber)?.doubleValue ?? 2.8
                if let p = d["profile"] as? [String: Any] {
                    profile = Profile(
                        id: p["id"] as? String ?? accountID,
                        email: p["email"] as? String ?? "",
                        display_name: p["display_name"] as? String ?? "",
                        provider: p["provider"] as? String ?? "device",
                        created_at: (p["created_at"] as? NSNumber)?.int64Value ?? 0
                    )
                }
                loggedIn = true
                lastError = nil
                return true
            }
        } catch {
            lastError = error.localizedDescription
        }
        return false
    }

    // MARK: - 云端偏好（字幕样式）

    func loadPrefs() async -> [String: Any]? {
        guard !token.isEmpty else { return nil }
        do {
            let data = try await request(path: "/v1/prefs")
            return (data as? [String: Any])?["data"] as? [String: Any]
        } catch {
            return nil
        }
    }

    @discardableResult
    func savePrefs(_ prefs: [String: Any]) async -> Bool {
        guard !token.isEmpty else { return false }
        do {
            _ = try await request(path: "/v1/prefs", body: prefs, method: "PUT")
            return true
        } catch {
            return false
        }
    }

    // MARK: - 使用记录

    struct UsageSession: Identifiable {
        let id: String
        let startedAt: Date
        let endedAt: Date?
        let audioMs: Int64
        let upstreamTokens: Int64
        let billedTokens: Int64
        let endReason: String
        let summary: String?

        var credits: Double { Double(billedTokens) * 1400.0 / 1_000_000.0 }
        var creditsText: String { Format.credits(credits) }
        var durationText: String { Format.duration(audioMs) }
        var hasSummary: Bool { !(summary ?? "").isEmpty }

        var reasonText: String {
            switch endReason {
            case "client_finish": return "主动停止"
            case "client_closed": return "连接断开"
            case "insufficient_balance": return "积分用完"
            case "session_cap": return "达单次上限"
            case "session_timeout": return "达时长上限"
            case "upstream_failed", "upstream_send_failed": return "识别服务异常"
            case "audio_flood": return "异常音频已拦截"
            case "": return "已结束"
            default: return endReason
            }
        }
    }

    func sessions(limit: Int = 100) async -> [UsageSession] {
        guard !token.isEmpty else { return [] }
        do {
            let data = try await request(path: "/v1/sessions", query: "limit=\(limit)")
            guard let d = data as? [String: Any], let items = d["items"] as? [[String: Any]] else { return [] }
            return items.compactMap { row in
                guard let sid = row["id"] as? String else { return nil }
                let start = (row["created_at"] as? NSNumber)?.doubleValue ?? 0
                let end = (row["ended_at"] as? NSNumber)?.doubleValue ?? 0
                return UsageSession(
                    id: sid,
                    startedAt: Date(timeIntervalSince1970: start),
                    endedAt: end > 0 ? Date(timeIntervalSince1970: end) : nil,
                    audioMs: (row["audio_ms"] as? NSNumber)?.int64Value ?? 0,
                    upstreamTokens: (row["upstream_tokens"] as? NSNumber)?.int64Value ?? 0,
                    billedTokens: (row["billed_tokens"] as? NSNumber)?.int64Value ?? 0,
                    endReason: row["end_reason"] as? String ?? "",
                    summary: row["summary"] as? String
                )
            }
        } catch {
            return []
        }
    }

    // MARK: - 对话记录 / 总结

    struct TranscriptLine: Identifiable {
        let id: Int
        let seq: Int64
        let source: String
        let trans: String
        let at: Date
    }

    struct SessionDetail {
        var lines: [TranscriptLine]
        var summary: String
    }

    func transcript(sessionID: String) async throws -> SessionDetail {
        let data = try await request(path: "/v1/sessions/\(sessionID)/transcript")
        guard let d = data as? [String: Any] else { throw CloudError.badResponse }
        let raw = d["items"] as? [[String: Any]] ?? []
        var lines: [TranscriptLine] = []
        for (i, row) in raw.enumerated() {
            lines.append(TranscriptLine(
                id: i,
                seq: (row["seq"] as? NSNumber)?.int64Value ?? 0,
                source: row["source"] as? String ?? "",
                trans: row["trans"] as? String ?? "",
                at: Date(timeIntervalSince1970: (row["at"] as? NSNumber)?.doubleValue ?? 0)
            ))
        }
        return SessionDetail(lines: lines, summary: d["summary"] as? String ?? "")
    }

    /// 生成（或取回）这一场的 AI 总结。服务端已生成过会直接返回，不重复花钱。
    func summarize(sessionID: String) async throws -> String {
        let data = try await request(path: "/v1/sessions/\(sessionID)/summary", body: [:], method: "POST")
        guard let d = data as? [String: Any], let s = d["summary"] as? String, !s.isEmpty else {
            throw CloudError.server("总结没生成出来，稍后再试")
        }
        return s
    }

    // MARK: - 内购

    func verifyPurchase(jws: String) async throws -> (credited: Int64, creditedCredits: Double, balance: Int64, balanceCredits: Double) {
        let body: [String: Any] = ["jws": jws]
        let data = try await request(path: "/v1/iap/verify", body: body)
        guard let d = data as? [String: Any] else { throw CloudError.badResponse }
        let credited = (d["credited"] as? NSNumber)?.int64Value ?? 0
        let cr = (d["credited_credits"] as? NSNumber)?.doubleValue ?? 0
        let bal = (d["balance"] as? NSNumber)?.int64Value ?? balanceTokens
        let balCr = (d["balance_credits"] as? NSNumber)?.doubleValue ?? balanceCredits
        balanceTokens = bal
        balanceCredits = balCr
        return (credited, cr, bal, balCr)
    }

    // MARK: - 请求

    enum CloudError: LocalizedError {
        case badResponse
        case server(String)
        var errorDescription: String? {
            switch self {
            case .badResponse: return "服务返回异常"
            case .server(let m): return m
            }
        }
    }

    private func request(path: String, query: String? = nil, body: [String: Any]? = nil, method: String? = nil) async throws -> Any {
        try await rawRequest(path: path, query: query, body: body, auth: true, method: method)
    }

    private func rawRequest(path: String, query: String? = nil, body: [String: Any]?, auth: Bool, method: String? = nil) async throws -> Any {
        var full = Self.baseURL + path
        if let q = query, !q.isEmpty { full += "?" + q }
        guard let url = URL(string: full) else { throw CloudError.badResponse }
        var req = URLRequest(url: url)
        let httpMethod = method ?? (body == nil ? "GET" : "POST")
        req.httpMethod = httpMethod
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var payload = Data()
        if let body = body {
            payload = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
            req.httpBody = payload
        }

        if auth {
            let t = token
            guard !t.isEmpty else { throw CloudError.server("请先登录") }
            let reqID = UUID().uuidString
            let ts = String(Int(Date().timeIntervalSince1970))
            let nonce = Self.randomHex(16)
            // 查询串不参与签名（服务端按 r.URL.Path 校验）
            let sig = Self.sign(token: t, method: httpMethod, path: path,
                                reqID: reqID, ts: ts, nonce: nonce, body: payload)
            req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
            req.setValue(reqID, forHTTPHeaderField: "X-Req-Id")
            req.setValue(ts, forHTTPHeaderField: "X-Ts")
            req.setValue(nonce, forHTTPHeaderField: "X-Nonce")
            req.setValue(sig, forHTTPHeaderField: "X-Sign")
        }

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw CloudError.badResponse }
        let json = (try? JSONSerialization.jsonObject(with: data)) ?? [:]
        if http.statusCode >= 400 {
            let msg = (json as? [String: Any])?["message"] as? String ?? "请求失败（\(http.statusCode)）"
            throw CloudError.server(msg)
        }
        return json
    }

    static func sign(token: String, method: String, path: String,
                     reqID: String, ts: String, nonce: String, body: Data) -> String {
        let bodyHash = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        let message = [method.uppercased(), path, reqID, ts, nonce, bodyHash].joined(separator: "\n")
        let key = SymmetricKey(data: Data(token.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key)
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    static func randomHex(_ bytes: Int) -> String {
        var b = [UInt8](repeating: 0, count: bytes)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes, &b)
        return b.map { String(format: "%02x", $0) }.joined()
    }
}
