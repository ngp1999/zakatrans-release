#import "ZKInterpreter.h"
#import "DoubaoAST.h"
#import "Shared.h"
#import <AVFoundation/AVFoundation.h>

// 文字体系判定：判断这句原文是哪国话，决定归谁
typedef NS_ENUM(NSInteger, ZKScript) {
    ZKScriptUnknown = 0,
    ZKScriptHan,      // 中文
    ZKScriptKana,     // 日文
    ZKScriptHangul,   // 韩文
    ZKScriptLatin,    // 英文/法/德/西等拉丁字母
    ZKScriptCyrillic, // 俄文
    ZKScriptThai,
    ZKScriptViet,     // 越南文（拉丁 + 大量声调符号）
    ZKScriptArabic,
};

static ZKScript ZKSriptOf(NSString *s) {
    if (s.length == 0) return ZKScriptUnknown;
    NSUInteger han = 0, kana = 0, hangul = 0, latin = 0, cyr = 0, thai = 0, arab = 0, total = 0;

    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        if (c == ' ' || c == '\t' || c == '\n') continue;
        if ([[NSCharacterSet punctuationCharacterSet] characterIsMember:c]) continue;
        total++;
        if (c >= 0x4E00 && c <= 0x9FFF) han++;
        else if ((c >= 0x3040 && c <= 0x30FF)) kana++;
        else if (c >= 0xAC00 && c <= 0xD7AF) hangul++;
        else if (c >= 0x0400 && c <= 0x04FF) cyr++;
        else if (c >= 0x0E00 && c <= 0x0E7F) thai++;
        else if (c >= 0x0600 && c <= 0x06FF) arab++;
        else if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= 0x00C0 && c <= 0x024F)) latin++;
    }
    if (total == 0) return ZKScriptUnknown;
    if (kana > 0) return ZKScriptKana;
    if (hangul > total / 4) return ZKScriptHangul;
    if (han > total / 4) return ZKScriptHan;
    if (cyr > total / 3) return ZKScriptCyrillic;
    if (thai > total / 3) return ZKScriptThai;
    if (arab > total / 3) return ZKScriptArabic;
    if (latin > total / 3) return ZKScriptLatin;
    return ZKScriptUnknown;
}

/// 语言代码 → 文字体系
static ZKScript ZKScriptOfLang(NSString *lang) {
    if (lang.length == 0) return ZKScriptUnknown;
    NSString *l = [lang.lowercaseString copy];
    if ([l hasPrefix:@"zh"]) return ZKScriptHan;
    if ([l hasPrefix:@"ja"]) return ZKScriptKana;
    if ([l hasPrefix:@"ko"]) return ZKScriptHangul;
    if ([l hasPrefix:@"ru"] || [l hasPrefix:@"uk"]) return ZKScriptCyrillic;
    if ([l hasPrefix:@"th"]) return ZKScriptThai;
    if ([l hasPrefix:@"vi"]) return ZKScriptLatin;
    if ([l hasPrefix:@"ar"]) return ZKScriptArabic;
    return ZKScriptLatin;
}

/// 上游要的是短码：zh-CN → zh，en-US → en
static NSString *ZKShort(NSString *bcp) {
    if (bcp.length == 0) return @"auto";
    NSRange r = [bcp rangeOfString:@"-"];
    return r.location == NSNotFound ? bcp : [bcp substringToIndex:r.location];
}

/// 这句是不是真有内容。
/// 上游在「语言对不上」那条通道上会吐纯标点（。，… —— 之类），
/// 以前这些原样进了界面，就成了用户看到的「说完一句，对面多一个符号」。
static BOOL ZKHasContent(NSString *s) {
    if (s.length == 0) return NO;
    NSCharacterSet *alnum = [NSCharacterSet alphanumericCharacterSet];
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        if ([alnum characterIsMember:c]) return YES;
        if (c >= 0x4E00 && c <= 0x9FFF) return YES;   // 汉字
        if (c >= 0x3040 && c <= 0x30FF) return YES;   // 假名
        if (c >= 0xAC00 && c <= 0xD7AF) return YES;   // 韩文
        if (c >= 0x0400 && c <= 0x04FF) return YES;   // 西里尔
        if (c >= 0x0E00 && c <= 0x0E7F) return YES;   // 泰文
    }
    return NO;
}

/// 译文增量可能是「累积式」（每帧给整句）也可能是「增量式」（每帧给一小段），
/// 上游两种都出现过。这里合并成整句：
///   新的一句以旧的结尾 → 已经包含了，用新的
///   旧的一句以新的开头 → 是回退/重复，保留旧的
///   新的比旧的短 → 当成一小段接上
static NSString *ZKMergeTrans(NSString *old, NSString *add) {
    if (!old.length) return add;
    if (!add.length) return old;
    if ([add isEqualToString:old]) return old;
    if ([add hasPrefix:old]) return add;
    if ([old hasPrefix:add]) return old;
    // 新的是旧句里的一段（上游把整句最后一段又发了一遍）：旧的已经完整，别接出重影
    if ([add containsString:old]) return add;
    if ([old containsString:add]) return old;
    if (add.length >= old.length) return add;
    if ([old hasSuffix:add]) return old;
    return [old stringByAppendingString:add];
}

/// 东亚文字：中日韩统一表意文字、假名、全角标点
static NSString *ZKNorm(NSString *s);   // 下面才定义，先声明

static BOOL ZKWide(unichar c) {
    return (c >= 0x4E00 && c <= 0x9FFF)
        || (c >= 0x3040 && c <= 0x30FF)
        || (c >= 0x3000 && c <= 0x303F)
        || (c >= 0xFF00 && c <= 0xFFEF);
}

/// 中文里不该有半角空格。上游偶尔把「我很 好，谢谢。」这种带空格的识别结果
/// 原样传下来，直接上屏就是一鼻子别扭。
static NSString *ZKTrimCJKSpace(NSString *s) {
    NSUInteger n = s.length;
    if (n < 3) return s;
    NSMutableString *m = [NSMutableString stringWithCapacity:n];
    for (NSUInteger i = 0; i < n; i++) {
        unichar c = [s characterAtIndex:i];
        if (c == ' ' && i > 0) {
            NSUInteger j = i + 1;
            while (j < n && [s characterAtIndex:j] == ' ') j++;
            if (j < n && ZKWide([s characterAtIndex:i - 1]) && ZKWide([s characterAtIndex:j])) {
                i = j - 1;   // 两侧都是汉字：把这个空格吞掉
                continue;
            }
        }
        [m appendFormat:@"%C", c];
    }
    return m;
}

/// 去掉首尾空白、把连续空白压成一个空格，空行不要
static NSString *ZKClean(NSString *s) {
    if (!s.length) return @"";
    NSString *t = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    t = [t stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
    while ([t containsString:@"  "]) t = [t stringByReplacingOccurrencesOfString:@"  " withString:@" "];
    return ZKTrimCJKSpace(t);
}

/// 这句话是不是已经说完了（结尾带句末标点）。
/// 上游分句是按静音切的，一句话中间停顿稍长就会被切成两条：
/// 「你叫什么」+「名字」。前一条没带句末标点，就说明它还没说完。
static BOOL ZKEndsSentence(NSString *s) {
    NSString *t = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!t.length) return NO;
    unichar c = [t characterAtIndex:t.length - 1];
    return c == 0x3002 || c == 0xFF01 || c == 0xFF1F || c == '.' || c == '!'
        || c == '?' || c == 0x2026 || c == 0xFF1B || c == ';' || c == 0xFF1A || c == ':';
}

/// 上屏用的文本：**句尾**的标点一律不要。
///
/// 一句话说完就完了，屏幕上一行结尾再多一个「。」既占位置又难看，
/// 尤其在同传气泡里，原文那行小字后面挂个句号显得很啰嗦。
/// 但句子**中间**的标点必须留着——「你好，我想问一下路」里的逗号去掉就读不通了。
/// 所以这里只从结尾往前连着删，碰到第一个非标点字符就停。
static NSString *ZKTrimEndPunct(NSString *s) {
    if (!s.length) return @"";
    NSMutableString *m = [s mutableCopy];
    while (m.length > 0) {
        unichar c = [m characterAtIndex:m.length - 1];
        BOOL punct = (c == 0x3002 || c == 0xFF01 || c == 0xFF1F || c == 0xFF0C
                      || c == 0x3001 || c == 0xFF1B || c == 0xFF1A
                      || c == '.' || c == ',' || c == '!' || c == '?'
                      || c == ';' || c == ':' || c == 0x2026 || c == ' '
                      || c == 0x3000 || c == '\n');
        if (!punct) break;
        [m deleteCharactersInRange:NSMakeRange(m.length - 1, 1)];
    }
    return m;
}

/// 是不是一个被切碎的碎片（一个词、两三个字）。
/// 只在「上一句已经收尾」时用来判断要不要接回去。
///
/// 以前这里放宽到「拉丁 40 字符 / 汉字 14 字」，本意是别让整句被切成一词一行，
/// 结果连着几句完整的话全被焊成一条：截图里那条
/// 「你叫什么名字? / What are you doing? How much? Welcome to China.」
/// 就是这么拼出来的——原文拼成一大条，译文跟着拼，最后图文都对不上。
static BOOL ZKIsFragment(NSString *s) {
    NSString *n = ZKNorm(s);
    if (!n.length) return NO;
    ZKScript sc = ZKSriptOf(s);
    if (sc == ZKScriptHan || sc == ZKScriptKana || sc == ZKScriptHangul) return n.length <= 3;
    if (sc == ZKScriptLatin) {
        if (n.length > 10) return NO;
        NSArray *w = [n componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        NSMutableArray *keep = [NSMutableArray array];
        for (NSString *x in w) if (x.length) [keep addObject:x];
        return keep.count <= 1;
    }
    return NO;
}

static BOOL ZKIsStub(NSString *s) {
    return ZKIsFragment(s);
}

/// 这一小段里有没有句中标点/句末标点（，,、？?！!。；;：:）。
/// 有标点就说明它自己是一个完整的句子或分句，不管前面那句收没收尾，都不许接上去。
/// 上游（豆包）经常整段不带标点，光看「上一句结尾有没有标点」根本判不出说完没说完，
/// 但「这一句自己带标点」是很硬的信号——截图里那条
/// 「我没事。你好，你在干嘛」被焊成一句，就是漏了这条。
static BOOL ZKHasClausePunct(NSString *s) {
    if (![s isKindOfClass:[NSString class]] || !s.length) return NO;
    static NSCharacterSet *set = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        set = [NSCharacterSet characterSetWithCharactersInString:@"，,、。．.？?！!；;：:"];
    });
    return [s rangeOfCharacterFromSet:set].location != NSNotFound;
}

