import SwiftUI

/// 关于语幕：应用信息 + 协议与说明。
/// 结构按国内主流 App 的"关于"页来：上面是图标和版本，下面是条款入口，最后是版权。
struct AboutView: View {
    /// 对外联系邮箱
    static let contactEmail = "1938044162@qq.com"

    @ObservedObject private var cloud = Cloud.shared
    @State private var showDelete = false
    @State private var deleting = false
    @State private var deleteError = ""

    /// 只读短版本号（V3.7.5）。构建号是内部排查用的，不给用户看。
    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        return v.isEmpty ? "" : "V\(v)"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                headerCard
                legalCard
                supportCard
                footer
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 28)
        }
        .background(Theme.bg)
        .navigationTitle("关于语幕")
        .navigationBarTitleDisplayMode(.inline)
        .alert("确认注销账号？", isPresented: $showDelete) {
            Button("取消", role: .cancel) {}
            Button("注销", role: .destructive) { deleteAccount() }
        } message: {
            Text("账号、积分、对话记录等数据会一并删除，无法恢复。")
        }
        .alert("注销失败", isPresented: Binding(
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
            if !ok { deleteError = cloud.lastError ?? "注销失败，请稍后重试" }
        }
    }

    // MARK: - 头部

    private var headerCard: some View {
        VStack(spacing: 12) {
            Image("Logo")
                .resizable()
                .scaledToFill()
                .frame(width: 76, height: 76)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Theme.hairline, lineWidth: 0.6)
                )

            Text("语幕")
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(Theme.ink)

            Text("实时字幕与同声传译")
                .font(.system(size: 14))
                .foregroundStyle(Theme.faint)
                .padding(.top, 2)

            // 版本号是排查问题的第一手信息，放在名字下面，一眼看得到。
            // 不做胶囊底、不带构建号——一行浅字就够。
            Text(version)
                .font(.system(size: 13).monospacedDigit())
                .foregroundStyle(Theme.faint)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
    }

    // MARK: - 协议

    private var legalCard: some View {
        VStack(spacing: 0) {
            row(title: "用户协议", kind: .terms)
            divider
            row(title: "隐私政策", kind: .privacy)
            divider
            row(title: "付费协议", kind: .payment)
            divider
            row(title: "应用权限说明", kind: .permissions)
        }
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
    }

    private var supportCard: some View {
        VStack(spacing: 0) {
            // 常见问题放在联系方式上面：先让用户自己查到答案，邮件留给真正需要人处理的事
            NavigationLink {
                TermsView(kind: .faq)
            } label: {
                HStack {
                    Text("常见问题").font(.system(size: 16)).foregroundStyle(Theme.ink)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.faint)
                }
                .padding(.horizontal, 16)
                .frame(height: 52)
                .contentShape(Rectangle())
            }
            .buttonStyle(RowButtonStyle())

            divider

            NavigationLink {
                TermsView(kind: .contact)
            } label: {
                HStack {
                    Text("联系我们").font(.system(size: 16)).foregroundStyle(Theme.ink)
                    Spacer()
                    // 邮箱放在页面里面，不在这一行露出来
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.faint)
                }
                .padding(.horizontal, 16)
                .frame(height: 52)
                .contentShape(Rectangle())
            }
            .buttonStyle(RowButtonStyle())

            divider

            // App Store 5.1.1(v)：账号必须能在 App 内自己注销，
            // 放在「联系我们」下面——用户找客服找不到就会翻到这儿。
            Button { showDelete = true } label: {
                HStack {
                    Text("注销账号").font(.system(size: 16)).foregroundStyle(Theme.warn)
                    Spacer()
                    if deleting {
                        ProgressView().scaleEffect(0.8)
                    }
                }
                .padding(.horizontal, 16)
                .frame(height: 52)
                .contentShape(Rectangle())
            }
            .buttonStyle(RowButtonStyle())
        }
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
    }

    private var footer: some View {
        VStack(spacing: 6) {
            Text("© 2026 语幕")
                .font(.system(size: 13))
                .foregroundStyle(Theme.faint)
            Text("保留所有权利")
                .font(.system(size: 12))
                .foregroundStyle(Theme.faint)
        }
        .padding(.top, 10)
    }

    private func row(title: String, kind: TermsView.Kind) -> some View {
        NavigationLink {
            TermsView(kind: kind)
        } label: {
            HStack {
                Text(title).font(.system(size: 16)).foregroundStyle(Theme.ink)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.faint)
            }
            .padding(.horizontal, 16)
            .frame(height: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle())
    }

    private var divider: some View {
        Rectangle().fill(Theme.line).frame(height: 0.5).padding(.leading, 16)
    }
}
