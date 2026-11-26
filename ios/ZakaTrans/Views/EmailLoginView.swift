import SwiftUI

/// 邮箱登录：输入邮箱 → 收 6 位验证码 → 登录。
///
/// 没有密码，账号就是这个邮箱：换手机、重装之后用同一个邮箱进来，
/// 余额和历史记录都在。第一次用某个邮箱登录会自动建号。
///
/// 呈现方式是「页面内切换」，不用模态弹窗：左上角返回 → 中间一段说明文 →
/// 邮箱输入框 + 发送按钮 → 验证码 → 登录按钮，与登录页同一套排版和圆角。
struct EmailLoginView: View {
    /// 左上角返回（由登录页负责把这一页收回去）
    var onBack: () -> Void
    /// 登录成功后的收尾（同步偏好、加载内购），由登录页传进来
    var onSuccess: () async -> Void

    @State private var email = ""
    @State private var code = ""
    @State private var sending = false
    @State private var logging = false
    @State private var cooldown = 0
    @State private var sentOnce = false
    @State private var error: String?

    @FocusState private var focus: Field?

    private enum Field { case email, code }

    private var trimmedEmail: String {
        email.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var emailValid: Bool {
        let e = trimmedEmail
        guard let at = e.firstIndex(of: "@"), at != e.startIndex else { return false }
        let host = e[e.index(after: at)...]
        return host.contains(".") && !host.hasSuffix(".")
    }

    private var canLogin: Bool {
        code.count == 6 && emailValid && !logging
    }

    var body: some View {
        ZStack {
            AmbientBackground()

            VStack(spacing: 0) {
                // 返回：跟系统返回一样贴在左上角
                HStack {
                    Button {
                        focus = nil
                        onBack()
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "chevron.left")
                                .font(.body.weight(.semibold))
                            Text("返回")
                                .font(.body)
                        }
                        .foregroundStyle(DSColor.accent)
                        .padding(.vertical, 8)
                        .padding(.trailing, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, DSSpace.l)
                .padding(.top, DSSpace.xs)

                ScrollView(showsIndicators: false) {
                    VStack(spacing: DSSpace.l) {
                        header

                        VStack(spacing: DSSpace.s) {
                            emailField
                            sendButton
                            codeField
                            loginButton
                        }

                        if let e = error {
                            Text(e)
                                .font(.footnote)
                                .foregroundStyle(DSColor.destructive)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity)
                        }

                        Text("登录即表示同意《用户协议》与《隐私政策》")
                            .font(.caption)
                            .foregroundStyle(DSColor.tertiaryLabel)
                            .multilineTextAlignment(.center)
                            .padding(.top, DSSpace.xxs)
                    }
                    .padding(.horizontal, DSSpace.xxl)
                    .padding(.top, DSSpace.xxl)
                    .padding(.bottom, DSSpace.xxl)
                    .frame(maxWidth: 520)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
            }
        }
        .onAppear {
            if email.isEmpty { focus = .email }
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            if cooldown > 0 { cooldown -= 1 }
        }
    }

    // MARK: - 说明文

    private var header: some View {
        VStack(spacing: DSSpace.s) {
            ZStack {
                Circle()
                    .fill(DSColor.accentSoft)
                    .frame(width: 64, height: 64)
                Image(systemName: "envelope.fill")
                    .font(.system(size: 26, weight: .regular))
                    .foregroundStyle(DSColor.accent)
            }
            .padding(.bottom, DSSpace.xxs)

            Text("邮箱登录")
                .font(.title2.weight(.semibold))
                .foregroundStyle(DSColor.label)

            Text("输入常用邮箱，我们会发送 6 位验证码。\n第一次用某个邮箱登录会自动创建账号，\n换手机、重装后余额和历史记录都还在。")
                .font(.subheadline)
                .foregroundStyle(DSColor.secondaryLabel)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, DSSpace.s)
    }

    // MARK: - 输入区

    private var emailField: some View {
        HStack(spacing: DSSpace.s) {
            Image(systemName: "at")
                .font(.body)
                .foregroundStyle(DSColor.tertiaryLabel)

            TextField("邮箱地址", text: $email)
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focus, equals: .email)
                .submitLabel(.send)
                .onSubmit { Task { await sendCode() } }
                .font(.body)

            if !email.isEmpty {
                Button {
                    email = ""
                    focus = .email
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(DSColor.tertiaryLabel)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 54)
        .background(
            RoundedRectangle(cornerRadius: DSRadius.button, style: .continuous)
                .fill(DSColor.cellAlt)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DSRadius.button, style: .continuous)
                .strokeBorder(focus == .email ? DSColor.accent.opacity(0.55) : DSColor.separator, lineWidth: focus == .email ? 1.2 : 0.5)
        )
        .animation(.easeOut(duration: 0.16), value: focus)
    }

    private var sendButton: some View {
        Button {
            Task { await sendCode() }
        } label: {
            HStack(spacing: 6) {
                if sending { ProgressView().controlSize(.small) }
                Text(cooldown > 0 ? "\(cooldown) 秒后可重新发送" : (sentOnce ? "重新发送验证码" : "发送验证码"))
            }
            .font(.subheadline.weight(.medium))
            .frame(maxWidth: .infinity)
            .frame(height: 48)
        }
        .buttonStyle(DSTintedButtonStyle())
        .disabled(sending || cooldown > 0 || !emailValid)
        .opacity(!emailValid || cooldown > 0 ? 0.5 : 1)
    }

    private var codeField: some View {
        VStack(alignment: .leading, spacing: DSSpace.xs) {
            Text("验证码")
                .font(.footnote.weight(.medium))
                .foregroundStyle(DSColor.secondaryLabel)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: DSSpace.s) {
                Image(systemName: "number")
                    .font(.body)
                    .foregroundStyle(DSColor.tertiaryLabel)

                TextField("6 位数字", text: $code)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .focused($focus, equals: .code)
                    .font(.title3.monospacedDigit())
                    .kerning(4)
                    .onChange(of: code) { v in
                        let digits = String(v.filter(\.isNumber).prefix(6))
                        if digits != v { code = digits }
                        if digits.count == 6 { focus = nil }
                    }
            }
            .padding(.horizontal, 16)
            .frame(height: 54)
            .background(
                RoundedRectangle(cornerRadius: DSRadius.button, style: .continuous)
                    .fill(DSColor.cellAlt)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DSRadius.button, style: .continuous)
                    .strokeBorder(focus == .code ? DSColor.accent.opacity(0.55) : DSColor.separator, lineWidth: focus == .code ? 1.2 : 0.5)
            )
            .animation(.easeOut(duration: 0.16), value: focus)
        }
        .padding(.top, DSSpace.xxs)
    }

    private var loginButton: some View {
        Button {
            Task { await login() }
        } label: {
            HStack(spacing: 6) {
                if logging { ProgressView().controlSize(.small).tint(.white) }
                Text("登录")
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
            .frame(height: 54)
        }
        .buttonStyle(DSPrimaryAccentButtonStyle())
        .disabled(!canLogin)
        .opacity(canLogin ? 1 : 0.55)
        .padding(.top, DSSpace.xs)
    }

    // MARK: - 交互

    private func sendCode() async {
        guard emailValid, !sending, cooldown == 0 else { return }
        sending = true
        error = nil
        defer { sending = false }
        do {
            let wait = try await Cloud.shared.sendEmailCode(to: trimmedEmail)
            cooldown = max(wait, 0)
            sentOnce = true
            focus = .code
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func login() async {
        guard canLogin else { return }
        logging = true
        error = nil
        defer { logging = false }
        do {
            try await Cloud.shared.loginWithEmail(email: trimmedEmail, code: code)
            await onSuccess()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - 局部按钮样式

/// 次级按钮：主题色的浅底填充，用于「发送验证码」
private struct DSTintedButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(DSColor.accent)
            .background(DSColor.accentSoft, in: RoundedRectangle(cornerRadius: DSRadius.button, style: .continuous))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// 主按钮：主题色渐变 + 轻玻璃高光，按下有回弹
private struct DSPrimaryAccentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .background(
                LinearGradient(
                    colors: [DSColor.accent, DSColor.accentFill],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: DSRadius.button, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DSRadius.button, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.22), lineWidth: 1)
            )
            .shadow(color: DSColor.accent.opacity(configuration.isPressed ? 0.12 : 0.3),
                    radius: configuration.isPressed ? 4 : 12,
                    y: configuration.isPressed ? 1 : 6)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}
