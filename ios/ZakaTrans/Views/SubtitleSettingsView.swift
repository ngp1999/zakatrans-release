import SwiftUI

/// 字幕样式：显示什么、多大、什么颜色、什么背景、画中画比例。
/// 改一处立刻生效（App 内字幕和画中画同步），并自动同步到云端。
struct SubtitleSettingsView: View {
    @ObservedObject private var app = AppState.shared
    private let haptic = UIImpactFeedbackGenerator(style: .light)

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                previewCard
                styleCard
                pipCard
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 28)
        }
        .background(Theme.bg)
        .navigationTitle("字幕样式")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: 预览

    /// 预览高度固定：调字号时页面不会跟着往上下一跳。
    /// 字大了在框里居中裁切，不用撑高整个页面。
    private var previewCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 6) {
                    if app.prefs.mode != "source" {
                        Text("这段话是翻译后的中文效果预览")
                            .font(.system(size: app.prefs.size, weight: .semibold))
                            .foregroundStyle(Color(uiColor: app.prefs.effectiveColor))
                    }
                    if app.prefs.mode != "zh" {
                        Text("This is what the original line looks like")
                            .font(.system(size: max(12, app.prefs.size - 4)))
                            .foregroundStyle(Color(uiColor: app.prefs.secondaryColor))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
        }
        .frame(height: 120, alignment: .leading)
        .background(app.prefs.backgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.6)
        )
    }

    // MARK: 样式（一行一个控制）

    private var styleCard: some View {
        VStack(spacing: 18) {
            // 字号
            HStack {
                Text("字号").font(.system(size: 15)).foregroundStyle(Theme.ink)
                Spacer()
                Text("\(Int(app.prefs.size))")
                    .font(.system(size: 15, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.sub)
            }
            Slider(value: Binding(
                get: { app.prefs.size },
                set: { v in app.updatePrefs { $0.size = v } }
            ), in: 14...30, step: 1)
            .tint(Theme.accent)

            divider

            // 文字颜色：一行 7 个色块，不带文字
            HStack(spacing: 0) {
                ForEach(SubtitlePrefs.colors, id: \.0) { opt in
                    Button {
                        haptic.impactOccurred()
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

            // 背景颜色：一行 7 个色块，不带文字
            HStack(spacing: 0) {
                ForEach(SubtitlePrefs.backgrounds, id: \.0) { opt in
                    Button {
                        haptic.impactOccurred()
                        withAnimation(.easeOut(duration: 0.15)) {
                            app.updatePrefs { $0.background = opt.0 }
                        }
                    } label: {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Color(uiColor: opt.2))
                            .frame(height: 32)
                            .overlay(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .strokeBorder(
                                        app.prefs.background == opt.0 ? Theme.ink : Color.white.opacity(0.22),
                                        lineWidth: app.prefs.background == opt.0 ? 2.5 : 0.8
                                    )
                            )
                            .padding(.horizontal, 2)
                    }
                    .buttonStyle(.plain)
                }
            }

            divider

            // 显示什么
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

    // MARK: 窗口比例（画中画尺寸，选了就按这个大小开）

    private var pipCard: some View {
        VStack(spacing: 12) {
            HStack {
                Text("窗口比例").font(.system(size: 15)).foregroundStyle(Theme.ink)
                Spacer()
                Text(SubtitlePrefs.pipSizeText(app.prefs.pip))
                    .font(.system(size: 13).monospacedDigit())
                    .foregroundStyle(Theme.sub)
            }

            Picker("窗口比例", selection: Binding(
                get: { app.prefs.pip },
                set: { v in
                    haptic.impactOccurred()
                    app.updatePrefs { $0.pip = v }
                    app.setPip(true)
                }
            )) {
                ForEach(SubtitlePrefs.pipOptions, id: \.0) { opt in
                    Text(opt.1).tag(opt.0)
                }
            }
            .pickerStyle(.segmented)

            Text("选哪个，字幕浮窗开出来就是哪个大小；大 4:3 适合看整段，小 21:9 最窄最省屏。")
                .font(.system(size: 12))
                .foregroundStyle(Theme.faint)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .card(padding: 16)
    }
}
