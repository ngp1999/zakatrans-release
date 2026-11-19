import SwiftUI

/// 用户协议 / 隐私政策。本地全文，审核要求能直接看到。
struct TermsView: View {
    enum Kind: String, Identifiable {
        case terms, privacy
        var id: String { rawValue }
    }
    let kind: Kind

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(kind == .terms ? "用户协议" : "隐私政策")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(Theme.ink)
                Text("更新日期：2026 年 11 月 19 日")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.faint)

                ForEach(Array(sections.enumerated()), id: \.offset) { _, s in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(s.0)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                        Text(s.1)
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.sub)
                            .lineSpacing(4)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 32)
        }
        .background(Theme.bg)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var sections: [(String, String)] {
        kind == .terms ? Self.termsText : Self.privacyText
    }

    private static let termsText: [(String, String)] = [
        ("一、服务内容",
         "语幕（以下简称「本应用」）提供实时语音转写与翻译服务：将正在播放或现场的声音转成文字，并翻译为中文，支持在应用内和画中画字幕中查看，也可以把译文朗读出来。部分功能需要联网，识别与翻译由云端服务完成。"),
        ("二、账号",
         "本应用使用「通过 Apple 登录」作为唯一登录方式。你的账号与 Apple 账户关联，用于在多台设备之间同步积分、设置和对话记录。请妥善保管你的设备与 Apple 账户，因设备遗失或账户被他人使用造成的损失由你自行承担。"),
        ("三、积分与付费",
         "本应用按实际用量扣除积分，1 元 = 10 积分。积分为虚拟服务额度，不具备货币属性，不可转让、不可提现。充值通过 Apple App Store 内购完成，价格以 App Store 显示为准。新用户可领取一次 5 分钟试用额度，同一账号、同一设备仅限一次。"),
        ("四、退款",
         "充值订单由 Apple 处理，退款请按 Apple 的退款规则在 App Store 中申请。退款成功后，对应积分将同步扣回；已消耗部分不予退还。"),
        ("五、使用规范",
         "你承诺不利用本应用从事违法活动，不录制、传播未经他人同意的内容。录制他人语音前，请自行确认已取得必要的同意，并遵守所在地法律法规。因你的使用行为产生的责任由你自行承担。"),
        ("六、服务变更与中断",
         "我们会持续改进服务，可能对功能进行调整。因网络、第三方服务故障、系统维护等原因造成的服务中断，我们会尽快恢复；因此导致的积分未消耗部分仍保留在你的账号中。"),
        ("七、免责",
         "语音识别与机器翻译存在误差，本应用的输出仅供参考，不构成任何专业意见。涉及医疗、法律、金融等重要场景时，请以人工确认为准。"),
        ("八、联系我们",
         "对本协议有任何疑问，可通过 App Store 页面提供的支持方式与我们联系。"),
    ]

    private static let privacyText: [(String, String)] = [
        ("一、我们收集哪些信息",
         "1. 账号信息：通过 Apple 登录时，我们会收到苹果提供的账号唯一标识；若你选择共享，还会收到姓名与邮箱。\n2. 设备信息：设备型号、系统版本、应用版本、用于防止试用额度被重复领取的设备标识。\n3. 使用数据：每场会话的开始与结束时间、音频时长、转写与翻译文本、消耗积分。\n4. 设置数据：字号、颜色、背景、语言等字幕偏好。"),
        ("二、音频如何处理",
         "录音屏时，音频由系统录屏扩展采集并直接送到云端识别服务，转成文字后即刻丢弃原始音频。我们不会保存你的音频文件，也不会将其用于其他用途。"),
        ("三、信息用途",
         "上述信息仅用于：提供转写与翻译、计算用量与扣费、在设备之间同步记录与设置、排查故障与保障服务安全。我们不会将你的对话内容用于广告投放，也不会出售给第三方。"),
        ("四、存储与保护",
         "账号、积分与对话记录保存在我们的服务器上，传输过程使用 HTTPS / WSS 加密。我们采取访问控制、最小权限等措施保护数据。对话记录你可以随时在应用内删除。"),
        ("五、第三方服务",
         "语音识别与翻译由云端的语音服务商提供，我们在服务端调用，你的设备不直接接触第三方凭据。充值由 Apple 完成，支付信息由 Apple 处理，我们不会获取你的银行卡或支付账号信息。"),
        ("六、你的权利",
         "你可以随时查看和删除对话记录、修改字幕设置、退出登录。如需注销账号或删除全部数据，可通过 App Store 页面提供的支持方式联系我们，我们会在核实身份后处理。"),
        ("七、未成年人",
         "本应用面向成年人提供服务。未成年人应在监护人指导下使用，且监护人需对其使用行为负责。"),
        ("八、政策更新",
         "本政策如有更新，会在应用内展示最新版本，继续使用即视为接受更新后的内容。"),
    ]
}
