#import "DoubaoAST.h"
#import "Shared.h"
#import <AVFoundation/AVFoundation.h>

// 客户端直连火山引擎「同声传译大模型」AST v2。
//
// 传输：一条 WebSocket（wss://openspeech.bytedance.com/api/v4/ast/v2/translate），
// 鉴权靠四个请求头：AppID / AppKey / AccessToken / ResourceID。
// 帧是裸 protobuf（没有额外包头、没有 gzip）：
//   field 1 request_meta / response_meta
//   field 2 event
//   field 3 user / payload
//   field 4 source_audio 或 text
//   field 6 request
//
// 事件：100 开会话 / 200 音频 / 102 结束
//       150 已建立 / 152 已结束 / 153 失败 / 154 用量
//       650 原文开始 / 651 原文增量 / 652 原文整句
//       653 译文开始 / 654 译文增量 / 655 译文整句
//
// 凭据只在钥匙串里，一个字节都不随包走。

#define ZT_CHUNK        1280        // 40ms @ 16kHz/16bit/单声道
#define ZT_RATE         16000.0
#define ZT_BUF_SECONDS  8.0
#define ZT_MAX_SESSION  1080.0
#define ZT_RECONNECT    2.0

static NSString *const ZT_AST_URL   = @"wss://openspeech.bytedance.com/api/v4/ast/v2/translate";
static NSString *const ZT_RESOURCE  = @"volc.service_type.10053";
static NSString *const ZT_KEYCHAIN  = @"com.zakatrans.livecap";

// ── 凭据 ────────────────────────────────────────────────────

static NSString *ZTKGet(NSString *key) {
    NSDictionary *q = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: ZT_KEYCHAIN,
        (__bridge id)kSecAttrAccount: key,
        (__bridge id)kSecReturnData: @YES,
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne,
    };
    CFTypeRef item = NULL;
    if (SecItemCopyMatching((__bridge CFDictionaryRef)q, &item) != errSecSuccess || !item) return nil;
    NSData *d = (__bridge_transfer NSData *)item;
    return [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
}

static void ZTKSet(NSString *key, NSString *value) {
    NSDictionary *q = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: ZT_KEYCHAIN,
        (__bridge id)kSecAttrAccount: key,
    };
    SecItemDelete((__bridge CFDictionaryRef)q);
    if (value.length == 0) return;
    NSMutableDictionary *add = [q mutableCopy];
    add[(__bridge id)kSecValueData] = [value dataUsingEncoding:NSUTF8StringEncoding];
    add[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlock;
    SecItemAdd((__bridge CFDictionaryRef)add, NULL);
}

// ── protobuf 最小实现 ───────────────────────────────────────

static void pbVarint(NSMutableData *d, uint64_t v) {
    uint8_t buf[10];
    int n = 0;
    while (v >= 0x80) {
        buf[n++] = (uint8_t)(v | 0x80);
        v >>= 7;
    }
    buf[n++] = (uint8_t)v;
    [d appendBytes:buf length:(NSUInteger)n];
}

static void pbKey(NSMutableData *d, int field, int wire) {
    pbVarint(d, ((uint64_t)field << 3) | (uint64_t)wire);
}

static void pbUInt(NSMutableData *d, int field, uint64_t v) {
    pbKey(d, field, 0);
    pbVarint(d, v);
}

static void pbBytes(NSMutableData *d, int field, NSData *b) {
    pbKey(d, field, 2);
    pbVarint(d, (uint64_t)b.length);
    [d appendData:b];
}

static void pbStr(NSMutableData *d, int field, NSString *s) {
    if (!s.length) return;
    pbBytes(d, field, [s dataUsingEncoding:NSUTF8StringEncoding]);
}

typedef struct {
    const uint8_t *b;
    NSUInteger n;
    NSUInteger i;
} ZKPB;

