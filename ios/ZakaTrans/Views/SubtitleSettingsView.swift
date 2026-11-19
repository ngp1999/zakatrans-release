import SwiftUI

/// 字幕设置：显示什么、多大、什么颜色、什么背景。
/// 改一处立刻生效（App 内字幕和画中画同步），并自动同步到云端。
struct SubtitleSettingsView: View {
    @ObservedObject private var app = AppState.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                previewCard
                languageCard
                appearanceCard
                pipCard
                if app.prefs.tts { speechCard }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 28)
        }
        .background(Theme.bg)
        .navigationTitle("字幕设置")
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
                            .foregroundStyle(app.prefs.background == "light" ? Color.black : app.prefs.swiftUIColor)
                    }
                    if app.prefs.mode != "zh" {
                        Text("This is what the original line looks like")
                            .font(.system(size: max(12, app.prefs.size - 4)))
                            .foregroundStyle(app.prefs.background == "light" ? Color.black.opacity(0.6) : Color.white.opacity(0.72))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
        }
        .frame(height: 118, alignment: .leading)
        .background(app.prefs.backgroundColor())
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(app.prefs.background == "none" ? 0.0 : 0.10), lineWidth: 0.6)
        )
    }

    // MARK: 语言

    private var languageCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "字幕内容")
            VStack(spacing: 0) {
                ForEach(Array(SubtitlePrefs.modeOptions.enumerated()), id: \.offset) { idx, opt in
                    if idx > 0 {
                        Rectangle().fill(Theme.line).frame(height: 0.5).padding(.leading, 16)
                    }
                    row(title: opt.1, selected: app.prefs.mode == opt.0) {
                        app.updatePrefs { $0.mode = opt.0 }
                    }
                }
            }
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        }
    }

    // MARK: 外观

    private var appearanceCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionLabel(text: "外观")

            VStack(spacing: 16) {
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

                Rectangle().fill(Theme.line).frame(height: 0.5)

                Text("颜色").font(.system(size: 15)).foregroundStyle(Theme.ink)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 5), spacing: 12) {
                    ForEach(SubtitlePrefs.colorOptions, id: \.0) { opt in
                        Button {
                            app.updatePrefs { $0.color = opt.0 }
                        } label: {
                            VStack(spacing: 5) {
                                Circle()
                                    .fill(Color(uiColor: SubtitlePrefs.uiColor(opt.0)))
                                    .frame(width: 28, height: 28)
                                    .overlay(
                                        Circle().strokeBorder(
                                            app.prefs.color == opt.0 ? Theme.accent : Theme.line,
                                            lineWidth: app.prefs.color == opt.0 ? 2.5 : 1
                                        )
                                    )
                                Text(opt.1)
                                    .font(.system(size: 10))
                                    .foregroundStyle(Theme.sub)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }

                Rectangle().fill(Theme.line).frame(height: 0.5)

                HStack {
                    Text("背景").font(.system(size: 15)).foregroundStyle(Theme.ink)
                    Spacer()
                }
                Picker("背景", selection: Binding(
                    get: { app.prefs.background },
                    set: { v in app.updatePrefs { $0.background = v } }
                )) {
                    ForEach(SubtitlePrefs.backgroundOptions, id: \.0) { opt in
                        Text(opt.1).tag(opt.0)
                    }
                }
                .pickerStyle(.segmented)
            }
            .card(padding: 16)
        }
    }

    // MARK: 画中画

    private var pipCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "画中画形态")
            VStack(spacing: 0) {
                ForEach(Array(SubtitlePrefs.pipOptions.enumerated()), id: \.offset) { idx, opt in
                    if idx > 0 {
                        Rectangle().fill(Theme.line).frame(height: 0.5).padding(.leading, 16)
                    }
                    row(title: opt.1, selected: app.prefs.pip == opt.0) {
                        app.updatePrefs { $0.pip = opt.0 }
                    }
                }
            }
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        }
    }

    // MARK: 朗读

    private var speechCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(text: "朗读")
            VStack(spacing: 12) {
                HStack {
                    Text("语速").font(.system(size: 15)).foregroundStyle(Theme.ink)
                    Spacer()
                    Text(String(format: "%.1fx", app.prefs.speechRate / 0.5))
                        .font(.system(size: 15, weight: .medium).monospacedDigit())
                        .foregroundStyle(Theme.sub)
                }
                Slider(value: Binding(
                    get: { app.prefs.speechRate },
                    set: { v in app.updatePrefs { $0.speechRate = v } }
                ), in: 0.4...0.62, step: 0.01)
                .tint(Theme.accent)

                Button {
                    Speaker.shared.rate = app.prefs.speechRate
                    Speaker.shared.preview("这是朗读效果，翻译结果会这样读出来。")
                } label: {
                    Text("试听")
                }
                .buttonStyle(SecondaryButtonStyle())
            }
            .card(padding: 16)
        }
    }

    private func row(title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).font(.system(size: 15)).foregroundStyle(Theme.ink)
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Theme.accent)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
