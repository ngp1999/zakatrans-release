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
    @Published var rate: Double = 0.46
    /// 别的 App 压到多少：0 = 不压（只混音），>0 = 系统压低（约 -20dB）
    @Published var duckLevel: Double = 60
    /// 音色：空 = 中文默认女声
    @Published var voiceId: String = ""

    /// 同声传译正在跑（它自己占着 PlayAndRecord + voiceChat 的会话）。
    /// 这种时候朗读绝不能再把会话改成 .playback —— 一改录音链路就被切走，
    /// 用户看到的就是「开了朗读，翻译开始延迟、卡顿、整段不翻译」。
    var usesExternalSession = false

    /// 麦克风收音（同传、以及首页选了麦克风收音）。
    /// 这一路没有「系统声音」那一路可以让位，也就不能靠静音自己来防回声，
    /// 只能靠「只在别人说完的空隙里念 + 真有人开口就让路」。
    var micCapture = false

    private let synth = AVSpeechSynthesizer()

    /// 最近一次听到人说话（半句也算）的时间：朗读只在它之后安静够久了才开口。
    /// 这是「开了朗读就漏读、漏翻」的解法——不再一边念一边抢着听，
    /// 也不再整段整段地把原声静音掉。
    private var lastVoiceAt = Date.distantPast
    /// 原声停下多久之后才念一句译文。太短会和说话叠在一起，太长就落后。
    /// 等多久才开口。系统声音那一路可以等到对方彻底安静；麦克风这一路
    /// 一旦要求「完全安静」就永远轮不到自己（对话是连续的），于是开了音频输出
    /// 反而一句都不念——所以这边只让很小的一个空隙。
    private var quietGap: TimeInterval { micCapture ? 0.10 : 0.8 }
    /// 麦克风收音时说话是连续的，几乎没有"完全安静"的空隙。
    /// 只按空隙判会让队列一直排不上——听起来就是"开了音频输出没有声音"。
    /// 所以再给一条硬线：排在最前面的译文等够这么久，不管有没有空隙都念。
    private var starveGap: TimeInterval { micCapture ? 2.0 : 6.0 }
    private var flushTimer: Timer?

    /// 待念队列（不含正在念的那句）：文本 + 语言（同声传译要按语言换嗓子）
    private var queue: [(text: String, lang: String, at: Date)] = []
    /// 最近说过的内容（归一化后）：同一句不管从哪个回调来都只念一次
    private var recentKeys: [String] = []
    /// 最近念过的句子 + 时间：用来把「我们自己念的声音又被录进去」的回声认出来
    private var spoken: [(key: String, at: Date)] = []
    /// 正在念的那句（原文，用于界面对比）
    private var current: String?
    /// 用户已经停止：之后进来的迟到回调一律丢掉，避免"暂停了还在念"
    private var paused = false
    /// 这一句是什么时候开始念的（刚开口的半秒不理会上游的杂音）
    private var speechStartedAt: Date?
    /// 手动点播的保护窗口：在这之前，别人说话也不让路。
    /// 不设的话，点播放刚念出两个字，下一句落定就把它掐了——听着就是「没声音」。
    private var manualUntil = Date.distantPast

    private var gateTimer: Timer?
    private var gateOpenedAt: Date?
    /// 上一次配好的音频会话（避免每句都重配）
    private var configuredKey = ""

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
        // 同传模式：会话归 ZKInterpreter 管（PlayAndRecord + voiceChat，自带回声消除），
        // 这里一个字都不许动，动了麦克风就断。
        guard !usesExternalSession else { return }
        let s = AVAudioSession.sharedInstance()
        // duckLevel = 0 就是「不压」：只混音，别人原样放
        let duck = duckLevel > 0
        // 每念一句都 setCategory + setActive 是一次音频硬件重配，主线程会卡 100~300ms；
        // 连着念十几句就是一路顿。配置没变就直接复用。
        let key = duck ? "playback-duck-mix" : "playback-mix"
        if configuredKey == key { return }
        configuredKey = key
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
        lastVoiceAt = Date.distantPast
        speechStartedAt = nil
        flushTimer?.invalidate()
        flushTimer = nil
        queue.removeAll()
        recentKeys.removeAll()
        current = nil
        configuredKey = ""      // 下一句重新配会话（上一场可能被系统改过路由）
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
            queue.append((text: t, lang: lang, at: Date()))
            if queue.count > maxQueue { queue.removeFirst(queue.count - maxQueue) }
        } else {
            pump()
        }
    }

    /// 出下一句：只在对方说完的空隙里开口。
    ///
    /// 以前是「一有译文就念，念到下一句来」。一路念下去，系统声音那一路就得
    /// 一直把我们对外的静音门挂着——门挂着的时候人家说的话也一起被丢掉，
    /// 于是开了朗读就开始漏读、漏翻、译文对不上。现在译文先攒着，
    /// 等原声安静下来才念：门只开在本来就没人说话的缝隙里，一个字都丢不了。
    private func pump() {
        guard enabled, !paused else { return }
        guard current == nil, !synth.isSpeaking else { return }
        guard !queue.isEmpty else {
            closeEchoGate()
            return
        }
        let head = queue[0]
        let waiting = Date().timeIntervalSince(head.at)
        if Date().timeIntervalSince(lastVoiceAt) < quietGap && waiting < starveGap {
            scheduleFlush()
            return
        }
        let item = queue.removeFirst()
        play(item.text, lang: item.lang)
    }

    /// 有人在说话，暂时轮不到我们：过一会儿再来看看安静下来没有。
    private func scheduleFlush() {
        guard flushTimer == nil else { return }
        flushTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                guard !self.paused, self.enabled else {
                    self.flushTimer?.invalidate()
                    self.flushTimer = nil
                    return
                }
                let idle = !self.synth.isSpeaking && self.current == nil
                    && Date().timeIntervalSince(self.lastVoiceAt) >= self.quietGap
                if self.queue.isEmpty || idle {
                    self.flushTimer?.invalidate()
                    self.flushTimer = nil
                    self.pump()
                }
            }
        }
    }

    /// 上游听到声音了（半句也算）。两个用处：
    /// 1) 决定什么时候才轮到我们开口（只在空隙里念）；
    /// 2) 麦克风收音时，真有人在说话就立刻闭嘴让路——
    ///    这一路没有静音门可挂，不闭嘴就等于用朗读盖住了人家的话。
    /// - Parameter final: 这一条是不是整句落定。
    ///   半句（还在滚动的那几段）只用来更新"有人在说话"的时间，不再抢朗读。
    ///   以前半句也进 bargeIn：上游每秒推好几次半句，朗读刚开口就被掐掉，
    ///   一句都念不完，用户听到的就是"开了音频输出没有声音"。
    func noteInput(_ text: String?, final: Bool = false) {
        let t = Self.clean(text ?? "")
        guard t.count >= 2 else { return }
        // 自己念出去的声音又被录回来：不算「有人在说话」，否则会自己把自己打断
        if t.count >= 3, isEcho([t], within: 8) { return }
        lastVoiceAt = Date()
        guard micCapture, enabled, !paused, final else { return }
        // 手动点播的这一句优先：念完之前不让路，否则只能听到半句
        if Date() < manualUntil { return }
        // 刚开始念的这半秒不动它：那多半是我们自己的尾音，掐了就等于白念
        if let started = speechStartedAt, Date().timeIntervalSince(started) < 0.6 { return }
        // 整句落定了：让路。只停当前这句，排着的译文留着接着念。
        if synth.isSpeaking || current != nil {
            bargeIn()
        }
    }

    /// 让路：立刻停，把还没念的译文一起丢掉。
    /// 宁可少念一句，也不压着人说话——听漏的那一句没法补，读漏的这句字幕还在。
    private func bargeIn() {
        // 只停当前这句，不动后面排着的：以前这里把整队清空，
        // 对方一开口就把还没念的译文全扔掉，用户看到的就是「有时不读」。
        current = nil
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        speaking = false
        closeEchoGate()
    }

    private func play(_ t: String) { play(t, lang: "zh") }

    private func play(_ t: String, lang: String) {
        configureSession()
        current = t
        speechStartedAt = Date()
        let u = AVSpeechUtterance(string: t)
        u.voice = Self.voice(voiceId, lang: lang)
        u.rate = Float(max(0.30, min(0.60, rate)))
        u.pitchMultiplier = 1.0
        // 压低别的 App 的时候自己可以响一点（相对更清楚）；不压的时候让一点，别盖住原声
        u.volume = duckLevel > 0 ? Float(0.9 + 0.1 * min(1, duckLevel / 100)) : 0.85
        u.postUtteranceDelay = 0.08
        u.preUtteranceDelay = 0
        synth.speak(u)
        // 现在念的是哪种语言：同传那边据此只暂停「会被这句回声污染」的那一路收音，
        // 另一路继续听人说话——这样开着音频输出也不会漏读、漏翻。
        ZKStore.setSetting("tts_lang", v: lang)
        openEchoGate()
    }

    /// 朗读门：念的时候给录屏那边留一个"我在出声"的时间戳，那边据此把这段音频换成静音。
    ///
    /// 上一版的门是「整句 + 后面再挂 2 秒」，而朗读是一句接一句不停的，
    /// 门几乎一直开着 —— 对方说话的声音也跟着被丢掉，所以一开朗读就漏料、句子断。
    /// 现在改成：只在真出声的这段时间开，念完立刻关（didFinish → closeEchoGate）。
    private func openEchoGate() {
        if gateOpenedAt == nil { gateOpenedAt = Date() }
        refreshEchoGate()
        gateTimer?.invalidate()
        gateTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.synth.isSpeaking || self.current != nil {
                    self.refreshEchoGate()
                } else {
                    self.closeEchoGate()
                }
            }
        }
    }

    private func refreshEchoGate() {
        // 麦克风收音这一路不挂门：挂了就是把麦克风整段掐掉，
        // 那是「一开朗读就漏读」的直接原因。这一路靠 noteInput 让路来避回声。
        guard !micCapture else { return }
        guard let t = gateOpenedAt else { return }
        // 硬上限：SpeechSynthesizer 有时候不给 didFinish（语音包缺失、被系统掐），
        // 门不能就这么一直挂着，否则等于把整场音频都静音了。
        if Date().timeIntervalSince(t) > 30 {
            closeEchoGate()
            return
        }
        // 门要比当前晚 1.6 秒，而且要带小数。
        // 原来存的是整秒（Int(now)+1），now = 100.9 时门只剩 0.1 秒，
        // 朗读还在响门就过期了 —— 念出来的译文被麦克风收进去又翻译一遍，
        // 就是用户看到的「系统朗读的音频被识别并翻译」。
        let until = Date().timeIntervalSince1970 + 1.6
        ZKStore.setSetting("tts_gate", v: String(format: "%.3f", until))
    }

    private func closeEchoGate() {
        gateTimer?.invalidate()
        gateTimer = nil
        gateOpenedAt = nil
        // 不念了：清掉「正在念的语言」，麦克风那边两条通道都恢复收音
        ZKStore.setSetting("tts_lang", v: "")
        guard !micCapture else { return }
        // 念完别立刻放行：扬声器到麦克风还有一点尾音在路上，
        // 立刻关会把最后几个字漏进识别里。多留 0.8 秒再关。
        let tail = Date().timeIntervalSince1970 + 0.8
        ZKStore.setSetting("tts_gate", v: String(format: "%.3f", tail))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            if self.gateOpenedAt == nil { ZKStore.setSetting("tts_gate", v: "0") }
        }
    }

    /// 试听：不排队，立刻念（不影响正式队列）
    func preview(_ text: String) {
        stopSpeaking()
        paused = false
        enabled = true
        play(text)
    }

    /// 手动点播（同传气泡旁边那颗播放键）：点了就必须出声。
    ///
    /// 自动朗读那套门控（文本去重、等安静空隙、有人说话就绪让路）是为「边说边念」设计的，
    /// 手动点一下还按它走，就会出现三种「点了没声音」：
    ///   · 同一句点第二次被去重直接丢掉；
    ///   · 前面刚有人说话，排队等空隙，等两秒才响；
    ///   · 刚开口，下一句整句落定就把它让路掐掉。
    /// 所以这条通道绕开全部三条，另外两件事也要做：
    ///   · 同传的会话是 PlayAndRecord，不主动切扬声器的话声音走听筒，等于没声音；
    ///   · 给一个保护窗口，念完之前不让路。
    func playNow(_ text: String, lang: String) {
        let t = Self.clean(text)
        guard !t.isEmpty else { return }
        paused = false
        // 正在念的、排着队的一起清掉：用户点的是这一句
        stopSpeaking()
        configuredKey = ""
        if usesExternalSession {
            let s = AVAudioSession.sharedInstance()
            try? s.setActive(true)
            try? s.overrideOutputAudioPort(.speaker)
        } else {
            configureSession()
        }
        // 保护窗口：按字数估一个时长，念完之前别人开口也不掐
        manualUntil = Date().addingTimeInterval(min(14.0, Double(t.count) * 0.24 + 1.8))
        let key = Self.key(t)
        spoken.append((key: key, at: Date()))
        if spoken.count > 30 { spoken.removeFirst(spoken.count - 30) }
        play(t, lang: lang)
    }

    /// 界面上关掉开关 / 停止翻译：立刻闭嘴，并把别人的音量放回去
    func stop() {
        paused = true
        manualUntil = Date.distantPast
        stopSpeaking()
        configuredKey = ""
        // 同传还占着麦克风的时候，绝对不能把会话改成 .playback —— 那等于把录音掐了
        guard !usesExternalSession else { return }
        // 关掉 ducking 之后如果不还原，别的 App 会一直被压着
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .default, options: [.mixWithOthers])
    }

    private func stopSpeaking() {
        flushTimer?.invalidate()
        flushTimer = nil
        speechStartedAt = nil
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
            // 手动点播刚起头时会把上一句停掉，那一次取消不能当成"念完了"处理，
            // 否则会把刚设好的 current 清掉，听着就是点了没声。
            if Date() < self.manualUntil { return }
            // 系统取消（来电、路由切换）：接着念下一条，别把队列卡死。
            // 但如果是用户点了停止就不动——那时 paused 已经是 true。
            if !self.paused && self.current != nil { self.next() }
        }
    }

    @MainActor
    private func next() {
        current = nil
        speechStartedAt = nil
        if paused || queue.isEmpty {
            speaking = false
            closeEchoGate()
            return
        }
        // 下一句也照样要等空隙：一句念完不代表对方说完了
        pump()
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
        let wanted = id.isEmpty ? defaultVoiceId() : id
        if !wanted.isEmpty, let v = AVSpeechSynthesisVoice(identifier: wanted) { return v }
        let voices = AVSpeechSynthesisVoice.speechVoices()
        if let v = voices.first(where: { $0.language.hasPrefix("zh") && $0.quality == .enhanced }) {
            return v
        }
        return AVSpeechSynthesisVoice(language: "zh-CN")
    }
}

