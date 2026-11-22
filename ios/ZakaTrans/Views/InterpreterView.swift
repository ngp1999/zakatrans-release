import SwiftUI
import UIKit
import AVFoundation

/// 同声传译：面对面说话，两边的话各自翻译、各自朗读。
///
/// 这一版改动集中在「感觉快不快」上：
///   · 原文一落定就上屏（以前要等译文到齐才出，白等半秒到一秒）
///   · 译文边翻边补进同一条气泡（以前要到整句结束才一次性蹦出来）
///   · 麦克风输入有实时电平，界面上看得见"在听"
///   · 气泡重做：译文大、原文小一号，自己右边对方左边，没有多余标签
///   · 那个多出来的符号：上游语言对不上的通道会吐纯标点，已在引擎里过滤
struct InterpreterView: View {
    @ObservedObject private var app = AppState.shared
    @ObservedObject private var cloud = Cloud.shared
    private let haptic = UIImpactFeedbackGenerator(style: .light)

    struct Line: Identifiable, Equatable {
        let id: String
        var side: String
        var source: String
        var trans: String
        var done: Bool
        var at = Date()
    }

    @State private var mine: String = "zh-CN"
    @State private var other: String = "en-US"
    @State private var running = false
    @State private var lines: [Line] = []
    @State private var level: CGFloat = 0
    @State private var showLang = false
    @State private var error: String?
    /// 刚点开始的头两秒：界面明说「在连」，别让人以为已经在听、对着手机说半天
    @State private var warming = false
    /// 长按说话：按住才收音，松手才出译文，上滑取消
    @State private var holding = false
    @State private var canceling = false
    @State private var pendingSpeak = false
    /// 这一次按住期间冒出来的那些行（取消时要把它们撤掉）
    @State private var holdIDs: Set<String> = []
    /// 松手之后的收尾：等最后一句译文回来就把会话关掉，不再常驻占麦克风
    @State private var idleStop: Timer?
    /// 连续断流的次数：偶发断开自己重连，连着三次都接不上才提示用户
    @State private var failCount = 0
    @State private var hardStop: Timer?
    @State private var waitingFinal = false

    /// 语言名称一律用中文显示：选语言这一步是给自己看的，
    /// 看到「日本語 / 한국어」还得先在心里翻译一遍，没必要。
    static let langs: [(String, String)] = [
        ("zh-CN", "中文"),
        ("en-US", "英语"),
        ("ja-JP", "日语"),
        ("ko-KR", "韩语"),
        ("es-ES", "西班牙语"),
        ("fr-FR", "法语"),
        ("de-DE", "德语"),
        ("ru-RU", "俄语"),
        ("th-TH", "泰语"),
        ("vi-VN", "越南语"),
        ("pt-BR", "葡萄牙语"),
        ("it-IT", "意大利语"),
    ]

    private func name(_ code: String) -> String {
        Self.langs.first { $0.0 == code }?.1 ?? code
    }

    var body: some View {
        VStack(spacing: 0) {
            languageRow
            clockRow
            transcript
            bottomBar
        }
        .screenBackground()
        .sheet(isPresented: $showLang) {
            LangPicker(mine: $mine, other: $other) { a, b in
                mine = a; other = b
                ZKInterpreter.shared()?.setMine(a, other: b)
            }
            .sheetChrome(radius: 30)
        }
        // 用自绘提示框，跟 App 其他地方的卡片是同一套语言（系统 alert 一弹出来就出戏）
        .notice($error)
        .onAppear {
            // 进页面就把通道握上（不碰麦克风）。按下开始时直接说话，不再等握手。
            ZKInterpreter.shared()?.prewarm(with: mine, other: other)
        }
        .onDisappear {
            // 不管引擎是不是已经自动关过，离开这个页面一律收干净
            stop()
        }
    }

    // MARK: - 语言

