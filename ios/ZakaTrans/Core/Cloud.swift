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

    private init() {
        // 卸载重装：钥匙串里的东西还在、本机偏好被清空。
        // 这种状态下不能拿旧 token 直接进主界面——那等于没登录就进去了，
        // 所以在本地偏好没了的时候把账号态一起清掉，强制回登录页。
        if (Keychain.get("zt_device_marker") ?? "").isEmpty {
            Keychain.set("1", for: "zt_device_marker")
            UserDefaults.standard.set(true, forKey: "zt_installed")
        } else if !UserDefaults.standard.bool(forKey: "zt_installed") {
            Keychain.set("", for: "account_token")
            Keychain.set("", for: "account_id")
            UserDefaults.standard.set(true, forKey: "zt_installed")
        }
        // 冷启动第一帧就把登录态认下来：本地有 token 就直接进主界面，
        // 不再先显示一个转圈的检查页等异步结果。
        loggedIn = !(Keychain.get("account_token") ?? "").isEmpty
        // 接口地址以包内的为准：老版本在本地留过旧地址，升级后不能被它拖回老服务器
        UserDefaults.standard.set(Self.baseURL, forKey: "zt_base_url")
    }

    static let baseURL = "https://api.yumss.cn"

    /// 余额对内是 token，对外全部显示积分（1 元 = 10 积分，1400 积分 = 100 万 token）
    @Published private(set) var balanceTokens: Int64 = 0
    @Published private(set) var balanceCredits: Double = 0
    @Published private(set) var todayUsedCredits: Double = 0
    @Published private(set) var loggedIn = false
    /// 登录态核验完成：没核完之前界面停在启动页，绝不先放人进主界面
    @Published private(set) var ready = false
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
    /// 本机头像补传只试一次：上传成功但服务端没存下来的话，
    /// 这里不拦就会 refresh → upload → refresh 无限转，界面看起来就是卡死。
    private var avatarUploadTried = false

    var hasAccount: Bool { !token.isEmpty }

    // MARK: - 启动

    /// 启动时核一次登录态：
    ///   · 本地没有 token → 直接判定未登录，停在登录页；
    ///   · 有 token → 先向服务端核一次。401 立刻掉线回登录页（token 被吊销、账号已删都能兜住）；
    ///     只是网络不通就不算掉线，按已登录放行，不能把人挡在门外。
    /// 核验最多等 5 秒，超时先放行，余额/资料在后面补。
    func bootstrap() async {
        guard !token.isEmpty else {
            loggedIn = false
            ready = true
            return
        }
        do {
            _ = try await request(path: "/v1/me", timeout: 5)
            loggedIn = true
        } catch Cloud.CloudError.unauthorized {
            loggedIn = false
        } catch {
            // 弱网 / 服务端临时故障：本地有 token 就先进去，后续请求到了再判断
            loggedIn = true
        }
        ready = true
        if loggedIn { Task { _ = await self.refresh() } }
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
        try applyAuth(data)
        await refresh()
    }

    // MARK: - 邮箱登录

    /// 发验证码，返回服务端规定的重发冷却秒数。
    func sendEmailCode(to email: String) async throws -> Int {
        let data = try await rawRequest(path: "/v1/auth/email/send", body: ["email": email], auth: false)
        guard let d = data as? [String: Any] else { throw CloudError.badResponse }
        return (d["cooldown"] as? NSNumber)?.intValue ?? 60
    }

    /// 邮箱 + 验证码换账号 token。第一次用这个邮箱会自动建号。
    func loginWithEmail(email: String, code: String) async throws {
        let body: [String: Any] = [
            "email": email,
            "code": code,
            "device_id": Keychain.deviceID(),
            "platform": "ios",
            "model": UIDevice.current.model,
            "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0",
        ]
        let data = try await rawRequest(path: "/v1/auth/email/verify", body: body, auth: false)
        try applyAuth(data)
    }

    /// Apple 和邮箱两条路登录成功后，落账号态的动作完全一样，抽出来免得改一处漏一处。
    private func applyAuth(_ data: Any) throws {
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
                provider: p["provider"] as? String ?? "device",
                created_at: (p["created_at"] as? NSNumber)?.int64Value ?? 0
            )
        }
        loggedIn = true
        lastError = nil
        // 引擎层（ObjC）要拿它连识别服务
        UserDefaults.standard.set(t, forKey: "zt_account_token")
        UserDefaults.standard.set(Self.baseURL, forKey: "zt_base_url")
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
                    // 头像：服务端有就以服务端为准（换设备 / 重装后能补回来）
                    if let b64 = p["avatar"] as? String, !b64.isEmpty,
                       AvatarStore.save(base64: b64) {
                        DispatchQueue.main.async { AppState.shared.avatarImage = AvatarStore.load() }
                    } else if !avatarUploadTried, let local = AvatarStore.base64(), !local.isEmpty {
                        // 本机有头像、服务端还是空的（换了账号、上次上传没成功、
                        // 或者是老版本只存在本机的头像）：补传一次，让账号上也有。
                        // 以前只做「服务端有就覆盖本机」，本机这张永远上不去，
                        // 换台设备登录就变回灰头像。
                        avatarUploadTried = true
                        Task { [weak self] in
                            guard let self else { return }
                            if await self.uploadAvatar(local) {
                                await self.refresh()
                            }
                        }
                    }
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

    // MARK: - 头像

    /// 头像同步到账号。空字符串 = 清掉，回到默认头像。
    @discardableResult
    func uploadAvatar(_ base64: String) async -> Bool {
        guard !token.isEmpty else { return false }
        do {
            _ = try await request(path: "/v1/avatar", body: ["image": base64], method: "PUT")
            return true
        } catch {
            return false
        }
    }

    // MARK: - 资料

    /// 改昵称。服务端存 display_name，换设备登录也是这个名字。
    @discardableResult
    func updateDisplayName(_ name: String) async -> Bool {
        guard !token.isEmpty else { return false }
        do {
            _ = try await request(path: "/v1/profile", body: ["display_name": name], method: "PUT")
            await refresh()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    /// 注销账号：服务端把钱、会话、转写、偏好一起删掉，然后清本地登录态。
    @discardableResult
    func deleteAccount() async -> Bool {
        guard !token.isEmpty else { return false }
        do {
            _ = try await request(path: "/v1/account", method: "DELETE")
            logout()
            return true
        } catch {
            lastError = error.localizedDescription
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
        let preview: String?

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
                    summary: row["summary"] as? String,
                    preview: row["preview"] as? String
                )
            }
        } catch {
            return []
        }
    }

    // MARK: - 积分使用明细

    /// 一条账目：购买、使用扣费、试用赠送、后台调整都走这张表。
    /// delta 是 token 数，积分按跟会话记录同一套换算（1400 积分 = 100 万 token）。
    struct LedgerItem: Identifiable {
        let id: Int64
        let kind: String
        let delta: Int64
        let balanceAfter: Int64
        let refID: String
        let meta: String
        let at: Date

        var credits: Double { Double(delta) * 1400.0 / 1_000_000.0 }
        var creditsText: String {
            let v = abs(credits)
            let body = v >= 100 ? String(format: "%.0f", v)
                : (v >= 10 ? String(format: "%.1f", v) : String(format: "%.2f", v))
            return delta >= 0 ? "+" + body : "-" + body
        }
        var balanceCredits: Double { Double(balanceAfter) * 1400.0 / 1_000_000.0 }

        /// 明细里出现的东西只有这几类，其它（后台手工调账之类）不摊给用户看。
        var title: String {
            switch kind {
            case "purchase": return "购买积分"
            case "usage":
                // 同声传译和实时字幕都是按用量扣费，靠结算时带回来的模式分开显示。
                // 这里不挑引号格式：meta 是服务端写的 JSON 串，字段顺序和转义都可能变，
                // 只要出现 interp 就当同传——以前只认一种写法，同传的记录全被算成了字幕识别。
                return meta.range(of: "interp", options: .caseInsensitive) != nil ? "同声传译" : "字幕识别"
            case "trial":    return "新用户赠送"
            case "grant":    return "赠送积分"
            case "refund":   return "退还"
            case "adjust":   return "调整"
            default:         return "积分变动"
            }
        }
        var isIncome: Bool { delta >= 0 }
    }

    func usage(limit: Int = 120) async -> [LedgerItem] {
        guard !token.isEmpty else { return [] }
        do {
            let data = try await request(path: "/v1/usage", query: "limit=\(limit)")
            guard let d = data as? [String: Any], let items = d["items"] as? [[String: Any]] else { return [] }
            return items.compactMap { row in
                guard let id = (row["id"] as? NSNumber)?.int64Value else { return nil }
                return LedgerItem(
                    id: id,
                    kind: row["kind"] as? String ?? "",
                    delta: (row["delta"] as? NSNumber)?.int64Value ?? 0,
                    balanceAfter: (row["balance_after"] as? NSNumber)?.int64Value ?? 0,
                    refID: row["ref_id"] as? String ?? "",
                    meta: row["meta"] as? String ?? "",
                    at: Date(timeIntervalSince1970: (row["created_at"] as? NSNumber)?.doubleValue ?? 0)
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
        /// 登录态失效（token 过期 / 被吊销 / 账号已删除）
        case unauthorized
        case server(String)
        var errorDescription: String? {
            switch self {
            case .badResponse: return "服务返回异常"
            case .unauthorized: return "登录已失效，请重新登录"
            case .server(let m): return m
            }
        }
    }

    private func request(path: String, query: String? = nil, body: [String: Any]? = nil,
                         method: String? = nil, timeout: TimeInterval = 20) async throws -> Any {
        try await rawRequest(path: path, query: query, body: body, auth: true, method: method, timeout: timeout)
    }

    private func rawRequest(path: String, query: String? = nil, body: [String: Any]?, auth: Bool,
                            method: String? = nil, timeout: TimeInterval = 20) async throws -> Any {
        var full = Self.baseURL + path
        if let q = query, !q.isEmpty { full += "?" + q }
        guard let url = URL(string: full) else { throw CloudError.badResponse }
        var req = URLRequest(url: url)
        let httpMethod = method ?? (body == nil ? "GET" : "POST")
        req.httpMethod = httpMethod
        req.timeoutInterval = timeout
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
        if http.statusCode == 401 {
            // 登录态失效：本地 token 立刻作废，界面回登录页
            if auth { logout() }
            throw CloudError.unauthorized
        }
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
