import SwiftUI
import AVFoundation
import UIKit

// MARK: - 播放器模型

@MainActor
final class VideoPlayerBox: ObservableObject {
    let player = AVPlayer()

    @Published var ready = false
    @Published var failed: String?
    @Published var playing = false
    @Published var current: Double = 0
    @Published var duration: Double = 0
    @Published var ended = false
    /// 这条视频的音轨到底拿到没有（拿不到就一个字幕都不会有）
    @Published var tapState: String = "准备中"

    private var tap: ZKVideoTap?
    private var statusObs: NSKeyValueObservation?
    private var rateObs: NSKeyValueObservation?
    private var timeObs: Any?
    private var endObs: NSObjectProtocol?
    private var loaded: URL?
    private(set) var request: VideoPlayRequest?

    func load(_ req: VideoPlayRequest) {
        guard loaded != req.url else { return }
        loaded = req.url
        request = req

        // 网页播放器怎么发的请求，我们就怎么发：
        // 带上原页面的 Referer / UA / Cookie，防盗链的站也解得开。
        let asset = AVURLAsset(url: req.url, options: [
            "AVURLAssetHTTPHeaderFieldsKey": req.headers,
            AVURLAssetPreferPreciseDurationAndTimingKey: true,
        ])
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 4
        player.replaceCurrentItem(with: item)

        statusObs = item.observe(\.status, options: [.new]) { [weak self] it, _ in
            Task { @MainActor in
                guard let self else { return }
                switch it.status {
                case .readyToPlay: self.onReady(it)
                case .failed: self.failed = it.error?.localizedDescription ?? "这条视频打不开"
                default: break
                }
            }
        }

        rateObs = player.observe(\.timeControlStatus, options: [.new]) { [weak self] p, _ in
            Task { @MainActor in self?.playing = (p.timeControlStatus == .playing) }
        }

        timeObs = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.3, preferredTimescale: 600), queue: .main
        ) { [weak self] t in
            Task { @MainActor in
                guard let self else { return }
                if !self.ended { self.current = max(0, t.seconds) }
                let d = self.player.currentItem?.duration.seconds ?? 0
                if d.isFinite, d > 0 { self.duration = d }
            }
        }

        endObs = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.ended = true
                self?.playing = false
            }
        }

        // 网页视频通常一进页面就想让它转起来，这里按静音自动播放的宽松做法先播，
        // 用户要声音点一下喇叭即可。
        player.isMuted = false
    }

    private func onReady(_ item: AVPlayerItem) {
        if !ready { ready = true }
        let d = item.duration.seconds
        if d.isFinite, d > 0 { duration = d }
        attachTap(retry: 0)
        player.play()
        playing = true
    }

    /// HLS 的音轨要等主列表解析完才出现，所以这里带重试
    private func attachTap(retry: Int) {
        guard tap == nil, let item = player.currentItem else { return }

        let ok = ZKVideoTap.attach(item, handler: { pcm, frames in
            guard frames > 0 else { return }
            // 指针只在这个回调里有效，必须立刻复制
            let copy = Data(bytes: UnsafeRawPointer(pcm), count: Int(frames) * MemoryLayout<Float>.size)
            let n = Int(frames)
            ZKFeedQueue.shared.async {
                videoAudioCore.push(copy, frames: n)
            }
        })

        if let ok {
            tap = ok
            tapState = "已接管音轨"
        } else if retry < 6 {
            tapState = "等待音轨"
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                self?.attachTap(retry: retry + 1)
            }
        } else {
            tapState = "这条视频取不到音轨"
        }
    }

    func togglePlay() {
        if ended {
            ended = false
            seek(to: 0)
            player.play()
            return
        }
        if player.timeControlStatus == .playing { player.pause() } else { player.play() }
    }

    func seek(to v: Double) {
        player.seek(to: CMTime(seconds: max(0, v), preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
        VideoSubtitleEngine.shared.clearLive()
        ended = false
    }

    func setRate(_ r: Float) {
        if player.timeControlStatus == .playing { player.rate = r }
    }

    func teardown() {
        player.pause()
        tap?.detach()
        tap = nil
        if let o = timeObs { player.removeTimeObserver(o); timeObs = nil }
        if let e = endObs { NotificationCenter.default.removeObserver(e); endObs = nil }
        player.replaceCurrentItem(with: nil)
    }
}

/// 全 App 一条串行队列处理视频音频，避免和主线程抢
enum ZKFeedQueue {
    static let shared = DispatchQueue(label: "zaka.video.feed.serial", qos: .userInitiated)
}

// MARK: - 播放画面

private final class ZKPlayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

private struct PlayerLayerRepresentable: UIViewRepresentable {
    let player: AVPlayer
    func makeUIView(context: Context) -> ZKPlayerUIView {
        let v = ZKPlayerUIView()
        v.backgroundColor = .black
        v.playerLayer.player = player
        v.playerLayer.videoGravity = .resizeAspect
        return v
    }
    func updateUIView(_ v: ZKPlayerUIView, context: Context) {
        if v.playerLayer.player !== player { v.playerLayer.player = player }
    }
}

// MARK: - 播放页

struct VideoPlayerScreen: View {
    let request: VideoPlayRequest

    @Environment(\.dismiss) private var dismiss
    @StateObject private var box = VideoPlayerBox()
    @ObservedObject private var subs = VideoSubtitleEngine.shared
    @ObservedObject private var app = AppState.shared

    @State private var controls = true
    @State private var dragging = false
    @State private var dragValue: Double = 0
    @State private var subtitlesOn = true
    @State private var rate: Float = 1.0
    @State private var showLines = false
    @State private var frames: UInt = 0
    @State private var hideTask: DispatchWorkItem?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            PlayerLayerRepresentable(player: box.player)
                .ignoresSafeArea()

            // 点画面切换控制条
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { toggleControls() }
                .ignoresSafeArea()

            if subtitlesOn { subtitleLayer }

            VStack(spacing: 0) {
                topBar
                Spacer()
                if controls { bottomBar.transition(.opacity) }
            }

            if box.tapState == "这条视频取不到音轨" && box.failed == nil {
                VStack {
                    Spacer()
                    HStack(spacing: 8) {
                        Image(systemName: "waveform.slash")
                            .font(.system(size: 12, weight: .semibold))
                        Text("这条视频的音轨取不到，字幕出不来")
                            .font(.system(size: 12))
                        Spacer()
                        Button("改用录屏字幕") { dismiss() }
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(.white, in: Capsule())
                    }
                    .foregroundStyle(.white)
                    .padding(12)
                    .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding(.horizontal, 16)
                    .padding(.bottom, controls ? 150 : 80)
                }
                .transition(.opacity)
            }

            if let f = box.failed { failCard(f) }
            if !box.ready && box.failed == nil { loadingCard }
        }
        .statusBarHidden(!controls)
        .task {
            // 视频要出声，用 playback 才不会受侧边静音开关影响。
            // 首页那场录屏字幕要是正在跑，就别动音频会话，免得把它切断。
            if !AppState.shared.running {
                try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
                try? AVAudioSession.sharedInstance().setActive(true)
            }
            box.load(request)
            subs.start()
            videoAudioCore.reset()
            try? await Task.sleep(nanoseconds: 300_000_000)
            scheduleHide()
            // 音轨/字幕状态每秒刷新一次
            while !Task.isCancelled {
                frames = videoAudioCore.frames
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { break }
            }
        }
        .onDisappear {
            hideTask?.cancel()
            subs.stop()
            box.teardown()
        }
        .sheet(isPresented: $showLines) {
            SubtitleLinesSheet()
        }
    }

    // MARK: 字幕

    private var subtitleLayer: some View {
        VStack {
            Spacer()
            let p = app.prefs
            VStack(spacing: 3) {
                if !subs.liveTrans.isEmpty, p.mode != "source" {
                    Text(subs.liveTrans)
                        .font(.system(size: p.size + 4, weight: .semibold))
                        .foregroundStyle(Color(uiColor: p.effectiveColor))
                        .multilineTextAlignment(.center)
                }
                if !subs.liveSource.isEmpty, p.mode != "zh" {
                    Text(subs.liveSource)
                        .font(.system(size: max(12, p.size - 1), weight: .medium))
                        .foregroundStyle(Color(uiColor: p.secondaryColor))
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(p.backgroundColor.opacity(0.82))
            )
            .padding(.horizontal, 18)
            .padding(.bottom, controls ? 96 : 34)
            .animation(.easeOut(duration: 0.12), value: subs.liveTrans)
        }
        .allowsHitTesting(false)
    }

    // MARK: 顶栏

    private var topBar: some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(.black.opacity(0.35), in: Circle())
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(request.title.isEmpty ? "视频" : request.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(statusLine)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(1)
            }
            Spacer()
            Button { showLines = true } label: {
                Image(systemName: "text.bubble")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(.black.opacity(0.35), in: Circle())
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .opacity(controls ? 1 : 0)
    }

    private var statusLine: String {
        if box.tapState == "这条视频取不到音轨" { return "取不到音轨 · 没有字幕" }
        if frames == 0 && box.ready { return "等待音频…" }
        if frames > 0, subs.state.contains("连接") || subs.state.isEmpty { return "字幕连接中…" }
        return subs.state.isEmpty ? "字幕就绪" : subs.state
    }

    // MARK: 底栏

    private var bottomBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                Text(timeText(dragging ? dragValue : box.current))
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.85))

                Slider(
                    value: Binding(
                        get: { dragging ? dragValue : min(box.current, max(box.duration, 1)) },
                        set: { dragValue = $0; dragging = true }
                    ),
                    in: 0...max(box.duration, 1),
                    onEditingChanged: { editing in
                        if editing {
                            dragging = true
                        } else {
                            box.seek(to: dragValue)
                            dragging = false
                        }
                    }
                )
                .tint(.white)

                Text(timeText(box.duration))
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.85))
            }

            HStack(spacing: 24) {
                Button { box.togglePlay(); scheduleHide() } label: {
                    Image(systemName: box.playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                }
                Button { seekBy(-10) } label: {
                    Image(systemName: "gobackward.10")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.white)
                }
                Button { seekBy(10) } label: {
                    Image(systemName: "goforward.10")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.white)
                }
                Spacer()
                Button { cycleRate() } label: {
                    Text(rate == 1 ? "1x" : String(format: "%gx", rate))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(.white.opacity(0.16), in: Capsule())
                }
                Button { subtitlesOn.toggle() } label: {
                    Image(systemName: subtitlesOn ? "captions.bubble.fill" : "captions.bubble")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(subtitlesOn ? Theme.accent : .white)
                }
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 14)
        .background(
            LinearGradient(colors: [.clear, .black.opacity(0.72)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .bottom)
        )
    }

    // MARK: 状态卡

    private var loadingCard: some View {
        VStack(spacing: 10) {
            ProgressView().tint(.white)
            Text("正在打开视频…").font(.system(size: 13)).foregroundStyle(.white.opacity(0.8))
        }
        .padding(22)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func failCard(_ msg: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 22))
                .foregroundStyle(.orange)
            Text(msg)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.85))
                .multilineTextAlignment(.center)
            Text("有些站会拦住外部播放器。可以返回网页里直接看，或者换一条视频试试。")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center)
            Button("返回网页") { dismiss() }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.black)
                .padding(.horizontal, 18).padding(.vertical, 8)
                .background(.white, in: Capsule())
        }
        .padding(22)
        .frame(maxWidth: 320)
        .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    // MARK: 交互

    private func toggleControls() {
        withAnimation(.easeInOut(duration: 0.18)) { controls.toggle() }
        if controls { scheduleHide() }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        let t = DispatchWorkItem {
            withAnimation(.easeInOut(duration: 0.25)) { controls = false }
        }
        hideTask = t
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.2, execute: t)
    }

    private func seekBy(_ d: Double) {
        box.seek(to: min(max(0, box.current + d), max(box.duration, 1)))
        scheduleHide()
    }

    private func cycleRate() {
        let all: [Float] = [1.0, 1.25, 1.5, 0.75]
        let i = all.firstIndex(of: rate) ?? 0
        rate = all[(i + 1) % all.count]
        box.setRate(rate)
        scheduleHide()
    }

    private func timeText(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "0:00" }
        let t = Int(s)
        if t >= 3600 { return String(format: "%d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60) }
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}

// MARK: - 字幕记录

struct SubtitleLinesSheet: View {
    @ObservedObject private var subs = VideoSubtitleEngine.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if subs.lines.isEmpty {
                    Text("还没有成句的字幕")
                        .foregroundStyle(Theme.sub)
                }
                ForEach(subs.lines) { l in
                    VStack(alignment: .leading, spacing: 4) {
                        if !l.trans.isEmpty {
                            Text(l.trans).font(.system(size: 15, weight: .medium))
                        }
                        if !l.source.isEmpty {
                            Text(l.source).font(.system(size: 13)).foregroundStyle(Theme.sub)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            .navigationTitle("字幕记录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) { Button("关闭") { dismiss() } }
            }
        }
    }
}