    private var languageRow: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            Button {
                guard !running else { return }
                haptic.impactOccurred()
                showLang = true
            } label: {
                HStack(spacing: 6) {
                    Text(name(mine))
                        .font(DSFont.headline)
                        .foregroundStyle(DSColor.label)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(DSColor.tertiaryLabel)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(running)

            Button {
                guard !running else { return }
                haptic.impactOccurred()
                let m = mine
                mine = other
                other = m
                ZKInterpreter.shared()?.setMine(mine, other: other)
            } label: {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(DSColor.accent)
                    .frame(width: 34, height: 34)
                    .background(Theme.accentSoft)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(running)

            Button {
                guard !running else { return }
                haptic.impactOccurred()
                showLang = true
            } label: {
                HStack(spacing: 6) {
                    Text(name(other))
                        .font(DSFont.headline)
                        .foregroundStyle(DSColor.label)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(DSColor.tertiaryLabel)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(running)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 6)
        .padding(.bottom, 14)
        .opacity(running ? 0.45 : 1)
    }

    /// 顶部状态行：只报连接状态，不再走 时:分:秒。
    /// 一上来那几秒最容易被误以为「已经在听了」，所以这时候明说在连；
    /// 连上之后就留白——时间读数对使用者没有信息量，反而占视线。
    /// 高度始终占着，开始前后下面的对话区不会跳一下。
    private var clockRow: some View {
        Text(statusLine)
            .font(.subheadline)
            .foregroundStyle(DSColor.secondaryLabel)
            .frame(height: 20)
            .frame(maxWidth: .infinity)
            .padding(.bottom, 10)
            .animation(DSMotion.quick, value: statusLine)
    }

    private var statusLine: String {
        if warming { return "正在连接识别服务" }
        if holding { return "" }
        return running ? "" : " "
    }

    // MARK: - 对话

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 10) {
                    if lines.isEmpty {
                        guide
                    }
                    ForEach(lines) { l in
                        bubble(l).id(l.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 10)
            }
            .onChange(of: lines.count) { _ in scrollDown(proxy) }
            .onChange(of: lastSignature) { _ in scrollDown(proxy) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var lastSignature: String {
        guard let l = lines.last else { return "" }
        return l.id + "|" + l.trans + "|" + l.source
    }

    private func scrollDown(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo("bottom", anchor: .bottom) }
    }

    private var guide: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform")
                .font(.system(size: 38, weight: .ultraLight))
                .foregroundStyle(DSColor.accent)
            Text(guideText)
                .font(.subheadline)
                .foregroundStyle(DSColor.secondaryLabel)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    /// 对话列表：不分左右，全部合成一列。
    /// 以前自己说的靠右、对方靠左，两块底色也不一样；面对面的时候手机摆在中间，
    /// 眼睛得两边来回扫才能把一句话对上行，反而更费劲。
    /// 现在一律左对齐往下排：译文一行、原文一行，按时间顺序读就行。
    private func bubble(_ l: Line) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                if !l.trans.isEmpty {
                    Text(l.trans)
                        .font(.body.weight(l.done ? .semibold : .regular))
                        .foregroundStyle(DSColor.label)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !l.source.isEmpty, l.source != l.trans {
                    Text(l.source)
                        .font(.subheadline)
                        .foregroundStyle(DSColor.secondaryLabel)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(DSColor.cell)
            )
            .opacity(l.done ? 1 : 0.82)

            playButton(l)
        }
        .frame(maxWidth: .infinity)
    }

    /// 气泡旁边那颗播放键：这一句念出来。
    /// 同传不再自动出声——现场两个人都在说话，机器一开口就把人声压掉，
    /// 所以改成一键手动点播，念哪句、什么时候念由自己定。
    @ViewBuilder
    private func playButton(_ l: Line) -> some View {
        let text = l.trans.isEmpty ? l.source : l.trans
        if l.done, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Button {
                play(l, text)
            } label: {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 25, weight: .light))
                    .foregroundStyle(DSColor.tertiaryLabel)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("朗读这一句")
        } else {
            Color.clear.frame(width: 28, height: 1)
        }
    }

    private func play(_ l: Line, _ text: String) {
        haptic.impactOccurred()
        Speaker.shared.usesExternalSession = running
        Speaker.shared.micCapture = running
        Speaker.shared.voiceId = app.prefs.voiceId
        // 念出去的这句会被麦克风拾回来：先记一笔，引擎据此当回声丢掉，不再冒出一条一模一样的
        ZKInterpreter.shared()?.noteSpoken(text)
        // 点播走强制通道：不排队、不去重、不让路。自动朗读那一套门控是给「边说边念」用的，
        // 用户手动点一下还按那套走，就会出现点了没反应、或者刚开口就被下一句掐掉。
        Speaker.shared.playNow(text, lang: l.side == "a" ? other : mine)
    }

