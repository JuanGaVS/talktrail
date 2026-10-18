import AVFoundation
import CoreAudio

/// Captures everything the Mac plays (the remote side of a call) through a Core Audio process tap.
///
/// Tools that process call audio usually install a virtual speaker driver that meeting apps must select.
/// A process tap needs no driver: it is attached to a private aggregate device that only this process
/// can see, so meeting apps keep using the real speakers and microphone.
public final class SystemAudioCapture: @unchecked Sendable {
    /// Receives each captured buffer and the host time of its first frame. The buffer is only valid
    /// during the call.
    public typealias BufferHandler = (AVAudioPCMBuffer, UInt64) -> Void

    private let controlQueue = DispatchQueue(label: "talktrail.system-audio.control")
    private let ioQueue = DispatchQueue(label: "talktrail.system-audio.io", qos: .userInteractive)
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var format: AVAudioFormat?
    private var handler: BufferHandler?
    private var outputDeviceListener: AudioObjectPropertyListenerBlock?

    public init() {}

    public func start(handler: @escaping BufferHandler) throws {
        try controlQueue.sync {
            self.handler = handler
            try startTap()
            listenForOutputDeviceChanges()
        }
    }

    public func stop() {
        controlQueue.sync {
            stopListeningForOutputDeviceChanges()
            stopTap()
            handler = nil
        }
    }

    // MARK: - Tap lifecycle (controlQueue)

    private func startTap() throws {
        do {
            let ownProcess = Self.processObject(for: getpid())
            let description = CATapDescription(stereoGlobalTapButExcludeProcesses: ownProcess.map { [$0] } ?? [])
            description.name = "talktrail"
            description.isPrivate = true
            description.muteBehavior = .unmuted
            try check(AudioHardwareCreateProcessTap(description, &tapID), localized("create the system audio tap"))

            // The default output device only provides the clock; the global tap hears every process
            // regardless of the device it plays to.
            let outputUID = try Self.defaultOutputDeviceUID()
            let aggregate: [String: Any] = [
                kAudioAggregateDeviceNameKey: "talktrail capture",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceMainSubDeviceKey: outputUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                ]],
            ]
            try check(
                AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID),
                localized("create the aggregate device")
            )

            var streamDescription = try Self.tapFormat(tapID)
            guard let format = AVAudioFormat(streamDescription: &streamDescription) else {
                throw TalktrailError.coreAudio(kAudioHardwareUnsupportedOperationError, localized("read the tap format"))
            }
            self.format = format

            try check(
                AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, ioQueue) { [weak self] _, input, inputTime, _, _ in
                    self?.deliver(input, at: inputTime)
                },
                localized("register the audio callback")
            )
            // The first start triggers the "System Audio Recording" permission prompt. Without
            // permission the tap delivers silence instead of failing.
            try check(AudioDeviceStart(aggregateID, ioProcID), localized("start capturing system audio"))
        } catch {
            stopTap()
            throw error
        }
    }

    private func stopTap() {
        if aggregateID != kAudioObjectUnknown {
            if let ioProcID {
                AudioDeviceStop(aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        ioProcID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        format = nil
    }

    /// The aggregate device is clocked by the output device that was the default when it was built, so it
    /// is rebuilt when the user switches outputs (e.g. connects headphones mid-call).
    private func listenForOutputDeviceChanges() {
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, self.handler != nil else { return }
            self.stopTap()
            try? self.startTap()
        }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, controlQueue, listener) == noErr {
            outputDeviceListener = listener
        }
    }

    private func stopListeningForOutputDeviceChanges() {
        guard let listener = outputDeviceListener else { return }
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, controlQueue, listener)
        outputDeviceListener = nil
    }

    // MARK: - IO (ioQueue)

    private func deliver(_ input: UnsafePointer<AudioBufferList>, at time: UnsafePointer<AudioTimeStamp>) {
        guard let format, let handler,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil),
              buffer.frameLength > 0
        else { return }
        let hostTime = time.pointee.mFlags.contains(.hostTimeValid) ? time.pointee.mHostTime : mach_absolute_time()
        handler(buffer, hostTime)
    }

    // MARK: - Core Audio properties

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func processObject(for pid: pid_t) -> AudioObjectID? {
        var address = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address,
            UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object
        )
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    private static func defaultOutputDeviceUID() throws -> String {
        var address = address(kAudioHardwarePropertyDefaultOutputDevice)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try check(
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device),
            localized("read the default output device")
        )

        address = Self.address(kAudioDevicePropertyDeviceUID)
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try check(
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid),
            localized("read the output device UID")
        )
        guard let uid else { throw TalktrailError.coreAudio(kAudioHardwareBadDeviceError, localized("read the output device UID")) }
        return uid.takeRetainedValue() as String
    }

    private static func tapFormat(_ tap: AudioObjectID) throws -> AudioStreamBasicDescription {
        var address = address(kAudioTapPropertyFormat)
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &format), localized("read the tap format"))
        return format
    }
}
