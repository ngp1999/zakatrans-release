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
static CGSize gPipSize = {1080, 216};          // 5:1 全宽横条（默认，最不挡画面）
static NSString *gPipStyle = @"X";             // 当前窗口档：X 小(5:1) / M 中(21:9) / B 大(16:10)
// 滚动方式：小窗 up = 叠化（交叉淡入淡出）/ cut = 上切（整批向上切走）；
//           中窗大窗 up = 上推（整列上移一格）/ segment = 逐字（上下两块连续文本、打字机，满了整块上推一行）
// 只影响字幕怎么"进来"，字号、行数、颜色一概不动。
static NSString *gScroll = @"up";
// 小窗兜底：窗口被拖得很小、字号已压到下限还是放不下时，原文限行（0 = 不限）。
// 优先保住中文主字幕的完整，原文宁可截一行，也不把两个字都缩到看不清。
static NSInteger gEnMaxLines = 0;
static const CGFloat ZK_PARA_GAP = 14.0;      // 句与句之间的空档
static const CGFloat ZK_MAX_BLOCKS = 120.0;   // 历史句上限（正常一场对话到不了）

// 滚动弹簧：固有频率越高追得越快（临界阻尼下约 4/ω 秒到位）。
// 22 ≈ 0.18s 到位，正好把"一行文字长出来"那 25 点的落差摊成一段连续位移。
// 大位移（重建、画中画被缩放）用慢一档的，看得清也更有质感。
static const CGFloat ZK_SPRING_W = 27.0;
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
            @"cocoa":    [UIColor colorWithRed:0.22 green:0.14 blue:0.10 alpha:1],
            @"teal":     [UIColor colorWithRed:0.04 green:0.22 blue:0.26 alpha:1],
            // 老版本存下来的键照旧给色，升级那一下也不会闪成纯黑
            @"graphite": [UIColor colorWithRed:0.22 green:0.14 blue:0.10 alpha:1],
            @"navy":     [UIColor colorWithRed:0.04 green:0.22 blue:0.26 alpha:1],
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
- (void)patchLastZh:(NSString *)zh;
- (void)patchZh:(NSString *)zh forEn:(NSString *)en;
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

// 精确版：按原文找回那一块再补译文（中间已经又上了新句也不会补错行）
- (void)patchZh:(NSString *)zh forEn:(NSString *)en {
    if (!zh.length) return;
    if (en.length) {
        for (NSInteger i = (NSInteger)_blocks.count - 1; i >= 0; i--) {
            ZKBlockView *b = _blocks[(NSUInteger)i];
            if (![b.enText isEqualToString:en]) continue;
            if (b.zhText.length) return;
            [b applyEn:b.enText zh:zh first:(i == 0) width:_w];
            [self relayoutAll];
            return;
        }
        if (_tail && [_tail.enText isEqualToString:en] && !_tail.zhText.length) {
            [self updateTailEn:_tail.enText zh:zh];
            return;
        }
    }
    [self patchLastZh:zh];
}

// 译文迟到：只补最后一块落定的句子。位置按新高度重排，上面的块不动、不重建、不重播淡入，
// 画面上看不出「刷新」，但那一行从「只有原文」变成「译文 + 原文」。
- (void)patchLastZh:(NSString *)zh {
    if (!zh.length) return;
    ZKBlockView *b = _blocks.lastObject;
    if (b) {
        NSString *en = b.enText ?: @"";
        [b applyEn:en zh:zh first:(_blocks.count == 1) width:_w];
        [self relayoutAll];
        return;
    }
    // 还挂在尾块里（这轮刚上屏、还没落定）
    if (_tail && (_tail.enText.length || _tail.zhText.length)) {
        [self updateTailEn:(_tail.enText ?: @"") zh:zh];
    }
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
- (void)patchLastZh:(NSString *)zh;
- (void)patchZh:(NSString *)zh forEn:(NSString *)en;
- (void)showLiveEn:(NSString *)en zh:(NSString *)zh;
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
    CGFloat h = ceil(CGRectGetHeight(r));
    return isfinite(h) && h > 0 ? h : 0;
}

// 单行宽度：用来判断「这一句还塞不塞得进当前这一行」
// 量一句的整行宽。用和 UILabel 同一套排版引擎（boundingRect + 字体行距），
// 结果向上取整再留 1pt 余量：sizeWithAttributes 会少算零点几到一两个点，
// 差这一两点就足以让一句本来放得下的句子在屏上被劈成两行。
static CGFloat ZKTextWidth(NSString *text, UIFont *font) {
    if (!text.length || !font) return 0;
    CGRect r = [text boundingRectWithSize:CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX)
                                 options:(NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading)
                              attributes:@{NSFontAttributeName: font}
                                 context:nil];
    CGFloat w = ceil(CGRectGetWidth(r)) + 1.0;
    return isfinite(w) ? w : CGFLOAT_MAX;
}

// 限行版：maxLines > 0 表示 UILabel 最多显示这么多行，高度也不能超过它。
// 小窗兜底要用这个量，否则算出来的高度是"全文高度"，永远判成放不下、字号一路缩到底。
static CGFloat ZKTextHeightLines(NSString *text, CGFloat width, UIFont *font, CGFloat lineSpacing, NSInteger maxLines) {
    CGFloat h = ZKTextHeight(text, width, font, lineSpacing);
    if (maxLines <= 0 || h <= 0) return h;
    CGFloat cap = ceil((font.lineHeight + lineSpacing) * maxLines + 1.0);
    return MIN(h, cap);
}

#pragma mark - 阅读速度

/// 这一句里「看得见的字」有几个：空格、换行不算，标点算半个（扫读时占位很小）。
static NSUInteger ZKVisibleLen(NSString *text) {
    if (![text isKindOfClass:[NSString class]] || !text.length) return 0;
    NSUInteger n = 0;
    for (NSUInteger i = 0; i < text.length; i++) {
        unichar c = [text characterAtIndex:i];
        if (c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == 0x3000) continue;
        n++;
    }
    return n;
}

#pragma mark - 小档（5:1）：两行，中文在上、源语言在下

#pragma mark - 逐帧动画（画中画里唯一跑得动的动画）

/// 画中画的内容视图跑在后台，系统的 UIView / CoreAnimation 补间在这里会被降频，
/// 甚至直接不执行——用户看到的就是「先不动，然后猛地跳到位」。
/// 所以字幕的进场、上推全部走这一条：每个刷新周期按真实时间往目标插一步。
/// 掉帧只会让步子变大，不会跳；ProMotion 上就是 120 帧。
@interface ZKAnim : NSObject
+ (instancetype)run:(NSTimeInterval)duration tick:(void (^)(CGFloat p))tick done:(void (^)(void))done;
- (void)cancel;
@end

@interface ZKAnim ()
- (void)step:(CADisplayLink *)link;
@end

@implementation ZKAnim {
    CADisplayLink *_link;
    CFTimeInterval _t0;
    NSTimeInterval _dur;
    void (^_tick)(CGFloat);
    void (^_done)(void);
    BOOL _over;
}

+ (instancetype)run:(NSTimeInterval)duration tick:(void (^)(CGFloat))tick done:(void (^)(void))done {
    ZKAnim *a = [ZKAnim new];
    a->_dur = MAX(0.05, duration);
    a->_tick = [tick copy];
    a->_done = [done copy];
    a->_link = [CADisplayLink displayLinkWithTarget:a selector:@selector(step:)];
    if (@available(iOS 15.0, *)) {
        a->_link.preferredFrameRateRange = CAFrameRateRangeMake(60, 120, 120);
    }
    [a->_link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    a->_t0 = CACurrentMediaTime();
    return a;
}

- (void)step:(CADisplayLink *)link {
    if (_over) return;
    CGFloat p = (CGFloat)((CACurrentMediaTime() - _t0) / _dur);
    if (!isfinite(p) || p < 0) p = 0;
    if (p > 1.0) p = 1.0;
    if (_tick) _tick(p);
    if (p >= 1.0) [self finish];
}

- (void)finish {
    if (_over) return;
    _over = YES;
    [_link invalidate];
    _link = nil;
    void (^d)(void) = _done;
    _tick = nil;
    _done = nil;
    if (d) d();
}

- (void)cancel {
    if (_over) return;
    _over = YES;
    [_link invalidate];
    _link = nil;
    _tick = nil;
    _done = nil;
}

@end

#pragma mark - 一行一句（中/大窗的上推、分段打字机共用）

/// 长句宁可缩一点，也不许被截掉半句——但也只在压不下时缩，最短到原字号的 half 为止。
static CGFloat ZKFitSize(NSString *text, UIFont *font, CGFloat width, CGFloat floorScale) {
    if (!text.length || !font || width < 8) return font ? font.pointSize : 12.0;
    CGRect r = [text boundingRectWithSize:CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX)
                                  options:(NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading)
                               attributes:@{NSFontAttributeName: font}
                                  context:nil];
    CGFloat need = ceil(CGRectGetWidth(r)) + 1.0;
    if (need <= width) return font.pointSize;
    CGFloat k = MAX(floorScale, width / MAX(1.0, need));
    return MAX(8.0, floor(font.pointSize * k * 10.0) / 10.0);
}

/// 一行 = 一句：上面译文、下面原文。打字机模式下它自己记着「已经露出几个字」，
/// 文字是长出来的，位置和行高却是按整句先摆好的——所以打字过程中不会挤动别的行。
@interface ZKLineRow : UIView
@property (nonatomic, strong) UILabel *zhLabel;
@property (nonatomic, strong) UILabel *srcLabel;
@property (nonatomic, copy) NSString *zh;
@property (nonatomic, copy) NSString *en;
@property (nonatomic, assign) NSInteger showZh;   // -1 = 全部显示
@property (nonatomic, assign) NSInteger showEn;
- (void)refreshText;
@end

@implementation ZKLineRow

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor clearColor];
        self.userInteractionEnabled = NO;
        self.clipsToBounds = NO;
        _zhLabel = [UILabel new];
        _srcLabel = [UILabel new];
        for (UILabel *l in @[_zhLabel, _srcLabel]) {
            l.numberOfLines = 1;
            l.lineBreakMode = NSLineBreakByTruncatingTail;
            l.adjustsFontSizeToFitWidth = YES;
            l.minimumScaleFactor = 0.5;
            l.backgroundColor = [UIColor clearColor];
            l.opaque = NO;
            l.userInteractionEnabled = NO;
            [self addSubview:l];
        }
        _showZh = -1;
        _showEn = -1;
    }
    return self;
}

- (void)setZh:(NSString *)zh {
    _zh = [zh copy];
    [self refreshText];
}

- (void)setEn:(NSString *)en {
    _en = [en copy];
    [self refreshText];
}

- (void)refreshText {
    NSString *z = _zh ?: @"";
    NSString *e = _en ?: @"";
    if (_showZh >= 0 && (NSInteger)z.length > _showZh) z = [z substringToIndex:(NSUInteger)_showZh];
    if (_showEn >= 0 && (NSInteger)e.length > _showEn) e = [e substringToIndex:(NSUInteger)_showEn];
    if (![_zhLabel.text isEqualToString:z]) _zhLabel.text = z;
    if (![_srcLabel.text isEqualToString:e]) _srcLabel.text = e;
}

@end

/// 中/大窗共用的「一列句子」：
///   · 行数按窗口定（双语：中窗 3 行、大窗 4 行；单语按高度放宽），每格等高，
///     整列正好铺满窗口——顶上不会留一截空白，跟预览里看到的一模一样；
///   · 新句从最下面进来，整列被它顶着往上一格，走的是逐帧插值，不是系统补间；
///   · typing = YES 时，新句逐字打出来。
@interface ZKRowStack : UIView
@property (nonatomic, assign) BOOL typing;
- (void)setBoxWidth:(CGFloat)w height:(CGFloat)h force:(BOOL)force;
- (void)resetWithLines:(NSArray *)lines;
- (void)addEn:(NSString *)en zh:(NSString *)zh;
- (void)patchZh:(NSString *)zh forEn:(NSString *)en;
- (void)patchLastZh:(NSString *)zh;
- (void)refreshStyle;
@end

@interface ZKRowStack ()
- (BOOL)twoRows;
- (void)recalcMetrics;
- (void)layoutRows;
- (void)layoutRow:(ZKLineRow *)r;
- (CGFloat)heightFor:(NSString *)t font:(UIFont *)f width:(CGFloat)w lines:(NSInteger)lines;
- (void)rollUp;
- (void)snapRoll;
- (void)clearRetired;
- (void)startTypingOn:(ZKLineRow *)r;
@end

