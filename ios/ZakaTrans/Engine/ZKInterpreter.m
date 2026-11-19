#import "ZKInterpreter.h"
#import "DoubaoAST.h"
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
    // 每条通道最近一句原文 + 译文，整句到达时成对推出
    NSString *_pendSrcA, *_pendDstA, *_pendSrcB, *_pendDstB;
    // 已经推过整句的原文，防止同一条增量又拼一遍
    NSString *_lastFinalA, *_lastFinalB;
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
    [s setActive:YES error:&err];
    if (err) { [self fail:@"麦克风没有权限，请在系统设置里允许"]; return; }

    // 两条独立会话
    _toOther = [ZKDoubaoAST session];
    _toMine = [ZKDoubaoAST session];
    [self wire:_toOther side:@"a"];
    [self wire:_toMine side:@"b"];
    [self applyLangs];

    _running = YES;
    [self state:@"启动中"];
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

- (void)stop {
    _running = NO;
    [self stopMic];
    [_toOther stop]; _toOther = nil;
    [_toMine stop];  _toMine = nil;
    _pendSrcA = _pendDstA = _pendSrcB = _pendDstB = nil;
    _lastFinalA = _lastFinalB = nil;
    [self state:@"已停止"];
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
        [s partial:side source:delta];
    };
    ast.onSourceEnd = ^(NSString *full) {
        __strong typeof(weakSelf) s = weakSelf;
        if (!s) return;
        if (side == nil) return;
        if ([side isEqualToString:@"a"]) s->_pendSrcA = full;
        else s->_pendSrcB = full;
        [s emitIfReady:side final:NO];
    };
    ast.onTransPartial = ^(NSString *delta) {
        __strong typeof(weakSelf) s = weakSelf;
        if (!s) return;
        [s partial:side trans:delta];
    };
    ast.onTransEnd = ^(NSString *full) {
        __strong typeof(weakSelf) s = weakSelf;
        if (!s) return;
        if ([side isEqualToString:@"a"]) s->_pendDstA = full;
        else s->_pendDstB = full;
        [s emitIfReady:side final:YES];
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

- (void)partial:(NSString *)side source:(NSString *)text {
    if (!_running) return;
    if (![self belongs:side src:text]) return;
    if (self.onLine) {
        NSString *line = [NSString stringWithFormat:@"%@", text ?: @""];
        self.onLine(side, line, @"", NO);
    }
}

- (void)partial:(NSString *)side trans:(NSString *)text {
    if (!_running) return;
    NSString *src = [side isEqualToString:@"a"] ? _pendSrcA : _pendSrcB;
    if (src.length && ![self belongs:side src:src]) return;
    if (src.length == 0) {
        // 还没拿到原文：先按通道默认归属
        if (![side isEqualToString:@"a"]) return;
    }
    if (self.onLine) self.onLine(side, @"", text ?: @"", NO);
}

- (void)emitIfReady:(NSString *)side final:(BOOL)final {
    NSString *src = [side isEqualToString:@"a"] ? (_pendSrcA ?: _pendSrcB) : _pendSrcB;
    if (!src.length) return;
    if (![self belongs:side src:src]) return;

    NSString *dst = [side isEqualToString:@"a"] ? _pendDstA : _pendDstB;
    if (!final) return;

    NSString *last = [side isEqualToString:@"a"] ? _lastFinalA : _lastFinalB;
    if (last.length && [last isEqualToString:src]) {
        // 同一条原文重复推送：清掉待发，不再发一遍
        if ([side isEqualToString:@"a"]) { _pendSrcA = nil; _pendDstA = nil; }
        else { _pendSrcB = nil; _pendDstB = nil; }
        return;
    }
    if ([side isEqualToString:@"a"]) { _lastFinalA = src; _pendSrcA = nil; _pendDstA = nil; }
    else { _lastFinalB = src; _pendSrcB = nil; _pendDstB = nil; }

    if (self.onLine) self.onLine(side, src, dst ?: @"", YES);
}

- (void)state:(NSString *)s {
    if (!_running && ![s isEqualToString:@"已停止"]) return;
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
        [s->_toOther pushFloat32:p count:out.frameLength];
        [s->_toMine pushFloat32:p count:out.frameLength];
    }];

    NSError *e = nil;
    [_engine prepare];
    [_engine startAndReturnError:&e];
    if (e) [self fail:@"麦克风启动失败"];
}

- (void)stopMic {
    if (!_engine) return;
    @try { [_engine.inputNode removeTapOnBus:0]; } @catch (__unused NSException *ex) {}
    [_engine stop];
    _engine = nil;
    _conv = nil;
}

@end
