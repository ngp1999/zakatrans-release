import Foundation
import AVFoundation

/// 输出音频：把翻译好的中文用系统语音读出来。
///
/// 三条硬要求：
/// 1. 开了朗读，别的 App（视频/音乐）要自动压低音量——不然两边声音叠在一起
///    根本听不清在念什么。用 .duckOthers：只压低，不暂停、不切断。
/// 2. 不打断：这一句念完再念下一句，最多积压 3 句，绝不"一有新句就掐断重来"。
/// 3. 不重复：同一句话可能被上游推好几次，这里按归一化文本去重，
///    而且停止之后（暂停状态）再进来的旧回调一律不念。
@MainActor
final class Speaker: NSObject, ObservableObject {
    static let shared = Speaker()

    @Published private(set) var speaking = false
    @Published var enabled = false
    @Published var rate: Double = 0.54

    private let synth = AVSpeechSynthesizer()

    /// 待念队列（不含正在念的那句）
    private var queue: [String] = []
    /// 最近说过的内容（归一化后）：同一句不管从哪个回调来都只念一次
    private var recentKeys: [String] = []
    /// 正在念的那句（原文，用于界面对比）
    private var current: String?
    /// 用户已经停止：之后进来的迟到回调一律丢掉，避免"暂停了还在念"
    private var paused = false

    private let maxQueue = 3
    private let recentLimit = 24

    override init() {
        super.init()
        synth.delegate = self
    }

    /// 只在这里切音频会话，而且只在真要出声前切。
    ///
    /// duckOthers：别的 App 音量自动压低（约 -20dB），念完恢复。
    /// 用 mixWithOthers 保证不会被系统判定成"要独占音频"，从而不会把对方视频停掉。
    private func configureSession() {
        let s = AVAudioSession.sharedInstance()
        do {
            try s.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers, .mixWithOthers])
            try s.setActive(true, options: [])
        } catch {
            // 拿不到会话也继续念：iOS 会用默认路由，最多是不压别人的音量
            try? s.setCategory(.playback, mode: .spokenAudio, options: [.mixWithOthers])
            try? s.setActive(true)
        }
    }

    /// 用户重新开始一场：解除暂停，清掉上一场残留
    func resume() {
        paused = false
        queue.removeAll()
        recentKeys.removeAll()
        current = nil
    }

    /// 新一句译文进来：排队，不打断正在念的
    func speak(_ text: String) {
        guard enabled, !paused else { return }
        let t = Self.clean(text)
        guard !t.isEmpty else { return }

        let key = Self.key(t)

        // 和正在念的一样 / 最近念过的（含"新句只是旧句的一部分"这种重复推送）→ 丢掉
        if let c = current, Self.key(Self.clean(c)) == key { return }
        if recentKeys.contains(key) { return }
        if recentKeys.contains(where: { $0.contains(key) && key.count * 3 >= $0.count * 2 }) { return }

        recentKeys.append(key)
        if recentKeys.count > recentLimit { recentKeys.removeFirst(recentKeys.count - recentLimit) }

        if synth.isSpeaking || current != nil {
            queue.append(t)
            if queue.count > maxQueue { queue.removeFirst(queue.count - maxQueue) }
        } else {
            play(t)
        }
    }

    private func play(_ t: String) {
        configureSession()
        current = t
        let u = AVSpeechUtterance(string: t)
        u.voice = Self.voice("zh-CN")
        u.rate = Float(max(0.40, min(0.62, rate)))
        u.pitchMultiplier = 1.0
        u.volume = 1.0
        u.postUtteranceDelay = 0
        u.preUtteranceDelay = 0
        synth.speak(u)
    }

    /// 试听：不排队，立刻念（不影响正式队列）
    func preview(_ text: String) {
        stopSpeaking()
        paused = false
        enabled = true
        play(text)
    }

    /// 界面上关掉开关 / 停止翻译：立刻闭嘴，并把别人的音量放回去
    func stop() {
        paused = true
        stopSpeaking()
        // 关掉 ducking 之后如果不还原，别的 App 会一直被压着
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .default, options: [.mixWithOthers])
    }

    private func stopSpeaking() {
        queue.removeAll()
        current = nil
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        speaking = false
    }

    // MARK: - 文本归一化 / 去重

    /// 去掉首尾空白、合并连续空白；标点不影响"是不是同一句"
    static func clean(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        t = t.replacingOccurrences(of: "\u{3000}", with: " ")
        while t.contains("  ") { t = t.replacingOccurrences(of: "  ", with: " ") }
        return t
    }

    static func key(_ s: String) -> String {
        let drop = CharacterSet(charactersIn: " \n\t，。、！？；：,.!?;:…—-\"'“”‘’()（）[]【】")
        return s.unicodeScalars.filter { !drop.contains($0) }.map { String($0) }.joined().lowercased()
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
            // 系统取消（来电、路由切换）：接着念下一条，别把队列卡死。
            // 但如果是用户点了停止就不动——那时 paused 已经是 true。
            if !self.paused && self.current != nil { self.next() }
        }
    }

    @MainActor
    private func next() {
        current = nil
        if paused || queue.isEmpty {
            speaking = false
            return
        }
        let t = queue.removeFirst()
        play(t)
    }
}

private extension Speaker {
    /// 中文优先用高质量女声，没有就回退系统默认
    static func voice(_ lang: String) -> AVSpeechSynthesisVoice? {
        let voices = AVSpeechSynthesisVoice.speechVoices()
        if let v = voices.first(where: { $0.language.hasPrefix("zh") && $0.quality == .enhanced }) {
            return v
        }
        return AVSpeechSynthesisVoice(language: lang)
    }
}
