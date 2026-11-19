import Foundation
import AuthenticationServices
import UIKit

/// Sign in with Apple。
///
/// 客户端只负责拿到苹果给的 identityToken；
/// 验签、建号、绑定老账号全在服务端做，客户端改不了自己的账号身份。
@MainActor
final class AppleSignIn: NSObject, ObservableObject {
    static let shared = AppleSignIn()

    @Published private(set) var busy = false
    @Published var error: String?

    /// 登录成功回调：(identityToken, 姓名)
    var onSuccess: ((String, String?) -> Void)?

    func start() {
        guard !busy else { return }
        error = nil
        let provider = ASAuthorizationAppleIDProvider()
        let request = provider.createRequest()
        request.requestedScopes = [.fullName, .email]

        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self
        busy = true
        controller.performRequests()
    }
}

extension AppleSignIn: ASAuthorizationControllerDelegate {
    nonisolated func authorizationController(controller: ASAuthorizationController,
                                            didCompleteWithAuthorization authorization: ASAuthorization) {
        guard let cred = authorization.credential as? ASAuthorizationAppleIDCredential,
              let tokenData = cred.identityToken,
              let token = String(data: tokenData, encoding: .utf8) else {
            Task { @MainActor in
                self.busy = false
                self.error = "没有拿到登录凭据，请重试"
            }
            return
        }
        // 姓名只有第一次授权才有，之后就没有了，所以第一次一定要存
        var name: String?
        if let comps = cred.fullName {
            let f = comps.familyName ?? ""
            let g = comps.givenName ?? ""
            let full = (f + g).trimmingCharacters(in: .whitespaces)
            if !full.isEmpty { name = full }
        }
        Task { @MainActor in
            self.onSuccess?(token, name)
        }
    }

    nonisolated func authorizationController(controller: ASAuthorizationController,
                                            didCompleteWithError error: Error) {
        Task { @MainActor in
            self.busy = false
            let e = error as? ASAuthorizationError
            switch e?.code {
            case .canceled:
                self.error = nil
            case .failed:
                self.error = "苹果登录失败，请检查网络后重试"
            case .invalidResponse:
                self.error = "苹果返回异常，请重试"
            default:
                self.error = error.localizedDescription
            }
        }
    }
}

extension AppleSignIn: ASAuthorizationControllerPresentationContextProviding {
    nonisolated func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        return scene?.keyWindow ?? ASPresentationAnchor()
    }
}
