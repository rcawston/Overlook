import Foundation
import AudioUnit
import CoreAudio

#if canImport(WebRTC)
@preconcurrency import WebRTC
#endif

final class WebRTCAudioDevice: NSObject, RTCAudioDevice {
    fileprivate var delegate: RTCAudioDeviceDelegate?

    private let inputDeviceUID: String?
    private let outputDeviceUID: String?

    fileprivate var inputUnit: AudioComponentInstance?
    fileprivate var outputUnit: AudioComponentInstance?

    fileprivate var inputBufferList: UnsafeMutablePointer<AudioBufferList>?
    private var inputBufferData: UnsafeMutableRawPointer?
    private var inputBufferCapacityFrames: UInt32 = 0

    private var _isInitialized: Bool = false
    private var _isPlayoutInitialized: Bool = false
    private var _isRecordingInitialized: Bool = false
    private var _isPlaying: Bool = false
    private var _isRecording: Bool = false

    private var inputSampleRate: Double = 48_000
    private var outputSampleRate: Double = 48_000

    private var inputIOBufferDurationValue: TimeInterval = 0.01
    private var outputIOBufferDurationValue: TimeInterval = 0.01

    private var inputChannels: Int = 1
    private var outputChannels: Int = 1

    private var inputLatencyValue: TimeInterval = 0
    private var outputLatencyValue: TimeInterval = 0

    init(inputDeviceUID: String?, outputDeviceUID: String?) {
        self.inputDeviceUID = inputDeviceUID?.isEmpty == true ? nil : inputDeviceUID
        self.outputDeviceUID = outputDeviceUID?.isEmpty == true ? nil : outputDeviceUID
        super.init()
    }

    var deviceInputSampleRate: Double { inputSampleRate }
    var inputIOBufferDuration: TimeInterval { inputIOBufferDurationValue }
    var inputNumberOfChannels: Int { inputChannels }
    var inputLatency: TimeInterval { inputLatencyValue }

    var deviceOutputSampleRate: Double { outputSampleRate }
    var outputIOBufferDuration: TimeInterval { outputIOBufferDurationValue }
    var outputNumberOfChannels: Int { outputChannels }
    var outputLatency: TimeInterval { outputLatencyValue }

    var isInitialized: Bool { _isInitialized }
    var isPlayoutInitialized: Bool { _isPlayoutInitialized }
    var isPlaying: Bool { _isPlaying }
    var isRecordingInitialized: Bool { _isRecordingInitialized }
    var isRecording: Bool { _isRecording }

    func initialize(with delegate: RTCAudioDeviceDelegate) -> Bool {
        self.delegate = delegate
        inputSampleRate = delegate.preferredInputSampleRate
        outputSampleRate = delegate.preferredOutputSampleRate
        inputIOBufferDurationValue = delegate.preferredInputIOBufferDuration
        outputIOBufferDurationValue = delegate.preferredOutputIOBufferDuration
        _isInitialized = true
        return true
    }

    func terminateDevice() -> Bool {
        _ = stopPlayout()
        _ = stopRecording()

        if let unit = outputUnit {
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
        outputUnit = nil
        _isPlayoutInitialized = false

        if let unit = inputUnit {
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
        inputUnit = nil
        _isRecordingInitialized = false

        inputBufferList?.deallocate()
        inputBufferList = nil
        inputBufferData?.deallocate()
        inputBufferData = nil
        inputBufferCapacityFrames = 0

        delegate = nil
        _isInitialized = false
        return true
    }

    func initializePlayout() -> Bool {
        guard _isInitialized else { return false }
        guard outputUnit == nil else {
            _isPlayoutInitialized = true
            return true
        }

        guard let unit = createHALOutputUnit(deviceID: resolveOutputDeviceID()) else { return false }
        outputUnit = unit

        var format = makeLinearPCMFormat(sampleRate: outputSampleRate, channels: outputChannels)
        var status = AudioUnitSetProperty(
            unit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input,
            0,
            &format,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        )
        guard status == noErr else { return false }

        var callback = AURenderCallbackStruct(
            inputProc: playoutRenderCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        status = AudioUnitSetProperty(
            unit,
            kAudioUnitProperty_SetRenderCallback,
            kAudioUnitScope_Input,
            0,
            &callback,
            UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        )
        guard status == noErr else { return false }

        status = AudioUnitInitialize(unit)
        guard status == noErr else { return false }

        _isPlayoutInitialized = true
        return true
    }

    func startPlayout() -> Bool {
        guard _isPlayoutInitialized, let unit = outputUnit else { return false }
        if _isPlaying { return true }
        let status = AudioOutputUnitStart(unit)
        guard status == noErr else { return false }
        _isPlaying = true
        return true
    }

    func stopPlayout() -> Bool {
        guard let unit = outputUnit else {
            _isPlaying = false
            return true
        }
        if !_isPlaying { return true }
        let status = AudioOutputUnitStop(unit)
        guard status == noErr else { return false }
        _isPlaying = false
        return true
    }

    func initializeRecording() -> Bool {
        guard _isInitialized else { return false }
        guard inputUnit == nil else {
            _isRecordingInitialized = true
            return true
        }

        guard let unit = createHALInputUnit(deviceID: resolveInputDeviceID()) else { return false }
        inputUnit = unit

        var format = makeLinearPCMFormat(sampleRate: inputSampleRate, channels: inputChannels)
        var status = AudioUnitSetProperty(
            unit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Output,
            1,
            &format,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        )
        guard status == noErr else { return false }

        var callback = AURenderCallbackStruct(
            inputProc: recordingInputCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_SetInputCallback,
            kAudioUnitScope_Global,
            0,
            &callback,
            UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        )
        guard status == noErr else { return false }

        if inputBufferList == nil {
            allocateInputBufferIfNeeded(sampleRate: inputSampleRate)
        }

        status = AudioUnitInitialize(unit)
        guard status == noErr else { return false }

        _isRecordingInitialized = true
        return true
    }

    func startRecording() -> Bool {
        guard _isRecordingInitialized, let unit = inputUnit else { return false }
        if _isRecording { return true }
        let status = AudioOutputUnitStart(unit)
        guard status == noErr else { return false }
        _isRecording = true
        return true
    }

    func stopRecording() -> Bool {
        guard let unit = inputUnit else {
            _isRecording = false
            return true
        }
        if !_isRecording { return true }
        let status = AudioOutputUnitStop(unit)
        guard status == noErr else { return false }
        _isRecording = false
        return true
    }

    private func resolveInputDeviceID() -> AudioDeviceID {
        if let uid = inputDeviceUID, let id = CoreAudioDevices.deviceID(forUID: uid) {
            return id
        }
        return defaultDeviceID(selector: kAudioHardwarePropertyDefaultInputDevice)
    }

    private func resolveOutputDeviceID() -> AudioDeviceID {
        if let uid = outputDeviceUID, let id = CoreAudioDevices.deviceID(forUID: uid) {
            return id
        }
        return defaultDeviceID(selector: kAudioHardwarePropertyDefaultOutputDevice)
    }

    private func defaultDeviceID(selector: AudioObjectPropertySelector) -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceID)
        if status != noErr { return AudioDeviceID(0) }
        return deviceID
    }

    private func makeLinearPCMFormat(sampleRate: Double, channels: Int) -> AudioStreamBasicDescription {
        let bytesPerFrame = UInt32(channels * 2)
        return AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: bytesPerFrame,
            mFramesPerPacket: 1,
            mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 16,
            mReserved: 0
        )
    }

