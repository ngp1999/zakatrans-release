#import "PipController.h"
#import <AVKit/AVKit.h>
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>
#import "Shared.h"

#pragma mark - 字幕视图（连续上推 · 零动画）

// 显示方式：说过的话 + 正在说的那句，是同一条连续的文本流。
// 正在说的那句不是"另贴一行"，它就是流的最后一块，随文字出字而变高，
// 于是整条流每 30~50ms 往上顶一点点——位移是连续的小步，不是"攒够一句再跳一大格"。
//
// v11 为什么把动画全删了：
// 画中画的内容视图跑在后台，UIView/CoreAnimation 的位移动画在后台会被系统降频甚至直接
// 不跑——上一版用 0.28s 的动画滚一段，实际表现是"先不动，然后猛地跳到位"，
// 用户看到的就是"一跳一跳"。既然动画靠不住，就改成让内容自己连续增长：
// 每次位移只有几个像素到一行高，同步改 offset，不需要动画帧也一样顺。
//
// 另外这版不再画那个闪烁光标（▍），也不再给新块做淡入——两者都会引起重排/重绘。

static const CGFloat ZK_ZH_SIZE = 20.0;
static const CGFloat ZK_EN_SIZE = 13.0;

// 字幕外观（从 App 的字幕设置同步过来）
static CGFloat gZhSize = 20.0;        // 当前真正生效的字号（会随画中画窗口大小自动变）
static CGFloat gEnSize = 13.0;
static CGFloat gZhBase = 20.0;        // 用户在设置里选的字号：自适应以它为中心放大/缩小
static UIColor *gTextColor = nil;
static NSString *gMode = @"bilingual";         // bilingual | zh | source
static NSString *gBackground = @"black";       // 7 种实色背景，见 ZKBackgroundColor()
static CGSize gPipSize = {480, 360};           // 4:3 大窗（默认）
// 小窗兜底：窗口被拖得很小、字号已压到下限还是放不下时，原文限行（0 = 不限）。
// 优先保住中文主字幕的完整，原文宁可截一行，也不把两个字都缩到看不清。
static NSInteger gEnMaxLines = 0;
static const CGFloat ZK_PARA_GAP = 14.0;      // 句与句之间的空档
static const CGFloat ZK_MAX_BLOCKS = 120.0;   // 历史句上限（正常一场对话到不了）

// 滚动弹簧：固有频率越高追得越快（临界阻尼下约 4/ω 秒到位）。
// 22 ≈ 0.18s 到位，正好把"一行文字长出来"那 25 点的落差摊成一段连续位移。
// 大位移（重建、画中画被缩放）用慢一档的，看得清也更有质感。
static const CGFloat ZK_SPRING_W = 22.0;
static const CGFloat ZK_SPRING_W_BIG = 13.0;

#pragma mark 一块（一句）

@interface ZKBlockView : UIView
@property (nonatomic, strong) UILabel *zhLabel;
@property (nonatomic, strong) UILabel *enLabel;
@property (nonatomic, assign) CGFloat blockH;
@property (nonatomic, assign) CGFloat zhH;
@property (nonatomic, assign) CGFloat enH;
@property (nonatomic, copy) NSString *zhText;
@property (nonatomic, copy) NSString *enText;
- (void)applyEn:(NSString *)en zh:(NSString *)zh first:(BOOL)first width:(CGFloat)w;
- (void)applyEn:(NSString *)en zh:(NSString *)zh first:(BOOL)first width:(CGFloat)w force:(BOOL)force;
- (void)fadeIn;
@end

@implementation ZKBlockView {
    // 上一帧应用过的内容：文字和宽度都没变就什么都不做。
    // 流式出字时 setLive 调用很密，而给 UILabel 赋 attributedText 必然触发
    // 重新排版 + 重绘（中文粗体 20pt）。这类无谓重排是画中画掉帧、看着"发顿"的常见来源。
    NSString *_appliedEn;
    NSString *_appliedZh;
    CGFloat _appliedW;
    BOOL _appliedFirst;
    NSInteger _appliedMaxLines;
    BOOL _faded;        // 淡入只做一次：这块已经露过脸了就不再闪
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor clearColor];
        self.userInteractionEnabled = NO;
        _zhLabel = [UILabel new];
        _zhLabel.numberOfLines = 0;
        _zhLabel.lineBreakMode = NSLineBreakByWordWrapping;
        _zhLabel.opaque = NO;
        _zhLabel.backgroundColor = [UIColor clearColor];
        _zhLabel.numberOfLines = 0;
        [self addSubview:_zhLabel];

        _enLabel = [UILabel new];
        _enLabel.numberOfLines = 0;
        _enLabel.lineBreakMode = NSLineBreakByWordWrapping;
        _enLabel.opaque = NO;
        _enLabel.backgroundColor = [UIColor clearColor];
        [self addSubview:_enLabel];
    }
    return self;
}

// 属性字典建一次就够：每帧 new 一个 ParagraphStyle + 字典是白扔的内存和 CPU
// 每次按当前设置生成（字幕设置改了要立刻生效，所以不能 dispatch_once 缓存死）
// 浅色底上白字看不见：统一在这里把「白/浅色」翻成深色，两边（App 内和画中画）口径一致
// 浅色底上把彩色文字压暗（保留色相），深色底上直接用原色。
// App 内字幕用的是同一套口径，两边看起来才是一回事。
static BOOL ZKLightBackground(void) {
    return [gBackground isEqualToString:@"paper"];
}

static UIColor *ZKMainColor(void) {
    UIColor *c = gTextColor ?: [UIColor whiteColor];
    if (!ZKLightBackground()) return c;
    CGFloat h = 0, s = 0, b = 0, a = 0;
    if ([c getHue:&h saturation:&s brightness:&b alpha:&a]) {
        return [UIColor colorWithHue:h saturation:MIN(1.0, s * 0.85 + 0.12) brightness:0.32 alpha:1];
    }
    return [UIColor colorWithWhite:0.10 alpha:1];
}

static NSDictionary *ZKZhAttrs(void) {
    NSMutableParagraphStyle *p = [NSMutableParagraphStyle new];
    p.lineSpacing = 2.0;
    p.lineBreakMode = NSLineBreakByWordWrapping;
    p.alignment = NSTextAlignmentLeft;
    return @{
        NSFontAttributeName: [UIFont boldSystemFontOfSize:gZhSize],
        NSForegroundColorAttributeName: ZKMainColor(),
        NSParagraphStyleAttributeName: p,
    };
}

static NSDictionary *ZKEnAttrs(void) {
    NSMutableParagraphStyle *p = [NSMutableParagraphStyle new];
    p.lineSpacing = 1.0;
    p.lineBreakMode = NSLineBreakByWordWrapping;
    p.alignment = NSTextAlignmentLeft;
    // 原文比译文暗一档（62%），不抢主字幕
    return @{
        NSFontAttributeName: [UIFont systemFontOfSize:gEnSize],
        NSForegroundColorAttributeName: [ZKMainColor() colorWithAlphaComponent:0.62],
        NSParagraphStyleAttributeName: p,
    };
}

