import SwiftUI
import UIKit

/// 实时字幕：一个按钮开启，字幕就在下面滚。
///
/// 这一版按 iOS 原生的工作页来做：
///   · 字幕区就是页面内容本身，不套卡片、不加边框、不加投影
///   · 底部控制区一条系统背景 + 一条 0.5pt 分隔线，按钮是系统观感的填充按钮
///   · 文案层级靠字号和次级色区分，不靠颜色和装饰
struct HomeView: View {
    @ObservedObject private var app = AppState.shared
    @ObservedObject private var cloud = Cloud.shared
    @State private var showCredit = false
    /// 字幕样式：走系统 sheet
    @State private var showStyle = false
    /// 麦克风权限被拒时给的提示
    @State private var micDenied = false

    var body: some View {
        VStack(spacing: 0) {
            subtitleArea
            Divider()
            controls
        }
        .background(DSColor.background)
        .sheet(isPresented: $showCredit) {
            NavigationStack { CreditView() }
        }
        .sheet(isPresented: $showStyle) {
            NavigationStack {
                SubtitleSettingsView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("完成") { showStyle = false }
                        }
                    }
            }
        }
        .onAppear { Haptics.warm() }
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

    // MARK: - 字幕区

    private var subtitleArea: some View {
        Group {
            if app.preparing {
                preparingState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                transcriptScroll
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var transcriptScroll: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: DSSpace.l) {
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
                .padding(.horizontal, DSSpace.l)
                .padding(.vertical, DSSpace.l)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .onChange(of: app.lines.count) { _ in
                withAnimation(DSMotion.quick) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: app.liveTrans) { _ in
                withAnimation(DSMotion.quick) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: app.liveSource) { _ in
                withAnimation(DSMotion.quick) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    /// 开启时的准备态：转圈放在正文中央（按钮上原来那个太不显眼），
    /// 顺带一句必须留在前台，避免用户点了就去锁屏、回来发现没有字幕。
    private var preparingState: some View {
        VStack(spacing: DSSpace.m) {
            ProgressView()
                .controlSize(.large)
            VStack(spacing: DSSpace.xxs) {
                Text("正在准备实时字幕")
                    .font(DSFont.headline)
                    .foregroundStyle(DSColor.label)
                Text("请保持 App 在前台，不要退出或锁屏，字幕会显示在下方。")
                    .font(DSFont.subheadline)
                    .foregroundStyle(DSColor.secondaryLabel)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, DSSpace.l)
    }

    /// 没开始时的引导：系统设置页那种竖排说明，不用卡片包起来
    private var emptyState: some View {
        let mic = app.prefs.audioSource == "mic"
        return VStack(alignment: .leading, spacing: DSSpace.l) {
            VStack(alignment: .leading, spacing: DSSpace.xs) {
                Text(mic ? "把现场说话变成中文字幕" : "把任何声音变成中文字幕")
                    .font(DSFont.title3)
                    .foregroundStyle(DSColor.label)
                Text("点下面的按钮开始，字幕会实时出现在这里。")
                    .font(DSFont.subheadline)
                    .foregroundStyle(DSColor.secondaryLabel)
            }
            .padding(.top, DSSpace.s)

            VStack(alignment: .leading, spacing: DSSpace.m) {
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
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: DSSpace.s) {
            Text("\(n)")
                .font(DSFont.footnote.weight(.semibold).monospacedDigit())
                .foregroundStyle(DSColor.secondaryLabel)
                .frame(width: 20, height: 20)
                .background(DSColor.fill, in: Circle())
            Text(text)
                .font(DSFont.subheadline)
                .foregroundStyle(DSColor.label)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // 对话记录是「记录」，不是字幕浮窗：固定用系统字号和系统文字颜色，
    // 不跟字幕样式走——否则把浮窗字号调到 30、颜色改成粉色，记录也跟着变，读起来很累。
    private func lineRow(_ line: AppState.SubtitleLine) -> some View {
        VStack(alignment: .leading, spacing: DSSpace.xxs) {
            if !line.trans.isEmpty {
                Text(line.trans)
                    .font(DSFont.body)
                    .foregroundStyle(DSColor.label)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !line.source.isEmpty, line.source != line.trans {
                Text(line.source)
                    .font(DSFont.subheadline)
                    .foregroundStyle(DSColor.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var liveRow: some View {
        VStack(alignment: .leading, spacing: DSSpace.xxs) {
            if !app.liveTrans.isEmpty {
                Text(app.liveTrans)
                    .font(DSFont.body)
                    .foregroundStyle(DSColor.label)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !app.liveSource.isEmpty, app.liveSource != app.liveTrans {
                Text(app.liveSource)
                    .font(DSFont.subheadline)
                    .foregroundStyle(DSColor.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 控制区

    private var controls: some View {
        VStack(spacing: DSSpace.xs) {
            if app.running && !app.preparing && !app.audioHint.isEmpty {
                Text(app.audioHint)
                    .font(DSFont.footnote)
                    .foregroundStyle(DSColor.destructive)
                    .frame(maxWidth: .infinity, alignment: .center)
            }

            HStack(spacing: DSSpace.s) {
                // 字幕样式：颜色、字号、背景、窗口大小都在里面，系统 sheet 呈现
                Button {
                    showStyle = true
                } label: {
                    Image(systemName: app.pipOn ? "pip.fill" : "pip")
                }
                .buttonStyle(DSIconButtonStyle(on: app.pipOn, size: 50))
                .accessibilityLabel("字幕样式")

                Button {
                    Haptics.tap(0.8)
                    if app.running || app.preparing {
                        app.stop()
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
                    HStack(spacing: DSSpace.xs) {
                        // 转圈挪到正文中央去了，按钮上只留图标和字，避免同一屏两个转圈
                        Image(systemName: (app.running && !app.preparing) ? "stop.fill" : "play.fill")
                            .font(.footnote.weight(.bold))
                        Text(app.preparing ? "准备中" : (app.running ? "停止" : "开启实时字幕"))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                }
                .buttonStyle(DSFilledButtonStyle(
                    tint: (app.running && !app.preparing) ? DSColor.destructive : DSColor.accentFill
                ))
            }
        }
        .padding(.horizontal, DSSpace.pageMargin)
        .padding(.top, DSSpace.s)
        .padding(.bottom, DSSpace.xs)
        .background(DSColor.background)
    }
}

/// 小按钮的按压反馈（兼容老调用）：只有亮度变化，不缩放、不回弹。
struct TileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.6 : 1)
            .animation(nil, value: configuration.isPressed)
    }
}

struct AlertText: Identifiable {
    let id = UUID()
    let text: String
}
