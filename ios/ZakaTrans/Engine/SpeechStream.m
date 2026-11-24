#import "SpeechStream.h"
#import "Shared.h"
#import "DoubaoAST.h"
#import <AVFoundation/AVFoundation.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <netinet/tcp.h>
#import <unistd.h>
#import <math.h>

#define ZK_PORT 39391
#define ZK_RATE 16000.0
#define ZK_HDR  9          // len(4) + type(1) + seq(4)

// 这一层只做两件事：
//   ① 把录屏扩展推过来的音频收进来（TCP 主通道 + 共享文件兜底）
//   ② 原样转交给豆包同传，把模型吐出来的原文/译文往上抛
//
// 识别和翻译都不在这里做了 —— 豆包同传一条流同时出原文和译文，
// 所以没有本地识别器、没有腾讯云 ASR、没有 DeepSeek 翻译，
// 也就不存在"每句重建识别任务"那段空窗。

static BOOL recvFull(int fd, void *buf, size_t n) {
    size_t got = 0;
    while (got < n) {
        ssize_t r = recv(fd, (char *)buf + got, n - got, 0);
        if (r <= 0) return NO;
        got += (size_t)r;
    }
    return YES;
}

@implementation ZKSpeechStream {
    int _listenFd;
    int _connFd;
    volatile BOOL _running;

    BOOL _firstAudioLogged;

    // 音频完整性
    unsigned long long _fedFrames;
    unsigned long long _lostFrames;
    unsigned long long _dupFrames;
    BOOL _seqInit;

    NSUInteger _pcmBytes;
    NSInteger _packets;
    NSInteger _chunksOut;
    NSString *_asrState;

    BOOL _fileMode;
    unsigned long long _fileOffset;
    NSTimer *_pollTimer;

    AVAudioEngine *_engine;
    AVAudioPlayerNode *_player;

    // 收音模式为「麦克风收音」时，这一套负责把手机麦克风的声音送进同一条通道
    AVAudioEngine *_micEngine;
    AVAudioConverter *_micConv;
    AVAudioFormat *_micOutFmt;
    double _micInRate;
    double _micGateChecked;

    NSString *_backendSig;
    NSString *_localeCode;

    // 当前这一段（一句）的原文/译文累计，用来给 root 做兜底
    NSString *_curSrc;
    NSString *_curTr;

    // 双向（同声传译）：
    //   一路 = 单例会话（原文 → 用户设的目标语言，同传页是中文）
    //   另一路 = _astB（原文 → 英文，用户自己说中文时给对方看）
    // 两条各自维护「还没落定的这一句」和「已经上屏的这句原文」，
    // 因为两条会话的段号是各自独立编号的，混在一起会串。
    BOOL _duplex;
    ZKDoubaoAST *_astB;
    NSMutableArray *_pairA;
    NSMutableArray *_pairB;
    NSMutableDictionary *_sentA;
    NSMutableDictionary *_sentB;
}

+ (instancetype)shared {
    static ZKSpeechStream *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [ZKSpeechStream new]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _listenFd = -1;
        _connFd = -1;
        _asrState = @"待启动";
        _curSrc = @"";
        _curTr = @"";
    }
    return self;
}

#pragma mark - 生命周期