/// 字幕底色：7 种实色。
/// 画中画的容器没有真正的透明通道，所以不做「半透明 / 无背景」——
/// 那两档在系统窗口里和纯黑一样，做了等于没做，不如全部给成能选的颜色。
static UIColor *ZKBackgroundColor(void) {
    static NSDictionary *map = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        map = @{
            // 必须和 Swift 侧 SubtitlePrefs.backgrounds 逐条一致，
            // 否则「设置里换了底色，画中画没变」——以前两处各写一套，深浅差一点点看不出来。
            @"black":    [UIColor colorWithRed:0.00 green:0.00 blue:0.00 alpha:1],
            @"graphite": [UIColor colorWithRed:0.17 green:0.17 blue:0.19 alpha:1],
            @"navy":     [UIColor colorWithRed:0.03 green:0.17 blue:0.42 alpha:1],
            @"forest":   [UIColor colorWithRed:0.03 green:0.28 blue:0.21 alpha:1],
            @"wine":     [UIColor colorWithRed:0.40 green:0.04 blue:0.14 alpha:1],
            @"indigo":   [UIColor colorWithRed:0.20 green:0.09 blue:0.44 alpha:1],
            @"paper":    [UIColor colorWithRed:0.94 green:0.94 blue:0.95 alpha:1],
            // 老值兜底
            @"dark":     [UIColor blackColor],
            @"solid":    [UIColor blackColor],
            @"none":     [UIColor blackColor],
            @"light":    [UIColor colorWithRed:0.95 green:0.95 blue:0.96 alpha:1],
        };
    });
    return map[gBackground] ?: [UIColor blackColor];
}

// 这个视图只做"内容画在固定位置上"，位置由外层滚动统一控制。
// 关掉它自己的隐式动画，避免和滚动弹簧打架。
- (id<CAAction>)actionForLayer:(CALayer *)layer forKey:(NSString *)event {
    return (id<CAAction>)[NSNull null];
}

- (NSAttributedString *)zhAttr:(NSString *)z {
    if (!z.length) return nil;
    return [[NSAttributedString alloc] initWithString:z attributes:ZKZhAttrs()];
}

- (NSAttributedString *)enAttr:(NSString *)e {
    if (!e.length) return nil;
    return [[NSAttributedString alloc] initWithString:e attributes:ZKEnAttrs()];
}

// 新的一句进场：只做透明度，不动位置、不改 frame —— 位置归滚动那条弹簧管，
// 两者各管一半，才不会互相打架（上一版就是动画和目标位置互相打断，看着一跳一跳）。
// model 值先设成 1：万一后台不执行这条动画，文字也是直接出现，绝不停在半透明。
- (void)fadeIn {
    if (_faded) return;
    _faded = YES;
    self.alpha = 1.0;
    CABasicAnimation *a = [CABasicAnimation animationWithKeyPath:@"opacity"];
    a.fromValue = @(0.0);
    a.toValue = @(1.0);
    a.duration = 0.20;
    a.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
    [self.layer addAnimation:a forKey:@"zkfade"];
}

// 只算自己这一块，跟上面有多少句无关
- (void)applyEn:(NSString *)en zh:(NSString *)zh first:(BOOL)first width:(CGFloat)w {
    [self applyEn:en zh:zh first:first width:w force:NO];
}

- (void)applyEn:(NSString *)en zh:(NSString *)zh first:(BOOL)first width:(CGFloat)w force:(BOOL)force {
    en = en ?: @"";
    zh = zh ?: @"";
    // 语言模式：双语 / 仅中文 / 仅原文
    if ([gMode isEqualToString:@"zh"]) {
        en = @"";
    } else if ([gMode isEqualToString:@"source"]) {
        zh = en;      // 原文当主字幕显示
        en = @"";
    }
    self.enText = en;
    self.zhText = zh;

    // 内容一个字都没变、宽度也没变：上一帧的排版结果直接复用，一次 sizeThatFits 都不做
    // 注意：限行档位（小窗/大窗）也算排版输入的一部分，否则窗口缩小时字号变了却复用了旧排版
    if (!force && _appliedW == w && _appliedFirst == first &&
        _appliedMaxLines == gEnMaxLines &&
        [_appliedEn isEqualToString:en] && [_appliedZh isEqualToString:zh]) {
        return;
    }
    _appliedEn = [en copy];
    _appliedZh = [zh copy];
    _appliedW = w;
    _appliedFirst = first;
    _appliedMaxLines = gEnMaxLines;
    self.enLabel.numberOfLines = gEnMaxLines > 0 ? gEnMaxLines : 0;

    CGFloat padTop = first ? 0 : ZK_PARA_GAP;

    // 底色由「背景」统一控制，文字本身只带一层很淡的阴影（浅色/纯黑底上不显脏）
    // 背景一律实色，文字自带足够对比，不需要投影
    BOOL needShadow = NO;
    for (UILabel *l in @[self.zhLabel, self.enLabel]) {
        l.backgroundColor = [UIColor clearColor];
        l.layer.cornerRadius = 0;
        l.layer.masksToBounds = NO;
        l.layer.shadowOpacity = needShadow ? 0.85 : 0.0;
        l.layer.shadowColor = [UIColor blackColor].CGColor;
        l.layer.shadowRadius = 3;
        l.layer.shadowOffset = CGSizeMake(0, 1);
    }

    NSAttributedString *za = [self zhAttr:zh];
    NSAttributedString *ea = [self enAttr:en];
    self.zhLabel.attributedText = za;
    self.enLabel.attributedText = ea;

    CGFloat zhH = 0, enH = 0;
    if (za && w > 0) {
        zhH = ceil([self.zhLabel sizeThatFits:CGSizeMake(w, CGFLOAT_MAX)].height);
    }
    if (ea && w > 0) {
        enH = ceil([self.enLabel sizeThatFits:CGSizeMake(w, CGFLOAT_MAX)].height);
    }
    if (!isfinite(zhH) || zhH < 0) zhH = 0;
    if (!isfinite(enH) || enH < 0) enH = 0;

    self.zhH = zhH;
    self.enH = enH;
    CGFloat gap = (zhH > 0 && enH > 0) ? 2.0 : 0.0;
    self.blockH = padTop + zhH + gap + enH;

    self.zhLabel.frame = CGRectMake(0, padTop, w, zhH);
    self.enLabel.frame = CGRectMake(0, padTop + zhH + gap, w, enH);
}

@end

#pragma mark 整条流

