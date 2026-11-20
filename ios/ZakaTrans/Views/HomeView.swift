import SwiftUI
import UIKit

/// 实时翻译：一个按钮开始，字幕就在下面滚。
struct HomeView: View {
    @ObservedObject private var app = AppState.shared
    @ObservedObject private var cloud = Cloud.shared
    @ObservedObject private var speaker = Speaker.shared
    @State private var showCredit = false
    @State private var showAudio = false
    @State private var showStyle = false


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
        // 朗读设置：页面内自绘的半屏面板。
        // 以前用系统 sheet，点下去要等系统那套转场和分档高度初始化，实测有明显延迟；
        // 这里按下即出，动效压到 0.18 秒，观感就是「点了就开」。
        .overlay(alignment: .bottom) {
            if showAudio {
                ZStack(alignment: .bottom) {
                    Color.black.opacity(0.30)
                        .ignoresSafeArea()
                        .transition(.opacity)
                        .onTapGesture { closeAudio() }
                    AudioOutputView(onClose: { closeAudio() })
                        .frame(height: min(430, UIScreen.main.bounds.height * 0.62))
                        .background(Theme.bg)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .padding(.horizontal, 8)
                        .padding(.bottom, 8)
                        .transition(.move(edge: .bottom))
                }
            }
        }
        .animation(.easeOut(duration: 0.18), value: showAudio)
        .onAppear { Haptics.warm() }
        // 字幕样式按用户要求走整屏：色块多、字号预览大，半屏挤
        .fullScreenCover(isPresented: $showStyle) {
            SubtitleSettingsView()
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

    private func closeAudio() {
        withAnimation(.easeOut(duration: 0.16)) { showAudio = false }
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
        // 边框固定一根细线：运行中不再套绿框，界面只在按钮上表达状态
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 0.8)
        )
    }

    /// 没开始时的引导：三步，按实际的系统流程写
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("把任何声音变成中文字幕")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .padding(.top, 8)

            VStack(alignment: .leading, spacing: 16) {
                step(1, "点下面的「开始实时翻译」")
                step(2, "在系统面板中打开「语幕实时翻译」的直播录屏权限")
                step(3, "等待出现字幕浮窗后即可开始使用")
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

    // 对话记录是「记录」，不是字幕浮窗：固定用系统字号和系统文字颜色，
    // 不跟字幕样式走——否则把浮窗字号调到 30、颜色改成粉色，记录也跟着变，读起来很累。
    private func lineRow(_ line: AppState.SubtitleLine) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if !line.trans.isEmpty {
                Text(line.trans)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !line.source.isEmpty, line.source != line.trans {
                Text(line.source)
                    .font(.system(size: 15))
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
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !app.liveSource.isEmpty, app.liveSource != app.liveTrans {
                Text(app.liveSource)
                    .font(.system(size: 15))
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
                // 音频输出：点开是半屏设置，图标反映当前开关
                iconButton(on: speaker.enabled) {
                    Haptics.tap()
                    showAudio = true
                } content: {
                    Image(systemName: speaker.enabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                        .font(.system(size: 17, weight: .medium))
                }

                // 字幕样式：颜色、字号、背景、窗口大小都在里面（整屏展示）
                iconButton(on: app.pipOn) {
                    Haptics.tap()
                    showStyle = true
                } content: {
                    SubtitleGlyph(on: app.pipOn)
                }

                Button {
                    Haptics.tap(0.8)
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
                        Text(app.preparing ? "正在加载字幕浮窗" : (app.running ? "停止" : "开始实时翻译"))
                            .font(.system(size: 17, weight: .semibold))
                            .contentTransition(.opacity)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle(tint: (app.running && !app.preparing) ? Theme.warn : Theme.accent))
            }
        }
    }

    private func iconButton<Content: View>(on: Bool,
                                           action: @escaping () -> Void,
                                           @ViewBuilder content: () -> Content) -> some View {
        Button(action: action) {
            content()
                .foregroundStyle(on ? Theme.accent : Theme.sub)
                .frame(width: 54, height: 54)
                .background(on ? Theme.accentSoft : Theme.surface)
                .clipShape(Circle())
        }
        .buttonStyle(TileButtonStyle())
    }
}

/// 字幕样式按钮的图标：一条渐变气泡 + 两条字幕线。
/// 不用「字号大小」这种字形，避免用户以为点进去只能调字号。
private struct SubtitleGlyph: View {
    var on: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8.5, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: on
                            ? [Color(red: 0.34, green: 0.60, blue: 1.00), Color(red: 0.56, green: 0.38, blue: 0.98)]
                            : [Color(red: 0.62, green: 0.66, blue: 0.74), Color(red: 0.72, green: 0.68, blue: 0.82)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
            VStack(spacing: 3) {
                Capsule().fill(.white).frame(width: 13, height: 2.4)
                Capsule().fill(.white.opacity(0.62)).frame(width: 9, height: 2.2)
            }
            // 气泡尾巴
            Path { p in
                p.move(to: CGPoint(x: 4, y: 21))
                p.addLine(to: CGPoint(x: 9.5, y: 21))
                p.addLine(to: CGPoint(x: 4, y: 25))
                p.closeSubpath()
            }
            .fill(on ? Color(red: 0.56, green: 0.38, blue: 0.98) : Color(red: 0.72, green: 0.68, blue: 0.82))
        }
        .frame(width: 24, height: 26)
        .shadow(color: .black.opacity(0.10), radius: 2, y: 1)
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