- (void)start {
    if (_running) return;
    _running = YES;
    _pcmBytes = 0;
    _packets = 0;
    _chunksOut = 0;
    _asrState = @"启动中";
    _fileOffset = 0;
    // 上一场如果 App 被划掉、录屏扩展还在跑，会把音频继续写进共享文件。
    // 新的一场开始时先清掉，绝不能让旧音频在这一场里补传给上游——那会凭空多扣钱。
    [ZKStore resetPCM];
    _fileMode = NO;
    _fedFrames = 0;
    _lostFrames = 0;
    _dupFrames = 0;
    _seqInit = NO;
    _firstAudioLogged = NO;
    _curSrc = @"";
    _curTr = @"";
    [ZKStore log:@"speech: start v18 (doubao ast) dir=%@", [ZKStore dir]];

    ZKCrumb("speech.server");
    @try { [self startServer]; } @catch (NSException *e) { [ZKStore log:@"server ex %@", e.reason]; }

    // 上次崩在这条路上时不再碰音频保活，先把画中画跑起来
    BOOL safe = [[ZKStore setting:@"safemode"] isEqualToString:@"1"];
    if (safe) {
        [ZKStore log:@"speech: 安全模式，跳过音频保活"];
    } else {
        ZKCrumb("speech.keeper");
        @try { [self startKeeper]; } @catch (NSException *e) { [ZKStore log:@"keeper ex %@", e.reason]; }
    }

    ZKCrumb("speech.ast");
    [self wireAst];

    ZKDoubaoAST *ast = [ZKDoubaoAST shared];
    if ([ast configured]) {
        [ast start];
        _asrState = @"连接同传中";
    } else {
        _asrState = @"未填火山凭据";
        [ZKStore log:@"speech: 没填火山凭据，同传不会启动"];
        if (self.onDiag) self.onDiag([self diag]);
    }

    if (_duplex) [self startDuplexSession];

    ZKCrumb("speech.source");
    @try { [self applyAudioSource]; } @catch (NSException *e) { [ZKStore log:@"source ex %@", e.reason]; }

    if (!_pollTimer) {
        _pollTimer = [NSTimer scheduledTimerWithTimeInterval:0.4
                                                     target:self
                                                   selector:@selector(pollFile)
                                                   userInfo:nil
                                                    repeats:YES];
    }
}

- (void)stop {
    _running = NO;
    @try { [self stopMicFeed]; } @catch (__unused NSException *e) {}
    @try { [[ZKDoubaoAST shared] stop]; } @catch (__unused NSException *e) {}
    @try { [_astB stop]; } @catch (__unused NSException *e) {}
    [_pairA removeAllObjects];
    [_pairB removeAllObjects];
    [_sentA removeAllObjects];
    [_sentB removeAllObjects];
    if (_listenFd >= 0) { close(_listenFd); _listenFd = -1; }
    if (_connFd >= 0) { close(_connFd); _connFd = -1; }
    [_pollTimer invalidate];
    _pollTimer = nil;
    @try {
        if (_player) [_player stop];
        if (_engine && _engine.isRunning) [_engine stop];
    } @catch (__unused NSException *e) {}
    _engine = nil;
    _player = nil;
    _asrState = @"已停止";
}

// 语种 / 凭据改了：重建一次同传会话（豆包的语种在会话里固定，中途换不了）
- (void)reloadLocale {
    NSString *code = [ZKStore setting:@"asrlang"] ?: @"auto";
    NSString *dst = [ZKStore setting:@"dstlang"] ?: @"zh";
    NSString *sig = [NSString stringWithFormat:@"%@|%@|%@|%@",
                     code, dst,
                     [ZKStore setting:@"volcappid"] ?: @"",
                     [ZKStore setting:@"volctoken"] ?: @""];
    if (_backendSig && [_backendSig isEqualToString:sig]) return;
    _backendSig = sig;
    _localeCode = code;

    [ZKStore log:@"speech: 语种/凭据变化 → 重建同传会话"];
    ZKDoubaoAST *ast = [ZKDoubaoAST shared];
    @try {
        [ast stop];
        if (_running) [ast start];
    } @catch (__unused NSException *e) {}
    if (_duplex) [self startDuplexSession];
}