@interface ZKStreamView : UIView
@property (nonatomic, assign, readonly) CGFloat contentHeight;
- (void)setStreamWidth:(CGFloat)w;
- (void)appendEn:(NSString *)en zh:(NSString *)zh;
- (void)updateTailEn:(NSString *)en zh:(NSString *)zh;
- (void)freezeTailEn:(NSString *)en zh:(NSString *)zh;
- (void)clearTail;
- (void)relayoutAll;
- (void)relayoutAllForce:(BOOL)force;
- (void)rebuildWithLines:(NSArray *)lines;
- (NSString *)liveZhText;
- (NSString *)liveEnText;
@end

@implementation ZKStreamView {
    NSMutableArray<ZKBlockView *> *_blocks;   // 已经说完的句子（落定后一个字都不改）
    ZKBlockView *_tail;                       // 正在说的那一句（就是流的最后一块）
    CGFloat _w;
    BOOL _built;
    CGFloat _tailFloorH;                      // 这一句已经占过的最高高度，只增不减
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _blocks = [NSMutableArray array];
        _tail = [[ZKBlockView alloc] initWithFrame:CGRectZero];
        [self addSubview:_tail];
        self.backgroundColor = [UIColor clearColor];
        self.clipsToBounds = NO;
    }
    return self;
}

- (CGFloat)historyBottom {
    if (!_blocks.count) return 0;
    return CGRectGetMaxY(_blocks.lastObject.frame);
}

- (CGFloat)contentHeight {
    CGFloat hb = [self historyBottom];
    if (!_tail) return hb;
    return hb + _tail.blockH;
}

// 宽度变了（PiP 被拖动缩放）才全量重算；否则一个字都不动
- (void)setStreamWidth:(CGFloat)w {
    if (w <= 0) return;
    if (_built && fabs(w - _w) < 0.5) return;
    _w = w;
    _built = YES;
    [self relayoutAll];
}

- (void)relayoutAll {
    [self relayoutAllForce:NO];
}

// force=YES 时无视"文字没变就复用"的缓存，强制按当前字号重新排版。
// 字号自适应必须走这条：窗口缩放时文字和宽度可能一模一样，只有字号变了，
// 走缓存会直接被 return 掉——那正是「窗口变了但字没变」的根因。
- (void)relayoutAllForce:(BOOL)force {
    CGFloat y = 0;
    NSUInteger i = 0;
    for (ZKBlockView *b in _blocks) {
        [b applyEn:b.enText zh:b.zhText first:(i == 0) width:_w force:force];
        b.frame = CGRectMake(0, y, _w, b.blockH);
        y += b.blockH;
        i++;
    }
    if (_tail) {
        [_tail applyEn:_tail.enText zh:_tail.zhText first:(_blocks.count == 0) width:_w force:force];
        _tailFloorH = _tail.blockH;
        _tail.frame = CGRectMake(0, y, _w, _tail.blockH);
    }
}

- (void)appendEn:(NSString *)en zh:(NSString *)zh {
    if (!en.length && !zh.length) return;
    ZKBlockView *b = [[ZKBlockView alloc] initWithFrame:CGRectZero];
    [b applyEn:en zh:zh first:(_blocks.count == 0) width:_w];
    b.frame = CGRectMake(0, [self historyBottom], _w, b.blockH);
    [self addSubview:b];
    [b fadeIn];
    [_blocks addObject:b];
    [self pruneIfNeeded];
}

// 正在说的那句：就地改内容、就地涨高度。上面已经说完的块一个字都不重排
- (void)updateTailEn:(NSString *)en zh:(NSString *)zh {
    if (!_tail) return;
    CGFloat y = [self historyBottom];
    [_tail applyEn:en zh:zh first:(_blocks.count == 0) width:_w];
    // 这一句第一次露脸：轻轻淡进来，不是"啪"一下蹦出来。
    // 只在全新的一句上做一次，后续逐字增长不再重播，不会闪。
    if (_tail.blockH > 0.5) [_tail fadeIn];
    // 这一句已经占过的高度只增不减，多出来的空白留在底部，画面只往上走。
    if (_tail.blockH < _tailFloorH) _tail.blockH = _tailFloorH;
    else _tailFloorH = _tail.blockH;
    _tail.frame = CGRectMake(0, y, _w, _tail.blockH);
}

// 一句说完了：把"正在说的那块"原样升级成历史块，然后新起一个空的尾巴。
// 因为复用的是同一个 view、同一段文字、同一个位置，落定的那一刻画面没有任何变化
- (void)freezeTailEn:(NSString *)en zh:(NSString *)zh {
    if (!_tail) return;
    if (en.length || zh.length) {
        [_tail applyEn:en zh:zh first:(_blocks.count == 0) width:_w];
        // 定稿译文通常和屏幕上那版字数不同。落定的这一刻块高如果变矮，
        // 画面就会往回缩一下——同样按"占过的高度只增不减"处理
        if (_tail.blockH < _tailFloorH) _tail.blockH = _tailFloorH;
        _tail.frame = CGRectMake(0, [self historyBottom], _w, _tail.blockH);
    }
    if (_tail.blockH > 0.5) {
        [_blocks addObject:_tail];
    }
    _tailFloorH = 0;
    _tail = [[ZKBlockView alloc] initWithFrame:CGRectMake(0, [self historyBottom], _w, 0)];
    [self addSubview:_tail];
    [self pruneIfNeeded];
}

- (void)clearTail {
    if (!_tail) return;
    _tailFloorH = 0;
    [_tail applyEn:nil zh:nil first:(_blocks.count == 0) width:_w];
    _tail.frame = CGRectMake(0, [self historyBottom], _w, 0);
}

// 超出上限就丢掉最老的一块，再把剩下的往上挪——只搬位置，不重算文字
- (void)pruneIfNeeded {
    if (_blocks.count <= (NSUInteger)ZK_MAX_BLOCKS) return;
    ZKBlockView *old = _blocks.firstObject;
    [old removeFromSuperview];
    [_blocks removeObjectAtIndex:0];
    CGFloat y = 0;
    for (ZKBlockView *b in _blocks) {
        b.frame = CGRectMake(0, y, _w, b.blockH);
        y += b.blockH;
    }
    if (_tail) _tail.frame = CGRectMake(0, y, _w, _tail.blockH);
}

// 最后一句（正在说的那句；没有的话就是最后说定的一句）的文本，供字号自适应算高度用
- (NSString *)liveZhText {
    if (_tail && _tail.blockH > 0.5) return _tail.zhText;
    return _blocks.lastObject.zhText;
}

- (NSString *)liveEnText {
    if (_tail && _tail.blockH > 0.5) return _tail.enText;
    return _blocks.lastObject.enText;
}

