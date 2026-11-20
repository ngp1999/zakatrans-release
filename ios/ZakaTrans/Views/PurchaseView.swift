import SwiftUI
import UIKit

/// 充值弹窗：6 个档位，每行 3 个。
/// 价格和积分的对应关系固定，客户端改不了——服务端按商品 id 发货。
/// 下单前必须勾选《付费协议》，这是审核要求，也让用户清楚买的是什么。
struct PurchaseView: View {
    @ObservedObject private var cloud = Cloud.shared
    @ObservedObject private var purch = Purchases.shared

    @State private var agreed = false
    @State private var hint: String?
    /// 没勾选协议就点了档位：先弹确认，确认后自动勾上再下单
    @State private var pendingId: String?

    private let haptic = UIImpactFeedbackGenerator(style: .light)
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

                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(Purchases.fallback, id: \.id) { item in
                            tile(id: item.id, credits: item.credits)
                        }
                    }

                    agreementRow

                    if let hint {
                        Text(hint)
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.warn)
                            .multilineTextAlignment(.center)
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
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 24)
            }
            .background(Theme.bg)
            .alert("购买前请确认", isPresented: Binding(
                get: { pendingId != nil },
                set: { if !$0 { pendingId = nil } }
            )) {
                Button("取消", role: .cancel) { pendingId = nil }
                Button("同意并购买") {
                    let id = pendingId
                    pendingId = nil
                    agreed = true
                    hint = nil
                    if let id { Task { await purch.buy(id: id) } }
                }
            } message: {
                Text("购买积分需要先阅读并同意《付费协议》。积分按实际用量扣除，充值通过 App Store 内购完成，退款按 Apple 规则处理。")
            }
            .navigationTitle("充值")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                if purch.products.isEmpty { await purch.load() }
                await cloud.refresh()
            }
        }
    }

    // MARK: - 协议勾选

    private var agreementRow: some View {
        HStack(alignment: .top, spacing: 9) {
            Button {
                agreed.toggle()
                if agreed { hint = nil }
            } label: {
                Image(systemName: agreed ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(agreed ? Theme.accent : Theme.faint)
            }
            .buttonStyle(.plain)

            HStack(spacing: 0) {
                Text("我已阅读并同意")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.sub)
                    .onTapGesture { agreed.toggle() }

                NavigationLink {
                    TermsView(kind: .payment)
                } label: {
                    Text("《付费协议》")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 2)

            Spacer(minLength: 0)
        }
        .padding(.top, 2)
    }

    private func tile(id: String, credits: Int) -> some View {
        let ok = purch.available(id)
        return Button {
            guard ok else { return }
            guard agreed else {
                haptic.impactOccurred()
                pendingId = id
                return
            }
            hint = nil
            Task { await purch.buy(id: id) }
        } label: {
            VStack(spacing: 7) {
                Text("\(credits)")
                    .font(.system(size: 23, weight: .bold).monospacedDigit())
                    .foregroundStyle(ok ? Theme.ink : Theme.sub)
                Text("积分")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.sub)
                Text(purch.priceText(for: id))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(ok ? Theme.accent : Theme.faint)
                    .padding(.top, 1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 104)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(ok && agreed ? Theme.accent.opacity(0.35) : Theme.hairline, lineWidth: 0.8)
            )
            .opacity(ok ? (agreed ? 1 : 0.55) : 0.45)
        }
        .buttonStyle(TileButtonStyle())
        .disabled(purch.busy || !ok)
    }
}
