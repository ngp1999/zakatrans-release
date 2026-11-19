import SwiftUI

/// 充值页：选积分档位，走苹果内购。
/// 价格和积分的对应关系固定，客户端改不了——服务端按商品 id 发货。
struct PurchaseView: View {
    @ObservedObject private var cloud = Cloud.shared
    @ObservedObject private var purch = Purchases.shared
    @Environment(\.dismiss) private var dismiss
    @State private var selected = "com.zakatrans.credits.1380"

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                balanceCard

                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel(text: "选择档位")
                    VStack(spacing: 10) {
                        ForEach(Purchases.fallback, id: \.id) { item in
                            tile(id: item.id, credits: item.credits)
                        }
                    }
                }

                Text("积分用于实时翻译，按模型返回的有效用量扣，不按时长。\n1 元 = 10 积分 · 1400 积分 = 100 万用量")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.sub)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)

                if let m = purch.message {
                    Text(m)
                        .font(.system(size: 13))
                        .foregroundStyle(m.contains("失败") || m.contains("未通过") ? Theme.warn : Theme.accent)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)
                }

                Text("购买通过 Apple 完成，支持退款按苹果规则处理。")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.faint)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 28)
        }
        .background(Theme.bg)
        .navigationTitle("充值积分")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("关闭") { dismiss() }
            }
        }
        .task {
            if purch.products.isEmpty { await purch.load() }
        }
    }

    private var balanceCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("当前余额").font(.system(size: 13)).foregroundStyle(Theme.sub)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Format.credits(cloud.balanceCredits))
                    .font(.system(size: 36, weight: .bold).monospacedDigit())
                    .foregroundStyle(Theme.ink)
                Text("积分").font(.system(size: 14)).foregroundStyle(Theme.sub)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 18)
    }

    private func tile(id: String, credits: Int) -> some View {
        let on = selected == id
        return Button {
            selected = id
            Task { await purch.buy(id: id) }
        } label: {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(credits) 积分")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                    Text("约 \(credits * 714) 用量")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.sub)
                }
                Spacer()
                Text(purch.priceText(for: id))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(on ? Theme.accent : Theme.ink)
                if purch.busy && on {
                    ProgressView().scaleEffect(0.7).padding(.leading, 2)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 66)
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(on ? Theme.accent : Color.clear, lineWidth: 1.6)
            )
        }
        .buttonStyle(.plain)
        .disabled(purch.busy)
    }
}