extension Speaker {
    /// 可选的中文音色：只留两个——婷婷、美嘉。
    /// 系统里还能列出十几个（含大量重复的方言包），全铺出来选择成本太高，
    /// 这两个是中文场景下最稳、覆盖最广的。
    static func voiceChoices() -> [(String, String)] {
        let all = AVSpeechSynthesisVoice.speechVoices()
        var out: [(String, String)] = []
        if let v = all.first(where: {
            $0.identifier.localizedCaseInsensitiveContains("Tingting")
                || $0.name.localizedCaseInsensitiveContains("Tingting")
                || $0.name.contains("婷婷")
        }) {
            out.append((v.identifier, "婷婷"))
        }
        if let v = all.first(where: {
            $0.identifier.localizedCaseInsensitiveContains("Meijia")
                || $0.name.localizedCaseInsensitiveContains("Meijia")
                || $0.name.contains("美嘉")
        }) {
            out.append((v.identifier, "美嘉"))
        }
        return out
    }

    /// 默认音色：有婷婷就用婷婷，没有就回到系统中文
    static func defaultVoiceId() -> String {
        voiceChoices().first?.0 ?? ""
    }

    /// 这个音色 id 在不在当前设备的可用列表里（换机型 / 语音包没下时会不在）
    static func isAvailable(_ id: String) -> Bool {
        guard !id.isEmpty else { return true }
        return AVSpeechSynthesisVoice(identifier: id) != nil
    }
}
