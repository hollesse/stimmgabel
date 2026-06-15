#import "AudioEngineBridge.h"

NSString * SGTryInstallTap(AVAudioNode *node,
                            AVAudioNodeBus bus,
                            AVAudioFrameCount bufferSize,
                            AVAudioFormat *format,
                            AVAudioNodeTapBlock block) {
    @try {
        [node installTapOnBus:bus bufferSize:bufferSize format:format block:block];
        return nil;
    } @catch (NSException *e) {
        return [NSString stringWithFormat:@"%@: %@", e.name, e.reason];
    }
}
