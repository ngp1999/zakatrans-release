import SwiftUI

/// 字幕样式：字号、颜色、背景、显示什么，以及字幕浮窗开关与窗口大小。
/// 改一处立刻生效（App 内字幕和画中画同步），并自动同步到云端。
struct SubtitleSettingsView: View {
    @ObservedObject private var app = AppState.shared
    private let haptic = UIImpactFeedbackGenerator(style: .light)

    /// 拖动中的字号：只影响预览，松手才落库
    @State private var draftSize: Double = 20

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
        .onAppear { draftSize = app.prefs.size }
        .onChange(of: app.prefs.size) { v in draftSize = v }
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
                            .font(.system(size: draftSize, weight: .semibold))
                            .foregroundStyle(Color(uiColor: app.prefs.effectiveColor))
                    }
                    if app.prefs.mode != "zh" {
                        Text("This is what the original line looks like")
                            .font(.system(size: max(12, draftSize - 4)))
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

    // MARK: 样式

    private var styleCard: some View {
        VStack(spacing: 16) {
            // 字号
            HStack {
                Text("字号").font(.system(size: 15)).foregroundStyle(Theme.ink)
                Spacer()
                Text("\(Int(draftSize))")
                    .font(.system(size: 15, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.sub)
            }
            FluidSlider(
                value: app.prefs.size,
                range: 14...30,
                step: 1,
                onChanged: { v in draftSize = v },
                onEnded: { v in
                    draftSize = v
                    app.updatePrefs { $0.size = v }
                }
            )

            divider

            // 文字颜色：一行色块
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

            // 背景颜色：一行色块
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
                            .frame(height: 40)
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

    // MARK: 字幕浮窗（开关 + 大小）

    private var pipCard: some View {
        VStack(spacing: 14) {
            HStack {
                Text("字幕浮窗").font(.system(size: 15)).foregroundStyle(Theme.ink)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { app.pipOn },
                    set: { v in
                        haptic.impactOccurred()
                        app.setPip(v)
                    }
                ))
                .labelsHidden()
                .tint(Theme.accent)
            }

            VStack(spacing: 8) {
                HStack {
                    Text("窗口大小").font(.system(size: 15)).foregroundStyle(Theme.ink)
                    Spacer()
                }
                Picker("窗口大小", selection: Binding(
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
            }
        }
        .card(padding: 14)
    }
}
