import Foundation
import SwiftUI
import AVFoundation

/// 字幕外观偏好。存本地 + 云端：换手机、重装都自动同步回来。
///
/// 显示逻辑集中在这里，画中画（ObjC 层）和 App 内字幕共用同一份设置，
/// 两边不会出现「App 里是双语、画中画是单语」这种不一致。
struct SubtitlePrefs: Codable, Equatable {
    /// 字号（App 内）。画中画按比例缩放。
    var size: Double = 20
    /// 颜色：white | yellow | cyan | green | pink | orange | blue | purple | mint | red
    var color: String = "white"
    /// 背景：none（无）| dark（半透明黑）| solid（纯黑）| light（浅色）
    var background: String = "dark"
    /// 语言模式：bilingual（双语）| zh（仅中文）| source（仅原文）
    var mode: String = "bilingual"
    /// 画中画形态：bar（宽横条，默认）| standard（大窗）
    var pip: String = "bar"
    /// 输出音频（把译文读出来）
    var tts: Bool = false
    /// 朗读语速 0.4~0.62（0.5 是系统正常语速）
    var speechRate: Double = 0.54
    /// 原文语言：auto = 让模型自己识别
    var sourceLang: String = "auto"
    /// 译文语言：固定中文
    var destLang: String = "zh"

    static let key = "zt_subtitle_prefs_v3"

    init() {}

    // 老版本的本地存档里没有 background 这些新键，缺哪个就用默认值，
    // 不能整份丢掉重来（否则用户调好的字号颜色会莫名其妙复位）
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SubtitlePrefs()
        size = try c.decodeIfPresent(Double.self, forKey: .size) ?? d.size
        color = try c.decodeIfPresent(String.self, forKey: .color) ?? d.color
        background = try c.decodeIfPresent(String.self, forKey: .background) ?? d.background
        mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? d.mode
        pip = try c.decodeIfPresent(String.self, forKey: .pip) ?? d.pip
        tts = try c.decodeIfPresent(Bool.self, forKey: .tts) ?? d.tts
        speechRate = try c.decodeIfPresent(Double.self, forKey: .speechRate) ?? d.speechRate
        sourceLang = try c.decodeIfPresent(String.self, forKey: .sourceLang) ?? d.sourceLang
        destLang = try c.decodeIfPresent(String.self, forKey: .destLang) ?? d.destLang
    }

    static func load() -> SubtitlePrefs {
        // 新键读不到时退回上一個版本的存档，尽量不丢设置
        for k in [key, "zt_subtitle_prefs_v2"] {
            if let data = UserDefaults.standard.data(forKey: k),
               var v = try? JSONDecoder().decode(SubtitlePrefs.self, from: data) {
                // 旧版本的默认字号是 19，新版统一到 20；手动调过的其它值保持不动
                if v.size == 19 { v.size = 20 }
                return v
            }
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
            "subtitle_background": background,
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
        if let v = dict["subtitle_background"] as? String { p.background = v }
        if let v = dict["subtitle_mode"] as? String { p.mode = v }
        if let v = dict["pip_style"] as? String { p.pip = v }
        if let v = dict["tts"] as? Bool { p.tts = v }
        if let v = dict["speech_rate"] as? NSNumber { p.speechRate = v.doubleValue }
        if let v = dict["source_lang"] as? String { p.sourceLang = v }
        if let v = dict["dest_lang"] as? String { p.destLang = v }
        return p
    }

    // MARK: - 颜色与背景

    var uiColor: UIColor { SubtitlePrefs.uiColor(color) }

    var swiftUIColor: Color { Color(uiColor: uiColor) }

    static func uiColor(_ name: String) -> UIColor {
        switch name {
        case "yellow": return UIColor(red: 1.00, green: 0.84, blue: 0.28, alpha: 1)
        case "cyan":   return UIColor(red: 0.38, green: 0.90, blue: 0.96, alpha: 1)
        case "green":  return UIColor(red: 0.52, green: 0.95, blue: 0.62, alpha: 1)
        case "pink":   return UIColor(red: 1.00, green: 0.60, blue: 0.78, alpha: 1)
        case "orange": return UIColor(red: 1.00, green: 0.66, blue: 0.32, alpha: 1)
        case "blue":   return UIColor(red: 0.45, green: 0.68, blue: 1.00, alpha: 1)
        case "purple": return UIColor(red: 0.76, green: 0.62, blue: 1.00, alpha: 1)
        case "mint":   return UIColor(red: 0.60, green: 0.96, blue: 0.85, alpha: 1)
        case "red":    return UIColor(red: 1.00, green: 0.48, blue: 0.45, alpha: 1)
        default:       return UIColor.white
        }
    }

    /// 实际底色（App 内和画中画共用）
    func backgroundColor() -> Color {
        switch background {
        case "none":  return Color.clear
        case "solid": return Color.black
        case "light": return Color(red: 0.96, green: 0.96, blue: 0.97)
        default:      return Color.black.opacity(0.86)
        }
    }

    /// 浅色底上文字要换成深色，否则白字看不见
    var effectiveColor: UIColor {
        if background == "light" && (color == "white" || color == "mint") {
            return UIColor(white: 0.10, alpha: 1)
        }
        return uiColor
    }

    /// 颜色名给设置页显示
    static let colorOptions: [(String, String)] = [
        ("white", "白色"), ("yellow", "暖黄"), ("cyan", "青色"), ("green", "绿色"), ("mint", "薄荷"),
        ("pink", "粉色"), ("orange", "橙色"), ("blue", "蓝色"), ("purple", "紫色"), ("red", "红色"),
    ]

    static let modeOptions: [(String, String)] = [
        ("bilingual", "双语（原文 + 中文）"), ("zh", "仅中文"), ("source", "仅原文"),
    ]

    static let backgroundOptions: [(String, String)] = [
        ("dark", "半透明黑"), ("solid", "纯黑"), ("light", "浅色"), ("none", "无背景"),
    ]

    static let pipOptions: [(String, String)] = [
        ("bar", "宽横条（默认，一句话一行）"), ("standard", "大窗（4:3）"),
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
        label.font = font(size: isTranslation ? prefs.size : max(12, prefs.size - 4))
        label.textColor = prefs.effectiveColor
        label.numberOfLines = 0
        label.backgroundColor = .clear
    }
}
