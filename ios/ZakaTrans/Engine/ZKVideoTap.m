#import "ZKVideoTap.h"
#import <MediaToolbox/MediaToolbox.h>
#import <AudioToolbox/AudioToolbox.h>
#import <stdlib.h>
#import <string.h>

// 目标输出格式：同传接口要的 16kHz 单声道 float32
#define ZK_TAP_RATE 16000.0

@interface ZKVideoTap () {
@public
    AudioStreamBasicDescription _asbd;
    float *_mono;
    float *_out;
    NSUInteger _monoCap;
    NSUInteger _outCap;
    double _pos;        // 下一个输出采样点落在输入时间轴上的位置
    float _prev;        // 上一帧（跨回调边界插值用）
    NSUInteger _fed;
    BOOL _ready;
}
@property (nonatomic, copy) ZKVideoTapBlock handler;
- (void)prepareWithFormat:(const AudioStreamBasicDescription *)fmt maxFrames:(NSUInteger)maxFrames;
- (void)unprepare;
- (void)consume:(AudioBufferList *)abl frames:(CMItemCount)n;
@end

#pragma mark - C 回调

static void ZKTapInit(MTAudioProcessingTapRef tap, void *clientInfo, void **tapStorageOut) {
    // 用 retained 指针把 self 钉住：tap 活得比局部变量久，
    // 不 retain 的话音频线程回调时对象可能已经被释放了。
    if (clientInfo) *tapStorageOut = (void *)CFBridgingRetain((__bridge id)clientInfo);
}

static void ZKTapFinalize(MTAudioProcessingTapRef tap) {
    void *s = MTAudioProcessingTapGetStorage(tap);
    if (s) CFBridgingRelease(s);
}

static void ZKTapPrepare(MTAudioProcessingTapRef tap, CMItemCount maxFrames,
                         const AudioStreamBasicDescription *processingFormat) {
    ZKVideoTap *me = (__bridge ZKVideoTap *)MTAudioProcessingTapGetStorage(tap);
    if (!me || !processingFormat) return;
    [me prepareWithFormat:processingFormat maxFrames:(NSUInteger)MAX(maxFrames, 4096)];
}

static void ZKTapUnprepare(MTAudioProcessingTapRef tap) {
    ZKVideoTap *me = (__bridge ZKVideoTap *)MTAudioProcessingTapGetStorage(tap);
    if (me) [me unprepare];
}

static void ZKTapProcess(MTAudioProcessingTapRef tap, CMItemCount numberFrames,
                         MTAudioProcessingTapFlags flags, AudioBufferList *bufferListInOut,
                         CMItemCount *numberFramesOut, MTAudioProcessingTapFlags *flagsOut) {
    OSStatus st = MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferListInOut,
                                                     flagsOut, NULL, numberFramesOut);
    if (st != noErr || !numberFramesOut || *numberFramesOut <= 0) {
        if (numberFramesOut) *numberFramesOut = 0;
        return;
    }
    ZKVideoTap *me = (__bridge ZKVideoTap *)MTAudioProcessingTapGetStorage(tap);
    if (me) [me consume:bufferListInOut frames:*numberFramesOut];
}

#pragma mark -

@implementation ZKVideoTap

+ (nullable ZKVideoTap *)attach:(AVPlayerItem *)item handler:(ZKVideoTapBlock)handler {
    if (!item || !handler) return nil;

    // HLS 的轨道要等主列表解析完才有；拿不到就返回 nil，上层会在状态变化后重试
    AVAssetTrack *track = [item.asset tracksWithMediaType:AVMediaTypeAudio].firstObject;
    if (!track && item.tracks.count) {
        for (AVPlayerItemTrack *t in item.tracks) {
            if (t.assetTrack.mediaType == AVMediaTypeAudio) { track = t.assetTrack; break; }
        }
    }
    if (!track) return nil;

    ZKVideoTap *tapObj = [ZKVideoTap new];
    tapObj.handler = handler;
    tapObj->_pos = 0;
    tapObj->_prev = 0;
    tapObj->_fed = 0;

    MTAudioProcessingTapCallbacks cb;
    memset(&cb, 0, sizeof(cb));
    cb.version = kMTAudioProcessingTapCallbacksVersion_0;
    cb.clientInfo = (__bridge void *)tapObj;
    cb.init = ZKTapInit;
    cb.finalize = ZKTapFinalize;
    cb.prepare = ZKTapPrepare;
    cb.unprepare = ZKTapUnprepare;
    cb.process = ZKTapProcess;

    MTAudioProcessingTapRef tap = NULL;
    OSStatus st = MTAudioProcessingTapCreate(kCFAllocatorDefault, &cb,
                                             kMTAudioProcessingTapCreationFlag_PostEffects,
                                             &tap);
    if (st != noErr || !tap) return nil;

    AVMutableAudioMixInputParameters *params =
        [AVMutableAudioMixInputParameters audioMixInputParametersWithTrack:track];
    params.audioTapProcessor = tap;
    CFRelease(tap);                       // params 已经持有

    AVMutableAudioMix *mix = [AVMutableAudioMix audioMix];
    mix.inputParameters = @[params];
    item.audioMix = mix;

    return tapObj;
}

- (void)detach {
    self.handler = nil;
}