@implementation ZKRowStack {
    UIView *_content;
    NSMutableArray<ZKLineRow *> *_rows;
    NSMutableArray<ZKLineRow *> *_retired;   // 正在被顶出画面的那几行
    CGFloat _w, _h, _font;
    NSInteger _slots;
    CGFloat _slotH, _gap, _inset;
    ZKAnim *_roller;
    ZKAnim *_typer;
    BOOL _built;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.clipsToBounds = YES;
        self.userInteractionEnabled = NO;
        self.backgroundColor = [UIColor clearColor];
        _rows = [NSMutableArray array];
        _retired = [NSMutableArray array];
        _font = 20;
        _slots = 3;
        _content = [UIView new];
        _content.backgroundColor = [UIColor clearColor];
        _content.userInteractionEnabled = NO;
        [self addSubview:_content];
    }
    return self;
}

- (BOOL)twoRows {
    return ![gMode isEqualToString:@"zh"] && ![gMode isEqualToString:@"source"];
}

- (void)recalcMetrics {
    if (_w < 1 || _h < 1) return;
    CGFloat area = (_w * _h) / (480.0 * 360.0);
    CGFloat scale = sqrt(MAX(0.04, area));
    scale = MAX(0.45, MIN(2.10, scale));
    _font = MAX(12.0, MIN(74.0, gZhBase * scale * 1.35));

    _inset = MAX(4.0, _h * 0.03);
    _gap = MAX(2.0, _h * 0.012);
    NSInteger n;
    if ([self twoRows]) {
        // 双语：行数跟预览一致（中窗 3 行原文 + 3 行译文、大窗 5 行原文 + 5 行译文），
        // 格子高多少由窗口分，这样整列刚好铺满——以前按内容算行数，最后一行下面空、上面也空。
        n = [gPipStyle isEqualToString:@"M"] ? 3 : 5;
    } else {
        // 只显一种语言：字大，行数按高度放宽
        n = (NSInteger)floor((_h - _inset * 2) / MAX(1.0, _font * 1.5));
        n = MAX(2, MIN(6, n));
    }
    _slots = MAX(1, n);
    _slotH = MAX(10.0, (_h - _inset * 2 - (_slots - 1) * _gap) / (CGFloat)_slots);
    // 双语一格要站「一行译文 + 一行原文」：格高不够时先把字号压下来，
    // 不然原文那行会溢出到下一格里（大窗站 5 行时最容易撞上）。
    if ([self twoRows]) {
        CGFloat maxFont = MAX(12.0, (_slotH - 6.0) / 2.0);
        if (_font > maxFont) _font = maxFont;
    }
    _content.frame = CGRectMake(0, 0, _w, _h);
}

- (CGFloat)heightFor:(NSString *)t font:(UIFont *)f width:(CGFloat)w lines:(NSInteger)lines {
    if (![t isKindOfClass:[NSString class]] || !t.length || w < 8 || !f) return 0;
    if (lines <= 1) return ceil(f.lineHeight) + 1.0;
    CGRect r = [t boundingRectWithSize:CGSizeMake(w, CGFLOAT_MAX)
                               options:(NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading)
                            attributes:@{NSFontAttributeName: f}
                               context:nil];
    CGFloat h = ceil(CGRectGetHeight(r)) + 1.0;
    if (!isfinite(h) || h < 0) h = 0;
    return MIN(h, ceil(f.lineHeight * lines) + 1.0);
}

- (void)layoutRow:(ZKLineRow *)r {
    if (!r || _w < 1 || _slotH < 10) return;
    BOOL two = [self twoRows];
    BOOL showTrans = ![gMode isEqualToString:@"source"];
    BOOL showSource = ![gMode isEqualToString:@"zh"];
    CGFloat padX = MAX(3.0, _w * 0.016);
    CGFloat w = MAX(8.0, _w - padX * 2);

    UIFont *zhBase = [UIFont boldSystemFontOfSize:_font];
    UIFont *srcBase = two ? [UIFont systemFontOfSize:_font * 0.66] : zhBase;

    CGFloat zhH = 0, srcH = 0;
    if (showTrans) {
        NSString *t = r.zh ?: @"";
        CGFloat fs = ZKFitSize(t, zhBase, w, two ? 0.5 : 0.72);
        UIFont *f = [UIFont boldSystemFontOfSize:fs];
        r.zhLabel.font = f;
        r.zhLabel.textColor = ZKMainColor();
        r.zhLabel.numberOfLines = two ? 1 : 2;
        r.zhLabel.adjustsFontSizeToFitWidth = two;
        zhH = [self heightFor:t font:f width:w lines:r.zhLabel.numberOfLines];
    }
    if (showSource) {
        NSString *t = r.en ?: @"";
        CGFloat fs = ZKFitSize(t, srcBase, w, two ? 0.5 : 0.72);
        UIFont *f = two ? [UIFont systemFontOfSize:fs] : [UIFont boldSystemFontOfSize:fs];
        r.srcLabel.font = f;
        r.srcLabel.textColor = two ? [ZKMainColor() colorWithAlphaComponent:0.62] : ZKMainColor();
        r.srcLabel.numberOfLines = two ? 1 : 2;
        r.srcLabel.adjustsFontSizeToFitWidth = two;
        srcH = [self heightFor:t font:f width:w lines:r.srcLabel.numberOfLines];
    }

    // 换成「仅原文 / 仅译文」时，另一条必须收干净，否则旧文字会留在原位
    if (!showTrans) { zhH = 0; r.zhLabel.hidden = YES; r.zhLabel.frame = CGRectZero; }
    if (!showSource) { srcH = 0; r.srcLabel.hidden = YES; r.srcLabel.frame = CGRectZero; }

    CGFloat gap = (zhH > 0 && srcH > 0) ? 2.0 : 0;
    CGFloat total = zhH + gap + srcH;
    CGFloat y = MAX(0, (_slotH - total) / 2.0);
    r.zhLabel.hidden = (zhH <= 0);
    r.srcLabel.hidden = (srcH <= 0);
    r.zhLabel.frame = CGRectMake(padX, y, w, zhH);
    r.srcLabel.frame = CGRectMake(padX, y + zhH + gap, w, srcH);
}

- (void)layoutRows {
    NSInteger count = (NSInteger)_rows.count;
    if (count <= 0) return;
    // 装不下的老句子先不显示（换档、换语言模式时会短暂多出来），
    // 一定是从最老的开始让位——最新的那句永远在底下看得见。
    NSInteger from = MAX(0, count - _slots);
    NSInteger first = _slots - (count - from);
    for (NSInteger i = 0; i < count; i++) {
        ZKLineRow *r = _rows[(NSUInteger)i];
        if (i < from) {
            r.hidden = YES;
            continue;
        }
        r.hidden = NO;
        NSInteger slot = MAX(0, first + (i - from));
        r.frame = CGRectMake(0, _inset + slot * (_slotH + _gap), _w, _slotH);
        [self layoutRow:r];
    }
}

- (void)rollUp {
    if (_w < 1 || _h < 1 || _slotH < 10) return;
    CGFloat dy = _slotH + _gap;
    _content.transform = CGAffineTransformMakeTranslation(0, dy);
    __weak typeof(self) weakSelf = self;
    _roller = [ZKAnim run:0.46 tick:^(CGFloat p) {
        typeof(self) s = weakSelf;
        if (!s) return;
        CGFloat e = 1.0 - pow(1.0 - p, 3.0);      // ease-out：起步快、落位轻
        s->_content.transform = CGAffineTransformMakeTranslation(0, dy * (1.0 - e));
    } done:^{
        typeof(self) s = weakSelf;
        if (!s) return;
        s->_content.transform = CGAffineTransformIdentity;
        [s clearRetired];
    }];
}

- (void)clearRetired {
    for (ZKLineRow *r in _retired) [r removeFromSuperview];
    [_retired removeAllObjects];
}

- (void)snapRoll {
    if (_roller) {
        [_roller cancel];
        _roller = nil;
    }
    _content.transform = CGAffineTransformIdentity;
    [self clearRetired];
}

- (void)addEn:(NSString *)en zh:(NSString *)zh {
    NSString *e = [en isKindOfClass:[NSString class]] ? en : @"";
    NSString *z = [zh isKindOfClass:[NSString class]] ? zh : @"";
    if (!e.length && !z.length) return;
    if (_w < 1 || _h < 1) return;

    // 同一句被重复推上来（断线重连、上游重复回调）：并回上一行，不再多一行
    ZKLineRow *last = _rows.lastObject;
    if (last && e.length && z.length == 0 && [last.en isEqualToString:e]) return;
    if (last && e.length && [last.en isEqualToString:e]) {
        if (!last.zh.length && z.length) {
            last.zh = z;
            [self layoutRow:last];
            if (self.typing) [self startTypingOn:last];
        }
        return;
    }

    [self snapRoll];        // 上一段没走完的先落定，避免两段插值打架

    ZKLineRow *r = [ZKLineRow new];
    r.showZh = self.typing ? 0 : -1;
    r.showEn = self.typing ? 0 : -1;
    r.zh = z;
    r.en = e;
    [_content addSubview:r];
    [_rows addObject:r];

    while ((NSInteger)_rows.count > _slots) {
        ZKLineRow *old = _rows.firstObject;
        [_rows removeObjectAtIndex:0];
        [_retired addObject:old];
    }

    [self layoutRows];

    // 被顶出去的那些，摆在最上面一格的上方（动画开始时正好落在观众看得见的位置）
    NSInteger firstSlot = MAX(0, _slots - (NSInteger)_rows.count);
    NSInteger st = firstSlot - 1;
    for (ZKLineRow *rr in _retired) {
        rr.hidden = NO;
        rr.frame = CGRectMake(0, _inset + st * (_slotH + _gap), _w, _slotH);
        [self layoutRow:rr];
        st--;
    }

    [self rollUp];
    if (self.typing) [self startTypingOn:r];
}

- (void)startTypingOn:(ZKLineRow *)r {
    if (_typer) {
        [_typer cancel];
        _typer = nil;
    }
    // 上一句还在打、这一句就来了：上一句直接显示全，不能停在半句上
    for (ZKLineRow *row in _rows) {
        if (row == r) continue;
        if (row.showZh >= 0 || row.showEn >= 0) {
            row.showZh = -1;
            row.showEn = -1;
            [row refreshText];
        }
    }
    if (!r) return;
    BOOL showTrans = ![gMode isEqualToString:@"source"];
    BOOL showSource = ![gMode isEqualToString:@"zh"];
    NSInteger nz = showTrans ? (NSInteger)r.zh.length : 0;
    NSInteger ne = showSource ? (NSInteger)r.en.length : 0;
    if (nz <= 0 && ne <= 0) return;
    r.showZh = nz > 0 ? 0 : -1;
    r.showEn = ne > 0 ? 0 : -1;
    [r refreshText];

    // 中文 22 字/秒、原文 52 字符/秒：跟预览里那台打字机同一个速度
    CGFloat dur = MAX(0.30, MIN(1.8, MAX(nz / 22.0, ne / 52.0)));
    CFTimeInterval t0 = CACurrentMediaTime();
    __weak typeof(self) weakSelf = self;
    __weak ZKLineRow *wr = r;
    _typer = [ZKAnim run:dur tick:^(CGFloat p) {
        typeof(self) s = weakSelf;
        if (!s) return;
        ZKLineRow *row = wr;
        if (!row) return;
        CFTimeInterval t = CACurrentMediaTime() - t0;
        NSInteger kz = MIN(nz, (NSInteger)(t * 22.0));
        NSInteger ke = MIN(ne, (NSInteger)(t * 52.0));
        if (p >= 1.0) { kz = nz; ke = ne; }
        if (kz != row.showZh || ke != row.showEn) {
            row.showZh = kz;
            row.showEn = ke;
            [row refreshText];
        }
    } done:^{
        ZKLineRow *row = wr;
        if (!row) return;
        row.showZh = -1;
        row.showEn = -1;
        [row refreshText];
    }];
}

- (void)patchZh:(NSString *)zh forEn:(NSString *)en {
    if (![zh isKindOfClass:[NSString class]] || !zh.length) return;
    ZKLineRow *hit = nil;
    for (NSInteger i = (NSInteger)_rows.count - 1; i >= 0; i--) {
        ZKLineRow *r = _rows[(NSUInteger)i];
        if (en.length) {
            if ([r.en isEqualToString:en]) { hit = r; break; }
        } else if ([r.en length] && ![r.zh length]) {
            hit = r;
            break;
        }
    }
    if (!hit || hit.zh.length) return;      // 这一句已经下屏了：丢掉，绝不硬补到最后一行
    hit.zh = zh;
    [self layoutRow:hit];
    if (self.typing) [self startTypingOn:hit];
    else [hit refreshText];
}

