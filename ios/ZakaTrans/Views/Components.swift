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

/// 自己画的滑动条。
///
/// 系统 Slider 放在 ScrollView 里有个老毛病：横向拖动时会被纵向滚动抢走手势，
/// 手指划过去要么不动、要么跳一下，用起来就是"卡"。这里用高优先级拖拽手势接管，
/// 并且只在松手时回写设置（拖动过程只更新本地值），不每一帧都触发同步。
struct FluidSlider: View {
    let value: Double
    let range: ClosedRange<Double>
    var step: Double = 0
    /// 拖动中（本地即时刷新用）
    var onChanged: (Double) -> Void = { _ in }
    /// 松手（落库 / 同步用）
    var onEnded: (Double) -> Void = { _ in }

    @State private var dragValue: Double?

    private var current: Double { dragValue ?? value }

    var body: some View {
        GeometryReader { geo in
            let w = max(1, geo.size.width)
            let knob: CGFloat = 26
            let travel = max(1, w - knob)
            let span = range.upperBound - range.lowerBound
            let frac = span > 0 ? min(1, max(0, (current - range.lowerBound) / span)) : 0
            let x = travel * CGFloat(frac)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Theme.fill)
                    .frame(height: 4)

                Capsule()
                    .fill(Theme.accent)
                    .frame(width: x + knob / 2, height: 4)

                Circle()
                    .fill(Color.white)
                    .frame(width: knob, height: knob)
                    .shadow(color: .black.opacity(0.18), radius: 4, y: 1)
                    .overlay(Circle().strokeBorder(Theme.hairline, lineWidth: 0.5))
                    .offset(x: x)
            }
            .frame(height: knob)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        var v = range.lowerBound
                        if travel > 0 {
                            let ratio = Double(min(travel, max(0, g.location.x - knob / 2)) / travel)
                            v = range.lowerBound + ratio * span
                        }
                        if step > 0 { v = (v / step).rounded() * step }
                        v = min(range.upperBound, max(range.lowerBound, v))
                        if let d = dragValue, abs(d - v) < 0.0001 { return }
                        dragValue = v
                        onChanged(v)
                    }
                    .onEnded { _ in
                        let v = dragValue ?? value
                        dragValue = nil
                        onEnded(v)
                    }
            )
        }
        .frame(height: 34)
        .accessibilityElement()
        .accessibilityValue(String(format: "%.1f", current))
    }
}
