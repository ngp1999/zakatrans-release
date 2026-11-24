import SwiftUI
import UIKit

/// 我的积分（充值页）。
///
/// 版式按参考图：最上面一张余额卡（余额 +「积分明细」入口），下面一组套餐卡，
/// 一颗整宽的「立即充值 · 价格」按钮，按钮下面一行协议小字。
/// 使用明细同时保留在导航栏右上角的图标上，两处都能进。
struct CreditView: View {
    @ObservedObject private var cloud = Cloud.shared
    @ObservedObject private var purch = Purchases.shared
    @State private var showUsage = false

    var body: some View {
        List {
            Section {
                balanceCard
                    .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 6, trailing: 8))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }

            CreditPurchaseSection()
        }
        .listStyle(.insetGrouped)
        .navigationTitle("积分充值")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Haptics.tap()
                    showUsage = true
                } label: {
                    Image(systemName: "list.bullet.rectangle")
                }
                .accessibilityLabel("积分明细")
            }
        }
        .navigationDestination(isPresented: $showUsage) {
            UsageDetailView()
        }
        .task {
            if purch.products.isEmpty { await purch.load() }
            await cloud.refresh()
        }
    }

    /// 余额卡：只有余额一件事，不再挂「积分可用于…」这类小字。
    /// 积分明细收在导航栏右上角的图标里。
    private var balanceCard: some View {
        VStack(alignment: .leading, spacing: DSSpace.xs) {
            Text("我的积分余额")
                .font(DSFont.footnote)
                .foregroundStyle(DSColor.secondaryLabel)

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Format.credits(cloud.balanceCredits))
                    .font(.system(size: 34, weight: .semibold).monospacedDigit())
                    .foregroundStyle(DSColor.label)
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text("积分")
                    .font(DSFont.subheadline)
                    .foregroundStyle(DSColor.secondaryLabel)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(DSColor.cell)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(DSColor.accent.opacity(0.16), lineWidth: 0.5)
        )
    }
}