- (void)patchLastZh:(NSString *)zh {
    if (![zh isKindOfClass:[NSString class]] || !zh.length) return;
    [self patchZh:zh forEn:@""];
}

- (void)setBoxWidth:(CGFloat)w height:(CGFloat)h force:(BOOL)force {
    if (w < 1 || h < 1) return;
    BOOL changed = fabs(w - _w) > 0.5 || fabs(h - _h) > 0.5;
    _w = w;
    _h = h;
    if (!changed && !force && _built) return;
    _built = YES;
    [self snapRoll];
    [self recalcMetrics];
    _content.frame = CGRectMake(0, 0, _w, _h);
    [self layoutRows];
}

- (void)refreshStyle {
    [self snapRoll];
    [self recalcMetrics];
    _content.frame = CGRectMake(0, 0, _w, _h);
    [self layoutRows];
}

- (void)resetWithLines:(NSArray *)lines {
    [self snapRoll];
    if (_typer) {
        [_typer cancel];
        _typer = nil;
    }
    for (ZKLineRow *r in _rows) [r removeFromSuperview];
    [_rows removeAllObjects];
    if ([lines isKindOfClass:[NSArray class]] && lines.count) {
        NSInteger from = MAX(0, (NSInteger)lines.count - _slots);
        for (NSInteger i = from; i < (NSInteger)lines.count; i++) {
            id o = lines[(NSUInteger)i];
            if (![o isKindOfClass:[NSDictionary class]]) continue;
            NSString *e = o[@"en"], *z = o[@"zh"];
            if (![e isKindOfClass:[NSString class]]) e = @"";
            if (![z isKindOfClass:[NSString class]]) z = @"";
            if (!e.length && !z.length) continue;
            ZKLineRow *r = [ZKLineRow new];
            r.zh = z;
            r.en = e;
            [_content addSubview:r];
            [_rows addObject:r];
        }
    }
    [self layoutRows];
}

@end

/// 中/大窗「逐字」：上下两块连续文本——上面一整段译文、下面一整段原文。
///
/// 字是一个一个长出来的（打字机）；一块写满之后，**整块向上推一行**，
/// 最上面那一行被切出画面——不是原地重排、更不是往左推。
/// 推的是整块文字的位置，走逐帧插值，看着就是由下往上连续滚一行。
/// 跟设置页那块预览（SubtitleSettingsView.segmentPreview）是同一套算法：
/// 同样的分块高度、同样的字号、同样 22 字/秒 与 52 字符/秒、同样的「满行推一行」。
@interface ZKSegmentView : UIView
- (void)setBoxWidth:(CGFloat)w height:(CGFloat)h force:(BOOL)force;
- (void)resetWithLines:(NSArray *)lines;
- (void)addEn:(NSString *)en zh:(NSString *)zh;
- (void)patchZh:(NSString *)zh forEn:(NSString *)en;
- (void)patchLastZh:(NSString *)zh;
- (void)refreshStyle;
@end

@interface ZKSegmentView ()
- (void)recalcMetrics;
- (void)layoutBlocks;
- (void)rebuild;
- (void)render;
- (void)renderSnap:(BOOL)snap;
- (void)ensureTyping;
- (void)stopTyping;
- (void)step:(CADisplayLink *)link;
- (CGFloat)heightOf:(NSString *)t font:(UIFont *)f width:(CGFloat)w;
- (NSString *)visibleOf:(NSMutableString *)buf pending:(CGFloat)pending;
- (void)aimZh:(CGFloat)nt lineH:(CGFloat)lineH snap:(BOOL)snap;
- (void)aimSrc:(CGFloat)nt lineH:(CGFloat)lineH snap:(BOOL)snap;
- (void)dropHiddenPending;
@end

@implementation ZKSegmentView {
    UIView *_zhBox, *_srcBox;          // 上块 / 下块（会裁掉溢出的部分）
    UILabel *_zhLabel, *_srcLabel;
    NSMutableArray<NSMutableDictionary *> *_pairs;   // 一句一条：{en, zh}
    NSMutableString *_srcFull, *_zhFull;             // 重新拼出来的整段
    CGFloat _srcPending, _zhPending;                 // 尾巴上还没长出来的字数
    CGFloat _srcAcc, _zhAcc;                         // 小数累计：60Hz 下一帧不足一个字也不卡住
    CGFloat _srcOffset, _zhOffset;                   // 已经往上滚了多少点（整条线，按行推进）
    CGFloat _srcTarget, _zhTarget;
    // 整行上推：用一段有时长的缓动跑完，而不是每帧指数逼近。
    // 以前那种逼近在打字过程中几乎看不出来——字一点点长、位置一点点挪，
    // 用户说的是「满了之后要有一个往上移动的动画」，要的是看得见的那一下。
    BOOL _zhRolling, _srcRolling;
    CFTimeInterval _zhRollT0, _srcRollT0;
    CGFloat _zhRollFrom, _srcRollFrom, _zhRollTo, _srcRollTo;
    CADisplayLink *_link;
    CFTimeInterval _lastTick;
    CGFloat _w, _h, _font, _inset, _midGap, _zhBoxH, _srcBoxH;
    NSInteger _linesZh, _linesSrc;     // 两块各站几行：中窗 3、大窗 5（跟「上推」档一致）
    CGFloat _groupTop;                 // 上下两块整组在窗口里的上沿（整组居中）
    BOOL _built;
}

static const CGFloat kZKZhTypeRate  = 22.0;   // 译文：22 字/秒
static const CGFloat kZKSrcTypeRate = 52.0;   // 原文：52 字符/秒
static const CFTimeInterval kZKRowRollDuration = 0.42;   // 逐字档满一行后整块上推一行的时长

/// 句子往整段后面接：英文之间留一个空格，中文直接接上，同一句重复推到就不再加一遍。
static void ZKSegAppend(NSMutableString *buf, NSString *s) {
    if (!s.length) return;
    if (!buf.length) { [buf appendString:s]; return; }
    if ([buf hasSuffix:s]) return;
    unichar c = [s characterAtIndex:0];
    BOOL latin = (c < 128);
    if (latin) {
        unichar last = [buf characterAtIndex:buf.length - 1];
        if (last != ' ' && last != '\n') [buf appendString:@" "];
    }
    [buf appendString:s];
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.clipsToBounds = YES;
        self.userInteractionEnabled = NO;
        self.backgroundColor = [UIColor clearColor];
        _pairs = [NSMutableArray array];
        _srcFull = [NSMutableString string];
        _zhFull = [NSMutableString string];
        _font = 20;
        _zhBox = [UIView new];
        _srcBox = [UIView new];
        for (UIView *b in @[_zhBox, _srcBox]) {
            b.clipsToBounds = YES;
            b.backgroundColor = [UIColor clearColor];
            b.userInteractionEnabled = NO;
            [self addSubview:b];
        }
        _zhLabel = [UILabel new];
        _srcLabel = [UILabel new];
        for (UILabel *l in @[_zhLabel, _srcLabel]) {
            l.numberOfLines = 0;
            l.lineBreakMode = NSLineBreakByWordWrapping;
            l.adjustsFontSizeToFitWidth = NO;
            l.backgroundColor = [UIColor clearColor];
            l.opaque = NO;
            l.userInteractionEnabled = NO;
            l.textAlignment = NSTextAlignmentLeft;
        }
        [_zhBox addSubview:_zhLabel];
        [_srcBox addSubview:_srcLabel];
    }
    return self;
}

- (BOOL)twoBlocks {
    return ![gMode isEqualToString:@"zh"] && ![gMode isEqualToString:@"source"];
}

- (void)recalcMetrics {
    if (_w < 1 || _h < 1) return;
    CGFloat area = (_w * _h) / (480.0 * 360.0);
    CGFloat scale = sqrt(MAX(0.04, area));
    scale = MAX(0.45, MIN(2.10, scale));
    _font = MAX(12.0, MIN(74.0, gZhBase * scale * 1.35));

    BOOL two = [self twoBlocks];
    _inset = MAX(4.0, _h * 0.03);
    _midGap = two ? MAX(3.0, _font * 0.30) : 0;
    CGFloat avail = MAX(10.0, _h - _inset * 2 - _midGap);

    if (two) {
        // 两块各站固定行数：中窗 3 行译文 + 3 行原文、大窗 5 + 5。
        // 块高取「行数 × 行高」（行高不取整），所以头一行永远是完整的一行，
        // 上推那一下正好切在行边界上——不会出现「最上面一行被切掉半个字」。
        // 放不下就压字号，不拿少一行顶上（压字号才叫真适配）。
        _linesZh = _linesSrc = ([gPipStyle isEqualToString:@"M"] ? 3 : 5);
        CGFloat f = _font;
        for (NSInteger i = 0; i < 120; i++) {
            CGFloat lz = [UIFont boldSystemFontOfSize:f].lineHeight;
            CGFloat ls = [UIFont systemFontOfSize:f * 0.66].lineHeight;
            if ((CGFloat)_linesZh * (lz + ls) <= avail) break;
            f -= 0.5;
            if (f <= 8.0) { f = 8.0; break; }
        }
        _font = f;
        _midGap = MAX(3.0, f * 0.30);
        CGFloat lz = MAX(1.0, [UIFont boldSystemFontOfSize:f].lineHeight);
        CGFloat ls = MAX(1.0, [UIFont systemFontOfSize:f * 0.66].lineHeight);
        _zhBoxH = (CGFloat)_linesZh * lz;
        _srcBoxH = (CGFloat)_linesSrc * ls;
    } else {
        // 只显一种语言：整块铺满，能站几行算几行
        _zhBoxH = _srcBoxH = avail;
        CGFloat lh = MAX(1.0, [UIFont boldSystemFontOfSize:_font].lineHeight);
        _linesZh = _linesSrc = MAX(1, (NSInteger)floor((avail + 0.5) / lh));
    }

    // 上下两块紧挨着成一组，在窗口里垂直居中（顶部/底部空白平均分）
    CGFloat groupH = two ? (_zhBoxH + _midGap + _srcBoxH) : _zhBoxH;
    _groupTop = _inset + MAX(0.0, (avail - groupH) / 2.0);
}

- (void)layoutBlocks {
    if (_w < 1 || _h < 1) return;
    BOOL two = [self twoBlocks];
    BOOL showTrans = ![gMode isEqualToString:@"source"];
    BOOL showSource = ![gMode isEqualToString:@"zh"];
    CGFloat padX = MAX(3.0, _w * 0.016);
    CGFloat bw = MAX(8.0, _w - padX * 2);

    _zhBox.hidden = !(showTrans);
    _srcBox.hidden = !(showSource);
    if (two) {
        _zhBox.frame = CGRectMake(padX, _groupTop, bw, _zhBoxH);
        _srcBox.frame = CGRectMake(padX, _groupTop + _zhBoxH + _midGap, bw, _srcBoxH);
    } else if (showTrans) {
        _zhBox.frame = CGRectMake(padX, _groupTop, bw, _zhBoxH);
    } else {
        _srcBox.frame = CGRectMake(padX, _groupTop, bw, _srcBoxH);
    }

    CGFloat zhF = _font;
    CGFloat srcF = two ? _font * 0.66 : _font;
    _zhLabel.font = [UIFont boldSystemFontOfSize:zhF];
    _srcLabel.font = two ? [UIFont systemFontOfSize:srcF] : [UIFont boldSystemFontOfSize:srcF];
    _zhLabel.textColor = ZKMainColor();
    _srcLabel.textColor = two ? [ZKMainColor() colorWithAlphaComponent:0.62] : ZKMainColor();
}

/// 把「一句一条」重新拼成两整段。拼法固定，所以已经露出来的字数、滚上去的位置都能一直沿用。
- (void)rebuild {
    NSMutableString *src = [NSMutableString string];
    NSMutableString *zh = [NSMutableString string];
    for (NSDictionary *p in _pairs) {
        NSString *e = p[@"en"], *z = p[@"zh"];
        if ([e isKindOfClass:[NSString class]] && e.length) ZKSegAppend(src, e);
        if ([z isKindOfClass:[NSString class]] && z.length) ZKSegAppend(zh, z);
    }
    _srcFull = src;
    _zhFull = zh;
}

- (CGFloat)heightOf:(NSString *)t font:(UIFont *)f width:(CGFloat)w {
    if (!t.length || w < 8 || !f) return 0;
    CGRect r = [t boundingRectWithSize:CGSizeMake(w, CGFLOAT_MAX)
                              options:(NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading)
                           attributes:@{NSFontAttributeName: f}
                              context:nil];
    CGFloat h = ceil(CGRectGetHeight(r));
    return isfinite(h) ? h : 0;
}