static BOOL pbReadVarint(ZKPB *p, uint64_t *out) {
    uint64_t v = 0;
    int shift = 0;
    while (p->i < p->n) {
        uint8_t c = p->b[p->i++];
        v |= (uint64_t)(c & 0x7f) << shift;
        if ((c & 0x80) == 0) { *out = v; return YES; }
        shift += 7;
        if (shift > 63) return NO;
    }
    return NO;
}

static BOOL pbReadBytes(ZKPB *p, const uint8_t **out, NSUInteger *len) {
    uint64_t l = 0;
    if (!pbReadVarint(p, &l)) return NO;
    if (l > p->n - p->i) return NO;
    *out = p->b + p->i;
    *len = (NSUInteger)l;
    p->i += (NSUInteger)l;
    return YES;
}

static BOOL pbSkip(ZKPB *p, int wire) {
    switch (wire) {
        case 0: { uint64_t v; return pbReadVarint(p, &v); }
        case 1: p->i += 8; break;
        case 2: { const uint8_t *b; NSUInteger l; return pbReadBytes(p, &b, &l); }
        case 5: p->i += 4; break;
        default: return NO;
    }
    return p->i <= p->n;
}

typedef struct {
    int event;
    NSString *text;
    int status;
    NSString *message;
} ZKFrame;

static ZKFrame ZKDecodeFrame(NSData *data) {
    ZKFrame f;
    f.event = 0;
    f.text = nil;
    f.status = 0;
    f.message = nil;

    ZKPB p = { (const uint8_t *)data.bytes, (NSUInteger)data.length, 0 };
    NSMutableArray<NSString *> *texts = [NSMutableArray array];
    NSMutableArray<NSString *> *msgs = [NSMutableArray array];

    while (p.i < p.n) {
        uint64_t k = 0;
        if (!pbReadVarint(&p, &k)) break;
        int field = (int)(k >> 3);
        int wire = (int)(k & 7);

        if (field == 1 && wire == 2) {
            const uint8_t *sb = NULL; NSUInteger sl = 0;
            if (!pbReadBytes(&p, &sb, &sl)) break;
            ZKPB m = { sb, sl, 0 };
            while (m.i < m.n) {
                uint64_t k2 = 0;
                if (!pbReadVarint(&m, &k2)) break;
                int f2 = (int)(k2 >> 3);
                int w2 = (int)(k2 & 7);
                if (f2 == 3 && w2 == 0) {
                    uint64_t v = 0;
                    if (pbReadVarint(&m, &v)) f.status = (int)v;
                } else if (f2 == 4 && w2 == 2) {
                    const uint8_t *vb = NULL; NSUInteger vl = 0;
                    if (pbReadBytes(&m, &vb, &vl)) {
                        NSString *s = [[NSString alloc] initWithBytes:vb length:vl encoding:NSUTF8StringEncoding];
                        if (s.length) [msgs addObject:s];
                    }
                } else if (!pbSkip(&m, w2)) {
                    m.i = m.n;
                }
            }
        } else if (field == 2 && wire == 0) {
            uint64_t v = 0;
            if (pbReadVarint(&p, &v)) f.event = (int)v;
        } else if (field == 4 && wire == 2) {
            const uint8_t *vb = NULL; NSUInteger vl = 0;
            if (!pbReadBytes(&p, &vb, &vl)) break;
            NSString *s = [[NSString alloc] initWithBytes:vb length:vl encoding:NSUTF8StringEncoding];
            if (s.length) [texts addObject:s];
        } else if (!pbSkip(&p, wire)) {
            break;
        }
    }

    if (texts.count) f.text = texts.firstObject;
    if (msgs.count) f.message = msgs.firstObject;
    return f;
}

// ── 会话 ────────────────────────────────────────────────────

