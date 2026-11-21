import SwiftUI
import UIKit

/// 我的积分：余额 + 充值积分档位 + 购买协议勾选。
/// 计费规则统一收在《付费协议》里，这里只留「买多少、付多少」。
struct CreditView: View {
    @ObservedObject private var cloud = Cloud.shared
    @ObservedObject private var purch = Purchases.shared

    /// 协议阅读弹窗
    @State private var showTerms = false
    @State private var agreed = false
    /// 没勾协议就点了档位：记下点的是哪一档，弹窗里同意了就直接买这一档
    @State private var pendingTier: String?

    private let haptic = UIImpactFeedbackGenerator(style: .light)
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                balanceBlock
                tiersBlock
                agreementRow
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
        // 未勾选协议就点档位时的确认弹窗：自绘，因为要在弹窗里直接点开《付费协议》
        .overlay {
            if pendingTier != nil {
                agreementDialog
            }
        }
        .animation(.easeOut(duration: 0.18), value: pendingTier)
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
        .padding(.horizontal, 18)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
    }

    // MARK: - 充值档位

    /// 档位直接摆在页面上，点哪一档就是买哪一档。
    /// 价格用 StoreKit 返回的本地化价格；拉不到就显示「未上架」，不编价格。
    private var tiersBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("充值积分")
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
            guard ready else { return }
            guard agreed else {
                // 没勾协议：先弹确认，弹窗里可以直接读协议
                pendingTier = id
                return
            }
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

    /// 「已阅读并同意语幕付费协议相关规则」——协议名可点，其余是普通文字。
    private var agreementSentence: Text {
        var head = AttributedString("已阅读并同意")
        head.foregroundColor = Theme.sub
        var link = AttributedString("语幕付费协议")
        link.link = URL(string: "zaka://terms")
        link.foregroundColor = Theme.accent
        var tail = AttributedString("相关规则")
        tail.foregroundColor = Theme.sub
        head.append(link)
        head.append(tail)
        return Text(head)
    }

    // MARK: - 未勾协议的确认弹窗

    private var agreementDialog: some View {
        ZStack {
            Color.black.opacity(0.30)
                .ignoresSafeArea()
                .onTapGesture { pendingTier = nil }

            VStack(spacing: 16) {
                Text("语幕付费协议")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .frame(maxWidth: .infinity)

                // 一句正文，「语幕付费协议」是绿色可点的链接，点了直接展开协议全文。
                // 用 AttributedString 塞 link，避免 HStack 拼接时换行错位。
                agreementSentence
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.sub)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .tint(Theme.accent)
                    .fixedSize(horizontal: false, vertical: true)
                    .environment(\.openURL, OpenURLAction { _ in
                        Haptics.tap()
                        showTerms = true
                        return .handled
                    })
                    .frame(maxWidth: .infinity)

                HStack(spacing: 10) {
                    Button {
                        pendingTier = nil
                    } label: {
                        Text("取消")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Theme.ink)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .background(Theme.fill)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(TileButtonStyle())

                    Button {
                        let id = pendingTier
                        pendingTier = nil
                        withAnimation(.easeOut(duration: 0.14)) { agreed = true }
                        if let id { Task { await purch.buy(id: id) } }
                    } label: {
                        Text("同意并继续")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .background(Theme.accent)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(TileButtonStyle())
                }
                .padding(.top, 2)
            }
            .padding(20)
            .frame(maxWidth: 330)
            .background(Theme.bg)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 0.7)
            )
            .shadow(color: .black.opacity(0.18), radius: 26, y: 10)
            .padding(.horizontal, 32)
        }
        .transition(.opacity)
    }
}
