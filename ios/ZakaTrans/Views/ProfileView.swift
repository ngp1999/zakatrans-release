import SwiftUI

/// 「我的」：账号、积分、字幕设置、对话记录、协议。
/// 所有数据都在云端，换手机登录同一个 Apple ID 就自动回来。
struct ProfileView: View {
    @ObservedObject private var cloud = Cloud.shared
    @ObservedObject private var app = AppState.shared
    @State private var showLogout = false

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
        }
        .alert("退出登录？", isPresented: $showLogout) {
            Button("取消", role: .cancel) {}
            Button("退出", role: .destructive) { cloud.logout() }
        } message: {
            Text("重新用 Apple ID 登录后，额度和记录都还在。")
        }
    }

    // MARK: - 账号

    private var accountCard: some View {
        HStack(spacing: 14) {
            // 系统默认人像：不自己拼头像，也不用首字母色块
            Image(systemName: "person.crop.circle.fill")
                .resizable()
                .scaledToFit()
                .frame(width: 54, height: 54)
                .foregroundStyle(Color(uiColor: .systemGray3))

            VStack(alignment: .leading, spacing: 4) {
                Text(cloud.profile?.displayName ?? "语幕用户")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                HStack(spacing: 5) {
                    Image(systemName: "apple.logo").font(.system(size: 10))
                    Text(cloud.profile?.provider == "apple" ? "通过 Apple 登录" : "设备账号")
                        .font(.system(size: 12))
                }
                .foregroundStyle(Theme.sub)
            }
            Spacer(minLength: 0)
        }
        .card(padding: 18)
    }

    // MARK: - 积分（一行，点进去看明细）

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
            navRow(icon: "textformat.size", title: "字幕设置", tint: .blue, detail: subtitleSummary) {
                SubtitleSettingsView()
            }
            divider
            navRow(icon: "clock.arrow.circlepath", title: "对话记录", tint: .orange, detail: "") {
                HistoryView()
            }
            divider
            Button {
                app.updatePrefs { $0.tts.toggle() }
                if !app.prefs.tts { Speaker.shared.stop() }
            } label: {
                rowContent(icon: "speaker.wave.2", title: "输出音频", tint: .purple,
                           detail: app.prefs.tts ? "已开启" : "已关闭", chevron: false)
            }
            .buttonStyle(RowButtonStyle())
        }
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
    }

    private var divider: some View {
        Rectangle().fill(Theme.line).frame(height: 0.5).padding(.leading, 56)
    }

    private var subtitleSummary: String {
        let mode = SubtitlePrefs.modeOptions.first { $0.0 == app.prefs.mode }?.1 ?? "双语"
        return "\(Int(app.prefs.size)) · \(mode)"
    }

    @ViewBuilder
    private func navRow<Destination: View>(icon: String, title: String, tint: Color, detail: String,
                                           @ViewBuilder destination: () -> Destination) -> some View {
        NavigationLink(destination: destination()) {
            rowContent(icon: icon, title: title, tint: tint, detail: detail, chevron: true)
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
            NavigationLink { TermsView(kind: .terms) } label: {
                plainRow("用户协议")
            }
            .buttonStyle(RowButtonStyle())
            divider
            NavigationLink { TermsView(kind: .privacy) } label: {
                plainRow("隐私政策")
            }
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
