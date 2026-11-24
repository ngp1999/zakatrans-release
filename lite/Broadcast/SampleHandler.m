#import <ReplayKit/ReplayKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <netinet/tcp.h>
#import <arpa/inet.h>
#import <unistd.h>
#import "Shared.h"

#define ZK_PORT 39392

// 录屏扩展只干一件事：把系统播放的音频抓下来，16k 单声道 float32，
// 一边通过 TCP 发给主 App（主通道），一边落到共享文件（备份通道）。
// 语音识别放在主 App 做——扩展里申请不到语音识别权限，这是之前没字幕的根本原因之一。
@interface BroadcastHandler : RPBroadcastSampleHandler
@end

@implementation BroadcastHandler {
    AVAudioConverter *_conv;
    AVAudioFormat *_convInFmt;
    AVAudioFormat *_outFmt;

    dispatch_queue_t _netQ;
    dispatch_source_t _beatSrc;
    NSMutableData *_pending;
    NSLock *_lock;
    NSMutableData *_fileAccum;

    int _fd;
    BOOL _everConnected;       // 曾经连上过主 App（连上过才说明用户真的在用）
    double _disconnectedAt;    // 断开时刻，0 表示当前连着
    BOOL _autoFinished;        // 已因主 App 消失而自动结束，避免重复调用
    NSInteger _bufs;
    NSInteger _audioFrames;
    NSInteger _dropped;
    NSInteger _ttsSkip;
    double _gateUntil;
    double _gateCheckedAt;
    NSInteger _ticks;
    double _startedAt;
    unsigned long long _pendingStart;   // pending 里第一帧的累计帧号（给主 App 做完整性校验）
}

- (void)broadcastStartedWithSetupInfo:(NSDictionary<NSString *, NSObject *> *)setupInfo {
    _outFmt = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32
                                               sampleRate:16000
                                                 channels:1
                                              interleaved:NO];
    _lock = [NSLock new];
    _pending = [NSMutableData data];
    _fileAccum = [NSMutableData data];
    _netQ = dispatch_queue_create("zaka.ext.net", DISPATCH_QUEUE_SERIAL);
    _fd = -1;
    _bufs = 0;
    _audioFrames = 0;
    _dropped = 0;
    _ttsSkip = 0;
    _startedAt = [NSDate date].timeIntervalSince1970;

    [ZKStore resetPCM];
    [ZKStore log:@"=== ext started ==="];
    [ZKStore log:@"ext dir=%@", [ZKStore dir]];
    [ZKStore beat:@{@"bufs": @0, @"conn": @"starting"}];

    __weak typeof(self) weakSelf0 = self;
    dispatch_async(_netQ, ^{ [weakSelf0 connect]; });
    [self startTimers];
}

- (void)broadcastPaused {
    [ZKStore log:@"ext paused"];
}

- (void)broadcastResumed {
    [ZKStore log:@"ext resumed"];
}

- (void)broadcastFinished {
    [ZKStore log:@"=== ext finished === bufs=%ld frames=%ld drop=%ld ttsSkip=%ld", (long)_bufs, (long)_audioFrames, (long)_dropped, (long)_ttsSkip];
    [ZKStore beat:@{@"bufs": @(_bufs), @"conn": @"finished"}];
    if (_beatSrc) { dispatch_source_cancel(_beatSrc); _beatSrc = nil; }
    if (_fd >= 0) { close(_fd); _fd = -1; }
}

#pragma mark - 网络

