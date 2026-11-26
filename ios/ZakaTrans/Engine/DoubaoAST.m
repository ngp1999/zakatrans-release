#import "DoubaoAST.h"
#import "Shared.h"
#import <AVFoundation/AVFoundation.h>
#import <CommonCrypto/CommonHMAC.h>

// 云端同传客户端
//
// 这一版不再直连上游模型：上游的 AppID / AccessToken 只存在服务端，
// 客户端拿到的是一个一次性 ticket，连的是自己的服务。
// 这样别人逆出二进制也拿不到上游凭据，扣费也只能按服务端记的账走。
//
// 对外接口跟以前完全一致（start / stop / pushFloat32 / 四个回调），
// 所以音频管线和画中画那一层一行都不用改。

#define ZT_CHUNK        1280        // 40ms @ 16kHz/16bit/单声道（越小越早上行，字幕越早出）
#define ZT_RATE         16000.0
#define ZT_BUF_SECONDS  8.0
#define ZT_MAX_SESSION  1080.0
#define ZT_RECONNECT    2.0

static NSString *ZTToken(void) {
    NSString *t = [[NSUserDefaults standardUserDefaults] stringForKey:@"zt_account_token"];
    return t.length ? t : nil;
}

static NSString *ZTBase(void) {
    NSString *b = [[NSUserDefaults standardUserDefaults] stringForKey:@"zt_base_url"];
    return b.length ? b : @"https://api.yumss.cn";
}

static NSString *ZTHex(const unsigned char *b, NSUInteger n) {
    NSMutableString *s = [NSMutableString stringWithCapacity:n * 2];
    for (NSUInteger i = 0; i < n; i++) [s appendFormat:@"%02x", b[i]];
    return s;
}

static NSString *ZTRandomHex(NSUInteger bytes) {
    NSMutableData *d = [NSMutableData dataWithLength:bytes];
    SecRandomCopyBytes(kSecRandomDefault, bytes, d.mutableBytes);
    return ZTHex(d.bytes, bytes);
}

static NSString *ZTSign(NSString *token, NSString *method, NSString *path,
                        NSString *reqID, NSString *ts, NSString *nonce, NSData *body) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(body.bytes, (CC_LONG)body.length, digest);
    NSString *bodyHash = ZTHex(digest, CC_SHA256_DIGEST_LENGTH);

    NSString *message = [NSString stringWithFormat:@"%@\n%@\n%@\n%@\n%@\n%@",
                         method.uppercaseString, path, reqID, ts, nonce, bodyHash];
    NSData *key = [token dataUsingEncoding:NSUTF8StringEncoding];
    NSData *msg = [message dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char mac[CC_SHA256_DIGEST_LENGTH];
    CCHmac(kCCHmacAlgSHA256, key.bytes, key.length, msg.bytes, msg.length, mac);
    return ZTHex(mac, CC_SHA256_DIGEST_LENGTH);
}

@implementation ZKDoubaoAST {
    NSURLSession *_session;
    NSURLSessionWebSocketTask *_ws;
    NSMutableData *_pkt;
    dispatch_queue_t _q;

    BOOL _running;
    BOOL _ready;
    BOOL _connecting;
    BOOL _noBalance;
    NSInteger _failCount;
    NSTimeInterval _sessionAt;
    NSString *_ticket;
}

+ (instancetype)shared {
    static ZKDoubaoAST *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [ZKDoubaoAST new]; });
    return s;
}

// 另开一条独立会话：同声传译要两条，各走各的连接、各带各的回调。
// 注意这里必须真 new（不能返回单例）——两条通道共用一个实例时，
// 后 wire 的回调会把前一条覆盖掉，结果只有一个方向能出字。
+ (instancetype)session {
    return [ZKDoubaoAST new];
}

- (instancetype)init {
    if ((self = [super init])) {
        _q = dispatch_queue_create("zaka.cloud.ast", DISPATCH_QUEUE_SERIAL);
        _pkt = [NSMutableData data];
        NSURLSessionConfiguration *c = [NSURLSessionConfiguration defaultSessionConfiguration];
        c.timeoutIntervalForRequest = 20;
        c.waitsForConnectivity = YES;
        _session = [NSURLSession sessionWithConfiguration:c delegate:self delegateQueue:nil];
    }
    return self;
}

