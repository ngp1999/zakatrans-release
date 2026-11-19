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
    @Published var status = "未开始"
    @Published var liveSource = ""
    @Published var liveTrans = ""
    @Published var lines: [SubtitleLine] = []
    @Published var alert: String?
    @Published var prefs: SubtitlePrefs = SubtitlePrefs.load()

    /// 画中画：用户想不想开（持久化），以及此刻是否真的在屏幕上
    @Published var pipOn: Bool = (UserDefaults.standard.object(forKey: "zt_pip_on") as? Bool) ?? true
    @Published var pipActive = false

    /// 默认头像（本机保存，四种底色，男女都有）
    @Published var avatarIndex: Int = UserDefaults.standard.integer(forKey: "zt_avatar") {
        didSet { UserDefaults.standard.set(avatarIndex, forKey: "zt_avatar") }
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
    private var sessionStartAt: TimeInterval = 0
    private var broadcastSeen = false
    private var pipRequested = false

    /// 同一句最终译文可能被回调推两次，这里做去重
    private var recentFinalKeys: [String] = []

    /// 后台保活：没有它，App 一回桌面就被挂起，画中画里字幕会停在那儿不动
    private let keeper = SilentKeeper()

    private init() {
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
        guard !running else { return }
        await Cloud.shared.refresh()
        if Cloud.shared.balanceCredits < Cloud.shared.minStartCredits {
            alert = "积分不足，先去充值。"
            return
        }
        // 每次开新的一场，字幕不会串上一次的
        ZKStore.beginNewSession()
        ZKStore.clearLines()
        // 清掉上一次的停止标记，否则录屏扩展刚起来就被判定"该结束了"
        ZKStore.setSetting("broadcast_stop", v: nil)

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
        running = false
        status = "未开始"
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
        // 画中画是否真的起来了，系统不给同步返回值，只能每秒对一次
        pipPollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let active = ZKPip.shared()!.isActive()
                if active != self.pipActive { self.pipActive = active }
            }
        }
    }

    private func stopWatching() {
        broadcastTimer?.invalidate()
        broadcastTimer = nil
        pipPollTimer?.invalidate()
        pipPollTimer = nil
    }

    private func checkBroadcast() {
        guard running, !broadcastSeen else { return }
        let beat: [AnyHashable: Any] = ZKStore.beat() ?? [:]
        let t = (beat["t"] as? NSNumber)?.doubleValue ?? 0
        let now = Date().timeIntervalSince1970
        guard t > 0, t >= sessionStartAt - 1.5, now - t < 4 else { return }

        broadcastSeen = true
        status = "正在听"
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