- (void)wireAst {
    __weak typeof(self) weakSelf = self;
    ZKDoubaoAST *ast = [ZKDoubaoAST shared];

    ast.onSourcePartial = ^(NSString *delta, NSInteger seg) {
        ZKSpeechStream *s = weakSelf;
        if (!s || !s->_running) return;
        if (s->_duplex) {
            [s duplexSrcDelta:delta seg:seg list:s->_pairA sent:s->_sentA toChinese:YES];
            return;
        }
        if (!s->_curSrc.length) s->_curSrc = @"";
        s->_curSrc = [s->_curSrc stringByAppendingString:delta ?: @""];
        // root 那边用 (stable, unstable) 两个口子：这里原文本身就是增量，
        // 全部当"还在滚动的尾巴"传，让 root 按增量拼接自己管稳定前缀。
        if (s.onPartial) s.onPartial(@"", delta);
    };

    ast.onSourceEnd = ^(NSString *full, NSInteger seg) {
        ZKSpeechStream *s = weakSelf;
        if (!s || !s->_running) return;
        if (s->_duplex) {
            s->_curSrc = @"";
            [s duplexSrcEnd:full seg:seg list:s->_pairA sent:s->_sentA toChinese:YES];
            return;
        }
        NSString *t = full.length ? full : s->_curSrc;
        s->_curSrc = @"";
        t = [t stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (!t.length) return;
        if (s.onSegment) s.onSegment(t, YES);
    };

    ast.onTransPartial = ^(NSString *delta, NSInteger seg) {
        ZKSpeechStream *s = weakSelf;
        if (!s || !s->_running) return;
        if (s->_duplex) {
            [s duplexTrDelta:delta seg:seg list:s->_pairA sent:s->_sentA toChinese:YES];
            return;
        }
        if (!s->_curTr.length) s->_curTr = @"";
        s->_curTr = [s->_curTr stringByAppendingString:delta ?: @""];
        if (s.onTransPartial) s.onTransPartial(delta);
    };

    ast.onTransEnd = ^(NSString *full, NSInteger seg) {
        ZKSpeechStream *s = weakSelf;
        if (!s || !s->_running) return;
        if (s->_duplex) {
            s->_curTr = @"";
            [s duplexTrEnd:full seg:seg list:s->_pairA sent:s->_sentA toChinese:YES];
            return;
        }
        NSString *t = full.length ? full : s->_curTr;
        s->_curTr = @"";
        t = [t stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (!t.length) return;
        if (s.onTransSegment) s.onTransSegment(t);
    };

    // 半句译文被服务端整句重翻了一遍：当成一条正常的整句译文收下。
    // 界面上那一行还没译文就被补上，已经有译文就不动（不会冒出第二段字）。
    ast.onTransReplace = ^(NSString *full, NSInteger seg) {
        ZKSpeechStream *s = weakSelf;
        if (!s || !s->_running) return;
        if (s->_duplex) {
            s->_curTr = @"";
            [s duplexTrEnd:full seg:seg list:s->_pairA sent:s->_sentA toChinese:YES];
            return;
        }
        NSString *t = full.length ? full : s->_curTr;
        s->_curTr = @"";
        t = [t stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (!t.length) return;
        if (s.onTransSegment) s.onTransSegment(t);
    };

    ast.onState = ^(NSString *state) {
        ZKSpeechStream *s = weakSelf;
        if (!s) return;
        s->_asrState = state;
        if (s.onDiag) s.onDiag([s diag]);
    };

    ast.onFail = ^(NSString *why) {
        ZKSpeechStream *s = weakSelf;
        if (!s) return;
        [ZKStore log:@"ast fail: %@", why];
        s->_asrState = why.length ? why : @"连接失败";
        if (s.onDiag) s.onDiag([s diag]);
    };
}

#pragma mark - 双向（同声传译）

/// 这句原话到底是不是中文：汉字占压倒多数才算。
/// 不能只看「有没有汉字」——「我用 iPhone 拍的」有 5 个汉字 6 个字母，那是中文；
/// 「OK，我明白了」只有 4 个汉字，也算中文。反过来纯英文一句一个汉字都没有。
- (BOOL)duplexIsChinese:(NSString *)s {
    if (!s.length) return NO;
    NSUInteger han = 0, latin = 0;
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        if (c >= 0x3400 && c <= 0x9FFF) han++;
        else if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')) latin++;
    }
    if (!han) return NO;
    return han * 2 >= latin;
}

- (NSString *)duplexTrim:(NSString *)s {
    if (![s isKindOfClass:[NSString class]]) return @"";
    return [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

/// 这一路该不该上屏：toChinese=YES 的那路只管外语原话，=NO 的那路只管中文原话。
- (BOOL)duplexWanted:(NSString *)src toChinese:(BOOL)toChinese {
    if (!src.length) return NO;
    BOOL zh = [self duplexIsChinese:src];
    return toChinese ? !zh : zh;
}

- (NSMutableDictionary *)duplexPair:(NSMutableArray *)list seg:(NSInteger)seg {
    for (NSMutableDictionary *p in list) {
        if ([p[@"seg"] integerValue] == seg) return p;
    }
    NSMutableDictionary *p = [NSMutableDictionary dictionary];
    p[@"seg"] = @(seg);
    p[@"src"] = [NSMutableString string];
    p[@"tr"] = [NSMutableString string];
    [list addObject:p];
    while (list.count > 12) [list removeObjectAtIndex:0];
    return p;
}

- (void)duplexSrcDelta:(NSString *)delta seg:(NSInteger)seg
                  list:(NSMutableArray *)list sent:(NSMutableDictionary *)sent
             toChinese:(BOOL)toChinese {
    if (!delta.length) return;
    if (sent[@(seg)]) return;                    // 这句已经上过屏了
    NSMutableDictionary *p = [self duplexPair:list seg:seg];
    [(NSMutableString *)p[@"src"] appendString:delta];
    NSString *src = [self duplexTrim:p[@"src"]];
    if ([self duplexWanted:src toChinese:toChinese] && self.onDuplexLive) {
        self.onDuplexLive(src, [self duplexTrim:p[@"tr"]]);
    }
}

- (void)duplexSrcEnd:(NSString *)full seg:(NSInteger)seg
                list:(NSMutableArray *)list sent:(NSMutableDictionary *)sent
           toChinese:(BOOL)toChinese {
    NSString *src = [self duplexTrim:full];
    NSMutableDictionary *p = [self duplexPair:list seg:seg];
    NSString *tr = [self duplexTrim:p[@"tr"]];
    [list removeObject:p];
    if (!src.length) return;
    if (sent[@(seg)]) return;
    if (![self duplexWanted:src toChinese:toChinese]) return;
    // 同一句被服务端重发一次：屏上不能多冒一行出来
    if ([sent.allValues containsObject:src]) return;
    sent[@(seg)] = src;
    if (sent.count > 24) [sent removeAllObjects];
    if (self.onDuplexLine) self.onDuplexLine(src, tr);
    if (self.onDuplexLive) self.onDuplexLive(@"", @"");
}

- (void)duplexTrDelta:(NSString *)delta seg:(NSInteger)seg
                 list:(NSMutableArray *)list sent:(NSMutableDictionary *)sent
            toChinese:(BOOL)toChinese {
    if (!delta.length) return;
    NSMutableDictionary *p = [self duplexPair:list seg:seg];
    [(NSMutableString *)p[@"tr"] appendString:delta];
    NSString *src = [self duplexTrim:p[@"src"]];
    if ([self duplexWanted:src toChinese:toChinese] && self.onDuplexLive) {
        self.onDuplexLive(src, [self duplexTrim:p[@"tr"]]);
    }
}

- (void)duplexTrEnd:(NSString *)full seg:(NSInteger)seg
               list:(NSMutableArray *)list sent:(NSMutableDictionary *)sent
          toChinese:(BOOL)toChinese {
    NSString *tr = [self duplexTrim:full];
    if (!tr.length) return;
    NSMutableDictionary *p = [self duplexPair:list seg:seg];
    p[@"tr"] = [tr mutableCopy];
    NSString *src = [self duplexTrim:p[@"src"]];
    if (![self duplexWanted:src toChinese:toChinese]) return;
    NSString *shown = sent[@(seg)];
    if (shown.length) {
        // 原文已经先上屏了：把译文补到那一行，而不是再冒一行
        if (self.onDuplexZh) self.onDuplexZh(tr, shown);
        [sent removeObjectForKey:@(seg)];
    } else if (self.onDuplexLive) {
        self.onDuplexLive(src, tr);
    }
}

/// 第二路（中文 → 英文）的回调。段号跟第一路各编各的，所以另存一套。
- (void)wireDuplexAst:(ZKDoubaoAST *)ast list:(NSMutableArray *)list
                 sent:(NSMutableDictionary *)sent toChinese:(BOOL)toChinese {
    __weak typeof(self) weakSelf = self;
    ast.onSourcePartial = ^(NSString *delta, NSInteger seg) {
        ZKSpeechStream *s = weakSelf;
        if (!s || !s->_running || !s->_duplex) return;
        [s duplexSrcDelta:delta seg:seg list:list sent:sent toChinese:toChinese];
    };
    ast.onSourceEnd = ^(NSString *full, NSInteger seg) {
        ZKSpeechStream *s = weakSelf;
        if (!s || !s->_running || !s->_duplex) return;
        [s duplexSrcEnd:full seg:seg list:list sent:sent toChinese:toChinese];
    };
    ast.onTransPartial = ^(NSString *delta, NSInteger seg) {
        ZKSpeechStream *s = weakSelf;
        if (!s || !s->_running || !s->_duplex) return;
        [s duplexTrDelta:delta seg:seg list:list sent:sent toChinese:toChinese];
    };
    ast.onTransEnd = ^(NSString *full, NSInteger seg) {
        ZKSpeechStream *s = weakSelf;
        if (!s || !s->_running || !s->_duplex) return;
        [s duplexTrEnd:full seg:seg list:list sent:sent toChinese:toChinese];
    };
    ast.onTransReplace = ^(NSString *full, NSInteger seg) {
        ZKSpeechStream *s = weakSelf;
        if (!s || !s->_running || !s->_duplex) return;
        [s duplexTrEnd:full seg:seg list:list sent:sent toChinese:toChinese];
    };
    ast.onState = ^(NSString *state) {
        ZKSpeechStream *s = weakSelf;
        if (!s) return;
        [ZKStore log:@"duplex(b): %@", state];
        if (s.onDiag) s.onDiag([s diag]);
    };
    ast.onFail = ^(NSString *why) {
        ZKSpeechStream *s = weakSelf;
        if (!s) return;
        [ZKStore log:@"duplex(b) fail: %@", why];
        if (s.onDiag) s.onDiag([s diag]);
    };
}

/// 起（或重建）双向的第二路。语种在会话建立时固定，所以换语种要重建。
- (void)startDuplexSession {
    if (!_pairA) _pairA = [NSMutableArray array];
    if (!_pairB) _pairB = [NSMutableArray array];
    if (!_sentA) _sentA = [NSMutableDictionary dictionary];
    if (!_sentB) _sentB = [NSMutableDictionary dictionary];
    ZKDoubaoAST *b = _astB;
    if (!b) {
        b = [ZKDoubaoAST session];
        _astB = b;
        b.srcLang = @"auto";
        b.dstLang = @"en";
        b.mode = @"interp";
        [self wireDuplexAst:b list:_pairB sent:_sentB toChinese:NO];
    }
    if (!_running) return;
    @try {
        [b stop];
        [b start];
    } @catch (__unused NSException *e) {}
}

- (void)setDuplex:(BOOL)on {
    if (_duplex == on) return;
    _duplex = on;
    if (!_pairA) _pairA = [NSMutableArray array];
    if (!_pairB) _pairB = [NSMutableArray array];
    if (!_sentA) _sentA = [NSMutableDictionary dictionary];
    if (!_sentB) _sentB = [NSMutableDictionary dictionary];
    [_pairA removeAllObjects];
    [_pairB removeAllObjects];
    [_sentA removeAllObjects];
    [_sentB removeAllObjects];
    _curSrc = @"";
    _curTr = @"";
    if (on) {
        [self startDuplexSession];
    } else {
        ZKDoubaoAST *b = _astB;
        _astB = nil;
        @try { [b stop]; } @catch (__unused NSException *e) {}
        if (self.onDuplexLive) self.onDuplexLive(@"", @"");
    }
    [ZKStore log:@"speech: 双向 %@", on ? @"开" : @"关"];
}

- (BOOL)duplex { return _duplex; }

#pragma mark - TCP 服务端

- (void)startServer {
    int s = socket(AF_INET, SOCK_STREAM, 0);
    if (s < 0) { _asrState = @"监听失败"; return; }
    int one = 1;
    setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    struct sockaddr_in a;
    memset(&a, 0, sizeof(a));
    a.sin_family = AF_INET;
    a.sin_port = htons(ZK_PORT);
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    // 端口被上一场没退干净的进程占着时，重试几次；一直失败才放弃。
    // 监听起不来，扩展就只能走文件备份通道，表现就是「有字幕但很慢 / 干脆不出字」。
    int tries = 0;
    while (bind(s, (struct sockaddr *)&a, sizeof(a)) != 0) {
        tries++;
        [ZKStore log:@"speech: bind failed (第 %d 次)", tries];
        if (tries >= 5) {
            close(s);
            _asrState = @"端口被占用";
            if (self.onDiag) self.onDiag([self diag]);
            return;
        }
        usleep(150000);
    }
    listen(s, 4);
    _listenFd = s;
    [ZKStore log:@"speech: listening on %d", ZK_PORT];

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        typeof(self) s2 = weakSelf;
        if (!s2) return;
        while (s2->_running) {
            int c = accept(s2->_listenFd, NULL, NULL);
            if (c < 0) {
                if (!s2->_running) break;
                usleep(120000);
                continue;
            }
            int one = 1;
            setsockopt(c, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
            s2->_connFd = c;
            s2->_fileMode = NO;
            s2->_asrState = @"扩展已连上";
            [ZKStore log:@"speech: ext connected"];
            [s2 readLoop:c];
            close(c);
            s2->_connFd = -1;
            s2->_asrState = @"扩展断开";
            [ZKStore log:@"speech: ext disconnected"];
        }
    });
}

- (void)readLoop:(int)fd {
    while (_running) {
        @autoreleasepool {
        unsigned char hdr[ZK_HDR];
        if (!recvFull(fd, hdr, ZK_HDR)) return;
        uint32_t len = ((uint32_t)hdr[0] << 24) | ((uint32_t)hdr[1] << 16) |
                       ((uint32_t)hdr[2] << 8) | hdr[3];
        uint8_t type = hdr[4];
        uint32_t seq = ((uint32_t)hdr[5] << 24) | ((uint32_t)hdr[6] << 16) |
                       ((uint32_t)hdr[7] << 8) | hdr[8];
        if (len == 0 || len > (4u << 20)) return;
        // 收音模式选了麦克风：扩展那边就算还连着，声音也不往里灌，免得两路一起喂
        if (type == 0 && [[self audioSource] isEqualToString:@"mic"]) {
            NSMutableData *skip = [NSMutableData dataWithLength:len];
            if (!recvFull(fd, skip.mutableBytes, len)) return;
            continue;
        }
        NSMutableData *d = [NSMutableData dataWithLength:len];
        if (!recvFull(fd, d.mutableBytes, len)) return;
        _packets++;

        if (type == 0) {
            _pcmBytes += len;
            [self feedPCM:d.bytes length:len seq:(long long)seq];
        } else if (type == 1) {
            NSString *s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
            if (s.length) [ZKStore log:@"ext status: %@", s];
        }
        }
    }
}

#pragma mark - 收音模式：内部收音 / 麦克风收音

/// 收音模式：system = 系统声音（录屏扩展送过来，跟别的 App 播放的声音走）
///           mic    = 手机麦克风（跟现场说话走）
- (NSString *)audioSource {
    NSString *v = [ZKStore setting:@"audio_src"];
    return v.length ? v : @"system";
}

- (void)applyAudioSource {
    if ([[self audioSource] isEqualToString:@"mic"]) {
        [self startMicFeed];
    } else {
        [self stopMicFeed];
    }
    [ZKStore log:@"speech: 收音模式 %@", [self audioSource]];
}

/// 把麦克风接进来。参数和录屏扩展那条路完全一致（16k 单声道 float32），
/// 所以下游的识别、计费、字幕都不用改。
- (void)startMicFeed {
    if (_micEngine) return;
    @try {
        AVAudioSession *s = [AVAudioSession sharedInstance];
        NSError *se = nil;
        [s setCategory:AVAudioSessionCategoryPlayAndRecord
                  mode:AVAudioSessionModeVoiceChat
               options:AVAudioSessionCategoryOptionDefaultToSpeaker |
                       AVAudioSessionCategoryOptionAllowBluetooth |
                       AVAudioSessionCategoryOptionMixWithOthers
                 error:&se];
        [s setPreferredIOBufferDuration:0.01 error:nil];
        [s setActive:YES error:&se];
        if (se) {
            [ZKStore log:@"mic: session %@", se.localizedDescription];
            if (self.onDiag) self.onDiag([self diag]);
            return;
        }

        _micEngine = [AVAudioEngine new];
        AVAudioInputNode *input = _micEngine.inputNode;
        AVAudioFormat *inFmt = [input inputFormatForBus:0];
        if (!inFmt || inFmt.sampleRate < 8000) {
            [ZKStore log:@"mic: 没有可用的输入格式"];
            _micEngine = nil;
            return;
        }
        _micInRate = inFmt.sampleRate;
        _micOutFmt = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32
                                                      sampleRate:16000
                                                        channels:1
                                                     interleaved:NO];
        _micConv = [[AVAudioConverter alloc] initFromFormat:inFmt toFormat:_micOutFmt];

        __weak typeof(self) weakSelf = self;
        [input installTapOnBus:0 bufferSize:1024 format:inFmt block:^(AVAudioPCMBuffer *buf, AVAudioTime *when) {
            __strong typeof(weakSelf) s2 = weakSelf;
            if (!s2 || !s2->_running || !buf.frameLength) return;

            // 朗读自己念译文的时候不收音，否则念出去的话又被识别一遍
            double nowS = [[NSDate date] timeIntervalSince1970];
            if (nowS - s2->_micGateChecked > 0.05) {
                s2->_micGateChecked = nowS;
            }
            double g = [[ZKStore setting:@"tts_gate"] doubleValue];
            if (g > nowS && g < nowS + 6) return;

            NSUInteger cap = (NSUInteger)(buf.frameLength * 16000.0 / MAX(8000.0, s2->_micInRate)) + 64;
            AVAudioPCMBuffer *out = [[AVAudioPCMBuffer alloc] initWithPCMFormat:s2->_micOutFmt frameCapacity:cap];
            __block BOOL fed = NO;
            NSError *err = nil;
            AVAudioConverterInputBlock ib = ^AVAudioBuffer *(AVAudioPacketCount need, AVAudioConverterInputStatus *st) {
                if (fed) { *st = AVAudioConverterInputStatus_NoDataNow; return nil; }
                fed = YES;
                *st = AVAudioConverterInputStatus_HaveData;
                return buf;
            };
            [s2->_micConv convertToBuffer:out error:&err withInputFromBlock:ib];
            if (err || !out.floatChannelData || out.frameLength == 0) return;
            [s2 feedPCM:out.floatChannelData[0] length:out.frameLength * 4 seq:-1];
        }];

        NSError *e = nil;
        [_micEngine prepare];
        [_micEngine startAndReturnError:&e];
        if (e) {
            [ZKStore log:@"mic: start %@", e.localizedDescription];
            [self stopMicFeed];
            return;
        }
        [ZKStore log:@"mic: 已接入字幕通道"];
    } @catch (NSException *ex) {
        [ZKStore log:@"mic: ex %@", ex.reason];
        _micEngine = nil;
        _micConv = nil;
    }
}

- (void)stopMicFeed {
    if (!_micEngine) return;
    @try { [_micEngine.inputNode removeTapOnBus:0]; } @catch (__unused NSException *ex) {}
    [_micEngine stop];
    _micEngine = nil;
    _micConv = nil;
}

#pragma mark - 音频

- (void)feedPCM:(const void *)p length:(NSUInteger)n {
    [self feedPCM:p length:n seq:-1];
}

// p 是 float32 / 16kHz / 单声道（录屏扩展那边已经转好了）
- (void)feedPCM:(const void *)p length:(NSUInteger)n seq:(long long)seq {
    if (n < 4) return;

    // 必须复制一份：p 来自调用方的临时缓冲
    NSData *d = [NSData dataWithBytes:p length:n];
    NSUInteger frames = n / 4;

    // 帧序号校验：重复的丢掉，跳号的计入丢帧（诊断行能看到）
    if (seq >= 0 && frames > 0) {
        unsigned long long s = (unsigned long long)seq;
        if (_seqInit && s + frames <= _fedFrames) {
            _dupFrames++;
            return;                       // 重复/乱序包，丢弃
        }
        if (_seqInit && s > _fedFrames) {
            _lostFrames += (s - _fedFrames);
        }
        _seqInit = YES;
        _fedFrames = s + frames;
    }

    if (!_firstAudioLogged) {
        _firstAudioLogged = YES;
        [ZKStore log:@"speech: 第一包音频 %lu 帧 → 同传", (unsigned long)frames];
        ZKCrumb("speech.audio");
    }

    // 直接交给同传：识别 + 翻译都由它一个模型干
    @try {
        [[ZKDoubaoAST shared] pushFloat32:(const float *)d.bytes count:frames];
        // 双向：同一条音频再喂一遍给「外语 → 英文」那条，
        // 两条各出各的，最后按原话语言挑一路显示。
        if (_duplex && _astB) [_astB pushFloat32:(const float *)d.bytes count:frames];
        _chunksOut++;
    } @catch (NSException *e) {
        [ZKStore log:@"ast push ex %@", e.reason];
    }
}

#pragma mark - 文件备份通道

- (void)pollFile {
    if (!_running) return;
    if (_connFd >= 0) return;
    NSString *p = [ZKStore pcmFileForRead];
    if (!p) return;
    @try {
        NSDictionary *at = [[NSFileManager defaultManager] attributesOfItemAtPath:p error:nil];
        unsigned long long sz = [at[NSFileSize] unsignedLongLongValue];
        if (sz < _fileOffset) _fileOffset = 0;
        if (sz <= _fileOffset) return;
        NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:p];
        if (!fh) return;
        [fh seekToFileOffset:_fileOffset];
        NSData *d = [fh readDataToEndOfFile];
        [fh closeFile];
        if (!d.length) return;
        _fileOffset += d.length;
        _fileMode = YES;
        _pcmBytes += d.length;
        [self feedPCM:d.bytes length:d.length seq:-1];
    } @catch (__unused NSException *e) {}
}

#pragma mark - 后台保活

- (void)startKeeper {
    if (_engine) return;
    @try {
        AVAudioSession *s = [AVAudioSession sharedInstance];
        [s setCategory:AVAudioSessionCategoryPlayback
                  mode:AVAudioSessionModeMoviePlayback
               options:AVAudioSessionCategoryOptionMixWithOthers
                 error:nil];
        [s setActive:YES error:nil];

        _engine = [[AVAudioEngine alloc] init];
        _player = [[AVAudioPlayerNode alloc] init];
        [_engine attachNode:_player];
        AVAudioFormat *fmt = [_engine.mainMixerNode outputFormatForBus:0];
        [_engine connect:_player to:_engine.mainMixerNode format:fmt];
        [_engine prepare];
        NSError *e = nil;
        [_engine startAndReturnError:&e];
        if (e) { [ZKStore log:@"keeper err %@", e.localizedDescription]; _engine = nil; return; }
        [_player play];
        [self feedSilence];
        [ZKStore log:@"speech: keeper on"];
    } @catch (__unused NSException *e) {
        [ZKStore log:@"keeper exception"];
        _engine = nil;
    }
}

- (void)feedSilence {
    if (!_player || !_engine) return;
    @try {
        AVAudioFormat *fmt = [_engine.mainMixerNode outputFormatForBus:0];
        if (!fmt || fmt.sampleRate <= 0) return;      // 没有音频路由时别硬塞，会抛异常
        AVAudioFrameCount frames = (AVAudioFrameCount)MAX(1024, fmt.sampleRate * 2);
        AVAudioPCMBuffer *b = [[AVAudioPCMBuffer alloc] initWithPCMFormat:fmt frameCapacity:frames];
        if (!b) return;
        b.frameLength = frames;
        __weak typeof(self) weakSelf = self;
        [_player scheduleBuffer:b completionHandler:^{
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [weakSelf feedSilence];
            });
        }];
    } @catch (NSException *e) {
        [ZKStore log:@"silence ex %@", e.reason];
    }
}

#pragma mark - 诊断

// 当前这句从段首开始的原文（上层备用）
- (NSString *)currentSentence {
    return _curSrc.length ? _curSrc : @"";
}

- (NSString *)backendLabel {
    ZKDoubaoAST *a = [ZKDoubaoAST shared];
    if ([a isOnline]) return @"同传在线";
    if (_asrState.length) return _asrState;
    return @"同传未连接";
}

- (NSString *)diag {
    NSString *conn;
    if (_connFd >= 0) conn = @"扩展已连上";
    else if (_fileMode) conn = @"文件通道";
    else conn = @"等扩展连接";

    NSString *lost = @"";
    if (_lostFrames > 0 || _dupFrames > 0) {
        lost = [NSString stringWithFormat:@" · 丢%.1fs/重%ld",
                (double)_lostFrames / ZK_RATE, (long)_dupFrames];
    }

    NSString *src = [[ZKDoubaoAST shared] isOnline] ? @"同传" : (@"同传待连");
    return [NSString stringWithFormat:
            @"%@ · %@ · 音频%.0fKB · 包%ld%@ · %@",
            src, conn, _pcmBytes / 1024.0, (long)_packets, lost,
            _asrState ?: @"待启动"];
}

@end
