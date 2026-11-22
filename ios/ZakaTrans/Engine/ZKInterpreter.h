#import <Foundation/Foundation.h>

// 同声传译引擎：面对面说话，两边的话各自翻译、各自朗读。
//
// 做法：手机麦克风收声音 → 16kHz 单声道 → 同时喂给两条独立会话
//   A→B（我说的话翻成对方的语言）
//   B→A（对方说的话翻成我的语言）
// 哪条说话，靠识别出的原文是哪国文字来判定，另一条的结果丢掉。
// 音频会话用 voiceChat 模式，系统自带的回声消除会把我们朗读出去的声音压掉，
// 不然自己念的话会被麦克风再收一遍，翻来翻去没完。
//
// 事件模型（这一版改的）：
// 原文一落定就立刻推一条 ZKLineKindFinal 出去（此时译文可能还是空的），
// 译文随后以同一个 lineID 推 ZKLineKindUpdate 补进去。
// 以前是「原文和译文都到齐了才发」，用户看到的就是“说完半天没反应”，
// 实际原文早就出来了，全卡在等译文上。

typedef NS_ENUM(NSInteger, ZKLineKind) {
    ZKLineKindDraft  = 0, // 边听边出字（原文在滚，或译文在滚）
    ZKLineKindUpdate = 1, // 这条已经落定，译文补进来
    ZKLineKindFinal  = 2, // 这句结束
};

@interface ZKInterpreter : NSObject

+ (instancetype)shared;

/// lineID 稳定：同一条消息的 Draft/Update/Final 共用同一个 id，界面原地更新不重排
@property (nonatomic, copy) void (^onLine)(NSString *lineID, NSString *side, NSString *source, NSString *trans, NSInteger kind);
@property (nonatomic, copy) void (^onState)(NSString *state);
@property (nonatomic, copy) void (^onFail)(NSString *why);
/// 输入音量 0~1，用来做跳动指示，让「在听」这件事看得见
@property (nonatomic, copy) void (^onLevel)(float level);

@property (nonatomic, readonly) BOOL running;

// a:我的语言（如 zh-CN），b:对方的语言（如 en-US）
- (void)startWith:(NSString *)a other:(NSString *)b;

/// 预热：进这个页面就把两条识别通道握上手，麦克风不动。
/// 按下开始时 startWith:other: 会直接接着用这两条，省掉每次几百毫秒的建连。
- (void)prewarmWith:(NSString *)a other:(NSString *)b;
- (void)stop;

// 交换两边语言，不用重开
- (void)setMine:(NSString *)a other:(NSString *)b;

/// 记下我们刚刚念出去的一句译文。麦克风会把它录回来再识别一遍，
/// 这里存着用来认掉这些回声，不当成人话。
- (void)noteSpoken:(NSString *)text;

#pragma mark - 长按说话

/// 长按说话：打开之后，只有「按住」那段时间的麦克风音频会送给识别服务，
/// 松手补一小段静音让上游把这一句落定，随后出原文和译文。
/// 这样每一句都是完整的一段，不会被环境音、咳嗽、中间停顿切碎。
@property (nonatomic, assign) BOOL pushToTalk;

/// 按下
- (void)beginUtterance;
/// 松开：结束这一句，等结果
- (void)endUtterance;
/// 上滑取消：这一段不要了，把已经冒出来的结果也撤掉
- (void)cancelUtterance;

@end
