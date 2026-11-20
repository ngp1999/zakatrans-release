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
        // 不能 isHidden：画中画在 App 内启动时，系统要求锚点视图真的在屏上（可见但几乎透明），
        // 隐藏的视图会让 isPictureInPicturePossible 变 false —— 这就是「有时画中画不出来」的原因
        v.isHidden = false
        v.alpha = 0.01
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

// MARK: - 顺手的滑动条

/// 滑动条。
///
/// 原来是 SwiftUI 手绘 + 高优先级拖拽手势，放在 ScrollView 里横拖会被纵向滚动抢走，
/// 拖起来一顿一顿的（用户实测：语速、压低音量这两根最明显）。
/// 现在直接用系统 UISlider：手势仲裁交给 UIKit，横拖永远优先，跟手且不掉帧；
/// 外观只改轨道和圆点颜色，跟 App 的青绿主色一致。
/// 拖动过程只回调 onChanged（本地即时显示），松手才回调 onEnded 落库。
struct FluidSlider: UIViewRepresentable {
    let value: Double
    let range: ClosedRange<Double>
    var step: Double = 0
    /// 拖动中（本地即时刷新用）
    var onChanged: (Double) -> Void = { _ in }
    /// 松手（落库 / 同步用）
    var onEnded: (Double) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UISlider {
        let s = UISlider()
        s.minimumValue = Float(range.lowerBound)
        s.maximumValue = Float(range.upperBound)
        s.value = Float(min(range.upperBound, max(range.lowerBound, value)))
        s.isContinuous = true
        s.minimumTrackTintColor = UIColor(Theme.accent)
        s.maximumTrackTintColor = UIColor.tertiarySystemFill
        s.thumbTintColor = .white
        s.setContentHuggingPriority(.defaultLow, for: .horizontal)
        s.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .valueChanged)
        s.addTarget(context.coordinator, action: #selector(Coordinator.ended(_:)),
                    for: [.touchUpInside, .touchUpOutside, .touchCancel])
        return s
    }

    func updateUIView(_ uiView: UISlider, context: Context) {
        context.coordinator.parent = self
        // 拖动中不回写：手指按着的时候被外部值拽回去会「粘住」
        if !context.coordinator.dragging,
           abs(Double(uiView.value) - value) > 0.0001 {
            uiView.value = Float(min(range.upperBound, max(range.lowerBound, value)))
        }
    }

    final class Coordinator: NSObject {
        var parent: FluidSlider
        var dragging = false

        init(_ p: FluidSlider) { parent = p }

        @objc func changed(_ s: UISlider) {
            dragging = true
            var v = Double(s.value)
            // 拖动过程不取整，避免一格一格地跳；数值标签自己取整显示
            v = min(parent.range.upperBound, max(parent.range.lowerBound, v))
            parent.onChanged(v)
        }

        @objc func ended(_ s: UISlider) {
            dragging = false
            var v = Double(s.value)
            if parent.step > 0 { v = (v / parent.step).rounded() * parent.step }
            v = min(parent.range.upperBound, max(parent.range.lowerBound, v))
            parent.onEnded(v)
        }
    }
}


// MARK: - 触感
// 每次点按都 new 一个 UIImpactFeedbackGenerator，第一次响要等 Taptic 引擎起来，
// 观感就是「按钮点了没反应，过一会儿才响应」。这里复用一台，页面出现时预热。
enum Haptics {
    private static let gen = UIImpactFeedbackGenerator(style: .light)
    static func warm() { gen.prepare() }
    static func tap(_ intensity: CGFloat = 1.0) {
        gen.impactOccurred(intensity: intensity)
        gen.prepare()
    }
}