- (void)prepareWithFormat:(const AudioStreamBasicDescription *)fmt maxFrames:(NSUInteger)maxFrames {
    @synchronized (self) {
        _asbd = *fmt;
        _ready = YES;
        _pos = 0;
        _prev = 0;
        _fed = 0;

        // 降采样后输出点数最多是输入的 (16k/srcRate) 倍，低采样率源留足余量
        NSUInteger cap = maxFrames + 8;
        double ratio = ZK_TAP_RATE / MAX(fmt->mSampleRate, 1.0);
        if (ratio > 1.0) cap = (NSUInteger)(maxFrames * ratio) + 16;

        if (!_mono || _monoCap < maxFrames) {
            free(_mono);
            _monoCap = maxFrames;
            _mono = (float *)malloc(sizeof(float) * _monoCap);
        }
        if (!_out || _outCap < cap) {
            free(_out);
            _outCap = cap;
            _out = (float *)malloc(sizeof(float) * _outCap);
        }
    }
}

- (void)unprepare {
    @synchronized (self) { _ready = NO; }
}

- (void)consume:(AudioBufferList *)abl frames:(CMItemCount)n {
    if (!_ready || n <= 0) return;
    ZKVideoTapBlock h = self.handler;
    if (!h) return;

    @synchronized (self) {
        if (!_mono || !_out) return;

        AudioStreamBasicDescription a = _asbd;
        if (a.mSampleRate <= 0) return;

        BOOL isFloat = (a.mFormatFlags & kAudioFormatFlagIsFloat) != 0;
        UInt32 ch = a.mChannelsPerFrame ? a.mChannelsPerFrame : 1;
        UInt32 frames = (UInt32)n;
        if (frames > _monoCap) frames = (UInt32)_monoCap;   // 保险，正常不会触发

        UInt32 bufs = abl->mNumberBuffers;
        if (bufs == 0) return;

        // ① 各声道混成单声道
        if (isFloat) {
            if (bufs == 1 && ch > 1) {
                // 交错：一个 buffer 里 LRLRLR
                const float *p = (const float *)abl->mBuffers[0].mData;
                if (!p) return;
                for (UInt32 i = 0; i < frames; i++) {
                    float sum = 0;
                    for (UInt32 c = 0; c < ch; c++) sum += p[i * ch + c];
                    _mono[i] = sum / (float)ch;
                }
            } else {
                // 非交错：每个声道一个 buffer
                UInt32 nb = MIN(bufs, ch);
                for (UInt32 i = 0; i < frames; i++) _mono[i] = 0;
                UInt32 used = 0;
                for (UInt32 c = 0; c < nb; c++) {
                    const float *p = (const float *)abl->mBuffers[c].mData;
                    if (!p) continue;
                    used++;
                    for (UInt32 i = 0; i < frames; i++) _mono[i] += p[i];
                }
                if (used > 1) {
                    float k = 1.0f / (float)used;
                    for (UInt32 i = 0; i < frames; i++) _mono[i] *= k;
                }
            }
        } else {
            // 16bit 整数（极少见，兜底）
            if (bufs == 1 && ch > 1) {
                const int16_t *p = (const int16_t *)abl->mBuffers[0].mData;
                if (!p) return;
                for (UInt32 i = 0; i < frames; i++) {
                    float sum = 0;
                    for (UInt32 c = 0; c < ch; c++) sum += (float)p[i * ch + c] / 32768.0f;
                    _mono[i] = sum / (float)ch;
                }
            } else {
                UInt32 nb = MIN(bufs, ch);
                for (UInt32 i = 0; i < frames; i++) _mono[i] = 0;
                UInt32 used = 0;
                for (UInt32 c = 0; c < nb; c++) {
                    const int16_t *p = (const int16_t *)abl->mBuffers[c].mData;
                    if (!p) continue;
                    used++;
                    for (UInt32 i = 0; i < frames; i++) _mono[i] += (float)p[i] / 32768.0f;
                }
                if (used > 1) {
                    float k = 1.0f / (float)used;
                    for (UInt32 i = 0; i < frames; i++) _mono[i] *= k;
                }
            }
        }

        // ② 重采样到 16k（线性插值，够 ASR 用，CPU 成本几乎为零）
        double step = a.mSampleRate / ZK_TAP_RATE;
        if (step < 0.0001) return;
        double pos = _pos;
        float prev = _prev;
        NSUInteger oi = 0;

        for (UInt32 i = 0; i < frames; i++) {
            float cur = _mono[i];
            while (pos <= (double)i) {
                double frac = pos - (double)((int)i - 1);
                if (frac < 0) frac = 0;
                if (frac > 1) frac = 1;
                float v = prev + (cur - prev) * (float)frac;
                if (oi < _outCap) _out[oi++] = v;
                pos += step;
            }
            prev = cur;
        }
        _pos = pos - (double)frames;
        if (_pos < -4.0) _pos = -4.0;
        _prev = prev;

        if (oi == 0) return;
        _fed += oi;
        h(_out, oi);
    }
}

- (NSUInteger)fedFrames {
    @synchronized (self) { return _fed; }
}

- (double)sourceRate {
    @synchronized (self) { return _asbd.mSampleRate; }
}

- (void)dealloc {
    free(_mono);
    free(_out);
}

@end
