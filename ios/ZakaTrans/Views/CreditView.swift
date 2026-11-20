import SwiftUI

/// 我的积分：余额 + 积分规则 + 付费协议入口。充值走弹窗，页面本身不铺档位。
struct CreditView: View {
    @ObservedObject private var cloud = Cloud.shared
    @ObservedObject private var purch = Purchases.shared

    @State private var showPurchase = false

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                balanceCard
                rulesCard
                agreementRow
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 28)
        }
        .background(Theme.bg)
        .navigationTitle("我的积分")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showPurchase) {
            PurchaseView()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .task {
            if purch.products.isEmpty { await purch.load() }
            await cloud.refresh()
        }
    }

    // MARK: - 余额

    private var balanceCard: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                Text("可用积分")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.sub)

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(Format.credits(cloud.balanceCredits))
                        .font(.system(size: 52, weight: .bold).monospacedDigit())
                        .foregroundStyle(Theme.ink)
                        .contentTransition(.numericText())
                    Text("积分")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.sub)
                }

            }
            .frame(maxWidth: .infinity)
            .padding(.top, 26)
            .padding(.bottom, 22)

            Rectangle().fill(Theme.line).frame(height: 0.5)

            Button {
                showPurchase = true
            } label: {
                Text("充值")
            }
            .buttonStyle(PrimaryButtonStyle())
            .padding(16)
        }
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .shadow(color: Color.black.opacity(0.04), radius: 12, y: 4)
    }

    // MARK: - 规则

    private var rulesCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("积分规则")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .padding(.bottom, 14)

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
        Rectangle().fill(Theme.line).frame(height: 0.5).padding(.vertical, 12)
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

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.ink)
                Text(body)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.sub)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 付费协议

    private var agreementRow: some View {
        NavigationLink {
            TermsView(kind: .payment)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "doc.text")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.sub)
                Text("付费协议")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.ink)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.faint)
            }
            .padding(.horizontal, 16)
            .frame(height: 52)
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        }
        .buttonStyle(RowButtonStyle())
    }
}
