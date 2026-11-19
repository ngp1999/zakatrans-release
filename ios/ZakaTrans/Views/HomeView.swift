import SwiftUI

/// 首页：一个按钮开始，实时字幕就在下面滚。
///
/// 布局按「用的时候拇指够得到」排：上面是状态和字幕，下面固定两个大按钮。
struct HomeView: View {
    @ObservedObject private var app = AppState.shared
    @ObservedObject private var cloud = Cloud.shared
    @ObservedObject private var speaker = Speaker.shared
    @State private var showBuy = false

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                    .padding(.horizontal, 20)
                    .padding(.top, 6)

                subtitlePanel
                    .padding(.horizontal, 16)
                    .padding(.top, 16)

                controls
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 8)
            }

            // 隐藏宿主：画中画和系统录屏面板都要求真实 UIView 挂在窗口上
            ZStack {
                PipAnchor().frame(width: 1, height: 1)
                BroadcastPicker().frame(width: 60, height: 60)
            }
            .opacity(0.01)
            .allowsHitTesting(false)
        }
        .alert(item: Binding(
            get: { app.alert.map { AlertText(text: $0) } },
            set: { if $0 == nil { app.alert = nil } }
        )) { item in
            Alert(title: Text("提示"), message: Text(item.text), dismissButton: .default(Text("知道了")))
        }
        .sheet(isPresented: $showBuy) {
            NavigationStack { PurchaseView() }
        }
    }

    // MARK: - 顶部

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("ZAKATRANS")
                .font(.system(size: 11, weight: .semibold))
                .tracking(1.6)
                .foregroundStyle(Theme.faint)

            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(app.running ? Theme.accent : Theme.faint.opacity(0.5))
                            .frame(width: 7, height: 7)
                            .overlay(
                                Circle()
                                    .stroke(Theme.accent.opacity(app.running ? 0.35 : 0), lineWidth: 4)
                            )
                        Text("实时字幕翻译")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundStyle(Theme.ink)
                    }
                    Text(app.status)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.sub)
                        .lineLimit(1)
                }
                Spacer(minLength: 12)
                CreditPill(credits: cloud.balanceCredits) { showBuy = true }
            }
        }
    }

    // MARK: - 字幕

    private var subtitlePanel: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        if app.lines.isEmpty && app.liveSource.isEmpty {
                            emptyState
                        }
                        ForEach(app.lines) { line in
                            lineRow(line).id(line.id)
                        }
                        if !app.liveSource.isEmpty || !app.liveTrans.isEmpty {
                            liveRow.id("live")
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: app.lines.count) { _ in
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo("live", anchor: .bottom)
                    }
                }
            }
            .frame(maxHeight: .infinity)

            if !app.lines.isEmpty {
                HStack {
                    Text("\(app.lines.count) 句")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.faint)
                    Spacer()
                    Button {
                        ZKStore.clearLines()
                        app.lines.removeAll()
                    } label: {
                        Text("清空")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.sub)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .overlay(alignment: .top) {
                    Rectangle().fill(Theme.line).frame(height: 0.5)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(app.running ? Theme.accent.opacity(0.35) : Color.clear, lineWidth: 1.2)
        )
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: app.running ? "waveform" : "captions.bubble")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(Theme.accent.opacity(0.75))
            Text(app.running ? "正在等声音…" : "点下面的按钮开始")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Theme.ink)
            Text(app.running
                 ? "在弹出的系统面板里选「ZakaTrans」并开始直播，声音一进来字幕就出现。"
                 : "开始后按提示启动录屏，对方说什么都会实时译成中文；切到别的 App 也能看画中画。")
                .font(.system(size: 13))
                .foregroundStyle(Theme.sub)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 26)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func lineRow(_ line: AppState.SubtitleLine) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if app.prefs.mode != "source", !line.trans.isEmpty {
                Text(line.trans)
                    .font(.system(size: app.prefs.size, weight: .medium))
                    .foregroundStyle(app.prefs.mode == "zh" ? Theme.ink : app.prefs.swiftUIColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if app.prefs.mode != "zh", !line.source.isEmpty {
                Text(line.source)
                    .font(.system(size: max(12, app.prefs.size - 5)))
                    .foregroundStyle(Theme.sub)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var liveRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            if app.prefs.mode != "source", !app.liveTrans.isEmpty {
                Text(app.liveTrans)
                    .font(.system(size: app.prefs.size, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if app.prefs.mode != "zh", !app.liveSource.isEmpty {
                Text(app.liveSource)
                    .font(.system(size: max(12, app.prefs.size - 5)))
                    .foregroundStyle(Theme.sub)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 控制

    private var controls: some View {
        VStack(spacing: 12) {
            Button {
                if app.running {
                    app.stop()
                } else {
                    Task {
                        await app.start()
                        if app.running { BroadcastTrigger.shared.fire() }
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: app.running ? "stop.fill" : "play.fill")
                        .font(.system(size: 15, weight: .bold))
                    Text(app.running ? "停止" : "开始实时翻译")
                }
            }
            .buttonStyle(PrimaryButtonStyle(tint: app.running ? Theme.warn : Theme.accent))

            HStack(spacing: 10) {
                actionTile(
                    icon: speaker.enabled ? "speaker.wave.2.fill" : "speaker.slash",
                    title: "输出音频",
                    detail: speaker.enabled ? "朗读译文" : "关闭",
                    on: speaker.enabled
                ) {
                    app.updatePrefs { $0.tts.toggle() }
                    if !app.prefs.tts { Speaker.shared.stop() }
                }

                actionTile(
                    icon: "pip.fill",
                    title: "画中画",
                    detail: app.prefs.pip == "bar" ? "横条" : "大窗",
                    on: app.prefs.pip == "bar"
                ) {
                    app.updatePrefs { $0.pip = $0.pip == "bar" ? "standard" : "bar" }
                }
            }

            VStack(spacing: 2) {
                Text("按翻译使用的有效用量扣积分，不按时长 · 1 元 = 10 积分")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.faint)
                Text("剩余 \(Format.credits(cloud.balanceCredits)) 积分")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(cloud.balanceCredits < cloud.minStartCredits ? Theme.warn : Theme.sub)
            }
            .multilineTextAlignment(.center)
            .padding(.bottom, 2)
        }
    }

    private func actionTile(icon: String, title: String, detail: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(on ? Theme.accent : Theme.sub)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.ink)
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.sub)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .frame(height: 52)
            .frame(maxWidth: .infinity)
            .background(on ? Theme.accentSoft : Theme.fill)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

struct AlertText: Identifiable {
    let id = UUID()
    let text: String
}
