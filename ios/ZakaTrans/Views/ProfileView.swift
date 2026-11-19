import SwiftUI

/// 「我的」：账号、积分、字幕设置、对话记录。
/// 所有数据都在云端，换手机登录同一个 Apple ID 就自动回来。
struct ProfileView: View {
    @ObservedObject private var cloud = Cloud.shared
    @ObservedObject private var app = AppState.shared
    @State private var showPurchase = false
    @State private var showLogout = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    accountCard
                    creditCard
                    menuGroup
                    aboutGroup
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 28)
            }
            .background(Theme.bg)
            .navigationTitle("我的")
            .navigationBarTitleDisplayMode(.large)
            .task { await cloud.refresh() }
        }
        .sheet(isPresented: $showPurchase) {
            NavigationStack { PurchaseView() }
        }
        .alert("退出登录？", isPresented: $showLogout) {
            Button("取消", role: .cancel) {}
            Button("退出", role: .destructive) { cloud.logout() }
        } message: {
            Text("退出后重新用 Apple ID 登录，额度、记录和设置都会回来。")
        }
    }

    // MARK: - 账号

    private var accountCard: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [Theme.accent, Theme.accent.opacity(0.7)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 56, height: 56)
                Text(cloud.profile?.initials ?? "Z")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(cloud.profile?.displayName ?? "Zaka 用户")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                HStack(spacing: 5) {
                    Image(systemName: "apple.logo")
                        .font(.system(size: 10))
                    Text(cloud.profile?.provider == "apple" ? "通过 Apple 登录" : "设备账号")
                        .font(.system(size: 12))
                }
                .foregroundStyle(Theme.sub)

                if let email = cloud.profile?.email, !email.isEmpty {
                    Text(email)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.faint)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .card(padding: 18)
    }

    // MARK: - 积分

    private var creditCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("积分余额")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.sub)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(Format.credits(cloud.balanceCredits))
                            .font(.system(size: 38, weight: .bold).monospacedDigit())
                            .foregroundStyle(Theme.ink)
                        Text("积分")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.sub)
                    }
                }
                Spacer()
                Button {
                    showPurchase = true
                } label: {
                    Text("充值")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .frame(height: 38)
                        .background(Theme.accent)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 0) {
                miniStat("今日消耗", "\(Format.credits(cloud.todayUsedCredits))")
                Rectangle().fill(Theme.line).frame(width: 0.5, height: 26)
                miniStat("可用时长", estimateHours)
            }
            .padding(.top, 2)

            Text("1 元 = 10 积分 · 1400 积分 = 100 万用量")
                .font(.system(size: 11))
                .foregroundStyle(Theme.faint)
        }
        .card(padding: 18)
    }

    /// 按每分钟约 1500 token 粗估还能用多久（只做参考，实际按上游真实用量）
    private var estimateHours: String {
        let minutes = cloud.balanceTokens / 1500
        if minutes < 60 { return "\(max(0, minutes)) 分钟" }
        return String(format: "%.1f 小时", Double(minutes) / 60.0)
    }

    private func miniStat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 11)).foregroundStyle(Theme.sub)
            Text(value).font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.ink)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 菜单

    private var menuGroup: some View {
        VStack(spacing: 0) {
            navRow(icon: "textformat.size", title: "字幕设置", tint: .blue,
                   detail: subtitleSummary) {
                SubtitleSettingsView()
            }
            divider
            navRow(icon: "clock.arrow.circlepath", title: "对话记录", tint: .orange,
                   detail: "每场都有") {
                HistoryView()
            }
            divider
            navRow(icon: "speaker.wave.2", title: "输出音频", tint: .purple,
                   detail: app.prefs.tts ? "已开启" : "已关闭", isToggle: true) {
                EmptyView()
            } action: {
                app.updatePrefs { $0.tts.toggle() }
                if !app.prefs.tts { Speaker.shared.stop() }
            }
        }
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
    }

    private var divider: some View {
        Rectangle().fill(Theme.line).frame(height: 0.5).padding(.leading, 56)
    }

    private var subtitleSummary: String {
        let mode = SubtitlePrefs.modeOptions.first { $0.0 == app.prefs.mode }?.1 ?? "双语"
        return "\(Int(app.prefs.size))pt · \(mode)"
    }

    @ViewBuilder
    private func navRow<Destination: View>(icon: String, title: String, tint: Color,
                                           detail: String, isToggle: Bool = false,
                                           @ViewBuilder destination: () -> Destination,
                                           action: (() -> Void)? = nil) -> some View {
        if let action {
            Button(action: action) {
                rowContent(icon: icon, title: title, tint: tint, detail: detail, isToggle: isToggle)
            }
            .buttonStyle(RowButtonStyle())
        } else {
            NavigationLink(destination: destination()) {
                rowContent(icon: icon, title: title, tint: tint, detail: detail, isToggle: false)
            }
            .buttonStyle(RowButtonStyle())
        }
    }

    private func rowContent(icon: String, title: String, tint: Color, detail: String, isToggle: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(tint)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            Text(title).font(.system(size: 16)).foregroundStyle(Theme.ink)
            Spacer()
            if isToggle {
                Text(detail).font(.system(size: 14)).foregroundStyle(Theme.sub)
            } else {
                Text(detail).font(.system(size: 14)).foregroundStyle(Theme.sub)
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
            HStack {
                Text("版本").font(.system(size: 15)).foregroundStyle(Theme.ink)
                Spacer()
                Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-")
                    .font(.system(size: 14).monospacedDigit())
                    .foregroundStyle(Theme.sub)
            }
            .padding(.horizontal, 16).frame(height: 48)
            divider
            HStack {
                Text("账号 ID").font(.system(size: 15)).foregroundStyle(Theme.ink)
                Spacer()
                Text(String(cloud.accountID.prefix(10)))
                    .font(.system(size: 12).monospaced())
                    .foregroundStyle(Theme.sub)
            }
            .padding(.horizontal, 16).frame(height: 48)
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
}
