#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// 豆包同声传译大模型（火山引擎 AST v2）——客户端直连版
//
// 这一版不经过任何中间服务：音频直接推到 ospeech 的 WebSocket，
// 原文和译文直接从模型回来。
//   650 原文开始 / 651 原文增量 / 652 原文整句
//   653 译文开始 / 654 译文增量 / 655 译文整句
//
// 凭据由使用者在设置里自己填（AppID + Access Token + Resource ID），
// 只存在本机钥匙串里，不随包分发、不上传任何地方。
//
// 音频要求：16kHz / 16bit / 单声道 PCM，建议 40~80ms 一包。
@interface ZKDoubaoAST : NSObject

+ (instancetype)shared;

// 另开一条独立会话（需要两个方向时才用；实时字幕只用单例）。
+ (instancetype)session;

- (instancetype)init;

// 这条会话的语向。不设就读设置里的 asrlang / dstlang。
@property (nonatomic, copy) NSString *srcLang;
@property (nonatomic, copy) NSString *dstLang;
// 用途标签：subtitle（实时字幕）/ interp（同传），只用于日志。
@property (nonatomic, copy) NSString *mode;

// 原文（增量 / 整句）。seg = 这一句的编号。
@property (nonatomic, copy) void (^onSourcePartial)(NSString *delta, NSInteger seg);
@property (nonatomic, copy) void (^onSourceEnd)(NSString *full, NSInteger seg);

// 译文（增量 / 整句）
@property (nonatomic, copy) void (^onTransPartial)(NSString *delta, NSInteger seg);
@property (nonatomic, copy) void (^onTransEnd)(NSString *full, NSInteger seg);
@property (nonatomic, copy) void (^onTransReplace)(NSString *full, NSInteger seg);

// 状态行 / 自己恢复不了的错
@property (nonatomic, copy) void (^onState)(NSString *state);
@property (nonatomic, copy) void (^onFail)(NSString *why);

- (BOOL)configured;      // AppID + Access Token 都填了没
- (BOOL)isOnline;        // 会话已建立，音频正在被接收

- (void)start;
- (void)stop;

// 喂 16kHz 单声道 float32
- (void)pushFloat32:(const float *)p count:(NSUInteger)n;

// 设置页：真建一次连接、真开一个会话，把结果原样吐出来
- (void)probe:(void (^)(NSString *result))cb;

// ── 凭据（本机钥匙串）──
+ (NSString *)savedAppID;
+ (NSString *)savedToken;
+ (NSString *)savedResource;
+ (void)saveAppID:(NSString *)appID token:(NSString *)token resource:(NSString *)resource;
+ (BOOL)hasCredential;

@end

NS_ASSUME_NONNULL_END
