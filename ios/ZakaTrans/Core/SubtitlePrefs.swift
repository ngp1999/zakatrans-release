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
    /// 画中画窗口大小：
    /// X 小（5:1 1080×216，铺满屏宽只占最下面一条，最不挡画面）
    /// M 中（21:9 840×360，宽条，能站三四行；新用户默认这一档）
    /// B 大（1080×640，又宽又大，一屏能站六七行）
    var pip: String = "M"
    /// 输出音频（把译文读出来）
    var tts: Bool = false
    /// 朗读语速 0.30~0.60（0.5 是系统正常语速）。3.9.5 起整体放慢，默认 0.46
    var speechRate: Double = 0.46
    /// 朗读时把别的 App 声音压低多少（0 = 不压，100 = 系统最大压低量）
    var duckLevel: Double = 60
    /// 朗读音色：空 = 跟随系统中文默认；否则是 AVSpeechSynthesisVoice.identifier
    var voiceId: String = ""
    /// 原文语言：auto = 让模型自己识别
    var sourceLang: String = "auto"
    /// 译文语言：固定中文
    var destLang: String = "zh"
    /// 收音模式：system = 内部收音（系统声音，跟别的 App 播放的声音走）
    ///           mic    = 麦克风收音（跟现场说话走）
    var audioSource: String = "system"
    /// 滚动方式（小窗）：up 叠化（新旧两批交叉淡入淡出）| cut 上切（整批向上切走，新的从下面进来）
    var scrollX: String = "up"
    /// 滚动方式（中窗/大窗）：up 上推（整列上移一格）| segment 逐字（上下两块连续文本，打字机出字，满了整块上推一行）
    var scrollMB: String = "up"

    /// 当前窗口档真正生效的滚动方式
    var scroll: String {
        let v = (pip == "X") ? scrollX : scrollMB
        return SubtitlePrefs.scrollOptions(pip).contains(where: { $0.0 == v }) ? v : "up"
    }

    static func scrollOptions(_ pip: String) -> [(String, String)] {
        pip == "X" ? [("up", "叠化"), ("cut", "上切")]
                   : [("up", "上推"), ("segment", "逐字")]
    }

    static let key = "zt_subtitle_prefs_v6"

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
        // 老版本存下来的 0.58~0.62 念起来偏快，统一收到新的慢速；更低的不动
        let savedRate = try c.decodeIfPresent(Double.self, forKey: .speechRate) ?? d.speechRate
        speechRate = savedRate > 0.52 ? 0.46 : savedRate
        sourceLang = try c.decodeIfPresent(String.self, forKey: .sourceLang) ?? d.sourceLang
        destLang = try c.decodeIfPresent(String.self, forKey: .destLang) ?? d.destLang
        duckLevel = try c.decodeIfPresent(Double.self, forKey: .duckLevel) ?? d.duckLevel
        voiceId = try c.decodeIfPresent(String.self, forKey: .voiceId) ?? d.voiceId
        audioSource = try c.decodeIfPresent(String.self, forKey: .audioSource) ?? d.audioSource
        scrollX = try c.decodeIfPresent(String.self, forKey: .scrollX) ?? d.scrollX
        scrollMB = try c.decodeIfPresent(String.self, forKey: .scrollMB) ?? d.scrollMB
        if scrollX == "push" { scrollX = "cut" }        // 老存档里的「横推」并到「上切」
        if !["up", "cut"].contains(scrollX) { scrollX = "up" }
        if !["up", "segment"].contains(scrollMB) { scrollMB = "up" }

        // 三档的新代码是 X / M / B（以前没用过），老存档的老代码在这里映射一次，
        // 之后写回去的就是新代码，不会二次映射。
        pip = SubtitlePrefs.pipFromLegacy(pip)

        switch background {
        case "dark", "solid": background = "black"
        case "light": background = "paper"
        case "none": background = "black"
        default: break
        }
        if !SubtitlePrefs.backgrounds.contains(where: { $0.0 == background }) { background = "black" }
        if !SubtitlePrefs.colors.contains(where: { $0.0 == color }) { color = "white" }
    }

    /// 老代码 → 新三档：老的「全宽 W」就是现在的小（5:1），
    /// 老的「S 21:9」现在是中，老的「M 16:9」「L 4:3」并到大。
    static func pipFromLegacy(_ v: String) -> String {
        switch v {
        case "X", "M", "B": return v          // 已经是新代码
        case "W", "full", "bar-full": return "X"
        case "S", "21:9", "bar": return "M"
        default: return "B"                    // 老的 M(16:9) / L(4:3)
        }
    }

    static func load() -> SubtitlePrefs {
        var loaded = loadRaw()
        loaded.migrateDefaultsOnce()
        return loaded
    }

    /// 默认值变更只做一次：用户自己后来打开的不动，只是把老默认值换过来。
    /// 现在这一条：输出音频默认关闭（开着一开就抢声音，先关掉更省事）。
    private mutating func migrateDefaultsOnce() {
        let flag = "zt_migrate_tts_off_v379"
        if !UserDefaults.standard.bool(forKey: flag) {
            UserDefaults.standard.set(true, forKey: flag)
            if tts {
                tts = false
                saveLocal()
            }
        }

        // 3.17.0：默认窗型从「小横条」改成「中窗」，滚动方式上推。
        // 只迁一次，还是旧默认（X）的存档升级过来就是中窗；用户自己后来改的不再动。
        let pipFlag = "zt_migrate_pip_m_v3170"
        if !UserDefaults.standard.bool(forKey: pipFlag) {
            UserDefaults.standard.set(true, forKey: pipFlag)
            if pip == "X" {
                pip = "M"
                saveLocal()
            }
        }
    }

    private static func loadRaw() -> SubtitlePrefs {
        // v6 之前默认是大窗（4:3）。现在小（5:1 横条）是默认，老存档一次性迁过来，
        // 其它设置（颜色、背景、朗读）原样保留。
        if UserDefaults.standard.data(forKey: key) == nil {
            for k in ["zt_subtitle_prefs_v5", "zt_subtitle_prefs_v4", "zt_subtitle_prefs_v3", "zt_subtitle_prefs_v2"] {
                if let data = UserDefaults.standard.data(forKey: k),
                   var v = try? JSONDecoder().decode(SubtitlePrefs.self, from: data) {
                    if v.size == 19 { v.size = 20 }
                    v.pip = SubtitlePrefs.pipFromLegacy(v.pip)
                    if v.pip == "B" { v.pip = "X" }      // 老默认窗一并挪到小
                    v.saveLocal()
                    return v
                }
            }
            return SubtitlePrefs()
        }
        if let data = UserDefaults.standard.data(forKey: key),
           var v = try? JSONDecoder().decode(SubtitlePrefs.self, from: data) {
            if v.size == 19 { v.size = 20 }
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
        ZKStore.setSetting("audio_src", v: audioSource)
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
            "duck_level": duckLevel,
            "voice_id": voiceId,
            "source_lang": sourceLang,
            "dest_lang": destLang,
            "audio_source": audioSource,
            "scroll_x": scrollX,
            "scroll_mb": scrollMB,
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
            p.pip = SubtitlePrefs.pipFromLegacy(v)
        }
        if let v = dict["duck_level"] as? NSNumber { p.duckLevel = v.doubleValue }
        if let v = dict["voice_id"] as? String { p.voiceId = v }
        if let v = dict["tts"] as? Bool { p.tts = v }
        if let v = dict["speech_rate"] as? NSNumber { p.speechRate = v.doubleValue }
        if let v = dict["source_lang"] as? String { p.sourceLang = v }
        if let v = dict["dest_lang"] as? String { p.destLang = v }
        if let v = dict["audio_source"] as? String, ["system", "mic"].contains(v) { p.audioSource = v }
        if let v = dict["scroll_x"] as? String {
            // 老账号云端存的「横推」并到「上切」
            p.scrollX = (v == "push") ? "cut" : v
            if !["up", "cut"].contains(p.scrollX) { p.scrollX = "up" }
        }
        if let v = dict["scroll_mb"] as? String, ["up", "segment"].contains(v) { p.scrollMB = v }
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
        // 二号、三号：一个暖褐、一个冷青，跟纯黑、墨绿、深紫都分得开
        ("cocoa",    "深咖", UIColor(red: 0.22, green: 0.14, blue: 0.10, alpha: 1)),
        ("teal",     "深青", UIColor(red: 0.04, green: 0.22, blue: 0.26, alpha: 1)),
        ("forest",   "墨绿", UIColor(red: 0.03, green: 0.28, blue: 0.21, alpha: 1)),
        ("wine",     "酒红", UIColor(red: 0.40, green: 0.04, blue: 0.14, alpha: 1)),
        ("indigo",   "深紫", UIColor(red: 0.20, green: 0.09, blue: 0.44, alpha: 1)),
        ("paper",    "米白", UIColor(red: 0.94, green: 0.94, blue: 0.95, alpha: 1)),
    ]

    /// 老版本存下来的背景键（graphite / navy）映射到新档位，
    /// 升级后不会莫名其妙掉回纯黑。
    private static let legacyBackground: [String: String] = [
        "graphite": "cocoa",
        "navy": "teal",
    ]

    static func uiBackground(_ name: String) -> UIColor {
        let key = legacyBackground[name] ?? name
        return backgrounds.first { $0.0 == key }?.2 ?? UIColor.black
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

    /// 收音模式：内部收音（系统声音）/ 麦克风收音（现场说话）
    static let audioSourceOptions: [(String, String)] = [
        ("system", "内部收音"), ("mic", "麦克风收音"),
    ]

    static let modeOptions: [(String, String)] = [
        ("bilingual", "双语"), ("zh", "仅中文"), ("source", "仅原文"),
    ]

    /// 窗口三档：选哪个，画中画开出来就是多大。小排第一，也是默认。
    static let pipOptions: [(String, String)] = [
        ("X", "小"), ("M", "中"), ("B", "大"),
    ]

    /// 每档的实际尺寸，设置页拿来做说明
    static func pipSizeText(_ v: String) -> String {
        switch v {
        case "M": return "21:9 宽条"
        case "B": return "21:12 大窗"
        default: return "5:1 横条"
        }
    }

    static let sourceLanguages: [(String, String)] = [
        ("auto", "自动识别"),
        ("zh", "中文"), ("en", "英语"), ("ja", "日语"), ("ko", "韩语"),
        ("es", "西班牙语"), ("fr", "法语"), ("de", "德语"), ("ru", "俄语"),
        ("pt", "葡萄牙语"), ("it", "意大利语"), ("ar", "阿拉伯语"), ("th", "泰语"),
        ("vi", "越南语"), ("id", "印尼语"),
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