- (NSString *)visibleOf:(NSMutableString *)buf pending:(CGFloat)pending {
    NSInteger total = (NSInteger)buf.length;
    NSInteger shown = total - (NSInteger)floor(MAX(0.0, pending));
    if (shown < 0) shown = 0;
    if (shown > total) shown = total;
    return [buf substringToIndex:(NSUInteger)shown];
}

/// 画出来。
///
/// 文字按「已经长出来的那一段」整段排，标签的 y 就是 -offset：
/// offset 每满一行加一个行高，于是整块文字就往上走一行、最上面那一行被裁掉。
/// snap = YES 时不走动画（换档、补译文这种「内容整体变了」的场合，动了反而像跳）。
- (void)render {
    [self renderSnap:NO];
}

- (void)renderSnap:(BOOL)snap {
    if (!_built || _w < 1) return;

    if (!_zhBox.hidden) {
        NSString *vis = [self visibleOf:_zhFull pending:_zhPending];
        CGFloat bw = CGRectGetWidth(_zhBox.bounds);
        CGFloat bh = CGRectGetHeight(_zhBox.bounds);
        CGFloat h = [self heightOf:vis font:_zhLabel.font width:bw];
        // 行高不取整：块高是「行数 × 行高」，这样 offset 走一行就正好切在行边界上，
        // 头顶那一行是完整消失的，不会露出半行。
        CGFloat lineH = MAX(1.0, _zhLabel.font.lineHeight);
        NSInteger lines = MAX(1, _linesZh);
        CGFloat nt = MAX(0.0, h - lines * lineH);
        [self aimZh:nt lineH:lineH snap:snap];
        if (![_zhLabel.text isEqualToString:vis]) _zhLabel.text = vis;
        // 块高一般不是行高的整数倍：这点余量固定补在底下，最新那一行正好贴着块底。
        // 注意必须**恒定**——以前是「滚起来之后才补」，那一补让整块先往下一沉，
        // 上推那一下正好被抵消，看着就像没动。
        CGFloat pad = MAX(0.0, bh - lines * lineH);
        _zhLabel.frame = CGRectMake(0, -_zhOffset + pad, bw, MAX(h, lineH));
    }
    if (!_srcBox.hidden) {
        NSString *vis = [self visibleOf:_srcFull pending:_srcPending];
        CGFloat bw = CGRectGetWidth(_srcBox.bounds);
        CGFloat bh = CGRectGetHeight(_srcBox.bounds);
        CGFloat h = [self heightOf:vis font:_srcLabel.font width:bw];
        CGFloat lineH = MAX(1.0, _srcLabel.font.lineHeight);
        NSInteger lines = MAX(1, _linesSrc);
        CGFloat nt = MAX(0.0, h - lines * lineH);
        [self aimSrc:nt lineH:lineH snap:snap];
        if (![_srcLabel.text isEqualToString:vis]) _srcLabel.text = vis;
        CGFloat padS = MAX(0.0, bh - lines * lineH);
        _srcLabel.frame = CGRectMake(0, -_srcOffset + padS, bw, MAX(h, lineH));
    }
}

/// 目标位置变了就开一段「整行上推」：时长固定 0.42 秒、ease-out，
/// 走完正好一行，顶上那一行被裁出画面。
/// snap（换档、补译文这种内容整体变了的场合）或一次跨太多行时直接对位，不要滑。
- (void)aimZh:(CGFloat)nt lineH:(CGFloat)lineH snap:(BOOL)snap {
    if (snap) {
        _zhTarget = nt;
        _zhOffset = nt;
        _zhRolling = NO;
        return;
    }
    if (fabs(nt - _zhTarget) < 0.5) return;          // 还在这几行里，位置不用动
    _zhTarget = nt;
    if (fabs(nt - _zhOffset) > lineH * 6.0) {        // 跨太多行：直接对位
        _zhOffset = nt;
        _zhRolling = NO;
        return;
    }
    if (_zhRolling) return;                          // 正在滚：滚到目标再接着算
    _zhRolling = YES;
    _zhRollFrom = _zhOffset;
    _zhRollTo = nt;
    _zhRollT0 = CACurrentMediaTime();
}

- (void)aimSrc:(CGFloat)nt lineH:(CGFloat)lineH snap:(BOOL)snap {
    if (snap) {
        _srcTarget = nt;
        _srcOffset = nt;
        _srcRolling = NO;
        return;
    }
    if (fabs(nt - _srcTarget) < 0.5) return;
    _srcTarget = nt;
    if (fabs(nt - _srcOffset) > lineH * 6.0) {
        _srcOffset = nt;
        _srcRolling = NO;
        return;
    }
    if (_srcRolling) return;
    _srcRolling = YES;
    _srcRollFrom = _srcOffset;
    _srcRollTo = nt;
    _srcRollT0 = CACurrentMediaTime();
}

