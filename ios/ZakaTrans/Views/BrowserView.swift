import SwiftUI
import WebKit
import Combine

/// 第四个页面：在 App 里直接逛网页，网页里点开视频就接过来用带字幕的播放器放。
struct BrowserView: View {
    @StateObject private var model = WebBrowserModel()

    @State private var input = ""
    @FocusState private var focused: Bool
    @State private var toast: String?

    private let quickLinks: [(String, String, String)] = [
        ("bilibili", "哔哩哔哩", "https://m.bilibili.com"),
        ("YouTube", "YouTube", "https://m.youtube.com"),
        ("TED", "TED", "https://www.ted.com/talks"),
        ("Vimeo", "Vimeo", "https://vimeo.com"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            addressBar
            ZStack(alignment: .top) {
                // 网页控件始终在层级里：一进 Tab 就能开始加载，
                // 起始页只是盖在它上面，不是把控件拿掉。
                WebContainer(webView: model.webView)
                    .background(Theme.bg)

                if model.address.isEmpty {
                    startPage.background(Theme.bg)
                }

                if model.loading && model.progress < 1 {
                    GeometryReader { g in
                        Rectangle()
                            .fill(Theme.accent)
                            .frame(width: max(2, g.size.width * model.progress), height: 2)
                    }
                    .frame(height: 2)
                }

                VStack {
                    Spacer()
                    if let d = model.detected {
                        detectBar(d)
                            .padding(.horizontal, 14)
                            .padding(.bottom, 14)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
            }
        }
        .background(Theme.bg)
        .sheet(item: $model.play) { req in
            VideoPlayerScreen(request: req)
        }
        .overlay(alignment: .bottom) {
            if let t = toast {
                Text(t)
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.black.opacity(0.8), in: Capsule())
                    .padding(.bottom, 90)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: model.detected?.url)
        .animation(.easeInOut(duration: 0.2), value: toast)
        .onReceive(model.$hint) { h in
            guard !h.isEmpty else { return }
            toast = h
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) {
                if toast == h { toast = nil }
            }
        }
        .onChange(of: model.address) { a in
            if !focused { input = a }
        }
        .onDisappear {
            // 切到别的页面就别让网页继续出声
            model.pauseWebMedia()
        }
    }

    // MARK: 地址栏

    private var addressBar: some View {
        HStack(spacing: 8) {
            Button { model.goBack() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(model.canBack ? Theme.ink : Theme.faint)
            }
            .disabled(!model.canBack)

            Button { model.goForward() } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(model.canForward ? Theme.ink : Theme.faint)
            }
            .disabled(!model.canForward)

            HStack(spacing: 6) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.faint)
                TextField("输入网址，或搜索关键词", text: $input)
                    .font(.system(size: 14))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .submitLabel(.go)
                    .focused($focused)
                    .onSubmit {
                        focused = false
                        model.submit(input)
                    }
                if !input.isEmpty && focused {
                    Button { input = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.faint)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Theme.fill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            if model.loading {
                Button { model.stopLoading() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Theme.sub)
                }
            } else {
                Button { model.reload() } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.sub)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Theme.bgElevated)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.line).frame(height: 0.5)
        }
    }

    // MARK: 起始页

    private var startPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("在 App 里看网页视频")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(Theme.ink)
                    Text("网页里点开视频，检测到之后会自动弹出播放条。用这里的播放器看，字幕会实时跟上，还能调字号和颜色。")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.sub)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 10)

                VStack(spacing: 10) {
                    ForEach(quickLinks, id: \.2) { item in
                        Button {
                            input = item.2
                            model.submit(item.2)
                        } label: {
                            HStack(spacing: 12) {
                                Text(item.0.prefix(1).uppercased())
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundStyle(Theme.accent)
                                    .frame(width: 34, height: 34)
                                    .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                                Text(item.1)
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(Theme.ink)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Theme.faint)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Label("怎么用", systemImage: "lightbulb")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.sub)
                    tipRow("1", "在上面输入网址，进到有视频的页面")
                    tipRow("2", "网页里点开视频，底部出现「检测到视频」")
                    tipRow("3", "点「用字幕播放」，视频进 App 播放器，字幕自动出")
                }
                .padding(.top, 4)

                VStack(alignment: .leading, spacing: 6) {
                    Label("有几种视频接不过来", systemImage: "info.circle")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.faint)
                    Text("需要登录且加密保护的流、以及把视频锁在播放器内部的站，取不到原始地址或音轨。遇到这种，回网页里直接看就行。")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.faint)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 6)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 30)
        }
    }

    private func tipRow(_ n: String, _ t: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(n)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 16, height: 16)
                .background(Theme.accent, in: Circle())
            Text(t)
                .font(.system(size: 12))
                .foregroundStyle(Theme.sub)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: 检测条

    private func detectBar(_ d: DetectedVideo) -> some View {
        HStack(spacing: 12) {
            Group {
                if let p = URL(string: d.poster), !d.poster.isEmpty {
                    AsyncImage(url: p) { img in
                        img.resizable().scaledToFill()
                    } placeholder: {
                        Color.black.opacity(0.4)
                    }
                } else {
                    ZStack {
                        Color.black.opacity(0.35)
                        Image(systemName: "play.rectangle")
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
            }
            .frame(width: 46, height: 34)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(d.label)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text("用字幕播放器打开 · 按实时翻译计积分")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
            }

            Spacer()

            Button {
                model.startPlaying()
            } label: {
                Text("播放")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Theme.accent, in: Capsule())
            }
        }
        .padding(10)
        .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
        )
    }
}

// MARK: - WKWebView 容器

private struct WebContainer: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView {
        webView.backgroundColor = .clear
        webView.isOpaque = false
        return webView
    }

    func updateUIView(_ ui: WKWebView, context: Context) {}
}
