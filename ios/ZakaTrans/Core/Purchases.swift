import Foundation
import StoreKit

/// 内购。档位全部是消耗型商品，买的是积分。
///
/// 换算：1 元 = 10 积分，1400 积分 = 100 万用量。
/// 苹果没有 10 元整这一档，最低实际档位是 12 元（120 积分）。
///
/// 客户端只负责把 StoreKit 给的凭据送到服务端；
/// 发多少积分、能不能发，全由服务端验完苹果签名后按商品表决定。
@MainActor
final class Purchases: ObservableObject {
    static let shared = Purchases()

    /// 与后端 credit.Products() 一一对应
    static let productIDs = [
        "com.zakatrans.credits.120",
        "com.zakatrans.credits.300",
        "com.zakatrans.credits.680",
        "com.zakatrans.credits.1380",
        "com.zakatrans.credits.2980",
        "com.zakatrans.credits.5980",
    ]

    /// 兜底价目（当 StoreKit 拉不到商品时用来占位，真实价格永远以苹果返回为准）
    static let fallback: [(id: String, cny: Int, credits: Int)] = [
        ("com.zakatrans.credits.120", 12, 120),
        ("com.zakatrans.credits.300", 30, 300),
        ("com.zakatrans.credits.680", 68, 680),
        ("com.zakatrans.credits.1380", 138, 1380),
        ("com.zakatrans.credits.2980", 298, 2980),
        ("com.zakatrans.credits.5980", 598, 5980),
    ]

    /// 页面上展示的档位：五档，从 120 到 2980。5980 仍在商品表里（已购用户/服务端校验
    /// 都还要认它），只是不再摆到台面上。
    static let shown: [(id: String, cny: Int, credits: Int)] = Array(fallback.prefix(5))

    @Published var products: [Product] = []
    @Published var busy = false
    @Published var message: String?
    @Published var loadFailed = false

    func load() async {
        do {
            let list = try await Product.products(for: Self.productIDs)
            // 按我们定义的顺序排，不按苹果返回的顺序
            products = Self.productIDs.compactMap { id in list.first { $0.id == id } }
            loadFailed = products.isEmpty
            if products.isEmpty {
                message = "商品还没在 App Store Connect 就绪，稍后再试"
            }
        } catch {
            loadFailed = true
            message = "商品信息加载失败：\(error.localizedDescription)"
        }
    }

    func product(id: String) -> Product? { products.first { $0.id == id } }

    func credits(for id: String) -> Int {
        Self.fallback.first { $0.id == id }?.credits ?? 0
    }

    /// 价格只认苹果返回的那一个。
    ///
    /// 之前的问题是两套来源混着用：拿到商品的显示苹果的价，拿不到的手写「¥12」。
    /// 苹果的价是按 **当前 Apple ID 所在区域** 结算的货币，
    /// 测试账号区域是美国时它就是 $1.99，旁边没配置的那几个还是写死的人民币，
    /// 于是同一个页面一半 $ 一半 ¥。
    /// 现在没拿到商品就显示「未上架」，不编价格，也不会两种货币混排。
    func priceText(for id: String) -> String {
        if let p = product(id: id) { return p.displayPrice }
        return "未上架"
    }

    func available(_ id: String) -> Bool { product(id: id) != nil }

    func buy(id: String) async {
        guard let product = product(id: id) else {
            message = "这个档位还没上架，去 App Store Connect 看一下商品状态"
            return
        }
        busy = true
        message = nil
        defer { busy = false }
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                guard case .verified(let transaction) = verification else {
                    message = "交易未通过苹果校验"
                    return
                }
                let r = try await Cloud.shared.verifyPurchase(jws: verification.jwsRepresentation)
                await transaction.finish()
                if r.credited > 0 {
                    message = "已到账 \(Format.credits(r.creditedCredits)) 积分"
                } else {
                    message = "这笔交易已入过账，当前余额 \(Format.credits(r.balanceCredits)) 积分"
                }
            case .userCancelled:
                message = nil
            case .pending:
                message = "交易处理中，到账后会自动通知"
            @unknown default:
                message = "未知的交易状态"
            }
        } catch {
            message = "购买失败：\(error.localizedDescription)"
        }
    }

    /// 启动时把没走完的交易补交一遍（杀进程、断网都可能留下未核销的单）
    func syncUnfinished() async {
        for await result in Transaction.unfinished {
            guard case .verified(let transaction) = result else { continue }
            if let r = try? await Cloud.shared.verifyPurchase(jws: result.jwsRepresentation) {
                if r.credited > 0 {
                    message = "已补记 \(Format.credits(r.creditedCredits)) 积分"
                }
                await transaction.finish()
            }
        }
    }

    static func format(_ v: Int64) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: v)) ?? "\(v)"
    }
}
