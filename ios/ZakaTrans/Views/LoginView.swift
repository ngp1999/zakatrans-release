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
            Theme.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer(minLength: 60)

                VStack(spacing: 12) {
                    Image("Logo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 88, height: 88)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

                    Text("语幕")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                    Text("实时字幕　同声传译")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.sub)
                }

                Spacer(minLength: 40)

                VStack(spacing: 14) {
                    AppleSignInButton(action: { apple.start() })
                        .frame(height: 52)
                        .disabled(working)

                    if let e = error ?? apple.error {
                        Text(e)
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.warn)
                            .multilineTextAlignment(.center)
                    }

                    HStack(spacing: 0) {
                        Text("登录即表示同意 ")
                        Button("《用户协议》") { terms = .terms }
                        Text(" 与 ")
                        Button("《隐私政策》") { terms = .privacy }
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.faint)
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 28)
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
        b.cornerRadius = 16
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
