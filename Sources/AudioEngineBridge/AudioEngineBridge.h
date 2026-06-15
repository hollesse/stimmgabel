#import <Foundation/Foundation.h>
#import <AVFAudio/AVFAudio.h>

NS_ASSUME_NONNULL_BEGIN

/// Installs a tap on an AVAudioNode inside @try/@catch.
/// Returns nil on success, or "ExceptionName: reason" on failure.
/// Swift cannot catch ObjC NSExceptions — this bridge prevents a hard crash.
NSString * _Nullable SGTryInstallTap(AVAudioNode *node,
                                      AVAudioNodeBus bus,
                                      AVAudioFrameCount bufferSize,
                                      AVAudioFormat * _Nullable format,
                                      AVAudioNodeTapBlock block);

NS_ASSUME_NONNULL_END
