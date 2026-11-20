import SwiftUI
import UIKit

/// 字幕翻译：一个按钮开始，字幕就在下面滚。
struct HomeView: View {
    @ObservedObject private var app = AppState.shared
    @ObservedObject private var cloud = Cloud.shared
    @ObservedObject private var speaker = Speaker.shared
    @State private var showCredit = false
    @State private var showAudio = false

    private let haptic = UIImpactFeedbackGenerator(style: .light)

    var body: some View {
        VStack(spacing: 0) {
            subtitlePanel
                .padding(.horizontal, 20)
                .padding(.top, 6)

            controls
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 8)
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

    // MARK: - 字幕

    private var subtitlePanel: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if app.lines.isEmpty && app.liveSource.isEmpty && app.liveTrans.isEmpty {
                        emptyState
                    }
                    ForEach(app.lines) { line in
                        lineRow(line).id(line.id)
                    }
                    if !app.liveSource.isEmpty || !app.liveTrans.isEmpty {
                        liveRow.id("live")
                    }
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
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(app.running ? Theme.accent.opacity(0.35) : Theme.hairline, lineWidth: 0.8)
        )
    }

    /// 没开始时的引导：只留三步，别的说明文字全去掉
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("把任何声音变成中文字幕")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .padding(.top, 8)

            VStack(alignment: .leading, spacing: 16) {
                step(1, "点下面的「开始字幕翻译」")
                step(2, "在系统面板里选「语幕」并开始录屏")
                step(3, "字幕浮窗自动出现，回桌面也继续显示")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 14)
        .padding(.horizontal, 2)
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(n)")
                .font(.system(size: 13, weight: .bold).monospacedDigit())
                .foregroundStyle(Theme.accent)
                .frame(width: 24, height: 24)
                .background(Theme.accentSoft)
                .clipShape(Circle())
            Text(text)
                .font(.system(size: 15))
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
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
                    .font(.system(size: max(14, app.prefs.size - 5)))
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
                    .font(.system(size: max(14, app.prefs.size - 5)))
                    .foregroundStyle(Theme.sub)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 控制

    private var controls: some View {
        VStack(spacing: 8) {
            if app.running && !app.preparing && !app.audioHint.isEmpty {
                Text(app.audioHint)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.warn)
                    .frame(maxWidth: .infinity, alignment: .center)
            }

            HStack(spacing: 10) {
                iconButton(
                    icon: speaker.enabled ? "speaker.wave.2.fill" : "speaker.slash.fill",
                    on: speaker.enabled
                ) {
                    haptic.impactOccurred()
                    showAudio = true
                }

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
                                Label("窗口\(opt.1)", systemImage: "checkmark")
                            } else {
                                Text("窗口\(opt.1)")
                            }
                        }
                    }
                    Divider()
                    Button {
                        haptic.impactOccurred()
                        app.setPip(!app.pipOn)
                    } label: {
                        Label(app.pipOn ? "关闭窗口" : "打开窗口",
                              systemImage: app.pipOn ? "pip.remove" : "pip.fill")
                    }
                } label: {
                    Image(systemName: app.pipOn ? (app.prefs.pip == "S" ? "rectangle.wide" : "pip.fill") : "pip.remove")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(app.pipOn ? Theme.accent : Theme.sub)
                        .frame(width: 54, height: 54)
                        .background(app.pipOn ? Theme.accentSoft : Theme.surface)
                        .clipShape(Circle())
                }
                .buttonStyle(TileButtonStyle())

                Button {
                    haptic.impactOccurred(intensity: 0.8)
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
                        Text(app.preparing ? "正在加载" : (app.running ? "停止" : "开始字幕翻译"))
                            .font(.system(size: 17, weight: .semibold))
                            .contentTransition(.opacity)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle(tint: (app.running && !app.preparing) ? Theme.warn : Theme.accent))
                .overlay(PreparingGlow(on: app.preparing).allowsHitTesting(false))
            }
        }
    }

    private func iconButton(icon: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(on ? Theme.accent : Theme.sub)
                .frame(width: 54, height: 54)
                .background(on ? Theme.accentSoft : Theme.surface)
                .clipShape(Circle())
        }
        .buttonStyle(TileButtonStyle())
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