/// 上一句没带句末标点时，这一小段是不是「半句话的尾巴」。
/// 只认很短的：中文 ≤4 字、拉丁 ≤2 个词且 ≤12 字符。
/// 以前放到「中文 12 字 / 拉丁 3 词 24 字符」，结果上游整段不带标点时，
/// 后面连着几句完整的话全被当成"尾巴"焊进上一句（截图里
/// 「What are you doing?What's your name」「我没事。你好，你在干嘛」就是这么来的）。
/// 现在宁可多起一行，也不许把两句话焊成一句。
/// 另：带句中标点的一律不接，由调用方先用 ZKHasClausePunct 挡一道。
static BOOL ZKIsTailLike(NSString *s) {
    NSString *n = ZKNorm(s);
    if (!n.length) return NO;
    ZKScript sc = ZKSriptOf(s);
    if (sc == ZKScriptHan || sc == ZKScriptKana || sc == ZKScriptHangul) return n.length <= 4;
    if (sc == ZKScriptLatin) {
        if (n.length > 12) return NO;
        NSArray *w = [n componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        NSMutableArray *keep = [NSMutableArray array];
        for (NSString *x in w) if (x.length) [keep addObject:x];
        return keep.count <= 2;
    }
    return NO;
}

/// 把碎尾巴接回前一句
static NSString *ZKJoinSrc(NSString *a, NSString *b) {
    if (!a.length) return b;
    if (!b.length) return a;
    ZKScript sa = ZKSriptOf(a);
    if (sa == ZKScriptHan || sa == ZKScriptKana || sa == ZKScriptHangul) {
        return [a stringByAppendingString:b];
    }
    return [a stringByAppendingFormat:@" %@", b];
}

/// 归一化：只留字母数字和汉字，转小写。用来做「两边说的是不是同一句」的比较。
static NSString *ZKNorm(NSString *s) {
    NSMutableString *m = [NSMutableString stringWithCapacity:s.length];
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        if (c >= 0x4E00 && c <= 0x9FFF) { [m appendFormat:@"%C", c]; continue; }
        if ([[NSCharacterSet alphanumericCharacterSet] characterIsMember:c]) {
            [m appendString:[[NSString stringWithFormat:@"%C", c] lowercaseString]];
        }
    }
    return m;
}

/// 两句话像不像（字符二元组重合度）。0 = 完全不像，1 = 一模一样。
static double ZKSim(NSString *a, NSString *b) {
    NSString *x = ZKNorm(a), *y = ZKNorm(b);
    if (x.length < 2 || y.length < 2) return 0;
    NSMutableDictionary<NSString *, NSNumber *> *cnt = [NSMutableDictionary dictionary];
    for (NSUInteger i = 0; i + 1 < x.length; i++) {
        NSString *g = [x substringWithRange:NSMakeRange(i, 2)];
        cnt[g] = @([cnt[g] intValue] + 1);
    }
    NSInteger hit = 0, total = 0;
    for (NSUInteger i = 0; i + 1 < y.length; i++) {
        NSString *g = [y substringWithRange:NSMakeRange(i, 2)];
        NSInteger c = [cnt[g] integerValue];
        if (c > 0) { cnt[g] = @(c - 1); hit++; }
        total++;
    }
    NSInteger t1 = (NSInteger)x.length - 1;
    return (double)hit / (double)MAX(1, MAX(t1, total));
}

/// 私有方法先声明一遍：块里调用的方法在下面才定义，不声明会走 id 返回值的隐式推断。
@interface ZKInterpreter (Private)
- (void)noteSpoken:(NSString *)text;
- (BOOL)isSpokenEcho:(NSString *)text;
- (void)reconcile:(NSString *)side seg:(NSInteger)seg;
- (void)sourcePartial:(NSString *)side seg:(NSInteger)seg text:(NSString *)text;
- (void)sourceEnd:(NSString *)side seg:(NSInteger)seg text:(NSString *)text;
- (void)transPartial:(NSString *)side seg:(NSInteger)seg text:(NSString *)text;
- (void)transEnd:(NSString *)side seg:(NSInteger)seg text:(NSString *)text;
- (void)transReplace:(NSString *)side seg:(NSInteger)seg text:(NSString *)text;
- (void)state:(NSString *)st;
- (void)fail:(NSString *)why;
- (void)stopMic;
- (BOOL)destFits:(NSString *)side dst:(NSString *)dst;
- (BOOL)isMirror:(NSString *)side src:(NSString *)src;
- (BOOL)mayStart:(NSString *)side length:(NSUInteger)n;
- (void)takeTurn:(NSString *)side;
- (void)rememberFinal:(NSString *)side src:(NSString *)src dst:(NSString *)dst;
- (NSInteger)absorb:(NSString *)side seg:(NSInteger)seg src:(NSString **)srcP dst:(NSString **)dstP;
- (NSInteger)hungrySegFor:(NSString *)side near:(NSInteger)seg;
- (BOOL)patchEmittedDst:(NSString *)side dst:(NSString *)dst;
- (BOOL)isSameAsEmitted:(NSString *)side src:(NSString *)src dst:(NSString *)dst;
- (BOOL)isSpokenEcho:(NSString *)text;
- (void)holdEmit:(NSString *)side seg:(NSInteger)seg;
- (void)flushHold:(NSString *)side;
- (void)emitSettled:(NSString *)side seg:(NSInteger)seg;
- (BOOL)isDropped;
- (void)pushSilence:(NSTimeInterval)seconds;
@end

@implementation ZKInterpreter {
    ZKDoubaoAST *_toOther;   // 我 → 对方
    ZKDoubaoAST *_toMine;    // 对方 → 我

    AVAudioEngine *_engine;
    AVAudioConverter *_conv;
    AVAudioFormat *_outFmt;
    double _inRate;

    NSString *_mine;   // zh-CN
    NSString *_other;  // en-US

    BOOL _running;

    // 每边当前这一句：消息 id、原文、译文（译文可能还没到）
    NSString *_idA, *_idB;
    NSString *_srcA, *_srcB;
    NSString *_dstA, *_dstB;

    // 去重：同一条原文被推两遍、或两个方向听成同一句
    NSString *_lastSrcA, *_lastSrcB;
    NSTimeInterval _lastAtA, _lastAtB;

    NSInteger _seq;
    NSTimeInterval _lastLevelAt;

    // 朗读门：TTS 正在出声的这段时间，麦克风收到的是手机自己的声音。
    // 不挡住的话，念出去的译文会被当成对方说话又识别一遍，
    // 界面上就出现「同一句原文/译文重复一条」，还会把真正的对话切碎。
    NSTimeInterval _gateUntil;
    NSTimeInterval _gateCheckedAt;
    NSTimeInterval _gateFrom;
    // 最近念出去的几句译文：自己念的声音会被麦克风录回来再识别一遍，
    // 那种句子不能当成人话，也不能翻。
    NSMutableArray<NSDictionary *> *_spoken;
    // 每边「已经落定、还在等译文」的句子，按落定顺序排队。
    // 上游的译文回调只给文字、不说是哪一句的译文。以前用一个「当前句」槽位去接：
    // 连着说两句时，第一句的译文回来会盖到第二句头上，第一句就永远停在只有原文。
    // 现在按队列接，先落定的先等到译文，串不了。
    NSMutableArray<NSMutableDictionary *> *_waitA;
    NSMutableArray<NSMutableDictionary *> *_waitB;

    // 长按说话：只有按住这段时间的音频会送给上游；松开补一段静音让上游把整句落定。
    // 取消（上滑）之后的一小段时间里，上游还会把刚才那段吐出结果，一律丢掉。
    BOOL _uttOn;
    CFTimeInterval _uttAt;
    NSTimeInterval _dropUntil;

    // 按句子编号配对的表：编号由服务端给，原文和译文带同一个号。
    // 这一版之前的做法是「译文按到达顺序认领最早一条还没译文的原文」——
    // 只要有一句原文被过滤掉（回声、碎句、重复），后面每一句的译文就整体错一行，
    // 用户看到的就是「译文全串到下一句上」和「有的句子只有原文没译文」。
    // 有了号就不需要猜：谁的译文回到谁头上，少了哪句一眼看得出来。
    NSMutableDictionary<NSNumber *, NSMutableDictionary *> *_segA;
    NSMutableDictionary<NSNumber *, NSMutableDictionary *> *_segB;
    NSInteger _localSegA, _localSegB;   // 老服务端不带号时自己编
    NSInteger _openSegA, _openSegB;     // 正在滚的那一句（0 = 没有）

    // 每边最后落定的一条（原文 + 译文 + 时间）。两条通道听的是同一路声音，
    // 有一路会把对方的话再"译"一遍吐回来（同一句出现两次、一次中文一次英文）。
    // 拿这个互相比较，把重复的那一路丢掉。
    NSString *_finSrcA, *_finDstA, *_finSrcB, *_finDstB;
    NSTimeInterval _finAtA, _finAtB;

    // 当前在说话的是哪一边：用来压掉另一条通道的碎渣
    NSString *_activeSide;
    NSTimeInterval _activeUntil;

    // 上一条落定的句子（每条通道各一份）。上游按静音分句，一句话中间停顿
    // 稍长就会被切成两条——「你叫什么」+「名字」。前一条没带句末标点时，
    // 后面紧跟的短尾巴要接回去，不然界面上就是一句没头没尾的「名字」。
    NSInteger _tailSegA, _tailSegB;
    NSTimeInterval _tailAtA, _tailAtB;
    BOOL _tailClosedA, _tailClosedB;          // 上一条已经是完整句，不再吃尾巴
    NSMutableDictionary<NSNumber *, NSNumber *> *_aliasA, *_aliasB;   // 碎句号 → 接回去的那条号

    // 每条通道最近一条已经上屏的句子。同一句被上游按静音切开、或者被识别成
    // 略有出入的两次，会连着吐两条：一条「你叫什么名字?→What's your name?」，
    // 下一尾巴「名字」又译出一遍「What's your name?」，界面上就是同一句出现两次。
    // 上屏前拿它比一下：同一路的重复句并回上一条，不再另起一个气泡。
    // 落定延迟：上游按静音分句，一句话中间停一下就先把前半段整句发下来，
    // 后半段往往一秒内接着到。立刻上屏的话，界面先出一行半句、第二段到了再补长，
    // 肉眼看到的就是「字在跳、句子断开」，译文也会晚一步单独挂上去。
    // 现在整句落定先压一小会儿：这段时间里接回来的尾巴并进同一条、迟到的译文也能一起上屏。
    NSInteger _holdSegA, _holdSegB;
    NSInteger _holdGenA, _holdGenB;
    // 这一条是从什么时候开始压的：后面接回来尾巴要重新计时，但不能没完没了地压，
    // 以第一次开始压的时间为准给一个硬上限（见 holdDelay）。
    NSInteger _holdFirstSegA, _holdFirstSegB;
    NSTimeInterval _holdFirstAtA, _holdFirstAtB;

    NSInteger _emitSegA, _emitSegB;
    NSString *_emitSrcA, *_emitDstA, *_emitSrcB, *_emitDstB;
    NSTimeInterval _emitAtA, _emitAtB;

    // 每条通道最近几条落定的句子，用来和另一条通道做交叉去重。
    // 两条通道听的是同一路声音，同一句会被两边各出一份（一次中文一次英文），
    // 只比「最后一条」经常比不着——对方那条可能还没落定。
    NSMutableArray<NSDictionary *> *_recentA, *_recentB;

    // 朗读那边正在念的语言（Speaker 每念一句写上，念完清空）。
    // 手机念出来的声音会被麦克风收回去，只有「念的那种语言」那一路会被污染，
    // 所以按语言只暂停对应的那一路，另一路照收——整段静音麦克风就会漏读漏翻。
    NSString *_ttsLang;

    // 已经上屏的气泡（id / 哪一路 / 原文 / 译文 / 时间）。
    // 一句英文被两条通道各听一遍时（a 通道会把它译成中文当原文吐出来），
    // 两边各自上屏就是三行：两个「What's your name?」加一条「你叫什么名字? / name」。
    // 每次落定都到这里对一遍，是同一句的并成一条，多出来的那条从界面上撤掉。
    NSMutableArray<NSMutableDictionary *> *_shown;
}

