import SwiftUI

/// 我的积分：余额 + 充值入口 + 计费规则。
/// 版式按原生设置页来：一块卡片、一条分隔线、一行一条说明，不加渐变和光晕。
struct CreditView: View {
    @ObservedObject private var cloud = Cloud.shared
    @ObservedObject private var purch = Purchases.shared

    @State private var showPurchase = false

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                balanceBlock
                rulesBlock
                footer
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
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

    private var balanceBlock: some View {
        VStack(spacing: 18) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("可用积分")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.sub)
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(Format.credits(cloud.balanceCredits))
                            .font(.system(size: 40, weight: .semibold).monospacedDigit())
                            .foregroundStyle(Theme.ink)
                            .contentTransition(.numericText())
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                        Text("积分")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.sub)
                    }
                }
                Spacer(minLength: 0)
                Button {
                    Haptics.tap()
                    showPurchase = true
                } label: {
                    Text("充值")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 24)
                        .frame(height: 38)
                        .background(Theme.accent)
                        .clipShape(Capsule())
                }
                .buttonStyle(TileButtonStyle())
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
    }

    // MARK: - 规则

    /// 一行一条：左边说明，右边数值。不写编号圆圈，也不写解释性长句。
    private var rulesBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("计费规则")
                .font(.system(size: 13))
                .foregroundStyle(Theme.sub)
                .padding(.bottom, 10)
                .padding(.leading, 4)

            VStack(spacing: 0) {
                ruleRow("充值比例", "1 元 = 10 积分")
                innerDivider
                ruleRow("计费单位", "1 积分 ≈ 714 Token")
                innerDivider
                ruleRow("如何计费", "按识别出的文字量计算")
                innerDivider
                ruleRow("静音片段", "不扣积分")
            }
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        }
    }

    private func ruleRow(_ title: String, _ value: String) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 15))
                .foregroundStyle(Theme.ink)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 14))
                .foregroundStyle(Theme.sub)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 16)
        .frame(height: 46)
    }

    private var innerDivider: some View {
        Rectangle().fill(Theme.line).frame(height: 0.5).padding(.leading, 16)
    }

    // MARK: - 页脚

    private var footer: some View {
        VStack(spacing: 10) {
            Button {
                showPurchase = true
            } label: {
                Text("购买积分与档位")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)

            NavigationLink {
                TermsView(kind: .payment)
            } label: {
                Text("积分购买协议")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.faint)
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 2)
    }
}
