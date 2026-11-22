import SwiftUI
import UIKit

/// 充值弹窗。
///
/// 只做两件事：显示余额、摆出档位。档位选择、协议勾选、下单都在
/// `CreditPurchaseSection` 里，跟「我的积分」页共用同一份实现。
struct PurchaseView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var cloud = Cloud.shared
    @ObservedObject private var purch = Purchases.shared

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(alignment: .firstTextBaseline) {
                        Text("当前可用")
                            .font(DSFont.subheadline)
                            .foregroundStyle(DSColor.secondaryLabel)
                        Spacer(minLength: DSSpace.xs)
                        Text(Format.credits(cloud.balanceCredits))
                            .font(.title3.weight(.semibold).monospacedDigit())
                            .foregroundStyle(DSColor.label)
                            .contentTransition(.numericText())
                            .lineLimit(1)
                        Text("积分")
                            .font(DSFont.subheadline)
                            .foregroundStyle(DSColor.secondaryLabel)
                    }
                }

                CreditPurchaseSection()
            }
            .listStyle(.insetGrouped)
            .navigationTitle("充值")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .task {
                if purch.products.isEmpty { await purch.load() }
                await cloud.refresh()
            }
        }
    }
}
