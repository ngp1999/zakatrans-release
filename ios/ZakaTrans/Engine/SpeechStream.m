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

    NSString *_backendSig;
    NSString *_localeCode;

    // 当前这一段（一句）的原文/译文累计，用来给 root 做兜底
    NSString *_curSrc;
    NSString *_curTr;
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
    @try { [[ZKDoubaoAST shared] stop]; } @catch (__unused NSException *e) {}
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
    NSString *code = [ZKStore setting:@"asrlang"] ?: @"en";
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
}

- (void)wireAst {
    __weak typeof(self) weakSelf = self;
    ZKDoubaoAST *ast = [ZKDoubaoAST shared];

    ast.onSourcePartial = ^(NSString *delta) {
        ZKSpeechStream *s = weakSelf;
        if (!s || !s->_running) return;
        if (!s->_curSrc.length) s->_curSrc = @"";
        s->_curSrc = [s->_curSrc stringByAppendingString:delta ?: @""];
        // root 那边用 (stable, unstable) 两个口子：这里原文本身就是增量，
        // 全部当"还在滚动的尾巴"传，让 root 按增量拼接自己管稳定前缀。
        if (s.onPartial) s.onPartial(@"", delta);
    };

    ast.onSourceEnd = ^(NSString *full) {
        ZKSpeechStream *s = weakSelf;
        if (!s || !s->_running) return;
        NSString *t = full.length ? full : s->_curSrc;
        s->_curSrc = @"";
        t = [t stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (!t.length) return;
        if (s.onSegment) s.onSegment(t, YES);
    };

    ast.onTransPartial = ^(NSString *delta) {
        ZKSpeechStream *s = weakSelf;
        if (!s || !s->_running) return;
        if (!s->_curTr.length) s->_curTr = @"";
        s->_curTr = [s->_curTr stringByAppendingString:delta ?: @""];
        if (s.onTransPartial) s.onTransPartial(delta);
    };

    ast.onTransEnd = ^(NSString *full) {
        ZKSpeechStream *s = weakSelf;
        if (!s || !s->_running) return;
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
    if (bind(s, (struct sockaddr *)&a, sizeof(a)) != 0) {
        close(s);
        _asrState = @"端口被占用";
        [ZKStore log:@"speech: bind failed"];
        return;
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
