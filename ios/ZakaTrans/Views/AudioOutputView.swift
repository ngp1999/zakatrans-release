import SwiftUI
import AVFoundation

/// 朗读设置：开关、语速、压低其他 App、试听。
/// 只放必要项，一屏放得下；音色固定用系统默认，不再给选项。
///
/// 性能注意：这一页以前每拖一下滑块就写一次设置 + 触发云同步 + 整页重排，所以糊。
/// 现在每根滑块自己持有拖动中的值，父页面不参与刷新，松手才落库。
struct AudioOutputView: View {
    /// 故意不用 @ObservedObject：这一页以前挂在 AppState 上，
    /// 同传跑起来时 AppState 每秒会推几十次，整页跟着重算，滑块就成了「拖一下就卡一下」。
    /// 这里只在打开时读一次初值，之后全靠本地状态，关掉时再落库。
    private let app = AppState.shared
    @ObservedObject private var speaker = Speaker.shared
    private let haptic = UIImpactFeedbackGenerator(style: .light)
    @Environment(\.dismiss) private var dismiss
    /// 由调用方接管关闭（首页是自绘半屏面板，不归系统 sheet 管）
    var onClose: (() -> Void)? = nil
    @State private var tts: Bool = AppState.shared.prefs.tts

    var body: some View {
        VStack(spacing: 0) {
            header
            FitScroll(cap: UIScreen.main.bounds.height * 0.60 - SafeArea.bottom) {
                VStack(spacing: 14) {
                    switchCard
                    RateCard()
                    DuckCard(duck: app.prefs.duckLevel)
                }
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .padding(.bottom, 10)
            }
        }
    }

    private var header: some View {
        ZStack {
            Text("音频输出")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.ink)
        }
        .padding(.horizontal, 16)
        .frame(height: 46)
    }

    private func dismissAudio() {
        if let onClose { onClose() } else { dismiss() }
    }

    private var switchCard: some View {
        Toggle(isOn: Binding(
            get: { tts },
            set: { v in
                haptic.impactOccurred()
                tts = v
                app.updatePrefs { $0.tts = v }
                if !v { Speaker.shared.stop() }
            }
        )) {
            VStack(alignment: .leading, spacing: 3) {
                Text("开启音频输出")
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.ink)
                Text("把译文读出来，原文不读")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.sub)
            }
        }
        .tint(Theme.accent)
        .card(padding: 16)
    }
}

// MARK: - 语速

private struct RateCard: View {
    private let app = AppState.shared
    @State private var value: Double = 0.62
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("语速")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.ink)
                Spacer()
                Text(String(format: "%.2fx", value))
                    .font(.system(size: 14, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.sub)
            }

            // 拖动期间只改本地状态，松手才写偏好和云同步
            FluidSlider(
                value: value,
                range: 0.42...0.80,
                step: 0.01,
                onChanged: { v in value = v },
                onEnded: { v in
                    value = v
                    app.updatePrefs { $0.speechRate = v }
                    Speaker.shared.rate = v
                }
            )

            Button {
                Speaker.shared.rate = value
                Speaker.shared.duckLevel = app.prefs.duckLevel
                Speaker.shared.voiceId = app.prefs.voiceId
                Speaker.shared.preview("这是现在的朗读效果，翻译结果会这样读出来。")
            } label: {
                Text("试听")
            }
            .buttonStyle(SecondaryButtonStyle())
        }
        .card(padding: 16)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            value = app.prefs.speechRate
            Speaker.shared.rate = value
        }
        .onReceive(app.$prefs.map(\.speechRate).removeDuplicates()) { v in
            if abs(v - value) > 0.001 { value = v }
        }
    }
}

// MARK: - 压低音量

private struct DuckCard: View {
    private let app = AppState.shared
    var duck: Double
    @State private var value: Double = 60
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("压低其他 App 声音")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.ink)
                Spacer()
                Text(value < 1 ? "不压低" : String(format: "%.0f%%", value))
                    .font(.system(size: 14, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.sub)
            }
            FluidSlider(
                value: value,
                range: 0...100,
                step: 5,
                onChanged: { v in value = v },
                onEnded: { v in
                    value = v
                    app.updatePrefs { $0.duckLevel = v }
                    Speaker.shared.duckLevel = v
                }
            )
        }
        .card(padding: 16)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            value = duck
            Speaker.shared.duckLevel = value
        }
    }
}
