import SwiftUI
import UIKit

/// 我的积分：余额 + 充值。
///
/// 档位、协议、下单全部交给 `CreditPurchaseSection`，和充值弹窗是同一份实现，
/// 不会出现「这个页面点一下直接扣款、那个页面要先确认」这种两套逻辑。
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

                Button {
                    Haptics.tap()
                    showUsage = true
                } label: {
                    HStack {
                        Text("使用明细")
                            .font(DSFont.body)
                            .foregroundStyle(DSColor.label)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(DSColor.tertiaryLabel)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } footer: {
                Text("积分用于实时字幕与同声传译。1 元 = 10 积分。")
            }

            CreditPurchaseSection()
        }
        .listStyle(.insetGrouped)
        .navigationTitle("我的积分")
        .navigationBarTitleDisplayMode(.large)
        .navigationDestination(isPresented: $showUsage) {
            UsageDetailView()
        }
        .task {
            if purch.products.isEmpty { await purch.load() }
            await cloud.refresh()
        }
    }
}