    // MARK: - 底部

    private var guideText: String {
        if holding { return canceling ? "松开手指取消这一句" : "正在听，上滑可取消" }
        return lines.isEmpty ? "按住下面对话，松手出译文" : "按住说话，松手翻译"
    }

    private var bottomBar: some View {
        VStack(spacing: 8) {
            // 长按说话：按住这段时间才算一句。松手结束、再翻译。
            // 松手后最后一句译文一落定就把会话关掉（见 beginAutoStop），
            // 不再常驻占着麦克风，也不需要再点一次「结束」。
            holdButton
                .overlay(alignment: .top) { slideHint }
        }
        .padding(.horizontal, DSSpace.l)
        .padding(.top, DSSpace.s)
        .padding(.bottom, DSSpace.xs)
        .background(DSColor.background)
        .overlay(alignment: .top) {
            Rectangle().fill(DSColor.separator).frame(height: 0.5)
        }
    }

    /// 按住时浮在按钮上方的那条提示：一眼告诉用户「上滑可以取消」，
    /// 真滑过阈值之后变成红色的「松开手指，取消这一句」。
    /// 用 overlay 浮在上面，不占布局——出现和消失都不会把按钮顶得动一下。
    private var slideHint: some View {
        HStack(spacing: 5) {
            Image(systemName: canceling ? "xmark.circle.fill" : "arrow.up")
                .font(.system(size: 11, weight: .bold))
            Text(canceling ? "松开手指，取消这一句" : "上滑取消")
                .font(.system(size: 13, weight: .medium))
        }
        .foregroundStyle(canceling ? Color.white : DSColor.secondaryLabel)
        .padding(.horizontal, DSSpace.s)
        .frame(height: 28)
        .background {
            if canceling {
                Capsule(style: .continuous).fill(DSColor.destructive)
            } else {
                Rectangle()
                    .fill(Color.clear)
                    .dsGlass(radius: 14, material: .thinMaterial)
            }
        }
        .offset(y: -36)
        .opacity(holding ? 1 : 0)
        .scaleEffect(holding ? 1 : 0.92, anchor: .bottom)
        .animation(.easeOut(duration: 0.16), value: holding)
        .animation(.easeOut(duration: 0.12), value: canceling)
        .allowsHitTesting(false)
    }