@implementation ZKDoubaoAST {
    NSURLSession *_session;
    NSURLSessionWebSocketTask *_ws;
    NSMutableData *_pkt;
    dispatch_queue_t _q;

    BOOL _running;
    BOOL _ready;
    BOOL _connecting;
    BOOL _failedFatal;
    NSInteger _failCount;
    NSTimeInterval _sessionAt;

    NSString *_sessionID;

    // 句子编号：上游不给号，按「原文开始」自己编，译文按到达顺序认领。
    NSInteger _segSeq;
    NSInteger _openSeg;
    NSMutableArray<NSNumber *> *_pendingSegs;

    BOOL _isProbe;
    void (^_probeCB)(NSString *);
}

+ (instancetype)shared {
    static ZKDoubaoAST *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [ZKDoubaoAST new]; });
    return s;
}

+ (instancetype)session {
    return [ZKDoubaoAST new];
}

- (instancetype)init {
    if ((self = [super init])) {
        _q = dispatch_queue_create("livecap.ast", DISPATCH_QUEUE_SERIAL);
        _pkt = [NSMutableData data];
        _pendingSegs = [NSMutableArray array];
        NSURLSessionConfiguration *c = [NSURLSessionConfiguration defaultSessionConfiguration];
        c.timeoutIntervalForRequest = 20;
        c.waitsForConnectivity = YES;
        _session = [NSURLSession sessionWithConfiguration:c delegate:self delegateQueue:nil];
    }
    return self;
}

#pragma mark - 凭据

+ (NSString *)savedAppID { return ZTKGet(@"pb_appid") ?: @""; }
+ (NSString *)savedToken { return ZTKGet(@"pb_token") ?: @""; }
+ (NSString *)savedResource {
    NSString *r = ZTKGet(@"pb_resource");
    return r.length ? r : ZT_RESOURCE;
}

+ (void)saveAppID:(NSString *)appID token:(NSString *)token resource:(NSString *)resource {
    ZTKSet(@"pb_appid", [appID stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]);
    ZTKSet(@"pb_token", [token stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]);
    NSString *r = [resource stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    ZTKSet(@"pb_resource", r.length ? r : ZT_RESOURCE);
}

+ (BOOL)hasCredential {
    return [self savedAppID].length > 0 && [self savedToken].length > 0;
}

- (BOOL)configured {
    return ZKDoubaoAST.savedAppID.length > 0 && ZKDoubaoAST.savedToken.length > 0;
}

- (BOOL)isOnline { return _ready; }

- (void)setState:(NSString *)s {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.onState) self.onState(s);
    });
}

- (void)fail:(NSString *)why {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.onFail) self.onFail(why);
    });
}

#pragma mark - 生命周期

- (void)start {
    dispatch_async(_q, ^{
        if (self->_running) return;
        self->_running = YES;
        self->_failedFatal = NO;
        self->_failCount = 0;
        [self->_pkt setLength:0];
        [self setState:@"连接中"];
        [self connect];
    });
}

- (void)stop {
    dispatch_async(_q, ^{
        self->_running = NO;
        [self finishSession];
        [self teardown];
        [self setState:@"已停止"];
    });
}

- (void)teardown {
    _ready = NO;
    _connecting = NO;
    [_ws cancelWithCloseCode:NSURLSessionWebSocketCloseCodeNormalClosure reason:nil];
    _ws = nil;
    [_pkt setLength:0];
}

#pragma mark - 编码

- (NSData *)metaFrame:(int)event {
    NSMutableData *f = [NSMutableData data];

    NSMutableData *m = [NSMutableData data];
    pbStr(m, 6, _sessionID);
    pbBytes(f, 1, m);
    pbUInt(f, 2, (uint64_t)event);

    NSMutableData *u = [NSMutableData data];
    pbStr(u, 1, @"livecap");
    pbStr(u, 2, @"ios");
    pbStr(u, 3, @"ios");
    pbBytes(f, 3, u);

    NSMutableData *sa = [NSMutableData data];
    pbStr(sa, 4, @"wav");
    pbStr(sa, 5, @"raw");
    pbUInt(sa, 7, 16000);
    pbUInt(sa, 8, 16);
    pbUInt(sa, 9, 1);
    pbBytes(f, 4, sa);

    NSMutableData *rq = [NSMutableData data];
    pbStr(rq, 1, @"s2t");
    pbStr(rq, 2, self.srcLang.length ? self.srcLang : ([ZKStore setting:@"asrlang"] ?: @"auto"));
    pbStr(rq, 3, self.dstLang.length ? self.dstLang : ([ZKStore setting:@"dstlang"] ?: @"zh"));
    pbBytes(f, 6, rq);

    return f;
}

