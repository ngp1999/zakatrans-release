import SwiftUI
import UIKit

/// 充值档位 + 立即充值 + 付费协议。
///
/// 「我的积分」和充值弹窗共用这一块。顺序按用户习惯来：
/// 先选档位（卡片只选中、不付款）→ 按「立即充值」→ 协议勾在按钮下面。
/// 页面上不放任何说明性小字，只在没勾协议时给一句提醒。
struct CreditPurchaseSection: View {
    @ObservedObject private var purch = Purchases.shared

    @State private var selectedId: String? = Purchases.shown.first?.id
    @State private var agreed = false
    @State private var hint: String?
    @State private var showTerms = false

    private let haptic = UINotificationFeedbackGenerator()

    var body: some View {
        Group {
            Section {
                ForEach(Purchases.shown, id: \.id) { item in
                    card(item)
                        .onTapGesture { pick(item.id) }
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
            } header: {
                Text("选择充值档位")
            }

            Section {
                Button(action: recharge) {
                    Text(purch.busy ? "正在处理…" : "立即充值")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 2)
                }
                .buttonStyle(.borderedProminent)
                .tint(DSColor.accentFill)
                .controlSize(.large)
                .disabled(purch.busy || selectedId == nil)
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                .listRowBackground(Color.clear)
            }

            Section {
                HStack(spacing: DSSpace.s) {
                    Button {
                        toggleAgree()
                    } label: {
                        HStack(spacing: DSSpace.s) {
                            Image(systemName: agreed ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 21))
                                .foregroundStyle(agreed ? DSColor.accent : DSColor.tertiaryLabel)
                            Text("我已阅读并同意")
                                .font(DSFont.body)
                                .foregroundStyle(DSColor.label)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Button {
                        showTerms = true
                    } label: {
                        Text("《付费协议》")
                            .font(DSFont.body)
                            .foregroundStyle(DSColor.accent)
                    }
                    .buttonStyle(.plain)
                }

                if let hint {
                    Text(hint)
                        .font(DSFont.footnote)
                        .foregroundStyle(DSColor.destructive)
                }
            }

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
        }
        .navigationDestination(isPresented: $showTerms) {
            TermsView(kind: .payment)
        }
    }

    // MARK: - 档位卡片

    private func pick(_ id: String) {
        guard purch.available(id) else { return }
        UISelectionFeedbackGenerator().selectionChanged()
        withAnimation(DSMotion.quick) {
            selectedId = id
            hint = nil
        }
    }

    private func toggleAgree() {
        Haptics.tap()
        withAnimation(DSMotion.quick) {
            agreed.toggle()
            if agreed { hint = nil }
        }
    }

    private func recharge() {
        guard let id = selectedId, purch.available(id) else {
            hint = "这个档位暂时不可用，换一个试试"
            return
        }
        guard agreed else {
            haptic.notificationOccurred(.warning)
            withAnimation(DSMotion.quick) { hint = "请先勾选《付费协议》" }
            return
        }
        hint = nil
        Task { await purch.buy(id: id) }
    }

    private func card(_ item: (id: String, cny: Int, credits: Int)) -> some View {
        let ready = purch.available(item.id)
        let on = selectedId == item.id
        return HStack(alignment: .center, spacing: DSSpace.s) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(item.credits)")
                    .font(.system(size: 22, weight: .semibold).monospacedDigit())
                    .foregroundStyle(DSColor.label)
                Text("积分")
                    .font(DSFont.subheadline)
                    .foregroundStyle(DSColor.secondaryLabel)
            }

            Spacer(minLength: DSSpace.xs)

            Text(purch.priceText(for: item.id))
                .font(.body.weight(.semibold).monospacedDigit())
                .foregroundStyle(ready ? DSColor.label : DSColor.tertiaryLabel)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(minHeight: 60)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(on && ready ? DSColor.accentSoft : DSColor.cell)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    on && ready ? DSColor.accent : DSColor.separator.opacity(0.6),
                    lineWidth: on && ready ? 1.6 : 0.5
                )
        )
        .overlay(alignment: .topTrailing) {
            if on && ready {
                Text("已选择")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(DSColor.accent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(DSColor.accentSoft))
                    .offset(x: -8, y: 6)
                    .transition(.opacity)
            }
        }
        .opacity(ready ? 1 : 0.45)
    }
}
