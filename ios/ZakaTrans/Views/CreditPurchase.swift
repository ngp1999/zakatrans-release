import SwiftUI
import UIKit

/// 充值档位 + 立即充值 + 付费协议。
///
/// 「我的积分」和充值弹窗共用这一块。版式按参考图来：
/// 上面一组「选择充值套餐」标题 + 一句副标题，下面一行一个套餐卡（名称、描述、价格、右侧勾选圈），
/// 卡片只负责选中、不付款；最下面一颗整宽的主按钮才进内购，按钮上带着当前档位的价格；
/// 按钮下面一行小字：圆形勾选 +「我已阅读并同意《付费协议》」。
/// 没勾协议就点充值，弹系统确认框。
struct CreditPurchaseSection: View {
    @ObservedObject private var purch = Purchases.shared

    @State private var selectedId: String? = Purchases.shown.first?.id
    @State private var agreed = false
    @State private var hint: String?
    @State private var showTerms = false
    /// 没勾协议就点了「立即充值」：先弹确认，同意后自动勾上再下单
    @State private var askAgree = false

    private let haptic = UINotificationFeedbackGenerator()

    var body: some View {
        Section {
            ForEach(Purchases.shown, id: \.id) { item in
                card(item)
                    .onTapGesture { pick(item.id) }
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }

            Button(action: recharge) {
                Text(buyTitle)
                    .font(DSFont.headline)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(
                        RoundedRectangle(cornerRadius: DSRadius.button, style: .continuous)
                            .fill(selectedId == nil ? DSColor.fill : DSColor.accentFill)
                    )
                    .foregroundStyle(selectedId == nil ? DSColor.tertiaryLabel : Color.white)
            }
            .buttonStyle(.plain)
            .disabled(purch.busy || selectedId == nil)
            .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 2, trailing: 16))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)

            agreementRow
                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 2, trailing: 16))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)

            if let hint {
                Text(hint)
                    .font(DSFont.footnote)
                    .foregroundStyle(DSColor.destructive)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 6, trailing: 16))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }

            if let m = purch.message {
                Text(m)
                    .font(DSFont.footnote)
                    .foregroundStyle(
                        (m.contains("失败") || m.contains("未通过"))
                        ? DSColor.destructive : DSColor.secondaryLabel
                    )
                    .frame(maxWidth: .infinity, alignment: .center)
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 6, trailing: 16))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
        } header: {
            VStack(alignment: .leading, spacing: 2) {
                Text("选择充值套餐")
                    .font(DSFont.headline)
                    .foregroundStyle(DSColor.label)
                Text("选择适合你的积分额度")
                    .font(DSFont.footnote)
                    .foregroundStyle(DSColor.secondaryLabel)
                    .textCase(nil)
            }
            .padding(.bottom, 2)
        }
        .navigationDestination(isPresented: $showTerms) {
            TermsView(kind: .payment)
        }
        .alert("购买前请确认", isPresented: $askAgree) {
            Button("取消", role: .cancel) {}
            Button("同意并购买") {
                agreed = true
                hint = nil
                guard let id = selectedId, purch.available(id) else { return }
                Task { await purch.buy(id: id) }
            }
        } message: {
            Text("我已阅读并同意《付费协议》")
        }
    }

    /// 按钮上的字跟着选中的档位走：选哪档、多少钱，一颗按钮上说清楚。
    private var buyTitle: String {
        if purch.busy { return "正在处理…" }
        guard let id = selectedId, purch.available(id) else { return "立即充值" }
        return "立即充值 · \(purch.priceText(for: id))"
    }

    // MARK: - 协议行

    /// 一行小字：圆形勾选 +「我已阅读并同意」+ 可点的《付费协议》。
    private var agreementRow: some View {
        HStack(spacing: 5) {
            Button {
                toggleAgree()
            } label: {
                Image(systemName: agreed ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(agreed ? DSColor.accent : DSColor.tertiaryLabel)
            }
            .buttonStyle(.plain)

            Button {
                toggleAgree()
            } label: {
                Text("我已阅读并同意")
                    .font(.system(size: 12))
                    .foregroundStyle(DSColor.secondaryLabel)
            }
            .buttonStyle(.plain)

            Button {
                showTerms = true
            } label: {
                Text("《付费协议》")
                    .font(.system(size: 12))
                    .foregroundStyle(DSColor.accent)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 2)
    }

    // MARK: - 档位卡片

    /// 档位名跟积分量绑在一起，不写「初次使用 / 少量补充」这类推销词。
    private func title(for credits: Int) -> String {
        switch credits {
        case ..<300:   return "体验套餐"
        case ..<700:   return "标准套餐"
        case ..<1400:  return "进阶套餐"
        case ..<3000:  return "畅享套餐"
        default:       return "尊享套餐"
        }
    }

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
            askAgree = true
            return
        }
        hint = nil
        Task { await purch.buy(id: id) }
    }

    private func card(_ item: (id: String, cny: Int, credits: Int)) -> some View {
        let ready = purch.available(item.id)
        let on = selectedId == item.id
        return HStack(alignment: .center, spacing: DSSpace.s) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title(for: item.credits))
                    .font(DSFont.body.weight(.semibold))
                    .foregroundStyle(DSColor.label)
                Text("\(Format.credits(Double(item.credits))) 积分")
                    .font(DSFont.footnote)
                    .foregroundStyle(DSColor.secondaryLabel)
            }

            Spacer(minLength: DSSpace.xs)

            Text(purch.priceText(for: item.id))
                .font(.body.weight(.semibold).monospacedDigit())
                .foregroundStyle(ready ? DSColor.label : DSColor.tertiaryLabel)
                .lineLimit(1)

            Image(systemName: on ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 21))
                .foregroundStyle(on ? DSColor.accent : DSColor.tertiaryLabel.opacity(0.5))
                .padding(.leading, 2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(minHeight: 62)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(on && ready ? DSColor.accentSoft : DSColor.cell)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    on && ready ? DSColor.accent : DSColor.separator.opacity(0.6),
                    lineWidth: on && ready ? 1.6 : 0.5
                )
        )
        .opacity(ready ? 1 : 0.45)
    }
}
