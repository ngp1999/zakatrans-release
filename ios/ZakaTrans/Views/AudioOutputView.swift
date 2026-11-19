import SwiftUI
import AVFoundation

/// 朗读设置：开关、语速、压低其他 App、音色。
/// 改一项立刻生效，并同步到云端（换手机回来还是这套）。
struct AudioOutputView: View {
    @ObservedObject private var app = AppState.shared
    @ObservedObject private var speaker = Speaker.shared
    private let haptic = UIImpactFeedbackGenerator(style: .light)

    private var voices: [AVSpeechSynthesisVoice] { Speaker.zhVoices() }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                switchCard
                rateCard
                duckCard
                voiceCard
                noteCard
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 28)
        }
        .background(Theme.bg)
        .navigationTitle("朗读设置")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var switchCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: Binding(
                get: { app.prefs.tts },
                set: { v in
                    haptic.impactOccurred()
                    app.updatePrefs { $0.tts = v }
                    if !v { Speaker.shared.stop() }
                }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("开启音频输出")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.ink)
                    Text("把译文用语音读出来，边说边显示")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.sub)
                }
            }
            .tint(Theme.accent)
        }
        .card(padding: 16)
    }

    private var rateCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("语速")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.ink)
                Spacer()
                Text(String(format: "%.2fx", app.prefs.speechRate))
                    .font(.system(size: 14, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.sub)
            }
            Slider(value: Binding(
                get: { app.prefs.speechRate },
                set: { v in app.updatePrefs { $0.speechRate = v } }
            ), in: 0.42...0.80, step: 0.01)
            .tint(Theme.accent)

            HStack {
                Text("慢")
                    .font(.system(size: 11)).foregroundStyle(Theme.faint)
                Spacer()
                Text("快")
                    .font(.system(size: 11)).foregroundStyle(Theme.faint)
            }

            Button {
                Speaker.shared.rate = app.prefs.speechRate
                Speaker.shared.duckLevel = app.prefs.duckLevel
                Speaker.shared.voiceId = app.prefs.voiceId
                Speaker.shared.preview("这是现在的朗读效果，翻译结果会这样读出来。")
            } label: {
                Text("试听")
            }
            .buttonStyle(SecondaryButtonStyle())
        }
        .card(padding: 16)
    }

    private var duckCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("压低其他 App 声音")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.ink)
                Spacer()
                Text(app.prefs.duckLevel < 1 ? "不压低" : String(format: "%.0f%%", app.prefs.duckLevel))
                    .font(.system(size: 14, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.sub)
            }
            Slider(value: Binding(
                get: { app.prefs.duckLevel },
                set: { v in app.updatePrefs { $0.duckLevel = v } }
            ), in: 0...100, step: 5)
            .tint(Theme.accent)

            Text("朗读时把视频、音乐的音量压下去，念完自动还原。滑到最左边就是不压，两边一起响。")
                .font(.system(size: 12))
                .foregroundStyle(Theme.faint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .card(padding: 16)
    }

    private var voiceCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("音色")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.ink)

            VStack(spacing: 0) {
                voiceRow(id: "", name: "系统默认（推荐）", detail: "中文女声，清楚不费劲")
                ForEach(voices, id: \.identifier) { v in
                    Divider().opacity(0.4)
                    voiceRow(id: v.identifier,
                             name: v.name,
                             detail: v.quality == .enhanced ? "增强音质 · \(v.language)" : v.language)
                }
            }
        }
        .card(padding: 16)
    }

    private func voiceRow(id: String, name: String, detail: String) -> some View {
        Button {
            haptic.impactOccurred()
            app.updatePrefs { $0.voiceId = id }
            Speaker.shared.voiceId = id
            Speaker.shared.preview("你好，这是这个音色的效果。")
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.ink)
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.faint)
                }
                Spacer(minLength: 0)
                if app.prefs.voiceId == id {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Theme.accent)
                }
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var noteCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("关于声音")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.ink)
            Text("开着朗读时，手机自己念出来的声音也会被录屏一起录进去一点。App 会自动把这类回声滤掉，不会重复显示、也不会重复念。")
                .font(.system(size: 12))
                .foregroundStyle(Theme.sub)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 16)
    }
}