- (NSData *)audioFrame:(NSData *)pcm {
    NSMutableData *f = [NSMutableData data];
    NSMutableData *m = [NSMutableData data];
    pbStr(m, 6, _sessionID);
    pbBytes(f, 1, m);
    pbUInt(f, 2, 200);

    NSMutableData *sa = [NSMutableData data];
    pbStr(sa, 4, @"wav");
    pbStr(sa, 5, @"raw");
    pbUInt(sa, 7, 16000);
    pbUInt(sa, 8, 16);
    pbUInt(sa, 9, 1);
    pbBytes(sa, 14, pcm);
    pbBytes(f, 4, sa);
    return f;
}

- (NSData *)finishFrame {
    NSMutableData *f = [NSMutableData data];
    NSMutableData *m = [NSMutableData data];
    pbStr(m, 6, _sessionID);
    pbBytes(f, 1, m);
    pbUInt(f, 2, 102);
    return f;
}

#pragma mark - 建连

- (void)connect {
    if (!_running || _connecting || _ws) return;

    if (![self configured]) {
        _running = NO;
        [self setState:@"未填 API 凭据"];
        [self fail:@"先在设置里填入豆包 AppID 和 Access Token"];
        return;
    }

    _connecting = YES;
    [self setState:@"连接中"];

    _sessionID = [[NSUUID UUID] UUIDString];
    _segSeq = 0;
    _openSeg = 0;
    [_pendingSegs removeAllObjects];

    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:ZT_AST_URL]];
    r.timeoutInterval = 20;
    NSString *appID = ZKDoubaoAST.savedAppID;
    NSString *token = ZKDoubaoAST.savedToken;
    [r setValue:appID forHTTPHeaderField:@"X-Api-App-Id"];
    [r setValue:appID forHTTPHeaderField:@"X-Api-App-Key"];
    [r setValue:token forHTTPHeaderField:@"X-Api-Access-Key"];
    [r setValue:ZKDoubaoAST.savedResource forHTTPHeaderField:@"X-Api-Resource-Id"];
    [r setValue:_sessionID forHTTPHeaderField:@"X-Api-Connect-Id"];

    NSURLSessionWebSocketTask *t = [_session webSocketTaskWithRequest:r];
    _ws = t;
    [t resume];
    [ZKStore log:@"ast: direct session %@ -> %@/%@", _sessionID, self.srcLang ?: @"auto", self.dstLang ?: @"zh"];

    // 开会话帧要第一个到
    [self sendData:[self metaFrame:100]];
    [self receiveLoop];
}

- (void)sendData:(NSData *)d {
    NSURLSessionWebSocketTask *ws = _ws;
    if (!ws || !d) return;
    [ws sendMessage:[[NSURLSessionWebSocketMessage alloc] initWithData:d]
  completionHandler:^(NSError *e) {
        if (e) {
            dispatch_async(self->_q, ^{ [self handleDisconnect:e.localizedDescription]; });
        }
    }];
}

- (void)receiveLoop {
    NSURLSessionWebSocketTask *ws = _ws;
    if (!ws) return;
    __weak typeof(self) weakSelf = self;
    [ws receiveMessageWithCompletionHandler:^(NSURLSessionWebSocketMessage *msg, NSError *err) {
        __strong typeof(weakSelf) s = weakSelf;
        if (!s) return;
        if (err) {
            dispatch_async(s->_q, ^{
                if (s->_ws != ws) return;
                [s handleDisconnect:err.localizedDescription];
            });
            return;
        }
        if (msg.type == NSURLSessionWebSocketMessageTypeData && msg.data.length) {
            NSData *d = msg.data;
            dispatch_async(s->_q, ^{ [s handleFrame:d]; });
        }
        dispatch_async(s->_q, ^{
            if (s->_ws == ws) [s receiveLoop];
        });
    }];
}

