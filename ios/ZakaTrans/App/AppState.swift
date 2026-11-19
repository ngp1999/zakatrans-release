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
    @Published var showBroadcastPicker = false
    @Published var alert: String?
    @Published var prefs: SubtitlePrefs = SubtitlePrefs.load()

    struct SubtitleLine: Identifiable, Equatable {
        let id = UUID()
        let source: String
        let trans: String
        let at = Date()
    }

    /// 画中画需要一个真实的 UIView 当锚点
    weak var anchorView: UIView?

    private var pipReady = false

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
            let zh = full ?? ""
            let src = self.liveSource
            if !zh.isEmpty {
                self.lines.append(SubtitleLine(source: src, trans: zh))
                // 太长的历史会吃内存，留最近 200 句足够回看
                if self.lines.count > 200 { self.lines.removeFirst(self.lines.count - 200) }
                ZKPip.shared()!.appendLineEn(src, zh: zh)
                // 输出音频：这一句念出来
                if self.prefs.tts { Speaker.shared.speak(zh) }
            }
            self.liveTrans = ""
            self.liveSource = ""
        }
        s.onDiag = { [weak self] d in
            guard let self, let d, !d.isEmpty else { return }
            self.status = d
        }
    }

    /// 把当前的样式设置推给画中画和引擎
    func applyPrefsToEngine() {
        ZKPip.applyStyle([
            "size": prefs.size,
            "color": prefs.color,
            "style": prefs.style,
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
            alert = "积分不足，先到「我的 → 积分」充值再开始。"
            return
        }
        if let anchor = anchorView, anchor.window != nil, !ZKPip.shared()!.isActive() {
            ZKPip.shared()!.start(in: anchor)
            pipReady = true
        }
        // 每次开新的一场，字幕不会串上一次的
        ZKStore.beginNewSession()
        ZKStore.clearLines()
        lines.removeAll()
        liveSource = ""
        liveTrans = ""
        ZKSpeechStream.shared()!.start()
        running = true
        status = "等待系统录屏开始"
        showBroadcastPicker = true
    }

    func stop() {
        ZKSpeechStream.shared()!.stop()
        Speaker.shared.stop()
        if ZKPip.shared()!.isActive() {
            ZKPip.shared()!.stop()
        }
        pipReady = false
        running = false
        showBroadcastPicker = false
        status = "已停止"
        liveSource = ""
        liveTrans = ""
        Task { await Cloud.shared.refresh() }
    }

    /// 用户点了系统录屏面板之后，扩展的心跳会出现在共享容器里
    func markBroadcastStarted() {
        status = "正在听"
    }

    /// 本次会话已经说过的内容（本地，用于停止后立即展示，不等服务端）
    var localTranscript: [(String, String)] {
        lines.map { ($0.source, $0.trans) }
    }
}
