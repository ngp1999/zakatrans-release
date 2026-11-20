import SwiftUI
import AVFoundation

/// 朗读设置：开关、语速、压低其他 App、音色。
/// 半屏弹窗里展示，一屏放得下，不用来回滚。
struct AudioOutputView: View {
    @ObservedObject private var app = AppState.shared
    @ObservedObject private var speaker = Speaker.shared
    private let haptic = UIImpactFeedbackGenerator(style: .light)

    /// 只列婷婷、美嘉两个
    private var voices: [(String, String)] { Speaker.voiceChoices() }

    @State private var draftRate: Double = 0.62
    @State private var draftDuck: Double = 60

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                switchCard
                rateCard
                duckCard
                voiceCard
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .background(Theme.bg)
        .navigationTitle("音频输出")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            draftRate = app.prefs.speechRate
            draftDuck = app.prefs.duckLevel
        }
        .onChange(of: app.prefs.speechRate) { v in draftRate = v }
        .onChange(of: app.prefs.duckLevel) { v in draftDuck = v }
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
                Text("开启音频输出")
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.ink)
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
                Text(String(format: "%.2fx", draftRate))
                    .font(.system(size: 14, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.sub)
            }
            FluidSlider(
                value: app.prefs.speechRate,
                range: 0.42...0.80,
                step: 0.01,
                onChanged: { v in draftRate = v },
                onEnded: { v in
                    draftRate = v
                    app.updatePrefs { $0.speechRate = v }
                    Speaker.shared.rate = v
                }
            )

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
                Text(draftDuck < 1 ? "不压低" : String(format: "%.0f%%", draftDuck))
                    .font(.system(size: 14, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.sub)
            }
            FluidSlider(
                value: app.prefs.duckLevel,
                range: 0...100,
                step: 5,
                onChanged: { v in draftDuck = v },
                onEnded: { v in
                    draftDuck = v
                    app.updatePrefs { $0.duckLevel = v }
                    Speaker.shared.duckLevel = v
                }
            )
        }
        .card(padding: 16)
    }

    private var voiceCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("音色")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.ink)

            VStack(spacing: 0) {
                if voices.isEmpty {
                    // 设备上还没下载中文语音包时的兜底，不让这一栏变空白
                    voiceRow(id: "", name: "系统默认")
                } else {
                    ForEach(Array(voices.enumerated()), id: \.offset) { i, v in
                        if i > 0 { Divider().opacity(0.4) }
                        voiceRow(id: v.0, name: v.1)
                    }
                }
            }
        }
        .card(padding: 16)
    }

    private func voiceRow(id: String, name: String) -> some View {
        Button {
            haptic.impactOccurred()
            app.updatePrefs { $0.voiceId = id }
            Speaker.shared.voiceId = id
            Speaker.shared.preview("你好，这是\(name)的声音。")
        } label: {
            HStack(spacing: 10) {
                Text(name)
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.ink)
                Spacer(minLength: 0)
                if app.prefs.voiceId == id || (id.isEmpty && app.prefs.voiceId.isEmpty) {
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
}