    private func createHALOutputUnit(deviceID: AudioDeviceID) -> AudioComponentInstance? {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let comp = AudioComponentFindNext(nil, &desc) else { return nil }

        var unit: AudioComponentInstance?
        var status = AudioComponentInstanceNew(comp, &unit)
        guard status == noErr, let unit else { return nil }

        var enableIO: UInt32 = 1
        status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &enableIO, UInt32(MemoryLayout<UInt32>.size))
        guard status == noErr else { AudioComponentInstanceDispose(unit); return nil }

        var disableInput: UInt32 = 0
        status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &disableInput, UInt32(MemoryLayout<UInt32>.size))
        guard status == noErr else { AudioComponentInstanceDispose(unit); return nil }

        var device = deviceID
        status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else { AudioComponentInstanceDispose(unit); return nil }

        return unit
    }

    private func createHALInputUnit(deviceID: AudioDeviceID) -> AudioComponentInstance? {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let comp = AudioComponentFindNext(nil, &desc) else { return nil }

        var unit: AudioComponentInstance?
        var status = AudioComponentInstanceNew(comp, &unit)
        guard status == noErr, let unit else { return nil }

        var enableInput: UInt32 = 1
        status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enableInput, UInt32(MemoryLayout<UInt32>.size))
        guard status == noErr else { AudioComponentInstanceDispose(unit); return nil }

        var disableOutput: UInt32 = 0
        status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &disableOutput, UInt32(MemoryLayout<UInt32>.size))
        guard status == noErr else { AudioComponentInstanceDispose(unit); return nil }

        var device = deviceID
        status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else { AudioComponentInstanceDispose(unit); return nil }

        return unit
    }

    private func allocateInputBufferIfNeeded(sampleRate: Double) {
        let framesPerBuffer = max(UInt32(sampleRate * inputIOBufferDurationValue), 256)
        inputBufferCapacityFrames = max(framesPerBuffer, 4096)
        let bytes = Int(inputBufferCapacityFrames) * inputChannels * MemoryLayout<Int16>.size

        inputBufferData?.deallocate()
        inputBufferData = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: MemoryLayout<Int16>.alignment)

        inputBufferList?.deallocate()
        inputBufferList = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
        inputBufferList?.pointee.mNumberBuffers = 1
        inputBufferList?.pointee.mBuffers.mNumberChannels = UInt32(inputChannels)
        inputBufferList?.pointee.mBuffers.mDataByteSize = UInt32(bytes)
        inputBufferList?.pointee.mBuffers.mData = inputBufferData
    }
}

private func playoutRenderCallback(
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber: UInt32,
    inNumberFrames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    let device = Unmanaged<WebRTCAudioDevice>.fromOpaque(inRefCon).takeUnretainedValue()
    guard let delegate = device.delegate, let ioData else { return noErr }
    return delegate.getPlayoutData(ioActionFlags, inTimeStamp, Int(inBusNumber), inNumberFrames, ioData)
}

private func recordingInputCallback(
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber: UInt32,
    inNumberFrames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    let device = Unmanaged<WebRTCAudioDevice>.fromOpaque(inRefCon).takeUnretainedValue()
    guard let unit = device.inputUnit, let delegate = device.delegate, let bufferList = device.inputBufferList else { return noErr }

    var flags = AudioUnitRenderActionFlags(rawValue: 0)
    let status = AudioUnitRender(unit, &flags, inTimeStamp, 1, inNumberFrames, bufferList)
    if status != noErr { return status }

    let inputPtr: UnsafePointer<AudioBufferList> = UnsafePointer(bufferList)
    return delegate.deliverRecordedData(ioActionFlags, inTimeStamp, Int(inBusNumber), inNumberFrames, inputPtr, nil, nil)
}
