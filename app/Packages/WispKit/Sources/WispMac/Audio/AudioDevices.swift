import WispCore
import CoreAudio
import Foundation

/// Minimal Core Audio device queries used to pick the microphone.
public enum AudioDevices {
    public struct Device: Equatable, Sendable {
        public var id: AudioDeviceID
        /// Stable across reboots and reconnects (the numeric id is not); what settings store.
        public var uid: String
        public var name: String
        public var transport: UInt32
        public var isBluetooth: Bool {
            transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
        }
        public var isBuiltIn: Bool { transport == kAudioDeviceTransportTypeBuiltIn }
    }

    public static func defaultInput() -> Device? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr,
              id != 0 else { return nil }
        return device(id)
    }

    public static func defaultOutput() -> Device? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr,
              id != 0 else { return nil }
        return device(id)
    }

    /// All devices that have at least one input stream.
    public static func inputs() -> [Device] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.filter(hasInput).compactMap(device)
    }

    /// The microphone to record from. When the default input is a Bluetooth headset and a built-in
    /// microphone exists, the built-in one is used so the headset keeps high-quality playback
    /// (opening a Bluetooth mic switches it to the low-quality call profile).
    /// - Parameter chosenUID: the microphone picked in Settings; used whenever it is connected.
    public static func preferredInput(chosenUID: String? = nil, preferBuiltInOverBluetooth: Bool = true) -> Device? {
        if let chosenUID, let chosen = inputs().first(where: { $0.uid == chosenUID }) { return chosen }
        guard let current = defaultInput() else { return nil }
        if preferBuiltInOverBluetooth && current.isBluetooth, let builtIn = inputs().first(where: \.isBuiltIn) {
            return builtIn
        }
        return current
    }

    /// True when another app is recording from a microphone right now (a call, a voice memo, dictation), not
    /// counting macOS's own background listeners (`CallDetection`). Asks
    /// macOS which processes are running audio input (not just whether a device is busy: a headset's device is
    /// busy whenever music plays through it). Wisp itself is never counted.
    public static func inputInUseElsewhere() -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr, size > 0 else { return false }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &objects) == noErr else { return false }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return objects.contains { object in
            var pid: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            var pidAddress = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID, mScope: kAudioObjectPropertyScopeGlobal,
                                                        mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(object, &pidAddress, 0, nil, &pidSize, &pid) == noErr, pid != ownPID else { return false }
            // macOS's own always-on listeners (Siri, dictation…) hold the microphone but aren't a call.
            var bundle: CFString = "" as CFString
            var bundleSize = UInt32(MemoryLayout<CFString>.size)
            var bundleAddress = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID, mScope: kAudioObjectPropertyScopeGlobal,
                                                           mElement: kAudioObjectPropertyElementMain)
            let bundleID = AudioObjectGetPropertyData(object, &bundleAddress, 0, nil, &bundleSize, &bundle) == noErr ? bundle as String : nil
            guard CallDetection.countsAsCall(bundleID: bundleID) else { return false }
            var running: UInt32 = 0
            var runningSize = UInt32(MemoryLayout<UInt32>.size)
            var runningAddress = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningInput, mScope: kAudioObjectPropertyScopeGlobal,
                                                            mElement: kAudioObjectPropertyElementMain)
            return AudioObjectGetPropertyData(object, &runningAddress, 0, nil, &runningSize, &running) == noErr && running != 0
        }
    }

    private static func device(_ id: AudioDeviceID) -> Device? {
        Device(id: id, uid: stringProperty(id, kAudioDevicePropertyDeviceUID) ?? "\(id)",
               name: stringProperty(id, kAudioObjectPropertyName) ?? "Unknown", transport: transportType(id))
    }

    private static func hasInput(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                 mScope: kAudioDevicePropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func transportType(_ id: AudioDeviceID) -> UInt32 {
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        _ = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)
        return value
    }

    private static func stringProperty(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
