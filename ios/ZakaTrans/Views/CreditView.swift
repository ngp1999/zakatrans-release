import SwiftUI

/// 积分：余额 + 积分规则。充值走弹窗，页面本身不铺档位。
struct CreditView: View {
    @ObservedObject private var cloud = Cloud.shared
    @ObservedObject private var purch = Purchases.shared
    @Environment(\.dismiss) private var dismiss

    @State private var showPurchase = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                balanceCard
                rulesCard
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 28)
        }
        .background(Theme.bg)
        .navigationTitle("积分")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("完成") { dismiss() }
            }
        }
        .sheet(isPresented: $showPurchase) {
            PurchaseView()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .task {
            if purch.products.isEmpty { await purch.load() }
            await cloud.refresh()
        }
    }

    // MARK: - 余额

    private var balanceCard: some View {
        VStack(spacing: 16) {
            VStack(spacing: 6) {
                Text("当前积分")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.sub)

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(Format.credits(cloud.balanceCredits))
                        .font(.system(size: 48, weight: .bold).monospacedDigit())
                        .foregroundStyle(Theme.ink)
                    Text("积分")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.sub)
                }
            }

            Button {
                showPurchase = true
            } label: {
                Text("充值")
            }
            .buttonStyle(PrimaryButtonStyle())
        }
        .frame(maxWidth: .infinity)
        .card(padding: 24)
    }

    // MARK: - 规则

    private var rulesCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("积分规则")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.ink)

            rule(
                index: "1",
                title: "充值比例",
                body: "1 元 = 10 积分。按积分档位充值，付款后自动到账。"
            )
            divider
            rule(
                index: "2",
                title: "积分与用量",
                body: "1 积分 ≈ 714 Token。中文大约 1 个汉字 ≈ 1.3~1.5 Token；英文大约 4 个字符 ≈ 1 Token。"
            )
            divider
            rule(
                index: "3",
                title: "消耗方式",
                body: "按有效识别内容对应的 Token 计费：识别到的语音转成文字，文字越多消耗越多；静音、空白不消耗积分。"
            )
        }
        .card(padding: 18)
    }

    private var divider: some View {
        Rectangle().fill(Theme.line).frame(height: 0.5)
    }

    private func rule(index: String, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(index)
                .font(.system(size: 12, weight: .bold).monospacedDigit())
                .foregroundStyle(Theme.accent)
                .frame(width: 20, height: 20)
                .background(Theme.accentSoft)
                .clipShape(Circle())
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.ink)
                Text(body)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.sub)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
