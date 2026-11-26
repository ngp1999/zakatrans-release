import SwiftUI
import PhotosUI
import UIKit

/// 「我的」页面里的几个去处。
/// 用 value 型 NavigationLink + 一处 navigationDestination：目的页是按需创建的，
/// 不会在列表 body 里给每一行都先造一个页面（旧写法在 iPad 上点开就卡死）。
enum ProfileRoute: Hashable {
    case credit
    case history
    case about
}

/// 「我的」：系统分组列表。
///
/// 之前是 ScrollView + 一堆手写「玻璃行」，行高、图标块、chevron、分隔线全是手工对齐的。
/// 现在交给 `List(.insetGrouped)`：分组圆角、行高、分隔线缩进、滑动高亮、
/// 动态字体、VoiceOver、iPad 上的居中宽度，全部由系统负责，跟系统设置页一模一样。
struct ProfileView: View {
    @ObservedObject private var cloud = Cloud.shared
    @ObservedObject private var app = AppState.shared
    @State private var showLogout = false
    @State private var showEdit = false

    var body: some View {
        List {
            // 账号
            Section {
                Button {
                    showEdit = true
                } label: {
                    accountRow
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("使用默认头像", role: .destructive) { app.setAvatar(nil) }
                }
            }

            // 积分
            Section {
                NavigationLink(value: ProfileRoute.credit) {
                    LabeledContent {
                        Text(Format.credits(cloud.balanceCredits))
                            .font(DSFont.body.monospacedDigit())
                            .foregroundStyle(DSColor.secondaryLabel)
                    } label: {
                        Label {
                            Text("我的积分")
                        } icon: {
                            Image(systemName: "star.circle.fill")
                                .font(.system(size: 17))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, DSColor.accent)
                                .frame(width: 24, alignment: .center)
                        }
                    }
                }
            }

            // 记录 / 关于
            Section {
                NavigationLink(value: ProfileRoute.history) {
                    Label {
                        Text("对话记录")
                    } icon: {
                        rowIcon("clock.arrow.circlepath")
                    }
                }
                NavigationLink(value: ProfileRoute.about) {
                    Label {
                        Text("关于语幕")
                    } icon: {
                        rowIcon("info.circle")
                    }
                }
            }

            // 退出
            Section {
                Button(role: .destructive) {
                    showLogout = true
                } label: {
                    Text("退出登录")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("我的")
        .navigationBarTitleDisplayMode(.large)
        .navigationDestination(for: ProfileRoute.self) { r in
            switch r {
            case .credit:  CreditView()
            case .history: HistoryView()
            case .about:   AboutView()
            }
        }
        .task { if cloud.profile == nil { await cloud.refresh() } }
        .sheet(isPresented: $showEdit) {
            NavigationStack { AccountEditView() }
        }
        .alert("确认退出登录？", isPresented: $showLogout) {
            Button("取消", role: .cancel) {}
            Button("退出登录", role: .destructive) { cloud.logout() }
        } message: {
            Text("退出登录不会丢失任何数据，你仍可以登录此账号。")
        }
    }

    /// 列表行图标统一尺寸。
    /// 系统符号本身的「视觉大小」并不一致——时钟带外圈、圆里加号那种会显得比 info 大一截，
    /// 按同一个字号排出来看着就是一高一矮。这里给同一个字号 + 同一个宽度槽位，光学校齐。
    private func rowIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 17, weight: .regular))
            .frame(width: 24, alignment: .center)
    }

    // MARK: - 账号行

    private var accountRow: some View {
        HStack(spacing: DSSpace.s) {
            AvatarView(size: 52)

            VStack(alignment: .leading, spacing: 2) {
                Text(cloud.profile?.displayName ?? "语幕用户")
                    .font(DSFont.headline)
                    .foregroundStyle(DSColor.label)
                    .lineLimit(1)

                if let email = cloud.profile?.email, !email.isEmpty {
                    Text(email)
                        .font(DSFont.footnote)
                        .foregroundStyle(DSColor.secondaryLabel)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(DSColor.tertiaryLabel)
        }
        .contentShape(Rectangle())
        .padding(.vertical, DSSpace.xxs)
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
        .overlay(Circle().strokeBorder(DSColor.separator, lineWidth: 0.5))
    }
}
