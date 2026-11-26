import SwiftUI
import AuthenticationServices

/// 登录页。Apple 登录是主入口，另一个是邮箱验证码登录——
/// 商用版要求「一个人一个账号，换手机数据还在」。
struct LoginView: View {
    @ObservedObject private var apple = AppleSignIn.shared
    @State private var error: String?
    @State private var working = false
    @State private var terms: TermsView.Kind?
    @State private var emailSheet = false
    /// 半屏弹窗高度：按邮箱表单的实际内容量出来，内容多少就多高
    @State private var emailSheetHeight: CGFloat = 360

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

                    HStack(spacing: 10) {
                        Rectangle().fill(DSColor.separator).frame(height: 0.5)
                        Text("或").font(.footnote).foregroundStyle(DSColor.tertiaryLabel)
                        Rectangle().fill(DSColor.separator).frame(height: 0.5)
                    }
                    .padding(.vertical, 2)

                    Button {
                        emailSheet = true
                    } label: {
                        HStack(spacing: DSSpace.xs) {
                            Image(systemName: "envelope.fill")
                                .font(.system(size: 17, weight: .medium))
                            Text("通过邮箱登录")
                                .font(.system(size: 19, weight: .medium))
                        }
                        .foregroundStyle(DSColor.label)
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .background(
                            RoundedRectangle(cornerRadius: DSRadius.button, style: .continuous)
                                .fill(DSColor.cellAlt)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: DSRadius.button, style: .continuous)
                                .strokeBorder(DSColor.separator, lineWidth: 0.5)
                        )
                    }
                    .buttonStyle(SignInLikeButtonStyle())
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
        .sheet(isPresented: $emailSheet) {
            EmailLoginView(
                onSuccess: { await afterLogin() },
                onHeight: { h in
                    // 内容高度 + 一点余量；上下限兜住极端字号，别弹成整屏
                    let target = min(max(h.rounded(.up) + 8, 300), 620)
                    if abs(target - emailSheetHeight) > 1 { emailSheetHeight = target }
                }
            )
            .presentationDetents([.height(emailSheetHeight)])
            .presentationDragIndicator(.visible)
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
            await afterLogin()
        } catch {
            self.error = error.localizedDescription
        }
        apple.busy = false
    }

    /// 两条登录路径共用的收尾：云端偏好、内购、未完成交易
    private func afterLogin() async {
        await AppState.shared.syncPrefsFromCloud()
        await Purchases.shared.load()
        await Purchases.shared.syncUnfinished()
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

/// 与系统「通过 Apple 登录」按钮同尺寸的次级按钮按压反馈：
/// 高度、圆角、字号都对齐系统控件，按下只有轻微收缩和高亮，不做回弹。
struct SignInLikeButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.82 : 1)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
