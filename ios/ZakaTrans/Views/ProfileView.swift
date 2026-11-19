import SwiftUI

/// 「我的」：账号、积分、字幕样式、对话记录、协议。
/// 所有数据都在云端，换手机登录同一个 Apple ID 就自动回来。
struct ProfileView: View {
    @ObservedObject private var cloud = Cloud.shared
    @ObservedObject private var app = AppState.shared
    @State private var showLogout = false
    @State private var showAvatarPicker = false

    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        return b.isEmpty ? v : "\(v) (\(b))"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    accountCard
                    creditRow
                    menuGroup
                    aboutGroup
                    Text("版本 \(version)")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.faint)
                        .padding(.top, 6)
                        .padding(.bottom, 10)
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
            }
            .background(Theme.bg)
            .navigationTitle("我的")
            .navigationBarTitleDisplayMode(.large)
            .task { await cloud.refresh() }
            .sheet(isPresented: $showAvatarPicker) {
                AvatarPicker()
                    .presentationDetents([.height(300)])
                    .presentationDragIndicator(.visible)
            }
        }
        .alert("退出登录？", isPresented: $showLogout) {
            Button("取消", role: .cancel) {}
            Button("退出", role: .destructive) { cloud.logout() }
        } message: {
            Text("重新用 Apple ID 登录后，积分和记录都还在。")
        }
    }

    // MARK: - 账号

    private var accountCard: some View {
        HStack(spacing: 14) {
            Button {
                showAvatarPicker = true
            } label: {
                AvatarView(index: app.avatarIndex, size: 54)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "pencil.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(.white, Theme.accent)
                            .offset(x: 2, y: 2)
                    }
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 4) {
                Text(cloud.profile?.displayName ?? "语幕用户")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)

                if let email = cloud.profile?.email, !email.isEmpty {
                    Text(email)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.sub)
                        .lineLimit(1)
                }

                HStack(spacing: 5) {
                    Image(systemName: "apple.logo").font(.system(size: 10))
                    Text(cloud.profile?.provider == "apple" ? "通过 Apple 登录" : "设备账号")
                        .font(.system(size: 12))
                }
                .foregroundStyle(Theme.faint)
            }
            Spacer(minLength: 0)
        }
        .card(padding: 18)
    }

    // MARK: - 积分（一行，点进去看）

    private var creditRow: some View {
        NavigationLink {
            CreditView()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(Theme.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                Text("积分")
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.ink)
                Spacer()
                Text(Format.credits(cloud.balanceCredits))
                    .font(.system(size: 16, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.ink)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.faint)
            }
            .padding(.horizontal, 16)
            .frame(height: 54)
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        }
        .buttonStyle(RowButtonStyle())
    }

    // MARK: - 菜单

    private var menuGroup: some View {
        VStack(spacing: 0) {
            navRow(icon: "textformat.size", title: "字幕样式", tint: .blue) {
                SubtitleSettingsView()
            }
            divider
            navRow(icon: "clock.arrow.circlepath", title: "对话记录", tint: .orange) {
                HistoryView()
            }
            divider
            Button {
                withAnimation(.easeOut(duration: 0.18)) {
                    app.updatePrefs { $0.tts.toggle() }
                }
                if !app.prefs.tts { Speaker.shared.stop() }
            } label: {
                rowContent(icon: "speaker.wave.2", title: "输出音频",
                           tint: .purple, detail: app.prefs.tts ? "开" : "关", chevron: false)
            }
            .buttonStyle(RowButtonStyle())
            divider
            navRow(icon: "questionmark.circle", title: "使用帮助", tint: .gray) {
                HelpView()
            }
        }
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
    }

    private var divider: some View {
        Rectangle().fill(Theme.line).frame(height: 0.5).padding(.leading, 56)
    }

    @ViewBuilder
    private func navRow<Destination: View>(icon: String, title: String, tint: Color,
                                           @ViewBuilder destination: () -> Destination) -> some View {
        NavigationLink(destination: destination()) {
            rowContent(icon: icon, title: title, tint: tint, detail: "", chevron: true)
        }
        .buttonStyle(RowButtonStyle())
    }

    private func rowContent(icon: String, title: String, tint: Color, detail: String, chevron: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(tint)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            Text(title).font(.system(size: 16)).foregroundStyle(Theme.ink)
            Spacer()
            if !detail.isEmpty {
                Text(detail).font(.system(size: 14)).foregroundStyle(Theme.sub)
            }
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.faint)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
        .contentShape(Rectangle())
    }

    // MARK: - 关于

    private var aboutGroup: some View {
        VStack(spacing: 0) {
            NavigationLink { TermsView(kind: .terms) } label: { plainRow("用户协议") }
                .buttonStyle(RowButtonStyle())
            divider
            NavigationLink { TermsView(kind: .privacy) } label: { plainRow("隐私政策") }
                .buttonStyle(RowButtonStyle())
            divider
            Button { showLogout = true } label: {
                HStack {
                    Text("退出登录").font(.system(size: 15)).foregroundStyle(Theme.warn)
                    Spacer()
                }
                .padding(.horizontal, 16).frame(height: 48)
                .contentShape(Rectangle())
            }
            .buttonStyle(RowButtonStyle())
        }
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
    }

    private func plainRow(_ title: String) -> some View {
        HStack {
            Text(title).font(.system(size: 15)).foregroundStyle(Theme.ink)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.faint)
        }
        .padding(.horizontal, 16).frame(height: 48)
        .contentShape(Rectangle())
    }
}

