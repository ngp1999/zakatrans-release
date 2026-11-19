import SwiftUI

/// 同声传译：面对面说话，两边的话各自翻译、各自朗读。
/// 先选两个语言，点开始，然后直接说——说话人不用切换，系统按识别出的语言自动归边。
struct InterpreterView: View {
    @ObservedObject private var app = AppState.shared
    @ObservedObject private var cloud = Cloud.shared
    @ObservedObject private var speaker = Speaker.shared
    private let haptic = UIImpactFeedbackGenerator(style: .light)

    struct Chat: Identifiable {
        let id = UUID()
        let side: String      // "a" 我 / "b" 对方
        let source: String
        let trans: String
        var final: Bool
    }

    @State private var mine: String = "zh-CN"
    @State private var other: String = "en-US"
    @State private var running = false
    @State private var state = "未开始"
    @State private var chats: [Chat] = []
    @State private var liveA = ""
    @State private var liveB = ""
    @State private var showLang = false
    @State private var error: String?
    @State private var startedAt: Date?

    /// 会用的语言（都是系统语音认得的）
    static let langs: [(String, String)] = [
        ("zh-CN", "中文"),
        ("en-US", "English"),
        ("ja-JP", "日本語"),
        ("ko-KR", "한국어"),
        ("es-ES", "Español"),
        ("fr-FR", "Français"),
        ("de-DE", "Deutsch"),
        ("ru-RU", "Русский"),
        ("th-TH", "ไทย"),
        ("vi-VN", "Tiếng Việt"),
    ]

    private func name(_ code: String) -> String {
        Self.langs.first { $0.0 == code }?.1 ?? code
    }