+ (instancetype)shared {
    static ZKInterpreter *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [ZKInterpreter new]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _mine = @"zh-CN";
        _other = @"en-US";
        _waitA = [NSMutableArray array];
        _waitB = [NSMutableArray array];
        _segA = [NSMutableDictionary dictionary];
        _segB = [NSMutableDictionary dictionary];
        _aliasA = [NSMutableDictionary dictionary];
        _aliasB = [NSMutableDictionary dictionary];
        _recentA = [NSMutableArray array];
        _recentB = [NSMutableArray array];
        _shown = [NSMutableArray array];
        _spoken = [NSMutableArray array];
        _gateFrom = 0;
        _gateUntil = 0;
        _tailClosedA = YES;
        _tailClosedB = YES;
    }
    return self;
}

- (BOOL)running { return _running; }

#pragma mark - 启停

- (void)startWith:(NSString *)a other:(NSString *)b {
    _mine = a.length ? a : @"zh-CN";
    _other = b.length ? b : @"en-US";
    if (_running) { [self setMine:_mine other:_other]; return; }

    // 音频会话：录 + 放。
    //
    // 这里以前用的是 voiceChat 模式（图它自带回声消除），但 voiceChat 会把
    // 整条会话按「通话」处理：朗读出来的译文走通话播放路径，被系统的通话
    // 音频处理当成回声整段抵消掉——用户看到的就是「开了音频输出，一点声音都没有」，
    // 而且通话模式会把采样率与增益锁死，识别也会跟着发闷。
    //
    // 现在改成普通模式，回声消除单独在麦克风那一环打开
    // （见 startMic 里的 setVoiceProcessingEnabled:），TTS 走正常播放路径。
    NSError *err = nil;
    AVAudioSession *s = [AVAudioSession sharedInstance];
    [s setCategory:AVAudioSessionCategoryPlayAndRecord
              mode:AVAudioSessionModeDefault
           options:AVAudioSessionCategoryOptionDefaultToSpeaker | AVAudioSessionCategoryOptionAllowBluetooth
             error:&err];
    // 缓冲给到最小：麦克风这一环少 20ms，字幕就早 20ms
    [s setPreferredIOBufferDuration:0.01 error:nil];
    [s setActive:YES error:&err];
    if (err) { [self fail:@"麦克风没有权限，请在系统设置里允许"]; return; }

    // 两条独立会话：已经预热过的直接续用，没有才现建。
    // 以前这里无条件新建，用户每次点开始都要重新握手（弱网下就是"点了等一秒"）。
    if (!_toOther) {
        _toOther = [ZKDoubaoAST session];
        _toOther.mode = @"interp";
        [self wire:_toOther side:@"a"];
    }
    if (!_toMine) {
        _toMine = [ZKDoubaoAST session];
        _toMine.mode = @"interp";
        [self wire:_toMine side:@"b"];
    }
    [self applyLangs];

    [self resetLines];
    _running = YES;
    // start 本身幂等：已经连着的不会重连，掉了的会重来一次
    [_toOther start];
    [_toMine start];

    [self startMic];
}

- (void)prewarmWith:(NSString *)a other:(NSString *)b {
    if (_running) return;
    _mine = a.length ? a : @"zh-CN";
    _other = b.length ? b : @"en-US";
    if (!_toOther) {
        _toOther = [ZKDoubaoAST session];
        _toOther.mode = @"interp";
        [self wire:_toOther side:@"a"];
    }
    if (!_toMine) {
        _toMine = [ZKDoubaoAST session];
        _toMine.mode = @"interp";
        [self wire:_toMine side:@"b"];
    }
    [self applyLangs];
    // 只连通道，不开麦克风、不激活音频会话：顶部橙点不亮，用户不点开始就等于没在用
    [_toOther start];
    [_toMine start];
}

- (void)setMine:(NSString *)a other:(NSString *)b {
    _mine = a.length ? a : @"zh-CN";
    _other = b.length ? b : @"en-US";
    [self applyLangs];
}

- (void)applyLangs {
    // 两条通道都跑双向：哪条对得上就留哪条
    _toOther.srcLang = ZKShort(_mine);
    _toOther.dstLang = ZKShort(_other);
    _toMine.srcLang = ZKShort(_other);
    _toMine.dstLang = ZKShort(_mine);
}

- (void)resetLines {

    _idA = _idB = nil;
    _srcA = _srcB = nil;
    _dstA = _dstB = nil;



    _lastSrcA = _lastSrcB = nil;
    _lastAtA = _lastAtB = 0;
    _finSrcA = _finDstA = _finSrcB = _finDstB = nil;
    _finAtA = _finAtB = 0;
    _activeSide = nil;
    _activeUntil = 0;
    [_waitA removeAllObjects];
    [_waitB removeAllObjects];
    [_segA removeAllObjects];
    [_segB removeAllObjects];
    [_aliasA removeAllObjects];
    [_aliasB removeAllObjects];
    [_recentA removeAllObjects];
    [_recentB removeAllObjects];
    [_shown removeAllObjects];
    _openSegA = _openSegB = 0;
    _localSegA = _localSegB = 0;
    _tailSegA = _tailSegB = 0;
    _tailAtA = _tailAtB = 0;
    _tailClosedA = _tailClosedB = YES;
    // 还压在手里没上屏的那一句跟着一起作废（代次加一，定时器回来就找不到自己了）
    _holdSegA = _holdSegB = 0;
    _holdGenA += 1;
    _holdGenB += 1;
}

- (void)stop {
    _running = NO;
    _uttOn = NO;
    _dropUntil = 0;
    [self stopMic];
    [_toOther stop]; _toOther = nil;
    [_toMine stop];  _toMine = nil;
    [self resetLines];
    if (self.onLevel) self.onLevel(0);
    NSError *e = nil;
    [[AVAudioSession sharedInstance] setActive:NO
                                   withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
                                         error:&e];
}

#pragma mark - 结果归类

- (void)wire:(ZKDoubaoAST *)ast side:(NSString *)side {
    __weak typeof(self) weakSelf = self;

    ast.onSourcePartial = ^(NSString *delta, NSInteger seg) {
        __strong typeof(weakSelf) s = weakSelf;
        if (!s) return;
        [s sourcePartial:side seg:seg text:delta];
    };
    ast.onSourceEnd = ^(NSString *full, NSInteger seg) {
        __strong typeof(weakSelf) s = weakSelf;
        if (!s) return;
        [s sourceEnd:side seg:seg text:full];
    };
    ast.onTransPartial = ^(NSString *delta, NSInteger seg) {
        __strong typeof(weakSelf) s = weakSelf;
        if (!s) return;
        [s transPartial:side seg:seg text:delta];
    };
    ast.onTransEnd = ^(NSString *full, NSInteger seg) {
        __strong typeof(weakSelf) s = weakSelf;
        if (!s) return;
        [s transEnd:side seg:seg text:full];
    };
    ast.onTransReplace = ^(NSString *full, NSInteger seg) {
        ZKInterpreter *me = weakSelf;
        if (!me) return;
        [me transReplace:side seg:seg text:full];
    };

    ast.onState = ^(NSString *st) {
        __strong typeof(weakSelf) s = weakSelf;
        if (!s) return;
        if ([side isEqualToString:@"a"]) [s state:st];
    };
    ast.onFail = ^(NSString *why) {
        __strong typeof(weakSelf) s = weakSelf;
        if (!s) return;
        if ([side isEqualToString:@"a"]) [s fail:why];
    };
}

/// 这条通道的原文是不是「我这边」说的话
- (BOOL)belongs:(NSString *)side src:(NSString *)src {
    ZKScript sc = ZKSriptOf(src);
    if (sc == ZKScriptUnknown) return YES; // 判不出来就别丢，宁可多显示
    ZKScript mine = ZKScriptOfLang(_mine);
    ZKScript other = ZKScriptOfLang(_other);
    if (mine == other) {
        // 两边同一种文字（比如中文↔日文都有汉字），只能靠通道本身
        return [side isEqualToString:@"a"];
    }
    return [side isEqualToString:@"a"] ? (sc == mine) : (sc == other);
}

/// 两个方向同时听同一段声音，偶发会把同一句认成两边都在说
- (BOOL)isEcho:(NSString *)side src:(NSString *)src {
    if (!src.length) return NO;
    BOOL a = [side isEqualToString:@"a"];
    NSString *otherLast = a ? _lastSrcB : _lastSrcA;
    NSTimeInterval otherAt = a ? _lastAtB : _lastAtA;
    if (otherLast.length && [otherLast isEqualToString:src] && [NSDate date].timeIntervalSince1970 - otherAt < 2.5) {
        return YES;
    }
    return NO;
}

