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
                .presentationDetents([.fraction(0.66), .large])
                .presentationDragIndicator(.visible)
        }
        .task {
            if purch.products.isEmpty { await purch.load() }
            await cloud.refresh()
        }
    }

    // MARK: - 余额

    /// 余额卡：大号余额 + 右上角起鼓的积分币 + 卡内一整条充值按钮。
    /// 版式照参考图，颜色全部换成主题青绿那一套，不照抄原来的橙金。
    private var balanceCard: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("可用积分")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.sub)

                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(Format.credits(cloud.balanceCredits))
                            .font(.system(size: 52, weight: .bold).monospacedDigit())
                            .foregroundStyle(Theme.ink)
                            .contentTransition(.numericText())
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                        Text("积分")
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.sub)
                    }
                }
                Spacer(minLength: 0)
                coinBadge
                    .padding(.top, 4)
            }
            .padding(.leading, 20)
            .padding(.trailing, 18)
            .padding(.top, 22)
            .padding(.bottom, 22)

            Button {
                Haptics.tap()
                showPurchase = true
            } label: {
                Text("充值")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(
                        LinearGradient(
                            colors: [Theme.accent, Theme.accent.opacity(0.86)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                    .shadow(color: Theme.accent.opacity(0.28), radius: 10, y: 5)
            }
            .buttonStyle(TileButtonStyle())
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .background(
            LinearGradient(
                colors: [Theme.accent.opacity(0.20), Theme.accent.opacity(0.06)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        )
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Theme.accent.opacity(0.18), lineWidth: 0.8)
        )
    }

    /// 积分币：外圈光晕 + 起鼓的圆盘 + 白色星，颜色跟着主题走
    private var coinBadge: some View {
        ZStack {
            Circle()
                .fill(Theme.accent.opacity(0.13))
                .frame(width: 72, height: 72)

            Circle()
                .fill(
                    LinearGradient(
                        colors: [Theme.accent.opacity(0.95), Theme.accent.opacity(0.72)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
                .frame(width: 58, height: 58)
                .overlay(
                    Circle().strokeBorder(Color.white.opacity(0.55), lineWidth: 2)
                )
                .shadow(color: Theme.accent.opacity(0.30), radius: 8, y: 3)

            Image(systemName: "star.fill")
                .font(.system(size: 24))
                .foregroundStyle(.white)
        }
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
}