- (void)rebuildWithLines:(NSArray *)lines {
    for (ZKBlockView *b in _blocks) [b removeFromSuperview];
    [_blocks removeAllObjects];
    if (!_tail) {
        _tail = [[ZKBlockView alloc] initWithFrame:CGRectZero];
        [self addSubview:_tail];
    }
    if ([lines isKindOfClass:[NSArray class]] && lines.count) {
        // 只保留末尾 N 句，一次性建好（启动/重连时才走这条路）
        NSUInteger from = lines.count > (NSUInteger)ZK_MAX_BLOCKS
                            ? lines.count - (NSUInteger)ZK_MAX_BLOCKS : 0;
        for (NSUInteger i = from; i < lines.count; i++) {
            id raw = lines[i];
            if (![raw isKindOfClass:[NSDictionary class]]) continue;
            NSDictionary *d = (NSDictionary *)raw;
            NSString *e = d[@"en"], *z = d[@"zh"];
            if (![e isKindOfClass:[NSString class]]) e = @"";
            if (![z isKindOfClass:[NSString class]]) z = @"";
            if (!e.length && !z.length) continue;
            ZKBlockView *b = [[ZKBlockView alloc] initWithFrame:CGRectZero];
            [b applyEn:e zh:z first:(_blocks.count == 0) width:_w];
            [_blocks addObject:b];
            [self addSubview:b];
        }
    }
    [self relayoutAll];
}

@end

#pragma mark - 字幕控制器

@interface ZKSubtitleVC : UIViewController
@property (nonatomic, strong) UIScrollView *scroll;
@property (nonatomic, strong) ZKStreamView *stream;
@property (nonatomic, strong) UILabel *placeholder;
@property (nonatomic, copy) NSString *liveEn;
@property (nonatomic, copy) NSString *liveZh;
- (void)shutdown;
- (void)refreshStyle;
- (void)rebuildFromLines:(NSArray *)lines;
- (void)appendLine:(NSDictionary *)d;
- (void)setLiveEn:(NSString *)en zh:(NSString *)zh;
- (void)setOffsetY:(CGFloat)y;
- (CGSize)containerSize;
- (void)startSizeProbe;
- (void)stopSizeProbe;
- (void)probeSize:(NSString *)why;
- (void)applyAdaptiveFontForWidth:(CGFloat)w height:(CGFloat)h;
@end

// 按当前宽度量一段文字要占多高（和 UILabel 走同一套换行规则，用来判断放不放得下）
static CGFloat ZKTextHeight(NSString *text, CGFloat width, UIFont *font, CGFloat lineSpacing) {
    if (!text.length || width <= 1) return 0;
    NSMutableParagraphStyle *p = [NSMutableParagraphStyle new];
    p.lineSpacing = lineSpacing;
    p.lineBreakMode = NSLineBreakByWordWrapping;
    NSDictionary *attrs = @{NSFontAttributeName: font, NSParagraphStyleAttributeName: p};
    CGRect r = [text boundingRectWithSize:CGSizeMake(width, CGFLOAT_MAX)
                                 options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading
                              attributes:attrs
                                 context:nil];
    CGFloat h = ceil(r.size.height);
    return isfinite(h) && h > 0 ? h : 0;
}

// 限行版：maxLines > 0 表示 UILabel 最多显示这么多行，高度也不能超过它。
// 小窗兜底要用这个量，否则算出来的高度是"全文高度"，永远判成放不下、字号一路缩到底。
static CGFloat ZKTextHeightLines(NSString *text, CGFloat width, UIFont *font, CGFloat lineSpacing, NSInteger maxLines) {
    CGFloat h = ZKTextHeight(text, width, font, lineSpacing);
    if (maxLines <= 0 || h <= 0) return h;
    CGFloat cap = ceil((font.lineHeight + lineSpacing) * maxLines + 1.0);
    return MIN(h, cap);
}

@implementation ZKSubtitleVC {
    CGFloat _lastLayoutW;
    CGFloat _lastLayoutH;
    // 画中画窗口尺寸探测：系统的 PiP 窗口可以被用户随时拖着放大缩小，
    // 而 viewDidLayoutSubviews 不一定每次都来（后台渲染、系统只换 surface）。
    // 所以这里存一份"上次看到的真实尺寸"，由 布局回调 / 轮询 / 转场回调 三路一起喂。
    CGFloat _probeW;
    CGFloat _probeH;
    NSTimer *_probeTimer;
    NSInteger _adaptMask;       // 上次生效的 (字号×10, 原文限行) 组合，用来判断要不要重排
    NSString *_lastKey;
    NSMutableArray<NSString *> *_recentKeys;
    CADisplayLink *_link;
    CGFloat _targetY;
    CFTimeInterval _lastTickAt;
    BOOL _snapNext;
    CGFloat _vel;          // 当前滚动速度（pt/s），弹簧的第二个状态量
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = ZKBackgroundColor();

    // 刚打开画中画还没收到音频：先给一句占位，别是一片黑让人以为坏了
    self.placeholder = [UILabel new];
    self.placeholder.text = @"等待音频播放";
    self.placeholder.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    self.placeholder.textColor = [UIColor colorWithWhite:1.0 alpha:0.55];
    self.placeholder.textAlignment = NSTextAlignmentCenter;
    self.placeholder.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.placeholder];
    [NSLayoutConstraint activateConstraints:@[
        [self.placeholder.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.placeholder.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
    ]];

    self.scroll = [UIScrollView new];
    self.scroll.showsVerticalScrollIndicator = NO;
    self.scroll.showsHorizontalScrollIndicator = NO;
    self.scroll.alwaysBounceVertical = NO;
    self.scroll.scrollEnabled = NO;          // 自己跟着内容走，不让手滑
    self.scroll.decelerationRate = UIScrollViewDecelerationRateFast;
    self.scroll.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    self.scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.scroll];

    self.stream = [ZKStreamView new];
    [self.scroll addSubview:self.stream];

    UIView *v = self.view;
    [NSLayoutConstraint activateConstraints:@[
        [self.scroll.topAnchor constraintEqualToAnchor:v.topAnchor constant:8],
        [self.scroll.leadingAnchor constraintEqualToAnchor:v.leadingAnchor constant:14],
        [self.scroll.trailingAnchor constraintEqualToAnchor:v.trailingAnchor constant:-14],
        [self.scroll.bottomAnchor constraintEqualToAnchor:v.bottomAnchor constant:-8],
    ]];

    // 逐帧插值：文字是"一行一行"长出来的，直接把 offset 设到目标位置，
    // 每跨一行就是硬跳一格（25 点上下），看着就是一顿一顿。
    // 改成每帧追 30%，约 6~8 帧追平，位移连续；这不是 CA 动画，
    // 不依赖被后台降频的那套补间机制，跑得动就跑，跑不动由 applyGeometry 兜底直接到位。
    _link = [CADisplayLink displayLinkWithTarget:self selector:@selector(onFrame:)];
    _link.paused = YES;
    [_link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];

    // 刚浮出来的那一下：字幕区从下方轻轻滑上来。
    // 用 CABasicAnimation 且 model 值保持原位——万一后台被降频不播，画面也不会卡在偏移处。
    CABasicAnimation *rise = [CABasicAnimation animationWithKeyPath:@"transform.translation.y"];
    rise.fromValue = @(20.0);
    rise.toValue = @(0.0);
    rise.duration = 0.36;
    rise.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
    [self.stream.layer addAnimation:rise forKey:@"zkrise"];

    [self startSizeProbe];
}

