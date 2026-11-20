import Foundation
import SwiftUI

/// 网页视频的字幕引擎。
///
/// 和首页那条链路互不干扰：这里自己开一条同传会话，
/// 音频来自视频播放器内部旁听出来的 PCM（见 ZKVideoTap），
/// 不走麦克风、不走录屏，所以戴着耳机看也不会被外放影响。
/// 音频回调 → 同传 的那一段。
/// MTAudioProcessingTap 的回调在音频线程上，直接在主线程做格式转换会把 UI 拖住，
/// 所以 PCM 复制一份丢到一条独立串行队列里推给同传，主线程完全不参与。
final class AudioFeedCore: @unchecked Sendable {
    private let lock = NSLock()
    private var ast: ZKDoubaoAST?
    private var total: UInt = 0

    func set(_ a: ZKDoubaoAST?) {
        lock.lock(); ast = a; lock.unlock()
    }

    func push(_ data: Data, frames: Int) {
        lock.lock(); let a = ast; lock.unlock()
        guard let a, frames > 0 else { return }
        data.withUnsafeBytes { raw in
            guard let p = raw.bindMemory(to: Float.self).baseAddress else { return }
            a.pushFloat32(p, count: UInt(frames))
        }
        lock.lock(); total &+= UInt(frames); lock.unlock()
    }

    var frames: UInt {
        lock.lock(); defer { lock.unlock() }
        return total
    }

    func reset() {
        lock.lock(); total = 0; lock.unlock()
    }
}

/// 全 App 只有这一条视频音频通道
let videoAudioCore = AudioFeedCore()

@MainActor
final class VideoSubtitleEngine: ObservableObject {
    static let shared = VideoSubtitleEngine()

    struct Line: Identifiable, Equatable {
        let id = UUID()
        let source: String
        let trans: String
        let at = Date()
    }

    /// 正在滚动的这一句（还没成句）
    @Published private(set) var liveSource = ""
    @Published private(set) var liveTrans = ""
    /// 已经成句的
    @Published private(set) var lines: [Line] = []
    /// 连接状态（给界面显示一行小字）
    @Published private(set) var state = "未开始"
    /// 视频这一路到底有没有真的收到音频
    @Published private(set) var audioFrames: UInt = 0
    @Published private(set) var active = false

    private var ast: ZKDoubaoAST?
    private var silenceTimer: Timer?
    private var lastHeard = Date.distantPast
    private var recentKeys: [String] = []

    private init() {}

    var backendLabel: String { state }
    var heardAnything: Bool { audioFrames > 0 }

    // MARK: - 生命周期

    func start() {
        guard !active else { return }
        active = true
        liveSource = ""
        liveTrans = ""
        lines.removeAll()
        recentKeys.removeAll()
        audioFrames = 0
        state = "连接中"

        // ObjC 那边没标 nullability，Swift 侧当可选值处理
        guard let session = ZKDoubaoAST.session() else {
            state = "字幕通道没起来"
            active = false
            return
        }
        ast = session
        videoAudioCore.reset()
        videoAudioCore.set(session)

        session.onSourcePartial = { [weak self] delta in
            guard let self, self.active else { return }
            self.liveSource += (delta ?? "")
            self.lastHeard = Date()
        }
        session.onSourceEnd = { [weak self] full in
            guard let self, self.active else { return }
            let t = (full ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { self.liveSource = t }
        }
        session.onTransPartial = { [weak self] delta in
            guard let self, self.active else { return }
            self.liveTrans += (delta ?? "")
            self.lastHeard = Date()
        }
        session.onTransEnd = { [weak self] full in
            guard let self, self.active else { return }
            let zh = (full ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let src = self.liveSource.trimmingCharacters(in: .whitespacesAndNewlines)
            self.liveTrans = ""
            self.liveSource = ""
            guard !zh.isEmpty || !src.isEmpty else { return }

            // 同一句不重复进列表
            let key = "\(src)\u{1}\(zh)"
            if self.recentKeys.contains(key) { return }
            self.recentKeys.append(key)
            if self.recentKeys.count > 60 { self.recentKeys.removeFirst(self.recentKeys.count - 60) }

            self.lines.append(Line(source: src, trans: zh))
            if self.lines.count > 400 { self.lines.removeFirst(self.lines.count - 400) }
        }
        session.onState = { [weak self] s in
            guard let self else { return }
            self.state = s ?? ""
        }
        session.onFail = { [weak self] why in
            guard let self else { return }
            self.state = (why?.isEmpty == false) ? why! : "连接失败"
        }

        session.start()
        startSilenceWatch()
    }

    func stop() {
        active = false
        silenceTimer?.invalidate()
        silenceTimer = nil
        videoAudioCore.set(nil)
        ast?.stop()
        ast = nil
        liveSource = ""
        liveTrans = ""
        state = "已停止"
    }


    // MARK: - 字幕收尾

    /// 画面停住／静音超过一会儿，把残留的半句清掉，不让它一直挂在屏幕上
    private func startSilenceWatch() {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.active else { return }
                if Date().timeIntervalSince(self.lastHeard) > 7,
                   !self.liveTrans.isEmpty || !self.liveSource.isEmpty {
                    self.liveTrans = ""
                    self.liveSource = ""
                }
            }
        }
    }

    /// seek / 暂停时丢掉屏幕上这句话
    func clearLive() {
        liveTrans = ""
        liveSource = ""
    }
}
