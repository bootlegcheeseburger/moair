import Foundation
import CoreAudio
import AudioToolbox

enum CoreAudioBridge {
    static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids
        ) == noErr else { return [] }
        return ids
    }

    static func hasOutputStreams(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr else { return false }
        return size > 0
    }

    static func defaultOutputDeviceID() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceID
        )
        return status == noErr ? deviceID : nil
    }

    @discardableResult
    static func setDefaultOutputDevice(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = id
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size), &deviceID
        )
        return status == noErr
    }

    static func deviceUID(_ id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString?>.size)
        var uid: CFString?
        let status = withUnsafeMutablePointer(to: &uid) { ptr in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, ptr)
        }
        return status == noErr ? (uid as String?) : nil
    }

    static func deviceName(_ id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString?>.size)
        var name: CFString?
        let status = withUnsafeMutablePointer(to: &name) { ptr in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, ptr)
        }
        return status == noErr ? (name as String?) : nil
    }

    /// Current data source for the output side of the device, if it
    /// publishes one. AirPods Max appears to expose distinct sources for
    /// the BT path vs the USB-C wired path — the canWriteVolumeDecibels
    /// flag is too sticky to use as a live signal, but the data source
    /// flips cleanly on plug/unplug.
    static func currentOutputDataSource(_ id: AudioDeviceID) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDataSource,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(id, &address) else { return nil }
        var src: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &src)
        return status == noErr ? src : nil
    }

    /// Human-readable name for a given source ID, if available.
    static func dataSourceName(_ id: AudioDeviceID, source: UInt32) -> String? {
        var src = source
        var name: Unmanaged<CFString>?
        var translation = withUnsafeMutablePointer(to: &src) { srcPtr in
            withUnsafeMutablePointer(to: &name) { namePtr in
                AudioValueTranslation(
                    mInputData: UnsafeMutableRawPointer(srcPtr),
                    mInputDataSize: UInt32(MemoryLayout<UInt32>.size),
                    mOutputData: UnsafeMutableRawPointer(namePtr),
                    mOutputDataSize: UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
                )
            }
        }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDataSourceNameForIDCFString,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(id, &address) else { return nil }
        var size = UInt32(MemoryLayout<AudioValueTranslation>.size)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &translation)
        guard status == noErr, let cf = name?.takeRetainedValue() else { return nil }
        return cf as String
    }

    /// Decode a CoreAudio FourCC `UInt32` back to its 4-character string
    /// (e.g. `0x626C7565` → `"blue"`). Handy for logging unknown source
    /// codes so we can map them to BT vs USB by inspection.
    static func fourCC(_ v: UInt32) -> String {
        let bytes: [UInt8] = [
            UInt8((v >> 24) & 0xFF),
            UInt8((v >> 16) & 0xFF),
            UInt8((v >>  8) & 0xFF),
            UInt8( v        & 0xFF),
        ]
        let chars: [Character] = bytes.map { b in
            // ASCII printable range; everything else becomes '.' so the
            // resulting string is always safe to log.
            (b >= 0x20 && b <= 0x7E) ? Character(UnicodeScalar(b)) : "."
        }
        return String(chars)
    }

    /// Device-side I/O latency in samples (output scope). Useful as a
    /// distinguisher between BT and USB paths when other properties are
    /// sticky — USB AC has dramatically lower latency than AVRCP/BT.
    static func outputLatencySamples(_ id: AudioDeviceID) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyLatency,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(id, &address) else { return nil }
        var latency: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &latency)
        return status == noErr ? latency : nil
    }

    /// Number of output streams the device exposes. May flip when a USB
    /// substream is added/removed on AirPods Max plug/unplug.
    static func outputStreamCount(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(id, &address) else { return 0 }
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr else { return 0 }
        return Int(size) / MemoryLayout<AudioStreamID>.size
    }

    static func transportType(_ id: AudioDeviceID) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<UInt32>.size)
        var transport = UInt32(0)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &transport)
        return status == noErr ? transport : nil
    }

    static func virtualFormat(_ id: AudioDeviceID, scope: AudioObjectPropertyScope = kAudioDevicePropertyScopeOutput) -> AudioStreamBasicDescription? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &format)
        return status == noErr ? format : nil
    }

    static func deviceLatency(_ id: AudioDeviceID, scope: AudioObjectPropertyScope = kAudioDevicePropertyScopeOutput) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyLatency,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var latency = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &latency)
        return status == noErr ? latency : nil
    }

    static func safetyOffset(_ id: AudioDeviceID, scope: AudioObjectPropertyScope = kAudioDevicePropertyScopeOutput) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertySafetyOffset,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var offset = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &offset)
        return status == noErr ? offset : nil
    }

    static func bufferFrameSize(_ id: AudioDeviceID, scope: AudioObjectPropertyScope = kAudioDevicePropertyScopeOutput) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var frames = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &frames)
        return status == noErr ? frames : nil
    }

    static func streamLatency(_ id: AudioDeviceID, scope: AudioObjectPropertyScope = kAudioDevicePropertyScopeOutput) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr else { return 0 }
        let count = Int(size) / MemoryLayout<AudioStreamID>.size
        guard count > 0 else { return 0 }
        var streams = [AudioStreamID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &streams) == noErr else { return 0 }

        var streamLatencyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioStreamPropertyLatency,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var total: UInt32 = 0
        for stream in streams {
            var latency: UInt32 = 0
            var s = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(stream, &streamLatencyAddress, 0, nil, &s, &latency) == noErr {
                total += latency
            }
        }
        return total
    }

    static func outputVolumeScalar(_ id: AudioDeviceID) -> Float? {
        let scopes: [AudioObjectPropertyScope] = [kAudioDevicePropertyScopeOutput, kAudioObjectPropertyScopeGlobal]
        let elements: [AudioObjectPropertyElement] = [kAudioObjectPropertyElementMain, 1, 2]
        for scope in scopes {
            for element in elements {
                var address = AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyVolumeScalar,
                    mScope: scope,
                    mElement: element
                )
                if AudioObjectHasProperty(id, &address) {
                    var volume: Float = 0
                    var size = UInt32(MemoryLayout<Float>.size)
                    if AudioObjectGetPropertyData(id, &address, 0, nil, &size, &volume) == noErr {
                        return volume
                    }
                }
            }
        }
        return nil
    }

    @discardableResult
    static func setOutputVolumeScalar(_ id: AudioDeviceID, _ value: Float) -> Bool {
        let clamped = max(0, min(1, value))
        let scopes: [AudioObjectPropertyScope] = [kAudioDevicePropertyScopeOutput, kAudioObjectPropertyScopeGlobal]
        let elements: [AudioObjectPropertyElement] = [kAudioObjectPropertyElementMain, 1, 2]
        var anySet = false
        for scope in scopes {
            for element in elements {
                var address = AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyVolumeScalar,
                    mScope: scope,
                    mElement: element
                )
                if AudioObjectHasProperty(id, &address) {
                    var v = clamped
                    if AudioObjectSetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<Float>.size), &v) == noErr {
                        anySet = true
                    }
                }
            }
        }
        return anySet
    }

    /// Convert dB to a scalar (0…1) using the device's own curve via
    /// `kAudioDevicePropertyVolumeDecibelsToScalar`. Inverse of
    /// `scalarToDecibels`. Lets us drive a dB-stepped slider on devices
    /// where direct dB writes are silently dropped (wired AirPods Max) by
    /// converting the dB target to a scalar and writing that instead.
    static func decibelsToScalar(_ id: AudioDeviceID, decibels: Float) -> Float? {
        let scopes: [AudioObjectPropertyScope] = [kAudioDevicePropertyScopeOutput, kAudioObjectPropertyScopeGlobal]
        let elements: [AudioObjectPropertyElement] = [kAudioObjectPropertyElementMain, 1, 2]
        for scope in scopes {
            for element in elements {
                var address = AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyVolumeDecibelsToScalar,
                    mScope: scope,
                    mElement: element
                )
                if AudioObjectHasProperty(id, &address) {
                    var value = decibels
                    var size = UInt32(MemoryLayout<Float>.size)
                    if AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr {
                        return value
                    }
                }
            }
        }
        return nil
    }

    /// Convert a scalar volume (0…1) to dB using the device's own curve via
    /// `kAudioDevicePropertyVolumeScalarToDecibels`. This is a CoreAudio
    /// "translation" property — the input scalar is written into the value
    /// buffer and `AudioObjectGetPropertyData` replaces it with the dB.
    /// When the device doesn't publish the translation, callers should fall
    /// back to a math approximation (e.g. 20·log10(scalar)).
    static func scalarToDecibels(_ id: AudioDeviceID, scalar: Float) -> Float? {
        let scopes: [AudioObjectPropertyScope] = [kAudioDevicePropertyScopeOutput, kAudioObjectPropertyScopeGlobal]
        let elements: [AudioObjectPropertyElement] = [kAudioObjectPropertyElementMain, 1, 2]
        for scope in scopes {
            for element in elements {
                var address = AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyVolumeScalarToDecibels,
                    mScope: scope,
                    mElement: element
                )
                if AudioObjectHasProperty(id, &address) {
                    var value = scalar
                    var size = UInt32(MemoryLayout<Float>.size)
                    if AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr {
                        return value
                    }
                }
            }
        }
        return nil
    }

    /// Whether `kAudioDevicePropertyVolumeDecibels` exists *and* is writable
    /// on this device. Some headphones (wired AirPods Max in particular)
    /// publish the property and a dB range read-only but silently reject
    /// writes — a calibrated slider bound to such a device looks frozen.
    static func canWriteVolumeDecibels(_ id: AudioDeviceID) -> Bool {
        let scopes: [AudioObjectPropertyScope] = [kAudioDevicePropertyScopeOutput, kAudioObjectPropertyScopeGlobal]
        let elements: [AudioObjectPropertyElement] = [kAudioObjectPropertyElementMain, 1, 2]
        for scope in scopes {
            for element in elements {
                var address = AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyVolumeDecibels,
                    mScope: scope,
                    mElement: element
                )
                guard AudioObjectHasProperty(id, &address) else { continue }
                var settable: DarwinBoolean = false
                if AudioObjectIsPropertySettable(id, &address, &settable) == noErr, settable.boolValue {
                    return true
                }
            }
        }
        return false
    }

    static func outputVolumeDecibels(_ id: AudioDeviceID) -> Float? {
        let scopes: [AudioObjectPropertyScope] = [kAudioDevicePropertyScopeOutput, kAudioObjectPropertyScopeGlobal]
        let elements: [AudioObjectPropertyElement] = [kAudioObjectPropertyElementMain, 1, 2]
        for scope in scopes {
            for element in elements {
                var address = AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyVolumeDecibels,
                    mScope: scope,
                    mElement: element
                )
                if AudioObjectHasProperty(id, &address) {
                    var db: Float = 0
                    var size = UInt32(MemoryLayout<Float>.size)
                    if AudioObjectGetPropertyData(id, &address, 0, nil, &size, &db) == noErr {
                        return db
                    }
                }
            }
        }
        return nil
    }

    @discardableResult
    static func setOutputVolumeDecibels(_ id: AudioDeviceID, _ db: Float) -> Bool {
        let scopes: [AudioObjectPropertyScope] = [kAudioDevicePropertyScopeOutput, kAudioObjectPropertyScopeGlobal]
        let elements: [AudioObjectPropertyElement] = [kAudioObjectPropertyElementMain, 1, 2]
        var anySet = false
        for scope in scopes {
            for element in elements {
                var address = AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyVolumeDecibels,
                    mScope: scope,
                    mElement: element
                )
                if AudioObjectHasProperty(id, &address) {
                    var v = db
                    if AudioObjectSetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<Float>.size), &v) == noErr {
                        anySet = true
                    }
                }
            }
        }
        return anySet
    }

    static func decibelRange(_ id: AudioDeviceID) -> (min: Float, max: Float)? {
        let scopes: [AudioObjectPropertyScope] = [kAudioDevicePropertyScopeOutput, kAudioObjectPropertyScopeGlobal]
        let elements: [AudioObjectPropertyElement] = [kAudioObjectPropertyElementMain, 1, 2]
        for scope in scopes {
            for element in elements {
                var address = AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyVolumeRangeDecibels,
                    mScope: scope,
                    mElement: element
                )
                if AudioObjectHasProperty(id, &address) {
                    var range = AudioValueRange()
                    var size = UInt32(MemoryLayout<AudioValueRange>.size)
                    if AudioObjectGetPropertyData(id, &address, 0, nil, &size, &range) == noErr {
                        return (Float(range.mMinimum), Float(range.mMaximum))
                    }
                }
            }
        }
        return nil
    }

    static func transportLabel(_ raw: UInt32?) -> String {
        guard let raw else { return "Unknown" }
        switch raw {
        case kAudioDeviceTransportTypeBuiltIn: return "Built-in"
        case kAudioDeviceTransportTypeAggregate: return "Aggregate"
        case kAudioDeviceTransportTypeVirtual: return "Virtual"
        case kAudioDeviceTransportTypePCI: return "PCI"
        case kAudioDeviceTransportTypeUSB: return "USB"
        case kAudioDeviceTransportTypeFireWire: return "FireWire"
        case kAudioDeviceTransportTypeBluetooth: return "Bluetooth"
        case kAudioDeviceTransportTypeBluetoothLE: return "Bluetooth LE"
        case kAudioDeviceTransportTypeHDMI: return "HDMI"
        case kAudioDeviceTransportTypeDisplayPort: return "DisplayPort"
        case kAudioDeviceTransportTypeAirPlay: return "AirPlay"
        case kAudioDeviceTransportTypeAVB: return "AVB"
        case kAudioDeviceTransportTypeThunderbolt: return "Thunderbolt"
        case kAudioDeviceTransportTypeContinuityCaptureWired: return "Continuity (Wired)"
        case kAudioDeviceTransportTypeContinuityCaptureWireless: return "Continuity (Wireless)"
        default: return "Other"
        }
    }
}
