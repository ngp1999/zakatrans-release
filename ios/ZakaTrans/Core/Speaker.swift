import Foundation
import AVFoundation

/// 输出音频：把翻译好的中文用系统语音读出来。
///
/// 同传场景的关键是「不打断」：这一句正在念，后面新来的句子排队等着，
/// 等这一句念完再接着念下一句，听起来是连贯的一条，而不是每来一句就掐断重来。
///
/// 同时也不能无限积压——排队超过 2 句时丢掉最旧的那句（保最新的），
/// 这样延迟最多落后一两句，不会越念越落后。
@MainActor
final class Speaker: NSObject, ObservableObject {
    static let shared = Speaker()

    @Published private(set) var speaking = false
    @Published var enabled = false
    @Published var rate: Double = 0.54

    private let synth = AVSpeechSynthesizer()

    /// 待念队列（不含正在念的那句）
    private var queue: [String] = []
    /// 最近说过的几句，防止同一句从不同回调重复进来时念两遍
    private var recent: [String] = []
    /// 正在念的那句
    private var current: String?

    private let maxQueue = 2

    override init() {
        super.init()
        synth.delegate = self
        configureSession()
    }

    private func configureSession() {
        // 只混音、不 duck：别的 App 的视频/音乐不会被压低或暂停。
        // 之前用了 .duckOthers，一开朗读对方的视频就哑了，就是这个原因。
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .spokenAudio, options: [.mixWithOthers])
        try? s.setActive(true)
    }

    /// 新一句译文进来：排队，不打断正在念的
    func speak(_ text: String) {
        guard enabled else { return }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        // 和正在念的、刚念过的重复就跳过（同一句会被多个回调推上来）
        if t == current { return }
        if recent.contains(t) { return }

        recent.append(t)
        if recent.count > 6 { recent.removeFirst(recent.count - 6) }

        if synth.isSpeaking || current != nil {
            queue.append(t)
            // 积压太多就丢最旧的，保证跟得上
            if queue.count > maxQueue {
                queue.removeFirst(queue.count - maxQueue)
            }
        } else {
            enqueue(t)
        }
    }

    private func enqueue(_ t: String) {
        current = t
        let u = AVSpeechUtterance(string: t)
        u.voice = Self.voice("zh-CN")
        u.rate = Float(max(0.4, min(0.62, rate)))
        u.pitchMultiplier = 1.0
        u.postUtteranceDelay = 0
        u.preUtteranceDelay = 0
        synth.speak(u)
    }

    /// 试听：不排队，立刻念
    func preview(_ text: String) {
        stop()
        enabled = true
        enqueue(text)
    }

    func stop() {
        queue.removeAll()
        current = nil
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        speaking = false
    }
}

extension Speaker: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didStart u: AVSpeechUtterance) {
        Task { @MainActor in self.speaking = true }
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        Task { @MainActor in self.next() }
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) {
        Task { @MainActor in
            // 被系统取消（来电、路由切换）时继续念下一条，不卡住队列
            if self.current != nil { self.next() }
        }
    }

    @MainActor
    private func next() {
        current = nil
        if queue.isEmpty {
            speaking = false
            return
        }
        let t = queue.removeFirst()
        enqueue(t)
    }
}

private extension Speaker {
    /// 中文优先用「婷婷/普通话」这类高质量音色，没有就回退系统默认
    static func voice(_ lang: String) -> AVSpeechSynthesisVoice? {
        let voices = AVSpeechSynthesisVoice.speechVoices()
        if let v = voices.first(where: { $0.language.hasPrefix("zh") && $0.quality == .enhanced }) {
            return v
        }
        return AVSpeechSynthesisVoice(language: lang)
    }
}
