import Foundation
import CryptoKit
import UIKit

/// 与自家后端通信。豆包凭据只在服务端，客户端连上游的资格都没有。
///
/// 每个请求都带签名：method + path + reqid + ts + nonce + body hash，
/// 用设备 token 做 HMAC。改一个字节签名就对不上，重发一次也会被 nonce 拦掉。
@MainActor
final class Cloud: ObservableObject {
    static let shared = Cloud()

    static let baseURL = "https://api.xingyans.com"

    @Published private(set) var balance: Int64 = 0
    @Published private(set) var todayUsed: Int64 = 0
    @Published private(set) var loggedIn = false
    @Published private(set) var lastError: String?

    private var token: String {
        get { Keychain.get("account_token") ?? "" }
        set { Keychain.set(newValue, for: "account_token") }
    }

    private(set) var accountID: String = Keychain.get("account_id") ?? ""

    var minStartBalance: Int64 = 2000

    // MARK: - 启动登录

    /// 首次进入时注册设备；已有凭据就直接用，失败再重注册一次。
    func bootstrap() async {
        if !token.isEmpty {
            if await refresh() { return }
        }
        await register()
    }

    func register() async {
        let body: [String: Any] = [
            "device_id": Keychain.deviceID(),
            "platform": "ios",
            "model": UIDevice.current.model,
            "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0",
        ]
        do {
            let data = try await rawRequest(path: "/v1/auth/device", body: body, auth: false)
            if let dict = data as? [String: Any],
               let t = dict["token"] as? String {
                token = t
                accountID = dict["account_id"] as? String ?? ""
                Keychain.set(accountID, for: "account_id")
                balance = (dict["balance"] as? NSNumber)?.int64Value ?? 0
                loggedIn = true
                // 引擎层（ObjC）要拿它连识别服务
                UserDefaults.standard.set(t, forKey: "zt_account_token")
                UserDefaults.standard.set(Self.baseURL, forKey: "zt_base_url")
                lastError = nil
            }
        } catch {
            lastError = "登录失败：\(error.localizedDescription)"
        }
    }

    // MARK: - 余额与流水

    @discardableResult
    func refresh() async -> Bool {
        guard !token.isEmpty else { return false }
        do {
            let data = try await request(path: "/v1/me")
            if let d = data as? [String: Any] {
                balance = (d["balance"] as? NSNumber)?.int64Value ?? balance
                todayUsed = (d["today_used"] as? NSNumber)?.int64Value ?? 0
                minStartBalance = (d["min_start_balance"] as? NSNumber)?.int64Value ?? 2000
                loggedIn = true
                lastError = nil
                return true
            }
        } catch {
            lastError = error.localizedDescription
        }
        return false
    }

    struct LedgerItem: Identifiable {
        let id: Int64
        let kind: String
        let delta: Int64
        let balanceAfter: Int64
        let at: Date
        var title: String {
            switch kind {
            case "purchase": return "购买额度"
            case "usage": return "同传消耗"
            case "grant": return "赠送额度"
            case "refund": return "退还"
            default: return kind
            }
        }
    }

    func ledger(limit: Int = 50) async -> [LedgerItem] {
        guard !token.isEmpty else { return [] }
        do {
            let data = try await request(path: "/v1/usage?limit=\(limit)")
            guard let d = data as? [String: Any], let items = d["items"] as? [[String: Any]] else { return [] }
            return items.compactMap { row in
                guard let id = (row["id"] as? NSNumber)?.int64Value else { return nil }
                return LedgerItem(
                    id: id,
                    kind: row["kind"] as? String ?? "",
                    delta: (row["delta"] as? NSNumber)?.int64Value ?? 0,
                    balanceAfter: (row["balance_after"] as? NSNumber)?.int64Value ?? 0,
                    at: Date(timeIntervalSince1970: (row["created_at"] as? NSNumber)?.doubleValue ?? 0)
                )
            }
        } catch {
            return []
        }
    }

    // MARK: - 内购核销

    /// 把 StoreKit 给的交易凭据交给服务端验签，额度由服务端发，客户端说了不算。
    func verifyPurchase(jws: String) async throws -> (credited: Int64, balance: Int64) {
        let body: [String: Any] = ["jws": jws]
        let data = try await request(path: "/v1/iap/verify", body: body)
        guard let d = data as? [String: Any] else { throw CloudError.badResponse }
        let credited = (d["credited"] as? NSNumber)?.int64Value ?? 0
        let bal = (d["balance"] as? NSNumber)?.int64Value ?? balance
        balance = bal
        return (credited, bal)
    }

    // MARK: - 请求与签名

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

    private func request(path: String, body: [String: Any]? = nil) async throws -> Any {
        try await rawRequest(path: path, body: body, auth: true)
    }

    private func rawRequest(path: String, body: [String: Any]?, auth: Bool) async throws -> Any {
        guard let url = URL(string: Self.baseURL + path) else { throw CloudError.badResponse }
        var req = URLRequest(url: url)
        req.httpMethod = body == nil ? "GET" : "POST"
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var payload = Data()
        if let body = body {
            payload = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
            req.httpBody = payload
        }

        if auth {
            let t = token
            guard !t.isEmpty else { throw CloudError.server("请先进入 App 完成初始化") }
            let reqID = UUID().uuidString
            let ts = String(Int(Date().timeIntervalSince1970))
            let nonce = Self.randomHex(16)
            let sig = Self.sign(token: t, method: req.httpMethod ?? "GET", path: path,
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
