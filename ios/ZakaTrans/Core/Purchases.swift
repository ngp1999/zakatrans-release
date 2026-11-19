import Foundation
import StoreKit

/// 内购。商品是消耗型：100 万 token / 140 元。
///
/// 客户端只负责把 StoreKit 给的凭据送到服务端；
/// 发多少额度、能不能发，全由服务端验完苹果签名后决定。
@MainActor
final class Purchases: ObservableObject {
    static let shared = Purchases()

    static let productID = "com.zakatrans.token.1m"
    static let displayPrice = "¥140"

    @Published var product: Product?
    @Published var busy = false
    @Published var message: String?

    func load() async {
        do {
            product = try await Product.products(for: [Self.productID]).first
            if product == nil {
                message = "商品还没在 App Store Connect 上线"
            }
        } catch {
            message = "商品信息加载失败：\(error.localizedDescription)"
        }
    }

    var priceText: String {
        product?.displayPrice ?? Self.displayPrice
    }

    func buy() async {
        guard let product else { return }
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
                let jws = verification.jwsRepresentation
                let r = try await Cloud.shared.verifyPurchase(jws: jws)
                await transaction.finish()
                message = r.credited > 0
                    ? "已到账 \(Self.format(r.credited)) token"
                    : "这笔交易已经入过账，余额 \(Self.format(r.balance))"
            case .userCancelled:
                message = nil
            case .pending:
                message = "交易处理中，稍后自动到账"
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
            if let credited = try? await Cloud.shared.verifyPurchase(jws: result.jwsRepresentation) {
                message = credited.credited > 0 ? "已补记 \(Self.format(credited.credited)) token" : nil
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