- (void)ensureTyping {
    if (_link) return;
    BOOL pending = (_zhPending > 0.5 && !_zhBox.hidden) || (_srcPending > 0.5 && !_srcBox.hidden);
    BOOL moving = _zhRolling || _srcRolling
               || fabs(_zhOffset - _zhTarget) > 0.4 || fabs(_srcOffset - _srcTarget) > 0.4;
    if (!pending && !moving) return;
    _lastTick = CACurrentMediaTime();
    _link = [CADisplayLink displayLinkWithTarget:self selector:@selector(step:)];
    if (@available(iOS 15.0, *)) {
        _link.preferredFrameRateRange = CAFrameRateRangeMake(30, 120, 60);
    }
    [_link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

- (void)stopTyping {
    if (_link) {
        [_link invalidate];
        _link = nil;
    }
}

- (void)step:(CADisplayLink *)link {
    CFTimeInterval now = CACurrentMediaTime();
    CGFloat dt = (CGFloat)(now - _lastTick);
    _lastTick = now;
    if (dt <= 0) return;
    if (dt > 0.20) dt = 0.20;      // 从后台回来别一口气甩一大段

    BOOL changed = NO;
    if (!_zhBox.hidden && _zhPending > 0) {
        // 落后太多就走快一点：是变速，不是跳字
        CGFloat boost = MIN(4.0, 1.0 + MAX(0.0, _zhPending - 12.0) / 24.0);
        _zhAcc += dt * kZKZhTypeRate * boost;
        NSInteger add = (NSInteger)floor(_zhAcc);
        if (add > 0) {
            _zhAcc -= (CGFloat)add;
            _zhPending = MAX(0, _zhPending - (CGFloat)add);
            changed = YES;
        }
    }
    if (!_srcBox.hidden && _srcPending > 0) {
        CGFloat boost = MIN(4.0, 1.0 + MAX(0.0, _srcPending - 24.0) / 40.0);
        _srcAcc += dt * kZKSrcTypeRate * boost;
        NSInteger add = (NSInteger)floor(_srcAcc);
        if (add > 0) {
            _srcAcc -= (CGFloat)add;
            _srcPending = MAX(0, _srcPending - (CGFloat)add);
            changed = YES;
        }
    }

    // 满行之后整块往上推一行：目标位置是按行算好的，这里每帧追一点，
    // 追的过程就是「由下往上滚」那一行。帧率掉了也只是步子变大，不会跳。
    CGFloat k = MIN(1.0, dt * 18.0);
    if (_zhRolling) {
        CGFloat p = MIN(1.0, (CGFloat)(now - _zhRollT0) / kZKRowRollDuration);
        CGFloat e = 1.0 - pow(1.0 - p, 3.0);        // ease-out：起步快、落位轻
        _zhOffset = _zhRollFrom + (_zhRollTo - _zhRollFrom) * e;
        if (p >= 1.0) { _zhOffset = _zhRollTo; _zhRolling = NO; }
        changed = YES;
    } else if (fabs(_zhOffset - _zhTarget) > 0.4) {
        _zhOffset += (_zhTarget - _zhOffset) * k;
        changed = YES;
    } else if (_zhOffset != _zhTarget) {
        _zhOffset = _zhTarget;
        changed = YES;
    }
    if (_srcRolling) {
        CGFloat p = MIN(1.0, (CGFloat)(now - _srcRollT0) / kZKRowRollDuration);
        CGFloat e = 1.0 - pow(1.0 - p, 3.0);
        _srcOffset = _srcRollFrom + (_srcRollTo - _srcRollFrom) * e;
        if (p >= 1.0) { _srcOffset = _srcRollTo; _srcRolling = NO; }
        changed = YES;
    } else if (fabs(_srcOffset - _srcTarget) > 0.4) {
        _srcOffset += (_srcTarget - _srcOffset) * k;
        changed = YES;
    } else if (_srcOffset != _srcTarget) {
        _srcOffset = _srcTarget;
        changed = YES;
    }

    if (changed) [self render];
    BOOL pending = (_zhPending > 0.5 && !_zhBox.hidden) || (_srcPending > 0.5 && !_srcBox.hidden);
    BOOL moving = _zhRolling || _srcRolling
               || fabs(_zhOffset - _zhTarget) > 0.4 || fabs(_srcOffset - _srcTarget) > 0.4;
    if (!pending && !moving) {
        _zhPending = 0;
        _srcPending = 0;
        _zhOffset = _zhTarget;
        _srcOffset = _srcTarget;
        [self render];
        [self stopTyping];
    }
}

- (void)addEn:(NSString *)en zh:(NSString *)zh {
    NSString *e = [en isKindOfClass:[NSString class]] ? en : @"";
    NSString *z = [zh isKindOfClass:[NSString class]] ? zh : @"";
    if (!e.length && !z.length) return;
    if (_w < 1 || _h < 1) return;

    NSMutableDictionary *last = _pairs.lastObject;
    if (last && e.length && [last[@"en"] isEqualToString:e]) {
        // 同一句又推一遍：只有它还缺译文时才补上，不再多占一段
        if (![last[@"zh"] length] && z.length) {
            last[@"zh"] = z;
            [self rebuild];
            _zhPending += (CGFloat)z.length;
            [self render];
            [self ensureTyping];
        }
        return;
    }

    NSMutableDictionary *p = [NSMutableDictionary dictionary];
    if (e.length) p[@"en"] = e;
    if (z.length) p[@"zh"] = z;
    [_pairs addObject:p];

    // 只留最近一段：长了没意义也占内存。丢的是头顶早就滚出画面的那几句，
    // 丢完把滚动位置一起往回退同样高度，画面上一个字都不会动。
    while (_pairs.count > 40) {
        NSMutableDictionary *old = _pairs.firstObject;
        NSString *oe = old[@"en"], *oz = old[@"zh"];
        CGFloat bwz = CGRectGetWidth(_zhBox.bounds);
        CGFloat bws = CGRectGetWidth(_srcBox.bounds);
        CGFloat dz = [oz isKindOfClass:[NSString class]] ? [self heightOf:oz font:_zhLabel.font width:bwz] : 0;
        CGFloat de = [oe isKindOfClass:[NSString class]] ? [self heightOf:oe font:_srcLabel.font width:bws] : 0;
        [_pairs removeObjectAtIndex:0];
        _zhOffset = MAX(0, _zhOffset - dz);
        _zhTarget = MAX(0, _zhTarget - dz);
        _srcOffset = MAX(0, _srcOffset - de);
        _srcTarget = MAX(0, _srcTarget - de);
    }

    [self rebuild];
    if (!_zhBox.hidden && z.length) _zhPending += (CGFloat)z.length;
    if (!_srcBox.hidden && e.length) _srcPending += (CGFloat)e.length;
    [self render];
    [self ensureTyping];
}

- (void)patchZh:(NSString *)zh forEn:(NSString *)en {
    if (![zh isKindOfClass:[NSString class]] || !zh.length) return;
    NSInteger hit = -1;
    for (NSInteger i = (NSInteger)_pairs.count - 1; i >= 0; i--) {
        NSMutableDictionary *p = _pairs[(NSUInteger)i];
        NSString *e = p[@"en"];
        if (![e isKindOfClass:[NSString class]]) e = @"";
        if (en.length) {
            if ([e isEqualToString:en]) { hit = i; break; }
        } else if (e.length && ![p[@"zh"] length]) {
            hit = i;
            break;
        }
    }
    if (hit < 0) return;                     // 这一句已经滚出画面了：丢掉，绝不硬塞到尾巴上
    NSMutableDictionary *p = _pairs[(NSUInteger)hit];
    if ([p[@"zh"] length]) return;           // 已经有译文，不重复
    p[@"zh"] = zh;
    [self rebuild];
    if (!_zhBox.hidden) _zhPending += (CGFloat)zh.length;
    // 补的是前面某一句：整段会变长，滚动位置直接对到新位置，别让画面滑一下
    [self renderSnap:YES];
    [self ensureTyping];
}

- (void)patchLastZh:(NSString *)zh {
    if (![zh isKindOfClass:[NSString class]] || !zh.length) return;
    [self patchZh:zh forEn:@""];
}

- (void)resetWithLines:(NSArray *)lines {
    [self stopTyping];
    [_pairs removeAllObjects];
    _srcPending = 0; _zhPending = 0;
    _srcAcc = 0; _zhAcc = 0;
    _srcOffset = 0; _zhOffset = 0;
    _srcTarget = 0; _zhTarget = 0;
    if ([lines isKindOfClass:[NSArray class]]) {
        for (id o in lines) {
            if (![o isKindOfClass:[NSDictionary class]]) continue;
            NSString *e = o[@"en"], *z = o[@"zh"];
            if (![e isKindOfClass:[NSString class]]) e = @"";
            if (![z isKindOfClass:[NSString class]]) z = @"";
            if (!e.length && !z.length) continue;
            NSMutableDictionary *p = [NSMutableDictionary dictionary];
            if (e.length) p[@"en"] = e;
            if (z.length) p[@"zh"] = z;
            [_pairs addObject:p];
        }
    }
    [self rebuild];
    [self renderSnap:YES];
}

- (void)setBoxWidth:(CGFloat)w height:(CGFloat)h force:(BOOL)force {
    if (w < 1 || h < 1) return;
    BOOL changed = fabs(w - _w) > 0.5 || fabs(h - _h) > 0.5;
    _w = w;
    _h = h;
    if (!changed && !force && _built) return;
    _built = YES;
    [self recalcMetrics];
    [self layoutBlocks];
    [self dropHiddenPending];
    [self renderSnap:YES];
    [self ensureTyping];
}

- (void)refreshStyle {
    if (!_built) return;
    [self recalcMetrics];
    [self layoutBlocks];
    [self dropHiddenPending];
    [self renderSnap:YES];
    [self ensureTyping];
}

/// 只显一种语言时，藏着的那一块不该攒着「还没长出来的字」，
/// 否则切回来会突然自己往外冒一段旧内容。
- (void)dropHiddenPending {
    if (_zhBox.hidden) { _zhPending = 0; _zhAcc = 0; }
    if (_srcBox.hidden) { _srcPending = 0; _srcAcc = 0; }
}

@end

// 做三件事：
// 1) 中文一行一组、源语言一行一组，各自居中，中文在上、原文在下；
// 2) 字号只跟窗口走，跟这一句多长完全无关——长句靠换行，绝不缩字、绝不缩窗；
// 3) 一批句子要么整批塞得进（两行都按换行算高度），要么就整批换下一批，
//    不存在「这一行的后半句跑到下一行开头」那种串行。
// 节奏：按阅读速度定每一屏停多久（见 holdSecondsFor），积压时自动压缩，绝不无限延迟。
@interface ZKWideView : UIView
- (void)setBoxWidth:(CGFloat)width height:(CGFloat)height force:(BOOL)force;
- (void)resetWithLines:(NSArray *)lines;
- (void)addEn:(NSString *)en zh:(NSString *)zh;
- (void)patchLastZh:(NSString *)zh;
- (void)patchZh:(NSString *)zh forEn:(NSString *)en;
- (void)refreshStyle;
- (BOOL)needsZh:(NSDictionary *)it;
- (BOOL)applyZh:(NSString *)zh forEn:(NSString *)en;
// 上切（小窗）：新的一批从下面顶上来，老的一批整块被切出画面顶端
- (BOOL)cutMode;
- (void)layoutZh:(UILabel *)zhLabel src:(UILabel *)srcLabel items:(NSArray<NSDictionary *> *)items;
- (void)commitFade;
@end

@implementation ZKWideView {
    UILabel *_zhLabel;                         // 译文行（上）
    UILabel *_srcLabel;                        // 原文行（下）
    // 小窗两档：叠化 = 新的一批先摆到「背面」那两行上，再让旧的淡出、新的淡入；
    // 上切 = 新的一批从下面顶上来、老的一批整块切走（见 renderAnimated 里的 cut 分支）。
    UILabel *_zhBack;
    UILabel *_srcBack;
    ZKAnim *_fade;
    CGFloat _w;
    CGFloat _h;
    CGFloat _font;                             // 译文行字号，原文行按比例取小
    NSArray<NSDictionary *> *_current;         // 现在屏上这一批，由哪几句拼成
    NSMutableArray<NSDictionary *> *_queue;    // 还没上屏的整句
    NSDate *_shownAt;                          // 这一屏是什么时候上来的
    NSDate *_holdUntil;                        // 这一屏最少停到什么时候（按阅读速度算）
    NSMutableArray<NSString *> *_pending;      // 已经上队、译文还没到的原文（先进先出，补译文时按顺序对号）
    NSTimer *_drain;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.clipsToBounds = YES;
        self.userInteractionEnabled = NO;
        self.backgroundColor = [UIColor clearColor];
        _queue = [NSMutableArray array];
        _pending = [NSMutableArray array];
        _font = 20;
        _zhLabel = [self makeRow];
        _srcLabel = [self makeRow];
        [self addSubview:_zhLabel];
        [self addSubview:_srcLabel];

        _zhBack = [self makeRow];
        _srcBack = [self makeRow];
        _zhBack.alpha = 0;
        _srcBack.alpha = 0;
        [self addSubview:_zhBack];
        [self addSubview:_srcBack];
    }
    return self;
}

- (UILabel *)makeRow {
    UILabel *l = [UILabel new];
    l.numberOfLines = 0;
    l.lineBreakMode = NSLineBreakByWordWrapping;
    l.textAlignment = NSTextAlignmentCenter;
    l.adjustsFontSizeToFitWidth = NO;
    l.baselineAdjustment = UIBaselineAdjustmentAlignCenters;
    l.backgroundColor = [UIColor clearColor];
    l.textColor = [UIColor whiteColor];
    return l;
}

#pragma mark 显示哪几行

- (BOOL)showTrans { return ![gMode isEqualToString:@"source"]; }
- (BOOL)showSource { return ![gMode isEqualToString:@"zh"]; }
- (BOOL)twoRows { return [self showTrans] && [self showSource]; }

/// 小窗的上切：新一批从下面顶上来，老一批整块切走（不淡入淡出）
- (BOOL)cutMode { return [gScroll isEqualToString:@"cut"]; }

- (UIFont *)zhFont:(CGFloat)f { return [UIFont boldSystemFontOfSize:f]; }
- (UIFont *)srcFont:(CGFloat)f { return [UIFont systemFontOfSize:f * 0.68]; }

- (CGFloat)zhLineH { return ceil(_font * 1.24); }
- (CGFloat)srcLineH { return ceil(_font * 0.68 * 1.26); }

/// 译文行最多几行、原文行最多几行：按窗口高度分，跟内容无关（内容不会改变字号）
- (NSInteger)zhCap {
    if (_h < 1 || _font < 1) return 2;
    if (![self twoRows]) return MAX(1, (NSInteger)floor(_h / MAX(1.0, [self zhLineH])));
    // 0.66：字号提上去之后，长句还得能在译文行里折成两行，
    // 换算下来两行译文 + 一行原文正好落在窗高之内。
    return MAX(1, (NSInteger)floor((_h * 0.66) / MAX(1.0, [self zhLineH])));
}

- (NSInteger)srcCap {
    if (_h < 1 || _font < 1) return 2;
    if (![self twoRows]) return MAX(1, (NSInteger)floor(_h / MAX(1.0, [self srcLineH])));
    return MAX(1, (NSInteger)floor((_h * 0.30) / MAX(1.0, [self srcLineH])));
}

#pragma mark 字号

// 字号只跟窗口走：宽度定「一行大概放几个汉字」，高度定「两行最多能占多高」，取小的那个。
// 用户设置里的字号在这一档不生效——窗口长宽比和竖排完全不是一回事，强塞会挤爆两行。
- (void)recalcFont {
    if (_w < 1 || _h < 1) return;
    // 一句一行之后，横条上的留白变多了，字号可以再放大一档（45 → 48 左右）。
    // 仍然只跟窗口走，跟这一句多长无关：长句靠换行，绝不缩字。
    CGFloat byWidth = _w / 17.2;       // 一行十七八个汉字，比上一版大一圈
    CGFloat byHeight = _h / 3.7;       // 两行译文 + 一行原文，各自留一点余量
    CGFloat f = MIN(byWidth, byHeight);
    _font = MAX(13.0, MIN(64.0, f));
}

#pragma mark 文本与测量

// 一批句子拼成一行：中文用全角空格隔开，英文用两个半角空格，读起来都有停顿感。
//
// 一条规矩：句子是**整句单位**，不许被拆到两行去。
// 以前是整批拼成一串直接交给 UILabel 自己换行，UILabel 只看字符，不看句子，
// 于是就会出现「上一行的后半句跑到下一行开头」，一句话被劈成两截，读起来串行。
// 现在自己排版：先量每句在当前字号下的整行宽，一句塞得进当前行就接着排，
// 塞不进就整句换到下一行；只有单句本身就比一整行还长的长句，才在它内部换行。
// 这样「一句两句并排铺满」还在，长句也不用缩字。
- (NSString *)lineFor:(NSArray<NSDictionary *> *)items key:(NSString *)key {
    BOOL chinese = [key isEqualToString:@"zh"];
    UIFont *font = [self zhFont:_font];
    if (!chinese) font = [self srcFont:_font];
    NSString *sep = chinese ? @"　" : @"  ";   // 中文用全角空格、英文用两个半角，都有停顿感
    CGFloat limit = [self textLimit];           // 量的宽度 = 排字时真正的宽度，一点不差

    // 一句一条，句子是**整句单位**：宁可这一行没铺满，也不许一句话被劈到两行去。
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSDictionary *it in items) {
        id v = it[key];
        if ([v isKindOfClass:[NSString class]] && [v length]) [parts addObject:v];
    }
    if (!parts.count) return @"";
    if (!(_w > 1) || !font || limit < 8) return [parts componentsJoinedByString:sep];

    // 逐句往里塞，塞之前先按真实排版量一遍：这一行加上这句还是不是「一行」。
    // 不靠宽度相加来估（估的和 UILabel 实际排的差一两点就会串行），而是直接量行数。
    CGFloat oneLineH = ceil(font.lineHeight) + 0.5;
    NSMutableString *out = [NSMutableString string];
    NSMutableString *cur = [NSMutableString string];
    for (NSString *part in parts) {
        if (!cur.length) {
            [cur appendString:part];
            continue;
        }
        NSString *cand = [NSString stringWithFormat:@"%@%@%@", cur, sep, part];
        // 超过一行高度（说明这句塞不进去会换行）就把它整句挪到下一行
        if (ZKTextHeight(cand, limit, font, 0) > oneLineH) {
            if (out.length) [out appendString:@"\n"];
            [out appendString:cur];
            cur = [NSMutableString stringWithString:part];
        } else {
            [cur appendString:sep];
            [cur appendString:part];
        }
    }
    if (cur.length) {
        if (out.length) [out appendString:@"\n"];
        [out appendString:cur];
    }
    return out;
}

/// 文字真正能用的宽度：左右各留 5pt。
/// 量的时候和 UILabel 排字的时候必须用同一个宽度——差一两个点，
/// 一句本来排得下的句子就会被 UILabel 自己再折一次，后半句掉到下一行开头。
- (CGFloat)textLimit {
    return MAX(8.0, _w - 10.0);
}

/// 这一批在屏上占多高（按换行算，不封顶）
- (CGFloat)zhHeightFor:(NSArray<NSDictionary *> *)items {
    if (![self showTrans]) return 0;
    return ZKTextHeight([self lineFor:items key:@"zh"], [self textLimit], [self zhFont:_font], 0);
}

- (CGFloat)srcHeightFor:(NSArray<NSDictionary *> *)items {
    if (![self showSource]) return 0;
    return ZKTextHeight([self lineFor:items key:@"en"], [self textLimit], [self srcFont:_font], 0);
}