- (BOOL)configured { return ZTToken() != nil; }
- (BOOL)isOnline   { return _ready; }

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
        self->_failCount = 0;
        self->_noBalance = NO;
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

#pragma mark - 建连

- (void)connect {
    if (!_running || _connecting || _ws) return;

    NSString *token = ZTToken();
    if (!token) {
        [self setState:@"未初始化"];
        [self fail:@"还没完成初始化，请重新打开 App"];
        return;
    }

    _connecting = YES;
    [self setState:@"连接中"];

    NSString *path = @"/v1/asr/session";
    NSData *body = [@"{}" dataUsingEncoding:NSUTF8StringEncoding];
    NSURL *url = [NSURL URLWithString:[ZTBase() stringByAppendingString:path]];
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:url];
    r.HTTPMethod = @"POST";
    r.timeoutInterval = 20;
    [r setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    r.HTTPBody = body;

    NSString *reqID = [[NSUUID UUID] UUIDString];
    NSString *ts = [NSString stringWithFormat:@"%ld", (long)[[NSDate date] timeIntervalSince1970]];
    NSString *nonce = ZTRandomHex(16);
    [r setValue:[NSString stringWithFormat:@"Bearer %@", token] forHTTPHeaderField:@"Authorization"];
    [r setValue:reqID forHTTPHeaderField:@"X-Req-Id"];
    [r setValue:ts forHTTPHeaderField:@"X-Ts"];
    [r setValue:nonce forHTTPHeaderField:@"X-Nonce"];
    [r setValue:ZTSign(token, @"POST", path, reqID, ts, nonce, body) forHTTPHeaderField:@"X-Sign"];

    __weak typeof(self) weakSelf = self;
    NSURLSessionDataTask *task =
    [_session dataTaskWithRequest:r completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        __strong typeof(weakSelf) s = weakSelf;
        if (!s) return;
        dispatch_async(s->_q, ^{
            if (!s->_running) { s->_connecting = NO; return; }

            NSInteger code = [(NSHTTPURLResponse *)resp statusCode];
            NSDictionary *json = nil;
            if (data.length) {
                id o = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                if ([o isKindOfClass:[NSDictionary class]]) json = o;
            }

            if (code == 402) {
                s->_connecting = NO;
                s->_noBalance = YES;
                NSString *msg = json[@"message"] ?: @"额度不足";
                [s setState:msg];
                [s fail:msg];
                return;
            }
            if (err || code != 200 || !json[@"ws_url"]) {
                s->_connecting = NO;
                NSString *why = err.localizedDescription ?: (json[@"message"] ?: @"连接服务失败");
                [s handleDisconnect:why];
                return;
            }

            NSString *ws = json[@"ws_url"];
            NSString *src = s.srcLang.length ? s.srcLang : ([ZKStore setting:@"asrlang"] ?: @"auto");
            NSString *dst = s.dstLang.length ? s.dstLang : ([ZKStore setting:@"dstlang"] ?: @"zh");
            NSString *md = s.mode.length ? s.mode : @"subtitle";
            // rep=1：这条客户端会处理「整句替换」的译文（replace=true）。
            // 老版本不认识这个标记，服务端就不发替换，免得把半句和整句接成一段。
            ws = [NSString stringWithFormat:@"%@&src=%@&dst=%@&mode=%@&rep=1", ws, src, dst, md];

            s->_ticket = json[@"ticket"];
            s->_failCount = 0;
            s->_sessionAt = [NSDate date].timeIntervalSince1970;

            NSURLSessionWebSocketTask *t = [s->_session webSocketTaskWithURL:[NSURL URLWithString:ws]];
            s->_ws = t;
            [t resume];
            [s setState:@"等待语音"];
            [ZKStore log:@"cloud: session %@ -> %@", json[@"session_id"], src];
            [s receiveLoop];
        });
    }];
    [task resume];
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
        if (msg.type == NSURLSessionWebSocketMessageTypeString) {
            dispatch_async(s->_q, ^{ [s handleText:msg.string]; });
        }
        dispatch_async(s->_q, ^{
            if (s->_ws == ws) [s receiveLoop];
        });
    }];
}