/// 同时在跑的还有另一条通道，它对「不是自己这种语言」的声音也会硬认，
/// 把对方那句再"译"一遍吐回来。真人不会抢在对方话尾半秒内接着说一句短的，
/// 所以另一条通道刚说完的这一小段里，短句一律不收。
/// 这里只查询，不收放行权——真正接过话头是在落定之后（takeTurn）。
- (BOOL)mayStart:(NSString *)side length:(NSUInteger)n {
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    if (_activeSide && ![_activeSide isEqualToString:side] && now < _activeUntil) {
        return n > 6;
    }
    return YES;
}

/// 这一句落定了，发言权归它，另一条通道安静一小会儿
- (void)takeTurn:(NSString *)side {
    _activeSide = side;
    _activeUntil = [NSDate date].timeIntervalSince1970 + 1.1;
}

/// 这一边这一句的气泡 id。按编号来，稳定且不会重：草稿和落定是同一条。
- (NSString *)lineIdFor:(NSString *)side seg:(NSInteger)seg {
    return [NSString stringWithFormat:@"%@-%ld", side, (long)seg];
}

/// 把服务端给的号落到本地。老服务端不带号（seg = 0）时自己编：
/// 原文增量沿用当前句的号，原文整句收尾后换新号。
- (NSInteger)segFor:(NSString *)side raw:(NSInteger)seg ending:(BOOL)ending {
    BOOL a = [side isEqualToString:@"a"];
    NSInteger cur = a ? _openSegA : _openSegB;
    NSInteger n = seg;
    if (n <= 0) {
        if (cur <= 0) {
            if (a) { _localSegA++; n = _localSegA; _openSegA = n; }
            else   { _localSegB++; n = _localSegB; _openSegB = n; }
        } else {
            n = cur;
        }
    }
    if (ending) { if (a) _openSegA = 0; else _openSegB = 0; }
    else        { if (a) _openSegA = n; else _openSegB = n; }
    // 碎句被接回上一句时，它自己的号在本条通道上有别名：
    // 它后面那条译文要跟着挂到接回去的那条上，不然界面上就是「有译文、没原文」。
    NSNumber *to = (a ? _aliasA : _aliasB)[@(n)];
    if (to) n = to.integerValue;
    return n;
}

/// 取这一句的记录；没有就建
- (NSMutableDictionary *)entryFor:(NSString *)side seg:(NSInteger)seg {
    NSMutableDictionary *m = [side isEqualToString:@"a"] ? _segA : _segB;
    NSNumber *k = @(seg);
    NSMutableDictionary *e = m[k];
    if (!e) {
        e = [@{@"seg": k, @"src": @"", @"dst": @"", @"at": @([NSDate date].timeIntervalSince1970)} mutableCopy];
        m[k] = e;
    }
    return e;
}

/// 译文回来了，但它带的号在本通道上找不到有原文的那一条（上游两条流各走各的，
/// 译文先到、或者号对不齐都会这样）。以前这里直接丢弃，界面上就是
/// 「左边整段只有英文、一句中文都没有」。现在按顺序兜底：找本通道最近一条
/// 有原文、还没译文、12 秒内的句子，把译文挂上去。
- (NSInteger)hungrySegFor:(NSString *)side near:(NSInteger)seg {
    NSMutableDictionary *m = [side isEqualToString:@"a"] ? _segA : _segB;
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    NSInteger best = 0;
    NSTimeInterval bestAt = 0;
    for (NSNumber *k in m) {
        NSDictionary *e = m[k];
        if (![e[@"src"] length]) continue;
        if ([e[@"dst"] length]) continue;
        if (now - [e[@"at"] doubleValue] > 20.0) continue;
        NSTimeInterval at = [e[@"at"] doubleValue];
        if (at > bestAt) { bestAt = at; best = k.integerValue; }
    }
    (void)seg;
    return best;
}

/// 译文到了，但这句原文早就在别的号上落定、已经上屏了：直接补到那一行上，
/// 不再空等一个永远不会来的原文。返回 YES 表示补上了。
/// 只在「这一边最近一条上屏记录还是空的译文」时补，避免把上一句的译文
/// 反复刷到同一行上。
- (BOOL)patchEmittedDst:(NSString *)side dst:(NSString *)dst {
    if (!dst.length) return NO;
    BOOL a = [side isEqualToString:@"a"];
    NSInteger seg = a ? _emitSegA : _emitSegB;
    NSString *src = (a ? _emitSrcA : _emitSrcB) ?: @"";
    NSString *had = (a ? _emitDstA : _emitDstB) ?: @"";
    NSTimeInterval at = a ? _emitAtA : _emitAtB;
    if (seg <= 0 || !src.length) return NO;
    NSTimeInterval gap = [NSDate date].timeIntervalSince1970 - at;
    // 太近的不补：译文常常比它自己的原文整句先到，这时候补上就会挂到
    // 上一条头上（历史上「译文整体错一行」就是这么来的）。给它 3 秒
    // 等自己的原文；原文一直没来，才认定是上一条迟到的译文。
    if (gap < 3.0 || gap > 20.0) return NO;
    NSString *out = dst;
    if (had.length) {
        out = ZKMergeTrans(had, dst);
        if ([out isEqualToString:had]) return NO;
    }
    NSMutableDictionary *e = [self entryFor:side seg:seg];
    e[@"dst"] = out;
    e[@"at"] = @([NSDate date].timeIntervalSince1970);
    if (a) { _emitDstA = out; _emitAtA = [NSDate date].timeIntervalSince1970; }
    else   { _emitDstB = out; _emitAtB = [NSDate date].timeIntervalSince1970; }
    [self emit:[self lineIdFor:side seg:seg] side:side src:src dst:out kind:ZKLineKindFinal];
    [self rememberFinal:side src:src dst:out];
    return YES;
}

/// 太久没动静的句子记录清掉，别一直挂着占内存
- (void)sweepSegs {
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    for (NSMutableDictionary *m in @[_segA, _segB]) {
        NSMutableArray *dead = [NSMutableArray array];
        for (NSNumber *k in m) {
            NSDictionary *e = m[k];
            if (now - [e[@"at"] doubleValue] > 25.0) [dead addObject:k];
        }
        [m removeObjectsForKeys:dead];
    }
}

/// 这句最终没能落定（重复、回声、纯噪声）：把它的草稿气泡撤掉。
- (void)dropSeg:(NSString *)side seg:(NSInteger)seg {
    if (seg <= 0) return;
    [self emit:[self lineIdFor:side seg:seg] side:side src:@"" dst:@"" kind:ZKLineKindDraft];
    NSMutableDictionary *m = [side isEqualToString:@"a"] ? _segA : _segB;
    [m removeObjectForKey:@(seg)];
}

- (void)sourcePartial:(NSString *)side seg:(NSInteger)segRaw text:(NSString *)text {
    if (!_running) return;
    if ([self isDropped]) return;   // 刚被取消的那一段：上游迟到的结果一律不要
    NSString *t = ZKClean(text);
    if (!ZKHasContent(t)) return;
    if (![self belongs:side src:t]) return;
    if ([self isSpokenEcho:t]) return;   // 自己念出来的译文又录回来一遍，不收
    if (![self mayStart:side length:t.length]) return;

    NSInteger seg = [self segFor:side raw:segRaw ending:NO];
    NSMutableDictionary *e = [self entryFor:side seg:seg];
    // 边说边出的半句只存着，不上屏。
    // 同传这一档要的是「整句准」，不是「出字快」：半句先上屏，等整句落定时
    // 文字会整段变一次，肉眼看到的就是「字幕在跳着改」；更糟的是译文经常比原文整句先到，
    // 半句和译文对不齐，就会出现截图上那种「你好，/How are you?」的错行。
    // 所以这里只落库，等 sourceEnd 一次成行。
    e[@"src"] = t;
    e[@"at"] = @([NSDate date].timeIntervalSince1970);
    // 半句也推出去：说话的人还在说，屏幕上已经有字，
    // 「说完了才有反应」的那种迟滞感就没了。整句落定时同一条 id 就地补全，
    // 不会多冒出第二个气泡。
    [self emit:[self lineIdFor:side seg:seg] side:side
           src:t dst:(e[@"dst"] ?: @"") kind:ZKLineKindDraft];
}