// 主 App 可能还没起来，所以不阻塞等待：每 0.5 秒试一次，连上就用，连不上就先走文件通道。
// 主 App 后启动也能自动接上，用户先按哪个按钮都不会白干。
- (void)connect {
    if (_fd >= 0) return;
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return;
    struct sockaddr_in a;
    memset(&a, 0, sizeof(a));
    a.sin_family = AF_INET;
    a.sin_port = htons(ZK_PORT);
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (connect(fd, (struct sockaddr *)&a, sizeof(a)) == 0) {
        struct timeval tv;
        tv.tv_sec = 0;
        tv.tv_usec = 250000;
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
        // 关掉 Nagle：我们每次发的是「9 字节头 + 一小段音频」两个小包，
        // 开着 Nagle 时第二个包要等前一个的 ACK，碰上对端延迟确认就是 +40ms，
        // 而且每包都可能撞上——这是最隐形的一段延迟抖动。
        int one = 1;
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
        _fd = fd;
        _everConnected = YES;
        _disconnectedAt = 0;
        [ZKStore log:@"ext: tcp connected at buf %ld", (long)_bufs];
        [ZKStore beat:@{@"bufs": @(_bufs), @"conn": @"tcp"}];
    } else {
        close(fd);
    }
}

- (void)flushPending {
    NSData *chunk = nil;
    unsigned long long startFrame = 0;
    [_lock lock];
    if (_pending.length) {
        chunk = [_pending copy];
        startFrame = _pendingStart;
        [_pending setLength:0];
    }
    [_lock unlock];
    if (!chunk.length || _fd < 0) return;

    uint32_t len = (uint32_t)chunk.length;
    uint32_t seq = (uint32_t)startFrame;
    // 头：长度(4) + 类型(1) + 起始帧号(4)。帧号让主 App 能发现丢包和重复。
    unsigned char hdr[9] = {
        (unsigned char)((len >> 24) & 0xff),
        (unsigned char)((len >> 16) & 0xff),
        (unsigned char)((len >> 8) & 0xff),
        (unsigned char)(len & 0xff),
        0,
        (unsigned char)((seq >> 24) & 0xff),
        (unsigned char)((seq >> 16) & 0xff),
        (unsigned char)((seq >> 8) & 0xff),
        (unsigned char)(seq & 0xff)
    };
    ssize_t n = send(_fd, hdr, 9, MSG_NOSIGNAL);
    if (n != 9) {
        close(_fd); _fd = -1;
        if (_disconnectedAt == 0) _disconnectedAt = [NSDate date].timeIntervalSince1970;
        return;
    }
    n = send(_fd, chunk.bytes, chunk.length, MSG_NOSIGNAL);
    if (n != (ssize_t)chunk.length) {
        // 断了就别再攒旧音频，重连后从新音频开始，免得字幕拖后几秒
        close(_fd);
        _fd = -1;
        if (_disconnectedAt == 0) _disconnectedAt = [NSDate date].timeIntervalSince1970;
        [_lock lock];
        [_pending setLength:0];
        [_lock unlock];
    }
}

