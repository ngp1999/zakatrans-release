import SwiftUI
import UIKit
import ReplayKit

/// 系统录屏选择器。这是唯一能把 App 之外的声音送进来的入口，
/// 所以必须用系统面板，不能自己做弹窗。
struct BroadcastPicker: UIViewRepresentable {
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let v = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 60, height: 60))
        // 扩展 id 必须跟着主 App 的 id 走，写死就会"列表里有、点了没反应"
        v.preferredExtension = Bundle.main.bundleIdentifier.map { $0 + ".ext" }
        v.showsMicrophoneButton = false
        v.backgroundColor = .clear
        BroadcastTrigger.shared.picker = v
        if let btn = v.subviews.compactMap({ $0 as? UIButton }).first {
            btn.setImage(nil, for: .normal)
            btn.alpha = 0.02 // 藏原生图标，点击由外面的 SwiftUI 按钮代理
        }
        return v
    }

    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {}
}

/// 把系统面板的按钮"借"出来：SwiftUI 按钮点一下，等于点了它
final class BroadcastTrigger: ObservableObject {
    static let shared = BroadcastTrigger()
    weak var picker: RPSystemBroadcastPickerView?

    func fire() {
        guard let picker else { return }
        for case let btn as UIButton in picker.subviews {
            btn.sendActions(for: .touchUpInside)
            return
        }
    }
}

/// 画中画要一个挂在窗口上的 UIView 当宿主
struct PipAnchor: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let v = UIView(frame: .zero)
        v.isHidden = true
        v.isUserInteractionEnabled = false
        DispatchQueue.main.async {
            AppState.shared.anchorView = v
        }
        return v
    }
    func updateUIView(_ uiView: UIView, context: Context) {
        AppState.shared.anchorView = uiView
    }
}
