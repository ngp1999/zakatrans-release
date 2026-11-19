import SwiftUI

/// 字幕设置：显示什么、多大、什么颜色、用什么样式。
/// 改一处改动立刻生效（App 内字幕和画中画同步），并自动同步到云端。
struct SubtitleSettingsView: View {
    @ObservedObject private var app = AppState.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                previewCard
                languageCard
                appearanceCard
                pipCard
                if app.prefs.tts { speechCard }
                footer
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

    private var previewCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            if app.prefs.mode != "source" {
                Text("这段话是翻译后的中文效果预览")
                    .font(.system(size: app.prefs.size, weight: .semibold))
                    .foregroundStyle(app.prefs.swiftUIColor)
            }
            if app.prefs.mode != "zh" {
                Text("This is what the original line looks like")
                    .font(.system(size: max(12, app.prefs.size - 5)))
                    .foregroundStyle(app.prefs.mode == "source" ? app.prefs.swiftUIColor : Theme.sub)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(previewBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.6)
        )
    }

    /// 预览底色模拟真实画面：黑底，才能看出白字/黄字的实际效果
    private var previewBackground: Color {
        app.prefs.style == "box" ? Color.black : Color.black.opacity(0.92)
    }

    // MARK: 语言

    private var languageCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(text: "字幕内容")
            VStack(spacing: 0) {
                ForEach(Array(SubtitlePrefs.modeOptions.enumerated()), id: \.offset) { idx, opt in
                    if idx > 0 {
                        Rectangle().fill(Theme.line).frame(height: 0.5).padding(.leading, 16)
                    }
                    Button {
                        app.updatePrefs { $0.mode = opt.0 }
                    } label: {
                        HStack {
                            Text(opt.1).font(.system(size: 15)).foregroundStyle(Theme.ink)
                            Spacer()
                            if app.prefs.mode == opt.0 {
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
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))

            HStack(spacing: 6) {
                Image(systemName: "globe")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.sub)
                Text("原文语言自动识别，译文固定为中文")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.sub)
            }
            .padding(.leading, 4)
        }
    }

    // MARK: 外观

    private var appearanceCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionLabel(text: "外观")

            VStack(spacing: 14) {
                // 字号
                HStack {
                    Text("字号").font(.system(size: 15)).foregroundStyle(Theme.ink)
                    Spacer()
                    Text("\(Int(app.prefs.size)) pt")
                        .font(.system(size: 14).monospacedDigit())
                        .foregroundStyle(Theme.sub)
                }
                Slider(value: Binding(
                    get: { app.prefs.size },
                    set: { v in app.updatePrefs { $0.size = v } }
                ), in: 13...30, step: 1)
                .tint(Theme.accent)

                Divider().overlay(Theme.line)

                // 颜色
                HStack {
                    Text("颜色").font(.system(size: 15)).foregroundStyle(Theme.ink)
                    Spacer()
                }
                HStack(spacing: 12) {
                    ForEach(SubtitlePrefs.colorOptions, id: \.0) { opt in
                        Button {
                            app.updatePrefs { $0.color = opt.0 }
                        } label: {
                            VStack(spacing: 5) {
                                Circle()
                                    .fill(Color(uiColor: swatch(opt.0)))
                                    .frame(width: 30, height: 30)
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
                    Spacer()
                }

                Divider().overlay(Theme.line)

                // 样式
                HStack {
                    Text("样式").font(.system(size: 15)).foregroundStyle(Theme.ink)
                    Spacer()
                }
                Picker("样式", selection: Binding(
                    get: { app.prefs.style },
                    set: { v in app.updatePrefs { $0.style = v } }
                )) {
                    ForEach(SubtitlePrefs.styleOptions, id: \.0) { opt in
                        Text(opt.1).tag(opt.0)
                    }
                }
                .pickerStyle(.segmented)
            }
            .card(padding: 16)
        }
    }

    private func swatch(_ name: String) -> UIColor {
        switch name {
        case "yellow": return UIColor(red: 1.0, green: 0.85, blue: 0.30, alpha: 1)
        case "cyan": return UIColor(red: 0.40, green: 0.90, blue: 0.95, alpha: 1)
        case "green": return UIColor(red: 0.55, green: 0.95, blue: 0.65, alpha: 1)
        case "black": return UIColor.black
        default: return UIColor.white
        }
    }

    // MARK: 画中画

    private var pipCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(text: "画中画形态")
            VStack(spacing: 0) {
                ForEach(Array(SubtitlePrefs.pipOptions.enumerated()), id: \.offset) { idx, opt in
                    if idx > 0 {
                        Rectangle().fill(Theme.line).frame(height: 0.5).padding(.leading, 16)
                    }
                    Button {
                        app.updatePrefs { $0.pip = opt.0 }
                    } label: {
                        HStack {
                            Text(opt.1).font(.system(size: 15)).foregroundStyle(Theme.ink)
                            Spacer()
                            if app.prefs.pip == opt.0 {
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
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))

            Text("横条模式把窗口做成 3.5:1，缩到最小也基本能一行放下整句，不会再被截断。")
                .font(.system(size: 12))
                .foregroundStyle(Theme.sub)
                .padding(.leading, 4)
        }
    }

    // MARK: 朗读

    private var speechCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionLabel(text: "朗读")
            VStack(spacing: 12) {
                HStack {
                    Text("语速").font(.system(size: 15)).foregroundStyle(Theme.ink)
                    Spacer()
                    Text(String(format: "%.1fx", app.prefs.speechRate / 0.5))
                        .font(.system(size: 14).monospacedDigit())
                        .foregroundStyle(Theme.sub)
                }
                Slider(value: Binding(
                    get: { app.prefs.speechRate },
                    set: { v in app.updatePrefs { $0.speechRate = v } }
                ), in: 0.35...0.6, step: 0.01)
                .tint(Theme.accent)

                Button {
                    Speaker.shared.enabled = true
                    Speaker.shared.rate = app.prefs.speechRate
                    Speaker.shared.speak("这是朗读效果，翻译结果会这样读出来。")
                } label: {
                    Text("试听")
                }
                .buttonStyle(SecondaryButtonStyle())
            }
            .card(padding: 16)
        }
    }

    private var footer: some View {
        Text("设置会自动同步到云端，换设备登录同一个 Apple ID 就能带回来。")
            .font(.system(size: 12))
            .foregroundStyle(Theme.faint)
            .multilineTextAlignment(.center)
            .padding(.top, 4)
    }
}
