import Foundation
import CoreAudio

struct CoreAudioDeviceInfo: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let hasInput: Bool
    let hasOutput: Bool
}

enum CoreAudioDevices {
    private static func getStringProperty(objectID: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &dataSize)
        guard status == noErr, dataSize > 0 else { return nil }

        var cfString: CFString?
        status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &dataSize, &cfString)
        guard status == noErr else { return nil }
        return cfString as String?
    }

    private static func deviceHasStreamConfiguration(deviceID: AudioDeviceID, scope: AudioObjectPropertyScope) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize)
        guard status == noErr, dataSize > 0 else { return false }

        let bufferListPointer = UnsafeMutableRawPointer.allocate(byteCount: Int(dataSize), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { bufferListPointer.deallocate() }

        var mutableSize = dataSize
        let status2 = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &mutableSize, bufferListPointer)
        guard status2 == noErr else { return false }

        let ablPtr = bufferListPointer.assumingMemoryBound(to: AudioBufferList.self)
        let buffers = UnsafeMutableAudioBufferListPointer(ablPtr)
        for buffer in buffers {
            if buffer.mNumberChannels > 0 {
                return true
            }
        }

        return false
    }

    static func listDevices() -> [CoreAudioDeviceInfo] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize)
        guard status == noErr else { return [] }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.stride
        var deviceIDs = Array(repeating: AudioDeviceID(0), count: deviceCount)
        status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceIDs)
        guard status == noErr else { return [] }

        return deviceIDs.compactMap { deviceID in
            guard let uid = getStringProperty(objectID: deviceID, selector: kAudioDevicePropertyDeviceUID),
                  let name = getStringProperty(objectID: deviceID, selector: kAudioObjectPropertyName) else {
                return nil
            }

            let hasInput = deviceHasStreamConfiguration(deviceID: deviceID, scope: kAudioDevicePropertyScopeInput)
            let hasOutput = deviceHasStreamConfiguration(deviceID: deviceID, scope: kAudioDevicePropertyScopeOutput)

            return CoreAudioDeviceInfo(id: deviceID, uid: uid, name: name, hasInput: hasInput, hasOutput: hasOutput)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func listInputDevices() -> [CoreAudioDeviceInfo] {
        listDevices().filter { $0.hasInput }
    }

    static func listOutputDevices() -> [CoreAudioDeviceInfo] {
        listDevices().filter { $0.hasOutput }
    }

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        listDevices().first(where: { $0.uid == uid })?.id
    }
}
