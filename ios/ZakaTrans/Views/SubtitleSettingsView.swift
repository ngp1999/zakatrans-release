import SwiftUI

/// 字幕样式：字号、颜色、背景、显示什么、字幕浮窗大小。
/// 以 80% 高度的面板弹出（不再整屏），点面板外空白处关闭，右上角不放关闭按钮。
/// 改一处立刻生效，并自动同步到云端。
struct SubtitleSettingsView: View {
    @ObservedObject private var app = AppState.shared

    /// 预览播放：跟真实字幕一模一样——一句一句推上来，不是一张静态图
    @State private var rollIndex: Int = 0
    @State private var ticker: Timer?

    var body: some View {
        VStack(spacing: 0) {
            header
            FitScroll(cap: UIScreen.main.bounds.height * 0.72 - SafeArea.bottom) {
                VStack(spacing: 14) {
                    previewCard
                    styleCard
                    pipCard
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 12)
            }
        }
        .onAppear {
            startPreviewLoop()
        }
        .onDisappear {
            ticker?.invalidate()
            ticker = nil
        }
        .onChange(of: app.prefs.pip) { _ in rollIndex += 1 }
    }

    private var header: some View {
        ZStack {
            VStack(spacing: 5) {
                Capsule()
                    .fill(Theme.faint.opacity(0.45))
                    .frame(width: 36, height: 4.5)
                Text("字幕样式")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.ink)
            }
        }
        .padding(.top, 8)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity)
        .frame(height: 56)
    }

    // MARK: - 预览

    /// 三档窗口的真实尺寸，和画中画里开出来的一模一样
    private var realDim: CGSize {
        switch app.prefs.pip {
        case "M": return CGSize(width: 840, height: 360)
        case "B": return CGSize(width: 1080, height: 640)
        default:  return CGSize(width: 1080, height: 216)
        }
    }

    /// 预览框：按真实窗口的宽高等比缩小，比例跟画中画完全一致
    private var previewMetrics: (w: CGFloat, h: CGFloat, k: CGFloat) {
        let dim = realDim
        let maxW = UIScreen.main.bounds.width - 32 - 32
        let maxH: CGFloat = app.prefs.pip == "X" ? 92 : 196
        let k = min(maxW / dim.width, maxH / dim.height)
        return (dim.width * k, dim.height * k, k)
    }

    /// 字号算法跟画中画里同一套，只是整体乘上缩放比 k
    private func previewFonts(width w: CGFloat, height h: CGFloat, k: CGFloat) -> (zh: CGFloat, src: CGFloat) {
        if app.prefs.pip == "X" {
            // 小档：只跟窗口长宽走，跟句子长短无关
            let f = min(realDim.width / 24.0, realDim.height / 4.5)
            let font = max(11.0, min(46.0, f)) * k
            return (font, font * 0.68)
        }
        // 竖排档：以 480×360 为基准，按面积比（开方）缩放
        let scale = max(0.45, min(2.10, sqrt((realDim.width * realDim.height) / (480.0 * 360.0))))
        let zh = max(9.5, min(58.0, app.prefs.size * scale)) * k
        return (zh, zh * 0.66)
    }

    /// 小档上屏的那一批：一两句，整批一起换
    private var wideBatch: (zh: String, src: String) {
        let n = Self.samples.count
        let a = Self.samples[rollIndex % n]
        let b = Self.samples[(rollIndex + 1) % n]
        // 两句拼一行常常塞不下，那就只放一句——跟真窗口的整批判定是同一个取舍
        let zhW = a.zh.count + b.zh.count
        if zhW <= 14 { return (a.zh + "\u{3000}" + b.zh, a.src + "  " + b.src) }
        return (a.zh, a.src)
    }

    /// 中档 / 大档：竖向多行，最新的在最下面，满了往上游——跟真实字幕流一样。
    /// 每句「中文在上、原文在下」，能站几行按窗口算，不写死。
    private var stackedBatch: [(zh: String, src: String)] {
        let m = previewMetrics
        let f = previewFonts(width: m.w, height: m.h, k: m.k)
        let rowH = (f.zh * 1.24 + f.src * 1.26) * (app.prefs.mode == "bilingual" ? 1.0 : 0.62)
        let can = max(2, Int((m.h - 10) / max(8, rowH + 3)))
        let total = Self.samples.count
        let start = rollIndex % total
        var out: [(zh: String, src: String)] = []
        for i in 0..<min(can, total) {
            out.append(Self.samples[(start + i) % total])
        }
        return out
    }

    private var previewCard: some View {
        let m = previewMetrics
        return ZStack {
            app.prefs.backgroundColor
            if app.prefs.pip == "X" {
                widePreview(m)
            } else {
                stackedPreview(m)
            }
        }
        .frame(width: m.w, height: m.h)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.6)
        )
        .frame(maxWidth: .infinity)
    }

    /// 小档（5:1）：中文一行在上、原文一行在下，整批换
    private func widePreview(_ m: (w: CGFloat, h: CGFloat, k: CGFloat)) -> some View {
        let f = previewFonts(width: m.w, height: m.h, k: m.k)
        let batch = wideBatch
        return VStack(spacing: max(1, m.h * 0.05)) {
            if app.prefs.mode != "source" {
                Text(batch.zh)
                    .font(.system(size: f.zh, weight: .bold))
                    .foregroundStyle(Color(uiColor: app.prefs.effectiveColor))
                    .lineLimit(2)
                    .minimumScaleFactor(1)
                    .multilineTextAlignment(.center)
            }
            if app.prefs.mode != "zh" {
                Text(batch.src)
                    .font(.system(size: f.src))
                    .foregroundStyle(Color(uiColor: app.prefs.secondaryColor).opacity(0.72))
                    .lineLimit(2)
                    .minimumScaleFactor(1)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding(.horizontal, 5)
        .id(rollIndex)
        .transition(.asymmetric(insertion: .offset(y: 5).combined(with: .opacity), removal: .opacity))
    }

    /// 中档 / 大档：竖排多行，看得见好几句在往上游
    private func stackedPreview(_ m: (w: CGFloat, h: CGFloat, k: CGFloat)) -> some View {
        let f = previewFonts(width: m.w, height: m.h, k: m.k)
        let items = stackedBatch
        return VStack(alignment: .leading, spacing: max(2, m.h * 0.012)) {
            ForEach(items.indices, id: \.self) { i in
                let it = items[i]
                VStack(alignment: .leading, spacing: max(0.5, m.h * 0.003)) {
                    if app.prefs.mode != "source" {
                        Text(it.zh)
                            .font(.system(size: f.zh, weight: .bold))
                            .foregroundStyle(Color(uiColor: app.prefs.effectiveColor))
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if app.prefs.mode != "zh" {
                        Text(it.src)
                            .font(.system(size: f.src))
                            .foregroundStyle(Color(uiColor: app.prefs.secondaryColor).opacity(0.72))
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .id(rollIndex)
        .transition(.asymmetric(insertion: .offset(y: 8).combined(with: .opacity), removal: .opacity))
    }

    /// 预览里念的是一段励志的话
    private static let samples: [(zh: String, src: String)] = [
        ("你走过的每一步都算数", "Every step you take counts"),
        ("慢一点没关系，别停下来", "Slow down if you must, just don't stop"),
        ("真正拉开差距的，是没人看见的时候", "What sets you apart happens when unseen"),
        ("把今天过好，明天自然会来", "Live today well and tomorrow will come"),
        ("你还年轻，可以成为任何你想成为的人", "You are young enough to be anyone you want"),
    ]

    private func startPreviewLoop() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 2.4, repeats: true) { _ in
            withAnimation(.easeOut(duration: 0.22)) { rollIndex += 1 }
        }
    }

    // MARK: - 样式

    private var styleCard: some View {
        VStack(spacing: 14) {
            // 字号已经全自动：每个窗口按自己的长宽算，长句靠换行，不再缩字。
            // 手动调字号那一栏因此没有意义了，整栏去掉。
            // 文字颜色：一行色块，均分整行
            HStack(spacing: 6) {
                ForEach(SubtitlePrefs.colors, id: \.0) { opt in
                    Button {
                        Haptics.tap()
                        withAnimation(.easeOut(duration: 0.15)) {
                            app.updatePrefs { $0.color = opt.0 }
                        }
                    } label: {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color(uiColor: opt.2))
                            .frame(maxWidth: .infinity)
                            .frame(height: 34)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(
                                    app.prefs.color == opt.0 ? Theme.ink : Color.white.opacity(0.20),
                                    lineWidth: app.prefs.color == opt.0 ? 2.2 : 0.8
                                )
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            divider

            // 背景颜色：7 个色块等分一整行、之间只留细缝，右边不留空
            HStack(spacing: 6) {
                ForEach(SubtitlePrefs.backgrounds, id: \.0) { opt in
                    Button {
                        Haptics.tap()
                        withAnimation(.easeOut(duration: 0.15)) {
                            app.updatePrefs { $0.background = opt.0 }
                        }
                    } label: {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Color(uiColor: opt.2))
                            .frame(maxWidth: .infinity)
                            .frame(height: 42)
                            .overlay(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .strokeBorder(
                                        app.prefs.background == opt.0 ? Theme.ink : Color.white.opacity(0.22),
                                        lineWidth: app.prefs.background == opt.0 ? 2.5 : 0.8
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            divider

            HStack {
                Text("字幕内容").font(.system(size: 15)).foregroundStyle(Theme.ink)
                Spacer()
            }
            Picker("字幕内容", selection: Binding(
                get: { app.prefs.mode },
                set: { v in app.updatePrefs { $0.mode = v } }
            )) {
                ForEach(SubtitlePrefs.modeOptions, id: \.0) { opt in
                    Text(opt.1).tag(opt.0)
                }
            }
            .pickerStyle(.segmented)
        }
        .card(padding: 16)
    }

    private var divider: some View {
        Rectangle().fill(Theme.line).frame(height: 0.5)
    }

    // MARK: - 字幕浮窗大小

    private var pipCard: some View {
        VStack(spacing: 10) {
            HStack {
                Text("字幕浮窗大小").font(.system(size: 15)).foregroundStyle(Theme.ink)
                Spacer()
            }
            Picker("窗口大小", selection: Binding(
                get: { app.prefs.pip },
                set: { v in
                    Haptics.tap()
                    app.updatePrefs { $0.pip = v }
                    app.setPip(true)
                }
            )) {
                ForEach(SubtitlePrefs.pipOptions, id: \.0) { opt in
                    Text(opt.1).tag(opt.0)
                }
            }
            .pickerStyle(.segmented)
        }
        .card(padding: 14)
    }
}
