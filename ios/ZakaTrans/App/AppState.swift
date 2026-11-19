import SwiftUI
import UIKit

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

    struct SubtitleLine: Identifiable, Equatable {
        let id = UUID()
        let source: String
        let trans: String
        let at = Date()
    }

    /// 画中画需要一个真实的 UIView 当锚点
    weak var anchorView: UIView?

    private var broadcastTimer: Timer?
    private var pipPollTimer: Timer?
    private var sessionStartAt: TimeInterval = 0
    private var broadcastSeen = false
    private var pipRequested = false

    /// 同一句最终译文可能被回调推两次，这里做去重
    private var lastFinalKey = ""
    private var lastFinalAt = Date.distantPast

    private init() {
        bindEngine()
        applyPrefsToEngine()
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
                // 去重：同一句（原文+译文一样）短时间内只收一次
                let key = src + "\u{1}" + zh
                let now = Date()
                if key == self.lastFinalKey && now.timeIntervalSince(self.lastFinalAt) < 4 {
                    self.liveTrans = ""
                    self.liveSource = ""
                    return
                }
                self.lastFinalKey = key
                self.lastFinalAt = now

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
            // 只保留对用户有意义的运行状态，不把内部诊断串刷到界面上
            if d.contains("连接") || d.contains("监听") || d.contains("启动") {
                self.status = self.running ? "正在听" : "未开始"
            }
        }
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
        lines.removeAll()
        liveSource = ""
        liveTrans = ""
        lastFinalKey = ""
        broadcastSeen = false
        pipRequested = false
        sessionStartAt = Date().timeIntervalSince1970

        ZKSpeechStream.shared()!.start()
        running = true
        status = "等待录屏"
        startWatchingBroadcast()
    }

    func stop() {
        stopWatching()
        ZKSpeechStream.shared()!.stop()
        Speaker.shared.stop()
        // 停止就一定要关：之前 stop 后系统窗口偶尔还挂着，就是因为只调了 stop 没清引用
        ZKPip.shared()!.stop()
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
        broadcastTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
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

        // 选完广播再开画中画：这时 App 可能还在前台，系统也允许 App 内直接浮出
        guard pipOn else { return }
        pipRequested = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            self?.startPipIfPossible()
        }
    }

    private func startPipIfPossible() {
        guard running, pipRequested, pipOn else { return }
        guard let anchor = anchorView, anchor.window != nil else {
            // 锚点还没上屏，200ms 后再试一次（切 Tab 回来、刚启动时会发生）
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
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
