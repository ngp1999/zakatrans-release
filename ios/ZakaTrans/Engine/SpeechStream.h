#import <Foundation/Foundation.h>

// 音频层 + 同传转发
//
// 这一层的职责只剩两件：
//   ① 把录屏扩展推过来的音频收进来（TCP 主通道 + 共享文件兜底）
//   ② 交给豆包同声传译，把它吐出来的原文/译文往上抛
//
// 识别和翻译由同一个模型完成，所以这里没有本地识别器、
// 也没有单独的翻译接口，句子边界由模型自己判定。

@interface ZKSpeechStream : NSObject

+ (instancetype)shared;

// 原文增量（651）。unstable 是这一拍新到的字，stable 恒为空——
// 保留两个参数是为了不破坏调用方的接口形态。
@property (nonatomic, copy) void (^onPartial)(NSString *stable, NSString *unstable);

// 原文整句（652）。isFinal 恒为 YES：这一段不会再变
@property (nonatomic, copy) void (^onSegment)(NSString *text, BOOL isFinal);

// 译文增量（654）
@property (nonatomic, copy) void (^onTransPartial)(NSString *delta);

// 译文整句（655）
@property (nonatomic, copy) void (^onTransSegment)(NSString *full);

@property (nonatomic, copy) void (^onDiag)(NSString *d);

// 兼容老接口（不再使用）
@property (nonatomic, copy) void (^onLive)(NSString *);
@property (nonatomic, copy) void (^onSentence)(NSString *);

- (void)start;
- (void)stop;
- (void)reloadLocale;
- (NSString *)diag;

// 当前状态（连接中 / 同传在线 / 失败原因），状态行显示用
- (NSString *)backendLabel;

// 当前这句从段首开始的原文（留给上层备用）
- (NSString *)currentSentence;

@end