- (void)handleText:(NSString *)text {
    if (!text.length) return;
    NSData *d = [text dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *m = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
    if (![m isKindOfClass:[NSDictionary class]]) return;

    NSString *type = m[@"type"];
    if ([type isEqualToString:@"source"]) {
        NSString *t = m[@"text"];
        if (!t.length) return;
        BOOL final = [m[@"final"] boolValue];
        NSInteger seg = [m[@"seg"] integerValue];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (final) {
                if (self.onSourceEnd) self.onSourceEnd(t, seg);
            } else {
                if (self.onSourcePartial) self.onSourcePartial(t, seg);
            }
        });
    } else if ([type isEqualToString:@"trans"]) {
        NSString *t = m[@"text"];
        if (!t.length) return;
        BOOL final = [m[@"final"] boolValue];
        BOOL replace = [m[@"replace"] boolValue];
        NSInteger seg = [m[@"seg"] integerValue];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (final) {
                if (replace && self.onTransReplace) {
                    self.onTransReplace(t, seg);
                } else if (self.onTransEnd) {
                    self.onTransEnd(t, seg);
                }
            } else {
                if (self.onTransPartial) self.onTransPartial(t, seg);
            }
        });
    } else if ([type isEqualToString:@"state"]) {
        BOOL wasReady = _ready;
        _ready = YES;
        _connecting = NO;
        // 刚连上：把握手期间攒下的声音立刻补发，不用等下一条音频推进来
        if (!wasReady) dispatch_async(_q, ^{ [self flushPackets]; });
        NSString *st = m[@"state"];
        if ([st isEqualToString:@"listening"]) [self setState:@"同传已连接"];
        else if ([st isEqualToString:@"connecting"]) [self setState:@"连接中"];
        else if ([st isEqualToString:@"finished"]) [self setState:@"本段已结束"];
    } else if ([type isEqualToString:@"error"]) {
        NSString *code = m[@"code"];
        NSString *msg = m[@"message"] ?: @"识别服务异常";
        if ([code isEqualToString:@"insufficient_balance"]) {
            _noBalance = YES;
            _running = NO;
        }
        [self setState:msg];
        [self fail:msg];
    } else if ([type isEqualToString:@"settled"]) {
        NSNumber *creds = m[@"credits"];
        if (creds) {
            [self setState:[NSString stringWithFormat:@"本次消耗 %@ 积分", creds]];
        } else {
            NSNumber *billed = m[@"billed"];
            [self setState:[NSString stringWithFormat:@"本次消耗 %@ token", billed ?: @0]];
        }
    }
}

- (void)handleDisconnect:(NSString *)why {
    BOOL wasReady = _ready;
    _ready = NO;
    _connecting = NO;
    [_ws cancelWithCloseCode:NSURLSessionWebSocketCloseCodeGoingAway reason:nil];
    _ws = nil;

    if (!_running || _noBalance) return;

    _failCount++;
    if (_failCount > 6) {
        [self setState:@"网络不稳，已停止"];
        [self fail:@"连不上识别服务，检查网络后再试"];
        _running = NO;
        return;
    }

    [self setState:[NSString stringWithFormat:@"重连中(%ld)", (long)_failCount]];
    if (wasReady || _failCount <= 1) {
        [self fail:why.length ? why : @"连接中断"];
    }

    NSTimeInterval delay = MIN(ZT_RECONNECT * pow(2.0, MIN(_failCount - 1, 2)), 8.0);
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), _q, ^{
        __strong typeof(weakSelf) s = weakSelf;
        if (s && s->_running) [s connect];
    });
}

