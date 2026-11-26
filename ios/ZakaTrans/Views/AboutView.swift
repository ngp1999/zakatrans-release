import SwiftUI

/// 关于语幕：应用信息 + 协议与说明。
/// 结构就是系统「关于」页：上面一块应用信息，下面分组入口。
struct AboutView: View {
    /// 对外联系邮箱
    static let contactEmail = "1938044162@qq.com"

    @ObservedObject private var cloud = Cloud.shared
    @State private var showDelete = false
    @State private var deleting = false
    @State private var deleteError = ""

    /// 只读短版本号（V3.10.5）。构建号是内部排查用的，不给用户看。
    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        return v.isEmpty ? "" : "V\(v)"
    }

    var body: some View {
        List {
            // 应用信息
            Section {
                VStack(spacing: DSSpace.s) {
                    Image("Logo")
                        .resizable()
                        .scaledToFill()
                        .frame(width: 76, height: 76)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                    Text("语幕")
                        .font(DSFont.title2)
                        .foregroundStyle(DSColor.label)

                    Text("实时字幕与同声传译")
                        .font(DSFont.subheadline)
                        .foregroundStyle(DSColor.secondaryLabel)

                    Text(version)
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(DSColor.tertiaryLabel)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, DSSpace.s)
                .listRowBackground(Color.clear)
            }

            // 免责声明：审核要求把第三方服务与误差责任讲清楚，放在应用信息下面
            Section {
                VStack(alignment: .leading, spacing: DSSpace.s) {
                    Text("免责声明")
                        .font(DSFont.headline)
                        .foregroundStyle(DSColor.label)

                    Text("""
                    本应用基于第三方技术服务（豆包）提供语音识别与翻译能力，输出结果可能存在延迟或识别偏差，重要场合请以原始信息为准。

                    · 本应用为工具类软件，不对因识别误差导致的任何直接或间接损失承担责任。
                    · 使用本应用即表示你已知悉并同意上述说明。
                    """)
                        .font(DSFont.footnote)
                        .foregroundStyle(DSColor.label.opacity(0.68))
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(DSSpace.m)
                .background(
                    LinearGradient(
                        colors: [DSColor.accentSoft, DSColor.accentSoft.opacity(0.45)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: RoundedRectangle(cornerRadius: DSRadius.card, style: .continuous)
                )
                .padding(.horizontal, DSSpace.xxs)
                .listRowInsets(EdgeInsets(top: DSSpace.xs, leading: DSSpace.m, bottom: DSSpace.xs, trailing: DSSpace.m))
                .listRowBackground(Color.clear)
            }

            // 协议
            Section {
                NavigationLink {
                    TermsView(kind: .terms)
                } label: {
                    Text("用户协议")
                }

                NavigationLink {
                    TermsView(kind: .privacy)
                } label: {
                    Text("隐私政策")
                }

                NavigationLink {
                    TermsView(kind: .payment)
                } label: {
                    Text("付费协议")
                }

                NavigationLink {
                    TermsView(kind: .permissions)
                } label: {
                    Text("应用权限说明")
                }
            }

            // 支持
            Section {
                // 常见问题放在联系方式上面：先让用户自己查到答案，邮件留给真正需要人处理的事
                NavigationLink {
                    TermsView(kind: .faq)
                } label: {
                    Text("常见问题")
                }

                NavigationLink {
                    TermsView(kind: .contact)
                } label: {
                    Text("联系我们")
                }

                // App Store 5.1.1(v)：账号必须能在 App 内自己注销
                Button(role: .destructive) {
                    showDelete = true
                } label: {
                    HStack {
                        Text("注销账号")
                        Spacer()
                        if deleting { ProgressView() }
                    }
                }
            }

            // 备案信息：工信部要求 App 内公示，点击可跳转备案系统查询
            Section {
                VStack(spacing: DSSpace.xxs) {
                    Link(destination: URL(string: "https://beian.miit.gov.cn/")!) {
                        Text("皖ICP备2026045837号-3A")
                            .font(DSFont.footnote)
                    }
                }
                .foregroundStyle(DSColor.tertiaryLabel)
                .frame(maxWidth: .infinity)
                .padding(.vertical, DSSpace.xs)
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.insetGrouped)
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
}