/// 这一批是不是整批都塞得进（两行都算上换行，绝不靠缩字硬塞）
- (BOOL)fits:(NSArray<NSDictionary *> *)items {
    if (!items.count) return YES;
    CGFloat zhCapH = [self zhCap] * [self zhLineH] + 1.0;
    CGFloat srcCapH = [self srcCap] * [self srcLineH] + 1.0;
    if ([self showTrans] && [self zhHeightFor:items] > zhCapH) return NO;
    if ([self showSource] && [self srcHeightFor:items] > srcCapH) return NO;
    return YES;
}

#pragma mark 出字

/// 这一句是不是「有原文、但译文还没到」
- (BOOL)needsZh:(NSDictionary *)it {
    if (![it isKindOfClass:[NSDictionary class]]) return NO;
    id z = it[@"zh"];
    id e = it[@"en"];
    if ([z isKindOfClass:[NSString class]] && [z length]) return NO;
    return [e isKindOfClass:[NSString class]] && [e length] > 0;
}

- (void)scheduleAfter:(NSTimeInterval)delay {
    [_drain invalidate];
    _drain = nil;
    if (delay < 0.02) delay = 0.02;
    __weak typeof(self) weakSelf = self;
    _drain = [NSTimer scheduledTimerWithTimeInterval:delay repeats:NO block:^(NSTimer *t) {
        [weakSelf pump];
    }];
    _drain.tolerance = delay * 0.2;
}

- (void)pump {
    [_drain invalidate];
    _drain = nil;
    if (_w < 1 || _h < 1) return;
    if (_queue.count == 0) return;

    // 这一屏还没到「读得完」的时间，就先不换——下限由下面的 holdSecondsFor 控住，
    // 不会因为等它而落后：积压越多，每一屏停得越短。
    if (_holdUntil) {
        NSTimeInterval left = [_holdUntil timeIntervalSinceNow];
        if (left > 0.02) {
            [self scheduleAfter:left];
            return;
        }
    }

    NSInteger pressure = (NSInteger)_queue.count;

    // 不再为了等译文把整条流压住。
    //
    // 上一版在这里有两道闸：队首那句没译文就等最多 1.2 秒，屏上这句没译文再多留 2 秒。
    // 结果是一句话在说快的时候，每句都要先等一会，队列只增不减——
    // 说得越久屏幕上越落后，用户看到的就是「越用越慢、延迟越来越高」。
    // 现在的规矩：原文来了立刻上屏；译文到了按原文精确回填到那一行（patchZh:forEn:），
    // 回填不了就说明那句早就下屏了，那也是正常的——画面不再为它停下来等。

    // 追赶：后面还堆着两句以上，说明已经落后于嘴了。
    // 这时候不逐句补播（越补越远），只留最新一句，把时间拉回来。
    if (pressure >= 3) {
        while (_queue.count > 1) {
            NSString *dropped = ((NSDictionary *)_queue.firstObject)[@"en"];
            if ([dropped isKindOfClass:[NSString class]] && dropped.length) [_pending removeObject:dropped];
            [_queue removeObjectAtIndex:0];
        }
        pressure = (NSInteger)_queue.count;
        _holdUntil = nil;
    }

    // 一句一批：默认屏上只放「一整句」。
    // 只有真的积压（快速连说、句子又短）时，才把相邻两句并成一批：
    // 少换一次屏，等于这两句在屏上多待一会儿，语速再快也不会一闪而过。
    // 合并只发生在整句之间，句子本身仍然不会被劈到两行。
    NSMutableArray *batch = [NSMutableArray arrayWithObject:_queue.firstObject];
    if (pressure >= 3 && _queue.count > 1) {
        NSArray *pair = @[_queue[0], _queue[1]];
        if ([self pairIsShort:pair] && [self fits:pair] && [self readSeconds:pair] <= 2.4) {
            [batch addObject:_queue[1]];
            [_queue removeObjectAtIndex:1];
        }
    }
    [_queue removeObjectAtIndex:0];
    _current = batch;
    [self renderAnimated:YES];
    _shownAt = [NSDate date];

    NSTimeInterval hold = [self holdSecondsFor:batch pressure:(NSInteger)_queue.count];
    // 屏上这句还只有原文、后面又没别的话要上：那就多留一会儿等译文。
    // 这时候压着不会造成"越拖越远"（队列是空的），但能让中文落到看得见的那一行上。
    if (!_queue.count && [self showTrans] && [self needsZh:batch.firstObject]) {
        hold = MAX(hold, 1.0);
    }
    _holdUntil = [NSDate dateWithTimeIntervalSinceNow:hold];
    if (_queue.count) [self scheduleAfter:hold];
}

/// 这两句合起来是不是「短句」——只有短句才值得合并，
/// 长句拼一起一行塞不下，合并也没意义。
- (BOOL)pairIsShort:(NSArray *)items {
    NSUInteger zh = 0, en = 0;
    for (NSDictionary *it in items) {
        if ([self showTrans]) zh += ZKVisibleLen(it[@"zh"]);
        if ([self showSource]) en += ZKVisibleLen(it[@"en"]);
    }
    return zh <= 30 && en <= 64;
}

/// 读完这一批大概要多久：中文按 10 字/秒，英文按 18 字符/秒，
/// 再加 0.35 秒「眼睛锁定这一行」的固定开销。都是横条字幕的扫读速度，不是逐字朗读。
- (NSTimeInterval)readSeconds:(NSArray *)items {
    NSUInteger zh = 0, en = 0;
    for (NSDictionary *it in items) {
        if ([self showTrans]) zh += ZKVisibleLen(it[@"zh"]);
        if ([self showSource]) en += ZKVisibleLen(it[@"en"]);
    }
    CGFloat need = MAX(zh / 10.0, en / 18.0) + 0.25;
    return need;
}

/// 这一屏该停多久。
///
/// 规则：按字数算出「读得完」的时间，再用积压量往下压——
/// 后面堆得越多，每一屏停得越短，保证画面追得上嘴，而不是无限往后拖。
/// 下限 0.30 秒（再快就成了闪一下），上限 1.8 秒。
/// 上一版是 0.55~2.6 秒，小窗里一句要等一秒多才换上来，看着就是「上屏慢」；
/// 现在整条节奏往前挪一档：积压一出现就压缩，不等堆到两句才开始。
- (NSTimeInterval)holdSecondsFor:(NSArray *)items pressure:(NSInteger)pressure {
    CGFloat need = [self readSeconds:items];
    CGFloat factor = 0.80;
    if (pressure >= 1) factor = 0.62;
    if (pressure >= 2) factor = 0.48;
    if (pressure >= 3) factor = 0.36;
    CGFloat hold = need * factor;
    return MIN(1.6, MAX(0.24, hold));
}

- (NSAttributedString *)attr:(NSString *)t font:(UIFont *)f color:(UIColor *)c {
    if (![t isKindOfClass:[NSString class]] || !t.length) return [[NSAttributedString alloc] initWithString:@""];
    NSMutableParagraphStyle *p = [NSMutableParagraphStyle new];
    p.alignment = NSTextAlignmentCenter;
    p.lineBreakMode = NSLineBreakByWordWrapping;
    return [[NSAttributedString alloc] initWithString:t
                                          attributes:@{NSFontAttributeName: f,
                                                       NSForegroundColorAttributeName: c,
                                                       NSParagraphStyleAttributeName: p}];
}

/// 按这一批实际占的高度，两行垂直居中排；高度封顶在各自的行数上限，超出的整句不会跑到另一行去。
- (void)layoutRowsFor:(NSArray<NSDictionary *> *)items {
    [self layoutZh:_zhLabel src:_srcLabel items:items];
}

/// 前后两页用同一套排版，交叉淡入时位置才对得上（不然淡到一半会看到字在挪）
- (void)layoutZh:(UILabel *)zhLabel src:(UILabel *)srcLabel items:(NSArray<NSDictionary *> *)items {
    if (_w < 1 || _h < 1) return;
    BOOL two = [self twoRows];

    CGFloat zhH = 0, srcH = 0;
    if ([self showTrans]) {
        zhH = MIN([self zhHeightFor:items], [self zhCap] * [self zhLineH] + 1.0);
    }
    if ([self showSource]) {
        srcH = MIN([self srcHeightFor:items], [self srcCap] * [self srcLineH] + 1.0);
    }
    CGFloat gap = (zhH > 0 && srcH > 0) ? MAX(2.0, _h * 0.05) : 0;
    CGFloat total = zhH + gap + srcH;
    CGFloat y = MAX(0, (_h - total) / 2.0);

    if (two) {
        zhLabel.hidden = (zhH <= 0);
        srcLabel.hidden = (srcH <= 0);
        zhLabel.numberOfLines = [self zhCap];
        srcLabel.numberOfLines = [self srcCap];
        CGFloat x = (_w - [self textLimit]) / 2.0;
        zhLabel.frame = CGRectMake(x, y, [self textLimit], zhH);
        srcLabel.frame = CGRectMake(x, y + zhH + gap, [self textLimit], srcH);
    } else if ([self showTrans]) {
        zhLabel.hidden = NO;
        srcLabel.hidden = YES;
        srcLabel.frame = CGRectZero;
        zhLabel.numberOfLines = [self zhCap];
        zhLabel.frame = CGRectMake((_w - [self textLimit]) / 2.0, y, [self textLimit], zhH);
    } else {
        srcLabel.hidden = NO;
        zhLabel.hidden = YES;
        zhLabel.frame = CGRectZero;
        srcLabel.numberOfLines = [self srcCap];
        srcLabel.frame = CGRectMake((_w - [self textLimit]) / 2.0, y, [self textLimit], srcH);
    }
}

/// 把「背面那两行」扶正：交叉淡入结束（或者被下一句打断）都走这里
- (void)commitFade {
    UILabel *oz = _zhLabel, *os = _srcLabel;
    _zhLabel = _zhBack;
    _srcLabel = _srcBack;
    _zhBack = oz;
    _srcBack = os;
    _zhLabel.alpha = 1; _srcLabel.alpha = 1;
    _zhBack.alpha = 0; _srcBack.alpha = 0;
    // 上切用过 transform：换过位置之后两边都要归零，否则下一批还偏在画面外
    _zhLabel.transform = CGAffineTransformIdentity;
    _srcLabel.transform = CGAffineTransformIdentity;
    _zhBack.transform = CGAffineTransformIdentity;
    _srcBack.transform = CGAffineTransformIdentity;
    _zhBack.attributedText = nil; _srcBack.attributedText = nil;
}