- (void)startTimers {
    _beatSrc = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _netQ);
    // 40ms 一跑：16k 单声道 float32 = 每包 2.5KB 左右，一条 TCP 连接完全扛得住。
    // 原来 100ms + 50ms leeway，平均要多等 75ms、最差 150ms 才发出去，
    // 这几十毫秒是纯白等的，直接算在「说话到出字」里。
    dispatch_source_set_timer(_beatSrc, dispatch_time(DISPATCH_TIME_NOW, 0), 40 * NSEC_PER_MSEC, 10 * NSEC_PER_MSEC);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(_beatSrc, ^{
        typeof(self) s = weakSelf;
        if (!s) return;
        if (s->_fd < 0) [s connect];
        [s flushPending];

        // 主 App 被上划杀掉后，录屏扩展进程还活着：红点一直亮、用户以为还在同传，
        // 实际上音频没人接、服务端也早就结算了。这里自己收尾。
        // 只有「曾经连上过」才判断，避免用户先点录屏、晚几秒才打开 App 被误停。
        if (s->_everConnected && s->_fd < 0 && s->_disconnectedAt > 0 && !s->_autoFinished) {
            double gone = [NSDate date].timeIntervalSince1970 - s->_disconnectedAt;
            if (gone > 20.0) {
                s->_autoFinished = YES;
                [ZKStore log:@"ext: 主 App 已断开 %.0fs，自动结束广播", gone];
                [ZKStore beat:@{@"bufs": @(s->_bufs), @"conn": @"app_gone"}];
                if (s->_beatSrc) { dispatch_source_cancel(s->_beatSrc); s->_beatSrc = nil; }
                dispatch_async(dispatch_get_main_queue(), ^{
                    [s finishBroadcastWithError:[NSError errorWithDomain:@"com.zakatrans.livecap.ext"
                                                                    code:4101
                                                                userInfo:@{NSLocalizedDescriptionKey:
                                                                               @"主 App 已关闭，录屏已停止"}]];
                });
                return;
            }
        }

        // 用户在 App 里点了「停止」：主 App 不能直接停掉系统录屏（ReplayKit 没有这个 API），
        // 但它会把停止时间写进共享设置，扩展在这里读到就自己收尾，红点立刻消失。
        // 只认「本次广播开始之后」的停止标记，上一次会话残留的不会误停。
        if (!s->_autoFinished) {
            NSString *stopAt = [ZKStore setting:@"broadcast_stop"];
            if (stopAt.length) {
                double t = stopAt.doubleValue;
                if (t > s->_startedAt) {
                    s->_autoFinished = YES;
                    [ZKStore log:@"ext: 主 App 要求停止（%.0f）", t];
                    [ZKStore beat:@{@"bufs": @(s->_bufs), @"conn": @"app_stop"}];
                    if (s->_beatSrc) { dispatch_source_cancel(s->_beatSrc); s->_beatSrc = nil; }
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [s finishBroadcastWithError:[NSError errorWithDomain:@"com.zakatrans.livecap.ext"
                                                                        code:4102
                                                                    userInfo:@{NSLocalizedDescriptionKey:
                                                                                   @"已停止实时字幕"}]];
                    });
                    return;
                }
            }
        }

        s->_ticks++;
        if (s->_ticks % 25 != 0) return;
        [ZKStore beat:@{@"bufs": @(s->_bufs),
                        @"frames": @(s->_audioFrames),
                        @"drop": @(s->_dropped),
                        @"conn": (s->_fd >= 0 ? @"tcp" : @"file"),
                        @"ver": @"1.3"}];
    });
    dispatch_resume(_beatSrc);
}

#pragma mark - 音频

