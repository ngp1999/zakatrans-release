import SwiftUI
import QuartzCore

/// 字幕样式：颜色、背景、字幕内容、悬浮窗大小、收音模式。
/// 设置项一律「左边文字、右边控件」排在一行，行与行之间一条细线，好扫读。
/// 上面是一块真预览：窗口比例、字号、行数、滚动方式都跟画中画里一模一样。
struct SubtitleSettingsView: View {
    @ObservedObject private var app = AppState.shared
    /// iPad（宽屏尺寸类）上这块面板是居中的大卡片，内容要按卡片宽居中收窄、高度也要多给，
    /// 不然设置项贴着卡片左右边、底下一截被压着，看着就是「没适配平板」。
    @Environment(\.horizontalSizeClass) private var hSize

    /// 预览里正在往上滚的那几行（中档 / 大档）
    @State private var feed: [PreviewLine] = []
    @State private var ticker: Timer?
    /// 逐字档的打字机（跟真窗口同一个速度：中文 22 字/秒、原文 52 字符/秒）
    @State private var typer: Timer?
    /// 逐字档的两块连续文本：上面一整段译文、下面一整段原文（跟画中画里同一条算法）
    @State private var segZh = TypeBlock()
    @State private var segSrc = TypeBlock()
    /// 逐字档自己往下接的句子下标
    @State private var segIndex = 0
    /// 小档（5:1）：一次上一批，整批换
    @State private var wideIndex = 0
    /// sheet 的高度：量完内容再定，避免系统给一档固定高度、底下留一截空白
    @State private var sheetH: CGFloat = 620
    /// 面板真实可用的宽度。iPad 上弹出来是一张居中的卡片（不是整屏宽），
    /// 预览要是按 UIScreen 的宽算，就会比卡片还宽——右边被裁掉、字号也跟着算错。
    /// 所以宽度一律量出来用，不读屏幕。
    @State private var boxW: CGFloat = 0
    /// 逐字档两块文字已经往上滚了多少（点）。
    /// 目标位置按行算，滚动用一段固定 0.42 秒的 ease-out 跑完——跟真窗口同一套。
    /// 以前把位移交给 SwiftUI 的 .animation 去做，量出来的偏移是半点几，
    /// 五行的量级根本看不出在动，所以手机上看是「没有动画」。
    @State private var zhOff: CGFloat = 0
    @State private var srcOff: CGFloat = 0
    @State private var zhTo: CGFloat = 0
    @State private var srcTo: CGFloat = 0
    @State private var zhFrom: CGFloat = 0
    @State private var srcFrom: CGFloat = 0
    @State private var zhT0: CFTimeInterval = 0
    @State private var srcT0: CFTimeInterval = 0
    @State private var zhRolling = false
    @State private var srcRolling = false
    @State private var rollTimer: Timer?

    private struct PreviewLine: Identifiable, Equatable {
        let id = UUID()
        let zh: String
        let src: String
        /// 逐字（打字机）用：这一行已经露出几个字。Int.max = 全显示
        var zhShown: Int = Int.max
        var srcShown: Int = Int.max
    }

    /// 一整段文本：full 是攒下来的全文，pending 是尾巴上还没长出来的字数。
    private struct TypeBlock: Equatable {
        var full = ""
        /// 尾巴上还没长出来的字数（打字机用）
        var pending: CGFloat = 0
    }

    /// 量高度、算裁几个字——跟真窗口（ZKSegmentView）里那两个方法一字不差。
    private enum SegType {
        static func height(_ t: NSString, font: UIFont, width: CGFloat) -> CGFloat {
            guard t.length > 0, width >= 8 else { return 0 }
            let r = t.boundingRect(
                with: CGSize(width: width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: font],
                context: nil
            )
            return ceil(r.height)
        }