- (void)onFrame:(CADisplayLink *)link {
    static BOOL once = NO;
    if (!once) { once = YES; ZKCrumb("pip.frame"); }
    // 关键：按真实时间推进，不按帧数。
    // 画中画的内容视图在后台不是恒定 60 帧——系统会降频，一会 60 一会 30。
    // 旧代码是「每帧 cur += d * 0.30」，帧率一变速度就跟着变，人眼看着就是忽快忽慢。
    CFTimeInterval now = CACurrentMediaTime();
    CGFloat dt = (_lastTickAt > 0) ? (CGFloat)(now - _lastTickAt) : (CGFloat)link.duration;
    _lastTickAt = now;
    if (!isfinite(dt) || dt <= 0) dt = 1.0 / 60.0;
    if (dt > 0.12) dt = 0.12;           // 中间被挂起过：这一帧别追一大截

    CGFloat cur = self.scroll.contentOffset.y;
    CGFloat d = _targetY - cur;

    if (fabs(d) < 0.30) {               // 到位：剩下这点差距肉眼看不出来，收掉
        if (fabs(d) > 0.0001) [self setOffsetY:_targetY];
        _vel = 0;
        link.paused = YES;
        return;
    }

    // 临界阻尼弹簧（ζ=1）：起步从零速平滑加速，到位前平滑减速，整段是一条 S 曲线。
    //
    // 旧版是「每帧 cur += d * 0.30」，也就是指数衰减——前两三帧就走掉六成位移，
    // 剩下几十帧在那儿慢慢蹭。眼睛看到的正是"猛地蹿一下，然后停住"，
    // 也就是用户说的"一顿一顿"。弹簧的速度曲线是中间快两头慢，看着才是"滑"过去的。
    CGFloat w = (fabs(d) > 80.0) ? ZK_SPRING_W_BIG : ZK_SPRING_W;
    _vel += (w * w * d - 2.0 * w * _vel) * dt;

    // 速度上下限：大位移不糊过去；小位移也不会爬不动
    CGFloat vmax = MAX(200.0, MIN(1900.0, fabs(d) * 12.0));
    if (_vel > vmax) _vel = vmax;
    else if (_vel < -vmax) _vel = -vmax;

    CGFloat step = _vel * dt;
    // 单帧位移上限：帧率掉到 24 的时候，同样的速度一帧就是 12 点、半行字，
    // 一帧跳半行看着还是"顿"。卡在 7 点以内，掉帧也只会变成"多走几步"，不会变成"跳一段"。
    CGFloat maxStep = 7.0;
    if (step > maxStep) step = maxStep;
    else if (step < -maxStep) step = -maxStep;
    if (fabs(step) >= fabs(d)) {        // 这一帧就能到：直接落定，不越过目标再弹回来
        [self setOffsetY:_targetY];
        _vel = 0;
        link.paused = YES;
        return;
    }
    [self setOffsetY:cur + step];
}

// 关掉一切隐式动画：补间交给上面那条弹簧。
// 如果系统再叠一层 CA 动画，两者会互相打断——那正是"走两步停一下"的来源。
- (void)setOffsetY:(CGFloat)y {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.scroll.contentOffset = CGPointMake(0, y);
    [CATransaction commit];
}

- (void)shutdown {
    [_link invalidate];
    _link = nil;
    [self stopSizeProbe];
}

#pragma mark 窗口尺寸探测

// 内容视图的真实尺寸。画中画里系统把 content VC 的 view 放进 PiP 窗口，尺寸跟着窗口走。
// 这几层（自己 / 父视图 / 宿主控制器 / 展示层）里取"有效且最小"的那个：
// 宁可少算、绝不用一个更大的容器尺寸去算字号，否则窗口小的时候字还是大的。
- (CGSize)containerSize {
    NSMutableArray<NSValue *> *cands = [NSMutableArray array];
    void (^add)(CGRect) = ^(CGRect r) {
        if (isfinite(r.size.width) && isfinite(r.size.height) && r.size.width >= 1 && r.size.height >= 1) {
            [cands addObject:[NSValue valueWithCGSize:r.size]];
        }
    };
    add(self.view.bounds);
    if (self.view.superview) add(self.view.superview.bounds);
    if (self.parentViewController.isViewLoaded) add(self.parentViewController.view.bounds);
    CALayer *pl = self.view.layer.presentationLayer;
    if (pl) add(pl.bounds);

    CGSize content = CGSizeZero;
    CGFloat bestArea = CGFLOAT_MAX;
    for (NSValue *v in cands) {
        CGSize s = v.CGSizeValue;
        CGFloat area = s.width * s.height;
        if (area < bestArea) { bestArea = area; content = s; }
    }
    if (content.width < 1 || content.height < 1) return CGSizeZero;

    // 画中画窗口本身：系统有时不同步改内容视图的尺寸，只换 surface 做整体缩放，
    // 那时窗口的 bounds 才是"用户实际拖到多大"。
    // 只在「比内容区小」且「宽高比接近」时采信——否则会把 App 主窗口（竖屏、
    // 比例完全不同）误当成画中画窗口，把 21:9 宽条档的字号算小。
    CGRect wr = self.view.window.bounds;
    CGSize ws = wr.size;
    if (isfinite(ws.width) && isfinite(ws.height) && ws.width >= 1 && ws.height >= 1) {
        CGFloat contentRatio = content.width / MAX(1.0, content.height);
        CGFloat windowRatio = ws.width / MAX(1.0, ws.height);
        BOOL closeAspect = (windowRatio > contentRatio * 0.78 && windowRatio < contentRatio * 1.28);
        if ((ws.width * ws.height) < bestArea && closeAspect) return ws;
    }
    return content;
}

// 系统的画中画窗口随时可以被用户拖着放大缩小，而且不保证每次都走 layout 回调
// （内容视图在后台渲染，系统有时只换 surface、不重排 view）。
// 所以除了 layout / 转场回调，再加一条 0.25s 的轻量轮询——只读几个 bounds 做比较，
// 不触发任何绘制，这是"任意时刻都能发现窗口变化"的兜底。
- (void)startSizeProbe {
    if (_probeTimer) return;
    __weak typeof(self) weakSelf = self;
    NSTimer *t = [NSTimer timerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *tm) {
        typeof(self) s = weakSelf;
        if (!s) { [tm invalidate]; return; }
        [s probeSize:@"tick"];
    }];
    _probeTimer = t;
    [[NSRunLoop mainRunLoop] addTimer:t forMode:NSRunLoopCommonModes];
}

