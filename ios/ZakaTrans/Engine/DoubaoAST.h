#import <Foundation/Foundation.h>

// 豆包同声传译大模型（火山引擎 AST v2）
//
// 一条 WebSocket 长连接，音频流进去，原文和译文一起出来：
//   650 原文开始 / 651 原文增量 / 652 原文整句
//   653 译文开始 / 654 译文增量 / 655 译文整句
//
// 所以识别和翻译是同一个模型干的，不需要本地识别器，也不需要另开翻译接口。
// 音频要求：16kHz / 16bit / 单声道 PCM，建议 80ms 一包（2560 字节）。
@interface ZKDoubaoAST : NSObject

+ (instancetype)shared;

// 原文（增量 / 整句）
@property (nonatomic, copy) void (^onSourcePartial)(NSString *delta);
@property (nonatomic, copy) void (^onSourceEnd)(NSString *full);

// 译文（增量 / 整句）
@property (nonatomic, copy) void (^onTransPartial)(NSString *delta);
@property (nonatomic, copy) void (^onTransEnd)(NSString *full);

// 状态行 / 自己恢复不了的错
@property (nonatomic, copy) void (^onState)(NSString *state);
@property (nonatomic, copy) void (^onFail)(NSString *why);

- (BOOL)configured;      // AppID + AccessToken 都填了没
- (BOOL)isOnline;        // 会话已建立，音频正在被接收

- (void)start;
- (void)stop;

// 喂 16kHz 单声道 float32（就是录屏扩展推过来的那份）
- (void)pushFloat32:(const float *)p count:(NSUInteger)n;

// 设置页：真建一次连接、真开一个会话，把服务端的回话原样吐出来
- (void)probe:(void (^)(NSString *result))cb;

@end