    private var holdButton: some View {
        ZStack {
            RoundedRectangle(cornerRadius: DSRadius.button, style: .continuous)
                .fill(canceling ? DSColor.destructive : DSColor.accentFill)
            HStack(spacing: DSSpace.xs) {
                if holding {
                    LevelBars(level: level)
                } else {
                    Image(systemName: "mic.fill")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(.white)
                }
                Text(holding ? (canceling ? "松开取消" : "松手翻译") : "按住说话")
                    .font(DSFont.headline)
                    .foregroundStyle(.white)
            }
        }
        .frame(height: 54)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { v in
                    if !holding { pressDown() }
                    let now = v.translation.height < -60
                    if now != canceling {
                        canceling = now
                        haptic.impactOccurred(intensity: 0.45)
                    }
                }
                .onEnded { _ in release() }
        )
    }

    // MARK: - 启停

    private func start() {
        guard !running else { return }
        if cloud.balanceCredits < Cloud.shared.minStartCredits {
            error = "积分不足，先去充值。"
            pendingSpeak = false
            return
        }
        // 麦克风权限得真拿到再开：没有权限时直接去碰 AVAudioEngine 的输入节点，系统会当场把进程带走
        ensureMic { ok in
            guard ok else {
                error = "需要麦克风权限才能同声传译，请在系统设置里允许后再试"
                pendingSpeak = false
                return
            }
            begin()
        }
    }

    private func ensureMic(_ done: @escaping (Bool) -> Void) {
        if #available(iOS 17.0, *) {
            switch AVAudioApplication.shared.recordPermission {
            case .granted: done(true); return
            case .denied: done(false); return
            default: break
            }
            AVAudioApplication.requestRecordPermission { ok in
                DispatchQueue.main.async { done(ok) }
            }
        } else {
            let sess = AVAudioSession.sharedInstance()
            switch sess.recordPermission {
            case .granted: done(true); return
            case .denied: done(false); return
            default: break
            }
            sess.requestRecordPermission { ok in
                DispatchQueue.main.async { done(ok) }
            }
        }
    }

    private func begin() {
        guard !running else { return }
        // 首页字幕翻译和同传都要占音频链路，两个一起跑必然互相打断——开同传就先停掉首页那场。
        // 停是异步的（引擎在后台队列里拆 tap、放掉录音），这边立刻去抢麦克风会撞车：
        // 头一两秒录不到东西，用户看到的就是「刚开始那几句认不出来」。
        // 所以从首页切过来时先等一下，让上一场真把麦克风还回来。
        let switching = app.running
        if switching { app.stop() }
        if switching {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                beginInterp()
            }
        } else {
            beginInterp()
        }
    }

    private func beginInterp() {
        guard !running else { return }
        running = true
        warming = true
        // 会话是每句按一次重建的，历史气泡要留着——这里绝不清空上一句
        // 兜底：通道没回报状态也照样在两秒后放开提示，别一直挂着「正在连接」
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [self] in
            if running { warming = false }
        }
        // 同传自己管着 PlayAndRecord 会话，朗读这边不许再去改会话类别
        Speaker.shared.usesExternalSession = true
        // 这一路是麦克风在听：没有系统声音可以让位，朗读只能靠"等空隙 + 让路"
        Speaker.shared.micCapture = true
        // 必须解一次暂停：上一场停止时 Speaker 会进入 paused，不解开的话
        // 后面每一句 speak() 都被直接挡掉——用户看到的就是"同传点了音频输出没声音"。
        Speaker.shared.resume()
        // 不自动出声：只把通道准备好，等用户点气泡旁边那颗播放键
        Speaker.shared.enabled = false
        Speaker.shared.voiceId = app.prefs.voiceId

        guard let itp = ZKInterpreter.shared() else {
            error = "同传引擎没启动起来，重开一次试试"
            running = false
            warming = false
            pendingSpeak = false
            Speaker.shared.usesExternalSession = false
            return
        }
        // 这一版只走长按说话：没按住的时候麦克风的声音不进上游。
        itp.pushToTalk = true
        itp.onLine = { lid, side, src, trans, kind in
            DispatchQueue.main.async {
                guard running else { return }
                // 松手之后还在回结果：每来一条就把收尾计时往后顺延，
                // 等它真没动静了再关会话——不能把最后一句的译文关在门外。
                failCount = 0
                warming = false
                if waitingFinal && !holding { scheduleIdleStop() }
                let isFinal = (kind == 2)   // ZKLineKindFinal
                let lineID = lid ?? UUID().uuidString
                // 这一次按住期间冒出来的行都记着：上滑取消时一起撤掉
                if holding { holdIDs.insert(lineID) }
                // 有人开口了（半句也算）：朗读据此避让，只在对方说完的空隙里念
                Speaker.shared.noteInput(src, final: isFinal)
                upsert(id: lineID, side: side ?? "a", source: src ?? "", trans: trans ?? "",
                       done: isFinal)
            }
        }
        itp.onLevel = { v in
            withAnimation(.linear(duration: 0.08)) { level = CGFloat(v) }
        }
        itp.onState = { _ in }
        // 上游断流（弱网、切网、代理抖动）太常见了，断一次就把通道原文
        // （OSStatus、waiting next packet 这类）糊到用户脸上，既看不懂也没用。
        // 现在先静默重开这一句：连着三次都接不上，才用一句人话提示。
        itp.onFail = { why in
            DispatchQueue.main.async {
                guard running else { return }
                let w = why ?? ""
                // 引擎自己写的中文说明（权限类）是给人看的，照说；
                // 其余都是通道层的原文，不外露。
                if w.contains("权限") || w.contains("麦克风") {
                    error = w
                    stop()
                    return
                }
                failCount += 1
                if failCount <= 2 {
                    let keepHolding = holding
                    waitingFinal = false
                    idleStop?.invalidate(); idleStop = nil
                    hardStop?.invalidate(); hardStop = nil
                    warming = true
                    ZKInterpreter.shared()?.stop()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        guard running else { return }
                        let again = ZKInterpreter.shared()
                        again?.pushToTalk = true
                        again?.start(with: mine, other: other)
                        if keepHolding { again?.beginUtterance() }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                            if running { warming = false }
                        }
                    }
                } else {
                    failCount = 0
                    error = "识别服务连接不稳定，请检查网络后重试。"
                    stop()
                }
            }
        }
        itp.start(with: mine, other: other)
        // 按下去的那一刻会话还在建：手还按着就立刻开始这一段（音频会在引擎里排队，
        // 连上之后补发，头几个字不会丢）；手已经松开了就什么都不做。
        if pendingSpeak {
            pendingSpeak = false
            if holding { itp.beginUtterance() }
        }
    }

    // MARK: - 长按

    private func pressDown() {
        guard !holding else { return }
        // 上一句的收尾计时先撤掉：这一句还没结束，别把会话关了
        idleStop?.invalidate(); idleStop = nil
        hardStop?.invalidate(); hardStop = nil
        waitingFinal = false
        holding = true
        canceling = false
        holdIDs.removeAll()
        haptic.impactOccurred()
        if running {
            ZKInterpreter.shared()?.beginUtterance()
        } else {
            pendingSpeak = true
            start()
        }
    }

    private func release() {
        guard holding else { return }
        holding = false
        if canceling {
            canceling = false
            cancelSpeak()
        } else {
            ZKInterpreter.shared()?.endUtterance()
            beginAutoStop()
        }
    }

    // MARK: - 松手收尾

    /// 松手之后：等最后一句的译文回来，然后把会话整个关掉。
    /// 用户说的「松手这一个会话就结束了」——不用再点「结束」，也不常驻占麦克风。
    /// 两个保险：最后一条结果之后 1.6 秒没新动静就关；最多等 6 秒必关。
    private func beginAutoStop() {
        waitingFinal = true
        hardStop?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: 6.0, repeats: false) { _ in
            if waitingFinal { finishAutoStop() }
        }
        RunLoop.main.add(t, forMode: .common)
        hardStop = t
        scheduleIdleStop()
    }

    private func scheduleIdleStop() {
        guard waitingFinal else { return }
        idleStop?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: 1.6, repeats: false) { _ in
            finishAutoStop()
        }
        RunLoop.main.add(t, forMode: .common)
        idleStop = t
    }

    private func finishAutoStop() {
        idleStop?.invalidate(); idleStop = nil
        hardStop?.invalidate(); hardStop = nil
        guard waitingFinal else { return }
        waitingFinal = false
        guard running else { return }
        running = false
        warming = false
        holding = false
        canceling = false
        pendingSpeak = false
        level = 0
        failCount = 0
        ZKInterpreter.shared()?.stop()
        Speaker.shared.stop()
        Speaker.shared.usesExternalSession = false
        Speaker.shared.micCapture = false
        if let itp = ZKInterpreter.shared() {
            itp.onLine = nil
            itp.onLevel = nil
            itp.onState = nil
            itp.onFail = nil
        }
    }

    /// 上滑取消：这一句不要了，把已经冒出来的半句也撤掉
    private func cancelSpeak() {
        pendingSpeak = false
        ZKInterpreter.shared()?.cancelUtterance()
        if !holdIDs.isEmpty {
            lines.removeAll { holdIDs.contains($0.id) }
        }
        holdIDs.removeAll()
    }

    /// 同一条消息原地更新：Draft 边听边出字，Final 落定，Update 补译文
    private func upsert(id: String, side: String, source: String, trans: String, done: Bool) {
        if let i = lines.firstIndex(where: { $0.id == id }) {
            // 引擎说这句不要了（重复 / 回声 / 纯噪声）：把这条气泡撤掉，
            // 不然聊天顶部会一直挂着半句没头没尾的字
            if source.isEmpty && trans.isEmpty {
                lines.remove(at: i)
                return
            }
            if !source.isEmpty { lines[i].source = source }
            if !trans.isEmpty || done { lines[i].trans = trans.isEmpty ? lines[i].trans : trans }
            if done { lines[i].done = true }
            return
        }
        let text = trans.isEmpty ? source : trans
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }
        // 兜底去重：同一句被两条通道各吐一遍（中→英 / 英→中 听的是同一路声音），
        // 引擎已经挡过一层，这里再按文字比一次——紧挨着重复的那句并到上一行，不再多一个气泡。
        // 只比够长的句子，像「好」「是」这种短句不动，免得把真的两句吞成一句。
        let k = Self.normForDedup(source)
        if k.count >= 6 {
            for i in stride(from: lines.count - 1, through: max(0, lines.count - 3), by: -1) {
                guard lines.indices.contains(i) else { break }
                let prev = lines[i]
                guard Self.normForDedup(prev.source) == k else { continue }
                if !trans.isEmpty, prev.trans.isEmpty { lines[i].trans = trans }
                if done { lines[i].done = true }
                return
            }
        }
        lines.append(Line(id: id, side: side, source: source, trans: trans, done: done))
        if lines.count > 240 { lines.removeFirst(lines.count - 240) }
    }

    /// 比重复用：去掉空白和标点、统一小写
    private static func normForDedup(_ s: String) -> String {
        let drop = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        return String(s.unicodeScalars.filter { !drop.contains($0) }).lowercased()
    }

    private func stop() {
        idleStop?.invalidate(); idleStop = nil
        hardStop?.invalidate(); hardStop = nil
        waitingFinal = false
        running = false
        warming = false
        holding = false
        canceling = false
        pendingSpeak = false
        failCount = 0
        ZKInterpreter.shared()?.stop()
        Speaker.shared.stop()
        // 会话归位：离开同传页之后朗读恢复成自己配会话
        Speaker.shared.usesExternalSession = false
        Speaker.shared.micCapture = false
        level = 0
        if let itp = ZKInterpreter.shared() {
            itp.onLine = nil
            itp.onLevel = nil
            itp.onState = nil
            itp.onFail = nil
        }
    }
}

