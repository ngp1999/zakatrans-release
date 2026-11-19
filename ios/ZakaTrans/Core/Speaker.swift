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
    @Published var rate: Double = 0.58
    /// 别的 App 压到多少：0 = 不压（只混音），>0 = 系统压低（约 -20dB）
    @Published var duckLevel: Double = 60
    /// 音色：空 = 中文默认女声
    @Published var voiceId: String = ""

    private let synth = AVSpeechSynthesizer()

    /// 待念队列（不含正在念的那句）：文本 + 语言（同声传译要按语言换嗓子）
    private var queue: [(text: String, lang: String)] = []
    /// 最近说过的内容（归一化后）：同一句不管从哪个回调来都只念一次
    private var recentKeys: [String] = []
    /// 最近念过的句子 + 时间：用来把「我们自己念的声音又被录进去」的回声认出来
    private var spoken: [(key: String, at: Date)] = []
    /// 正在念的那句（原文，用于界面对比）
    private var current: String?
    /// 用户已经停止：之后进来的迟到回调一律丢掉，避免"暂停了还在念"
    private var paused = false

    private var gateTimer: Timer?

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
        // duckLevel = 0 就是「不压」：只混音，别人原样放
        let duck = duckLevel > 0
        let opts: AVAudioSession.CategoryOptions = duck ? [.duckOthers, .mixWithOthers] : [.mixWithOthers]
        do {
            try s.setCategory(.playback, mode: .spokenAudio, options: opts)
            try s.setActive(true, options: [])
        } catch {
            // 拿不到会话也继续念：iOS 会用默认路由，最多是不压别人的音量
            try? s.setCategory(.playback, mode: .spokenAudio, options: [.mixWithOthers])
            try? s.setActive(true)
        }
    }

    /// 这句是不是我们自己刚念出去的（被录屏又录回来一遍）
    /// 上游把我们的朗读当成人声识别，再翻一次推回来——既重复显示又重复念，必须认掉。
    func isEcho(_ texts: [String], within: TimeInterval = 20) -> Bool {
        let now = Date()
        spoken.removeAll { now.timeIntervalSince($0.at) > within }
        guard !spoken.isEmpty else { return false }
        for t in texts {
            let k = Self.key(Self.clean(t))
            if k.count < 3 { continue }
            for sp in spoken {
                if sp.key == k { return true }
                // 长句被切成两半再识别回来：一半能对上就算回声
                if sp.key.count >= 4 && (sp.key.contains(k) || k.contains(sp.key)) { return true }
            }
        }
        return false
    }

    /// 用户重新开始一场：解除暂停，清掉上一场残留
    func resume() {
        paused = false
        queue.removeAll()
        recentKeys.removeAll()
        current = nil
    }

    /// 新一句译文进来：排队，不打断正在念的
    func speak(_ text: String) { speak(text, lang: "zh") }

    /// 指定语言朗读：同声传译两边说的话要用各自的语言念
    func speak(_ text: String, lang: String) {
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

        let stamp = Date()
        spoken.append((key: key, at: stamp))
        if spoken.count > 30 { spoken.removeFirst(spoken.count - 30) }

        if synth.isSpeaking || current != nil {
            queue.append((text: t, lang: lang))
            if queue.count > maxQueue { queue.removeFirst(queue.count - maxQueue) }
        } else {
            play(t, lang: lang)
        }
    }

    private func play(_ t: String) { play(t, lang: "zh") }

    private func play(_ t: String, lang: String) {
        configureSession()
        current = t
        let u = AVSpeechUtterance(string: t)
        u.voice = Self.voice(voiceId, lang: lang)
        u.rate = Float(max(0.40, min(0.80, rate)))
        u.pitchMultiplier = 1.0
        // 压低别的 App 的时候自己可以响一点（相对更清楚）；不压的时候让一点，别盖住原声
        u.volume = duckLevel > 0 ? Float(0.9 + 0.1 * min(1, duckLevel / 100)) : 0.85
        u.postUtteranceDelay = 0
        u.preUtteranceDelay = 0
        synth.speak(u)
        openEchoGate()
    }

    /// 朗读门:念的时候给录屏那边留一个"我在出声"的时间戳,那边据此把这段音频丢掉。
    /// 系统录屏拿到的是混音,我们的朗读也在里面——送进上游就会被当成对方说话再翻一遍,
    /// 结果就是文本重复两遍、句子被切断、还白烧 token。
    private func openEchoGate() {
        let deadline = String(Int(Date().timeIntervalSince1970) + 2)
        ZKStore.setSetting("tts_gate", v: deadline)
        gateTimer?.invalidate()
        gateTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.synth.isSpeaking || self.current != nil {
                    ZKStore.setSetting("tts_gate", v: String(Int(Date().timeIntervalSince1970) + 2))
                } else {
                    self.closeEchoGate()
                }
            }
        }
    }

    private func closeEchoGate() {
        gateTimer?.invalidate()
        gateTimer = nil
        ZKStore.setSetting("tts_gate", v: "0")
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
        spoken.removeAll { Date().timeIntervalSince($0.at) > 20 }
        current = nil
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        speaking = false
        closeEchoGate()
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
            closeEchoGate()
            return
        }
        let item = queue.removeFirst()
        play(item.text, lang: item.lang)
    }
}

private extension Speaker {
    /// 用户选了音色就用它；没选就中文优先高质量女声，最后回退系统默认
    static func voice(_ id: String, lang: String = "zh") -> AVSpeechSynthesisVoice? {
        // 非中文：直接用那个语言的系统音色
        if !lang.hasPrefix("zh") {
            let all = AVSpeechSynthesisVoice.speechVoices()
            if let v = all.first(where: { $0.language == lang && $0.quality == .enhanced }) { return v }
            if let v = all.first(where: { $0.language == lang }) { return v }
            if let v = all.first(where: { $0.language.hasPrefix(lang) }) { return v }
            return AVSpeechSynthesisVoice(language: lang)
        }
        if !id.isEmpty, let v = AVSpeechSynthesisVoice(identifier: id) { return v }
        let voices = AVSpeechSynthesisVoice.speechVoices()
        if let v = voices.first(where: { $0.language.hasPrefix("zh") && $0.quality == .enhanced }) {
            return v
        }
        return AVSpeechSynthesisVoice(language: "zh-CN")
    }

    /// 可选的中文音色（给设置页列出来）
    static func zhVoices() -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("zh") }
            .sorted { a, b in
                if a.quality.rawValue != b.quality.rawValue { return a.quality.rawValue > b.quality.rawValue }
                return a.name < b.name
            }
    }
}
