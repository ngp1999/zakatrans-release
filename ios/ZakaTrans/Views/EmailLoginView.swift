import SwiftUI

/// 邮箱登录（半屏弹窗）：输入邮箱 → 收 6 位验证码 → 登录。
///
/// 没有密码，账号就是这个邮箱：换手机、重装之后用同一个邮箱进来，
/// 余额和历史记录都在。第一次用某个邮箱登录会自动建号。
///
/// 这一版按「正经 App 的登录弹窗」来做：只有标题、两个输入框、一个主按钮，
/// 不放整段说明文、不放底部小字。弹窗高度由内容自己量出来交给外层。
struct EmailLoginView: View {
    /// 登录成功后的收尾（同步偏好、加载内购），由登录页传进来
    var onSuccess: () async -> Void = {}
    /// 内容实际高度（外层据此定半屏弹窗的高度）
    var onHeight: (CGFloat) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss

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

    private var canSend: Bool { emailValid && !sending && cooldown == 0 }

    private var canLogin: Bool { code.count == 6 && emailValid && !logging }

    private var sendTitle: String {
        if sending { return "发送中" }
        if cooldown > 0 { return "\(cooldown) 秒" }
        return sentOnce ? "重新发送" : "发送验证码"
    }

    var body: some View {
        // 键盘弹起来时这一层可以滚，内容本身高度交给外层定弹窗
        ScrollView(showsIndicators: false) {
            content.readHeight(onHeight)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DSColor.groupedBackground)
        .onAppear {
            if email.isEmpty { focus = .email }
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            if cooldown > 0 { cooldown -= 1 }
        }
    }

    // MARK: - 内容

    private var content: some View {
        VStack(spacing: DSSpace.l) {
            VStack(spacing: DSSpace.xxs) {
                Text("通过邮箱登录")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(DSColor.label)
                Text("验证码会发送到这个邮箱")
                    .font(.subheadline)
                    .foregroundStyle(DSColor.secondaryLabel)
            }
            .padding(.top, DSSpace.xl)

            VStack(spacing: DSSpace.s) {
                emailRow
                codeRow

                if let e = error {
                    Text(e)
                        .font(.footnote)
                        .foregroundStyle(DSColor.destructive)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button {
                    Task { await login() }
                } label: {
                    HStack(spacing: 6) {
                        if logging { ProgressView().controlSize(.small).tint(.white) }
                        Text("登录")
                    }
                }
                .buttonStyle(DSFilledButtonStyle())
                .disabled(!canLogin)
                .opacity(canLogin ? 1 : 0.5)
                .padding(.top, DSSpace.xs)
            }
        }
        .padding(.horizontal, DSSpace.xl)
        .padding(.bottom, DSSpace.l)
    }

    // MARK: - 输入

    private var emailRow: some View {
        HStack(spacing: DSSpace.xs) {
            TextField("邮箱地址", text: $email)
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focus, equals: .email)
                .submitLabel(.send)
                .font(.body)
                .onSubmit { Task { await sendCode() } }

            if !email.isEmpty && cooldown == 0 && !sending {
                Button {
                    email = ""
                    focus = .email
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(DSColor.tertiaryLabel)
                }
                .buttonStyle(.plain)
            }

            Button(sendTitle) {
                Task { await sendCode() }
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(canSend ? DSColor.accent : DSColor.tertiaryLabel)
            .disabled(!canSend)
            .layoutPriority(1)
        }
        .padding(.horizontal, DSSpace.m)
        .frame(height: 54)
        .background(DSColor.cell, in: RoundedRectangle(cornerRadius: DSRadius.button, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DSRadius.button, style: .continuous)
                .strokeBorder(focus == .email ? DSColor.accent : DSColor.separator,
                              lineWidth: focus == .email ? 1 : 0.5)
        )
        .animation(.easeOut(duration: 0.16), value: focus)
    }

    private var codeRow: some View {
        TextField("6 位验证码", text: $code)
            .keyboardType(.numberPad)
            .textContentType(.oneTimeCode)
            .focused($focus, equals: .code)
            .font(.body.monospacedDigit())
            .kerning(2)
            .onChange(of: code) { v in
                let digits = String(v.filter(\.isNumber).prefix(6))
                if digits != v { code = digits }
            }
            .padding(.horizontal, DSSpace.m)
            .frame(height: 54)
            .background(DSColor.cell, in: RoundedRectangle(cornerRadius: DSRadius.button, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DSRadius.button, style: .continuous)
                    .strokeBorder(focus == .code ? DSColor.accent : DSColor.separator,
                                  lineWidth: focus == .code ? 1 : 0.5)
            )
            .animation(.easeOut(duration: 0.16), value: focus)
    }

    // MARK: - 交互

    private func sendCode() async {
        guard canSend else { return }
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
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - 量高度

private struct EmailSheetHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

extension View {
    /// 把自身实际高度读出来（用来给半屏弹窗定高度，内容多少就多高）
    func readHeight(_ onChange: @escaping (CGFloat) -> Void) -> some View {
        background(
            GeometryReader { g in
                Color.clear.preference(key: EmailSheetHeightKey.self, value: g.size.height)
            }
        )
        .onPreferenceChange(EmailSheetHeightKey.self) { h in
            if h > 0 { onChange(h) }
        }
    }
}
