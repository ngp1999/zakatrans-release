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
static CGFloat gZhSize = 20.0;
static CGFloat gEnSize = 13.0;
static UIColor *gTextColor = nil;
static NSString *gStyle = @"shadow";       // shadow | box | plain
static NSString *gMode = @"bilingual";     // bilingual | zh | source
static CGSize gPipSize = {640, 180};       // bar 默认横条
static BOOL gPipBar = YES;
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
static NSDictionary *ZKZhAttrs(void) {
    NSMutableParagraphStyle *p = [NSMutableParagraphStyle new];
    p.lineSpacing = 2.0;
    p.lineBreakMode = NSLineBreakByWordWrapping;
    p.alignment = NSTextAlignmentLeft;
    UIColor *c = gTextColor ?: [UIColor whiteColor];
    return @{
        NSFontAttributeName: [UIFont boldSystemFontOfSize:gZhSize],
        NSForegroundColorAttributeName: c,
        NSParagraphStyleAttributeName: p,
    };
}

static NSDictionary *ZKEnAttrs(void) {
    NSMutableParagraphStyle *p = [NSMutableParagraphStyle new];
    p.lineSpacing = 1.0;
    p.lineBreakMode = NSLineBreakByWordWrapping;
    p.alignment = NSTextAlignmentLeft;
    // 原文比译文暗一档：同一底色下按 70% 亮度走，纯白时是浅灰
    UIColor *c = gTextColor ?: [UIColor colorWithWhite:1 alpha:1];
    return @{
        NSFontAttributeName: [UIFont systemFontOfSize:gEnSize],
        NSForegroundColorAttributeName: [c colorWithAlphaComponent:0.72],
        NSParagraphStyleAttributeName: p,
    };
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
    if (!force && _appliedW == w && _appliedFirst == first &&
        [_appliedEn isEqualToString:en] && [_appliedZh isEqualToString:zh]) {
        return;
    }
    _appliedEn = [en copy];
    _appliedZh = [zh copy];
    _appliedW = w;
    _appliedFirst = first;

    CGFloat padTop = first ? 0 : ZK_PARA_GAP;

    // 样式：底板 / 描边阴影 / 纯文字
    BOOL box = [gStyle isEqualToString:@"box"];
    BOOL plain = [gStyle isEqualToString:@"plain"];
    for (UILabel *l in @[self.zhLabel, self.enLabel]) {
        l.backgroundColor = box ? [UIColor colorWithWhite:0 alpha:0.45] : [UIColor clearColor];
        l.layer.cornerRadius = box ? 6 : 0;
        l.layer.masksToBounds = box;
        l.layer.shadowOpacity = plain ? 0 : (box ? 0 : 0.85);
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
- (void)rebuildWithLines:(NSArray *)lines;
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
    CGFloat y = 0;
    NSUInteger i = 0;
    for (ZKBlockView *b in _blocks) {
        [b applyEn:b.enText zh:b.zhText first:(i == 0) width:_w];
        b.frame = CGRectMake(0, y, _w, b.blockH);
        y += b.blockH;
        i++;
    }
    if (_tail) {
        [_tail applyEn:_tail.enText zh:_tail.zhText first:(_blocks.count == 0) width:_w];
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
@property (nonatomic, copy) NSString *liveEn;
@property (nonatomic, copy) NSString *liveZh;
- (void)shutdown;
- (void)rebuildFromLines:(NSArray *)lines;
- (void)appendLine:(NSDictionary *)d;
- (void)setLiveEn:(NSString *)en zh:(NSString *)zh;
- (void)setOffsetY:(CGFloat)y;
@end

@implementation ZKSubtitleVC {
    CGFloat _lastLayoutW;
    CGFloat _lastLayoutH;
    CADisplayLink *_link;
    CGFloat _targetY;
    CFTimeInterval _lastTickAt;
    BOOL _snapNext;
    CGFloat _vel;          // 当前滚动速度（pt/s），弹簧的第二个状态量
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithWhite:0 alpha:0.86];

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
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat w = self.scroll.bounds.size.width;
    CGFloat h = self.scroll.bounds.size.height;
    if (w <= 0 || h <= 0) return;
    if (fabs(w - _lastLayoutW) > 0.5 || fabs(h - _lastLayoutH) > 0.5) {
        _lastLayoutW = w;
        _lastLayoutH = h;
        [self applyGeometry];
    }
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
    [self.scroll setContentOffset:CGPointZero animated:NO];
    [self.stream rebuildWithLines:lines];
    _lastLayoutW = 0;   // 强制重排一次
    [self.view setNeedsLayout];
    [self.view layoutIfNeeded];
    [self applyGeometry];
}

- (void)appendLine:(NSDictionary *)d {
    if (![d isKindOfClass:[NSDictionary class]]) return;
    NSString *e = d[@"en"], *z = d[@"zh"];
    if (![e isKindOfClass:[NSString class]]) e = @"";
    if (![z isKindOfClass:[NSString class]]) z = @"";
    if (!e.length && !z.length) return;

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

// App 的字幕设置传进来：字号、颜色、样式、语言模式、画中画形态
+ (void)applyStyle:(NSDictionary *)p {
    if (![p isKindOfClass:[NSDictionary class]]) return;
    NSNumber *size = p[@"size"];
    if ([size isKindOfClass:[NSNumber class]] && size.doubleValue > 8) {
        gZhSize = size.doubleValue;
        gEnSize = MAX(11.0, size.doubleValue - 6.0);
    }
    NSString *color = p[@"color"];
    if ([color isKindOfClass:[NSString class]]) {
        if ([color isEqualToString:@"yellow"])      gTextColor = [UIColor colorWithRed:1.00 green:0.85 blue:0.30 alpha:1];
        else if ([color isEqualToString:@"cyan"])   gTextColor = [UIColor colorWithRed:0.40 green:0.90 blue:0.95 alpha:1];
        else if ([color isEqualToString:@"green"])  gTextColor = [UIColor colorWithRed:0.55 green:0.95 blue:0.65 alpha:1];
        else if ([color isEqualToString:@"black"])  gTextColor = [UIColor blackColor];
        else                                        gTextColor = [UIColor whiteColor];
    }
    NSString *style = p[@"style"];
    if ([style isKindOfClass:[NSString class]]) gStyle = style;
    NSString *mode = p[@"mode"];
    if ([mode isKindOfClass:[NSString class]]) gMode = mode;

    NSString *pip = p[@"pip"];
    if ([pip isKindOfClass:[NSString class]]) {
        gPipBar = [pip isEqualToString:@"bar"];
        // 横条：3.5:1，缩到最小窗口时一句中文也基本能放一行，不会两三行叠在一起
        gPipSize = gPipBar ? CGSizeMake(640, 180) : CGSizeMake(420, 300);
    }
    [ZKStore log:@"pip style size=%.0f color=%@ style=%@ mode=%@ pip=%@",
        gZhSize, color ?: @"", gStyle, gMode, pip ?: @""];
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
    if (_pip) [_pip stopPictureInPicture];
    _starting = NO;
    @try { [_sub shutdown]; } @catch (__unused NSException *e) {}
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
