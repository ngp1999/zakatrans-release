import SwiftUI
import UIKit

/// 我的积分：余额 + 充值档位 + 购买协议勾选。
/// 计费规则从这里挪走了——统一收进《付费协议》，页面上只留「买多少、付多少」。
struct CreditView: View {
    @ObservedObject private var cloud = Cloud.shared
    @ObservedObject private var purch = Purchases.shared

    @State private var showPurchase = false
    /// 协议阅读弹窗
    @State private var showTerms = false
    @State private var agreed = false
    @State private var hint: String?

    private let haptic = UIImpactFeedbackGenerator(style: .light)
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                balanceBlock
                tiersBlock
                agreementRow
                if let hint {
                    Text(hint)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.warn)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, alignment: .center)
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
        .sheet(isPresented: $showTerms) {
            NavigationStack {
                TermsView(kind: .payment)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button("完成") { showTerms = false }
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(Theme.accent)
                        }
                    }
            }
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

    // MARK: - 充值档位

    /// 档位直接摆在页面上，不用再点一次「购买积分与档位」才看得到。
    /// 价格用 StoreKit 返回的本地化价格；拉不到就按兜底表显示。
    private var tiersBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("充值档位")
                .font(.system(size: 13))
                .foregroundStyle(Theme.sub)
                .padding(.leading, 4)

            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(Purchases.fallback, id: \.id) { item in
                    tierTile(id: item.id, credits: item.credits)
                }
            }
        }
    }

    private func tierTile(id: String, credits: Int) -> some View {
        let price = purch.priceText(for: id)
        let ready = purch.available(id)
        return Button {
            haptic.impactOccurred()
            guard agreed else {
                hint = "购买前请先阅读并勾选《付费协议》"
                return
            }
            hint = nil
            Task { await purch.buy(id: id) }
        } label: {
            VStack(spacing: 5) {
                Text("\(credits)")
                    .font(.system(size: 21, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text("积分")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.faint)
                Text(price)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .padding(.top, 2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 0.7)
            )
            .opacity(ready ? 1 : 0.55)
        }
        .buttonStyle(TileButtonStyle())
        .disabled(purch.busy)
    }

    // MARK: - 协议勾选

    private var agreementRow: some View {
        HStack(alignment: .center, spacing: 8) {
            Button {
                Haptics.tap()
                withAnimation(.easeOut(duration: 0.14)) { agreed.toggle() }
                if agreed { hint = nil }
            } label: {
                Image(systemName: agreed ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 21))
                    .foregroundStyle(agreed ? Theme.accent : Theme.faint)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            HStack(spacing: 0) {
                Text("我已阅读并同意")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.sub)
                Button {
                    Haptics.tap()
                    showTerms = true
                } label: {
                    Text("《付费协议》")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 0)
        }
        .padding(.top, 2)
    }
}
