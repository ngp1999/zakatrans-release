import SwiftUI
import UIKit

/// 全局状态：把 SwiftUI 界面和底下的原生引擎连起来。
///
/// 音频链路仍然是：录屏扩展 → 共享容器/TCP → SpeechStream → 后端识别；
/// 界面这边只负责按钮、字幕和余额。
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
            let en = self.liveSource
            if !zh.isEmpty {
                self.lines.append(SubtitleLine(source: en, trans: zh))
                ZKPip.shared()!.appendLineEn(en, zh: zh)
            }
            self.liveTrans = ""
            self.liveSource = ""
        }
        s.onDiag = { [weak self] d in
            guard let self, let d, !d.isEmpty else { return }
            self.status = d
        }
    }

    // MARK: - 开 / 停

    /// 开始前先看余额：不够就直接说清楚，别让用户开了录屏才发现没字。
    func start() async {
        guard !running else { return }
        await Cloud.shared.refresh()
        if Cloud.shared.balance < Cloud.shared.minStartBalance {
            alert = "额度不足，先到「额度」页买一份再开始。"
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
}