- (void)sourceEnd:(NSString *)side seg:(NSInteger)segRaw text:(NSString *)text {
    if (!_running) return;
    if ([self isDropped]) return;   // 刚被取消的那一段：上游迟到的结果一律不要
    NSString *t = ZKClean(text);
    if (!ZKHasContent(t)) return;
    if (![self belongs:side src:t]) return;
    if ([self isSpokenEcho:t]) return;   // 自己念出来的译文又录回来一遍，不收

    BOOL a = [side isEqualToString:@"a"];
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;

    NSString *last = a ? _lastSrcA : _lastSrcB;
    NSTimeInterval lastAt = a ? _lastAtA : _lastAtB;
    // 同一句被上游重复推一遍：丢掉，但不撤销已经上屏的内容
    if (last.length && [last isEqualToString:t] && now - lastAt < 3.0) return;

    // 另一条通道刚说完，这一小段里的短句基本都是它把对方的声音硬认了一遍
    if (![self mayStart:side length:t.length]) return;
    if ([self isEcho:side src:t]) return;
    // 另一条通道刚吐过几乎同一句 → 同一路声音被反向译了一遍，丢掉
    if ([self isMirror:side src:t]) return;

    if (a) { _lastSrcA = t; _lastAtA = now; } else { _lastSrcB = t; _lastAtB = now; }

    // 上一条没带句末标点，紧跟着又来了一个短尾巴：这是同一句被上游按静音
    // 切开的两段（「你叫什么」+「名字」）。接回上一条，不另起一个气泡。
    NSInteger tailSeg = a ? _tailSegA : _tailSegB;
    NSTimeInterval tailAt = a ? _tailAtA : _tailAtB;
    BOOL tailClosed = a ? _tailClosedA : _tailClosedB;
    // 上游按静音分句，一句话中间停一下就切成两段。
    // 规则只有一条：**上一句没说完就接**（「你叫什么」+「名字」）；
    // 上一句已经收尾（带句末标点）时，只有「一个词/两三个字」这种碎片才接
    // （「你叫什么名字?」+「name」），完整的另一句一律自己成行。
    BOOL glue = NO;
    if (tailSeg > 0 && (now - tailAt) < 3.2) {
        NSString *prevSrc = [self entryFor:side seg:tailSeg][@"src"] ?: @"";
        BOOL prevLong = prevSrc.length >= 60;   // 已经够长，不再往后接
        if (tailClosed) {
            // 上一句已经收尾：只有「name」「名字」这种碎片才接回去
            glue = ZKIsFragment(t);
        } else {
            // 上一句没收尾：只在紧跟其后（1.0 秒内）的短尾巴才接，
            // 而且这一小段自己不能带标点（带标点 = 一句独立的话），
            // 否则就是另一句完整的话，自己成行
            glue = !prevLong && (now - tailAt) < 1.0
                   && !ZKHasClausePunct(t) && ZKIsTailLike(t);
        }
    }

    NSInteger seg = 0;
    NSMutableDictionary *e = nil;
    if (glue) {
        seg = tailSeg;
        e = [self entryFor:side seg:seg];
        e[@"src"] = ZKJoinSrc(e[@"src"] ?: @"", t);
        // 这条碎句的译文可能比原文整句先到，已经挂在它自己的号上了：搬过来
        if (segRaw > 0 && segRaw != seg) {
            NSMutableDictionary *old = (a ? _segA : _segB)[@(segRaw)];
            NSString *od = old[@"dst"];
            if (od.length) e[@"dst"] = ZKMergeTrans(od, e[@"dst"] ?: @"");
        }
        if (a) { _openSegA = 0; _tailAtA = now; _tailClosedA = ZKEndsSentence(e[@"src"]); }
        else   { _openSegB = 0; _tailAtB = now; _tailClosedB = ZKEndsSentence(e[@"src"]); }
    } else {
        seg = [self segFor:side raw:segRaw ending:YES];
        e = [self entryFor:side seg:seg];
        e[@"src"] = t;
        if (a) { _tailSegA = seg; _tailAtA = now; _tailClosedA = ZKEndsSentence(t); }
        else   { _tailSegB = seg; _tailAtB = now; _tailClosedB = ZKEndsSentence(t); }
    }
    e[@"at"] = @(now);

    // 碎句被接回去之后，它自己那条译文（上游按它自己的号发）要挂到接回去的那条上，
    // 不然界面上就是「有译文、没原文」。
    if (segRaw > 0 && segRaw != seg) {
        NSMutableDictionary *alias = a ? _aliasA : _aliasB;
        alias[@(segRaw)] = @(seg);
        // 它刚才边听边出字时已经推过一条草稿气泡：现在被接回上一句了，把它撤掉，
        // 否则屏幕上会永远挂着半句没头没尾的字。
        [self emit:[self lineIdFor:side seg:segRaw] side:side src:@"" dst:@"" kind:ZKLineKindDraft];
    }

    // 不立刻上屏：先压一小会儿，等这一句的后半段、以及迟到的译文到齐。
    [self holdEmit:side seg:seg];
}

/// 整句落定 -> 压一小会儿再上屏。
///
/// 上游按静音分句：一句话中间停一两秒，前半段就作为整句发下来了，后半段一秒内接着到。
/// 立刻上屏的话，界面上先出半句、第二段到了再补长，看着就是「字在跳、句子断开」；
/// 译文也常常比原文晚半秒到，先上屏就会看到一行只有原文、再单独补一行译文。
/// 这一小段等待里接回来的尾巴会并进同一条，上屏时就是完整一句带译文。
// 上屏不再压时间：上游一句落定，这边立刻上屏。
//
// 前几版在这里压 0.55~2.0 秒，为的是等译文、等被上游按静音切开的尾巴，
// 结果整句要一秒多才出来，用户看到的就是「字幕慢」。
// 现在改成最原生的返回速度：上游给一句就上屏一句；
// 同一句的后半段若紧接着再来，会并回同一条（见 sourceEnd 的 glue 与 holdEmit 的合并），
// 界面上是同一行补长，不会多出一个气泡；译文晚到也照样就地补在原文下面。
// 也就是说：速度由上游决定，不吃我们额外加的等待。
static const NSTimeInterval ZKHoldReady = 0.0;
static const NSTimeInterval ZKHoldWaitDst = 0.0;
static const NSTimeInterval ZKHoldOpen = 0.0;
static const NSTimeInterval ZKHoldCap = 0.0;

- (void)holdEmit:(NSString *)side seg:(NSInteger)seg {
    if (seg <= 0) return;
    BOOL a = [side isEqualToString:@"a"];
    // 上一条还在压下、这一条又来了
    NSInteger prev = a ? _holdSegA : _holdSegB;
    if (prev > 0 && prev != seg) {
        // 上一条结尾没句末标点（话没说完），间隔又短：基本还是同一句被上游按静音切开的两段。
        // 并进上一条一起上屏——以前这里直接「压一条、放一条」，界面上就是一句话拆成两个气泡。
        BOOL closed = a ? _tailClosedA : _tailClosedB;
        NSTimeInterval tailAt = a ? _tailAtA : _tailAtB;
        NSTimeInterval now = [NSDate date].timeIntervalSince1970;
        NSMutableDictionary *pe = [self entryFor:side seg:prev];
        NSMutableDictionary *ne = [self entryFor:side seg:seg];
        NSString *ns2 = ne[@"src"] ?: @"";
        if (!closed && ns2.length && (now - tailAt) < 1.0
            && !ZKHasClausePunct(ns2) && ZKIsTailLike(ns2)) {
            pe[@"src"] = ZKJoinSrc(pe[@"src"] ?: @"", ns2);
            NSString *nd = ne[@"dst"];
            if (nd.length) pe[@"dst"] = ZKMergeTrans(pe[@"dst"] ?: @"", nd);
            pe[@"at"] = @(now);
            // 这一段的号以后再有译文，也挂到并进去的那条上
            [(a ? _aliasA : _aliasB) setObject:@(prev) forKey:@(seg)];
            [(a ? _segA : _segB) removeObjectForKey:@(seg)];
            [self emit:[self lineIdFor:side seg:seg] side:side src:@"" dst:@"" kind:ZKLineKindDraft];
            if (a) { _tailSegA = prev; _tailAtA = now; _tailClosedA = ZKEndsSentence(pe[@"src"]); }
            else   { _tailSegB = prev; _tailAtB = now; _tailClosedB = ZKEndsSentence(pe[@"src"]); }
            [self armHold:side seg:prev];   // 重新计时，等这句真正说完再上屏
            return;
        }
        [self flushHold:side];   // 上一条确实是完整的一句：先发出去，别把它吞了
    }

    [self armHold:side seg:seg];
}

/// 开始/重置这一条的上屏倒计时
- (NSTimeInterval)holdDelay:(NSString *)side seg:(NSInteger)seg {
    BOOL a = [side isEqualToString:@"a"];
    NSMutableDictionary *e = [self entryFor:side seg:seg];
    NSString *src = e[@"src"] ?: @"";
    NSString *dst = e[@"dst"] ?: @"";
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;

    // 这一条第一次开始压的时间（接回来尾巴会重新调 armHold，但不能因此无限延长）
    NSInteger firstSeg = a ? _holdFirstSegA : _holdFirstSegB;
    NSTimeInterval firstAt = a ? _holdFirstAtA : _holdFirstAtB;
    if (firstSeg != seg || firstAt <= 0) {
        firstSeg = seg;
        firstAt = now;
        if (a) { _holdFirstSegA = seg; _holdFirstAtA = now; }
        else   { _holdFirstSegB = seg; _holdFirstAtB = now; }
    }

    NSTimeInterval d = ZKHoldOpen;
    if (ZKEndsSentence(src)) {
        d = (dst.length > 0) ? ZKHoldReady : ZKHoldWaitDst;
    }
    NSTimeInterval left = firstAt + ZKHoldCap - now;
    if (left < 0.25) left = 0.25;
    return MIN(d, left);
}

- (void)armHold:(NSString *)side seg:(NSInteger)seg {
    if (seg <= 0) return;
    BOOL a = [side isEqualToString:@"a"];
    if (a) { _holdSegA = seg; _holdGenA += 1; }
    else   { _holdSegB = seg; _holdGenB += 1; }
    NSInteger gen = a ? _holdGenA : _holdGenB;

    NSTimeInterval delay = [self holdDelay:side seg:seg];
    // 不压时间：立刻上屏。留这条分支是为了以后想调回「等译文」时只改常量就行。
    if (delay <= 0) { [self flushHold:side]; return; }
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        ZKInterpreter *me = weakSelf;
        if (!me) return;
        // 这期间又接回来一段（尾巴并进同一条），代次已经变了：等下一次
        NSInteger g = a ? me->_holdGenA : me->_holdGenB;
        if (g != gen) return;
        NSInteger cur = a ? me->_holdSegA : me->_holdSegB;
        if (cur != seg) return;
        [me flushHold:side];
    });
}

- (void)flushHold:(NSString *)side {
    BOOL a = [side isEqualToString:@"a"];
    NSInteger seg = a ? _holdSegA : _holdSegB;
    if (seg <= 0) return;
    if (a) { _holdSegA = 0; _holdGenA += 1; }
    else   { _holdSegB = 0; _holdGenB += 1; }
    [self emitSettled:side seg:seg];
}

/// 上屏一条已经落定的句子（原文 + 当时拿到的译文）。
- (void)emitSettled:(NSString *)side seg:(NSInteger)seg {
    NSMutableDictionary *e = [self entryFor:side seg:seg];
    NSString *src = e[@"src"] ?: @"";
    NSString *dst = e[@"dst"] ?: @"";
    if (!ZKHasContent(src)) return;
    if ([self absorb:side seg:seg src:&src dst:&dst] > 0) {
        [self takeTurn:side];
        [self sweepSegs];
        return;
    }
    BOOL a = [side isEqualToString:@"a"];
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    [self emit:[self lineIdFor:side seg:seg] side:side src:src dst:dst kind:ZKLineKindFinal];
    [self rememberFinal:side src:src dst:dst];
    if (a) { _emitSegA = seg; _emitSrcA = src; _emitDstA = dst; _emitAtA = now; }
    else   { _emitSegB = seg; _emitSrcB = src; _emitDstB = dst; _emitAtB = now; }
    [self reconcile:side seg:seg];
    [self takeTurn:side];
    [self sweepSegs];
}