        /// 溢出了就从最前面裁，二分找到「正好装得下」的最小字数，再挪到词/句边界，
        /// 这样头顶消失的是完整的一行，不会从半个词中间断开。
        static func trimCount(_ vis: NSString, font: UIFont, width: CGFloat, boxH: CGFloat) -> Int {
            let n = vis.length
            if n <= 0 { return 0 }
            if height(vis, font: font, width: width) <= boxH + 0.5 { return 0 }
            var lo = 1, hi = n
            while lo < hi {
                let mid = (lo + hi) / 2
                let t = vis.substring(from: mid) as NSString
                if height(t, font: font, width: width) <= boxH + 0.5 { hi = mid } else { lo = mid + 1 }
            }
            var k = lo
            if k >= n { return n }
            let marks = CharacterSet(charactersIn: " \n。，、；：！？.,;:!?")
            var i = k
            let lim = min(n - 1, k + 16)
            while i <= lim {
                if let u = Unicode.Scalar(vis.character(at: i)), marks.contains(u) { k = i + 1; break }
                i += 1
            }
            if k >= n { return n }
            while k < n - 1, vis.character(at: k) == 32 { k += 1 }
            return k
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            FitScroll(cap: scrollCap) {
                VStack(spacing: 12) {
                    // 预览固定按最高那一档占位、下沿对齐：换档时字是往上缩的，
                    // 卡片底边不动，所以后面的设置项一行都不挪。
                    previewSlot
                    lookCard
                    windowCard
                }
                .padding(.horizontal, 16)
                .padding(.top, 2)
                .padding(.bottom, 10)
                // iPad：内容按 620 收窄居中，别把一排控件拉成一整条屏宽
                .frame(maxWidth: hSize == .regular ? 620 : .infinity)
                .frame(maxWidth: .infinity)
                .background(
                    GeometryReader { g in
                        Color.clear
                            .onAppear { fitSheet(g.size.height) }
                            .onChange(of: g.size.height) { fitSheet($0) }
                    }
                )
            }
        }
        .navigationTitle("字幕样式")
        .navigationBarTitleDisplayMode(.inline)
        .presentationDetents(hSize == .regular ? [.large] : [.height(sheetH)])
        .presentationDragIndicator(.visible)
        // 量一下真实可用宽度（iPhone = 屏宽，iPad = 卡片宽）。
        // 挂在 background 上，不参与布局，所以不会把高度量歪。
        .background(
            GeometryReader { g in
                Color.clear
                    .onAppear { if abs(g.size.width - boxW) > 0.5 { boxW = g.size.width } }
                    .onChange(of: g.size.width) { w in
                        if abs(w - boxW) > 0.5 {
                            boxW = w
                            segSync(snap: true)
                        }
                    }
            }
        )
        .onAppear { restartPreview() }
        .onDisappear {
            ticker?.invalidate()
            ticker = nil
            typer?.invalidate()
            typer = nil
            rollTimer?.invalidate()
            rollTimer = nil
        }
        // 换档只改「站几行」，不重建内容：以前这里重播一遍预览，
        // 一换档下面的字整批换掉，看着就是「字在跳」。
        .onChange(of: app.prefs.pip) { _ in
            withAnimation(.easeInOut(duration: 0.22)) { resizeFeed() }
            ensureSegSeed()
            segSync(snap: true)
        }
        .onChange(of: app.prefs.mode) { _ in
            withAnimation(.easeInOut(duration: 0.22)) { resizeFeed() }
            ensureSegSeed()
            segSync(snap: true)
        }
        .onChange(of: app.prefs.scroll) { _ in
            withAnimation(.easeInOut(duration: 0.22)) { resizeFeed() }
            ensureSegSeed()
            segSync(snap: true)
        }
    }

    /// 面板内容最多能有多高：手机按 70% 屏高，平板给到 86%（平板弹的是大卡片，高一点才装得下）。
    private var scrollCap: CGFloat {
        let ratio: CGFloat = hSize == .regular ? 0.86 : 0.70
        // 减掉导航栏（44）和下拉指示条占的高度，别让最后一行被压到 card 底下
        return UIScreen.main.bounds.height * ratio - SafeArea.bottom - 44
    }

    // MARK: - 预览窗口的尺寸

    /// 三档窗口的真实像素，跟画中画里开出来的一致
    private var realDim: CGSize { Self.dim(for: app.prefs.pip) }

    private static func dim(for code: String) -> CGSize {
        switch code {
        case "M": return CGSize(width: 840, height: 360)
        case "B": return CGSize(width: 1080, height: 640)
        default:  return CGSize(width: 1080, height: 216)
        }
    }

    /// 预览框：**一律铺满可用宽度**，高度按各自比例算。
    /// 以前是按高度上限反推缩放比，大窗反而被压窄了——越大越窄，看着就不对。
    private var metrics: (w: CGFloat, h: CGFloat, k: CGFloat) {
        let dim = realDim
        // 卡片左右各 16 的边距，剩下的全给预览，不再额外留白。
        // 宽度优先用实测值：iPad 上卡片比屏幕窄得多，按屏宽算会溢出。
        let full = boxW > 1 ? boxW : UIScreen.main.bounds.width
        let w = max(120, full - 32)
        let k = w / dim.width
        let h = dim.height * k
        // 大窗在 iPad 上能站到 300 出头，上限放到 320；iPhone 本来就到不了这一档。
        let cap: CGFloat = min(320, UIScreen.main.bounds.height * 0.34)
        if h > cap {                       // 只有特别矮的屏才会走到这里
            let k2 = cap / dim.height
            return (dim.width * k2, cap, k2)
        }
        return (w, h, k)
    }

    /// 字号：跟画中画同一套算法（含刚放大的那一档），再乘以预览的缩放比。
    /// 两处必须一模一样，否则用户在设置里看到的和真正跑起来的不一样。
    private func previewFonts(k: CGFloat) -> (zh: CGFloat, src: CGFloat) {
        let dim = realDim
        if app.prefs.pip == "X" {
            let f = min(dim.width / 17.2, dim.height / 3.7)
            let font = max(13.0, min(64.0, f)) * k
            return (font, font * 0.68)
        }
        let scale = max(0.45, min(2.10, sqrt((dim.width * dim.height) / (480.0 * 360.0))))
        // 中窗跟真窗口（PipController 的 ZKFontBoost）抬同一档，两边不同步的话
        // 设置里看到的中窗会比真窗口小一圈。
        let boost: CGFloat = app.prefs.pip == "M" ? 1.16 : 1.0
        let zh = max(12.0, min(74.0, app.prefs.size * scale * 1.35 * boost)) * k
        return (zh, zh * 0.66)
    }

    // MARK: - 预览

    /// 预览槽：高度就是**当前这一档**的高度，卡片上沿贴着标题条，头顶不留白。
    ///
    /// 换档时槽高跟着变，面板高度同时被重算（见 fitSheet），而 sheet 的下沿是钉在
    /// 屏幕底部的——所以视觉上就是「卡片往上长」，下面的设置项在屏幕上纹丝不动。
    /// 以前槽高写死成最大档，小档时头上顶一大块空白，就是用户说的那个洞。
    private var previewSlot: some View {
        let m = metrics
        return ZStack(alignment: .bottom) {
            Color.clear
            previewCard
        }
        .frame(maxWidth: .infinity)
        .frame(height: m.h, alignment: .bottom)
        .animation(.easeInOut(duration: 0.22), value: m.h)
    }

