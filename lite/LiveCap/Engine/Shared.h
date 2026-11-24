#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

extern NSString *const ZKGroupID;
extern NSString *const ZKNotifySub;
extern NSString *const ZKNotifyLog;

// 主 App 与录屏扩展之间的数据交换
// 三条通道同时工作：
//   1) TCP 127.0.0.1（音频主通道）
//   2) 共享文件（音频备份通道、日志、心跳）
//   3) App Group（如果设备上有）
@interface ZKStore : NSObject

+ (NSArray<NSString *> *)dirs;            // 所有可写目录
+ (NSString *)dir;                        // 首选目录（写）
+ (NSString *)path:(NSString *)name;      // 首选路径
+ (NSArray<NSString *> *)readPathsFor:(NSString *)name;  // 所有可能的读取位置
+ (NSDictionary *)read:(NSString *)name;  // 读最新的那份
+ (void)write:(NSDictionary *)d to:(NSString *)name;

+ (NSString *)setting:(NSString *)k;
+ (void)setSetting:(NSString *)k v:(NSString *)v;

// 翻译上下文：最近说过的句子（原文 + 译文），用于代词消解、术语一致、语气连贯
+ (NSArray<NSDictionary *> *)ctxPairs;
+ (void)pushCtxPair:(NSString *)en zh:(NSString *)zh;
+ (void)clearCtx;

+ (void)setSubtitle:(NSString *)orig trans:(NSString *)trans;
+ (NSDictionary *)subtitle;

// 字幕流：已经说完的句子一条条往后排，像看小说一样往上滚
// 已落进流里的句子不再改动（这是画中画不闪的关键）
+ (NSArray<NSDictionary *> *)lines;
+ (void)appendLineEn:(NSString *)en zh:(NSString *)zh;
// 原文先落定、译文后到：把译文补进当前会话最后一行（画中画读的就是这份）
+ (void)updateLastLineZh:(NSString *)zh;
// 精确版：按原文找回那一行再补译文（中间已经又上了新句也不会补错行）
+ (void)updateLineZh:(NSString *)zh forEn:(NSString *)en;
+ (void)clearLines;

// 会话：每次打开 App / 每次起画中画，都算一场新会话。
// 字幕行和翻译上下文都带会话号，读的时候只认当前这场——
// 就算磁盘上有上一场的残留（写盘失败、扩展容器里那份没清掉），也不会被带出来。
+ (NSString *)sessionId;
+ (void)beginNewSession;

+ (void)log:(NSString *)fmt, ...;
+ (NSString *)logTail;

+ (NSArray<NSString *> *)extDirs;         // 扫到的扩展容器目录（主 App 侧有效）
+ (BOOL)isExtension;

// 心跳：扩展每秒写一次，主 App 用来判断扩展到底有没有被拉起来
+ (void)beat:(NSDictionary *)d;
+ (NSDictionary *)beat;

// 音频落盘（备份通道）
+ (NSString *)pcmPath;
+ (void)resetPCM;
+ (void)appendPCM:(const void *)bytes length:(NSUInteger)n;
+ (NSString *)pcmFileForRead;             // 找到扩展写的 pcm 文件
+ (NSString *)diagLine;                   // 一行诊断信息

// 崩溃断点：崩溃时把最后一步写进文件（信号安全），下次启动能读到“中断在哪”
void ZKCrumb(const char *tag);
void ZKInstallCrashHandlers(void);
NSString *ZKCrashTail(void);      // 形如「上次中断：pip.5.check（闪退）」，没有则 nil
void ZKCrumbsReset(void);

@end
