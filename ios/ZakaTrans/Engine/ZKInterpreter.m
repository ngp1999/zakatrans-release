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
    if ([add hasPrefix:old]) return add;
    if ([old hasPrefix:add]) return old;
    if (add.length >= old.length) return add;
    if ([old hasSuffix:add]) return old;
    return [old stringByAppendingString:add];
}

/// 去掉首尾空白、把连续空白压成一个空格，空行不要
static NSString *ZKClean(NSString *s) {
    if (!s.length) return @"";
    NSString *t = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    t = [t stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
    while ([t containsString:@"  "]) t = [t stringByReplacingOccurrencesOfString:@"  " withString:@" "];
    return t;
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
- (void)sourcePartial:(NSString *)side seg:(NSInteger)seg text:(NSString *)text;
- (void)sourceEnd:(NSString *)side seg:(NSInteger)seg text:(NSString *)text;
- (void)transPartial:(NSString *)side seg:(NSInteger)seg text:(NSString *)text;
- (void)transEnd:(NSString *)side seg:(NSInteger)seg text:(NSString *)text;
- (void)state:(NSString *)st;
- (void)fail:(NSString *)why;
- (void)stopMic;
- (BOOL)destFits:(NSString *)side dst:(NSString *)dst;
- (BOOL)isMirror:(NSString *)side src:(NSString *)src;
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
    // 每边「已经落定、还在等译文」的句子，按落定顺序排队。
    // 上游的译文回调只给文字、不说是哪一句的译文。以前用一个「当前句」槽位去接：
    // 连着说两句时，第一句的译文回来会盖到第二句头上，第一句就永远停在只有原文。
    // 现在按队列接，先落定的先等到译文，串不了。
    NSMutableArray<NSMutableDictionary *> *_waitA;
    NSMutableArray<NSMutableDictionary *> *_waitB;

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
    }
    return self;
}

- (BOOL)running { return _running; }

#pragma mark - 启停

- (void)startWith:(NSString *)a other:(NSString *)b {
    _mine = a.length ? a : @"zh-CN";
    _other = b.length ? b : @"en-US";
    if (_running) { [self setMine:_mine other:_other]; return; }

    // 音频会话：录 + 放，voiceChat 模式带来系统回声消除与自动增益
    NSError *err = nil;
    AVAudioSession *s = [AVAudioSession sharedInstance];
    [s setCategory:AVAudioSessionCategoryPlayAndRecord
              mode:AVAudioSessionModeVoiceChat
           options:AVAudioSessionCategoryOptionDefaultToSpeaker | AVAudioSessionCategoryOptionAllowBluetooth
             error:&err];
    // 缓冲给到最小：麦克风这一环少 20ms，字幕就早 20ms
    [s setPreferredIOBufferDuration:0.01 error:nil];
    [s setActive:YES error:&err];
    if (err) { [self fail:@"麦克风没有权限，请在系统设置里允许"]; return; }

    // 两条独立会话
    _toOther = [ZKDoubaoAST session];
    _toMine = [ZKDoubaoAST session];
    [self wire:_toOther side:@"a"];
    [self wire:_toMine side:@"b"];
    [self applyLangs];

    [self resetLines];
    _running = YES;
    [_toOther start];
    [_toMine start];

    [self startMic];
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
    _openSegA = _openSegB = 0;
    _localSegA = _localSegB = 0;
}