/// 上屏前拿「这一边刚刚上屏的那一条」比一下。
/// 上游按静音把一句话切成两段推下来时（「你叫什么」+「名字」），
/// 或者在两段之间补推了一次译文，就会出现两条内容相同的句子：
/// 截图里两个「What's your name?」、以及「你叫什么名字? / name」都是这么来的。
/// 同一路里跟前一条是同一句的，并回那一条，不再另起气泡；返回并进去的那条号，没并返回 0。
- (NSInteger)absorb:(NSString *)side seg:(NSInteger)seg src:(NSString **)srcP dst:(NSString **)dstP {
    BOOL a = [side isEqualToString:@"a"];
    NSInteger pSeg = a ? _emitSegA : _emitSegB;
    NSString *pSrc = (a ? _emitSrcA : _emitSrcB) ?: @"";
    NSString *pDst = (a ? _emitDstA : _emitDstB) ?: @"";
    NSTimeInterval pAt = a ? _emitAtA : _emitAtB;
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    if (pSeg <= 0 || pSeg == seg) return 0;
    if (now - pAt > 6.0) return 0;

    NSString *src = *srcP ?: @"";
    NSString *dst = *dstP ?: @"";
    if (!src.length) return 0;

    NSString *ns2 = src.lowercaseString;
    NSString *ps2 = pSrc.lowercaseString;
    BOOL inside = ps2.length >= 2 && ns2.length >= 2 &&
                  ([ps2 rangeOfString:ns2].location != NSNotFound ||
                   [ns2 rangeOfString:ps2].location != NSNotFound);
    BOOL sameSrc = (ZKSim(src, pSrc) >= 0.8) || inside;
    BOOL sameDst = dst.length > 0 && pDst.length > 0 &&
                   ([dst isEqualToString:pDst] || ZKSim(dst, pDst) >= 0.8);

    if (!(sameSrc || sameDst)) return 0;
    // 两句都是完整句子、只是长得像（「你好」/「你好吗」这种）：不并
    if (sameSrc && !inside && ZKSim(src, pSrc) < 0.8) return 0;

    NSMutableDictionary *e = [self entryFor:side seg:pSeg];
    NSString *newSrc = pSrc;
    if (src.length > pSrc.length && (inside || sameSrc)) newSrc = src;
    else if (!inside && src.length) newSrc = ZKJoinSrc(pSrc, src);
    NSString *newDst = pDst;
    if (!newDst.length) newDst = dst;
    else if (dst.length) newDst = (dst.length > pDst.length) ? dst : ZKMergeTrans(pDst, dst);

    e[@"src"] = newSrc;
    e[@"dst"] = newDst;
    e[@"at"] = @(now);

    if (a) { _emitSrcA = newSrc; _emitDstA = newDst; }
    else   { _emitSrcB = newSrc; _emitDstB = newDst; }

    // 被并掉的那条：号留下别名，后面迟到的译文还能挂到并进去的那条上；
    // 它自己的记录清掉，免得界面上再冒一条。
    if (seg > 0) {
        NSMutableDictionary *alias = a ? _aliasA : _aliasB;
        alias[@(seg)] = @(pSeg);
        NSMutableDictionary *m = a ? _segA : _segB;
        [m removeObjectForKey:@(seg)];
        [self emit:[self lineIdFor:side seg:seg] side:side src:@"" dst:@"" kind:ZKLineKindDraft];
    }
    [self emit:[self lineIdFor:side seg:pSeg] side:side src:newSrc dst:newDst kind:ZKLineKindFinal];
    [self rememberFinal:side src:newSrc dst:newDst];
    [self reconcile:side seg:pSeg];
    return pSeg;
}

/// 记下这一边最后落定的一条（原文 + 译文 + 时间），并留一份最近几条给跨通道去重用。
/// 同一句先落原文、后补译文时更新最后一条，不再追加一条重复的。
- (void)rememberFinal:(NSString *)side src:(NSString *)src dst:(NSString *)dst {
    BOOL a = [side isEqualToString:@"a"];
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    NSString *s0 = src ?: @"";
    NSString *d0 = dst ?: @"";
    if (a) { _finSrcA = s0; _finDstA = d0; _finAtA = now; }
    else   { _finSrcB = s0; _finDstB = d0; _finAtB = now; }

    NSMutableArray<NSDictionary *> *recent = a ? _recentA : _recentB;
    NSDictionary *last = recent.lastObject;
    if (last && [last[@"src"] isEqualToString:s0]) [recent removeLastObject];
    [recent addObject:@{@"src": s0, @"dst": d0, @"at": @(now)}];
    while (recent.count > 8) [recent removeObjectAtIndex:0];
}

/// 整句替换：上游这句只翻了半句，服务端重翻了一遍发下来（replace=true）。
/// 直接把这一行已有的译文换掉——这里绝不能再走 ZKMergeTrans，
/// 否则就是「Beijing 欢迎来到北京」这种半句拼接。
- (void)transReplace:(NSString *)side seg:(NSInteger)segRaw text:(NSString *)text {
    if (!_running) return;
    if ([self isDropped]) return;   // 刚被取消的那一段：上游迟到的结果一律不要
    NSString *t = ZKClean(text);
    if (!t.length) return;
    if (![self destFits:side dst:t]) return;

    BOOL a = [side isEqualToString:@"a"];
    NSInteger openKeep = a ? _openSegA : _openSegB;
    NSInteger seg = [self segFor:side raw:segRaw ending:NO];
    if (a) _openSegA = openKeep; else _openSegB = openKeep;

    NSMutableDictionary *e = [self entryFor:side seg:seg];
    NSString *src = e[@"src"] ?: @"";
    e[@"dst"] = t;
    e[@"at"] = @([NSDate date].timeIntervalSince1970);
    if (!src.length) {
        // 原文还没落定：记下就够了，原文上屏时会带着它一起出
        [self sweepSegs];
        return;
    }
    [self emit:[self lineIdFor:side seg:seg] side:side src:src dst:t kind:ZKLineKindFinal];
    [self rememberFinal:side src:src dst:t];
    if (a) { _emitDstA = t; _emitAtA = [NSDate date].timeIntervalSince1970; }
    else   { _emitDstB = t; _emitAtB = [NSDate date].timeIntervalSince1970; }
    [self sweepSegs];
}

- (void)transPartial:(NSString *)side seg:(NSInteger)segRaw text:(NSString *)text {
    if (!_running) return;
    if ([self isDropped]) return;   // 刚被取消的那一段：上游迟到的结果一律不要
    NSString *t = ZKClean(text);
    if (!t.length) return;

    if (![self destFits:side dst:t]) return;

    BOOL a0 = [side isEqualToString:@"a"];
    NSInteger open = a0 ? _openSegA : _openSegB;
    if (segRaw <= 0 && open <= 0) {
        NSInteger tail = a0 ? _tailSegA : _tailSegB;
        NSTimeInterval tailAt = a0 ? _tailAtA : _tailAtB;
        if (tail > 0 && ([NSDate date].timeIntervalSince1970 - tailAt) < 6.0) segRaw = tail;
    }
    NSInteger seg = [self segFor:side raw:segRaw ending:NO];
    // 译文不该把「进行中的句子」这个位置占住：占了之后，下一句原文会沿用译文的号，
    // 整排就错一行。这里还原回原文自己的位置。
    if (a0) _openSegA = open; else _openSegB = open;
    // 只有上游没给号（老服务端 seg=0）时才按「最近一句还没译文的」兜底。
    // 带号的译文一律只挂自己那一条：按"最近空着的"去猜，
    // 一旦有一句上游没回译文，后面每一句都会整体错一行——
    // 截图里「Welcome to Beijing」下面写着「你在干嘛」就是这么来的。
    if (segRaw <= 0 && ![[self entryFor:side seg:seg][@"src"] length]) {
        NSInteger alt = [self hungrySegFor:side near:seg];
        if (alt > 0) seg = alt;
    }
    NSMutableDictionary *e = [self entryFor:side seg:seg];
    NSString *merged = ZKMergeTrans(e[@"dst"] ?: @"", t);
    e[@"dst"] = merged;
    e[@"at"] = @([NSDate date].timeIntervalSince1970);

    // 译文也是整句才上屏：边说边补的译文先攒在记录里，
    // 等这句的译文整句（655）到了再一次性显示，避免同一行被反复改写。
    // 原文还没到的，先存着等原文整句到了再一起上屏。
}

- (void)transEnd:(NSString *)side seg:(NSInteger)segRaw text:(NSString *)text {
    if (!_running) return;
    if ([self isDropped]) return;   // 刚被取消的那一段：上游迟到的结果一律不要
    NSString *t = ZKClean(text);
    if (!t.length) return;

    if (![self destFits:side dst:t]) return;

    // 老服务端这条不带号（seg = 0），而这一边手上已经没有进行中的句子了：
    // 以前会新开一条「只有译文、没有原文」的记录，之后要么空着、要么挂到下一句上。
    // 这一边刚落定过一句、还在等译文的，就挂回那一句。
    if (segRaw <= 0) {
        BOOL a0 = [side isEqualToString:@"a"];
        NSInteger open = a0 ? _openSegA : _openSegB;
        NSInteger tail = a0 ? _tailSegA : _tailSegB;
        NSTimeInterval tailAt = a0 ? _tailAtA : _tailAtB;
        if (open <= 0 && tail > 0 && ([NSDate date].timeIntervalSince1970 - tailAt) < 6.0) segRaw = tail;
    }

    BOOL aHead = [side isEqualToString:@"a"];
    NSInteger openKeep = aHead ? _openSegA : _openSegB;
    NSInteger seg = [self segFor:side raw:segRaw ending:NO];
    if (aHead) _openSegA = openKeep; else _openSegB = openKeep;
    // 只有上游没给号（老服务端 seg=0）时才按「最近一句还没译文的」兜底。
    // 带号的译文一律只挂自己那一条：按"最近空着的"去猜，
    // 一旦有一句上游没回译文，后面每一句都会整体错一行——
    // 截图里「Welcome to Beijing」下面写着「你在干嘛」就是这么来的。
    if (segRaw <= 0 && ![[self entryFor:side seg:seg][@"src"] length]) {
        NSInteger alt = [self hungrySegFor:side near:seg];
        if (alt > 0) seg = alt;
    }
    NSMutableDictionary *e = [self entryFor:side seg:seg];
    // 上游这条有时给整句、有时只给这一句的最后一段。以前直接覆盖，
    // 「你叫什么名字?」就只剩「名字」。这里合并，短的接上去、长的整体替换。
    NSString *merged = ZKMergeTrans(e[@"dst"] ?: @"", t);
    e[@"dst"] = merged;
    e[@"at"] = @([NSDate date].timeIntervalSince1970);
    NSString *src = e[@"src"] ?: @"";
    // 原文还没到：译文已经存在这条记录里，原文落地时（sourceEnd）会带着它一起上屏，
    // 迟一点点也能补上，不会再出现「这句永远没有译文」。
    if (!src.length) {
        // 还有一种情况：原文早就上屏过了，只是号对不上（上游原文、译文两条流
        // 各走各的号）。这条译文挂不回任何记录，以前直接丢掉，界面上就是
        // 「左边整段只有英文、一句中文都没有」。现在补到本通道最近一条
        // 「有原文、还没译文」的已上屏记录上，原地把那一行补全。
        if ([self patchEmittedDst:side dst:merged]) {
            NSMutableDictionary *m = aHead ? _segA : _segB;
            if (seg != (aHead ? _emitSegA : _emitSegB)) [m removeObjectForKey:@(seg)];
            [self sweepSegs];
        }
        return;
    }
    // 这一条还压在手里等上屏（整句落定后的那一小段等待）：只把译文记上，
    // 到时候原文和译文一起上去。不然界面上会先出一行原文，隔半秒再单独补一行译文。
    if (seg == (aHead ? _holdSegA : _holdSegB)) {
        // 原文、译文都齐了：重新算一次延迟（0.55 秒），不用再干等那 0.95 秒
        [self armHold:side seg:seg];
        [self sweepSegs];
        return;
    }

    NSString *ds = merged;
    if ([self absorb:side seg:seg src:&src dst:&ds] > 0) { [self sweepSegs]; return; }
    [self emit:[self lineIdFor:side seg:seg] side:side src:src dst:ds kind:ZKLineKindFinal];
    [self rememberFinal:side src:src dst:ds];
    BOOL a1 = [side isEqualToString:@"a"];
    NSTimeInterval now1 = [NSDate date].timeIntervalSince1970;
    if (a1) { _emitSegA = seg; _emitSrcA = src; _emitDstA = ds; _emitAtA = now1; }
    else    { _emitSegB = seg; _emitSrcB = src; _emitDstB = ds; _emitAtB = now1; }
    [self reconcile:side seg:seg];
    [self sweepSegs];
}

