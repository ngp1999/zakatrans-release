import Foundation
import SwiftUI
import AVFoundation

/// 字幕外观偏好。存本地 + 云端：换手机、重装都自动同步回来。
///
/// 显示逻辑集中在这里，画中画（ObjC 层）和 App 内字幕共用同一份设置，
/// 两边不会出现「App 里是双语、画中画是单语」这种不一致。
struct SubtitlePrefs: Codable, Equatable {
    /// 字号（App 内）。画中画按比例缩放。
    var size: Double = 19
    /// 颜色：white | yellow | cyan | green | black
    var color: String = "white"
    /// 样式：shadow（描边阴影）| box（半透明底板）| plain（纯文字）
    var style: String = "shadow"
    /// 语言模式：bilingual（双语）| zh（仅中文）| source（仅原文）
    var mode: String = "bilingual"
    /// 画中画形态：bar（横条，一句一行铺开）| standard（4:3 大窗）
    var pip: String = "bar"
    /// 输出音频（把译文读出来）
    var tts: Bool = false
    /// 朗读语速 0.35~0.6
    var speechRate: Double = 0.48
    /// 原文语言：auto = 让模型自己识别
    var sourceLang: String = "auto"
    /// 译文语言：固定中文
    var destLang: String = "zh"

    static let key = "zt_subtitle_prefs_v2"

    static func load() -> SubtitlePrefs {
        if let data = UserDefaults.standard.data(forKey: key),
           let v = try? JSONDecoder().decode(SubtitlePrefs.self, from: data) {
            return v
        }
        return SubtitlePrefs()
    }

    func saveLocal() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
        // 引擎层（ObjC）读的是字符串设置
        ZKStore.setSetting("asrlang", v: sourceLang)
        ZKStore.setSetting("dstlang", v: destLang)
    }

    func dict() -> [String: Any] {
        [
            "subtitle_size": size,
            "subtitle_color": color,
            "subtitle_style": style,
            "subtitle_mode": mode,
            "pip_style": pip,
            "tts": tts,
            "speech_rate": speechRate,
            "source_lang": sourceLang,
            "dest_lang": destLang,
        ]
    }

    static func from(dict: [String: Any]) -> SubtitlePrefs? {
        var p = SubtitlePrefs()
        if let v = dict["subtitle_size"] as? NSNumber { p.size = v.doubleValue }
        if let v = dict["subtitle_color"] as? String { p.color = v }
        if let v = dict["subtitle_style"] as? String { p.style = v }
        if let v = dict["subtitle_mode"] as? String { p.mode = v }
        if let v = dict["pip_style"] as? String { p.pip = v }
        if let v = dict["tts"] as? Bool { p.tts = v }
        if let v = dict["speech_rate"] as? NSNumber { p.speechRate = v.doubleValue }
        if let v = dict["source_lang"] as? String { p.sourceLang = v }
        if let v = dict["dest_lang"] as? String { p.destLang = v }
        return p
    }

    // MARK: - 颜色映射

    var uiColor: UIColor {
        switch color {
        case "yellow": return UIColor(red: 1.0, green: 0.85, blue: 0.30, alpha: 1)
        case "cyan": return UIColor(red: 0.40, green: 0.90, blue: 0.95, alpha: 1)
        case "green": return UIColor(red: 0.55, green: 0.95, blue: 0.65, alpha: 1)
        case "black": return UIColor.black
        default: return UIColor.white
        }
    }

    var swiftUIColor: Color { Color(uiColor: uiColor) }

    /// 颜色名给设置页显示
    static let colorOptions: [(String, String)] = [
        ("white", "白色"), ("yellow", "暖黄"), ("cyan", "青色"), ("green", "浅绿"), ("black", "黑色"),
    ]

    static let modeOptions: [(String, String)] = [
        ("bilingual", "双语（原文 + 中文）"), ("zh", "仅中文"), ("source", "仅原文"),
    ]

    static let styleOptions: [(String, String)] = [
        ("shadow", "描边阴影"), ("box", "半透明底板"), ("plain", "纯文字"),
    ]

    static let pipOptions: [(String, String)] = [
        ("bar", "横条（推荐，一句一行）"), ("standard", "大窗（4:3）"),
    ]

    static let sourceLanguages: [(String, String)] = [
        ("auto", "自动识别"),
        ("zh", "中文"), ("en", "English"), ("ja", "日本語"), ("ko", "한국어"),
        ("es", "Español"), ("fr", "Français"), ("de", "Deutsch"), ("ru", "Русский"),
        ("pt", "Português"), ("it", "Italiano"), ("ar", "العربية"), ("th", "ไทย"),
        ("vi", "Tiếng Việt"), ("id", "Indonesia"),
    ]
}

/// 字幕渲染参数，App 内和画中画共用
enum SubtitleRender {
    static func font(size: Double) -> UIFont {
        UIFont.systemFont(ofSize: CGFloat(size), weight: .semibold)
    }

    static func apply(to label: UILabel, prefs: SubtitlePrefs, isTranslation: Bool) {
        label.font = font(size: isTranslation ? prefs.size : max(12, prefs.size - 3))
        label.textColor = prefs.uiColor
        label.numberOfLines = 0
        switch prefs.style {
        case "box":
            label.backgroundColor = UIColor.black.withAlphaComponent(0.45)
            label.layer.cornerRadius = 8
            label.layer.masksToBounds = true
            label.layer.shadowOpacity = 0
        case "plain":
            label.backgroundColor = .clear
            label.layer.shadowOpacity = 0
        default:
            label.backgroundColor = .clear
            label.layer.shadowColor = UIColor.black.cgColor
            label.layer.shadowOpacity = 0.85
            label.layer.shadowRadius = 3
            label.layer.shadowOffset = CGSize(width: 0, height: 1)
        }
    }
}
