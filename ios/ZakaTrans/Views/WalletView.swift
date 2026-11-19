import SwiftUI

struct WalletView: View {
    @ObservedObject private var cloud = Cloud.shared
    @ObservedObject private var purchases = Purchases.shared
    @Environment(\.dismiss) private var dismiss
    @State private var items: [Cloud.LedgerItem] = []

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 16) {
                    balanceCard
                    productCard
                    historyCard
                    Text("额度按模型接口返回的有效 Token 数量扣减，与开启时长相无关。\n识别与翻译由服务端转发完成，凭据不下发到设备。")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.sub)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)
                }
                .padding(16)
            }
        }
        .navigationTitle("额度")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("完成") { dismiss() }
            }
        }
        .task {
            await cloud.refresh()
            await purchases.load()
            items = await cloud.ledger()
        }
        .onChange(of: purchases.message) { _ in
            Task {
                await cloud.refresh()
                items = await cloud.ledger()
            }
        }
    }

    private var balanceCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("剩余额度")
                .font(.system(size: 13))
                .foregroundStyle(Theme.sub)
            Text(Purchases.format(cloud.balance))
                .font(.system(size: 40, weight: .bold).monospacedDigit())
                .foregroundStyle(Theme.ink)
            Text("token")
                .font(.system(size: 12))
                .foregroundStyle(Theme.sub)
            Divider().overlay(Theme.line).padding(.vertical, 6)
            HStack {
                stat("今日消耗", Purchases.format(cloud.todayUsed))
                Spacer()
                stat("起播门槛", Purchases.format(cloud.minStartBalance))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private func stat(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(k).font(.system(size: 11)).foregroundStyle(Theme.sub)
            Text(v).font(.system(size: 15, weight: .medium).monospacedDigit()).foregroundStyle(Theme.ink)
        }
    }

    private var productCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("100 万 token")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                    Text("约 11 小时连续同传")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.sub)
                }
                Spacer()
                Text(purchases.priceText)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Theme.ink)
            }

            Button {
                Task { await purchases.buy() }
            } label: {
                if purchases.busy {
                    ProgressView().tint(.white)
                } else {
                    Text("购买")
                }
            }
            .buttonStyle(PrimaryButtonStyle(enabled: !purchases.busy))

            if let m = purchases.message {
                Text(m)
                    .font(.system(size: 12))
                    .foregroundStyle(m.contains("失败") ? Theme.warn : Theme.sub)
            }
        }
        .card()
    }

    private var historyCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("明细")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.ink)
            if items.isEmpty {
                Text("还没有记录")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.sub)
            } else {
                ForEach(items.prefix(30)) { item in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                                .font(.system(size: 14))
                                .foregroundStyle(Theme.ink)
                            Text(item.at.formatted(date: .numeric, time: .shortened))
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.sub)
                        }
                        Spacer()
                        Text((item.delta > 0 ? "+" : "") + Purchases.format(item.delta))
                            .font(.system(size: 14, weight: .medium).monospacedDigit())
                            .foregroundStyle(item.delta > 0 ? Theme.accent : Theme.ink)
                    }
                    if item.id != items.prefix(30).last?.id {
                        Divider().overlay(Theme.line)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}