- (void)finishSession {
    if (!_ws) return;
    NSData *b = [@"{\"type\":\"finish\"}" dataUsingEncoding:NSUTF8StringEncoding];
    [_ws sendMessage:[[NSURLSessionWebSocketMessage alloc] initWithData:b] completionHandler:^(NSError *e) {}];
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
    if (!_running) return;

    // 还没握手完：这段声音先留着，别丢。
    // 以前这里超过半秒就整段清掉，结果开口头一两个词永远进不去——
    // 用户看到的就是"要等一下才认得上"。现在按 ZT_BUF_SECONDS 留满，
    // 连上之后 flushPackets 会把这段补发出去，第一句就是完整的。
    if (!_ready) return;

    // 会话到点主动换一个新的，免得长连接被服务端掐在半句话上
    if ([NSDate date].timeIntervalSince1970 - _sessionAt > ZT_MAX_SESSION) {
        [self finishSession];
        [self teardown];
        _sessionAt = [NSDate date].timeIntervalSince1970;
        [self connect];
        return;
    }

    NSMutableArray *batch = [NSMutableArray array];
    @synchronized (_pkt) {
        while (_pkt.length >= ZT_CHUNK) {
            [batch addObject:[_pkt subdataWithRange:NSMakeRange(0, ZT_CHUNK)]];
            [_pkt replaceBytesInRange:NSMakeRange(0, ZT_CHUNK) withBytes:NULL length:0];
            if (batch.count >= 12) break;   // 补发时一次多带几包，追得上实时
        }
    }

    for (NSData *chunk in batch) {
        NSURLSessionWebSocketTask *ws = _ws;
        if (!ws) break;
        [ws sendMessage:[[NSURLSessionWebSocketMessage alloc] initWithData:chunk]
      completionHandler:^(NSError *e) {
            if (e) {
                dispatch_async(self->_q, ^{ [self handleDisconnect:e.localizedDescription]; });
            }
        }];
    }
}

#pragma mark - 设置页测试

- (void)probe:(void (^)(NSString *))cb {
    NSString *token = ZTToken();
    if (!token) {
        if (cb) cb(@"还没完成初始化");
        return;
    }
    NSString *path = @"/v1/me";
    NSURL *url = [NSURL URLWithString:[ZTBase() stringByAppendingString:path]];
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:url];
    r.timeoutInterval = 15;
    NSString *reqID = [[NSUUID UUID] UUIDString];
    NSString *ts = [NSString stringWithFormat:@"%ld", (long)[[NSDate date] timeIntervalSince1970]];
    NSString *nonce = ZTRandomHex(16);
    [r setValue:[NSString stringWithFormat:@"Bearer %@", token] forHTTPHeaderField:@"Authorization"];
    [r setValue:reqID forHTTPHeaderField:@"X-Req-Id"];
    [r setValue:ts forHTTPHeaderField:@"X-Ts"];
    [r setValue:nonce forHTTPHeaderField:@"X-Nonce"];
    [r setValue:ZTSign(token, @"GET", path, reqID, ts, nonce, [NSData data]) forHTTPHeaderField:@"X-Sign"];

    [[_session dataTaskWithRequest:r completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!cb) return;
            if (err) { cb([NSString stringWithFormat:@"连接失败：%@", err.localizedDescription]); return; }
            NSDictionary *d = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
            NSInteger code = [(NSHTTPURLResponse *)resp statusCode];
            if (code == 200 && [d isKindOfClass:[NSDictionary class]]) {
                cb([NSString stringWithFormat:@"服务正常，剩余 %@ token", d[@"balance"] ?: @0]);
            } else {
                cb([NSString stringWithFormat:@"服务返回 %ld %@", (long)code, d[@"message"] ?: @""]);
            }
        });
    }] resume];
}

#pragma mark - NSURLSessionWebSocketDelegate

- (void)URLSession:(NSURLSession *)session webSocketTask:(NSURLSessionWebSocketTask *)task
didCloseWithCode:(NSURLSessionWebSocketCloseCode)code reason:(NSData *)reason {
    NSString *why = reason.length
        ? [[NSString alloc] initWithData:reason encoding:NSUTF8StringEncoding]
        : [NSString stringWithFormat:@"连接关闭(%ld)", (long)code];
    dispatch_async(_q, ^{
        if (self->_ws != task) return;
        if (code == 4402) {
            self->_noBalance = YES;
            self->_running = NO;
        }
        [self handleDisconnect:why];
    });
}

@end
