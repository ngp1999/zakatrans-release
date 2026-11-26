import SwiftUI

/// 邮箱登录：输入邮箱 → 收 6 位验证码 → 登录。
///
/// 没有密码，账号就是这个邮箱：换手机、重装之后用同一个邮箱进来，
/// 余额和历史记录都在。第一次用某个邮箱登录会自动建号。
struct EmailLoginView: View {
    /// 登录成功后的收尾（同步偏好、加载内购），由登录页传进来
    var onSuccess: () async -> Void

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

    private var emailValid: Bool {
        let e = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let at = e.firstIndex(of: "@"), at != e.startIndex else { return false }
        let host = e[e.index(after: at)...]
        return host.contains(".") && !host.hasSuffix(".")
    }

    private var canLogin: Bool {
        code.count == 6 && emailValid && !logging
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                fieldBox {
                    TextField("邮箱", text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focus, equals: .email)
                        .submitLabel(.send)
                        .onSubmit { Task { await sendCode() } }
                }

                Button {
                    Task { await sendCode() }
                } label: {
                    HStack(spacing: 6) {
                        if sending { ProgressView().controlSize(.small) }
                        Text(cooldown > 0 ? "\(cooldown) 秒后可重发" : (sentOnce ? "重新发送验证码" : "发送验证码"))
                    }
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                }
                .buttonStyle(.bordered)
                .disabled(sending || cooldown > 0 || !emailValid)

                fieldBox {
                    TextField("6 位验证码", text: $code)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        .focused($focus, equals: .code)
                        .onChange(of: code) { v in
                            let digits = String(v.filter(\.isNumber).prefix(6))
                            if digits != v { code = digits }
                            if digits.count == 6 { focus = nil }
                        }
                }

                Button {
                    Task { await login() }
                } label: {
                    HStack(spacing: 6) {
                        if logging { ProgressView().controlSize(.small).tint(DSColor.invertedLabel) }
                        Text("登录")
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                }
                .buttonStyle(.borderedProminent)
                .tint(DSColor.label)
                .foregroundStyle(DSColor.invertedLabel)
                .disabled(!canLogin)

                if let e = error {
                    Text(e)
                        .font(.footnote)
                        .foregroundStyle(DSColor.destructive)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, DSSpace.xxl)
            .padding(.top, DSSpace.l)
            .navigationTitle("邮箱登录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("取消") { dismiss() }
                }
            }
            .onAppear {
                if email.isEmpty { focus = .email }
            }
            .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
                if cooldown > 0 { cooldown -= 1 }
            }
        }
        .sheetChrome()
    }

    private func fieldBox<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 14)
            .frame(height: 50)
            .background(
                RoundedRectangle(cornerRadius: DSRadius.button, style: .continuous)
                    .fill(DSColor.cellAlt)
            )
    }

    private func sendCode() async {
        guard emailValid, !sending, cooldown == 0 else { return }
        sending = true
        error = nil
        defer { sending = false }
        do {
            let wait = try await Cloud.shared.sendEmailCode(to: email.trimmingCharacters(in: .whitespacesAndNewlines))
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
            try await Cloud.shared.loginWithEmail(
                email: email.trimmingCharacters(in: .whitespacesAndNewlines),
                code: code
            )
            await onSuccess()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