    /// 面板高度跟着内容走：换档时预览高了多少，面板就长多少；
    /// sheet 底边不动，所以多出来的高度全在顶上，画面上就是往上顶一格。
    /// 只在第一次量（0 高度）时跳过，避免出现「先铺满 70% 再缩回去」那一帧空白。
    private func fitSheet(_ content: CGFloat) {
        guard content > 0 else { return }
        let want = 44 + content + SafeArea.bottom + 2
        let h = min(UIScreen.main.bounds.height * 0.94, max(320, want))
        if abs(h - sheetH) > 0.5 { sheetH = h }
    }

    private var previewCard: some View {
        let m = metrics
        return ZStack {
            app.prefs.backgroundColor
            if app.prefs.pip == "X" {
                if app.prefs.scroll == "cut" { wideCutPreview(m) } else { widePreview(m) }
            } else {
                if app.prefs.scroll == "segment" { segmentPreview(m) } else { rollingPreview(m) }
            }
        }
        .frame(width: m.w, height: m.h)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.6)
        )
        .frame(width: m.w)
    }

    /// 小档（5:1）：中文一行在上、原文一行在下；**一行只放一整句**，不跟下一句拼行
    private func widePreview(_ m: (w: CGFloat, h: CGFloat, k: CGFloat)) -> some View {
        let f = previewFonts(k: m.k)
        let a = Self.samples[wideIndex % Self.samples.count]
        // 只显一种语言时用主字号：单语本该更大，不能拿原文那档小字顶上去
        let one = app.prefs.mode != "bilingual"
        return VStack(spacing: max(1, m.h * 0.06)) {
            if app.prefs.mode != "source" {
                Text(a.zh)
                    .font(.system(size: f.zh, weight: .bold))
                    .foregroundStyle(Color(uiColor: app.prefs.effectiveColor))
                    .lineLimit(2)
                    .minimumScaleFactor(1)
                    .multilineTextAlignment(.center)
            }
            if app.prefs.mode != "zh" {
                Text(a.src)
                    .font(.system(size: one ? f.zh : f.src, weight: one ? .bold : .regular))
                    .foregroundStyle(Color(uiColor: app.prefs.secondaryColor))
                    .lineLimit(2)
                    .minimumScaleFactor(1)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding(.horizontal, 6)
        .id(wideIndex)
        .transition(.opacity)
    }

    /// 小档 · 上切：新的一批从下面整体顶上来，老的一批被切出画面顶端。
    /// 跟真窗口（ZKWideView 的 cut 分支）同一个动作、同一个时长（0.24s）。
    private func wideCutPreview(_ m: (w: CGFloat, h: CGFloat, k: CGFloat)) -> some View {
        let f = previewFonts(k: m.k)
        let a = Self.samples[wideIndex % Self.samples.count]
        let one = app.prefs.mode != "bilingual"
        return VStack(spacing: max(1, m.h * 0.06)) {
            if app.prefs.mode != "source" {
                Text(a.zh)
                    .font(.system(size: f.zh, weight: .bold))
                    .foregroundStyle(Color(uiColor: app.prefs.effectiveColor))
                    .lineLimit(2)
                    .minimumScaleFactor(1)
                    .multilineTextAlignment(.center)
            }
            if app.prefs.mode != "zh" {
                Text(a.src)
                    .font(.system(size: one ? f.zh : f.src, weight: one ? .bold : .regular))
                    .foregroundStyle(Color(uiColor: app.prefs.secondaryColor))
                    .lineLimit(2)
                    .minimumScaleFactor(1)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding(.horizontal, 6)
        .id(wideIndex)
        .transition(.asymmetric(insertion: .move(edge: .bottom),
                                removal: .move(edge: .top)))
    }

    /// 中/大档 · 逐字：窗口分上下两块——上面一整段译文、下面一整段原文，各是一段连续文字。
    /// 字一个一个字长出来；一块写满之后，**整块向上推一行**，最上面那一行被切出画面。
    /// 跟真窗口（ZKSegmentView）是同一套算法：同样的行数（中 3 / 大 5）、同样的行高、
    /// 同样的 0.42s 整行上推。绘制也交给 UILabel——以前量用 UIKit、画用 SwiftUI，
    /// 两边行高差半点几，累到第五行就成了「顶上一行被切一半」加「看着没动」。
    private func segmentPreview(_ m: (w: CGFloat, h: CGFloat, k: CGFloat)) -> some View {
        let g = segGeom(m)
        let showT = app.prefs.mode != "source"
        let showS = app.prefs.mode != "zh"
        return ZStack(alignment: .topLeading) {
            Color.clear
            if showT {
                segBlock(segVisible(segZh), geo: g, zh: true)
                    .offset(x: g.padX, y: g.zhY)
            }
            if showS {
                segBlock(segVisible(segSrc), geo: g, zh: false)
                    .offset(x: g.padX, y: g.srcY)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { segSync(snap: true) }
    }

    /// 逐字档的几何：跟真窗口 recalcMetrics 同一套。
    /// 两块各站固定行数，块高 = 行数 × 行高；放不下就压字号（不拿少一行顶上）。
    private struct SegGeom {
        var two = true
        var padX: CGFloat = 0
        var bw: CGFloat = 0
        var inset: CGFloat = 0
        var midGap: CGFloat = 0
        var zhFont = UIFont.systemFont(ofSize: 17, weight: .bold)
        var srcFont = UIFont.systemFont(ofSize: 12)
        var zhLineH: CGFloat = 1
        var srcLineH: CGFloat = 1
        var zhRows = 1
        var srcRows = 1
        var zhH: CGFloat = 0
        var srcH: CGFloat = 0
        var zhY: CGFloat = 0
        var srcY: CGFloat = 0
    }

    private func segGeom(_ m: (w: CGFloat, h: CGFloat, k: CGFloat)) -> SegGeom {
        let f = previewFonts(k: m.k)
        var g = SegGeom()
        g.two = app.prefs.mode == "bilingual"
        g.padX = max(3, m.w * 0.016)
        g.bw = max(8, m.w - g.padX * 2)
        g.inset = max(4, m.h * 0.03)
        let showT = app.prefs.mode != "source"
        let showS = app.prefs.mode != "zh"
        if g.two {
            g.midGap = max(3, f.zh * 0.30)
            let avail = max(10, m.h - g.inset * 2 - g.midGap)
            let rows = app.prefs.pip == "M" ? 3 : 5
            var zh = f.zh
            var i = 0
            while i < 120 {
                let lz = UIFont.systemFont(ofSize: zh, weight: .bold).lineHeight
                let ls = UIFont.systemFont(ofSize: zh * 0.66).lineHeight
                if CGFloat(rows) * (lz + ls) <= avail { break }
                zh -= 0.5
                if zh <= 8 { zh = 8; break }
                i += 1
            }
            g.midGap = max(3, zh * 0.30)
            g.zhFont = .systemFont(ofSize: zh, weight: .bold)
            g.srcFont = .systemFont(ofSize: zh * 0.66)
            g.zhRows = rows
            g.srcRows = rows
            g.zhLineH = max(1, g.zhFont.lineHeight)
            g.srcLineH = max(1, g.srcFont.lineHeight)
            g.zhH = CGFloat(rows) * g.zhLineH
            g.srcH = CGFloat(rows) * g.srcLineH
        } else {
            let avail = max(10, m.h - g.inset * 2)
            g.zhFont = .systemFont(ofSize: f.zh, weight: .bold)
            g.srcFont = g.zhFont
            g.zhLineH = max(1, g.zhFont.lineHeight)
            g.srcLineH = g.zhLineH
            let rows = max(1, Int((avail + 0.5) / g.zhLineH))
            g.zhRows = rows
            g.srcRows = rows
            g.zhH = avail
            g.srcH = avail
        }
        // 两块紧挨着成一组，垂直居中——顶部/底部空白平均分，跟真窗口一样
        let availAll = max(10, m.h - g.inset * 2 - (g.two ? g.midGap : 0))
        let groupH = (showT ? g.zhH : 0) + (showS ? g.srcH : 0) + ((showT && showS) ? g.midGap : 0)
        let top = g.inset + max(0, (availAll - groupH) / 2)
        g.zhY = top
        g.srcY = top + (showT ? g.zhH + (showS ? g.midGap : 0) : 0)
        return g
    }

    /// 一块连续文本：交给 UILabel 画，量高度和画出来的是同一个对象，一个点都不差。
    /// 整块往上挪多少由外面的逐帧滚动给（off），每次正好一行。
    private func segBlock(_ text: String, geo: SegGeom, zh: Bool) -> some View {
        SegBlockLabel(
            text: text,
            font: zh ? geo.zhFont : geo.srcFont,
            color: zh ? app.prefs.effectiveColor : app.prefs.secondaryColor,
            boxW: geo.bw,
            boxH: zh ? geo.zhH : geo.srcH,
            rows: zh ? geo.zhRows : geo.srcRows,
            lineH: zh ? geo.zhLineH : geo.srcLineH,
            off: zh ? zhOff : srcOff
        )
        .frame(width: geo.bw, height: zh ? geo.zhH : geo.srcH, alignment: .topLeading)
    }

    // MARK: - 逐字档：量、画、滚动都跟真窗口对齐

    /// 一块文字。画和量都是这一个 UILabel，所以「能站几行」「切在第几行」两边完全一致。
    private struct SegBlockLabel: UIViewRepresentable {
        var text: String
        var font: UIFont
        var color: UIColor
        var boxW: CGFloat
        var boxH: CGFloat
        var rows: Int
        var lineH: CGFloat
        var off: CGFloat

        func makeUIView(context: Context) -> UIView {
            let v = UIView()
            v.clipsToBounds = true
            v.backgroundColor = .clear
            v.isUserInteractionEnabled = false
            let l = UILabel()
            l.tag = 21
            l.numberOfLines = 0
            l.lineBreakMode = .byWordWrapping
            l.textAlignment = .left
            l.adjustsFontSizeToFitWidth = false
            l.backgroundColor = .clear
            l.isOpaque = false
            l.isUserInteractionEnabled = false
            v.addSubview(l)
            return v
        }

        func updateUIView(_ v: UIView, context: Context) {
            guard let l = v.viewWithTag(21) as? UILabel else { return }
            if l.font.pointSize != font.pointSize || l.font.fontDescriptor.symbolicTraits != font.fontDescriptor.symbolicTraits {
                l.font = font
            }
            l.textColor = color
            if l.text != text { l.text = text }
            let w = max(1, boxW)
            let h = l.sizeThatFits(CGSize(width: w, height: .greatestFiniteMagnitude)).height
            // 块高是「行数 × 行高」，余量恒定；整块往上挪 off，正好是一整行
            let pad = max(0, boxH - CGFloat(max(1, rows)) * lineH)
            l.frame = CGRect(x: 0, y: -off + pad, width: w, height: max(h, lineH))
        }
    }

    /// 目标位置 = 内容高 - 站的行数 × 行高。内容多一行，目标就多一个行高，
    /// 所以每次正好往上走一行、头顶那一行被裁掉。
    private func segTarget(_ text: String, font: UIFont, width: CGFloat,
                           rows: Int, lineH: CGFloat) -> CGFloat {
        let h = SegType.height(text as NSString, font: font, width: width)
        return max(0, h - CGFloat(max(1, rows)) * lineH)
    }

    /// 内容变了之后对一次位：在逐字档才动，其它档位不用管。
    private func segSync(snap: Bool = false) {
        guard app.prefs.scroll == "segment", app.prefs.pip != "X" else { return }
        let g = segGeom(metrics)
        if app.prefs.mode != "source" {
            let t = segTarget(segVisible(segZh), font: g.zhFont, width: g.bw,
                              rows: g.zhRows, lineH: g.zhLineH)
            aimZh(t, lineH: g.zhLineH, snap: snap)
        }
        if app.prefs.mode != "zh" {
            let t = segTarget(segVisible(segSrc), font: g.srcFont, width: g.bw,
                              rows: g.srcRows, lineH: g.srcLineH)
            aimSrc(t, lineH: g.srcLineH, snap: snap)
        }
    }

    private func aimZh(_ t: CGFloat, lineH: CGFloat, snap: Bool) {
        if snap { zhTo = t; zhOff = t; zhRolling = false; return }
        if abs(t - zhTo) < 0.5 { return }
        zhTo = t
        if abs(t - zhOff) > lineH * 6 { zhOff = t; zhRolling = false; return }
        if zhRolling { return }
        zhRolling = true
        zhFrom = zhOff
        zhT0 = CACurrentMediaTime()
        ensureRollTimer()
    }

    private func aimSrc(_ t: CGFloat, lineH: CGFloat, snap: Bool) {
        if snap { srcTo = t; srcOff = t; srcRolling = false; return }
        if abs(t - srcTo) < 0.5 { return }
        srcTo = t
        if abs(t - srcOff) > lineH * 6 { srcOff = t; srcRolling = false; return }
        if srcRolling { return }
        srcRolling = true
        srcFrom = srcOff
        srcT0 = CACurrentMediaTime()
        ensureRollTimer()
    }

    private func ensureRollTimer() {
        guard rollTimer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { _ in rollTick() }
        RunLoop.main.add(t, forMode: .common)
        rollTimer = t
    }

    /// 逐帧推一行：0.42 秒、ease-out，跟真窗口那条 kZKRowRollDuration 一致。
    private func rollTick() {
        let now = CACurrentMediaTime()
        var moving = false
        if zhRolling {
            let p = min(1, max(0, (now - zhT0) / 0.42))
            let e = 1 - pow(1 - p, 3)
            zhOff = zhFrom + (zhTo - zhFrom) * e
            if p >= 1 { zhOff = zhTo; zhRolling = false }
            moving = true
        }
        if srcRolling {
            let p = min(1, max(0, (now - srcT0) / 0.42))
            let e = 1 - pow(1 - p, 3)
            srcOff = srcFrom + (srcTo - srcFrom) * e
            if p >= 1 { srcOff = srcTo; srcRolling = false }
            moving = true
        }
        if !moving {
            rollTimer?.invalidate()
            rollTimer = nil
        }
    }

    /// 屏幕上该显示的那一段：整段里扣掉尾巴还没长出来的。
    private func segVisible(_ b: TypeBlock) -> String {
        let s = b.full as NSString
        let n = s.length
        let to = max(0, n - Int(b.pending.rounded(.down)))
        return s.substring(with: NSRange(location: 0, length: min(to, n)))
    }

    /// 一格内「译文 + 原文」之间的空隙，跟真窗口 ZKPairGap 是同一个公式。
    private func pairGap(_ slot: CGFloat) -> CGFloat {
        max(2, min(8, slot * 0.05))
    }

    /// 上推档的字号：双语时真窗口会按格高把主字号压下来（一格要站一行译文 + 一行原文），
    /// 不然大窗站 5 行时原文那行会溢出到下一格。预览必须压得一模一样，否则两边看着就不一样。
    private func rollingFonts(_ m: (w: CGFloat, h: CGFloat, k: CGFloat)) -> (zh: CGFloat, src: CGFloat) {
        let f = previewFonts(k: m.k)
        guard app.prefs.mode == "bilingual" else { return f }
        let slot = slotHeight(m)
        let maxFont = max(12, (slot - pairGap(slot) - 2) / 2)
        if f.zh > maxFont { return (maxFont, maxFont * 0.66) }
        return f
    }

    /// 中档 / 大档 · 上推：一行一句，新句从底下进来，整列被它顶着往上一格。
    /// 行高按窗口均分（见 slotHeight）——整列铺满，顶上不会留那一截空白。
    /// 动画用 ease-out（跟真窗口那条逐帧插值一个手感），不再带淡入：闪一下也叫卡。
    private func rollingPreview(_ m: (w: CGFloat, h: CGFloat, k: CGFloat)) -> some View {
        let f = rollingFonts(m)
        let single = app.prefs.mode != "bilingual"
        let slot = slotHeight(m)
        let gap = max(2, m.h * 0.012)
        let rows = Array(feed.suffix(visibleRows))
        return VStack(alignment: .leading, spacing: gap) {
            ForEach(rows) { it in
                VStack(alignment: .leading, spacing: single ? max(0.5, m.h * 0.004) : pairGap(slot)) {
                    if app.prefs.mode != "source" {
                        Text(it.zh)
                            .font(.system(size: f.zh, weight: .bold))
                            .foregroundStyle(Color(uiColor: app.prefs.effectiveColor))
                            .lineLimit(single ? 2 : 1)
                            .minimumScaleFactor(single ? 1 : 0.5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if app.prefs.mode != "zh" {
                        // 只显原文时用主字号（不是原文那档小字），并允许多占一行
                        Text(it.src)
                            .font(.system(size: single ? f.zh : f.src, weight: single ? .bold : .regular))
                            .foregroundStyle(Color(uiColor: app.prefs.secondaryColor))
                            .lineLimit(single ? 2 : 1)
                            .minimumScaleFactor(single ? 1 : 0.5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(height: slot, alignment: .center)
                .transition(.asymmetric(
                    insertion: .move(edge: .bottom),
                    removal: .move(edge: .top)
                ))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .clipped()
    }

    /// 每格多高：窗口高度扣掉边距、按行数均分。真窗口（ZKRowStack）用的是同一个算法，
    /// 两边看到的行高、行距完全一样。
    private func slotHeight(_ m: (w: CGFloat, h: CGFloat, k: CGFloat)) -> CGFloat {
        let n = CGFloat(max(1, visibleRows))
        let gap = max(2, m.h * 0.012)
        let inset = max(4, m.h * 0.03)
        return max(8, (m.h - inset * 2 - (n - 1) * gap) / n)
    }

    /// 这块窗口站几行：跟真窗口（ZKRowStack.recalcMetrics）用的是同一套算法。
    /// 双语：中窗 3 行（3 行原文 + 3 行译文）、大窗 5 行（5 行原文 + 5 行译文），
    /// 格高由窗口均分，整列铺满——所以顶上不会有那截空白。
    /// 只显一种语言时字大，按高度放宽。
    private var visibleRows: Int {
        let m = metrics
        let f = previewFonts(k: m.k)
        let inset = max(4, m.h * 0.03)
        if app.prefs.mode == "bilingual" {
            return app.prefs.pip == "M" ? 3 : 5
        }
        let n = Int((m.h - inset * 2) / max(1, f.zh * 1.5))
        return min(6, max(2, n))
    }

    /// 换档时按新的行数增删，锚定最下面那句不动。
    private func resizeFeed() {
        guard app.prefs.pip != "X" else { return }
        let n = visibleRows
        if feed.isEmpty { feed = Self.tail(count: n, endingAt: 0); return }
        var out = feed
        while out.count > n { out.removeFirst() }
        while out.count < n, let first = out.first, let i = Self.indexOf(first) {
            let idx = wrap(i - 1)
            out.insert(PreviewLine(zh: Self.samples[idx].zh, src: Self.samples[idx].src), at: 0)
        }
        feed = out
    }

    private func restartPreview() {
        ticker?.invalidate()
        ticker = nil
        typer?.invalidate()
        typer = nil
        feed = Self.tail(count: visibleRows, endingAt: 0)
        wideIndex = 0
        segZh = TypeBlock()
        segSrc = TypeBlock()
        segIndex = 0
        zhOff = 0
        srcOff = 0
        zhTo = 0
        srcTo = 0
        zhRolling = false
        srcRolling = false
        rollTimer?.invalidate()
        rollTimer = nil
        seedSeg()
        seedSeg()
        segSync(snap: true)
        let t = Timer.scheduledTimer(withTimeInterval: 2.7, repeats: true) { _ in
            advance()
        }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    private func advance() {
        if app.prefs.pip == "X" {
            // 小窗：叠化 0.30s（新旧交叉淡入淡出）／上切 0.24s（新一批从下顶上来），
            // 时长跟真窗口一致
            if app.prefs.scroll == "cut" {
                withAnimation(.easeOut(duration: 0.24)) { wideIndex += 1 }
            } else {
                withAnimation(.easeInOut(duration: 0.30)) { wideIndex += 1 }
            }
            return
        }
        if app.prefs.scroll == "segment" {
            segNextSentence()
            return
        }
        let next = (feed.last.flatMap { Self.indexOf($0) } ?? -1) + 1
        let line = PreviewLine(zh: Self.samples[wrap(next)].zh, src: Self.samples[wrap(next)].src)
        // ease-out 0.46s：跟真窗口那条逐帧插值同一个节奏（先快后稳，不是匀速滑过去）
        withAnimation(.easeOut(duration: 0.46)) {
            if feed.count >= visibleRows { feed.removeFirst() }
            feed.append(line)
        }
    }

    // MARK: - 逐字（打字机）

    /// 往两段文本的尾巴上接一句，不设位移——字是自己长出来的。
    ///
    /// 跟真窗口（ZKSegmentView 的 ZKSegAppend）同一套：标点一律转成「，」，
    /// 句子之间也用一个逗号接上。译文和原文都走这条，两块文字的节奏才一致。
    private func segJoin(_ buf: String, _ s: String) -> String {
        let t = segCommafy(s)
        if t.isEmpty { return buf }
        if buf.isEmpty { return t }
        if buf.hasSuffix(t) { return buf }
        return buf + "，" + t
    }

    /// 句号、问号、叹号、分号、冒号、省略号 → 逗号；连续逗号只留一个，首尾不留。
    private func segCommafy(_ s: String) -> String {
        var out = ""
        for ch in s {
            let o: Character = "。！？.!?;:；：…".contains(ch) ? "，" : ch
            if o == "，" {
                if out.isEmpty { continue }
                if let last = out.last, "， \u{3000}\n".contains(last) { continue }
            }
            out.append(o)
        }
        while let last = out.last, "， \u{3000}\n".contains(last) { out.removeLast() }
        return out
    }

    /// 垫一句进去（已经全显示，不参与打字）
    private func seedSeg() {
        let s = Self.samples[wrap(segIndex)]
        segIndex = wrap(segIndex + 1)
        if app.prefs.mode != "source" { segZh.full = segJoin(segZh.full, s.zh) }
        if app.prefs.mode != "zh" { segSrc.full = segJoin(segSrc.full, s.src) }
    }

    private func segNextSentence() {
        let s = Self.samples[wrap(segIndex)]
        segIndex = wrap(segIndex + 1)
        if app.prefs.mode != "source" {
            segZh.full = segJoin(segZh.full, s.zh)
            segZh.pending += CGFloat((s.zh as NSString).length)
        }
        if app.prefs.mode != "zh" {
            segSrc.full = segJoin(segSrc.full, s.src)
            segSrc.pending += CGFloat((s.src as NSString).length)
        }
        startTyping()
        segSync()
    }

    /// 逐字档打字机：译文 22 字/秒、原文 52 字符/秒，落后了会自动快一点（是变速，不是跳字）。
    private func startTyping() {
        if typer != nil { return }
        let t = Timer(timeInterval: 0.05, repeats: true) { timer in
            guard app.prefs.scroll == "segment" else {
                timer.invalidate()
                typer = nil
                return
            }
            var z = segZh
            var r = segSrc
            var changed = false
            if z.pending > 0 {
                let boost = min(4, 1 + max(0, z.pending - 12) / 24)
                z.pending = max(0, z.pending - 0.05 * 22 * boost)
                changed = true
            }
            if r.pending > 0 {
                let boost = min(4, 1 + max(0, r.pending - 24) / 40)
                r.pending = max(0, r.pending - 0.05 * 52 * boost)
                changed = true
            }
            if z.pending <= 0.5 { z.pending = 0 }
            if r.pending <= 0.5 { r.pending = 0 }
            if changed {
                segZh = z
                segSrc = r
                segSync()
            }
            if z.pending <= 0 && r.pending <= 0 {
                timer.invalidate()
                typer = nil
            }
        }
        RunLoop.main.add(t, forMode: .common)
        typer = t
    }

    /// 换到逐字档、或者换档之后，块里没东西就垫两句，别让预览空着
    private func ensureSegSeed() {
        guard app.prefs.scroll == "segment", app.prefs.pip != "X" else { return }
        if segZh.full.isEmpty && segSrc.full.isEmpty {
            seedSeg()
            seedSeg()
        }
        startTyping()
    }

    private func wrap(_ i: Int) -> Int {
        let n = Self.samples.count
        return ((i % n) + n) % n
    }

    private static func indexOf(_ line: PreviewLine) -> Int? {
        samples.firstIndex { $0.zh == line.zh }
    }

    /// 从 endingAt 这一句往前数 count 行（最后一句在最下面）
    private static func tail(count: Int, endingAt end: Int) -> [PreviewLine] {
        var out: [PreviewLine] = []
        for i in stride(from: count - 1, through: 0, by: -1) {
            let idx = ((end - i) % samples.count + samples.count) % samples.count
            out.append(PreviewLine(zh: samples[idx].zh, src: samples[idx].src))
        }
        return out
    }

    /// 预览念的这段：安静积累的那类励志文字，句子长短都有，正好试排版
    private static let samples: [(zh: String, src: String)] = [
        ("学会和生活里的平淡相处。", "Learn to live with the ordinariness of life."),
        ("不必时刻追求轰轰烈烈的进展。", "No need to chase dramatic progress all the time."),
        ("不用因为日子缺少惊喜就觉得失落。", "Don't feel lost just because days lack surprises."),
        ("我们大多时候都处在安静积累的阶段。", "Most of the time we are quietly accumulating."),
        ("不用强迫自己每天都有亮眼的收获。", "Don't force yourself to shine every single day."),
        ("不用拿短暂的结果评判自己的付出。", "Don't judge your effort by short-term results."),
        ("守住内心的安稳 专注手中的事情。", "Keep an inner calm and focus on the task at hand."),
        ("不用被外界嘈杂的声音打乱步调。", "Don't let the noise outside break your pace."),
        ("不用跟风追赶别人前行的速度。", "No need to chase the speed others are moving at."),
        ("允许过程缓慢 允许暂时没有回响。", "Allow slow progress, allow no echo for a while."),
        ("允许自己偶尔疲惫 偶尔陷入迷茫。", "Allow yourself to be tired, to feel lost sometimes."),
        ("不用一没有起色就着急否定自己。", "Don't rush to deny yourself when nothing shows yet."),
        ("把注意力放回当下要完成的小事。", "Bring your attention back to the small thing at hand."),
        ("保持松弛而坚定的状态慢慢往前走。", "Stay relaxed but steady, and keep moving."),
        ("不用预想未来所有未知的困难。", "Don't pre-imagine every unknown difficulty ahead."),
        ("也不用纠结当下一时的得失起落。", "Don't agonize over momentary gains and losses."),
        ("只要持续做该做的事 不轻易停下。", "Just keep doing what should be done, don't stop easily."),
        ("慢慢就会发现很多改变都在悄悄发生。", "Slowly you'll find many changes happening quietly."),
        ("那些安静度过的时光从不会被辜负。", "The quiet hours you spend are never wasted."),
        ("它们一点点沉淀下来 成为前行的底气。", "They settle bit by bit and become your strength."),
    ]

    // MARK: - 外观

    private var lookCard: some View {
        VStack(spacing: 0) {
            settingRow(label: "字体颜色") {
                HStack(spacing: 6) {
                    ForEach(SubtitlePrefs.colors, id: \.0) { opt in
                        Button {
                            Haptics.tap()
                            withAnimation(.easeOut(duration: 0.14)) {
                                app.updatePrefs { $0.color = opt.0 }
                            }
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(Color(uiColor: opt.2))
                                    .frame(width: 24, height: 24)
                                    .overlay(
                                        Circle().strokeBorder(
                                            app.prefs.color == opt.0 ? Theme.ink : Color(uiColor: .separator),
                                            lineWidth: app.prefs.color == opt.0 ? 2 : 0.8
                                        )
                                    )
                                    .overlay(
                                        // 选中的再加一圈外环，圆圈小的时候也一眼看得出选的是哪个
                                        Circle()
                                            .strokeBorder(Theme.ink.opacity(app.prefs.color == opt.0 ? 0.18 : 0),
                                                          lineWidth: 3)
                                            .frame(width: 30, height: 30)
                                    )
                            }
                            .frame(maxWidth: .infinity)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            divider

            settingRow(label: "背景颜色") {
                HStack(spacing: 7) {
                    ForEach(SubtitlePrefs.backgrounds, id: \.0) { opt in
                        Button {
                            Haptics.tap()
                            withAnimation(.easeOut(duration: 0.14)) {
                                app.updatePrefs { $0.background = opt.0 }
                            }
                        } label: {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Color(uiColor: opt.2))
                                .frame(maxWidth: .infinity)
                                .frame(height: 26)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(
                                        app.prefs.background == opt.0 ? Theme.ink : Color(uiColor: .separator),
                                        lineWidth: app.prefs.background == opt.0 ? 2 : 0.7
                                    )
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            divider

            settingRow(label: "字幕内容") {
                Picker("字幕内容", selection: Binding(
                    get: { app.prefs.mode },
                    set: { v in app.updatePrefs { $0.mode = v } }
                )) {
                    ForEach(SubtitlePrefs.modeOptions, id: \.0) { opt in
                        Text(opt.1).tag(opt.0)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
        .card(padding: 14)
    }

    // MARK: - 窗口与收音

    private var windowCard: some View {
        VStack(spacing: 0) {
            settingRow(label: "浮窗大小") {
                Picker("窗口大小", selection: Binding(
                    get: { app.prefs.pip },
                    set: { v in
                        Haptics.tap()
                        app.updatePrefs { $0.pip = v }
                        app.setPip(true)
                    }
                )) {
                    ForEach(SubtitlePrefs.pipOptions, id: \.0) { opt in
                        Text(opt.1).tag(opt.0)
                    }
                }
                .pickerStyle(.segmented)
            }

            divider

            settingRow(label: "滚动方式") {
                Picker("滚动方式", selection: Binding(
                    get: { app.prefs.scroll },
                    set: { v in
                        Haptics.tap()
                        app.updatePrefs { p in
                            if p.pip == "X" { p.scrollX = v } else { p.scrollMB = v }
                        }
                    }
                )) {
                    // 选项跟着浮窗档位走：小窗是「叠化 / 上切」，中窗大窗是「上推 / 逐字」
                    ForEach(SubtitlePrefs.scrollOptions(app.prefs.pip), id: \.0) { opt in
                        Text(opt.1).tag(opt.0)
                    }
                }
                .pickerStyle(.segmented)
            }

            divider

            settingRow(label: "收音模式") {
                Picker("收音模式", selection: Binding(
                    get: { app.prefs.audioSource },
                    set: { v in
                        Haptics.tap()
                        app.updatePrefs { $0.audioSource = v }
                    }
                )) {
                    ForEach(SubtitlePrefs.audioSourceOptions, id: \.0) { opt in
                        Text(opt.1).tag(opt.0)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
        .card(padding: 14)
    }

    // MARK: - 行

    /// 统一的行：左边说明文字（固定宽，上下行对齐），右边控件撑满剩下的宽度
    private func settingRow<Content: View>(label: String,
                                          @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: DSSpace.s) {
            Text(label)
                .font(DSFont.subheadline)
                .foregroundStyle(DSColor.label)
                .frame(width: 68, alignment: .leading)
            content()
                .frame(maxWidth: .infinity)
        }
        .frame(minHeight: DSSpace.rowMinHeight)
        .padding(.vertical, 2)
    }

    private var divider: some View {
        Rectangle().fill(DSColor.separator).frame(height: 0.5)
    }
}