- (void)renderAnimated:(BOOL)animated {
    // 上一批的淡入还没走完、下一批就来了（说得快的时候真会发生）：
    // 先把上一次落定，否则两批字会叠在一起。
    if (_fade) {
        [_fade cancel];
        _fade = nil;
        [self commitFade];
    }
    if (!_current.count) {
        if (_fade) { [_fade cancel]; _fade = nil; }
        for (UILabel *l in @[_zhLabel, _srcLabel, _zhBack, _srcBack]) {
            l.attributedText = nil;
            l.frame = CGRectZero;
        }
        _zhLabel.alpha = 1; _srcLabel.alpha = 1;
        _zhBack.alpha = 0; _srcBack.alpha = 0;
        return;
    }
    NSString *zh = [self showTrans] ? [self lineFor:_current key:@"zh"] : @"";
    NSString *src = [self showSource] ? [self lineFor:_current key:@"en"] : @"";

    _zhLabel.hidden = NO;
    _srcLabel.hidden = NO;
    _zhBack.hidden = NO;
    _srcBack.hidden = NO;
    _zhLabel.alpha = 1;
    _srcLabel.alpha = 1;

    UIColor *main = ZKMainColor();
    NSAttributedString *za = [self attr:zh font:[self zhFont:_font] color:main];
    NSAttributedString *sa = [self attr:src font:[self srcFont:_font]
                                   color:[main colorWithAlphaComponent:0.62]];

    // 第一批（或者重建）：直接摆上去，不从看不见淡一遍
    BOOL first = (_zhLabel.attributedText.length == 0 && _srcLabel.attributedText.length == 0);
    if (!animated || first) {
        if (_fade) { [_fade cancel]; _fade = nil; }
        _zhLabel.attributedText = za;
        _srcLabel.attributedText = sa;
        [self layoutRowsFor:_current];
        _zhLabel.alpha = 1; _srcLabel.alpha = 1;
        _zhBack.attributedText = nil; _srcBack.attributedText = nil;
        _zhBack.alpha = 0; _srcBack.alpha = 0;
        _zhLabel.transform = CGAffineTransformIdentity;
        _srcLabel.transform = CGAffineTransformIdentity;
        _zhBack.transform = CGAffineTransformIdentity;
        _srcBack.transform = CGAffineTransformIdentity;
        return;
    }

    _zhBack.attributedText = za;
    _srcBack.attributedText = sa;
    [self layoutZh:_zhBack src:_srcBack items:_current];

    // 上切：新的一批从下面整体顶上来，老的一批被切出画面顶端。
    // 不是淡入淡出、不是横向推，就是一次干脆的纵向切换。
    if ([self cutMode]) {
        _zhLabel.transform = CGAffineTransformIdentity;
        _srcLabel.transform = CGAffineTransformIdentity;
        _zhBack.transform = CGAffineTransformMakeTranslation(0, _h);
        _srcBack.transform = CGAffineTransformMakeTranslation(0, _h);
        _zhLabel.alpha = 1; _srcLabel.alpha = 1;
        _zhBack.alpha = 1; _srcBack.alpha = 1;
        if (_fade) { [_fade cancel]; _fade = nil; }
        __weak typeof(self) weakSelf = self;
        _fade = [ZKAnim run:0.24 tick:^(CGFloat p) {
            typeof(self) s = weakSelf;
            if (!s) return;
            CGFloat e = 1.0 - pow(1.0 - p, 3.0);      // ease-out：起来快、落位稳
            s->_zhLabel.transform = CGAffineTransformMakeTranslation(0, -s->_h * e);
            s->_srcLabel.transform = CGAffineTransformMakeTranslation(0, -s->_h * e);
            s->_zhBack.transform = CGAffineTransformMakeTranslation(0, s->_h * (1.0 - e));
            s->_srcBack.transform = CGAffineTransformMakeTranslation(0, s->_h * (1.0 - e));
        } done:^{
            typeof(self) s = weakSelf;
            if (!s) return;
            s->_fade = nil;
            [s commitFade];
        }];
        return;
    }

    // 叠化：旧的一批淡出、新的一批淡入，全程不动位置。
    // 走的是逐帧插值，不依赖被后台降频的系统补间，所以每一下都是顺的。
    _zhBack.alpha = 0; _srcBack.alpha = 0;
    _zhLabel.alpha = 1; _srcLabel.alpha = 1;

    if (_fade) { [_fade cancel]; _fade = nil; }
    __weak typeof(self) weakSelf = self;
    _fade = [ZKAnim run:0.30 tick:^(CGFloat p) {
        typeof(self) s = weakSelf;
        if (!s) return;
        CGFloat e = p * p * (3.0 - 2.0 * p);       // smoothstep
        s->_zhLabel.alpha = 1.0 - e;
        s->_srcLabel.alpha = 1.0 - e;
        s->_zhBack.alpha = e;
        s->_srcBack.alpha = e;
    } done:^{
        typeof(self) s = weakSelf;
        if (!s) return;
        s->_fade = nil;
        [s commitFade];
    }];
}

#pragma mark 对外

- (void)setBoxWidth:(CGFloat)width height:(CGFloat)height force:(BOOL)force {
    if (width < 1 || height < 1) return;
    BOOL changed = fabs(width - _w) > 0.5 || fabs(height - _h) > 0.5;
    _w = width;
    _h = height;
    if (!changed && !force) return;
    [self recalcFont];
    if (_current.count) [self renderAnimated:NO];
    if (_queue.count) {
        _shownAt = nil;         // 尺寸变了：新句立刻上屏，不用等防抖
        _holdUntil = nil;
        [self pump];
    }
}

- (void)resetWithLines:(NSArray *)lines {
    [_drain invalidate];
    _drain = nil;
    if (_fade) { [_fade cancel]; _fade = nil; }
    _zhBack.attributedText = nil;
    _srcBack.attributedText = nil;
    _zhBack.alpha = 0;
    _srcBack.alpha = 0;
    _zhLabel.alpha = 1;
    _srcLabel.alpha = 1;
    [_queue removeAllObjects];
    [_pending removeAllObjects];
    _current = nil;
    _zhLabel.attributedText = nil;
    _srcLabel.attributedText = nil;
    _zhLabel.transform = CGAffineTransformIdentity;
    _srcLabel.transform = CGAffineTransformIdentity;
    _zhBack.transform = CGAffineTransformIdentity;
    _srcBack.transform = CGAffineTransformIdentity;
    _shownAt = nil;
    _holdUntil = nil;
    if (![lines isKindOfClass:[NSArray class]]) return;
    // 画中画重建（切窗口、改设置）时把最近两句接上，不至于一片空
    NSInteger from = MAX(0, (NSInteger)lines.count - 2);
    for (NSInteger i = from; i < (NSInteger)lines.count; i++) {
        id o = lines[i];
        if (![o isKindOfClass:[NSDictionary class]]) continue;
        NSString *e = o[@"en"], *z = o[@"zh"];
        if (![e isKindOfClass:[NSString class]]) e = @"";
        if (![z isKindOfClass:[NSString class]]) z = @"";
        if (!e.length && !z.length) continue;
        // 历史行不参与「等译文」那套计时：它们本来就是落定过的句子
        [_queue addObject:@{@"en": e, @"zh": z, @"at": [NSDate dateWithTimeIntervalSinceNow:-60]}];
    }
    [self pump];
}

- (void)addEn:(NSString *)en zh:(NSString *)zh {
    NSString *e = [en isKindOfClass:[NSString class]] ? en : @"";
    NSString *z = [zh isKindOfClass:[NSString class]] ? zh : @"";
    if (!e.length && !z.length) return;

    [_queue addObject:@{@"en": e, @"zh": z, @"at": [NSDate date]}];
    // 只有原文没有译文：记一笔，等译文到了按这个顺序对号补上
    if (!z.length && e.length && [self showTrans]) [_pending addObject:e];
    // 待补的最多留 8 句：留太多，译文晚到时反而容易对错号
    while (_pending.count > 8) [_pending removeObjectAtIndex:0];
    // 越落越远时只保最后几句，宁可跳过也不让画面追不上嘴
    while (_queue.count > 5) {
        NSString *dropped = ((NSDictionary *)_queue.firstObject)[@"en"];
        if ([dropped isKindOfClass:[NSString class]] && dropped.length) [_pending removeObject:dropped];
        [_queue removeObjectAtIndex:0];
    }
    // 已经堆到五句以上：这一屏只要停够了最短时间（0.4 秒），就不再等它读满，
    // 立刻往下走——积压的时候宁可快一点，也不能把画面拖在嘴后面。
    if (_queue.count >= 5 && _shownAt && -[_shownAt timeIntervalSinceNow] >= 0.4) {
        _holdUntil = nil;
    }
    // 屏上这句还在等译文、新的已经来了：不等了，新句立刻上。
    // 等译文只在"没有下句"的时候才做，不能为了它把整条流压住。
    if (_current.count && [self showTrans] && [self needsZh:_current.firstObject]
        && _shownAt && -[_shownAt timeIntervalSinceNow] >= 0.35) {
        _holdUntil = nil;
    }
    [self pump];
}

- (void)refreshStyle {
    [self recalcFont];
    [self renderAnimated:NO];
}

// 译文迟到：先按原文精确找回那一句再补（屏上这批找一遍、队列里找一遍），
// 对不上号就补「最早一句还没译文的」——绝不能像以前那样直接补屏上最后一句，
// 那样补出来的中文和屏幕上的英文根本不是一句话。
- (void)patchZh:(NSString *)zh forEn:(NSString *)en {
    if (![zh isKindOfClass:[NSString class]] || !zh.length) return;
    if (en.length && [self applyZh:zh forEn:en]) return;
    // 上游把这条并进了别的句子：按先进先出，补最早那句还没译文的
    for (NSString *pe in [_pending copy]) {
        if ([self applyZh:zh forEn:pe]) return;
    }
    // 这一句已经下屏了：丢掉，不要硬补到屏上最后一句上——
    // 那样补出来的中文和屏幕上的英文根本不是一句话。
    if (en.length) return;
    [self patchLastZh:zh];
}

/// 把译文写到指定原文那一句上。写成功返回 YES。
- (BOOL)applyZh:(NSString *)zh forEn:(NSString *)en {
    if (!zh.length) return NO;
    for (NSInteger i = 0; i < (NSInteger)_current.count; i++) {
        NSDictionary *it = _current[i];
        if (![it isKindOfClass:[NSDictionary class]]) continue;
        NSString *e = it[@"en"];
        if (![e isKindOfClass:[NSString class]] || ![e isEqualToString:en]) continue;
        NSString *old = it[@"zh"];
        if ([old isKindOfClass:[NSString class]] && old.length) return NO;
        NSMutableArray *arr = [_current mutableCopy];
        NSMutableDictionary *m = [it mutableCopy];
        m[@"zh"] = zh;
        arr[i] = m;
        _current = arr;
        [_pending removeObject:en];
        [self renderAnimated:NO];
        return YES;
    }
    for (NSInteger i = 0; i < (NSInteger)_queue.count; i++) {
        NSDictionary *it = _queue[i];
        if (![it isKindOfClass:[NSDictionary class]]) continue;
        NSString *e = it[@"en"];
        if (![e isKindOfClass:[NSString class]] || ![e isEqualToString:en]) continue;
        NSString *old = it[@"zh"];
        if ([old isKindOfClass:[NSString class]] && old.length) return NO;
        NSMutableDictionary *m = [it mutableCopy];
        m[@"zh"] = zh;
        _queue[i] = m;
        [_pending removeObject:en];
        return YES;
    }
    return NO;
}

// 译文迟到：屏上这一批的最后一句补上译文，整屏重排一次（字号跟着内容重算，不跳位）
- (void)patchLastZh:(NSString *)zh {
    if (!zh.length) return;
    if (_current.count) {
        NSMutableArray *arr = [_current mutableCopy];
        NSMutableDictionary *m = [arr.lastObject mutableCopy];
        NSString *old = m[@"zh"];
        if ([old isKindOfClass:[NSString class]] && old.length) return;
        m[@"zh"] = zh;
        arr[arr.count - 1] = m;
        _current = arr;
        [self renderAnimated:NO];
        return;
    }
    if (_queue.count) {
        NSMutableDictionary *m = [_queue.lastObject mutableCopy];
        NSString *old = m[@"zh"];
        if ([old isKindOfClass:[NSString class]] && old.length) return;
        m[@"zh"] = zh;
        _queue[_queue.count - 1] = m;
    }
}

