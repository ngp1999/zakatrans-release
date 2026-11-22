import SwiftUI
import UIKit

/// 对话记录：一场一条，点进去能看完整转写、让 AI 总结。
/// 列表一行说清三件事：什么时候、聊了多久、这一场讲了什么。
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
                    ForEach(items) { s in
                        NavigationLink(destination: SessionDetailView(session: s)) {
                            row(s)
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("对话记录")
        .navigationBarTitleDisplayMode(.large)
        .refreshable { await load() }
        .task { if items.isEmpty { await load() } }
    }

    // MARK: - 列表行

    /// 标题就是这一场的内容本身：有 AI 总结取总结首句，没总结取第一句转写的前几个字。
    /// 不写「实时字幕」这种功能名——一列功能名等于没有标题。
    private func title(_ s: Cloud.UsageSession) -> String {
        if let sum = s.summary?.trimmingCharacters(in: .whitespacesAndNewlines), !sum.isEmpty {
            let first = sum
                .replacingOccurrences(of: "**", with: "")
                .split(whereSeparator: { $0 == "\n" || $0 == "。" })
                .first
                .map(String.init) ?? sum
            let t = first.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { return t }
        }
        if let p = s.preview?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty {
            return p
        }
        return "未命名的对话"
    }

    /// 年月日：列表里必须能一眼看出是哪天，不靠分组标题猜
    static func dateText(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy年M月d日"
        return f.string(from: d)
    }

    static func shortStamp(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日 HH:mm"
        return f.string(from: d)
    }

    /// 一行三件事：什么时候（年月日 + 时分）、聊了多久、讲的什么。
    /// 「怎么断开的」（主动停止 / 连接断开）不上列表——那是内部状态，不是用户关心的内容。
    private func row(_ s: Cloud.UsageSession) -> some View {
        HStack(alignment: .center, spacing: 10) {
            // 左边两块：内容标题 + 什么时候、聊了多久
            VStack(alignment: .leading, spacing: 7) {
                Text(title(s))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(DSColor.label)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 6) {
                    Text(Self.dateText(s.startedAt) + " " + Self.timeText(s.startedAt))
                    dot
                    Text(s.durationText)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(DSColor.secondaryLabel)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            }

            // 积分不在这里出现：一场花多少是账目，放在积分页的「使用明细」里看，
            // 混在对话记录里既占位置又要跟总账对不上。
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var dot: some View {
        Text("·").font(.caption).foregroundStyle(DSColor.tertiaryLabel)
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
                .foregroundStyle(DSColor.tertiaryLabel)
            Text("还没有记录")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(DSColor.label)
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
    /// 选「导出字幕」之后才进格式与内容的设置页
    @State private var showExportSheet = false

    var body: some View {
        List {
            Section {
                metaRows
            }
            Section("AI 总结") {
                summarySection
            }
            Section("对话内容") {
                transcriptSection
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("对话详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                // 右上角只放系统分享图标，一个字都不写。
                // 点它直接进「导出字幕」：格式和内容都在那一页选，中间不再插一层「复制全文」。
                Button {
                    Haptics.tap()
                    showExportSheet = true
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.subheadline.weight(.semibold))
                }
                .disabled(detail == nil || (detail?.lines.isEmpty ?? true))
            }
        }
        .sheet(isPresented: $showExportSheet) {
            SubtitleExportView(session: session, lines: detail?.lines ?? [])
        }
        .task { await load() }
    }

    /// 日期只在第一行出现一次，第二行只放时间 / 时长 / 句数——
    /// 以前两行各写一遍「11月20日 19:22」，同一页看到两个日期，纯属重复。
    private var metaRows: some View {
        VStack(alignment: .leading, spacing: DSSpace.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text(Self.dayText(session.startedAt))
                    .font(DSFont.headline)
                    .foregroundStyle(DSColor.label)
                Spacer()
            }
            HStack(spacing: 14) {
                Label(Self.timeText(session.startedAt), systemImage: "clock")
                Label(session.durationText, systemImage: "timer")
                Label("\(detail?.lines.count ?? 0) 句", systemImage: "text.bubble")
            }
            .font(.caption)
            .foregroundStyle(DSColor.secondaryLabel)
        }
        .padding(.vertical, DSSpace.xxs)
    }

    /// 今天 / 昨天用口语写法，其它日子写全「yyyy年M月d日」
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
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: DSSpace.s) {
            HStack {
                Image(systemName: "sparkles")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DSColor.accent)
                Text("AI 总结")
                    .font(DSFont.headline)
                    .foregroundStyle(DSColor.label)
                Spacer()
                if summarizing {
                    ProgressView()
                }
            }
            .padding(.bottom, DSSpace.xxs)

            if !summary.isEmpty {
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(DSColor.label)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            } else if summarizing {
                Text("正在整理这一场的内容…")
                    .font(.footnote)
                    .foregroundStyle(DSColor.secondaryLabel)
            } else {
                Text("将本场对话压缩为概要、要点、待办，数秒即可完成。")
                    .font(.footnote)
                    .foregroundStyle(DSColor.secondaryLabel)
                Button("生成总结") {
                    Task { await makeSummary() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled((detail?.lines.count ?? 0) == 0)
            }

            if let e = error {
                Text(e).font(.caption).foregroundStyle(DSColor.destructive)
            }
        }
    }

    private var transcriptSection: some View {
        VStack(alignment: .leading, spacing: DSSpace.s) {
            HStack {
                Text("对话内容")
                    .font(DSFont.headline)
                    .foregroundStyle(DSColor.label)
                Spacer()
            }
            .padding(.bottom, DSSpace.xxs)

            if loading {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 20)
            } else if let d = detail, d.lines.isEmpty {
                Text("这一场没有识别到内容（可能没有声音）。")
                    .font(.footnote)
                    .foregroundStyle(DSColor.secondaryLabel)
            } else if let d = detail {
                ForEach(d.lines) { line in
                    VStack(alignment: .leading, spacing: 4) {
                        if !line.trans.isEmpty {
                            Text(line.trans)
                                .font(.subheadline)
                                .foregroundStyle(DSColor.label)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if !line.source.isEmpty, line.source != line.trans {
                            Text(line.source)
                                .font(.caption)
                                .foregroundStyle(DSColor.secondaryLabel)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
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

// MARK: - 导出字幕

/// 字幕导出：SRT / TXT 两种格式，内容可选原文、译文、双语。
/// 生成的文件放进临时目录，用系统分享面板存到「文件」、发给别人都行。
struct SubtitleExportView: View {
    let session: Cloud.UsageSession
    let lines: [Cloud.TranscriptLine]

    @State private var format = "srt"
    @State private var content = "both"
    @State private var fileURL: URL?

    private let formats = [("srt", "SRT 字幕"), ("txt", "TXT 文本")]
    private let contents = [("source", "原文"), ("trans", "译文"), ("both", "双语")]

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("格式", selection: $format) {
                        ForEach(formats, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(DSColor.cell)
                } header: {
                    Text("格式")
                }

                Section {
                    Picker("内容", selection: $content) {
                        ForEach(contents, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(DSColor.cell)
                } header: {
                    Text("内容")
                }

                Section {
                    if let url = fileURL {
                        ShareLink(item: url) {
                            Label("保存或分享", systemImage: "square.and.arrow.up")
                        }
                        .listRowBackground(DSColor.cell)
                    } else {
                        Text("没有可导出的内容")
                            .foregroundStyle(DSColor.secondaryLabel)
                            .listRowBackground(DSColor.cell)
                    }
                } footer: {
                    Text("共 \(lines.count) 句 · 时长 \(session.durationText) · 文件名 \(fileName)")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("导出字幕")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .onAppear { rebuild() }
        .onChange(of: format) { _ in rebuild() }
        .onChange(of: content) { _ in rebuild() }
    }

    private var fileName: String {
        "语幕字幕_\(Self.stamp(session.startedAt)).\(format)"
    }

    private static func stamp(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyyMMdd_HHmm"
        return f.string(from: d)
    }

    private func rebuild() {
        let text = format == "srt" ? srtText() : plainText()
        guard !text.isEmpty else {
            fileURL = nil
            return
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        do {
            try text.data(using: .utf8)?.write(to: url, options: .atomic)
            fileURL = url
        } catch {
            fileURL = nil
        }
    }

    private var usable: [Cloud.TranscriptLine] {
        lines.filter { !$0.trans.isEmpty || !$0.source.isEmpty }
    }

    private func lineText(_ l: Cloud.TranscriptLine) -> String {
        switch content {
        case "source": return l.source
        case "trans": return l.trans
        default:
            if l.trans.isEmpty { return l.source }
            if l.source.isEmpty || l.source == l.trans { return l.trans }
            return l.trans + "\n" + l.source
        }
    }

    private func plainText() -> String {
        let rows = usable.map { lineText($0) }.filter { !$0.isEmpty }
        guard !rows.isEmpty else { return "" }
        return rows.joined(separator: "\n\n") + "\n"
    }

    /// SRT：序号 + 时间码 + 文本，时间码按每句的落定时刻算，末句给 3 秒
    private func srtText() -> String {
        let rows = usable
        guard !rows.isEmpty else { return "" }
        let start = rows.first?.at ?? session.startedAt
        var out = ""
        for (i, l) in rows.enumerated() {
            let from = max(0, l.at.timeIntervalSince(start))
            let next = i + 1 < rows.count ? max(0, rows[i + 1].at.timeIntervalSince(start)) : from + 3
            let to = next > from ? next : from + 3
            out += "\(i + 1)\n"
            out += "\(Self.timecode(from)) --> \(Self.timecode(to))\n"
            out += "\(lineText(l))\n\n"
        }
        return out
    }

    private static func timecode(_ t: TimeInterval) -> String {
        let total = Int(t.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        let ms = Int(((t - floor(t)) * 1000).rounded())
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
    }
}
