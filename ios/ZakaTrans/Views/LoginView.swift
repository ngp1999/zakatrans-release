import SwiftUI
import AuthenticationServices

/// 登录页。Apple 登录是唯一入口，不提供匿名设备号——
/// 商用版要求「一个人一个账号，换手机数据还在」。
struct LoginView: View {
    @ObservedObject private var apple = AppleSignIn.shared
    @State private var error: String?
    @State private var working = false
    @State private var terms: TermsView.Kind?

    var body: some View {
        ZStack {
            AmbientBackground()

            VStack(spacing: 0) {
                Spacer(minLength: 60)

                VStack(spacing: 14) {
                    Image("Logo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 92, height: 92)
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))

                    VStack(spacing: 6) {
                        Text("语幕")
                            .font(.largeTitle.weight(.semibold))
                            .tracking(3)
                            .foregroundStyle(DSColor.label)
                        Text("实时字幕　同声传译")
                            .font(.subheadline)
                            .foregroundStyle(DSColor.secondaryLabel)
                    }
                    .padding(.top, 6)
                }

                Spacer(minLength: 40)

                VStack(spacing: 14) {
                    AppleSignInButton(action: { apple.start() })
                        .frame(height: 54)
                        .disabled(working)

                    if let e = error ?? apple.error {
                        Text(e)
                            .font(.footnote)
                            .foregroundStyle(DSColor.destructive)
                            .multilineTextAlignment(.center)
                    }

                    HStack(spacing: 0) {
                        Text("登录即表示同意 ")
                        Button("《用户协议》") { terms = .terms }
                        Text(" 与 ")
                        Button("《隐私政策》") { terms = .privacy }
                    }
                    .font(.caption)
                    .foregroundStyle(DSColor.tertiaryLabel)
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, DSSpace.xxl)
                .padding(.bottom, DSSpace.xxl)
            }
        }
        .sheet(item: $terms) { kind in
            NavigationStack {
                TermsView(kind: kind)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("完成") { terms = nil }
                        }
                    }
            }
            .sheetChrome()
        }
        .onAppear {
            apple.onSuccess = { token, name in
                Task { await handle(token: token, name: name) }
            }
        }
    }

    private func handle(token: String, name: String?) async {
        working = true
        defer { working = false }
        do {
            try await Cloud.shared.loginWithApple(identityToken: token, fullName: name)
            await AppState.shared.syncPrefsFromCloud()
            await Purchases.shared.load()
            await Purchases.shared.syncUnfinished()
        } catch {
            self.error = error.localizedDescription
        }
        apple.busy = false
    }
}

/// 系统标准的「通过 Apple 登录」按钮。
/// 必须用系统控件——自己画一个苹果图标拼出来的按钮，审核会被打回。
struct AppleSignInButton: UIViewRepresentable {
    var action: () -> Void

    func makeUIView(context: Context) -> ASAuthorizationAppleIDButton {
        let b = ASAuthorizationAppleIDButton(type: .signIn, style: .black)
        b.cornerRadius = DSRadius.button
        b.addTarget(context.coordinator, action: #selector(Coordinator.tap), for: .touchUpInside)
        return b
    }

    func updateUIView(_ uiView: ASAuthorizationAppleIDButton, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    final class Coordinator: NSObject {
        let action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func tap() { action() }
    }
}
