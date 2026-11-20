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
    // 原文还在滚的时候先攒着，等落定了再把 id 定下来
    NSString *_draftSrcA, *_draftSrcB;
    // 滚动中的那条气泡用的 id。
    // 以前 draft 固定叫 draft-a / draft-b，落定时又换一个新 id 推 Final，
    // 结果那条 draft 气泡永远留在最上面、只显示最后一个词——就是用户看到的「第一行老是最后一个词」。
    // 现在 draft 和 Final 共用同一个 id，落定时原地变成正式气泡。
    NSString *_draftIdA, *_draftIdB;
    NSString *_draftDstA, *_draftDstB;
    // 译文先于原文到达时暂存
    NSString *_earlyDstA, *_earlyDstB;

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
    _draftIdA = _draftIdB = nil;
    _idA = _idB = nil;
    _srcA = _srcB = nil;
    _dstA = _dstB = nil;
    _draftSrcA = _draftSrcB = nil;
    _draftDstA = _draftDstB = nil;
    _earlyDstA = _earlyDstB = nil;
    _lastSrcA = _lastSrcB = nil;
    _lastAtA = _lastAtB = 0;
    _activeSide = nil;
    _activeUntil = 0;
    [_waitA removeAllObjects];
    [_waitB removeAllObjects];
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

    ast.onSourcePartial = ^(NSString *delta) {
        __strong typeof(weakSelf) s = weakSelf;
        if (!s) return;
        [s sourcePartial:side text:delta];
    };
    ast.onSourceEnd = ^(NSString *full) {
        __strong typeof(weakSelf) s = weakSelf;
        if (!s) return;
        [s sourceEnd:side text:full];
    };
    ast.onTransPartial = ^(NSString *delta) {
        __strong typeof(weakSelf) s = weakSelf;
        if (!s) return;
        [s transPartial:side text:delta];
    };
    ast.onTransEnd = ^(NSString *full) {
        __strong typeof(weakSelf) s = weakSelf;
        if (!s) return;
        [s transEnd:side text:full];
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
    if (_activeSide && ![_activeSide isEqualToString:side] && now < _activeUntil && n <= 6) {
        return NO;
    }
    if (n >= 3) { _activeSide = side; _activeUntil = now + 1.0; }
    return YES;
}

/// 这一边当前正在滚的那条气泡 id；没有就建一条
- (NSString *)draftIdFor:(NSString *)side create:(BOOL)create {
    BOOL a = [side isEqualToString:@"a"];
    NSString *cur = a ? _draftIdA : _draftIdB;
    if (!cur.length && create) {
        cur = [NSString stringWithFormat:@"%@-%ld", side, (long)++_seq];
        if (a) _draftIdA = cur; else _draftIdB = cur;
    }
    return cur;
}

/// 这句最终没能落定（重复、回声、纯噪声）：把那条滚动中的气泡撤掉，
/// 否则界面最上面会一直挂着半句没头没尾的字。
- (void)dropDraft:(NSString *)side {
    BOOL a = [side isEqualToString:@"a"];
    NSString *cur = a ? _draftIdA : _draftIdB;
    if (!cur.length) return;
    if (a) _draftIdA = nil; else _draftIdB = nil;
    if (a) { _draftSrcA = nil; _draftDstA = nil; } else { _draftSrcB = nil; _draftDstB = nil; }
    [self emit:cur side:side src:@"" dst:@"" kind:ZKLineKindDraft];
}

- (void)sourcePartial:(NSString *)side text:(NSString *)text {
    if (!_running) return;
    NSString *t = ZKClean(text);
    if (!ZKHasContent(t)) return;
    if (![self belongs:side src:t]) return;
    if (![self acceptSide:side length:t.length]) return;

    BOOL a = [side isEqualToString:@"a"];
    NSString *dst = a ? _draftDstA : _draftDstB;
    if (a) _draftSrcA = t; else _draftSrcB = t;
    [self emit:[self draftIdFor:side create:YES] side:side src:t dst:dst kind:ZKLineKindDraft];
}

