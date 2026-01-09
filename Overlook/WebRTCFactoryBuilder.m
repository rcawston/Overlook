#import "WebRTCFactoryBuilder.h"

@implementation WebRTCFactoryBuilder

+ (RTCPeerConnectionFactory *)makeFactoryWithAudioDevice:(id<RTCAudioDevice>)audioDevice {
    RTCDefaultVideoEncoderFactory *encoderFactory = [[RTCDefaultVideoEncoderFactory alloc] init];
    RTCDefaultVideoDecoderFactory *decoderFactory = [[RTCDefaultVideoDecoderFactory alloc] init];

    if (audioDevice != nil) {
        return [[RTCPeerConnectionFactory alloc] initWithEncoderFactory:encoderFactory
                                                         decoderFactory:decoderFactory
                                                            audioDevice:audioDevice];
    }

    return [[RTCPeerConnectionFactory alloc] initWithEncoderFactory:encoderFactory
                                                     decoderFactory:decoderFactory];
}

@end
