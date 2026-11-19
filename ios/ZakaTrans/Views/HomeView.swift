import SwiftUI

/// 首页：一个按钮开始，字幕就在下面滚。
struct HomeView: View {
    @ObservedObject private var app = AppState.shared
    @ObservedObject private var cloud = Cloud.shared
    @ObservedObject private var speaker = Speaker.shared
    @State private var showCredit = false

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

            // 画中画和系统录屏面板都要求真实 UIView 挂在窗口上
            ZStack {
                PipAnchor().frame(width: 1, height: 1)
                BroadcastPicker().frame(width: 60, height: 60)
            }
            .opacity(0.01)
            .allowsHitTesting(false)
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
        HStack(alignment: .center) {
            HStack(spacing: 7) {
                Circle()
                    .fill(app.running ? Theme.accent : Theme.faint.opacity(0.55))
                    .frame(width: 7, height: 7)
                Text("实时字幕翻译")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Theme.ink)
            }
            Spacer(minLength: 12)
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(app.running ? Theme.accent.opacity(0.3) : Color.clear, lineWidth: 1)
        )
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "captions.bubble")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Theme.faint)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 90)
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
                    on: speaker.enabled
                ) {
                    app.updatePrefs { $0.tts.toggle() }
                    if !app.prefs.tts { Speaker.shared.stop() }
                }

                actionTile(
                    icon: app.pipOn ? "pip.fill" : "pip.exit",
                    title: "画中画",
                    on: app.pipOn
                ) {
                    app.togglePip()
                }
            }
        }
    }

    private func actionTile(icon: String, title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(on ? Theme.accent : Theme.sub)
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.ink)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .frame(height: 50)
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