/// 这条通道吐出来的译文是不是它该有的目标语言。
/// en→zh 的通道如果把中文听成了英文、再"译"成英文，两行就都是英文，
/// 这种条目上屏只会让人看着莫名其妙——直接不要。
- (BOOL)destFits:(NSString *)side dst:(NSString *)dst {
    if (!dst.length) return YES;
    ZKScript sc = ZKSriptOf(dst);
    if (sc == ZKScriptUnknown) return YES;
    BOOL a = [side isEqualToString:@"a"];
    ZKScript want = ZKScriptOfLang(a ? _other : _mine);
    if (want == ZKScriptUnknown) return YES;
    return sc == want;
}

/// 两条通道听的是同一路声音。有一路会把对方的话再译一遍吐回来，
/// 结果同一句在界面上出现两次（一次中文一次英文）。另一路刚吐过几乎一样的，就丢掉。
- (BOOL)isMirror:(NSString *)side src:(NSString *)src {
    if (!src.length) return NO;
    BOOL a = [side isEqualToString:@"a"];
    NSArray<NSDictionary *> *recent = a ? _recentB : _recentA;
    if (!recent.count) return NO;
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    for (NSDictionary *r in recent.reverseObjectEnumerator) {
        NSTimeInterval at = [r[@"at"] doubleValue];
        if (now - at > 8.0) break;
        double s1 = ZKSim(src, r[@"src"] ?: @"");
        double s2 = ZKSim(src, r[@"dst"] ?: @"");
        // 对方的原文或译文有一条几乎一样：同一路声音，只留一条
        if (MAX(s1, s2) >= 0.62) return YES;
    }
    return NO;
}

/// 两句话像不像：像，或者一句整个包住另一句（「名字」包在「你叫什么名字」里）
static BOOL ZKAlike(NSString *a, NSString *b, double thr, NSUInteger minShort) {
    if (a.length < 2 || b.length < 2) return NO;
    if (ZKSim(a, b) >= thr) return YES;
    NSString *x = ZKNorm(a), *y = ZKNorm(b);
    if (x.length < (NSInteger)minShort || y.length < (NSInteger)minShort) return NO;
    return [x rangeOfString:y].location != NSNotFound ||
           [y rangeOfString:x].location != NSNotFound;
}

#pragma mark - 回声 / 重复

/// 这一句是我们自己刚念出去的译文，被麦克风录回来又识别了一遍。
/// 认得出来就丢：不显示、不翻译，也不再念一遍。
- (void)noteSpoken:(NSString *)text {
    NSString *t = ZKClean(text ?: @"");
    if (!t.length) return;
    if (!_spoken) _spoken = [NSMutableArray array];
    [_spoken addObject:@{@"t": t, @"at": @([NSDate date].timeIntervalSince1970)}];
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    NSMutableArray *dead = [NSMutableArray array];
    for (NSDictionary *d in _spoken) {
        if (now - [d[@"at"] doubleValue] > 12.0) [dead addObject:d];
    }
    [_spoken removeObjectsInArray:dead];
    while (_spoken.count > 24) [_spoken removeObjectAtIndex:0];
}

- (BOOL)isSpokenEcho:(NSString *)text {
    if (!text.length || !_spoken.count) return NO;
    NSString *k = ZKClean(text).lowercaseString;
    if (k.length < 3) return NO;
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    for (NSDictionary *d in _spoken) {
        if (now - [d[@"at"] doubleValue] > 12.0) continue;
        NSString *s = [d[@"t"] lowercaseString];
        if (!s.length) continue;
        if ([s isEqualToString:k]) return YES;
        if (s.length >= 4 && ([s containsString:k] || [k containsString:s])) return YES;
    }
    return NO;
}

/// 上屏之后对一遍账。
/// 两条通道听的是同一路声音：对方说一句英文，b 通道如实出英文原文，
/// a 通道（源语言中文）会把同一句"译"成中文当原文再吐一遍，两边各自上屏，
/// 界面上就是「What's your name?」「What's your name?」「你叫什么名字? / name」三行。
/// 同一路里被上游按静音切开、重复推两遍的也一样。这里把重复的并回先上屏的那条。
- (void)reconcile:(NSString *)side seg:(NSInteger)seg {
    if (seg <= 0 || !_running) return;
    if (!_shown) _shown = [NSMutableArray array];
    NSMutableDictionary *e = [self entryFor:side seg:seg];
    NSString *src = e[@"src"] ?: @"";
    NSString *dst = e[@"dst"] ?: @"";
    if (!src.length) return;
    NSString *lid = [self lineIdFor:side seg:seg];
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;

    NSMutableDictionary *me = nil;
    for (NSMutableDictionary *r in _shown) {
        if ([r[@"lid"] isEqualToString:lid]) { me = r; break; }
    }
    if (!me) {
        me = [NSMutableDictionary dictionary];
        me[@"lid"] = lid;
        me[@"side"] = side;
        me[@"seg"] = @(seg);
        [_shown addObject:me];
    }
    me[@"src"] = src;
    me[@"dst"] = dst;
    me[@"at"] = @(now);
    while (_shown.count > 24) [_shown removeObjectAtIndex:0];

    for (NSMutableDictionary *r in [_shown copy]) {
        if (r == me) continue;
        if (now - [r[@"at"] doubleValue] > 20.0) continue;
        NSString *rs = r[@"src"] ?: @"";
        NSString *rd = r[@"dst"] ?: @"";
        BOOL cross = ![r[@"side"] isEqualToString:side];
        BOOL hit = NO;
        if (cross) {
            // 两条通道听的是同一路声音：能对上的是「一边的原文」和「另一边的译文」，
            // 四种组合都过一遍，只要有一对够像就是同一句。
            hit = ZKAlike(src, rs, 0.62, 2) || ZKAlike(src, rd, 0.62, 2) ||
                  ZKAlike(dst, rs, 0.62, 2) || ZKAlike(dst, rd, 0.62, 2);
        } else {
            // 同一路的重复要更严：连着说两遍「好的」「谢谢」是真说了两遍，不能并。
            if (src.length >= 5 && rs.length >= 5) hit = ZKAlike(src, rs, 0.90, 6);
            if (!hit && dst.length >= 5 && rd.length >= 5) hit = ZKAlike(dst, rd, 0.90, 6);
        }
        if (!hit) continue;

        // 留哪一条：跨通道时优先留「原文正好是这条通道自己的语言」的那条。
        // 对方说英文时，b 通道直接出英文原文（真转录），a 通道（中文识别）也会
        // 吐一串中文——那是译文的回声，不该当成原文留在界面上。
        NSMutableDictionary *keep = r;
        NSMutableDictionary *drop = me;
        NSString *kside = r[@"side"] ?: @"a";
        NSString *dside = side;
        if (cross) {
            NSString *rlang = [kside isEqualToString:@"a"] ? _mine : _other;
            NSString *dlang = [dside isEqualToString:@"a"] ? _mine : _other;
            BOOL rNative = ZKScriptOfLang(ZKShort(rlang)) == ZKSriptOf(rs);
            BOOL dNative = ZKScriptOfLang(ZKShort(dlang)) == ZKSriptOf(src);
            BOOL takeMine = (dNative && !rNative);
            if (!dNative && !rNative) {
                takeMine = [me[@"at"] doubleValue] < [r[@"at"] doubleValue]; // 都不是本通道语言，留先上屏的
            }
            if (takeMine) {
                keep = me; drop = r;
                kside = side; dside = r[@"side"] ?: @"a";
            }
        }

        NSString *ks = keep[@"src"] ?: @"";
        NSString *kd = keep[@"dst"] ?: @"";
        NSString *dsrc = drop[@"src"] ?: @"";
        NSString *ddst = drop[@"dst"] ?: @"";

        // 对不上语言的译文是碎渣（中文那行底下挂个「name」），先剔掉
        if (kd.length && ![self destFits:kside dst:kd]) kd = @"";

        if (cross) {
            // 留下这一条缺的译文，往往就是被撤那条的原文；都不行就用它的译文
            if (!kd.length && [self destFits:kside dst:dsrc]) kd = dsrc;
            if (!kd.length && [self destFits:kside dst:ddst]) kd = ddst;
            if (!ks.length) ks = dsrc;
        } else {
            if (dsrc.length > ks.length && ZKSim(dsrc, ks) >= 0.8) ks = dsrc;
            if (ddst.length > kd.length && (!kd.length || ZKSim(ddst, kd) >= 0.6)) kd = ddst;
        }
        // 同一条记录被反复 updat 时,它的 at 也跟着走,不然 12 秒之后就不认账了
        keep[@"src"] = ks;
        keep[@"dst"] = kd;
        keep[@"at"] = @(now);
        if (drop != me) {
            me = keep;
            me[@"src"] = ks;
            me[@"dst"] = kd;
        }
        [self emit:keep[@"lid"] side:kside src:ks dst:kd kind:ZKLineKindFinal];
        if ([kside isEqualToString:@"a"]) { _emitSrcA = ks; _emitDstA = kd; }
        else                              { _emitSrcB = ks; _emitDstB = kd; }

        // 被撤掉的这条：界面上抹掉，它那份记录也清掉，免得迟到的译文又把它顶回来
        NSInteger dseg = [drop[@"seg"] integerValue];
        if (dseg > 0) {
            if ([dside isEqualToString:@"a"]) {
                [_segA removeObjectForKey:@(dseg)];
                // 号一律留别名：被撤那条的译文可能还在路上，迟到了也得挂回留下的这条，
                // 否则界面就是「撤掉一条之后，剩下那条永远只有原文」。
                _aliasA[@(dseg)] = @([keep[@"seg"] integerValue]);
            } else {
                [_segB removeObjectForKey:@(dseg)];
                _aliasB[@(dseg)] = @([keep[@"seg"] integerValue]);
            }
        }
        [_shown removeObject:drop];
        [self emit:drop[@"lid"] side:dside src:@"" dst:@"" kind:ZKLineKindDraft];
        return;
    }
}