#pragma mark - 收帧

- (void)handleFrame:(NSData *)data {
    ZKFrame f = ZKDecodeFrame(data);

    switch (f.event) {
        case 150: {
            _ready = YES;
            _connecting = NO;
            _failCount = 0;
            _sessionAt = [NSDate date].timeIntervalSince1970;
            [self setState:@"已连接"];
            if (_isProbe) {
                [self finishProbe:@"连接正常，会话已建立"];
                break;
            }
            // 握手期间攒下的声音立刻补发
            [self flushPackets];
            break;
        }
        case 152:
            [self setState:@"本段已结束"];
            break;
        case 153: {
            NSString *why = f.message.length ? f.message : @"会话建立失败";
            [self setState:why];
            [self fail:why];
            if (_isProbe) [self finishProbe:why];
            break;
        }
        case 650: {
            _openSeg = ++_segSeq;
            break;
        }
        case 651: {
            NSString *t = f.text;
            if (!t.length) break;
            NSInteger seg = _openSeg ?: _segSeq;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (self.onSourcePartial) self.onSourcePartial(t, seg);
            });
            break;
        }
        case 652: {
            NSString *t = f.text;
            if (!t.length) break;
            NSInteger seg = _openSeg ?: _segSeq;
            if (seg > 0) [_pendingSegs addObject:@(seg)];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (self.onSourceEnd) self.onSourceEnd(t, seg);
            });
            break;
        }
        case 653: {
            // 译文开始：认领最早一句还没配上的原文
            if (_pendingSegs.count) {
                _openSeg = [_pendingSegs.firstObject integerValue];
                [_pendingSegs removeObjectAtIndex:0];
            }
            break;
        }
        case 654: {
            NSString *t = f.text;
            if (!t.length) break;
            NSInteger seg = _openSeg ?: _segSeq;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (self.onTransPartial) self.onTransPartial(t, seg);
            });
            break;
        }
        case 655: {
            NSString *t = f.text;
            if (!t.length) break;
            NSInteger seg = _openSeg ?: _segSeq;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (self.onTransEnd) self.onTransEnd(t, seg);
            });
            break;
        }
        default:
            break;
    }
}

- (void)handleDisconnect:(NSString *)why {
    BOOL wasReady = _ready;
    _ready = NO;
    _connecting = NO;
    [_ws cancelWithCloseCode:NSURLSessionWebSocketCloseCodeGoingAway reason:nil];
    _ws = nil;

    if (_isProbe) {
        [self finishProbe:why.length ? why : @"连接中断"];
        return;
    }
    if (!_running || _failedFatal) return;

    _failCount++;
    if (_failCount > 6) {
        [self setState:@"网络不稳，已停止"];
        [self fail:@"连不上识别服务，检查网络和凭据后再试"];
        _running = NO;
        _failedFatal = YES;
        return;
    }

    [self setState:[NSString stringWithFormat:@"重连中(%ld)", (long)_failCount]];
    if (wasReady) [self fail:why.length ? why : @"连接中断"];

    NSTimeInterval delay = MIN(ZT_RECONNECT * pow(2.0, MIN(_failCount - 1, 2)), 8.0);
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), _q, ^{
        __strong typeof(weakSelf) s = weakSelf;
        if (s && s->_running) [s connect];
    });
}

- (void)finishSession {
    if (!_ws) return;
    [self sendData:[self finishFrame]];
}

#pragma mark - 音频入口

