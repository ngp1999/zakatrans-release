import SwiftUI

/// 对话记录：一场一条，点进去能看完整转写，还能让 AI 总结。
/// 数据在云端，换设备也在。
struct HistoryView: View {
    @ObservedObject private var cloud = Cloud.shared
    @State private var items: [Cloud.UsageSession] = []
    @State private var loading = true

    var body: some View {
        Group {
            if loading && items.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if items.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(grouped, id: \.0) { group in
                        Section {
                            ForEach(group.1) { s in
                                NavigationLink(destination: SessionDetailView(session: s)) {
                                    row(s)
                                }
                            }
                        } header: {
                            Text(group.0)
                        } footer: {
                            if group.0 == grouped.last?.0 {
                                Text("云端只保留最近 30 天的记录，更早的已自动删除。")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.faint)
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .refreshable { await load() }
            }
        }
        .background(Theme.bg)
        .navigationTitle("对话记录")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    /// 按天分组：标题是「今天 / 昨天 / 11月19日 周三」
    private var grouped: [(String, [Cloud.UsageSession])] {
        let df = DateFormatter()
        df.locale = Locale(identifier: "zh_CN")
        df.dateFormat = "yyyy-MM-dd"

        var order: [String] = []
        var map: [String: [Cloud.UsageSession]] = [:]
        for s in items {
            let k = df.string(from: s.startedAt)
            if map[k] == nil { order.append(k) }
            map[k, default: []].append(s)
        }
        return order.map { key in
            (Self.dayTitle(key), map[key] ?? [])
        }
    }

    static func dayTitle(_ key: String) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "zh_CN")
        df.dateFormat = "yyyy-MM-dd"
        guard let d = df.date(from: key) else { return key }

        let cal = Calendar.current
        if cal.isDateInToday(d) { return "今天" }
        if cal.isDateInYesterday(d) { return "昨天" }

        let out = DateFormatter()
        out.locale = Locale(identifier: "zh_CN")
        out.dateFormat = cal.component(.year, from: d) == cal.component(.year, from: Date())
            ? "M月d日 EEEE"
            : "yyyy年M月d日 EEEE"
        return out.string(from: d)
    }

    private func row(_ s: Cloud.UsageSession) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(Self.timeText(s.startedAt))
                .font(.system(size: 16, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.ink)
                .frame(width: 52, alignment: .leading)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 10) {
                    Label(s.durationText, systemImage: "clock")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.sub)

                    Text("\(s.creditsText) 积分")
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .foregroundStyle(Theme.accent)

                    if s.hasSummary {
                        Text("已总结")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.accent)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Theme.accentSoft)
                            .clipShape(Capsule())
                    }
                }

                if let sum = s.summary, !sum.isEmpty {
                    Text(sum.replacingOccurrences(of: "\n", with: " "))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.sub)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
    }

    static func timeText(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(Theme.faint)
            Text("还没有记录")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Theme.ink)
            Text("开始一次实时翻译，这里就会出现每场的完整对话。")
                .font(.system(size: 13))
                .foregroundStyle(Theme.sub)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func load() async {
        loading = true
        items = await cloud.sessions(limit: 200)
        loading = false
    }
}

/// 单场详情：摘要 + 完整转写
struct SessionDetailView: View {
    let session: Cloud.UsageSession
    @ObservedObject private var cloud = Cloud.shared

    @State private var detail: Cloud.SessionDetail?
    @State private var summary = ""
    @State private var loading = true
    @State private var summarizing = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                metaCard
                summaryCard
                transcriptCard
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 28)
        }
        .background(Theme.bg)
        .navigationTitle("对话详情")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private var metaCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(Format.date(session.startedAt))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Spacer()
                Text("\(session.creditsText) 积分")
                    .font(.system(size: 15, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.accent)
            }
            HStack(spacing: 16) {
                Label(session.durationText, systemImage: "clock")
                Label("\(detail?.lines.count ?? 0) 句", systemImage: "text.bubble")
            }
            .font(.system(size: 12))
            .foregroundStyle(Theme.sub)
        }
        .card()
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "sparkles")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Text("AI 总结")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Spacer()
                if summarizing {
                    ProgressView().scaleEffect(0.8)
                }
            }

            if !summary.isEmpty {
                Text(summary)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.ink)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            } else if summarizing {
                Text("正在整理这一场的内容…")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.sub)
            } else {
                Text("把这一场的对话压成「概要 + 要点 + 待办」，几秒钟就好。")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.sub)
                Button {
                    Task { await makeSummary() }
                } label: {
                    Text("生成总结")
                }
                .buttonStyle(SecondaryButtonStyle(tint: Theme.accent))
                .disabled((detail?.lines.count ?? 0) == 0)
            }

            if let e = error {
                Text(e).font(.system(size: 12)).foregroundStyle(Theme.warn)
            }
        }
        .card()
    }

    private var transcriptCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("对话内容")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.ink)

            if loading {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 20)
            } else if let d = detail, d.lines.isEmpty {
                Text("这一场没有识别到内容（可能没有声音）。")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.sub)
            } else if let d = detail {
                ForEach(d.lines) { line in
                    VStack(alignment: .leading, spacing: 4) {
                        if !line.trans.isEmpty {
                            Text(line.trans)
                                .font(.system(size: 15))
                                .foregroundStyle(Theme.ink)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if !line.source.isEmpty, line.source != line.trans {
                            Text(line.source)
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.sub)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .card()
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let d = try await cloud.transcript(sessionID: session.id)
            detail = d
            summary = d.summary
        } catch {
            self.error = "记录加载失败：\(error.localizedDescription)"
        }
    }

    private func makeSummary() async {
        summarizing = true
        error = nil
        defer { summarizing = false }
        do {
            summary = try await cloud.summarize(sessionID: session.id)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