- (void)sourceEnd:(NSString *)side text:(NSString *)text {
    if (!_running) return;
    NSString *t = ZKClean(text);
    // 纯标点、空串——直接丢，顺手把自己那条草稿气泡撤掉
    if (!ZKHasContent(t)) { [self dropDraft:side]; return; }
    if (![self belongs:side src:t]) { [self dropDraft:side]; return; }
    if (![self acceptSide:side length:t.length]) { [self dropDraft:side]; return; }
    if ([self isEcho:side src:t]) { [self dropDraft:side]; return; }

    BOOL a = [side isEqualToString:@"a"];
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    NSString *last = a ? _lastSrcA : _lastSrcB;
    NSTimeInterval lastAt = a ? _lastAtA : _lastAtB;

    // 同一句被上游重复推一遍
    if (last.length && [last isEqualToString:t] && now - lastAt < 3.0) {
        [self dropDraft:side];
        return;
    }
    if (a) { _lastSrcA = t; _lastAtA = now; } else { _lastSrcB = t; _lastAtB = now; }

    // 这一句的 id：滚动中的草稿已经在用，就沿用它——气泡原地落定，不再多出一条
    NSString *lid = [self draftIdFor:side create:YES];
    NSString *early = a ? _earlyDstA : _earlyDstB;
    if (a) {
        _idA = lid; _srcA = t; _dstA = early ?: @"";
        _draftIdA = nil; _draftSrcA = nil; _draftDstA = nil; _earlyDstA = nil;
    } else {
        _idB = lid; _srcB = t; _dstB = early ?: @"";
        _draftIdB = nil; _draftSrcB = nil; _draftDstB = nil; _earlyDstB = nil;
    }
    // 挂进等待队列：译文晚到也能认回这一句
    NSMutableArray *q = a ? _waitA : _waitB;
    if (!early.length) {
        [q addObject:[@{@"id": lid, @"src": t, @"at": @(now)} mutableCopy]];
    }
    // 太久没等到译文的先摘掉，别让它一直占着队首、把后面每句的译文都接错
    while (q.count) {
        NSMutableDictionary *head = q.firstObject;
        double at = [head[@"at"] doubleValue];
        if (now - at < 12.0) break;
        [q removeObjectAtIndex:0];
    }
    [self emit:lid side:side src:t dst:(early ?: @"") kind:ZKLineKindFinal];
}

- (void)transPartial:(NSString *)side text:(NSString *)text {
    if (!_running) return;
    NSString *t = ZKClean(text);
    if (!t.length) return;

    BOOL a = [side isEqualToString:@"a"];
    NSMutableArray *q = a ? _waitA : _waitB;
    NSMutableDictionary *cur = q.lastObject;

    if (cur) {
        // 这句已经落定，译文原地补进去：滚动中的那条气泡直接变成正式气泡
        NSString *merged = ZKMergeTrans(cur[@"dst"] ?: @"", t);
        cur[@"dst"] = merged;
        if (a) _dstA = merged; else _dstB = merged;
        [self emit:cur[@"id"] side:side src:(cur[@"src"] ?: @"") dst:merged kind:ZKLineKindUpdate];
    } else {
        // 译文比原文先到：先攒着，等原文落定一起发
        if (a) { _earlyDstA = t; _draftDstA = t; } else { _earlyDstB = t; _draftDstB = t; }
        NSString *draftSrc = a ? _draftSrcA : _draftSrcB;
        if (draftSrc.length) {
            [self emit:[self draftIdFor:side create:YES] side:side src:draftSrc dst:t kind:ZKLineKindDraft];
        }
    }
}

- (void)transEnd:(NSString *)side text:(NSString *)text {
    if (!_running) return;
    NSString *t = ZKClean(text);
    if (!t.length) return;

    BOOL a = [side isEqualToString:@"a"];
    NSMutableArray *q = a ? _waitA : _waitB;

    // 认领顺序：先给最早那条还没等到译文的句子；都等到了就落到最新一条
    NSMutableDictionary *target = nil;
    for (NSMutableDictionary *it in q) {
        id d = it[@"dst"];
        if (![d isKindOfClass:[NSString class]] || ![d length]) { target = it; break; }
    }
    if (!target) target = q.lastObject;

    if (!target) {
        // 这句连原文都还没落定：先攒着，等原文落定再一起发
        if (a) _earlyDstA = t; else _earlyDstB = t;
        return;
    }

    target[@"dst"] = t;
    if (a) _dstA = t; else _dstB = t;
    // 收尾再推一次 Final，界面把它当成这句的最终状态
    [self emit:target[@"id"] side:side src:(target[@"src"] ?: @"") dst:t kind:ZKLineKindFinal];
    [q removeObject:target];

    // 这一边没有待接的句子了，才清「当前句」槽位；
    // 还有排队没等到译文的，槽位要留着，不然下一条译文无处可去。
    if (!q.count) {
        if (a) { _idA = nil; _srcA = nil; _dstA = nil; }
        else   { _idB = nil; _srcB = nil; _dstB = nil; }
    }
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
        if (nowS - s->_gateCheckedAt > 0.3) {
            s->_gateCheckedAt = nowS;
            double g = [[ZKStore setting:@"tts_gate"] doubleValue];
            if (!(g > nowS) || g > nowS + 5) g = 0;   // 写坏的值一律当没开
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