- (void)stopSizeProbe {
    [_probeTimer invalidate];
    _probeTimer = nil;
}

- (void)probeSize:(NSString *)why {
    CGSize s = [self containerSize];
    if (s.width < 1 || s.height < 1) return;
    if (_probeW > 0 && fabs(s.width - _probeW) <= 0.5 && fabs(s.height - _probeH) <= 0.5) return;
    _probeW = s.width;
    _probeH = s.height;
    _lastLayoutW = s.width;
    _lastLayoutH = s.height;
    [ZKStore log:@"pip size %@ %.0fx%.0f", why, s.width, s.height];
    [self applyAdaptiveFontForWidth:s.width height:s.height];
    [self applyGeometry];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self probeSize:@"layout"];
}

- (void)viewWillTransitionToSize:(CGSize)size
       withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
    __weak typeof(self) weakSelf = self;
    [coordinator animateAlongsideTransition:nil
                                 completion:^(id<UIViewControllerTransitionCoordinatorContext> ctx) {
        [weakSelf probeSize:@"transition"];
    }];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self startSizeProbe];
}

// 不在这里停：画中画从 App 窗口切到 PiP 窗口时 viewWillDisappear 可能被调用，
// 一停就再也没有兜底探测了。轮询成本只是每 0.25 秒读几个 bounds，
// 真正的生命周期结束由 ZKPip 的 shutdown（停止画中画）负责收尾。

#pragma mark 字号自适应

// 窗口尺寸变了就重算字号。
// 1) 以 480×360 为基准窗，按面积比（开方）缩放用户选的字号；
//    不用 min(宽比, 高比)——用户拖窗口时宽高同时变，min 会让"窗口大了两圈字只涨一点"，
//    看着就是没有自适应。
// 2) 再按"最后这一句（译文 + 原文）能不能整段塞进当前窗口"往下收；
//    字号收到下限还放不下，才把原文限成一行——中文主字幕优先保完整。
- (void)applyAdaptiveFontForWidth:(CGFloat)w height:(CGFloat)h {
    if (w < 1 || h < 1) return;

    CGFloat areaRatio = (w * h) / (480.0 * 360.0);
    CGFloat scale = sqrt(MAX(0.04, areaRatio));
    scale = MAX(0.40, MIN(2.20, scale));

    CGFloat zhMain = MAX(9.0, MIN(60.0, gZhBase * scale));
    CGFloat zhFloor = MAX(8.5, zhMain * 0.72);   // 因"这一句太长"临时收缩的底线
    CGFloat zh = zhMain;
    CGFloat en = MAX(8.0, zh * 0.66);
    NSInteger enLines = 0;

    NSString *zt = [self.stream liveZhText];
    NSString *et = [self.stream liveEnText];

    // 顺序很重要：先牺牲原文的行数（原文是辅助），再温和地缩字号。
    // 反过来做的话，只要碰上一句长句字就缩、下一句短的又弹回，
    // 窗口明明没动，字号却一句一跳——那比不自适应还晃眼。
    for (int i = 0; i < 8; i++) {
        CGFloat zhH = ZKTextHeightLines(zt, w, [UIFont boldSystemFontOfSize:zh], 2.0, 0);
        CGFloat enH = ZKTextHeightLines(et, w, [UIFont systemFontOfSize:en], 1.0, enLines);
        CGFloat gap = (zhH > 0 && enH > 0) ? 2.0 : 0.0;
        CGFloat need = zhH + enH + gap;
        if (need <= 0 || need <= h * 0.94) break;

        if (enLines == 0) { enLines = 1; continue; }   // 第一步：原文收成一行

        if (zh > zhFloor) {                            // 第二步：温和收缩，最多缩到 72%
            zh = MAX(zhFloor, zh * 0.90);
            en = MAX(8.0, zh * 0.66);
            continue;
        }
        if (zh > 9.0) {                                // 第三步：真放不下才继续往下压
            zh = MAX(9.0, zh * 0.88);
            en = MAX(7.5, zh * 0.72);
            continue;
        }
        break;
    }

    NSInteger mask = (NSInteger)lround(zh * 10.0);
    BOOL changed = (mask != _adaptMask) || (enLines != gEnMaxLines)
                   || fabs(zh - gZhSize) > 0.25 || fabs(en - gEnSize) > 0.25;
    gZhSize = zh;
    gEnSize = en;
    gEnMaxLines = enLines;
    if (!changed) return;
    _adaptMask = mask;
    [ZKStore log:@"pip adapt %.0fx%.0f zh=%.1f en=%.1f lines=%ld", w, h, zh, en, (long)enLines];

    // 必须 force：窗口缩放时文字内容往往一字没变，走缓存就把这次重排吞掉了，
    // 表现就是"字号算了新的、屏幕上还是老字号"。
    [self.stream relayoutAllForce:YES];
}

#pragma mark 几何

// 内容不满一屏时贴住底部；满了就整体铺开，滚动看最新。
// 全程不动画：位移有多小就有多小，靠"内容持续增长"来连续，而不是靠补间动画。
- (void)applyGeometry {
    CGFloat w = self.scroll.bounds.size.width;
    CGFloat h = self.scroll.bounds.size.height;
    if (w <= 0 || h <= 0) return;

    // 布局这一步全部关掉隐式动画：内容位置必须"当帧就准"，
    // 否则系统给 stream.frame 补一个 0.25s 的过渡，和滚动弹簧叠在一起就是二次抖动。
    [CATransaction begin];
    [CATransaction setDisableActions:YES];

    [self.stream setStreamWidth:w];
    CGFloat contentH = self.stream.contentHeight;
    CGFloat shownH = MAX(contentH, h);

    CGRect f = CGRectMake(0, shownH - contentH, w, contentH);
    if (!CGRectEqualToRect(self.stream.frame, f)) self.stream.frame = f;

    CGSize cs = CGSizeMake(w, shownH);
    if (!CGSizeEqualToSize(self.scroll.contentSize, cs)) self.scroll.contentSize = cs;

    CGFloat target = MAX(0, shownH - h);
    _targetY = target;

    if (_snapNext || !_link) {         // 新会话/重建：瞬间到位，不要从上往下滑一遍
        _snapNext = NO;
        _vel = 0;
        [_link setPaused:YES];
        self.scroll.contentOffset = CGPointMake(0, target);
        [CATransaction commit];
        return;
    }

    CFTimeInterval now = CACurrentMediaTime();
    // 逐帧回调被系统掐掉了（锁屏/后台这类）——不能停在半路，直接到位。
    // 阈值放 0.6s：太灵敏的话每次都会走这条"直接到位"，等于把弹簧又变回台阶。
    if (!_link.isPaused && (now - _lastTickAt) > 0.6) {
        _vel = 0;
        _link.paused = YES;
        self.scroll.contentOffset = CGPointMake(0, target);
        [CATransaction commit];
        return;
    }

    // 只要有位移就立刻启动，不再等攒够 0.5 点。
    // 旧版的小位移会被攒着不动，攒几次一起跳——"积少成多"那种顿挫就是这么来的。
    CGFloat cur = self.scroll.contentOffset.y;
    if (fabs(target - cur) >= 0.12) {
        if (_link.isPaused) _link.paused = NO;
    } else if (!_link.isPaused) {
        _link.paused = YES;
    }

    [CATransaction commit];
}

