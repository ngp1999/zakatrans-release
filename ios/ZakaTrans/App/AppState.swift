import SwiftUI
import UIKit
import AVFoundation

/// 全局状态：把 SwiftUI 界面和底下的原生引擎连起来。
///
/// 音频链路：录屏扩展 → 共享容器/TCP → SpeechStream → 后端识别；
/// 界面这边只负责按钮、字幕、积分和朗读。
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var running = false
    /// 点完「开始」到字幕浮窗真正出来这段：按钮显示加载态
    @Published var preparing = false
    @Published var status = "未开始"
    @Published var liveSource = ""
    @Published var liveTrans = ""
    @Published var lines: [SubtitleLine] = []

    // 实时字幕的上屏节奏：先按「整句」攒，整句一落定就立刻上屏原文，
    // 译文到了再就地补上去，等译文的时间不占用上屏速度。
    private var pendSrc = ""
    private var pendZh = ""
    private var pendAt = Date()
    // 已经落成一行的那条原文（译文迟到时按这个位置补回去）
    private var lastLineKey = ""
    private var lastLineAt = Date.distantPast
    private var pendTimer: DispatchWorkItem?
    @Published var alert: String?
    @Published var prefs: SubtitlePrefs = SubtitlePrefs.load()
    /// 音频到底有没有进来：录屏扩展每秒写心跳，这里对帧数做差。
    /// 用户说「开了扩展没声音、不出字」时，一眼就能看到是没收到音频还是收到了没翻出来。
    @Published var audioHint = ""
    private var lastBufs = -1
    private var lastBufsAt: TimeInterval = 0

    /// 画中画：用户想不想开（持久化），以及此刻是否真的在屏幕上
    @Published var pipOn: Bool = (UserDefaults.standard.object(forKey: "zt_pip_on") as? Bool) ?? true
    @Published var pipActive = false

    /// 头像：没有就是系统灰头像；换过就存本机（照片不出设备，也不上传）
    @Published var avatarImage: UIImage? = AvatarStore.load()

    func setAvatar(_ image: UIImage?) {
        avatarImage = image
        AvatarStore.save(image)
        let b64 = AvatarStore.base64() ?? ""
        Task {
            // 换头像要「实时同步到服务器」：一次不成就再试一次，
            // 成了把 /v1/me 拉一遍，服务端那份和本机这份始终是一张图。
            var ok = await Cloud.shared.uploadAvatar(b64)
            if !ok {
                try? await Task.sleep(nanoseconds: 900_000_000)
                ok = await Cloud.shared.uploadAvatar(b64)
            }
            if ok { await Cloud.shared.refresh() }
        }
    }

    struct SubtitleLine: Identifiable, Equatable {
        let id = UUID()
        let source: String
        var trans: String
        let at = Date()
    }

    /// 画中画需要一个真实的 UIView 当锚点。
    /// 这个视图挂在 MainView 最外层（不是某个页面里），切 Tab、开抽屉都不会让它离开窗口——
    /// 一离开窗口系统就会把画中画收掉，这也是之前「回桌面就没了」的一半原因。
    weak var anchorView: UIView?

    private var broadcastTimer: Timer?
    private var pipPollTimer: Timer?
    private var audioTimer: Timer?
    private var sessionStartAt: TimeInterval = 0
    private var broadcastSeen = false
    private var pipRequested = false

    /// 同一句最终译文可能被回调推两次，这里做去重
    private var recentFinalKeys: [String] = []

    /// 后台保活：没有它，App 一回桌面就被挂起，画中画里字幕会停在那儿不动
    private let keeper = SilentKeeper()

    private init() {
        if prefs.voiceId.isEmpty || !Speaker.isAvailable(prefs.voiceId) {
            prefs.voiceId = Speaker.defaultVoiceId()
        }
        bindEngine()
        applyPrefsToEngine()
        bindLifecycle()
    }

    // MARK: - 整句上屏

    /// 上屏前把**句尾**的标点去掉（句子中间的保留）。
    /// 一句话说完就是完了，行尾再挂一个「。」既占位又难看；
    /// 「你好，我想问一下」中间那个逗号要留着，不然读不通。
    static func trimEndPunct(_ s: String) -> String {
        var t = s
        let drop: Set<Character> = ["。", "！", "？", "，", "、", "；", "：",
                                    ".", ",", "!", "?", ";", ":", "…", " ", "\u{3000}"]
        while let c = t.last, drop.contains(c) { t.removeLast() }
        return t
    }

    /// 译文/原文收尾了没有：带句末标点就算说完了。
    static func endsSentence(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = t.unicodeScalars.last else { return false }
        if "。！？!?…；;.".unicodeScalars.contains(last) { return true }
        return false
    }

    private static func hanCount(_ s: String) -> Int {
        return s.unicodeScalars.filter { $0.value >= 0x3400 && $0.value <= 0x9FFF }.count
    }

    private static func wordCount(_ s: String) -> Int {
        return s.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).count
    }

    /// 这段是新一句，还是上一句的尾巴？
    /// 上一句没说完 → 接上；上一句已经收尾 → 只有「一个词」或三字以内的碎片才接。
    /// 以前英文放到 40 字符、中文放到 14 字都当尾巴，结果连着几句完整的话被焊成一大条
    /// （截图里那条「你叫什么名字? / What are you doing? How much? Welcome to China.」就是它们拼的）。
    static func tailGlued(_ t: String, prev: String, gap: Double) -> Bool {
        guard !prev.isEmpty, gap >= 0, gap <= 1.8 else { return false }
        if hanCount(prev) >= 45 || prev.count >= 140 { return false }   // 已经够长，不再接
        if !endsSentence(prev) { return true }
        let han = hanCount(t)
        if han > 0 { return han <= 3 && !endsSentence(t) }
        return wordCount(t) <= 1
    }

    static func join(_ a: String, _ b: String) -> String {
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        guard let last = a.unicodeScalars.last, let first = b.unicodeScalars.first else { return a + b }
        let punct = "，。！？；：、,.!?;:".unicodeScalars
        if punct.contains(last) { return a + b }
        if last.value >= 0x2E80 || first.value >= 0x2E80 { return a + b }
        return a + " " + b
    }

    private func armPendFlush(_ delay: Double) {
        pendTimer?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.flushPending()
        }
        pendTimer = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    /// 把这句落成一行：有译文带译文，没译文就只有原文一行。
    private func flushPending() {
        pendTimer?.cancel()
        pendTimer = nil
        let src = AppState.trimEndPunct(pendSrc.trimmingCharacters(in: .whitespacesAndNewlines))
        let zh = AppState.trimEndPunct(pendZh.trimmingCharacters(in: .whitespacesAndNewlines))
        pendSrc = ""
        pendZh = ""
        guard !src.isEmpty || !zh.isEmpty else { return }
        let key = Speaker.key(src) + "\u{1}" + Speaker.key(zh)
        if recentFinalKeys.contains(key) { return }
        recentFinalKeys.append(key)
        if recentFinalKeys.count > 40 {
            recentFinalKeys.removeFirst(recentFinalKeys.count - 40)
        }
        lines.append(SubtitleLine(source: src, trans: zh))
        lastLineKey = Speaker.key(src)
        lastLineAt = Date()
        if lines.count > 200 { lines.removeFirst(lines.count - 200) }
        ZKPip.shared()!.appendLineEn(src, zh: zh)
    }

    // MARK: - 引擎回调

    private func bindEngine() {
        let s = ZKSpeechStream.shared()!
        s.onPartial = { [weak self] stable, unstable in
            guard let self else { return }
            let t = (stable ?? "") + (unstable ?? "")
            // 有人在说话：朗读据此避让，只在空隙里念（麦克风收音时还会让路）
            Speaker.shared.noteInput(t)
            self.liveSource = t
            ZKPip.shared()!.setLiveEn(t, zh: self.liveTrans)
        }
        s.onSegment = { [weak self] text, _ in
            guard let self else { return }
            let raw = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { return }
            self.liveSource = raw
            // 整句落定才算「该让路了」：半句还在滚动的时候朗读照念，
            // 否则每秒好几次的半句会把刚开口的那句一直掐掉，听起来就是没声音。
            Speaker.shared.noteInput(raw, final: true)

            if !self.pendSrc.isEmpty {
                let gap = Date().timeIntervalSince(self.pendAt)
                if AppState.tailGlued(raw, prev: self.pendSrc, gap: gap) {
                    self.pendSrc = AppState.join(self.pendSrc, raw)
                    self.pendAt = Date()
                    ZKPip.shared()!.showLiveEn(self.pendSrc, zh: self.pendZh)
                    self.armPendFlush(0)
                    return
                }
                // 换了一句：上一句先落定（译文早就到了的话一起带走）
                self.flushPending()
            }
            self.pendSrc = raw
            self.pendZh = ""
            self.pendAt = Date()
            ZKPip.shared()!.showLiveEn(raw, zh: "")
            // 不压时间：上游整句一落定就上屏。
            // 前几版这里压 1.6~2.2 秒等译文和尾巴，用户看到的就是「字幕慢半拍」；
            // 译文晚到另有通路——落在上一行原地补（见 onTransSegment），所以不用等。
            self.armPendFlush(0)
        }
        s.onTransPartial = { [weak self] delta in
            guard let self else { return }
            self.liveTrans += delta ?? ""
        }
        s.onTransSegment = { [weak self] full in
            guard let self else { return }
            let zh = (full ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            self.liveTrans = ""
            guard !zh.isEmpty else { return }
            // 没有对应的原文：这句的原文已经落过一行了。
            // 译文比原文晚到（整句先落、译文再补）时原地补到那一行上，
            // 不能直接丢掉——丢了界面上就是「只有原文、一句译文都没有」。
            guard !self.pendSrc.isEmpty else {
                // 译文比原文晚到：原文那行已经上屏了，原地把译文补上去。
                // 从前往后找第一条还没有译文的行（译文按说话顺序到，先补最早那条），
                // 连续两句原文都还没译文时不会一直往最后一行上堆。
                guard let idx = self.lines.firstIndex(where: {
                    $0.trans.isEmpty && Date().timeIntervalSince($0.at) < 20
                }) else { return }
                let t = AppState.trimEndPunct(zh)
                self.lines[idx].trans = t
                // 画中画读的是共享字幕流，那边也得补上——以前只改了内存里这份，
                // 所以 App 内对话记录有译文、画中画永远只有原文
                ZKPip.shared()!.patchZh(t, forEn: self.lines[idx].source)
                return
            }
            // 回声先拦：这句话是我们自己刚念出去的，被录屏录回来又识别了一遍
            if self.prefs.tts && Speaker.shared.isEcho([zh, self.pendSrc]) {
                self.pendSrc = ""
                self.pendZh = ""
                return
            }
            self.pendZh = self.pendZh.isEmpty ? zh : AppState.join(self.pendZh, zh)
            ZKPip.shared()!.showLiveEn(self.pendSrc, zh: self.pendZh)
            // 译文到了就落定，不再等尾巴
            self.armPendFlush(0)
        }
        s.onDiag = { [weak self] d in
            guard let self, let d, !d.isEmpty else { return }
            if d.contains("连接") || d.contains("监听") || d.contains("启动") {
                self.status = self.running ? "正在听" : "未开始"
            }
        }
    }

    // MARK: - 前后台

    private func bindLifecycle() {
        let c = NotificationCenter.default
        c.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.onWillBackground() }
        }
        c.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.onForeground() }
        }
    }

    /// 要进后台了：画中画必须在还处于前台时起来。
    /// 系统不允许在后台启动 PiP，所以这里是最后一个机会窗口。
    private func onWillBackground() {
        guard running, pipOn else { return }
        keeper.start()
        if !ZKPip.shared()!.isActive() {
            pipRequested = true
            startPipIfPossible()
        }
    }

    /// 回到前台：画中画不该因为切出去就消失，没了就补起来
    private func onForeground() {
        guard running else { return }
        keeper.start()
        if pipOn && broadcastSeen && !ZKPip.shared()!.isActive() {
            pipRequested = true
            startPipIfPossible()
        }
        pipActive = ZKPip.shared()!.isActive()
    }

    /// 把当前的样式设置推给画中画和引擎
    func applyPrefsToEngine() {
        ZKPip.applyStyle([
            "size": prefs.size,
            "color": prefs.color,
            "background": prefs.background,
            "mode": prefs.mode,
            "pip": prefs.pip,
            "scroll": prefs.scroll,
        ])
        prefs.saveLocal()
        // 收音模式改了要立刻切换采集来源（内部收音 / 麦克风收音）
        ZKSpeechStream.shared()?.applyAudioSource()
        // 实时字幕不再朗读：音频输出已从这一页去掉，声音只留给同声传译里手动点播
        Speaker.shared.enabled = false
        Speaker.shared.rate = prefs.speechRate
        Speaker.shared.duckLevel = prefs.duckLevel
        Speaker.shared.voiceId = prefs.voiceId
    }

    /// 改设置后统一走这里：本地存 + 云端同步 + 通知引擎
    func updatePrefs(_ mutate: (inout SubtitlePrefs) -> Void) {
        var p = prefs
        let oldPip = prefs.pip
        mutate(&p)
        prefs = p
        applyPrefsToEngine()
        Task { await Cloud.shared.savePrefs(p.dict()) }

        // 窗口大小只在开窗那一刻交给系统，改了必须重开一次才会变。
        // 不重开的话，用户在运行中切到"全宽"会觉得没反应。
        if p.pip != oldPip, pipOn, running, broadcastSeen {
            ZKPip.shared()!.stop()
            pipActive = false
            pipRequested = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.startPipIfPossible()
            }
        }
    }

    /// 登录 / 换设备后，把云端的设置拉回来（云端有就以云端为准）
    func syncPrefsFromCloud() async {
        guard let d = await Cloud.shared.loadPrefs(),
              let remote = SubtitlePrefs.from(dict: d) else { return }
        var r = remote
        // 全宽改成默认档后，老账号云端存的还是旧的 4:3 默认值，
        // 拉回来会把刚改好的默认值顶掉。这里只迁一次，之后用户怎么选就怎么存。
        let migrated = "zt_pip_default_w_done"
        if !UserDefaults.standard.bool(forKey: migrated) {
            r.pip = "W"
            UserDefaults.standard.set(true, forKey: migrated)
            let snapshot = r
            Task { await Cloud.shared.savePrefs(snapshot.dict()) }
        }
        prefs = r
        applyPrefsToEngine()
    }

    // MARK: - 开 / 停

    /// 麦克风收音前必须先拿到系统权限：
    /// 没权限就直接去碰 AVAudioEngine 的输入节点，系统会当场把进程带走（闪退）。
    func requestMicPermissionIfNeeded() async -> Bool {
        guard prefs.audioSource == "mic" else { return true }
        if #available(iOS 17.0, *) {
            switch AVAudioApplication.shared.recordPermission {
            case .granted: return true
            case .denied: return false
            default: break
            }
            return await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
                AVAudioApplication.requestRecordPermission { ok in c.resume(returning: ok) }
            }
        } else {
            let sess = AVAudioSession.sharedInstance()
            switch sess.recordPermission {
            case .granted: return true
            case .denied: return false
            default: break
            }
            return await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
                sess.requestRecordPermission { ok in c.resume(returning: ok) }
            }
        }
    }

    func start() async {
        guard !running, !preparing else { return }
        // 余额用本地已知的，不再等网络往返（弱网下这一下要好几秒）
        if Cloud.shared.balanceCredits < Cloud.shared.minStartCredits {
            await Cloud.shared.refresh()
            if Cloud.shared.balanceCredits < Cloud.shared.minStartCredits {
                alert = "积分不足，先去充值。"
                return
            }
        }
        preparing = true
        // 每次开新的一场，字幕不会串上一次的
        ZKStore.beginNewSession()
        ZKStore.clearLines()
        // 清掉上一次的停止标记，否则录屏扩展刚起来就被判定"该结束了"
        ZKStore.setSetting("broadcast_stop", v: nil)
        // 上一场如果停在「正在朗读」上，朗读门(tts_gate)可能还挂着未来时间戳，
        // 那会让这一整场录到的音频被当成回声静音掉——开新的一场先清干净。
        ZKStore.setSetting("tts_gate", v: "0")
        lastBufs = -1
        lastBufsAt = 0
        audioHint = ""

        lines.removeAll()
        liveSource = ""
        liveTrans = ""
        recentFinalKeys.removeAll()
        broadcastSeen = false
        pipRequested = false
        sessionStartAt = Date().timeIntervalSince1970

        Speaker.shared.resume()
        // 麦克风收音这一路由麦克风在听，朗读不能挂静音门（那等于把话筒掐了）
        Speaker.shared.micCapture = (prefs.audioSource == "mic")
        ZKSpeechStream.shared()!.start()
        keeper.start()
        running = true
        let mic = (prefs.audioSource == "mic")
        status = mic ? "正在听" : "等待录屏"
        startWatchingBroadcast()
        if mic {
            // 麦克风收音：不用等系统录屏面板，直接自己把浮窗浮出来
            broadcastSeen = true
            if pipOn {
                pipRequested = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    self?.startPipIfPossible()
                }
            } else {
                preparing = false
            }
        }
        // 兜底：12 秒还没浮出来也不能一直转圈
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
            self?.preparing = false
        }
    }

    func stop() {
        stopWatching()
        ZKSpeechStream.shared()!.stop()
        // 停止后迟到的翻译回调不许再念
        Speaker.shared.stop()
        Speaker.shared.micCapture = false
        // 停止就一定要关：之前 stop 后系统窗口偶尔还挂着，就是因为只调了 stop 没清引用
        ZKPip.shared()!.stop()
        // 系统录屏（屏幕广播）ReplayKit 没有提供"从 App 停止"的接口，
        // 但扩展会读这个时间戳，读到就自己结束——红点跟着消失，不用用户再去点。
        ZKStore.setSetting("broadcast_stop", v: String(format: "%.0f", Date().timeIntervalSince1970 + 1))
        keeper.stop()
        pipRequested = false
        pipActive = false
        preparing = false
        running = false
        status = "未开始"
        audioHint = ""
        lastBufs = -1
        liveSource = ""
        liveTrans = ""
        Task { await Cloud.shared.refresh() }
    }

    /// 用户点了系统录屏面板之后，扩展会写心跳；轮询到就说明真的开始录了
    private func startWatchingBroadcast() {
        stopWatching()
        // 麦克风收音不经过录屏扩展：既没有广播权限要等，也没有扩展心跳可看。
        // 这两条轮询只在内部收音（系统声音）时才需要，否则会一直提示"等待授予直播录屏权限"。
        if prefs.audioSource != "mic" {
            broadcastTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.checkBroadcast() }
            }
            // 音频看门狗：扩展的心跳里带累计帧数，数字不涨就是一段都没收到
            audioTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.checkAudio() }
            }
        }
        // 画中画是否真的起来了，系统不给同步返回值，只能每秒对一次
        pipPollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let active = ZKPip.shared()!.isActive()
                if active != self.pipActive { self.pipActive = active }
                // 浮窗出来了，按钮就从「正在加载字幕浮窗」变成「停止」
                if active && self.preparing { self.preparing = false }
            }
        }
    }

    private func stopWatching() {
        broadcastTimer?.invalidate()
        broadcastTimer = nil
        audioTimer?.invalidate()
        audioTimer = nil
        pipPollTimer?.invalidate()
        pipPollTimer = nil
    }

    /// 每秒对一次扩展心跳里的帧数：涨了就是真的在收音频，一直不动就是没收到。
    private func checkAudio() {
        guard running else { return }
        let beat: [AnyHashable: Any] = ZKStore.beat() ?? [:]
        let t = (beat["t"] as? NSNumber)?.doubleValue ?? 0
        let bufs = (beat["bufs"] as? NSNumber)?.intValue ?? 0
        let conn = beat["conn"] as? String ?? ""
        let now = Date().timeIntervalSince1970
        guard t > 0, t >= sessionStartAt - 1.5, now - t < 6 else {
            audioHint = broadcastSeen ? "录屏已断开" : "等待授予直播录屏权限"
            return
        }
        if bufs != lastBufs {
            lastBufs = bufs
            lastBufsAt = now
            audioHint = "正在接收音频"
            return
        }
        // 帧数没动：超过 6 秒说明扩展活着但没拿到声音
        if lastBufsAt > 0, now - lastBufsAt > 6 {
            audioHint = "没收到音频（在控制中心重新选「语幕」）"
        } else if lastBufsAt == 0 {
            audioHint = "扩展已连上，等音频"
        }
        _ = conn
    }

    private func checkBroadcast() {
        guard running, !broadcastSeen else { return }
        let beat: [AnyHashable: Any] = ZKStore.beat() ?? [:]
        let t = (beat["t"] as? NSNumber)?.doubleValue ?? 0
        let now = Date().timeIntervalSince1970
        guard t > 0, t >= sessionStartAt - 1.5, now - t < 4 else { return }

        broadcastSeen = true
        status = "正在听"
        // 画中画关掉的人，录制一开始就算就位了
        if !pipOn { preparing = false }
        broadcastTimer?.invalidate()
        broadcastTimer = nil

        // 选完广播再开画中画：这时 App 可能还在前台，系统也允许 App 内直接浮出。
        // 间隔压到 0.15s——用户选完广播很可能马上就按 Home，慢一点就来不及了。
        guard pipOn else { return }
        pipRequested = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.startPipIfPossible()
        }
    }

    private func startPipIfPossible() {
        guard running, pipRequested, pipOn else { return }
        guard let anchor = anchorView, anchor.window != nil else {
            // 锚点还没上屏，200ms 后再试一次（切 Tab 回来、刚启动时会发生）
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.startPipIfPossible()
            }
            return
        }
        ZKPip.shared()!.start(in: anchor)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self else { return }
            if ZKPip.shared()!.isActive() {
                self.pipActive = true
                self.preparing = false
            } else if self.running && self.pipRequested {
                // 再试一次：视图刚上屏时系统偶尔会拒
                ZKPip.shared()!.start(in: anchor)
            }
        }
    }

    /// 首页「画中画」按钮 / 设置页开关
    func setPip(_ on: Bool) {
        pipOn = on
        UserDefaults.standard.set(on, forKey: "zt_pip_on")
        if on {
            if running && broadcastSeen {
                pipRequested = true
                startPipIfPossible()
            }
        } else {
            pipRequested = false
            ZKPip.shared()!.stop()
            pipActive = false
        }
    }

    func togglePip() { setPip(!pipOn) }

    /// 本次会话已经说过的内容（本地，用于停止后立即展示，不等服务端）
    var localTranscript: [(String, String)] {
        lines.map { ($0.source, $0.trans) }
    }
}

