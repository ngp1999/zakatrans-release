import SwiftUI
import UIKit

/// 实时字幕：一个按钮开启，字幕就在下面滚。
struct HomeView: View {
    @ObservedObject private var app = AppState.shared
    @ObservedObject private var cloud = Cloud.shared
    @State private var showCredit = false
    /// 字幕样式：走系统 sheet，带上分档高度和下拉关闭，手势是系统那套
    @State private var showStyle = false
    /// 麦克风权限被拒时给的提示
    @State private var micDenied = false


    var body: some View {
        VStack(spacing: 0) {
            subtitlePanel
                .padding(.horizontal, 20)
                .padding(.top, 6)
                // 单独挂在这个视图上：和下面那个「积分不足」各自独立，不会互相抢
                .alert("需要麦克风权限", isPresented: $micDenied) {
                    Button("去设置") {
                        if let u = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(u)
                        }
                    }
                    Button("取消", role: .cancel) {}
                } message: {
                    Text("麦克风收音需要录音权限。到「设置 → 语幕翻译」打开麦克风后再试一次。")
                }

            controls
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 8)
        }
        .sheet(isPresented: $showCredit) {
            NavigationStack { CreditView() }
                .sheetChrome(radius: 30)
        }
        .sheet(isPresented: $showStyle) {
            panel(SubtitleSettingsView())
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

    /// 面板底色：原先铺的是一块纯色，面板本身看着像一张白纸。
    /// 现在铺系统材质，面板浮在 App 上面时能透出底下的内容，跟系统 sheet 是一类观感。
    @ViewBuilder
    private func panel<V: View>(_ content: V) -> some View {
        if #available(iOS 16.4, *) {
            content
                .presentationBackground(.regularMaterial)
                .presentationCornerRadius(30)
        } else {
            content
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
        // 一块浮起来的玻璃：材质 + 顶亮底暗的细边，运行中不开绿框，状态只由按钮表达
        .glassSurface(radius: 26, material: .ultraThinMaterial)
    }

    /// 没开始时的引导：三步，按实际的系统流程写
    private var emptyState: some View {
        let mic = app.prefs.audioSource == "mic"
        return VStack(alignment: .leading, spacing: 20) {
            Text(mic ? "把现场说话变成中文字幕" : "把任何声音变成中文字幕")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .padding(.top, 8)

            VStack(alignment: .leading, spacing: 16) {
                step(1, "点下面的「开启实时字幕」")
                if mic {
                    step(2, "第一次会问麦克风权限，点「允许」")
                    step(3, "直接说话，字幕跟着声音出来")
                } else {
                    step(2, "在系统面板中打开「语幕」的直播录屏权限")
                    step(3, "等待出现字幕浮窗后即可使用")
                }
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
                // 字幕样式：颜色、字号、背景、窗口大小都在里面，系统 sheet 呈现
                // 图标用系统自带的画中画（矢量，跟系统其他图标是一套），
                // 不再自己画调色板——自制图标缩到 17pt 细节全糊，也不像系统图标。
                iconButton(on: app.pipOn) {
                    showStyle = true
                } content: {
                    Image(systemName: app.pipOn ? "pip.fill" : "pip")
                        .font(.system(size: 17, weight: .medium))
                }

                Button {
                    Haptics.tap(0.8)
                    if app.running || app.preparing {
                        withAnimation(.easeOut(duration: 0.2)) { app.stop() }
                    } else if !app.preparing {
                        Task {
                            // 麦克风收音：先把权限拿到，再开引擎（没权限直接碰输入节点会闪退）
                            guard await app.requestMicPermissionIfNeeded() else {
                                micDenied = true
                                return
                            }
                            await app.start()
                            // 麦克风收音不需要屏幕广播权限：只有内部收音（系统声音）才去叫系统面板
                            if app.running, app.prefs.audioSource != "mic" { BroadcastTrigger.shared.fire() }
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
                        Text(app.preparing ? "正在加载字幕浮窗" : (app.running ? "停止" : "开启实时字幕"))
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
                .background {
                    Circle()
                        .fill(on ? AnyShapeStyle(Theme.accent.opacity(0.14))
                                  : AnyShapeStyle(Material.ultraThinMaterial))
                }
                .overlay(
                    Circle().strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(0.55), Color.white.opacity(0.08)],
                            startPoint: .top, endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
                )
                .shadow(color: Color.black.opacity(0.07), radius: 14, x: 0, y: 6)
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
