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
    @ObservedObject private var speaker = Speaker.shared
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
    @State private var spoken: Set<String> = []

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
            transcript
            bottomBar
        }
        .background(Theme.bg)
        .sheet(isPresented: $showLang) {
            LangPicker(mine: $mine, other: $other) { a, b in
                mine = a; other = b
                ZKInterpreter.shared()?.setMine(a, other: b)
            }
        }
        // 用自绘提示框，跟 App 其他地方的卡片是同一套语言（系统 alert 一弹出来就出戏）
        .notice($error)
        .onDisappear {
            if running { stop() }
        }
    }

    // MARK: - 语言

    private var languageRow: some View {
        HStack(spacing: 8) {
            Button {
                guard !running else { return }
                haptic.impactOccurred()
                showLang = true
            } label: {
                HStack(spacing: 6) {
                    Text(name(mine))
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.faint)
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
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.accent)
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
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.faint)
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
                .foregroundStyle(Theme.accent)
            Text("点开始，直接说话")
                .font(.system(size: 15))
                .foregroundStyle(Theme.sub)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    private func bubble(_ l: Line) -> some View {
        let mineSide = l.side == "a"
        return HStack(alignment: .bottom, spacing: 0) {
            if mineSide { Spacer(minLength: 52) }

            VStack(alignment: mineSide ? .trailing : .leading, spacing: 5) {
                if !l.trans.isEmpty {
                    Text(l.trans)
                        .font(.system(size: 17, weight: l.done ? .semibold : .regular))
                        .foregroundStyle(mineSide ? Color.white : Theme.ink)
                        .multilineTextAlignment(mineSide ? .trailing : .leading)
                }
                if !l.source.isEmpty, l.source != l.trans {
                    Text(l.source)
                        .font(.system(size: 14))
                        .foregroundStyle(mineSide ? Color.white.opacity(0.72) : Theme.sub)
                        .multilineTextAlignment(mineSide ? .trailing : .leading)
                }
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(mineSide ? Theme.accent : Theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(mineSide ? Color.clear : Theme.hairline, lineWidth: 0.8)
            )
            .opacity(l.done ? 1 : 0.82)

            if !mineSide { Spacer(minLength: 52) }
        }
    }

    // MARK: - 底部

    private var bottomBar: some View {
        HStack(spacing: 10) {
            // 朗读开关：一眼看得出现在念不念
            Button {
                haptic.impactOccurred()
                let on = !speaker.enabled
                speaker.enabled = on
                Speaker.shared.enabled = on
                if on {
                    Speaker.shared.resume()
                    Speaker.shared.usesExternalSession = running
                } else {
                    Speaker.shared.stop()
                }
                app.updatePrefs { $0.tts = on }
            } label: {
                Image(systemName: speaker.enabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(speaker.enabled ? Theme.accent : Theme.sub)
                    .frame(width: 54, height: 54)
                    .background(speaker.enabled ? Theme.accentSoft : Theme.surface)
                    .clipShape(Circle())
            }
            .buttonStyle(TileButtonStyle())

            Button {
                haptic.impactOccurred(intensity: 0.8)
                if running { stop() } else { start() }
            } label: {
                HStack(spacing: 9) {
                    if running {
                        LevelBars(level: level)
                    } else {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 15, weight: .bold))
                    }
                    Text(running ? "结束同声传译" : "开始同声传译")
                        .font(.system(size: 17, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButtonStyle(tint: running ? Theme.warn : Theme.accent))
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(Theme.bg)
    }

    // MARK: - 启停

    private func start() {
        guard !running else { return }
        if cloud.balanceCredits < Cloud.shared.minStartCredits {
            error = "积分不足，先去充值。"
            return
        }
        // 麦克风权限得真拿到再开：没有权限时直接去碰 AVAudioEngine 的输入节点，系统会当场把进程带走
        ensureMic { ok in
            guard ok else {
                error = "需要麦克风权限才能同声传译，请在系统设置里允许后再试"
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
        // 首页字幕翻译和同传都要占音频链路，两个一起跑必然互相打断——开同传就先停掉首页那场
        if app.running { app.stop() }
        lines.removeAll()
        spoken.removeAll()
        running = true
        // 同传自己管着 PlayAndRecord 会话，朗读这边不许再去改会话类别
        Speaker.shared.usesExternalSession = true
        // 这一路是麦克风在听：没有系统声音可以让位，朗读只能靠"等空隙 + 让路"
        Speaker.shared.micCapture = true
        // 必须解一次暂停：上一场停止时 Speaker 会进入 paused，不解开的话
        // 后面每一句 speak() 都被直接挡掉——用户看到的就是"同传点了音频输出没声音"。
        Speaker.shared.resume()
        Speaker.shared.enabled = app.prefs.tts
        Speaker.shared.voiceId = app.prefs.voiceId

        guard let itp = ZKInterpreter.shared() else {
            error = "同传引擎没启动起来，重开一次试试"
            running = false
            Speaker.shared.usesExternalSession = false
            return
        }
        itp.onLine = { lid, side, src, trans, kind in
            DispatchQueue.main.async {
                guard running else { return }
                let isFinal = (kind == 2)   // ZKLineKindFinal
                let lineID = lid ?? UUID().uuidString
                // 有人开口了（半句也算）：朗读据此避让，只在对方说完的空隙里念
                Speaker.shared.noteInput(src, final: isFinal)
                upsert(id: lineID, side: side ?? "a", source: src ?? "", trans: trans ?? "",
                       done: isFinal)

                // 朗读：句子里一有译文就念。同一条只念一次
                let tr = (trans ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if Speaker.shared.enabled, !tr.isEmpty, isFinal, !spoken.contains(lineID) {
                    // 自己念出去的那句被麦克风拾回来，会被当成"对方又说了一遍"
                    let srcText = src ?? ""
                    if Speaker.shared.isEcho([tr, srcText]) { return }
                    spoken.insert(lineID)
                    // 记下这句：麦克风会把它录回来再识别一遍，引擎据此认掉回声
                    ZKInterpreter.shared()?.noteSpoken(tr)
                    Speaker.shared.speak(tr, lang: (side ?? "a") == "a" ? other : mine)
                }
            }
        }
        itp.onLevel = { v in
            withAnimation(.linear(duration: 0.08)) { level = CGFloat(v) }
        }
        itp.onState = { _ in }
        itp.onFail = { why in
            DispatchQueue.main.async {
                error = why ?? ""
                stop()
            }
        }
        itp.start(with: mine, other: other)
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
        lines.append(Line(id: id, side: side, source: source, trans: trans, done: done))
        if lines.count > 240 { lines.removeFirst(lines.count - 240) }
    }

    private func stop() {
        running = false
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
            .background(Theme.bg)
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
                    .foregroundStyle(Theme.accent)
                }
            }
        }
    }

    private func section(_ title: String, current: Binding<String>, exclude: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.sub)
                .padding(.leading, 4)
            VStack(spacing: 0) {
                ForEach(Array(InterpreterView.langs.enumerated()), id: \.offset) { _, item in
                    if item.0 != exclude {
                        Button {
                            current.wrappedValue = item.0
                        } label: {
                            HStack {
                                Text(item.1)
                                    .font(.system(size: 16))
                                    .foregroundStyle(Theme.ink)
                                Spacer()
                                if current.wrappedValue == item.0 {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundStyle(Theme.accent)
                                }
                            }
                            .padding(.horizontal, 16)
                            .frame(height: 48)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(RowButtonStyle())
                        if item.0 != InterpreterView.langs.filter({ $0.0 != exclude }).last?.0 {
                            Rectangle().fill(Theme.hairline).frame(height: 0.5).padding(.leading, 16)
                        }
                    }
                }
            }
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
}
