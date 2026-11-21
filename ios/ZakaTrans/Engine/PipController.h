#import <UIKit/UIKit.h>

@interface ZKPip : NSObject
+ (instancetype)shared;
// 字幕设置：size / color / style / mode / pip
+ (void)applyStyle:(NSDictionary *)p;
- (BOOL)isActive;
- (void)startInView:(UIView *)view;
- (void)stop;
- (void)refreshFromStore;

// 长文本阅读流：说过的话一句句往后接，当前正在说的那句贴在底部
- (void)appendLineEn:(NSString *)en zh:(NSString *)zh;
- (void)setLiveEn:(NSString *)en zh:(NSString *)zh;
// 已经听完整的一句先上屏（原文），译文到了再就地补上去——上屏快，字不跳
- (void)showLiveEn:(NSString *)en zh:(NSString *)zh;
// 译文比原文晚到：补到最后一行上（内存 + 共享流都补），画中画不会只剩原文
- (void)patchLastZh:(NSString *)zh;
// 精确版：按原文找回那一行再补
- (void)patchZh:(NSString *)zh forEn:(NSString *)en;

// 兼容旧调用
- (void)setTrans:(NSString *)t orig:(NSString *)o;
- (void)showText:(NSString *)t;
@end
