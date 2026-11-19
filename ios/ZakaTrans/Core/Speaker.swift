import Foundation
import AVFoundation

/// 输出音频：把翻译好的中文用系统语音读出来。
///
/// 同传场景要「跟得上」，所以策略是打断式——新一句来了就停掉上一句，
/// 不排队、不积压。系统 TTS 是本地能力，不联网、不额外扣费。
@MainActor
final class Speaker: NSObject, ObservableObject {
    static let shared = Speaker()

    @Published private(set) var speaking = false
    @Published var enabled = false
    @Published var rate: Double = 0.48

    private let synth = AVSpeechSynthesizer()
    private var lastSpoken = ""

    override init() {
        super.init()
        synth.delegate = self
        configureSession()
    }

    private func configureSession() {
        // 和画中画、录屏共用音频会话：用 .playback + mixWithOthers，不打断别人的播放
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .spokenAudio,
                           options: [.mixWithOthers, .duckOthers])
        try? s.setActive(true)
    }

    func speak(_ text: String, language: String = "zh-CN") {
        guard enabled else { return }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t != lastSpoken else { return }
        // 只念中文译文；纯英文的原文不念，避免中英混读
        lastSpoken = t
        if synth.isSpeaking {
            synth.stopSpeaking(at: .immediate)
        }
        let u = AVSpeechUtterance(string: t)
        u.voice = Self.voice(language)
        u.rate = Float(max(0.3, min(0.65, rate)))
        u.pitchMultiplier = 1.0
        u.postUtteranceDelay = 0
        synth.speak(u)
    }

    func stop() {
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        speaking = false
    }

    /// 中文优先用「婷婷/普通话」这类高质量音色，没有就回退系统默认
    private static func voice(_ lang: String) -> AVSpeechSynthesisVoice? {
        let voices = AVSpeechSynthesisVoice.speechVoices()
        if let v = voices.first(where: { $0.language.hasPrefix("zh") && $0.quality == .enhanced }) {
            return v
        }
        return AVSpeechSynthesisVoice(language: lang)
    }
}

extension Speaker: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didStart u: AVSpeechUtterance) {
        Task { @MainActor in self.speaking = true }
    }
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        Task { @MainActor in self.speaking = s.isSpeaking }
    }
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) {
        Task { @MainActor in self.speaking = false }
    }
}
