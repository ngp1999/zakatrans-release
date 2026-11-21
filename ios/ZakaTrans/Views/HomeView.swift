import SwiftUI
import UIKit

/// 实时翻译：一个按钮开始，字幕就在下面滚。
struct HomeView: View {
    @ObservedObject private var app = AppState.shared
    @ObservedObject private var cloud = Cloud.shared
    @ObservedObject private var speaker = Speaker.shared
    @State private var showCredit = false
    /// 当前弹出的面板（朗读设置 / 字幕样式），同一个时刻只会有一个
    @State private var panel: PanelKind?
    /// 面板是否已经滑到位置。整块面板用 offset 驱动，从屏幕底部整体滑上来，
    /// 不依赖 SwiftUI 的 transition（那个在 overlay 里有时候只有内容在动、面板底不跟着走）。
    @State private var panelUp = false
    /// 麦克风权限被拒时给的提示
    @State private var micDenied = false

    private enum PanelKind: String {
        case audio, style
    }


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
        }
        // 朗读设置：页面内自绘的半屏面板。
        // 以前用系统 sheet，点下去要等系统那套转场和分档高度初始化，实测有明显延迟；
        // 这里按下即出，动效压到 0.18 秒，观感就是「点了就开」。
        .overlay(alignment: .bottom) { panelLayer }
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

    // MARK: - 底部面板

    /// 面板整块由下往上滑：背景和面板一起动，滑到位置才可点。
    private var panelLayer: some View {
        Group {
            if let kind = panel {
                ZStack(alignment: .bottom) {
                    Color.black
                        .opacity(panelUp ? 0.28 : 0)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture { closePanel() }

                    VStack(spacing: 0) {
                        switch kind {
                        case .audio:
                            AudioOutputView(onClose: { closePanel() })
                        case .style:
                            SubtitleSettingsView()
                        }
                        Color.clear.frame(height: SafeArea.bottom)
                    }
                    .frame(maxWidth: .infinity)
                    .background(Theme.bg)
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: 22,
                                                      topTrailingRadius: 22,
                                                      style: .continuous))
                    .overlay(alignment: .top) {
                        UnevenRoundedRectangle(topLeadingRadius: 22,
                                               topTrailingRadius: 22,
                                               style: .continuous)
                            .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.6)
                            .allowsHitTesting(false)
                    }
                    .shadow(color: .black.opacity(0.16), radius: 22, y: -8)
                    .offset(y: panelUp ? 0 : UIScreen.main.bounds.height)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .ignoresSafeArea()
            }
        }
        // 阻尼压低一点：滑到位置之后会先过一点再弹回来，手感不再是"推上去就停住"。
        .animation(.spring(response: 0.44, dampingFraction: 0.60), value: panelUp)
    }

    private func openPanel(_ kind: PanelKind) {
        Haptics.tap()
        if panel == kind { return }
        if panel == nil {
            panel = kind
            panelUp = false
            // 先让它以「在屏幕外」的姿态完成一次布局，下一拍再滑上来——
            // 直接在同一次事务里设 true，第一帧就已经在位置上了，等于没有动画。
            DispatchQueue.main.async {
                panelUp = true
            }
        } else {
            withAnimation(.easeInOut(duration: 0.16)) { panel = kind }
        }
    }

    private func closePanel() {
        withAnimation(.easeIn(duration: 0.22)) { panelUp = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) {
            if !panelUp { panel = nil }
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
        // 边框固定一根细线：运行中不再套绿框，界面只在按钮上表达状态
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 0.8)
        )
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
                step(1, "点下面的「开始实时翻译」")
                if mic {
                    step(2, "第一次会问麦克风权限，点「允许」")
                    step(3, "直接说话，字幕跟着声音出来")
                } else {
                    step(2, "在系统面板中打开「语幕实时翻译」的直播录屏权限")
                    step(3, "等待出现字幕浮窗后即可开始使用")
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
                // 音频输出：点开是半屏设置，图标反映当前开关
                iconButton(on: speaker.enabled) {
                    openPanel(.audio)
                } content: {
                    Image(systemName: speaker.enabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                        .font(.system(size: 17, weight: .medium))
                }

                // 字幕样式：颜色、字号、背景、窗口大小都在里面（80% 面板，点空白关闭）
                iconButton(on: app.pipOn) {
                    openPanel(.style)
                } content: {
                    SubtitleGlyph(on: app.pipOn)
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

/// 字幕样式按钮的图标：调色板 + 画笔。
/// 形状照参考图来——一块压扁的椭圆盘、右下角一个拇指孔、盘上三颗颜料点，
/// 一支笔从右上斜插到左下、笔头压在盘面上。颜色统一走主题青绿，不跟参考图的彩色走。
private struct SubtitleGlyph: View {
    var on: Bool

    private var tint: Color { Theme.accent }

    var body: some View {
        ZStack {
            // 盘面：实心淡色 + 一圈细描边（浅色底上也不糊）
            PaletteShape()
                .fill(tint.opacity(on ? 0.26 : 0.18), style: FillStyle(eoFill: true))
            PaletteShape()
                .stroke(tint, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))

            // 三颗颜料点
            dot(3.0, 13.2)
            dot(7.6, 11.8)
            dot(6.4, 16.8)

            // 画笔：右上斜到左下，笔杆 + 笔头 + 笔尖
            BrushShape()
                .fill(tint)
                .rotationEffect(.degrees(-42))
                .offset(x: 2.6, y: -4.2)
        }
        .frame(width: 27, height: 27)
    }

    private func dot(_ x: CGFloat, _ y: CGFloat) -> some View {
        Circle()
            .fill(tint)
            .frame(width: 3.0, height: 3.0)
            .offset(x: x - 13.5, y: y - 13.5)
    }
}

/// 调色板外形：椭圆盘 + 右下角拇指孔（两个子路径配合 eoFill 挖空）
private struct PaletteShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let body = CGRect(x: r.minX + 1.4, y: r.minY + 8.4,
                          width: r.width - 7.6, height: r.height - 11.0)
        p.addEllipse(in: body)
        let hole = CGRect(x: body.maxX - 5.6, y: body.midY + 2.2, width: 4.4, height: 4.4)
        p.addEllipse(in: hole)
        return p
    }
}

/// 画笔：横着画好再整体转 -42°
private struct BrushShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let cx = r.midX
        let cy = r.midY
        // 笔杆
        p.addRoundedRect(in: CGRect(x: cx - 2.6, y: cy - 1.1, width: 10.4, height: 2.2),
                         cornerSize: CGSize(width: 1.1, height: 1.1))
        // 笔头（比笔杆粗一点）
        p.addRoundedRect(in: CGRect(x: cx - 6.2, y: cy - 1.7, width: 3.8, height: 3.4),
                         cornerSize: CGSize(width: 1.3, height: 1.3))
        // 笔尖
        p.move(to: CGPoint(x: cx - 6.2, y: cy - 1.7))
        p.addLine(to: CGPoint(x: cx - 9.2, y: cy))
        p.addLine(to: CGPoint(x: cx - 6.2, y: cy + 1.7))
        p.closeSubpath()
        return p
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
