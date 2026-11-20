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
    }

    struct SubtitleLine: Identifiable, Equatable {
        let id = UUID()
        let source: String
        let trans: String
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

    // MARK: - 引擎回调

    private func bindEngine() {
        let s = ZKSpeechStream.shared()!
        s.onPartial = { [weak self] stable, unstable in
            guard let self else { return }
            let t = (stable ?? "") + (unstable ?? "")
            self.liveSource = t
            ZKPip.shared()!.setLiveEn(t, zh: self.liveTrans)
        }
        s.onSegment = { [weak self] text, _ in
            guard let self else { return }
            if let t = text, !t.isEmpty { self.liveSource = t }
        }
        s.onTransPartial = { [weak self] delta in
            guard let self else { return }
            self.liveTrans += delta ?? ""
            ZKPip.shared()!.setLiveEn(self.liveSource, zh: self.liveTrans)
        }
        s.onTransSegment = { [weak self] full in
            guard let self else { return }
            let zh = (full ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let src = self.liveSource.trimmingCharacters(in: .whitespacesAndNewlines)
            if !zh.isEmpty {
                // 回声先拦：这句话是我们自己刚念出去的，被录屏录回来又识别了一遍。
                // 不拦的话既重复显示、又重复念，还会把真实语音的句子切碎。
                if self.prefs.tts && Speaker.shared.isEcho([zh, src]) {
                    self.liveTrans = ""
                    self.liveSource = ""
                    return
                }
                // 去重：同一句（原文+译文）短时间内只收一次。
                // 只跟上一句比不够——中间夹一句别的，同一句照样会再冒出来一遍。
                let key = Speaker.key(src) + "\u{1}" + Speaker.key(zh)
                if self.recentFinalKeys.contains(key) {
                    self.liveTrans = ""
                    self.liveSource = ""
                    return
                }
                self.recentFinalKeys.append(key)
                if self.recentFinalKeys.count > 40 {
                    self.recentFinalKeys.removeFirst(self.recentFinalKeys.count - 40)
                }

                self.lines.append(SubtitleLine(source: src, trans: zh))
                if self.lines.count > 200 { self.lines.removeFirst(self.lines.count - 200) }
                ZKPip.shared()!.appendLineEn(src, zh: zh)
                if self.prefs.tts { Speaker.shared.speak(zh) }
            }
            self.liveTrans = ""
            self.liveSource = ""
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
        ])
        prefs.saveLocal()
        Speaker.shared.enabled = prefs.tts
        Speaker.shared.rate = prefs.speechRate
        Speaker.shared.duckLevel = prefs.duckLevel
        Speaker.shared.voiceId = prefs.voiceId
    }

    /// 改设置后统一走这里：本地存 + 云端同步 + 通知引擎
    func updatePrefs(_ mutate: (inout SubtitlePrefs) -> Void) {
        var p = prefs
        mutate(&p)
        prefs = p
        applyPrefsToEngine()
        Task { await Cloud.shared.savePrefs(p.dict()) }
    }

    /// 登录 / 换设备后，把云端的设置拉回来（云端有就以云端为准）
    func syncPrefsFromCloud() async {
        guard let d = await Cloud.shared.loadPrefs(),
              let remote = SubtitlePrefs.from(dict: d) else { return }
        prefs = remote
        applyPrefsToEngine()
    }

    // MARK: - 开 / 停

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
        ZKSpeechStream.shared()!.start()
        keeper.start()
        running = true
        status = "等待录屏"
        startWatchingBroadcast()
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
        broadcastTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkBroadcast() }
        }
        // 音频看门狗：扩展的心跳里带累计帧数，数字不涨就是一段都没收到
        audioTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkAudio() }
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
            audioHint = broadcastSeen ? "录屏已断开" : "等你在控制中心点开始"
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
            audioHint = "没收到音频（在控制中心重新选「语幕实时翻译」）"
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

/// 头像只存本机：用户从相册选的照片属于个人内容，没必要也不应该传到服务器。
enum AvatarStore {
    private static var url: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("avatar.jpg")
    }

    static func load() -> UIImage? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
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
