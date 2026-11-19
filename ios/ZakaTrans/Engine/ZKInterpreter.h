#import <Foundation/Foundation.h>

// 同声传译引擎：面对面说话，两边的话各自翻译、各自朗读。
//
// 做法：手机麦克风收声音 → 16kHz 单声道 → 同时喂给两条独立会话
//   A→B（我说的话翻成对方的语言）
//   B→A（对方说的话翻成我的语言）
// 哪条说话，靠识别出的原文是哪国文字来判定，另一条的结果丢掉。
// 音频会话用 voiceChat 模式，系统自带的回声消除会把我们朗读出去的声音压掉，
// 不然自己念的话会被麦克风再收一遍，翻来翻去没完。
@interface ZKInterpreter : NSObject

+ (instancetype)shared;

@property (nonatomic, copy) void (^onLine)(NSString *side, NSString *source, NSString *trans, BOOL final);
@property (nonatomic, copy) void (^onState)(NSString *state);
@property (nonatomic, copy) void (^onFail)(NSString *why);

@property (nonatomic, readonly) BOOL running;

// a:我的语言（如 zh-CN），b:对方的语言（如 en-US）
- (void)startWith:(NSString *)a other:(NSString *)b;
- (void)stop;

// 交换两边语言，不用重开
- (void)setMine:(NSString *)a other:(NSString *)b;

@end
