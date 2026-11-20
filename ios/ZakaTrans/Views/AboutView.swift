import SwiftUI

/// 关于语幕：应用信息 + 协议与说明。
/// 结构按国内主流 App 的"关于"页来：上面是图标和版本，下面是条款入口，最后是版权。
struct AboutView: View {
    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        return b.isEmpty ? v : "\(v) (\(b))"
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

            Text("语幕翻译")
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(Theme.ink)

            Text("版本 \(version)")
                .font(.system(size: 14).monospacedDigit())
                .foregroundStyle(Theme.sub)

            Text("实时字幕与同声传译")
                .font(.system(size: 14))
                .foregroundStyle(Theme.faint)
                .padding(.top, 2)
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
            row(title: "联系我们", kind: .contact)
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