- (void)emit:(NSString *)lid side:(NSString *)side src:(NSString *)src dst:(NSString *)dst kind:(NSInteger)kind {
    if (!_running) return;
    // 显示层裁掉句尾标点：内部存的还是带标点的原文（判断断句、去重、导出 SRT 都要用），
    // 只有推给界面的这一份去掉句尾那一个符号。
    NSString *s = ZKTrimEndPunct(src ?: @"");
    NSString *d = ZKTrimEndPunct(dst ?: @"");
    if (self.onLine) self.onLine(lid ?: @"", side ?: @"a", s, d, kind);
}

- (void)state:(NSString *)s {
    if (!_running) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.onState) self.onState(s);
    });
}

- (void)fail:(NSString *)why {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.onFail) self.onFail(why);
    });
}

#pragma mark - 长按说话

- (BOOL)isDropped {
    if (_dropUntil <= 0) return NO;
    return [NSDate date].timeIntervalSince1970 < _dropUntil;
}

/// 松手之后补一段静音。上游是按「静音多久」分句的：不给它这段静音，
/// 它不会认为这一句说完了，要等到下一次开口才把上一句吐出来——
/// 那就成了「松开手半天没反应」。
- (void)pushSilence:(NSTimeInterval)seconds {
    if (!_running) return;
    NSUInteger n = 1600;              // 100ms @ 16k
    float *z = calloc(n, sizeof(float));
    if (!z) return;
    NSInteger times = (NSInteger)ceil(MAX(0.1, seconds) / 0.1);
    for (NSInteger i = 0; i < times; i++) {
        [_toOther pushFloat32:z count:n];
        [_toMine pushFloat32:z count:n];
    }
    free(z);
}

- (void)beginUtterance {
    if (!_running) return;
    _dropUntil = 0;                    // 新的一句开始：刚才取消丢掉的那段时间结束
    _uttOn = YES;
    _uttAt = CFAbsoluteTimeGetCurrent();
}

- (void)endUtterance {
    if (!_uttOn) return;
    _uttOn = NO;
    _dropUntil = 0;
    // 补 1 秒静音：够上游把这一句切成整句、并把译文翻好
    [self pushSilence:1.0];
}

- (void)cancelUtterance {
    BOOL was = _uttOn;
    _uttOn = NO;
    if (!_running) return;
    // 先把已经送进去的那一段用静音收个尾（让上游别再等），再把接下来 2 秒的结果全丢掉
    if (was) [self pushSilence:0.6];
    _dropUntil = [NSDate date].timeIntervalSince1970 + 2.0;
}

#pragma mark - 麦克风

- (void)startMic {
    // 上一次的引擎没收干净就再装一次 tap，AVAudioEngine 会抛
    // 「required condition is false: nullptr == Tap()」直接把进程带走，
    // 所以进这里先把旧的拆了（没装过的话这一步什么也不做）。
    [self stopMic];
    _engine = [AVAudioEngine new];
    AVAudioInputNode *input = _engine.inputNode;
    // 回声消除单独开在麦克风这一环（上面把会话的模式换成了普通模式，
    // 不再靠 voiceChat 顺带做 AEC）。要在取格式、装 tap 之前开——
    // 开了之后输入采样率会变，格式必须重新取。开不起来也不致命：
    // 朗读那一侧还有文本回声过滤兜着。
    if (@available(iOS 13.0, *)) {
        NSError *vpErr = nil;
        if (![input setVoiceProcessingEnabled:YES error:&vpErr]) {
            NSLog(@"[interp] voice processing off: %@", vpErr);
        }
    }
    AVAudioFormat *inFmt = [input inputFormatForBus:0];
    if (inFmt.sampleRate < 8000) {
        [self fail:@"拿不到麦克风，检查一下权限"];
        return;
    }
    _inRate = inFmt.sampleRate;
    _outFmt = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32
                                               sampleRate:16000
                                                 channels:1
                                              interleaved:NO];
    _conv = [[AVAudioConverter alloc] initFromFormat:inFmt toFormat:_outFmt];

    __weak typeof(self) weakSelf = self;
    [input installTapOnBus:0 bufferSize:1024 format:inFmt block:^(AVAudioPCMBuffer *buf, AVAudioTime *when) {
        __strong typeof(weakSelf) s = weakSelf;
        if (!s || !s->_running || !buf.frameLength) return;
        // 长按说话：没按住就把这一帧丢掉——送进上游的只有按住那一段，
        // 环境音、旁边人说话、咳嗽都不会被认进来。
        if (s->_pushToTalk && !s->_uttOn) return;
        // 朗读期间不收麦：这几十毫秒里全是扬声器里念出来的译文
        double nowS = [[NSDate date] timeIntervalSince1970];
        if (nowS - s->_gateCheckedAt > 0.03) {
            s->_gateCheckedAt = nowS;
            double g = [[ZKStore setting:@"tts_gate"] doubleValue];
            if (!(g > nowS) || g > nowS + 6) g = 0;   // 写坏的值一律当没开
            s->_gateUntil = g;
            NSString *tl = [ZKStore setting:@"tts_lang"];
            s->_ttsLang = (tl.length && ![tl isEqualToString:@"0"]) ? tl : nil;
        }
        // 朗读期间以前是把麦克风整段丢掉（`return`）——那正是「一开音频输出就漏读、
        // 漏翻、字幕不翻」的根源：人家在你念的同时说的话，全被扔了。
        // 现在会话本来就是 voiceChat（系统自带回声消除），不再丢音频；
        // 只在每句开口的头 120ms 让一下，等回声消除收敛，之后的照收。
        if (s->_gateUntil > nowS) {
            if (s->_gateFrom <= 0 || s->_gateFrom > nowS) s->_gateFrom = nowS;
            if (nowS - s->_gateFrom < 0.12) return;
        } else {
            s->_gateFrom = 0;
        }

        NSUInteger cap = (NSUInteger)(buf.frameLength * 16000.0 / MAX(8000, s->_inRate)) + 64;
        AVAudioPCMBuffer *out = [[AVAudioPCMBuffer alloc] initWithPCMFormat:s->_outFmt frameCapacity:cap];
        __block BOOL fed = NO;
        NSError *err = nil;
        AVAudioConverterInputBlock ib = ^AVAudioBuffer *(AVAudioPacketCount need, AVAudioConverterInputStatus *st) {
            if (fed) { *st = AVAudioConverterInputStatus_NoDataNow; return nil; }
            fed = YES;
            *st = AVAudioConverterInputStatus_HaveData;
            return buf;
        };
        [s->_conv convertToBuffer:out error:&err withInputFromBlock:ib];
        if (err || !out.floatChannelData || out.frameLength == 0) return;

        const float *p = out.floatChannelData[0];
        // 以前这里念的时候会把「被自己的声音污染」的那一路整段停掉（念英文就停英
        // 文那一路）。那正是「一开音频输出就漏读、漏翻、字幕不翻」的另一半原因：
        // 人家在你念的同时接着说话，那一路根本没送到上游。
        // 现在麦克风那一环开了系统回声消除，朗读出来的声音会被抵消掉，
        // 两路因此都照收——宁可多几句要过滤的，也不漏一个字。
        (void)s->_ttsLang;
        [s->_toOther pushFloat32:p count:out.frameLength];
        [s->_toMine pushFloat32:p count:out.frameLength];
        [s reportLevel:p count:out.frameLength];
    }];

    NSError *e = nil;
    [_engine prepare];
    [_engine startAndReturnError:&e];
    if (e) {
        // 起不来就把 tap 和引擎一起拆掉，否则下次再点开始就撞上"tap 已存在"
        [self stopMic];
        [self fail:@"麦克风启动失败"];
    }
}

/// 输入电平，给界面做跳动指示。最多 15 次/秒，别把主线程刷爆
- (void)reportLevel:(const float *)p count:(NSUInteger)n {
    if (!self.onLevel || !n) return;
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    if (now - _lastLevelAt < 0.066) return;
    _lastLevelAt = now;

    double sum = 0;
    for (NSUInteger i = 0; i < n; i++) sum += (double)p[i] * p[i];
    float rms = sqrt(sum / (double)n);
    float db = 20.0f * log10f(rms + 1e-6f);       // 大约 -100 ~ 0
    float level = (db + 52.0f) / 46.0f;            // 映射到 0~1
    if (level < 0) level = 0;
    if (level > 1) level = 1;
    level = powf(level, 0.7f);                     // 小音量也看得见

    void (^cb)(float) = self.onLevel;
    dispatch_async(dispatch_get_main_queue(), ^{ if (cb) cb(level); });
}

- (void)stopMic {
    if (!_engine) return;
    @try { [_engine.inputNode removeTapOnBus:0]; } @catch (__unused NSException *ex) {}
    [_engine stop];
    _engine = nil;
    _conv = nil;
}

@end
