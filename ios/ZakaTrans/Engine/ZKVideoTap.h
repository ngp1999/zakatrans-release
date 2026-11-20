#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 从 AVPlayer 的音轨上"旁听"出 PCM —— 声音照常从扬声器出来，一点不少。
///
/// 做法是 AVFoundation 官方的 MTAudioProcessingTap：给播放器挂一个后处理 tap，
/// 系统每解出一段音频就在音频线程里回调一次，我们只是顺手抄一份。
///
/// 拿到的统一是 16kHz / 单声道 / float32，正好是同传接口 pushFloat32 要的格式，
/// 中间的重采样和声道混音都在这里做完，上层不用管源视频是 44.1k 还是 48k。
typedef void (^ZKVideoTapBlock)(const float *pcm, NSUInteger frames);

@interface ZKVideoTap : NSObject

/// item 进入 readyToPlay 之后再调（HLS 的音轨要等主列表解析完才存在）。
/// 返回 nil 表示这条视频拿不到可解析的音轨（FairPlay 加密 / 纯视频无音轨）。
+ (nullable ZKVideoTap *)attach:(AVPlayerItem *)item handler:(ZKVideoTapBlock)handler;

/// 拆掉 tap（换片、退出播放页时调）
- (void)detach;

/// 已经转出来的 16k 采样点总数，用来判断"到底有没有声音进来"
@property (nonatomic, readonly) NSUInteger fedFrames;

/// 源采样率，诊断用
@property (nonatomic, readonly) double sourceRate;

@end

NS_ASSUME_NONNULL_END