    var body: some View {
        VStack(spacing: 0) {
            languageBar
            transcript
            bottomBar
        }
        .background(Theme.bg)
        .navigationTitle("同声传译")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showLang) {
            LangPicker(mine: $mine, other: $other) { a, b in
                mine = a; other = b
                ZKInterpreter.shared()?.setMine(a, other: b)
            }
        }
        .alert("提示", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("知道了", role: .cancel) { error = nil }
        } message: {
            Text(error ?? "")
        }
        .onDisappear {
            if running { stop() }
        }
    }

    // MARK: - 语言条

    private var languageBar: some View {
        Button {
            haptic.impactOccurred()
            showLang = true
        } label: {
            HStack(spacing: 10) {
                langChip(name(mine), accent: true)
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.sub)
                langChip(name(other), accent: false)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.faint)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(running)
        .opacity(running ? 0.6 : 1)
    }

    private func langChip(_ t: String, accent: Bool) -> some View {
        Text(t)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(accent ? Theme.accent : Theme.ink)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(accent ? Theme.accentSoft : Theme.fill)
            )
    }

    // MARK: - 对话

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 10) {
                    if chats.isEmpty && !running {
                        guide
                    }
                    ForEach(chats) { c in
                        bubble(c)
                    }
                    if running {
                        if !liveA.isEmpty || !liveB.isEmpty {
                            bubble(Chat(side: liveA.isEmpty ? "b" : "a",
                                        source: liveA.isEmpty ? liveB : liveA,
                                        trans: "", final: false))
                        }
                        listening
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .padding(.bottom, 12)
            }
            .onChange(of: chats.count) { _ in
                if let last = chats.last {
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private var guide: some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform.and.mic")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Theme.accent)
            Text("选好两边语言，点开始")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.ink)
            VStack(alignment: .leading, spacing: 8) {
                tip("1", "把手机放在两人中间")
                tip("2", "谁说话都行，不用按键、不用切人")
                tip("3", "译文会自动念出来，耳机效果更好")
            }
            Text("按识别出的文字量计费，两边说话都算在一起")
                .font(.system(size: 11))
                .foregroundStyle(Theme.faint)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
    }

    private func tip(_ n: String, _ t: String) -> some View {
        HStack(spacing: 8) {
            Text(n)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.accent)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Theme.accentSoft))
            Text(t)
                .font(.system(size: 12))
                .foregroundStyle(Theme.sub)
            Spacer(minLength: 0)
        }
    }

    private func bubble(_ c: Chat) -> some View {
        HStack {
            if c.side == "a" { Spacer(minLength: 40) }
            VStack(alignment: c.side == "a" ? .trailing : .leading, spacing: 4) {
                Text(c.side == "a" ? name(mine) : name(other))
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.faint)
                if !c.source.isEmpty {
                    Text(c.source)
                        .font(.system(size: 15))
                        .foregroundStyle(c.side == "a" ? .white : Theme.ink)
                        .multilineTextAlignment(c.side == "a" ? .trailing : .leading)
                }
                if !c.trans.isEmpty {
                    Text(c.trans)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(c.side == "a" ? .white.opacity(0.92) : Theme.accent)
                        .multilineTextAlignment(c.side == "a" ? .trailing : .leading)
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(c.side == "a" ? Theme.accent : Theme.fill)
            )
            .opacity(c.final ? 1 : 0.75)
            if c.side == "b" { Spacer(minLength: 40) }
        }
        .id(c.id)
    }

    private var listening: some View {
        HStack(spacing: 6) {
            Circle().fill(Theme.accent).frame(width: 6, height: 6)
            Text(state)
                .font(.system(size: 11))
                .foregroundStyle(Theme.faint)
            Spacer(minLength: 0)
        }
        .padding(.top, 4)
    }

    // MARK: - 底部

    private var bottomBar: some View {
        VStack(spacing: 10) {
            Button {
                haptic.impactOccurred(intensity: 0.7)
                if running { stop() } else { start() }
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: running ? "stop.fill" : "mic.fill")
                        .font(.system(size: 15, weight: .bold))
                    Text(running ? "结束同声传译" : "开始同声传译")
                        .font(.system(size: 17, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButtonStyle(tint: running ? Theme.warn : Theme.accent))

            HStack {
                Image(systemName: speaker.enabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .font(.system(size: 12))
                Text(speaker.enabled ? "朗读已开启" : "朗读已关闭")
                    .font(.system(size: 12))
                Spacer()
                Text("积分 \(Int(cloud.balanceCredits))")
                    .font(.system(size: 12))
                Text("·")
                    .font(.system(size: 12))
                Button("朗读设置") {
                    haptic.impactOccurred()
                    showAudioSheet = true
                }
                .font(.system(size: 12))
            }
            .foregroundStyle(Theme.faint)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(Theme.bg)
        .sheet(isPresented: $showAudioSheet) {
            NavigationStack { AudioOutputView() }
        }
    }

    @State private var showAudioSheet = false

    // MARK: - 启停

    private func start() {
        guard !running else { return }
        if cloud.balanceCredits < Cloud.shared.minStartCredits {
            error = "积分不足，先去充值。"
            return
        }
        chats.removeAll()
        liveA = ""; liveB = ""
        startedAt = Date()
        running = true
        state = "连接中"

        guard let itp = ZKInterpreter.shared() else { error = "同传引擎没启动起来，重开一次试试"; return }
        itp.onLine = { side, source, trans, final in
            let s = side ?? "a"
            let source = source ?? ""
            let trans = trans ?? ""
            DispatchQueue.main.async {
                // 增量：先在「正在说」那行里滚
                if !final {
                    if s == "a" { liveA = source.isEmpty ? liveA : source } else { liveB = source.isEmpty ? liveB : source }
                    return
                }
                // 整句：落成一条消息，清掉临时行
                if s == "a" { liveA = "" } else { liveB = "" }
                let text = source.trimmingCharacters(in: .whitespacesAndNewlines)
                let tr = trans.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty || !tr.isEmpty else { return }
                chats.append(Chat(side: s, source: text, trans: tr, final: true))
                if chats.count > 200 { chats.removeFirst(chats.count - 200) }

                // 朗读：念译文（念另一种语言）
                if Speaker.shared.enabled, !tr.isEmpty {
                    Speaker.shared.speak(tr, lang: s == "a" ? other : mine)
                }
            }
        }
        itp.onState = { st in
            DispatchQueue.main.async { state = st }
        }
        itp.onFail = { why in
            DispatchQueue.main.async {
                error = why
                stop()
            }
        }
        itp.start(with: mine, other: other)
    }

    private func stop() {
        running = false
        ZKInterpreter.shared()?.stop()
        Speaker.shared.stop()
        state = "未开始"
        liveA = ""; liveB = ""
        startedAt = nil
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
                VStack(spacing: 18) {
                    section("我的语言", current: $a, exclude: b)
                    section("对方的语言", current: $b, exclude: a)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
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
                }
            }
        }
    }

    private func section(_ title: String, current: Binding<String>, exclude: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.sub)
            VStack(spacing: 0) {
                ForEach(Array(InterpreterView.langs.enumerated()), id: \.offset) { _, item in
                    if item.0 != exclude {
                        Button {
                            current.wrappedValue = item.0
                        } label: {
                            HStack {
                                Text(item.1)
                                    .font(.system(size: 15))
                                    .foregroundStyle(Theme.ink)
                                Text(item.0)
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.faint)
                                Spacer()
                                if current.wrappedValue == item.0 {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundStyle(Theme.accent)
                                }
                            }
                            .padding(.vertical, 11)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider().opacity(0.4)
                    }
                }
            }
        }
        .card(padding: 14)
    }
}
