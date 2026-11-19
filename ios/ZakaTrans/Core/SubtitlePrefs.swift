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
    /// 文字颜色（7 种，全部按弹幕可读性挑的高对比色）
    /// white | yellow | cyan | green | orange | pink | blue
    var color: String = "white"
    /// 字幕背景（7 种实色，画中画里没有透明通道，透明等于没效果，所以一律实色）
    /// black | graphite | navy | forest | wine | indigo | paper
    var background: String = "black"
    /// 语言模式：bilingual（双语）| zh（仅中文）| source（仅原文）
    var mode: String = "bilingual"
    /// 画中画比例：4:3（默认大窗）| 21:9（宽横条）
    var pip: String = "4:3"
    /// 输出音频（把译文读出来）
    var tts: Bool = false
    /// 朗读语速 0.4~0.62（0.5 是系统正常语速）
    var speechRate: Double = 0.54
    /// 原文语言：auto = 让模型自己识别
    var sourceLang: String = "auto"
    /// 译文语言：固定中文
    var destLang: String = "zh"

    static let key = "zt_subtitle_prefs_v4"

    init() {}

    // 老版本的本地存档里没有这些新键，缺哪个就用默认值，
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

        // 旧值映射：以前的 bar/standard、半透明黑/浅色/无背景
        if pip == "bar" { pip = "21:9" }
        else if pip == "standard" { pip = "4:3" }
        else if pip != "21:9" && pip != "4:3" { pip = "4:3" }

        switch background {
        case "dark", "solid": background = "black"
        case "light": background = "paper"
        case "none": background = "black"
        default: break
        }
        if !SubtitlePrefs.backgrounds.contains(where: { $0.0 == background }) { background = "black" }
        if !SubtitlePrefs.colors.contains(where: { $0.0 == color }) { color = "white" }
    }

    static func load() -> SubtitlePrefs {
        for k in [key, "zt_subtitle_prefs_v3", "zt_subtitle_prefs_v2"] {
            if let data = UserDefaults.standard.data(forKey: k),
               var v = try? JSONDecoder().decode(SubtitlePrefs.self, from: data) {
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
        if let v = dict["subtitle_color"] as? String, colors.contains(where: { $0.0 == v }) { p.color = v }
        if let v = dict["subtitle_background"] as? String {
            p.background = (v == "dark" || v == "solid") ? "black"
                         : (v == "light" ? "paper" : (v == "none" ? "black" : v))
        }
        if let v = dict["subtitle_mode"] as? String { p.mode = v }
        if let v = dict["pip_style"] as? String {
            p.pip = (v == "bar" || v == "21:9") ? "21:9" : "4:3"
        }
        if let v = dict["tts"] as? Bool { p.tts = v }
        if let v = dict["speech_rate"] as? NSNumber { p.speechRate = v.doubleValue }
        if let v = dict["source_lang"] as? String { p.sourceLang = v }
        if let v = dict["dest_lang"] as? String { p.destLang = v }
        return p
    }

    // MARK: - 颜色

    var uiColor: UIColor { SubtitlePrefs.uiColor(color) }
    var swiftUIColor: Color { Color(uiColor: uiColor) }

    /// 7 种文字色。选的都是弹幕实测里最好读的：白、暖黄、青、亮绿、橙、粉、天蓝。
    /// 共同特点——亮度足够高，压在深色底上不糊，细笔画也不会被吃掉。
    static let colors: [(String, String, UIColor)] = [
        ("white",  "白色", UIColor(white: 1.0, alpha: 1)),
        ("yellow", "暖黄", UIColor(red: 1.00, green: 0.84, blue: 0.25, alpha: 1)),
        ("cyan",   "青色", UIColor(red: 0.30, green: 0.88, blue: 0.96, alpha: 1)),
        ("green",  "亮绿", UIColor(red: 0.44, green: 0.94, blue: 0.56, alpha: 1)),
        ("orange", "橙色", UIColor(red: 1.00, green: 0.64, blue: 0.28, alpha: 1)),
        ("pink",   "粉色", UIColor(red: 1.00, green: 0.58, blue: 0.76, alpha: 1)),
        ("blue",   "天蓝", UIColor(red: 0.42, green: 0.70, blue: 1.00, alpha: 1)),
    ]

    static func uiColor(_ name: String) -> UIColor {
        colors.first { $0.0 == name }?.2 ?? UIColor.white
    }

    // MARK: - 背景

    /// 7 种背景色：6 个深色 + 1 个浅色。
    /// 全部是不透明实色——画中画的容器没有真正的透明通道，
    /// 之前那两档「半透明黑 / 无背景」在系统窗口里和纯黑一模一样，等于没做。
    static let backgrounds: [(String, String, UIColor)] = [
        ("black",    "纯黑", UIColor(red: 0.00, green: 0.00, blue: 0.00, alpha: 1)),
        ("graphite", "石墨", UIColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1)),
        ("navy",     "深蓝", UIColor(red: 0.04, green: 0.10, blue: 0.20, alpha: 1)),
        ("forest",   "墨绿", UIColor(red: 0.05, green: 0.14, blue: 0.10, alpha: 1)),
        ("wine",     "酒红", UIColor(red: 0.16, green: 0.05, blue: 0.08, alpha: 1)),
        ("indigo",   "深紫", UIColor(red: 0.10, green: 0.07, blue: 0.18, alpha: 1)),
        ("paper",    "米白", UIColor(red: 0.95, green: 0.95, blue: 0.96, alpha: 1)),
    ]

    static func uiBackground(_ name: String) -> UIColor {
        backgrounds.first { $0.0 == name }?.2 ?? UIColor.black
    }

    var backgroundColor: Color { Color(uiColor: SubtitlePrefs.uiBackground(background)) }

    /// 背景是不是浅色（决定文字要不要翻成深色）
    var isLightBackground: Bool { background == "paper" }

    /// 实际文字颜色：浅底上把彩色压暗，深底上直接用原色。
    /// 这样「白字 + 米白底」这种看不见的组合不会出现。
    var effectiveColor: UIColor {
        let c = uiColor
        guard isLightBackground else { return c }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        if c.getHue(&h, saturation: &s, brightness: &b, alpha: &a) {
            // 保留色相（一眼还能看出是黄还是青），亮度和饱和度压到深色区
            return UIColor(hue: h, saturation: min(1.0, s * 0.85 + 0.12), brightness: 0.32, alpha: 1)
        }
        return UIColor(white: 0.10, alpha: 1)
    }

    /// 原文那行比译文暗一档（同一底色下按 62% 亮度），层次分明又不抢主字幕
    var secondaryColor: UIColor { effectiveColor.withAlphaComponent(0.62) }

    static let colorOptions: [(String, String)] = colors.map { ($0.0, $0.1) }
    static let backgroundOptions: [(String, String)] = backgrounds.map { ($0.0, $0.1) }

    static let modeOptions: [(String, String)] = [
        ("bilingual", "双语"), ("zh", "仅中文"), ("source", "仅原文"),
    ]

    static let pipOptions: [(String, String)] = [
        ("4:3", "4:3"), ("21:9", "21:9"),
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
        label.textColor = isTranslation ? prefs.effectiveColor : prefs.secondaryColor
        label.numberOfLines = 0
        label.backgroundColor = .clear
    }
}