- (void)processSampleBuffer:(CMSampleBufferRef)sampleBuffer withType:(RPSampleBufferType)bufferType {
    if (bufferType != RPSampleBufferTypeAudioApp) return;

    // 朗读门：App 正在用系统语音念字幕时，录到的混音里就有我们自己的声音。
    // 送进上游会被当成对方说话再翻一遍——文本重复、句子被切断、还白烧 token，
    // 所以这段时间不能把混音送上去。
    //
    // 但不能整段丢包：上一版就是直接 return，包一断上游拿不到音频，
    // 时间轴跟着就断了，表现为「漏一段、句子断、要等好几秒才继续出字」。
    // 现在改成送等长的静音帧——时长和帧号都连续，上游只当是没人说话。
    // 值每 0.3 秒最多读一次：音频回调一秒几十次，每次都去读共享设置会把采集线程拖卡。
    BOOL silent = NO;
    double nowSec = [[NSDate date] timeIntervalSince1970];
    if (nowSec - _gateCheckedAt > 0.3) {
        _gateCheckedAt = nowSec;
        double g = [[ZKStore setting:@"tts_gate"] doubleValue];
        // 防御:朗读门的时间戳最多只可能是「现在 + 1 秒」。
        // 读到离谱的未来值(上一次进程崩在门里、设置被写坏)整场录音会被静音,
        // 用户看到的就是「扩展开起来了,但一个字都不出」——这种值一律当 0。
        if (!(g > nowSec) || g > nowSec + 5) g = 0;
        _gateUntil = g;
    }
    if (_gateUntil > nowSec) {
        _ttsSkip++;
        silent = YES;
    }

    CMFormatDescriptionRef fd = CMSampleBufferGetFormatDescription(sampleBuffer);
    if (!fd) return;
    const AudioStreamBasicDescription *asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd);
    if (!asbd) return;

    AVAudioFormat *inFmt = [[AVAudioFormat alloc] initWithStreamDescription:asbd];
    if (!inFmt) return;

    if (!_conv || !_convInFmt || _convInFmt.sampleRate != inFmt.sampleRate ||
        _convInFmt.channelCount != inFmt.channelCount || _convInFmt.isInterleaved != inFmt.isInterleaved) {
        _convInFmt = inFmt;
        _conv = [[AVAudioConverter alloc] initFromFormat:inFmt toFormat:_outFmt];
    }
    if (!_conv) return;

    CMItemCount n = CMSampleBufferGetNumSamples(sampleBuffer);
    if (n <= 0) return;

    AVAudioPCMBuffer *inBuf = [[AVAudioPCMBuffer alloc] initWithPCMFormat:inFmt frameCapacity:(AVAudioFrameCount)n];
    if (!inBuf) return;
    inBuf.frameLength = (AVAudioFrameCount)n;
    OSStatus st = CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, 0, (int32_t)n, inBuf.mutableAudioBufferList);
    if (st != noErr) return;

    AVAudioFrameCount cap = (AVAudioFrameCount)((double)n * 16000.0 / MAX(inFmt.sampleRate, 1) + 16);
    AVAudioPCMBuffer *outBuf = [[AVAudioPCMBuffer alloc] initWithPCMFormat:_outFmt frameCapacity:cap];
    if (!outBuf || !outBuf.floatChannelData) return;

    __block BOOL fed = NO;
    AVAudioConverterInputBlock block = ^AVAudioBuffer *(AVAudioPacketCount inPackets, AVAudioConverterInputStatus *outStatus) {
        if (fed) { *outStatus = AVAudioConverterInputStatus_NoDataNow; return nil; }
        fed = YES;
        *outStatus = AVAudioConverterInputStatus_HaveData;
        return inBuf;
    };
    NSError *err = nil;
    [_conv convertToBuffer:outBuf error:&err withInputFromBlock:block];
    if (!outBuf.frameLength) return;

    NSUInteger bytes = outBuf.frameLength * sizeof(float);
    if (silent && outBuf.floatChannelData[0]) {
        memset(outBuf.floatChannelData[0], 0, bytes);
    }
    NSData *pcm = [NSData dataWithBytes:outBuf.floatChannelData[0] length:bytes];
    if (!pcm.length) return;

    _bufs++;
    unsigned long long startFrame = (unsigned long long)_audioFrames;
    _audioFrames += outBuf.frameLength;

    // 主通道：攒着等定时器发
    [_lock lock];
    if (_pending.length > 3 * 1024 * 1024) {
        _dropped++;
        // 积压太多就整段丢掉，后面的音频重新开始攒，字幕不会越拖越远
        [_pending setLength:0];
    } else {
        if (_pending.length == 0) _pendingStart = startFrame;
        [_pending appendData:pcm];
    }
    if (_fileAccum.length < 64 * 1024) [_fileAccum appendData:pcm];
    NSData *toWrite = nil;
    if (_fileAccum.length >= 64 * 1024) {
        toWrite = [_fileAccum copy];
        [_fileAccum setLength:0];
    }
    [_lock unlock];

    // 备份通道：落盘
    if (toWrite.length) [ZKStore appendPCM:toWrite.bytes length:toWrite.length];

    if (_bufs == 1) {
        [ZKStore log:@"ext: 第一帧音频到了 sr=%.0f ch=%u silent=%d", inFmt.sampleRate, (unsigned)inFmt.channelCount, (int)silent];
    }
    if (_bufs % 400 == 1) {
        [ZKStore log:@"ext audio bufs=%ld frames=%ld fd=%d", (long)_bufs, (long)_audioFrames, _fd];
    }
}

@end
