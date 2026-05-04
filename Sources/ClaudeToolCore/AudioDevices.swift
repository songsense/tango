import Foundation
import CoreAudio
import AVFoundation

public struct AudioInputDevice: Sendable, Hashable, Identifiable {
    public let id: AudioDeviceID
    public let name: String
    public let uid: String
    public let isDefault: Bool

    public init(id: AudioDeviceID, name: String, uid: String, isDefault: Bool) {
        self.id = id
        self.name = name
        self.uid = uid
        self.isDefault = isDefault
    }
}

public enum AudioDevices {
    /// Enumerate all input-capable audio devices currently visible to Core Audio.
    public static func listInputDevices() -> [AudioInputDevice] {
        let defaultID = currentDefaultInputDevice()
        let allIDs = allDeviceIDs()
        var devices: [AudioInputDevice] = []
        for id in allIDs {
            guard hasInputStreams(deviceID: id) else { continue }
            let name = stringProperty(deviceID: id, selector: kAudioObjectPropertyName) ?? "Device \(id)"
            let uid = stringProperty(deviceID: id, selector: kAudioDevicePropertyDeviceUID) ?? ""
            devices.append(AudioInputDevice(id: id, name: name, uid: uid, isDefault: id == defaultID))
        }
        return devices.sorted { lhs, rhs in
            if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    /// Find a device by its CoreAudio UID (stable across reboots).
    public static func device(forUID uid: String) -> AudioInputDevice? {
        listInputDevices().first { $0.uid == uid }
    }

    /// Set the input device for an AVAudioEngine. Must be called BEFORE
    /// engine.start(); changes after start are ignored by AVAudioEngine.
    @discardableResult
    public static func setInputDevice(_ deviceID: AudioDeviceID, on engine: AVAudioEngine) -> OSStatus {
        guard let unit = engine.inputNode.audioUnit else { return -1 }
        var devID = deviceID
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        return AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &devID,
            size
        )
    }

    /// Returns the device ID currently bound to an engine's input node, or nil.
    public static func currentInputDevice(on engine: AVAudioEngine) -> AudioDeviceID? {
        guard let unit = engine.inputNode.audioUnit else { return nil }
        var devID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitGetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &devID,
            &size
        )
        return status == noErr ? devID : nil
    }

    public static func currentDefaultInputDevice() -> AudioDeviceID {
        var devID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &devID
        )
        return devID
    }

    public static func name(forDeviceID id: AudioDeviceID) -> String? {
        guard id != 0 else { return nil }
        return stringProperty(deviceID: id, selector: kAudioObjectPropertyName)
    }

    // MARK: - Internals

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var size: UInt32 = 0
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size
        )
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: count)
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids
        )
        return ids
    }

    private static func hasInputStreams(deviceID: AudioDeviceID) -> Bool {
        var size: UInt32 = 0
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &size)
        return size > 0
    }

    private static func stringProperty(deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = UInt32(MemoryLayout<CFString?>.size)
        var cfStr: Unmanaged<CFString>?
        let status = AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &cfStr)
        guard status == noErr, let value = cfStr?.takeRetainedValue() else { return nil }
        return value as String
    }
}