// MARK: - 后台保活

/// 播一段完全听不见的音频，让 App 在后台保持运行。
///
/// 为什么需要：画中画的画面由系统渲染，但里面的字幕是 App 自己更新 UIView 的。
/// App 一旦被挂起，字幕就停在最后一帧——用户看到的就是「回到桌面后画中画卡住了」。
/// 有后台音频权限时，只要真的在出声（哪怕音量是 0），App 就不会被挂起。
@MainActor
final class SilentKeeper {
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?

    func start() {
        if engine != nil { return }
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? s.setActive(true)

        let e = AVAudioEngine()
        let p = AVAudioPlayerNode()
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1) else { return }
        e.attach(p)
        e.connect(p, to: e.mainMixerNode, format: fmt)
        e.mainMixerNode.outputVolume = 0     // 真静音，用户听不到
        do {
            try e.start()
        } catch {
            return
        }
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 44100) else { return }
        buf.frameLength = 44100
        p.scheduleBuffer(buf, at: nil, options: .loops, completionHandler: nil)
        p.play()
        engine = e
        player = p
    }

    func stop() {
        player?.stop()
        engine?.stop()
        player = nil
        engine = nil
    }
}

// MARK: - 头像

/// 头像：本机存一份用于秒开，同时同步到账号上（换手机 / 重装还在）。
/// 只传压缩后的 JPEG（600px 以内，几十 KB），不传原图。
enum AvatarStore {
    private static var url: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("avatar.jpg")
    }

    static func load() -> UIImage? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    /// 当前头像的 base64（给服务端同步用）
    static func base64() -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return data.base64EncodedString()
    }

    /// 用服务端下发的 base64 覆盖本机头像
    @discardableResult
    static func save(base64: String) -> Bool {
        guard let data = Data(base64Encoded: base64) else { return false }
        return (try? data.write(to: url, options: .atomic)) != nil
    }

    static func save(_ image: UIImage?) {
        guard let image else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        // 头像控件最大也就 80pt，压到 600px 足够，原图几 MB 没必要进沙盒
        let side: CGFloat = 600
        let scale = min(1, side / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.scale = 1
        let out = UIGraphicsImageRenderer(size: size, format: fmt).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        if let data = out.jpegData(compressionQuality: 0.88) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
