import SwiftUI
import PhotosUI
import UIKit

/// 「我的」：账号、积分、对话记录、关于。
/// 翻译相关的设置都在首页按钮里，这一页只管和"我"有关的东西。
struct ProfileView: View {
    @ObservedObject private var cloud = Cloud.shared
    @ObservedObject private var app = AppState.shared
    @State private var showLogout = false
    @State private var showEdit = false
    @State private var showDelete = false
    @State private var deleting = false
    @State private var deleteError = ""

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                accountCard
                creditRow
                mainGroup
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 24)
        }
        .background(Theme.bg)
        .navigationTitle("我的")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("完成") { dismiss() }
                    .fontWeight(.semibold)
                    .foregroundStyle(Theme.accent)
            }
        }
        .task { await cloud.refresh() }
        .sheet(isPresented: $showEdit) {
            NavigationStack { AccountEditView() }
        }
        .alert("确认退出登录？", isPresented: $showLogout) {
            Button("取消", role: .cancel) {}
            Button("退出登录", role: .destructive) { cloud.logout() }
        } message: {
            Text("退出登录不会丢失任何数据，你仍可以登录此账号。")
        }
        .alert("确认删除账号？", isPresented: $showDelete) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) { deleteAccount() }
        } message: {
            Text("账号、余额、购买记录和对记录会一并删除，无法恢复。")
        }
        .alert("删除失败", isPresented: Binding(
            get: { !deleteError.isEmpty },
            set: { if !$0 { deleteError = "" } }
        )) {
            Button("好", role: .cancel) { deleteError = "" }
        } message: {
            Text(deleteError)
        }
    }

    private func deleteAccount() {
        guard !deleting else { return }
        deleting = true
        Task {
            let ok = await cloud.deleteAccount()
            deleting = false
            if !ok { deleteError = cloud.lastError ?? "删除失败，请稍后重试" }
        }
    }

    // MARK: - 账号

    private var accountCard: some View {
        // 整张卡就是入口：点头像或昵称都进同一个修改面板，头像上不再挂相机角标
        Button {
            showEdit = true
        } label: {
            HStack(spacing: 14) {
                AvatarView(size: 58)

                VStack(alignment: .leading, spacing: 4) {
                    Text(cloud.profile?.displayName ?? "语幕用户")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)

                    if let email = cloud.profile?.email, !email.isEmpty {
                        Text(email)
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.sub)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.faint)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .card(padding: 18)
        .contextMenu {
            Button("使用默认头像", role: .destructive) { app.setAvatar(nil) }
        }
    }

    // MARK: - 积分

    private var creditRow: some View {
        NavigationLink {
            CreditView()
        } label: {
            HStack(spacing: 10) {
                // 积分图标：星形套圆环，上白下主题色——跟积分页那个是同一颗
                Image(systemName: "star.circle.fill")
                    .font(.system(size: 26))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Theme.accent)
                    .frame(width: 28, height: 28)
                Text("我的积分")
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

    // MARK: - 对话记录 / 关于 / 退出

    private var mainGroup: some View {
        VStack(spacing: 0) {
            NavigationLink {
                HistoryView()
            } label: {
                rowContent(icon: "clock.arrow.circlepath", title: "对话记录",
                           tint: .orange, detail: "", chevron: true)
            }
            .buttonStyle(RowButtonStyle())

            divider

            NavigationLink {
                AboutView()
            } label: {
                rowContent(icon: "info.circle.fill", title: "关于语幕",
                           tint: .gray, detail: "", chevron: true)
            }
            .buttonStyle(RowButtonStyle())

            divider

            Button { showLogout = true } label: {
                HStack(spacing: 12) {
                    // 跟上面两行一样的图标方块，只是换成红色系，位置对齐
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(Theme.warn)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    Text("退出登录").font(.system(size: 16)).foregroundStyle(Theme.warn)
                    Spacer()
                }
                .padding(.horizontal, 16).frame(height: 52)
                .contentShape(Rectangle())
            }
            .buttonStyle(RowButtonStyle())

            divider

            // 5.1.1(v)：App 内必须能自助删除账号，不能只写「联系我们」
            Button { showDelete = true } label: {
                rowContent(icon: "trash.fill", title: "删除账号", tint: Theme.warn,
                           detail: "", chevron: false)
            }
            .buttonStyle(RowButtonStyle())
        }
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
    }

    private var divider: some View {
        Rectangle().fill(Theme.line).frame(height: 0.5).padding(.leading, 56)
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
}

// MARK: - 头像

/// 默认头像是系统灰底人像；换过头像就显示用户自己选的图。
/// 不预置一堆卡通脸，免得用户觉得被塞了不喜欢的东西。
struct AvatarView: View {
    var size: CGFloat
    @ObservedObject private var app = AppState.shared

    var body: some View {
        ZStack {
            if let img = app.avatarImage {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
            } else {
                Circle().fill(Color(uiColor: .systemGray4))
                Image(systemName: "person.fill")
                    .font(.system(size: size * 0.46, weight: .regular))
                    .foregroundStyle(.white.opacity(0.95))
                    .offset(y: size * 0.04)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}
