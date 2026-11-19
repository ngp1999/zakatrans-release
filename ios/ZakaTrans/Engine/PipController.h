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

// 兼容旧调用
- (void)setTrans:(NSString *)t orig:(NSString *)o;
- (void)showText:(NSString *)t;
@end