// MARK: - 头像

/// 默认头像：苹果系统人像 + 四种底色（男女各两款），不自己画脸，也不放 AI 图。
struct AvatarView: View {
    let index: Int
    let size: CGFloat

    static let tints: [Color] = [
        Color(red: 0.55, green: 0.58, blue: 0.62),   // 石墨
        Color(red: 0.30, green: 0.52, blue: 0.86),   // 蓝
        Color(red: 0.20, green: 0.66, blue: 0.58),   // 青绿
        Color(red: 0.86, green: 0.48, blue: 0.56),   // 粉
    ]

    var body: some View {
        ZStack {
            Circle().fill(Self.tints[max(0, min(Self.tints.count - 1, index))])
            Image(systemName: "person.fill")
                .font(.system(size: size * 0.46, weight: .regular))
                .foregroundStyle(.white.opacity(0.95))
                .offset(y: size * 0.04)
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

struct AvatarPicker: View {
    @ObservedObject private var app = AppState.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 22) {
            Text("选择头像")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .padding(.top, 18)

            HStack(spacing: 18) {
                ForEach(0..<AvatarView.tints.count, id: \.self) { i in
                    Button {
                        app.avatarIndex = i
                        dismiss()
                    } label: {
                        AvatarView(index: i, size: 62)
                            .overlay(
                                Circle().strokeBorder(
                                    app.avatarIndex == i ? Theme.accent : Color.clear,
                                    lineWidth: 3
                                )
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            Text("头像只保存在本机，不同步到云端。")
                .font(.system(size: 12))
                .foregroundStyle(Theme.sub)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .background(Theme.bg)
    }
}

// MARK: - 使用帮助

struct HelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                section("怎么开始", [
                    "点首页的「开始实时翻译」。",
                    "系统弹出录屏面板，选「语幕」并点开始广播。",
                    "回到 App，字幕会自动浮出；退出 App 也能继续显示。",
                ])
                section("画中画", [
                    "在「字幕样式」里打开画中画开关，并选择比例（4:3 大窗 / 21:9 横条）。",
                    "首页的「画中画」按钮可以快速切换比例。",
                    "停止翻译时，画中画和屏幕广播会一起关掉。",
                ])
                section("字幕与朗读", [
                    "字号、文字颜色、背景颜色、双语/仅中文都在「字幕样式」里调。",
                    "打开「输出音频」后，翻译结果会用系统语音念出来，同时会压低其他 App 的音量。",
                ])
                section("积分", [
                    "按识别到的有效内容计费，静音不消耗。",
                    "1 元 = 10 积分，1 积分 ≈ 714 Token。",
                ])
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .background(Theme.bg)
        .navigationTitle("使用帮助")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func section(_ title: String, _ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.ink)
            ForEach(items, id: \.self) { t in
                HStack(alignment: .top, spacing: 8) {
                    Circle()
                        .fill(Theme.accent)
                        .frame(width: 4, height: 4)
                        .padding(.top, 7)
                    Text(t)
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.sub)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .card(padding: 16)
    }
}
