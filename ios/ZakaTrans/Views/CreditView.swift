import SwiftUI

/// 积分：余额、充值、用量，一个页面看全。
struct CreditView: View {
    @ObservedObject private var cloud = Cloud.shared
    @ObservedObject private var purch = Purchases.shared
    @Environment(\.dismiss) private var dismiss

    @State private var sessions: [Cloud.UsageSession] = []
    @State private var loading = true

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                balanceCard
                rechargeCard
                usageCard
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 28)
        }
        .background(Theme.bg)
        .navigationTitle("积分")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("完成") { dismiss() }
            }
        }
        .task {
            if purch.products.isEmpty { await purch.load() }
            await cloud.refresh()
            sessions = await cloud.sessions(limit: 20)
            loading = false
        }
    }

    // MARK: - 余额

    private var balanceCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("当前积分")
                .font(.system(size: 13))
                .foregroundStyle(Theme.sub)

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Format.credits(cloud.balanceCredits))
                    .font(.system(size: 46, weight: .bold).monospacedDigit())
                    .foregroundStyle(Theme.ink)
                Text("积分")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.sub)
            }

            HStack(spacing: 0) {
                stat("今日消耗", Format.credits(cloud.todayUsedCredits))
                divider
                stat("可用时长", estimateTime)
                divider
                stat("本场最低", Format.credits(cloud.minStartCredits))
            }
        }
        .card(padding: 20)
    }

    private var divider: some View {
        Rectangle().fill(Theme.line).frame(width: 0.5, height: 28)
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 11)).foregroundStyle(Theme.sub)
            Text(value).font(.system(size: 15, weight: .medium).monospacedDigit()).foregroundStyle(Theme.ink)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var estimateTime: String {
        let minutes = cloud.balanceTokens / 1500
        if minutes < 60 { return "\(max(0, minutes)) 分钟" }
        return String(format: "%.1f 小时", Double(minutes) / 60.0)
    }

    // MARK: - 充值

    private var rechargeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("充值")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Spacer()
                Text("1 元 = 10 积分")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.sub)
            }

            VStack(spacing: 10) {
                ForEach(Purchases.fallback, id: \.id) { item in
                    Button {
                        Task { await purch.buy(id: item.id) }
                    } label: {
                        HStack(spacing: 12) {
                            Text("\(item.credits)")
                                .font(.system(size: 19, weight: .semibold).monospacedDigit())
                                .foregroundStyle(Theme.ink)
                            Text("积分")
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.sub)
                            Spacer()
                            Text(purch.priceText(for: item.id))
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(Theme.accent)
                            if purch.busy {
                                ProgressView().scaleEffect(0.65)
                            }
                        }
                        .padding(.horizontal, 16)
                        .frame(height: 56)
                        .background(Theme.fill)
                        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(purch.busy)
                }
            }

            if let m = purch.message {
                Text(m)
                    .font(.system(size: 12))
                    .foregroundStyle(m.contains("失败") || m.contains("未通过") ? Theme.warn : Theme.accent)
            }
        }
        .card(padding: 16)
    }

    // MARK: - 用量

    private var usageCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("用量")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Spacer()
                if loading { ProgressView().scaleEffect(0.7) }
            }

            if sessions.isEmpty {
                Text(loading ? " " : "还没有使用记录")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.sub)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
            } else {
                ForEach(Array(sessions.prefix(10).enumerated()), id: \.element.id) { idx, s in
                    if idx > 0 {
                        Rectangle().fill(Theme.line).frame(height: 0.5)
                    }
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(Format.date(s.startedAt))
                                .font(.system(size: 14))
                                .foregroundStyle(Theme.ink)
                            Text(s.durationText)
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.sub)
                        }
                        Spacer()
                        Text("\(s.creditsText) 积分")
                            .font(.system(size: 14, weight: .medium).monospacedDigit())
                            .foregroundStyle(Theme.sub)
                    }
                    .padding(.vertical, 9)
                }
            }
        }
        .card(padding: 16)
    }
}
