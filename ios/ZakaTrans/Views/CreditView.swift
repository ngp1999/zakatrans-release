import SwiftUI
import UIKit

/// 我的积分：余额 + 充值。
///
/// 页面上只留三样东西：余额、充值档位、下单按钮。说明性小字一律不放，
/// 使用明细挪到导航栏右上角，需要的时候点进去看。
struct CreditView: View {
    @ObservedObject private var cloud = Cloud.shared
    @ObservedObject private var purch = Purchases.shared
    @State private var showUsage = false

    var body: some View {
        List {
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

            CreditPurchaseSection()
        }
        .listStyle(.insetGrouped)
        .navigationTitle("我的积分")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Haptics.tap()
                    showUsage = true
                } label: {
                    Image(systemName: "list.bullet.rectangle")
                }
                .accessibilityLabel("使用明细")
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
}
