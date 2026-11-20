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
                bottomSheet {
                    AudioOutputView(onClose: { closeAudio() })
                } onDismiss: { closeAudio() }
            }
        }
        .overlay(alignment: .bottom) {
            if showStyle {
                bottomSheet {
                    // 高度由内容自己定：内容矮就矮着弹，底部不留空白；内容高才滚
                    SubtitleSettingsView()
                } onDismiss: { closeStyle() }
            }
        }
        .onAppear { Haptics.warm() }
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
        withAnimation(.easeIn(duration: 0.18)) { showAudio = false }
    }

    private func closeStyle() {
        withAnimation(.easeIn(duration: 0.18)) { showStyle = false }
    }

    private func openAudio() {
        Haptics.tap()
        withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) {
            showStyle = false
            showAudio = true
        }
    }

    private func openStyle() {
        Haptics.tap()
        withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) {
            showAudio = false
            showStyle = true
        }
    }

    /// 自绘的半屏面板：从底部弹上来、点空白处关掉，右上角不放关闭按钮。
    /// 整块铺到屏幕物理底边：外层忽略安全区、面板背景直接到底，
    /// 只在内容最下面垫一条 Home 指示条的高度。以前是给面板加底部内边距、
    /// 指望背景自己越过安全区，结果那段经常没铺到，底下就露出一条空。
    @ViewBuilder
    private func bottomSheet<Content: View>(@ViewBuilder content: () -> Content,
                                            onDismiss: @escaping () -> Void) -> some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.28)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onDismiss() }
                .transition(.opacity)

            VStack(spacing: 0) {
                content()
                Color.clear.frame(height: SafeArea.bottom)
            }
            .frame(maxWidth: .infinity)
            .background(Theme.bg)
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 22, topTrailingRadius: 22, style: .continuous))
            .overlay(alignment: .top) {
                UnevenRoundedRectangle(topLeadingRadius: 22, topTrailingRadius: 22, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.6)
                    .allowsHitTesting(false)
            }
            .transition(.move(edge: .bottom))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .ignoresSafeArea()
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
                    openAudio()
                } content: {
                    Image(systemName: speaker.enabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                        .font(.system(size: 17, weight: .medium))
                }

                // 字幕样式：颜色、字号、背景、窗口大小都在里面（80% 面板，点空白关闭）
                iconButton(on: app.pipOn) {
                    openStyle()
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

/// 字幕样式按钮的图标：调色板 + 画笔，颜色一律走主题青绿。
/// 这一档管的是颜色、背景和窗口大小，用画笔和调色板比「Aa」更直接。
private struct SubtitleGlyph: View {
    var on: Bool

    private var tint: Color { Theme.accent }

    var body: some View {
        ZStack {
            // 调色板：圆盘 + 右侧一个拇指缺口，盘里四颗颜料点
            ZStack {
                Circle()
                    .fill(tint.opacity(on ? 0.18 : 0.12))
                Circle()
                    .stroke(tint, lineWidth: 1.6)
                HStack(spacing: 1.8) {
                    dot; dot; dot
                }
                .offset(y: -0.5)
                VStack(spacing: 1.8) {
                    Circle().fill(tint).frame(width: 2.0, height: 2.0)
                }
                .offset(y: 4.6)
                // 拇指缺口：盖一个跟按钮底色同色的圆，右侧咬掉一块
                Circle()
                    .fill(Theme.surface)
                    .frame(width: 6.4, height: 6.4)
                    .offset(x: 8.0, y: 1.5)
            }
            .compositingGroup()
            .frame(width: 17.5, height: 17.5)
            .offset(x: -3.0, y: -1.5)

            // 画笔：斜着从右上搭到左下，笔杆 + 笔头
            ZStack {
                Capsule()
                    .fill(tint)
                    .frame(width: 12.5, height: 2.8)
                    .offset(x: 0.6)
                Circle()
                    .fill(tint)
                    .frame(width: 3.2, height: 3.2)
                    .offset(x: -6.6)
            }
            .rotationEffect(.degrees(-42))
            .offset(x: 6.6, y: 6.8)
        }
        .frame(width: 26, height: 26)
    }

    private var dot: some View {
        Circle().fill(tint).frame(width: 2.2, height: 2.2)
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
