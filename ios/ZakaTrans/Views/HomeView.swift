import SwiftUI
import UIKit

/// 首页：一个按钮开始，字幕就在下面滚。
struct HomeView: View {
    @ObservedObject private var app = AppState.shared
    @ObservedObject private var cloud = Cloud.shared
    @ObservedObject private var speaker = Speaker.shared
    @State private var showCredit = false

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
                step(1, "点下面的「开始实时翻译」")
                step(2, "在系统面板里选「语幕」并开始录屏")
                step(3, "字幕自动浮出来，回桌面也继续显示")
            }

            HStack(spacing: 6) {
                Image(systemName: "globe")
                    .font(.system(size: 11))
                Text("源语言自动识别 · 输出中文")
                    .font(.system(size: 11))
            }
            .foregroundStyle(Theme.faint)
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

    private func lineRow(_ line: AppState.SubtitleLine) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if app.prefs.mode != "source", !line.trans.isEmpty {
                Text(line.trans)
                    .font(.system(size: app.prefs.size, weight: .semibold))
                    .foregroundStyle(app.prefs.mode == "zh" ? Theme.ink : app.prefs.swiftUIColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if app.prefs.mode != "zh", !line.source.isEmpty {
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
            if app.prefs.mode != "source", !app.liveTrans.isEmpty {
                Text(app.liveTrans)
                    .font(.system(size: app.prefs.size, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if app.prefs.mode != "zh", !app.liveSource.isEmpty {
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
                if app.running {
                    withAnimation(.easeOut(duration: 0.2)) { app.stop() }
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
                // 输出音频：开 / 关
                Button {
                    haptic.impactOccurred()
                    withAnimation(.easeOut(duration: 0.18)) {
                        app.updatePrefs { $0.tts.toggle() }
                    }
                    if !app.prefs.tts { Speaker.shared.stop() }
                } label: {
                    tile(
                        icon: speaker.enabled ? "speaker.wave.2.fill" : "speaker.slash.fill",
                        title: "输出音频",
                        detail: speaker.enabled ? "已开启" : "已关闭",
                        on: speaker.enabled
                    )
                }
                .buttonStyle(TileButtonStyle())

                // 画中画：这里选比例，开关在「字幕样式」里
                Menu {
                    ForEach(SubtitlePrefs.pipOptions, id: \.0) { opt in
                        Button {
                            haptic.impactOccurred()
                            withAnimation(.easeOut(duration: 0.18)) {
                                app.updatePrefs { $0.pip = opt.0 }
                            }
                        } label: {
                            if app.prefs.pip == opt.0 {
                                Label(opt.0 == "4:3" ? "4:3 大窗" : "21:9 宽横条", systemImage: "checkmark")
                            } else {
                                Text(opt.0 == "4:3" ? "4:3 大窗" : "21:9 宽横条")
                            }
                        }
                    }
                } label: {
                    tile(
                        icon: app.prefs.pip == "21:9" ? "rectangle.wide" : "pip.fill",
                        title: "画中画",
                        detail: app.prefs.pip,
                        on: app.pipOn
                    )
                }
                .buttonStyle(TileButtonStyle())
            }
        }
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
