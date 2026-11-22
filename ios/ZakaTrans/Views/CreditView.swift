import SwiftUI
import UIKit

/// 我的积分：余额 + 充值档位 + 付费协议。
///
/// 结构就是系统「订阅/购买」页的样子：分组列表、每档一行、右侧价格。
/// 之前是三列自绘小方块 + 自绘勾选圈 + 自绘遮罩弹窗，这三样在 iOS 上都有系统对应物。
struct CreditView: View {
    @ObservedObject private var cloud = Cloud.shared
    @ObservedObject private var purch = Purchases.shared

    @State private var showTerms = false
    @State private var agreed = false
    /// 没勾协议就点了档位：记下点的是哪一档，弹窗里同意了就直接买这一档
    @State private var pendingTier: String?
    @State private var showUsage = false
    @State private var showAgreementPrompt = false

    private let haptic = UIImpactFeedbackGenerator(style: .light)

    var body: some View {
        List {
            // 余额
            Section {
                VStack(alignment: .leading, spacing: DSSpace.xxs) {
                    Text("可用积分")
                        .font(DSFont.footnote)
                        .foregroundStyle(DSColor.secondaryLabel)
                    Text(Format.credits(cloud.balanceCredits))
                        .font(.largeTitle.weight(.semibold).monospacedDigit())
                        .foregroundStyle(DSColor.label)
                        .contentTransition(.numericText())
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
                .padding(.vertical, DSSpace.xxs)
            }

            // 充值档位
            Section {
                ForEach(Purchases.fallback, id: \.id) { item in
                    tierRow(id: item.id, credits: item.credits)
                }
            } header: {
                Text("充值积分")
            } footer: {
                Text("积分用于实时字幕与同声传译。1 元 = 10 积分。")
            }

            // 协议
            Section {
                Toggle(isOn: Binding(
                    get: { agreed },
                    set: { v in
                        Haptics.tap()
                        withAnimation(DSMotion.quick) { agreed = v }
                    }
                )) {
                    Text("我已阅读并同意付费协议")
                        .font(DSFont.body)
                }

                Button {
                    showTerms = true
                } label: {
                    HStack {
                        Text("《语幕付费协议》")
                            .font(DSFont.body)
                            .foregroundStyle(DSColor.accent)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(DSColor.tertiaryLabel)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            // 状态提示
            if let m = purch.message {
                Section {
                    Text(m)
                        .font(DSFont.footnote)
                        .foregroundStyle(
                            (m.contains("失败") || m.contains("未通过"))
                            ? DSColor.destructive : DSColor.secondaryLabel
                        )
                }
            }

            if purch.busy {
                Section {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("我的积分")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    UsageDetailView()
                } label: {
                    Image(systemName: "list.bullet.rectangle")
                }
                .accessibilityLabel("使用明细")
            }
        }
        .sheet(isPresented: $showTerms) {
            NavigationStack {
                TermsView(kind: .payment)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("完成") { showTerms = false }
                        }
                    }
            }
        }
        // 未勾协议就点档位：系统确认弹窗，里面可以直接看协议
        .alert("语幕付费协议", isPresented: $showAgreementPrompt) {
            Button("查看协议") { showTerms = true }
            Button("同意并继续") {
                withAnimation(DSMotion.quick) { agreed = true }
                if let id = pendingTier {
                    pendingTier = nil
                    Task { await purch.buy(id: id) }
                }
            }
            Button("取消", role: .cancel) { pendingTier = nil }
        } message: {
            Text("购买前需要阅读并同意《语幕付费协议》。")
        }
        .task {
            if purch.products.isEmpty { await purch.load() }
            await cloud.refresh()
        }
    }

    // MARK: - 档位行

    private func tierRow(id: String, credits: Int) -> some View {
        let price = purch.priceText(for: id)
        let ready = purch.available(id)

        return Button {
            haptic.impactOccurred()
            guard ready else { return }
            guard agreed else {
                pendingTier = id
                showAgreementPrompt = true
                return
            }
            Task { await purch.buy(id: id) }
        } label: {
            HStack(spacing: DSSpace.s) {
                Text("\(credits)")
                    .font(DSFont.number)
                    .foregroundStyle(DSColor.label)
                    .frame(minWidth: 64, alignment: .leading)

                Text("积分")
                    .font(DSFont.subheadline)
                    .foregroundStyle(DSColor.secondaryLabel)

                Spacer(minLength: DSSpace.xs)

                Text(price)
                    .font(DSFont.body.weight(.semibold))
                    .foregroundStyle(ready ? DSColor.accent : DSColor.tertiaryLabel)
                    .lineLimit(1)
            }
            .frame(minHeight: DSSpace.rowMinHeight)
            .contentShape(Rectangle())
            .opacity(ready ? 1 : 0.5)
        }
        .buttonStyle(.plain)
        .disabled(purch.busy || !ready)
    }
}
