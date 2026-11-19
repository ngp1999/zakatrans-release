import SwiftUI
import AuthenticationServices

/// 登录页。Apple 登录是唯一入口，不提供匿名设备号——
/// 商用版要求「一个人一个账号，换手机数据还在」。
struct LoginView: View {
    @ObservedObject private var apple = AppleSignIn.shared
    @State private var error: String?
    @State private var working = false

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer(minLength: 40)

                // 品牌区
                VStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .fill(
                                LinearGradient(colors: [Theme.accent, Theme.accent.opacity(0.75)],
                                               startPoint: .topLeading, endPoint: .bottomTrailing)
                            )
                            .frame(width: 76, height: 76)
                        Image(systemName: "waveform")
                            .font(.system(size: 32, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .shadow(color: Theme.accent.opacity(0.35), radius: 18, x: 0, y: 8)

                    Text("ZakaTrans")
                        .font(.system(size: 30, weight: .bold, design: .default))
                        .foregroundStyle(Theme.ink)
                    Text("实时语音翻译")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.sub)
                }

                Spacer(minLength: 28)

                // 三个卖点
                VStack(alignment: .leading, spacing: 16) {
                    feature("waveform", "边说边译", "自动识别对方语言，译文实时上屏")
                    feature("rectangle.inset.filled.and.person.filled", "画中画字幕", "切到别的 App 也能看，横条模式一句一行")
                    feature("icloud", "云端同步", "换设备登录，记录和设置自动带回")
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .card(padding: 20)
                .padding(.horizontal, 24)

                Spacer(minLength: 32)

                VStack(spacing: 12) {
                    AppleSignInButton(action: { apple.start() })
                        .frame(height: 52)
                        .disabled(working)

                    if let e = error ?? apple.error {
                        Text(e)
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.warn)
                            .multilineTextAlignment(.center)
                    }

                    Text("登录即表示同意《用户协议》与《隐私政策》")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.faint)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
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

    private func feature(_ icon: String, _ title: String, _ desc: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Theme.accent)
                .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.ink)
                Text(desc).font(.system(size: 13)).foregroundStyle(Theme.sub)
            }
        }
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
