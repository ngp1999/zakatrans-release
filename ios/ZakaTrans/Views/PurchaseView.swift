import SwiftUI

/// 充值弹窗：6 个档位，每行 3 个。
/// 价格和积分的对应关系固定，客户端改不了——服务端按商品 id 发货。
struct PurchaseView: View {
    @ObservedObject private var cloud = Cloud.shared
    @ObservedObject private var purch = Purchases.shared

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    HStack {
                        Text("当前余额")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.sub)
                        Spacer()
                        Text("\(Format.credits(cloud.balanceCredits)) 积分")
                            .font(.system(size: 15, weight: .semibold).monospacedDigit())
                            .foregroundStyle(Theme.ink)
                    }
                    .card(padding: 16)

                    Text("选择档位，付款后立即到账")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.sub)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 2)

                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(Purchases.fallback, id: \.id) { item in
                            tile(id: item.id, credits: item.credits)
                        }
                    }

                    if let m = purch.message {
                        Text(m)
                            .font(.system(size: 13))
                            .foregroundStyle(m.contains("失败") || m.contains("未通过") ? Theme.warn : Theme.accent)
                            .multilineTextAlignment(.center)
                    }

                    if purch.busy {
                        ProgressView().scaleEffect(0.8)
                    }

                    NavigationLink {
                        TermsView(kind: .payment)
                    } label: {
                        HStack(spacing: 4) {
                            Text("付费协议")
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.faint)
                    }
                    .padding(.top, 12)
                    .padding(.bottom, 24)
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
            }
            .background(Theme.bg)
            .navigationTitle("充值")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                if purch.products.isEmpty { await purch.load() }
                await cloud.refresh()
            }
        }
    }

    private func tile(id: String, credits: Int) -> some View {
        Button {
            Task { await purch.buy(id: id) }
        } label: {
            VStack(spacing: 6) {
                Text("\(credits)")
                    .font(.system(size: 22, weight: .bold).monospacedDigit())
                    .foregroundStyle(Theme.ink)
                Text("积分")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.sub)
                Text(purch.priceText(for: id))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .padding(.top, 2)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 98)
            .background(Theme.fill)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(TileButtonStyle())
        .disabled(purch.busy)
    }
}
