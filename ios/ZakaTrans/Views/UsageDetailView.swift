import SwiftUI

/// 积分使用明细：每一笔进出都列出来，按天分组。
///
/// 跟「对话记录」分工明确：那边是一场一场的对话内容，这边是账。
/// 一场对话花了多少在这里看得到，不在列表里重复。
struct UsageDetailView: View {
    @ObservedObject private var cloud = Cloud.shared
    @State private var items: [Cloud.LedgerItem] = []
    @State private var loading = true

    /// 按天分组（顺序沿用接口返回的时间倒序）
    private var sections: [(day: Date, rows: [Cloud.LedgerItem])] {
        let cal = Calendar.current
        var out: [(day: Date, rows: [Cloud.LedgerItem])] = []
        for it in items {
            let d = cal.startOfDay(for: it.at)
            if let i = out.firstIndex(where: { $0.day == d }) {
                out[i].rows.append(it)
            } else {
                out.append((day: d, rows: [it]))
            }
        }
        return out
    }

    var body: some View {
        Group {
            if loading && items.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if items.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(sections, id: \.day) { sec in
                        Section(Self.dayText(sec.day)) {
                            ForEach(sec.rows) { it in
                                row(it)
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("使用明细")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { if items.isEmpty { await load() } }
    }

    private func row(_ it: Cloud.LedgerItem) -> some View {
        HStack(alignment: .center, spacing: DSSpace.s) {
            VStack(alignment: .leading, spacing: DSSpace.xxs) {
                Text(it.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(DSColor.label)
                    .lineLimit(1)
                Text(Self.timeText(it.at))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(DSColor.tertiaryLabel)
            }
            Spacer(minLength: DSSpace.xs)
            VStack(alignment: .trailing, spacing: DSSpace.xxs) {
                Text(it.creditsText)
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(it.isIncome ? DSColor.accent : DSColor.label)
                    .lineLimit(1)
                Text("余额 " + Format.credits(it.balanceCredits))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(DSColor.tertiaryLabel)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, DSSpace.xxs)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "list.bullet.rectangle")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(DSColor.tertiaryLabel)
            Text("还没有使用记录")
                .font(.subheadline)
                .foregroundStyle(DSColor.secondaryLabel)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func load() async {
        loading = true
        defer { loading = false }
        items = await cloud.usage()
    }

    static func dayText(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "今天" }
        if cal.isDateInYesterday(d) { return "昨天" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = cal.component(.year, from: d) == cal.component(.year, from: Date())
            ? "M月d日" : "yyyy年M月d日"
        return f.string(from: d)
    }

    static func timeText(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }
}
