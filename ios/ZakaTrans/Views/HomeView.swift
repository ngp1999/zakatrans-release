import SwiftUI

struct HomeView: View {
    @ObservedObject private var app = AppState.shared
    @ObservedObject private var cloud = Cloud.shared
    @State private var showBuy = false

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                    .padding(.horizontal, 22)
                    .padding(.top, 8)

                subtitlePanel
                    .padding(.horizontal, 16)
                    .padding(.top, 18)

                Spacer(minLength: 12)
                controls
                    .padding(.horizontal, 22)
                    .padding(.bottom, 10)
            }

            // 隐藏的宿主：画中画和录屏面板都需要真实 UIView
            ZStack {
                PipAnchor().frame(width: 1, height: 1)
                BroadcastPicker().frame(width: 1, height: 1)
            }
            .opacity(0.01)
            .allowsHitTesting(false)
        }
        .alert(item: Binding(
            get: { app.alert.map { AlertText(text: $0) } },
            set: { if $0 == nil { app.alert = nil } }
        )) { item in
            Alert(title: Text("提示"), message: Text(item.text), dismissButton: .default(Text("知道了")))
        }
        .sheet(isPresented: $showBuy) {
            NavigationStack { WalletView() }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Zaka 翻译")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(Theme.ink)
                Text("录屏即可，字幕浮在画中画里")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.sub)
            }
            Spacer()
            Button {
                showBuy = true
            } label: {
                VStack(alignment: .trailing, spacing: 3) {
                    Text(Purchases.format(cloud.balance))
                        .font(.system(size: 17, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Theme.ink)
                    Text("token")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.sub)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Theme.card)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(Theme.line, lineWidth: 0.8))
            }
            .buttonStyle(.plain)
        }
    }

    private var subtitlePanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Circle()
                    .fill(app.running ? Theme.accent : Color(white: 0.78))
                    .frame(width: 7, height: 7)
                Text(app.status)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.sub)
                Spacer()
                if !app.lines.isEmpty {
                    Button {
                        ZKStore.clearLines()
                        app.lines.removeAll()
                    } label: {
                        Text("清空")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.sub)
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 10)

            Divider().overlay(Theme.line)

            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if app.lines.isEmpty && app.liveSource.isEmpty {
                            placeholder
                        }
                        ForEach(app.lines) { line in
                            lineRow(line)
                                .id(line.id)
                        }
                        if !app.liveSource.isEmpty || !app.liveTrans.isEmpty {
                            liveRow.id("live")
                        }
                    }
                    .padding(18)
                }
                .onChange(of: app.lines.count) { _ in
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo("live", anchor: .bottom)
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Theme.line, lineWidth: 0.5)
        )
    }

    private var placeholder: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("还没有字幕")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Theme.ink)
            Text("点下面的按钮，选择「Zaka 录屏」开始。\n系统会把正在播放的声音交给我，逐句出原文和译文。")
                .font(.system(size: 14))
                .foregroundStyle(Theme.sub)
                .lineSpacing(4)
        }
        .padding(.top, 8)
    }

    private func lineRow(_ line: AppState.SubtitleLine) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !line.trans.isEmpty {
                Text(line.trans)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !line.source.isEmpty {
                Text(line.source)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.sub)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var liveRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !app.liveTrans.isEmpty {
                Text(app.liveTrans)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !app.liveSource.isEmpty {
                Text(app.liveSource)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.sub)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

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
                Text(app.running ? "停止" : "开始实时字幕")
            }
            .buttonStyle(PrimaryButtonStyle())

            Text("按模型接口返回的有效 Token 数量扣费，不按时长计费")
                .font(.system(size: 11))
                .foregroundStyle(Theme.sub)
                .multilineTextAlignment(.center)
        }
    }
}

struct AlertText: Identifiable {
    let id = UUID()
    let text: String
}
