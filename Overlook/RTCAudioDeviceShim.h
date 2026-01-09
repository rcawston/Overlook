#ifndef OVERLOOK_RTCAUDIO_DEVICE_SHIM_H_
#define OVERLOOK_RTCAUDIO_DEVICE_SHIM_H_

#import <AudioUnit/AudioUnit.h>
#import <Foundation/Foundation.h>

#import <WebRTC/RTCMacros.h>

NS_ASSUME_NONNULL_BEGIN

typedef OSStatus (^RTC_OBJC_TYPE(RTCAudioDeviceGetPlayoutDataBlock))(
    AudioUnitRenderActionFlags *_Nonnull actionFlags,
    const AudioTimeStamp *_Nonnull timestamp,
    NSInteger inputBusNumber,
    UInt32 frameCount,
    AudioBufferList *_Nonnull outputData);

typedef OSStatus (^RTC_OBJC_TYPE(RTCAudioDeviceRenderRecordedDataBlock))(
    AudioUnitRenderActionFlags *_Nonnull actionFlags,
    const AudioTimeStamp *_Nonnull timestamp,
    NSInteger inputBusNumber,
    UInt32 frameCount,
    AudioBufferList *_Nonnull inputData,
    void *_Nullable renderContext);

typedef OSStatus (^RTC_OBJC_TYPE(RTCAudioDeviceDeliverRecordedDataBlock))(
    AudioUnitRenderActionFlags *_Nonnull actionFlags,
    const AudioTimeStamp *_Nonnull timestamp,
    NSInteger inputBusNumber,
    UInt32 frameCount,
    const AudioBufferList *_Nullable inputData,
    void *_Nullable renderContext,
    NS_NOESCAPE RTC_OBJC_TYPE(RTCAudioDeviceRenderRecordedDataBlock) _Nullable renderBlock);

RTC_OBJC_EXPORT
@protocol RTC_OBJC_TYPE(RTCAudioDeviceDelegate) <NSObject>
@property(readonly, nonnull) RTC_OBJC_TYPE(RTCAudioDeviceDeliverRecordedDataBlock) deliverRecordedData;
@property(readonly) double preferredInputSampleRate;
@property(readonly) NSTimeInterval preferredInputIOBufferDuration;
@property(readonly) double preferredOutputSampleRate;
@property(readonly) NSTimeInterval preferredOutputIOBufferDuration;
@property(readonly, nonnull) RTC_OBJC_TYPE(RTCAudioDeviceGetPlayoutDataBlock) getPlayoutData;
- (void)notifyAudioInputParametersChange;
- (void)notifyAudioOutputParametersChange;
- (void)notifyAudioInputInterrupted;
- (void)notifyAudioOutputInterrupted;
- (void)dispatchAsync:(dispatch_block_t)block;
- (void)dispatchSync:(dispatch_block_t)block;
@end

RTC_OBJC_EXPORT
@protocol RTC_OBJC_TYPE(RTCAudioDevice) <NSObject>
@property(readonly) double deviceInputSampleRate;
@property(readonly) NSTimeInterval inputIOBufferDuration;
@property(readonly) NSInteger inputNumberOfChannels;
@property(readonly) NSTimeInterval inputLatency;
@property(readonly) double deviceOutputSampleRate;
@property(readonly) NSTimeInterval outputIOBufferDuration;
@property(readonly) NSInteger outputNumberOfChannels;
@property(readonly) NSTimeInterval outputLatency;
@property(readonly) BOOL isInitialized;
- (BOOL)initializeWithDelegate:(id<RTC_OBJC_TYPE(RTCAudioDeviceDelegate)>)delegate;
- (BOOL)terminateDevice;
@property(readonly) BOOL isPlayoutInitialized;
- (BOOL)initializePlayout;
@property(readonly) BOOL isPlaying;
- (BOOL)startPlayout;
- (BOOL)stopPlayout;
@property(readonly) BOOL isRecordingInitialized;
- (BOOL)initializeRecording;
@property(readonly) BOOL isRecording;
- (BOOL)startRecording;
- (BOOL)stopRecording;
@end

NS_ASSUME_NONNULL_END

#endif  // OVERLOOK_RTCAUDIO_DEVICE_SHIM_H_
