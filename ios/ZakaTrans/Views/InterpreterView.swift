import SwiftUI
import UIKit

/// 同声传译。
///
/// 这一页就是「实时字幕 · 麦克风收音」的复制品，只是单独占一个入口：
/// 点一下开始，麦克风直接收音，画中画浮窗同时出字幕，下面的记录实时往下长。
/// 差别只有两处：
///   1. 不用选语言——上游本来就能自动识别源语言并译成中文，选语言纯属多余；
///   2. 这一页固定走麦克风，跟首页「收音来源」那个设置分开，互不影响。
struct InterpreterView: View {
    @ObservedObject private var app = AppState.shared
    @ObservedObject private var cloud = Cloud.shared

    @State private var micDenied = false
    /// 进页面之前用户的收音/语言设置，退出这一页时原样还回去
    @State private var savedAudioSource: String?
    @State private var savedSourceLang: String?
    @State private var savedDestLang: String?
    /// 这一页现在在不在屏幕上（不在屏幕上但还在收音时，不要急着还原设置）
    @State private var pageVisible = false

    var body: some View {
        VStack(spacing: 0) {
            content
            controls
        }
        .background(DSColor.background)
        .navigationTitle("同声传译")
        .navigationBarTitleDisplayMode(.inline)
        .alert("需要麦克风权限", isPresented: $micDenied) {
            Button("去设置") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("同声传译需要用麦克风收音，请在系统设置里允许语幕访问麦克风。")
        }
        .onAppear {
            pageVisible = true
            enterPage()
        }
        .onDisappear {
            pageVisible = false
            leavePage()
        }
        // 离开页面后还在同传（画中画照常出字幕），等它真的停了再还原设置
        .onChange(of: app.running) { running in
            if !running && !pageVisible {
                app.setDuplex(false)
                restoreUserPrefs()
            }
        }
    }

    // MARK: - 内容区

    private var content: some View {
        Group {
            if app.preparing {
                preparingState
            } else {
                transcriptScroll
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var preparingState: some View {
        VStack(spacing: DSSpace.m) {
            ProgressView()
                .controlSize(.large)
            VStack(spacing: DSSpace.xxs) {
                Text("正在准备同声传译")
                    .font(DSFont.headline)
                    .foregroundStyle(DSColor.label)
                Text("请保持 App 在前台，不要退出或锁屏。")
                    .font(DSFont.subheadline)
                    .foregroundStyle(DSColor.secondaryLabel)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, DSSpace.l)
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

    /// 没开始时的一段说明：干什么、怎么说、字幕在哪看。
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: DSSpace.l) {
            VStack(alignment: .leading, spacing: DSSpace.xs) {
                Text("你说中文，译成英文；对方说外语，译成中文")
                    .font(DSFont.title3)
                    .foregroundStyle(DSColor.label)
                Text("原语言自动识别，哪个方向也自动。每行上面是译文，下面是原话。")
                    .font(DSFont.subheadline)
                    .foregroundStyle(DSColor.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, DSSpace.s)

            VStack(alignment: .leading, spacing: DSSpace.m) {
                step(1, "点下面的「开启同声传译」")
                step(2, "第一次会问麦克风权限，点「允许」")
                step(3, "直接说话：说中文就出英文，对方说英文就出中文")
                step(4, "字幕会同时出现在画中画浮窗里，可以拖到屏幕任意位置")
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

    // 记录用系统字号和系统文字色，不跟字幕浮窗的外观走（理由同首页）。
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
                Button {
                    Haptics.tap()
                    app.setPip(!app.pipOn)
                } label: {
                    Image(systemName: app.pipOn ? "pip.fill" : "pip")
                }
                .buttonStyle(DSIconButtonStyle(on: app.pipOn, size: 50))
                .accessibilityLabel("画中画字幕")

                Button {
                    Haptics.tap(0.8)
                    if app.running || app.preparing {
                        app.stop()
                    } else {
                        Task {
                            // 麦克风收音：先拿权限再开引擎（没权限直接碰输入节点会闪退）
                            guard await app.requestMicPermissionIfNeeded() else {
                                micDenied = true
                                return
                            }
                            await app.start()
                        }
                    }
                } label: {
                    HStack(spacing: DSSpace.xs) {
                        if app.preparing {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .tint(.white)
                        } else {
                            Image(systemName: (app.running && !app.preparing) ? "stop.fill" : "play.fill")
                                .font(.footnote.weight(.bold))
                        }
                        Text(app.preparing ? "正在加载" : (app.running ? "停止" : "开启同声传译"))
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

    // MARK: - 进/出这一页

    /// 进页面：这一页固定麦克风 + 自动识别源语言 + 译文中文 + 开画中画。
    /// 用户首页的设置先记下来，退出时还回去，免得他首页的收音来源被悄悄改掉。
    private func enterPage() {
        app.micOnly = true
        savedAudioSource = app.prefs.audioSource
        savedSourceLang = app.prefs.sourceLang
        savedDestLang = app.prefs.destLang

        // 先把语向按这一页定好（外语→中文），再开双向：两条会话的语向都在建立时固定，
        // 顺序反了第一路会沿用用户上一次的目标语言，外语那一路就译不到中文。
        var p = app.prefs
        p.audioSource = "mic"
        p.sourceLang = "auto"
        p.destLang = "zh"
        if p != app.prefs {
            app.updatePrefs { q in
                q.audioSource = "mic"
                q.sourceLang = "auto"
                q.destLang = "zh"
            }
        } else {
            app.applyPrefsToEngine()
        }
        // 双向：外语→中文、中文→英文，两条会话同时跑
        app.setDuplex(true)
        if !app.pipOn { app.setPip(true) }
        _ = cloud
    }

    /// 退出这一页。
    /// 还在收音就不停：切到别的页面（或退回首页看一眼）时同传不该断，
    /// 画中画浮窗会继续出字幕；等用户自己点了停止，再把他的设置还回去。
    private func leavePage() {
        guard !app.running else { return }
        app.micOnly = false
        app.setDuplex(false)
        restoreUserPrefs()
    }

    private func restoreUserPrefs() {
        defer {
            savedAudioSource = nil
            savedSourceLang = nil
            savedDestLang = nil
        }
        app.setDuplex(false)
        guard let a = savedAudioSource, let s = savedSourceLang else { return }
        let d = savedDestLang ?? app.prefs.destLang
        guard app.prefs.audioSource != a || app.prefs.sourceLang != s
                || app.prefs.destLang != d else { return }
        app.updatePrefs { q in
            q.audioSource = a
            q.sourceLang = s
            q.destLang = d
        }
    }
}