@end

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
    ZKWideView *_wide;     // W 全宽档：原文一行 + 译文一行
    ZKSegmentView *_segment;   // 中/大窗「逐字」：上下两块连续文本，逐字长出来、满了整块上推一行
    ZKRowStack *_roll;         // 中/大窗「上推」：一列句子由下往上滚
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

    // 全宽档专用的两行视图，跟竖排字幕互斥，谁在用谁显示
    _wide = [ZKWideView new];
    _wide.translatesAutoresizingMaskIntoConstraints = NO;
    _wide.hidden = YES;
    [self.view addSubview:_wide];
    [NSLayoutConstraint activateConstraints:@[
        [_wide.topAnchor constraintEqualToAnchor:v.topAnchor constant:8],
        [_wide.leadingAnchor constraintEqualToAnchor:v.leadingAnchor constant:14],
        [_wide.trailingAnchor constraintEqualToAnchor:v.trailingAnchor constant:-14],
        [_wide.bottomAnchor constraintEqualToAnchor:v.bottomAnchor constant:-8],
    ]];

    // 中窗/大窗的「上推」：一列句子从下往上滚（跟预览同一条轨迹）；
    // 「逐字」：上下两块连续文本，逐字长出来、满了整块上推一行。两者互斥，也跟全宽档互斥。
    // 逐字这块铺满整个窗口，边距由它自己按窗口尺寸算——外面再套一圈 8/14 的话，
    // 实际能排字的宽度比传进去的宽度窄，换行位置就跟预览对不上了。
    _segment = [ZKSegmentView new];
    _segment.translatesAutoresizingMaskIntoConstraints = NO;
    _segment.hidden = YES;
    [self.view addSubview:_segment];
    [NSLayoutConstraint activateConstraints:@[
        [_segment.topAnchor constraintEqualToAnchor:v.topAnchor],
        [_segment.leadingAnchor constraintEqualToAnchor:v.leadingAnchor],
        [_segment.trailingAnchor constraintEqualToAnchor:v.trailingAnchor],
        [_segment.bottomAnchor constraintEqualToAnchor:v.bottomAnchor],
    ]];

    _roll = [ZKRowStack new];
    _roll.typing = NO;
    _roll.translatesAutoresizingMaskIntoConstraints = NO;
    _roll.hidden = YES;
    [self.view addSubview:_roll];
    [NSLayoutConstraint activateConstraints:@[
        [_roll.topAnchor constraintEqualToAnchor:v.topAnchor constant:8],
        [_roll.leadingAnchor constraintEqualToAnchor:v.leadingAnchor constant:14],
        [_roll.trailingAnchor constraintEqualToAnchor:v.trailingAnchor constant:-14],
        [_roll.bottomAnchor constraintEqualToAnchor:v.bottomAnchor constant:-8],
    ]];

    // 逐帧插值：文字是"一行一行"长出来的，直接把 offset 设到目标位置，
    // 每跨一行就是硬跳一格（25 点上下），看着就是一顿一顿。
    // 改成每帧追 30%，约 6~8 帧追平，位移连续；这不是 CA 动画，
    // 不依赖被后台降频的那套补间机制，跑得动就跑，跑不动由 applyGeometry 兜底直接到位。
    _link = [CADisplayLink displayLinkWithTarget:self selector:@selector(onFrame:)];
    if (@available(iOS 15.0, *)) {
        _link.preferredFrameRateRange = CAFrameRateRangeMake(60, 120, 120);
    }
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
        if (isfinite(CGRectGetWidth(r)) && isfinite(CGRectGetHeight(r)) && CGRectGetWidth(r) >= 1 && CGRectGetHeight(r) >= 1) {
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

// 小档（5:1 横条）：中文一行、原文一行，不走竖排那一套
- (BOOL)isWideMode {
    return [gPipStyle isEqualToString:@"X"];
}

/// 中窗/大窗选了「逐字」才走这块（两块连续文本 + 打字机，满行整块上推）；小窗没有这个选项
- (BOOL)isSegmentMode {
    return ![self isWideMode] && [gScroll isEqualToString:@"segment"];
}

// 窗口尺寸变了就重算字号。
// 唯一规则：字号只跟窗口走，跟「这一句有多长」完全无关。
// 旧版遇到长句会把字缩一档、下一句短了又弹回来——窗口一动没动、字却一句一跳，
// 那正是用户说的「一长句字号就变了」。现在长句靠换行解决，绝不缩字。
- (void)applyAdaptiveFontForWidth:(CGFloat)w height:(CGFloat)h {
    if (w < 1 || h < 1) return;

    if ([self isWideMode]) {
        // 小档不用这套：它按两行高度和窗宽自己算字号（见 ZKWideView）
        self.scroll.hidden = YES;
        _wide.hidden = NO;
        if (_segment) _segment.hidden = YES;
        if (_roll) _roll.hidden = YES;
        [_wide setBoxWidth:w height:h force:NO];
        return;
    }
    if ([self isSegmentMode] && _segment) {
        self.scroll.hidden = YES;
        _wide.hidden = YES;
        if (_roll) _roll.hidden = YES;
        _segment.hidden = NO;
        [_segment setBoxWidth:w height:h force:NO];
        return;
    }
    // 中窗/大窗的「上推」：一列句子由下往上滚。字号、行数、格高都在它自己里算，
    // 整个窗口刚好被填满——不会再出现顶上留一截空白。
    self.scroll.hidden = YES;
    _wide.hidden = YES;
    if (_segment) _segment.hidden = YES;
    if (_roll) {
        _roll.hidden = NO;
        [_roll setBoxWidth:w height:h force:NO];
        return;
    }

    // 没有 roll 视图时的老路子（竖排流）：以 480×360 为基准窗，按面积比（开方）缩放。
    self.scroll.hidden = NO;
    CGFloat areaRatio = (w * h) / (480.0 * 360.0);
    CGFloat scale = sqrt(MAX(0.04, areaRatio));
    scale = MAX(0.45, MIN(2.10, scale));

    CGFloat zh = MAX(12.0, MIN(74.0, gZhBase * scale * 1.35));
    CGFloat en = MAX(9.5, zh * 0.66);
    NSInteger enLines = 0;         // 原文不限行：跟着换行，不截断

    NSInteger mask = (NSInteger)lround(zh * 10.0);
    BOOL changed = (mask != _adaptMask) || (enLines != gEnMaxLines)
                   || fabs(zh - gZhSize) > 0.25 || fabs(en - gEnSize) > 0.25;
    gZhSize = zh;
    gEnSize = en;
    gEnMaxLines = enLines;
    if (!changed) return;
    _adaptMask = mask;
    [ZKStore log:@"pip adapt %.0fx%.0f zh=%.1f en=%.1f", w, h, zh, en];

    // 必须 force：窗口缩放时文字内容往往一字没变，走缓存就把这次重排吞掉了，
    // 表现就是「字号算了新的、屏幕上还是老字号」。
    [self.stream relayoutAllForce:YES];
}

#pragma mark 几何

// 内容不满一屏时贴住底部；满了就整体铺开，滚动看最新。
// 全程不动画：位移有多小就有多小，靠"内容持续增长"来连续，而不是靠补间动画。
- (void)applyGeometry {
    CGFloat w = self.scroll.bounds.size.width;
    CGFloat h = self.scroll.bounds.size.height;
    if (w <= 0 || h <= 0) return;

    if ([self isWideMode] && _wide) {
        // 全宽档：竖排那条流整个不用，只喂两行视图
        self.scroll.hidden = YES;
        _wide.hidden = NO;
        if (_segment) _segment.hidden = YES;
        if (_roll) _roll.hidden = YES;
        [_wide setBoxWidth:w height:h force:NO];
        return;
    }
    if ([self isSegmentMode] && _segment) {
        self.scroll.hidden = YES;
        if (_wide) _wide.hidden = YES;
        if (_roll) _roll.hidden = YES;
        _segment.hidden = NO;
        [_segment setBoxWidth:w height:h force:NO];
        return;
    }
    if (_roll) {
        // 中窗/大窗「上推」：一列句子自己滚，不再走竖排流那套 scroll + 弹簧
        self.scroll.hidden = YES;
        if (_wide) _wide.hidden = YES;
        if (_segment) _segment.hidden = YES;
        _roll.hidden = NO;
        [_roll setBoxWidth:w height:h force:NO];
        return;
    }
    if (_wide) {
        _wide.hidden = YES;
        self.scroll.hidden = NO;
    }
    if (_segment) _segment.hidden = YES;

    // 布局这一步全部关掉隐式动画：内容位置必须"当帧就准"，
    // 否则系统给 stream.frame 补一个 0.25s 的过渡，和滚动弹簧叠在一起就是二次抖动。
    [CATransaction begin];
    [CATransaction setDisableActions:YES];

    [self.stream setStreamWidth:w];
    CGFloat contentH = self.stream.contentHeight;
    CGFloat shownH = MAX(contentH, h);

    BOOL fits = (contentH <= h + 0.5);
    CGRect f = CGRectMake(0, shownH - contentH, w, contentH);
    CGSize cs = CGSizeMake(w, shownH);

    // 前几行：内容还没占满一屏，没有滚动可做，但新句顶上来不能是「啪」的一下跳一格。
    // 这里补一段上推动画，让第一句起就有连续的滚动观感，而不是等满屏之后才动起来。
    if (fits && !_snapNext && !CGRectEqualToRect(self.stream.frame, f)) {
        CGRect from = self.stream.frame;
        self.stream.frame = f;
        if (!CGSizeEqualToSize(self.scroll.contentSize, cs)) self.scroll.contentSize = cs;
        _targetY = 0;
        [CATransaction commit];
        CABasicAnimation *rise = [CABasicAnimation animationWithKeyPath:@"position.y"];
        rise.fromValue = @(CGRectGetMidY(from));
        rise.toValue = @(CGRectGetMidY(f));
        rise.duration = 0.16;
        rise.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
        [self.stream.layer addAnimation:rise forKey:@"streamRise"];
        _lastTickAt = CACurrentMediaTime();
        return;
    }

    if (!CGRectEqualToRect(self.stream.frame, f)) self.stream.frame = f;
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
    if (_wide) [_wide resetWithLines:lines];
    if (_segment) [_segment resetWithLines:lines];
    if (_roll) [_roll resetWithLines:lines];
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
    if (_wide) [_wide refreshStyle];
    if (_segment) [_segment refreshStyle];
    if (_roll) [_roll refreshStyle];
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

    if ([self isWideMode] && _wide) {
        // 全宽档：不做逐字动画，整句落定了才上一批
        [_wide addEn:e zh:z];
        [self applyGeometry];
        return;
    }

    if (_segment && ![self isWideMode]) {
        if ([self isSegmentMode]) { [_segment addEn:e zh:z]; return; }
        if (_roll) { [_roll addEn:e zh:z]; return; }
    }

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
    // 画中画里不显示「正在说的半句」：整句翻完才落一行。
    // 尾块现在用来挂「已经落定、还在等译文」的整句（见 showLiveEn:），
    // 这里绝不能清尾块，否则那句原文刚出现就被半句回调擦掉了。
    if (en.length || zh.length) [self hidePlaceholder];
}

// 整句落定就先上屏原文，译文到了再就地补在它上面：
// 一句说完 0.2 秒内就能看见字；译文到齐时只往上长一行，屏幕上的字不重排、不跳。
- (void)showLiveEn:(NSString *)en zh:(NSString *)zh {
    if (!en.length && !zh.length) return;
    [self hidePlaceholder];
    self.liveEn = en.length ? en : nil;
    self.liveZh = zh.length ? zh : nil;
    [self.stream updateTailEn:(en ?: @"") zh:(zh ?: @"")];
    [self applyGeometry];
}

// 译文迟到：补到最后一行。竖排流里补最后一块，全宽档里补屏上那批的最后一句。
- (void)patchLastZh:(NSString *)zh {
    if (!zh.length) return;
    if ([self isWideMode] && _wide) {
        [_wide patchLastZh:zh];
        return;
    }
    if ([self isSegmentMode] && _segment) {
        [_segment patchLastZh:zh];
        return;
    }
    if (_roll) {
        [_roll patchLastZh:zh];
        return;
    }
    [self.stream patchLastZh:zh];
    [self applyGeometry];
}

// 精确版：按原文找回那一行（中间又上了新句也不会补错）
- (void)patchZh:(NSString *)zh forEn:(NSString *)en {
    if (!zh.length) return;
    if ([self isWideMode] && _wide) {
        [_wide patchZh:zh forEn:en];
        return;
    }
    if ([self isSegmentMode] && _segment) {
        [_segment patchZh:zh forEn:en];
        return;
    }
    if (_roll) {
        [_roll patchZh:zh forEn:en];
        return;
    }
    [self.stream patchZh:zh forEn:en];
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

    NSString *scroll = p[@"scroll"];
    if ([scroll isKindOfClass:[NSString class]] && scroll.length) gScroll = scroll;

    NSString *pip = p[@"pip"];
    if ([pip isKindOfClass:[NSString class]]) {
        // 窗口三档，选哪个开出来就是多大：
        //   X 小 = 5:1 1080×216（默认，铺满屏宽、最矮，中文一行 + 原文一行）
        //   M 中 = 21:9 840×360（宽条，竖向能站三四行）
        //   B 大 = 27:16 1080×640（又宽又大：比中档更宽更高，一屏能站六七行）
        // 老版本的 W / S(21:9) / M(16:9) / L(4:3) 也认，映射到对应的新档
        if ([pip isEqualToString:@"X"] || [pip isEqualToString:@"W"] || [pip isEqualToString:@"full"]) {
            gPipSize = CGSizeMake(1080, 216);
            gPipStyle = @"X";
        } else if ([pip isEqualToString:@"M"] || [pip isEqualToString:@"S"]
                   || [pip isEqualToString:@"21:9"] || [pip isEqualToString:@"bar"]) {
            gPipSize = CGSizeMake(840, 360);
            gPipStyle = @"M";
        } else {
            gPipSize = CGSizeMake(1080, 640);
            gPipStyle = @"B";
        }
        // 窗口档换了：正在播的那块由 App 侧重开窗口生效，
        // 这里只管把档位记下来，内容层（W / 竖排）当场切换
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

- (void)showLiveEn:(NSString *)en zh:(NSString *)zh {
    if (!_sub) return;
    [_sub showLiveEn:en zh:zh];
}

// 译文迟到：共享流里那一行补上译文（下次开画中画读到的也是全的），屏上就地补
- (void)patchLastZh:(NSString *)zh {
    if (!zh.length) return;
    [ZKStore updateLastLineZh:zh];
    if (!_sub) return;
    [_sub patchLastZh:zh];
}

// 精确版：按原文找回那一行再补
- (void)patchZh:(NSString *)zh forEn:(NSString *)en {
    if (!zh.length) return;
    if (en.length) [ZKStore updateLineZh:zh forEn:en];
    else [ZKStore updateLastLineZh:zh];
    if (!_sub) return;
    [_sub patchZh:zh forEn:en];
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