- (void)stop {
    _running = NO;
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
/// 认出来就是一句短碎的乱码（几个字母、一个语气词）。
/// 真人对话很少同时开口，所以：另一边刚说完 1 秒内的短句一律不收，长句照收。
- (BOOL)acceptSide:(NSString *)side length:(NSUInteger)n {
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    // 另一条通道对「不是它那种语言」的声音也会硬认，认出来就是两三个字的碎渣。
    // 以前把 6 个字以内的都挡掉，连正常的短句（「好」「OK」「谢谢」）一起挡了，
    // 结果那句话只剩译文、没有原文。现在只挡 3 个字以内的碎渣，窗口也收紧。
    if (_activeSide && ![_activeSide isEqualToString:side] && now < _activeUntil && n <= 3) {
        return NO;
    }
    if (n >= 3) { _activeSide = side; _activeUntil = now + 0.7; }
    return YES;
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
    NSString *t = ZKClean(text);
    if (!ZKHasContent(t)) return;
    if (![self belongs:side src:t]) return;
    if (![self acceptSide:side length:t.length]) return;

    NSInteger seg = [self segFor:side raw:segRaw ending:NO];
    NSMutableDictionary *e = [self entryFor:side seg:seg];
    // 边说边出的半句只存着，不上屏。
    // 同传这一档要的是「整句准」，不是「出字快」：半句先上屏，等整句落定时
    // 文字会整段变一次，肉眼看到的就是「字幕在跳着改」；更糟的是译文经常比原文整句先到，
    // 半句和译文对不齐，就会出现截图上那种「你好，/How are you?」的错行。
    // 所以这里只落库，等 sourceEnd 一次成行。
    e[@"src"] = t;
    e[@"at"] = @([NSDate date].timeIntervalSince1970);
}

- (void)sourceEnd:(NSString *)side seg:(NSInteger)segRaw text:(NSString *)text {
    if (!_running) return;
    NSString *t = ZKClean(text);
    if (!ZKHasContent(t)) return;
    if (![self belongs:side src:t]) return;
    if (![self acceptSide:side length:t.length]) return;
    if ([self isEcho:side src:t]) return;

    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    NSString *last = [side isEqualToString:@"a"] ? _lastSrcA : _lastSrcB;
    NSTimeInterval lastAt = [side isEqualToString:@"a"] ? _lastAtA : _lastAtB;
    // 同一句被上游重复推一遍：丢掉，但不撤销已经上屏的内容
    if (last.length && [last isEqualToString:t] && now - lastAt < 3.0) return;
    if ([side isEqualToString:@"a"]) { _lastSrcA = t; _lastAtA = now; } else { _lastSrcB = t; _lastAtB = now; }

    // 另一条通道刚刚吐过几乎同一句 → 这是同一路声音被"反向译"了一遍，丢掉
    if ([self isMirror:side src:t]) return;

    NSInteger seg = [self segFor:side raw:segRaw ending:YES];
    NSMutableDictionary *e = [self entryFor:side seg:seg];
    e[@"src"] = t;
    e[@"at"] = @(now);
    NSString *dst = e[@"dst"] ?: @"";
    [self emit:[self lineIdFor:side seg:seg] side:side src:t dst:dst kind:ZKLineKindFinal];

    if ([side isEqualToString:@"a"]) {
        _finSrcA = t; _finDstA = dst; _finAtA = now;
    } else {
        _finSrcB = t; _finDstB = dst; _finAtB = now;
    }
    [self sweepSegs];
}

- (void)transPartial:(NSString *)side seg:(NSInteger)segRaw text:(NSString *)text {
    if (!_running) return;
    NSString *t = ZKClean(text);
    if (!t.length) return;

    if (![self destFits:side dst:t]) return;

    NSInteger seg = [self segFor:side raw:segRaw ending:NO];
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
    NSString *t = ZKClean(text);
    if (!t.length) return;

    if (![self destFits:side dst:t]) return;

    NSInteger seg = [self segFor:side raw:segRaw ending:NO];
    NSMutableDictionary *e = [self entryFor:side seg:seg];
    e[@"dst"] = t;
    e[@"at"] = @([NSDate date].timeIntervalSince1970);
    NSString *src = e[@"src"] ?: @"";
    if ([side isEqualToString:@"a"]) { _finDstA = t; _finAtA = e[@"at"] ? [e[@"at"] doubleValue] : _finAtA; }
    else { _finDstB = t; _finAtB = e[@"at"] ? [e[@"at"] doubleValue] : _finAtB; }
    if (!src.length) return;
    [self emit:[self lineIdFor:side seg:seg] side:side src:src dst:t kind:ZKLineKindFinal];
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
    NSString *os = a ? _finSrcB : _finSrcA;
    NSString *od = a ? _finDstB : _finDstA;
    NSTimeInterval oat = a ? _finAtB : _finAtA;
    if (!os.length && !od.length) return NO;
    if ([NSDate date].timeIntervalSince1970 - oat > 3.0) return NO;
    double s1 = ZKSim(src, os), s2 = ZKSim(src, od);
    return MAX(s1, s2) >= 0.72;
}

- (void)emit:(NSString *)lid side:(NSString *)side src:(NSString *)src dst:(NSString *)dst kind:(NSInteger)kind {
    if (!_running) return;
    if (self.onLine) self.onLine(lid ?: @"", side ?: @"a", src ?: @"", dst ?: @"", kind);
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

#pragma mark - 麦克风

- (void)startMic {
    // 上一次的引擎没收干净就再装一次 tap，AVAudioEngine 会抛
    // 「required condition is false: nullptr == Tap()」直接把进程带走，
    // 所以进这里先把旧的拆了（没装过的话这一步什么也不做）。
    [self stopMic];
    _engine = [AVAudioEngine new];
    AVAudioInputNode *input = _engine.inputNode;
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
        // 朗读期间不收麦：这几十毫秒里全是扬声器里念出来的译文
        double nowS = [[NSDate date] timeIntervalSince1970];
        if (nowS - s->_gateCheckedAt > 0.03) {
            s->_gateCheckedAt = nowS;
            double g = [[ZKStore setting:@"tts_gate"] doubleValue];
            if (!(g > nowS) || g > nowS + 6) g = 0;   // 写坏的值一律当没开
            s->_gateUntil = g;
        }
        if (s->_gateUntil > nowS) return;

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
        // 两路同时喂：谁说话由文字体系判定
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