// MARK: - 电平指示

/// 五根柱子跟着输入音量跳，让人一眼看出「在听」，而不是对着静止界面猜
private struct LevelBars: View {
    let level: CGFloat
    private let weights: [CGFloat] = [0.55, 0.85, 1.0, 0.78, 0.6]

    var body: some View {
        HStack(alignment: .center, spacing: 2.5) {
            ForEach(0..<5, id: \.self) { i in
                Capsule()
                    .fill(Color.white.opacity(0.9))
                    .frame(width: 3, height: 4 + 14 * max(0.08, level * weights[i]))
            }
        }
        .frame(height: 18)
    }
}

// MARK: - 语言选择

private struct LangPicker: View {
    @Binding var mine: String
    @Binding var other: String
    var onDone: (String, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var a: String
    @State private var b: String

    init(mine: Binding<String>, other: Binding<String>, onDone: @escaping (String, String) -> Void) {
        self._mine = mine
        self._other = other
        self.onDone = onDone
        self._a = State(initialValue: mine.wrappedValue)
        self._b = State(initialValue: other.wrappedValue)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    section("我的语言", current: $a, exclude: b)
                    section("对方的语言", current: $b, exclude: a)
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .screenBackground()
            .glassNavigationBar()
            .navigationTitle("选择语言")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("确定") {
                        let aa = a, bb = b
                        mine = aa; other = bb
                        onDone(aa, bb)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .foregroundStyle(DSColor.accent)
                }
            }
        }
    }

    private func section(_ title: String, current: Binding<String>, exclude: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(DSColor.secondaryLabel)
                .padding(.leading, 4)
            VStack(spacing: 0) {
                ForEach(Array(InterpreterView.langs.enumerated()), id: \.offset) { _, item in
                    if item.0 != exclude {
                        Button {
                            current.wrappedValue = item.0
                        } label: {
                            HStack {
                                Text(item.1)
                                    .font(.body)
                                    .foregroundStyle(DSColor.label)
                                Spacer()
                                if current.wrappedValue == item.0 {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundStyle(DSColor.accent)
                                }
                            }
                            .padding(.horizontal, 16)
                            .frame(height: 48)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(RowButtonStyle())
                        if item.0 != InterpreterView.langs.filter({ $0.0 != exclude }).last?.0 {
                            Rectangle().fill(DSColor.separator).frame(height: 0.5).padding(.leading, 16)
                        }
                    }
                }
            }
            .background(DSColor.cell, in: RoundedRectangle(cornerRadius: DSRadius.card, style: .continuous))
        }
    }
}