#pragma mark 组装

- (void)rebuildFromLines:(NSArray *)lines {
    _snapNext = YES;
    _lastKey = nil;
    [_recentKeys removeAllObjects];
    self.placeholder.hidden = ([lines isKindOfClass:[NSArray class]] && lines.count > 0);
    [self.scroll setContentOffset:CGPointZero animated:NO];
    [self.stream rebuildWithLines:lines];
    _lastLayoutW = 0;   // 强制重排一次
    [self.view setNeedsLayout];
    [self.view layoutIfNeeded];
    [self applyGeometry];
}

- (void)refreshStyle {
    self.view.backgroundColor = ZKBackgroundColor();
    self.placeholder.textColor = ZKLightBackground()
        ? [UIColor colorWithWhite:0.35 alpha:1]
        : [UIColor colorWithWhite:1.0 alpha:0.55];
    _lastLayoutW = 0;
    _probeW = 0;        // 让探测重新认一次尺寸：改字号后必须重新算自适应
    _probeH = 0;
    [self.view setNeedsLayout];
    [self.view layoutIfNeeded];
    CGSize cs = [self containerSize];
    if (cs.width >= 1 && cs.height >= 1) {
        _probeW = cs.width;
        _probeH = cs.height;
        [self applyAdaptiveFontForWidth:cs.width height:cs.height];
    }
    // 用户改字号/颜色时文字内容没变，走缓存就不生效 → 这里必须强制重排
    [self.stream relayoutAllForce:YES];
    [self applyGeometry];
}

- (void)hidePlaceholder {
    if (self.placeholder && !self.placeholder.hidden) self.placeholder.hidden = YES;
}

- (void)appendLine:(NSDictionary *)d {
    if (![d isKindOfClass:[NSDictionary class]]) return;
    NSString *e = d[@"en"], *z = d[@"zh"];
    if (![e isKindOfClass:[NSString class]]) e = @"";
    if (![z isKindOfClass:[NSString class]]) z = @"";
    if (!e.length && !z.length) return;
    [self hidePlaceholder];
    // 同一句重复推上来（断线重连、上游重复回调）就不再落一块。
    // 只跟上一句比是不够的：中间夹了别的句子之后，同一句照样会再出现一遍，
    // 所以保留最近 24 句的指纹。
    NSString *key = [NSString stringWithFormat:@"%@|%@", e, z];
    if (!_recentKeys) _recentKeys = [NSMutableArray array];
    if ([_recentKeys containsObject:key]) return;
    [_recentKeys addObject:key];
    if (_recentKeys.count > 24) [_recentKeys removeObjectAtIndex:0];
    _lastKey = key;

    if (self.scroll.bounds.size.width < 1) {
        [self.view layoutIfNeeded];
    }
    CGFloat w = self.scroll.bounds.size.width;
    if (w > 0) [self.stream setStreamWidth:w];
    [self.stream freezeTailEn:e zh:z];
    self.liveEn = nil;
    self.liveZh = nil;
    [self applyGeometry];
}

// 正在说的这句：就地改流尾那一块，整条流会随文字增长连续往上顶
- (void)setLiveEn:(NSString *)en zh:(NSString *)zh {
    NSString *e = en.length ? en : nil;
    NSString *z = zh.length ? zh : nil;
    if (e.length || z.length) [self hidePlaceholder];
    if ((e == self.liveEn || [e isEqualToString:self.liveEn]) &&
        (z == self.liveZh || [z isEqualToString:self.liveZh])) return;
    self.liveEn = e;
    self.liveZh = z;

    if (self.scroll.bounds.size.width < 1) {
        [self.view layoutIfNeeded];
    }
    CGFloat w = self.scroll.bounds.size.width;
    if (w > 0) [self.stream setStreamWidth:w];

    if (!e.length && !z.length) [self.stream clearTail];
    else [self.stream updateTailEn:e zh:z];
    [self applyGeometry];
}

@end

#pragma mark - PiP 控制

@interface ZKPip () <AVPictureInPictureControllerDelegate>
@end

@implementation ZKPip {
    AVPictureInPictureController *_pip;
    AVPictureInPictureVideoCallViewController *_host;
    ZKSubtitleVC *_sub;
    BOOL _starting;
}

// 已经开着的字幕视图：改了字幕设置要立刻反映到画中画上，而不是等下一场
static __weak id gActiveSub = nil;

// App 的字幕设置传进来：字号、颜色、背景、语言模式、画中画形态
+ (void)applyStyle:(NSDictionary *)p {
    if (![p isKindOfClass:[NSDictionary class]]) return;
    NSNumber *size = p[@"size"];
    if ([size isKindOfClass:[NSNumber class]] && size.doubleValue > 8) {
        gZhBase = size.doubleValue;
        gZhSize = gZhBase;
        gEnSize = MAX(11.0, gZhBase - 6.0);
    }
    NSString *color = p[@"color"];
    if ([color isKindOfClass:[NSString class]]) {
        if ([color isEqualToString:@"yellow"])      gTextColor = [UIColor colorWithRed:1.00 green:0.84 blue:0.25 alpha:1];
        else if ([color isEqualToString:@"cyan"])   gTextColor = [UIColor colorWithRed:0.30 green:0.88 blue:0.96 alpha:1];
        else if ([color isEqualToString:@"green"])  gTextColor = [UIColor colorWithRed:0.44 green:0.94 blue:0.56 alpha:1];
        else if ([color isEqualToString:@"orange"]) gTextColor = [UIColor colorWithRed:1.00 green:0.64 blue:0.28 alpha:1];
        else if ([color isEqualToString:@"pink"])   gTextColor = [UIColor colorWithRed:1.00 green:0.58 blue:0.76 alpha:1];
        else if ([color isEqualToString:@"blue"])   gTextColor = [UIColor colorWithRed:0.42 green:0.70 blue:1.00 alpha:1];
        else                                        gTextColor = [UIColor whiteColor];
    }
    NSString *bg = p[@"background"];
    if ([bg isKindOfClass:[NSString class]]) gBackground = bg;
    NSString *mode = p[@"mode"];
    if ([mode isKindOfClass:[NSString class]]) gMode = mode;

    NSString *pip = p[@"pip"];
    if ([pip isKindOfClass:[NSString class]]) {
        // 窗口三档，选哪个开出来就是多大：
        //   L 大 = 4:3 480×360（默认，能看清两行）
        //   M 中 = 16:9 576×324
        //   S 小 = 21:9 840×360（最宽最矮，一行铺满屏宽）
        // 老版本的 4:3 / 21:9 / bar 也认，映射到对应的档
        if ([pip isEqualToString:@"M"] || [pip isEqualToString:@"16:9"]) {
            gPipSize = CGSizeMake(576, 324);
        } else if ([pip isEqualToString:@"S"] || [pip isEqualToString:@"21:9"] || [pip isEqualToString:@"bar"]) {
            gPipSize = CGSizeMake(840, 360);
        } else {
            gPipSize = CGSizeMake(480, 360);
        }
    }
    [ZKStore log:@"pip style size=%.0f color=%@ bg=%@ mode=%@ win=%.0fx%.0f",
        gZhSize, color ?: @"", gBackground, gMode, gPipSize.width, gPipSize.height];
    if (gActiveSub) [(id)gActiveSub performSelector:@selector(refreshStyle)];
}

