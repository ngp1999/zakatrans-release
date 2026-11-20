import SwiftUI

/// 字幕样式：字号、颜色、背景、显示什么、字幕浮窗大小。
/// 以 80% 高度的面板弹出（不再整屏），点面板外空白处关闭，右上角不放关闭按钮。
/// 改一处立刻生效，并自动同步到云端。
struct SubtitleSettingsView: View {
    @ObservedObject private var app = AppState.shared

    /// 拖动中的字号：只影响预览，松手才落库
    @State private var draftSize: Double = 20

    /// 预览播放：跟真实字幕一样一句一句推上来，不是一张静态图
    @State private var rollIndex: Int = 0
    @State private var ticker: Timer?

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView(showsIndicators: false) {
                VStack(spacing: 14) {
                    previewCard
                    styleCard
                    pipCard
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 24)
            }
        }
        .background(Theme.bg)
        .onAppear {
            draftSize = app.prefs.size
            startPreviewLoop()
        }
        .onDisappear {
            ticker?.invalidate()
            ticker = nil
        }
        .onChange(of: app.prefs.size) { v in draftSize = v }
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

    /// 预览就是真预览：窗口比例、字号算法、两行排布都跟画中画里一模一样，
    /// 只是整体按屏幕宽度等比缩了一下。里面跑着和真实字幕同样的推行动画。
    private var previewCard: some View {
        let m = previewMetrics
        let f = previewFonts(width: m.w, height: m.h)
        return ZStack {
            app.prefs.backgroundColor
            ZStack {
                previewLines(font: f)
                    .id(rollIndex)
                    .transition(.asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .opacity
                    ))
            }
            .padding(.horizontal, 6)
        }
        .frame(width: m.w, height: m.h)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.6)
        )
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func previewLines(font: (zh: CGFloat, src: CGFloat)) -> some View {
        let t = previewText
        VStack(spacing: 2) {
            if app.prefs.mode != "zh" {
                Text(t.1)
                    .font(.system(size: font.src))
                    .foregroundStyle(Color(uiColor: app.prefs.secondaryColor))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            if app.prefs.mode != "source" {
                Text(t.0)
                    .font(.system(size: font.zh, weight: .bold))
                    .foregroundStyle(Color(uiColor: app.prefs.effectiveColor))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .multilineTextAlignment(.center)
    }

    /// 窗口比例按所选档位来，宽度铺满卡片、高度按比例算；太高的档（4:3）限高，宽度同步收窄。
    private var previewMetrics: (w: CGFloat, h: CGFloat) {
        let ratio: CGFloat
        switch app.prefs.pip {
        case "W": ratio = 5.0
        case "M": ratio = 16.0 / 9.0
        case "S": ratio = 840.0 / 360.0
        default: ratio = 480.0 / 360.0
        }
        let screenW = UIScreen.main.bounds.width
        var w = screenW - 64
        var h = w / ratio
        let maxH: CGFloat = 172
        if h > maxH {
            h = maxH
            w = h * ratio
        }
        return (w, h)
    }

    /// 字号也按真窗口的算法走：全宽跟窗口高度走，竖排档按 480 宽的基准等比缩放。
    private func previewFonts(width: CGFloat, height: CGFloat) -> (zh: CGFloat, src: CGFloat) {
        if app.prefs.pip == "W" {
            let rows: CGFloat = app.prefs.mode == "bilingual" ? 2 : 1
            let base = min((height / rows) * 0.74, width / 20)
            let zh = max(8, min(48, base))
            return (zh, max(7, zh * 0.66))
        }
        let scale = width / 480.0
        let zh = max(8, min(50, draftSize * scale))
        return (zh, max(7, zh * 0.78))
    }

    /// 模拟真实字幕：有时一句，有时两句拼一行，按批次推进
    private var previewText: (String, String) {
        let s = Self.samples
        let i = rollIndex % s.count
        let a = s[i]
        guard app.prefs.pip == "W", rollIndex % 3 != 2 else { return a }
        let b = s[(i + 1) % s.count]
        return (a.0 + "　" + b.0, a.1 + "  " + b.1)
    }

    private static let samples: [(String, String)] = [
        ("这一段就是字幕实际显示的样子", "This is exactly how the subtitle looks"),
        ("字号、颜色、背景都会即时生效", "Size, color and background apply instantly"),
        ("说话人一句说完，字幕就跟着推上来", "Each finished sentence rolls up right away"),
        ("长句会自动收进窗口宽度里", "Long lines are fitted into the window width"),
    ]

    private func startPreviewLoop() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 2.6, repeats: true) { _ in
            withAnimation(.easeOut(duration: 0.26)) { rollIndex += 1 }
        }
    }

    // MARK: - 样式

    private var styleCard: some View {
        VStack(spacing: 14) {
            HStack {
                Text("字号").font(.system(size: 15)).foregroundStyle(Theme.ink)
                Spacer()
                Text("\(Int(draftSize))")
                    .font(.system(size: 15, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.sub)
            }
            FluidSlider(
                value: app.prefs.size,
                range: 14...50,
                step: 1,
                onChanged: { v in draftSize = v },
                onEnded: { v in
                    draftSize = v
                    app.updatePrefs { $0.size = v }
                }
            )
            if app.prefs.pip == "W" {
                Text("全宽窗按窗口高度自动排版，字号以窗口为准；这里的字号作用于 App 内预览和对话记录。")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.sub)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            divider

            // 文字颜色：一行色块，均分整行
            HStack(spacing: 0) {
                ForEach(SubtitlePrefs.colors, id: \.0) { opt in
                    Button {
                        Haptics.tap()
                        withAnimation(.easeOut(duration: 0.15)) {
                            app.updatePrefs { $0.color = opt.0 }
                        }
                    } label: {
                        Circle()
                            .fill(Color(uiColor: opt.2))
                            .frame(width: 30, height: 30)
                            .overlay(
                                Circle().strokeBorder(
                                    app.prefs.color == opt.0 ? Theme.ink : Color.white.opacity(0.22),
                                    lineWidth: app.prefs.color == opt.0 ? 2.5 : 0.8
                                )
                            )
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                }
            }

            divider

            // 背景颜色：6 个深色 + 1 个浅色，色块等分一整行、之间留缝，刚好铺满宽度
            HStack(spacing: 9) {
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
                            .frame(height: 44)
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