- (void)pushFloat32:(const float *)p count:(NSUInteger)n {
    if (!p || !n) return;

    NSUInteger bytes = n * 2;
    NSMutableData *pcm = [NSMutableData dataWithLength:bytes];
    int16_t *dst = (int16_t *)pcm.mutableBytes;
    for (NSUInteger i = 0; i < n; i++) {
        float v = p[i];
        if (v > 1.0f) v = 1.0f;
        if (v < -1.0f) v = -1.0f;
        dst[i] = (int16_t)(v * 32767.0f);
    }

    @synchronized (_pkt) {
        [_pkt appendData:pcm];
        NSUInteger cap = (NSUInteger)(ZT_RATE * 2 * ZT_BUF_SECONDS);
        if (_pkt.length > cap) {
            NSUInteger cut = _pkt.length - cap;
            cut -= (cut % 2);
            [_pkt replaceBytesInRange:NSMakeRange(0, cut) withBytes:NULL length:0];
        }
    }
    dispatch_async(_q, ^{ [self flushPackets]; });
}

- (void)flushPackets {
    if (!_running || _isProbe) return;

    // 还没握手完：声音先留着，连上之后整段补发，免得第一句被吃掉
    if (!_ready) return;

    if ([NSDate date].timeIntervalSince1970 - _sessionAt > ZT_MAX_SESSION) {
        [self finishSession];
        [self teardown];
        [self connect];
        return;
    }

    NSMutableArray<NSData *> *batch = [NSMutableArray array];
    @synchronized (_pkt) {
        while (_pkt.length >= ZT_CHUNK) {
            [batch addObject:[_pkt subdataWithRange:NSMakeRange(0, ZT_CHUNK)]];
            [_pkt replaceBytesInRange:NSMakeRange(0, ZT_CHUNK) withBytes:NULL length:0];
            if (batch.count >= 12) break;
        }
    }

    for (NSData *chunk in batch) {
        [self sendData:[self audioFrame:chunk]];
    }
}

#pragma mark - 设置页测试

- (void)finishProbe:(NSString *)result {
    void (^cb)(NSString *) = _probeCB;
    _probeCB = nil;
    _isProbe = NO;
    _running = NO;
    _ready = NO;
    [_ws cancelWithCloseCode:NSURLSessionWebSocketCloseCodeNormalClosure reason:nil];
    _ws = nil;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (cb) cb(result);
    });
}

- (void)probe:(void (^)(NSString *))cb {
    if (![self configured]) {
        if (cb) cb(@"还没填 AppID 或 Access Token");
        return;
    }
    _probeCB = [cb copy];
    _isProbe = YES;
    _failedFatal = NO;
    _failCount = 0;
    _running = YES;
    dispatch_async(_q, ^{ [self connect]; });

    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(12 * NSEC_PER_SEC)), _q, ^{
        __strong typeof(weakSelf) s = weakSelf;
        if (s && s->_isProbe) {
            [s finishProbe:@"连接超时：检查网络，或确认 AppID / Token / ResourceID 是否开通了同声传译"];
        }
    });
}

#pragma mark - NSURLSessionWebSocketDelegate

- (void)URLSession:(NSURLSession *)session webSocketTask:(NSURLSessionWebSocketTask *)task
didCloseWithCode:(NSURLSessionWebSocketCloseCode)code reason:(NSData *)reason {
    NSString *why = reason.length
        ? [[NSString alloc] initWithData:reason encoding:NSUTF8StringEncoding]
        : [NSString stringWithFormat:@"连接关闭(%ld)", (long)code];
    dispatch_async(_q, ^{
        if (self->_ws != task) return;
        // 401/403 这类鉴权错误重连也没用，直接停
        if (code == 4401 || code == 4403) {
            self->_failedFatal = YES;
            self->_running = NO;
            [self setState:@"凭据被拒绝"];
            [self fail:@"AppID / Token / ResourceID 校验没通过，检查设置里的三项"];
        }
        [self handleDisconnect:why];
    });
}

@end