+ (instancetype)shared {
    static ZKPip *s; static dispatch_once_t o;
    dispatch_once(&o, ^{ s = [ZKPip new]; });
    return s;
}

- (BOOL)isActive { return _pip && _pip.isPictureInPictureActive; }

- (void)startInView:(UIView *)view {
    if (_starting) return;
    if (_pip && _pip.isPictureInPictureActive) return;
    // 上一次的残留先彻底清掉，避免「关了还挂着」「再开起不来」
    if (_pip) { @try { [_pip stopPictureInPicture]; } @catch (__unused NSException *e) {} }
    _pip = nil;
    _host = nil;
    _sub = nil;
    gActiveSub = nil;
    // 视图还没上屏就起画中画，系统会直接拒绝，严重时会把进程带走
    if (!view || !view.window) {
        [ZKStore log:@"pip: 视图还没上屏，先别起"];
        return;
    }
    _starting = YES;
    ZKCrumb("pip.1.session");

    @try {
        AVAudioSession *s = [AVAudioSession sharedInstance];
        [s setCategory:AVAudioSessionCategoryPlayback mode:AVAudioSessionModeMoviePlayback
               options:AVAudioSessionCategoryOptionMixWithOthers error:nil];
        [s setActive:YES error:nil];
    } @catch (NSException *e) {
        [ZKStore log:@"pip session ex %@", e.reason];
    }

    ZKCrumb("pip.2.host");
    @try {
        _host = [[AVPictureInPictureVideoCallViewController alloc] init];
        _host.preferredContentSize = gPipSize;
        _sub = [[ZKSubtitleVC alloc] init];
        [_host addChildViewController:_sub];
        _sub.view.frame = _host.view.bounds;
        _sub.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [_host.view addSubview:_sub.view];
        [_sub didMoveToParentViewController:_host];
        gActiveSub = _sub;
    } @catch (NSException *e) {
        [ZKStore log:@"pip host ex %@", e.reason];
        _starting = NO;
        return;
    }

    ZKCrumb("pip.3.source");
    @try {
        AVPictureInPictureControllerContentSource *src =
            [[AVPictureInPictureControllerContentSource alloc] initWithActiveVideoCallSourceView:view
                                                                              contentViewController:_host];
        _pip = [[AVPictureInPictureController alloc] initWithContentSource:src];
        _pip.delegate = self;
        if ([_pip respondsToSelector:@selector(setCanStartPictureInPictureAutomaticallyFromInline:)]) {
            _pip.canStartPictureInPictureAutomaticallyFromInline = YES;
        }
    } @catch (NSException *e) {
        [ZKStore log:@"pip source ex %@", e.reason];
        _pip = nil;
        _starting = NO;
        return;
    }

    [self refreshFromStore];
    ZKCrumb("pip.4.request");
    [self attemptStart:0];
}

// 一次不成不代表坏了：视图刚上屏、音频会话刚切，前几百毫秒可能还是"不可用"
- (void)attemptStart:(NSInteger)attempt {
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        typeof(self) s = weakSelf;
        if (!s || !s->_pip) { if (s) s->_starting = NO; return; }
        ZKCrumb("pip.5.check");
        BOOL possible = s->_pip.isPictureInPicturePossible;
        [ZKStore log:@"pip attempt %ld possible=%d", (long)attempt, possible];
        if (!possible) {
            if (attempt < 4) { [s attemptStart:attempt + 1]; return; }
            s->_starting = NO;
            [ZKStore log:@"pip: 起不来（多次不可用）"];
            return;
        }
        @try {
            ZKCrumb("pip.6.start");
            [s->_pip startPictureInPicture];
        } @catch (NSException *e) {
            [ZKStore log:@"pip start ex %@", e.reason];
        }
        s->_starting = NO;
    });
}

- (void)stop {
    _starting = NO;
    @try { [_pip stopPictureInPicture]; } @catch (__unused NSException *e) {}
    // 引用一起清掉：只调 stopPictureInPicture 的话，下一次 isActive 判断会拿到旧对象，
    // 表现就是「已经停止了，画中画还赖在屏幕上」或者「再点开始起不来」
    _pip = nil;
    @try { [_sub shutdown]; } @catch (__unused NSException *e) {}
    _host = nil;
    _sub = nil;
    gActiveSub = nil;
}

- (void)refreshFromStore {
    if (!_sub) return;
    NSArray *lines = [ZKStore lines];
    [_sub rebuildFromLines:lines];
}

// 一句说完了：流尾那块就地落定，新的空尾巴接在后面
- (void)appendLineEn:(NSString *)en zh:(NSString *)zh {
    if (!_sub) return;
    [_sub appendLine:@{@"en": en ?: @"", @"zh": zh ?: @""}];
}

// 正在说的这一句：更新流尾
- (void)setLiveEn:(NSString *)en zh:(NSString *)zh {
    if (!_sub) return;
    [_sub setLiveEn:en zh:zh];
}

// 兼容旧调用
- (void)setTrans:(NSString *)t orig:(NSString *)o { [self setLiveEn:o zh:t]; }
- (void)showText:(NSString *)t { [self setLiveEn:nil zh:t]; }

#pragma mark delegate

- (void)pictureInPictureControllerDidStartPictureInPicture:(AVPictureInPictureController *)c {
    ZKCrumb("pip.on");
    [ZKStore log:@"pip started"];
    [self refreshFromStore];
}
- (void)pictureInPictureControllerDidStopPictureInPicture:(AVPictureInPictureController *)c {
    [ZKStore log:@"pip stopped"];
}
- (void)pictureInPictureController:(AVPictureInPictureController *)c failedToStartPictureInPictureWithError:(NSError *)e {
    ZKCrumb("pip.fail");
    [ZKStore log:@"pip fail: %@", e.localizedDescription];
}
@end
