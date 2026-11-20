import SwiftUI
import UIKit

/// 首页：一个按钮开始，字幕就在下面滚。
struct HomeView: View {
    @ObservedObject private var app = AppState.shared
    @ObservedObject private var cloud = Cloud.shared
    @ObservedObject private var speaker = Speaker.shared
    @State private var showCredit = false
    @State private var showAudio = false

    private let haptic = UIImpactFeedbackGenerator(style: .light)

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                    .padding(.horizontal, 20)
                    .padding(.top, 6)

                subtitlePanel
                    .padding(.horizontal, 16)
                    .padding(.top, 14)

                controls
                    .padding(.horizontal, 20)
                    .padding(.top, 14)
                    .padding(.bottom, 6)
            }
        }
        .sheet(isPresented: $showCredit) {
            NavigationStack { CreditView() }
        }
        .sheet(isPresented: $showAudio) {
            NavigationStack { AudioOutputView() }
        }
        .alert("积分不足", isPresented: Binding(
            get: { app.alert != nil },
            set: { if !$0 { app.alert = nil } }
        )) {
            Button("去充值") { app.alert = nil; showCredit = true }
            Button("取消", role: .cancel) { app.alert = nil }
        } message: {
            Text(app.alert ?? "")
        }
    }

    // MARK: - 顶部

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            HStack(spacing: 9) {
                // App 图标（就是桌面那个，纯色青绿 + 两条字幕条）
                Image("Logo")
                    .resizable()
                    .scaledToFill()
                    .frame(width: 32, height: 32)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 1) {
                    Text("语幕-实时翻译")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                }

                if app.running {
                    Circle()
                        .fill(Theme.accent)
                        .frame(width: 6, height: 6)
                        .padding(.leading, 2)
                }
            }
            Spacer(minLength: 8)
            CreditPill(credits: cloud.balanceCredits) { showCredit = true }
        }
    }

    // MARK: - 字幕

    private var subtitlePanel: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if app.lines.isEmpty && app.liveSource.isEmpty && app.liveTrans.isEmpty {
                        emptyState
                    }
                    ForEach(app.lines) { line in
                        lineRow(line).id(line.id)
                    }
                    if !app.liveSource.isEmpty || !app.liveTrans.isEmpty {
                        liveRow.id("live")
                    }
                    // 滚动锚点：新一句进来时滚到这里，字幕是从下往上走的
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: app.lines.count) { _ in
                withAnimation(.easeOut(duration: 0.24)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: app.liveTrans) { _ in
                withAnimation(.easeOut(duration: 0.16)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: app.liveSource) { _ in
                withAnimation(.easeOut(duration: 0.16)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(app.running ? Theme.accent.opacity(0.3) : Color.clear, lineWidth: 1)
        )
    }

    /// 没开始时的引导：告诉用户这三步会发生什么，别让中间空一大片
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("把任何声音变成中文字幕")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Text("视频、会议、播客、网课，播放什么就翻译什么。")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.sub)
            }

            VStack(alignment: .leading, spacing: 14) {
                step(1, "点下面的「开始字幕翻译」")
                step(2, "在系统面板里选「语幕」并开始录屏")
                step(3, "字幕浮窗自动出现，回桌面也继续显示")
            }

            Divider().opacity(0.5)

            VStack(alignment: .leading, spacing: 8) {
                tip("globe", "源语言自动识别，输出中文")
                tip("speaker.wave.2", "开着音频输出时，别的视频声音会自动降低")
                tip("rectangle.on.rectangle", "窗口大小、字号、颜色都在「我的 → 字幕样式」里")
                tip("mic.slash", "不说话的部分不计费，按识别出的文字量算")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 24)
        .padding(.horizontal, 2)
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)")
                .font(.system(size: 12, weight: .bold).monospacedDigit())
                .foregroundStyle(Theme.accent)
                .frame(width: 20, height: 20)
                .background(Theme.accentSoft)
                .clipShape(Circle())
            Text(text)
                .font(.system(size: 14))
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func tip(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(Theme.accent)
                .frame(width: 16)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(Theme.faint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // 对话记录永远两条都在（译文在上、原文在下）。
    // 字幕浮窗上的"只看译文 / 只看原文"只管浮窗，不能把记录也一起裁掉——
    // 之前记录里只剩英文，就是因为这个开关把译文那行也藏了。
    private func lineRow(_ line: AppState.SubtitleLine) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if !line.trans.isEmpty {
                Text(line.trans)
                    .font(.system(size: app.prefs.size, weight: .semibold))
                    .foregroundStyle(app.prefs.swiftUIColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !line.source.isEmpty, line.source != line.trans {
                Text(line.source)
                    .font(.system(size: max(12, app.prefs.size - 4)))
                    .foregroundStyle(Theme.sub)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var liveRow: some View {
        VStack(alignment: .leading, spacing: 5) {
            if !app.liveTrans.isEmpty {
                Text(app.liveTrans)
                    .font(.system(size: app.prefs.size, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !app.liveSource.isEmpty, app.liveSource != app.liveTrans {
                Text(app.liveSource)
                    .font(.system(size: max(12, app.prefs.size - 4)))
                    .foregroundStyle(Theme.sub)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 控制

    private var controls: some View {
        VStack(spacing: 10) {
            Button {
                haptic.impactOccurred(intensity: 0.7)
                if app.running || app.preparing {
                    withAnimation(.easeOut(duration: 0.2)) { app.stop() }
                } else if !app.preparing {
                    Task {
                        await app.start()
                        if app.running { BroadcastTrigger.shared.fire() }
                    }
                }
            } label: {
                HStack(spacing: 9) {
                    if app.preparing {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(.white)
                            .scaleEffect(0.85)
                    } else {
                        Image(systemName: (app.running && !app.preparing) ? "stop.fill" : "play.fill")
                            .font(.system(size: 15, weight: .bold))
                    }
                    Text(app.preparing ? "正在加载字幕浮窗" : (app.running ? "停止" : "开始字幕翻译"))
                        .font(.system(size: 17, weight: .semibold))
                        .contentTransition(.opacity)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButtonStyle(tint: (app.running && !app.preparing) ? Theme.warn : Theme.accent))
            // 加载态的呼吸光圈：让人一眼看出「在等浮窗，不是没反应」
            .overlay(PreparingGlow(on: app.preparing).allowsHitTesting(false))

            HStack(spacing: 10) {
                // 朗读设置：点进去调语速、压低、音色
                Button {
                    haptic.impactOccurred()
                    showAudio = true
                } label: {
                    tile(
                        icon: speaker.enabled ? "speaker.wave.2.fill" : "speaker.slash.fill",
                        title: "音频输出",
                        detail: speaker.enabled ? String(format: "已开启 · %.2fx", app.prefs.speechRate) : "已关闭",
                        on: speaker.enabled
                    )
                }
                .buttonStyle(TileButtonStyle())

                // 窗口：选哪个，画中画开出来就是多大（含开关）
                Menu {
                    ForEach(SubtitlePrefs.pipOptions, id: \.0) { opt in
                        Button {
                            haptic.impactOccurred()
                            withAnimation(.easeOut(duration: 0.18)) {
                                app.updatePrefs { $0.pip = opt.0 }
                                app.setPip(true)
                            }
                        } label: {
                            if app.prefs.pip == opt.0 {
                                Label("窗口\(opt.1) · \(SubtitlePrefs.pipSizeText(opt.0))", systemImage: "checkmark")
                            } else {
                                Text("窗口\(opt.1) · \(SubtitlePrefs.pipSizeText(opt.0))")
                            }
                        }
                    }
                    Divider()
                    Button {
                        haptic.impactOccurred()
                        app.setPip(!app.pipOn)
                    } label: {
                        Label(app.pipOn ? "关闭画中画" : "打开画中画",
                              systemImage: app.pipOn ? "pip.remove" : "pip.fill")
                    }
                } label: {
                    tile(
                        icon: app.pipOn ? (app.prefs.pip == "S" ? "rectangle.wide" : "pip.fill") : "pip.remove",
                        title: "窗口",
                        detail: app.pipOn ? "窗口\(pipLabel) · \(SubtitlePrefs.pipSizeText(app.prefs.pip))" : "已关闭",
                        on: app.pipOn
                    )
                }
                .buttonStyle(TileButtonStyle())
            }
        }
    }

    /// 大 / 中 / 小
    private var pipLabel: String {
        SubtitlePrefs.pipOptions.first { $0.0 == app.prefs.pip }?.1 ?? "大"
    }

    private func tile(icon: String, title: String, detail: String, on: Bool) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(on ? Theme.accent : Theme.sub)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.ink)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(on ? Theme.accent : Theme.sub)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(height: 56)
        .frame(maxWidth: .infinity)
        .background(on ? Theme.accentSoft : Theme.fill)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(on ? Theme.accent.opacity(0.35) : Color.clear, lineWidth: 1)
        )
    }
}

/// 小按钮的按压反馈：缩一下、压暗一点，手指一按就有回应
struct TileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct AlertText: Identifiable {
    let id = UUID()
    let text: String
}

/// 加载态光环：按钮外面一圈呼吸的描边
private struct PreparingGlow: View {
    let on: Bool
    @State private var flip = false

    var body: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .stroke(Theme.accent.opacity(0.6), lineWidth: 2)
            .scaleEffect(flip ? 1.035 : 1.0)
            .opacity(flip ? 0 : 0.9)
            .animation(on ? .easeInOut(duration: 0.95).repeatForever(autoreverses: true) : .easeOut(duration: 0.2), value: flip)
            .onChange(of: on) { v in flip = v }
            .onAppear { if on { flip = true } }
    }
}
