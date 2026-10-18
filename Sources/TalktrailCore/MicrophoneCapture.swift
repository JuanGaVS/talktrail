import AVFoundation

/// Captures the default input device (the local side of a call).
///
/// macOS lets several apps read the same microphone, so this runs alongside Zoom, Teams or Meet without
/// the user having to pick a virtual device in them.
public final class MicrophoneCapture: @unchecked Sendable {
    /// Receives each captured buffer and the host time of its first frame.
    public typealias BufferHandler = (AVAudioPCMBuffer, UInt64) -> Void

    private let engine = AVAudioEngine()
    private var configurationObserver: NSObjectProtocol?

    public init() {}

    public static func requestAccess() async throws {
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            throw TalktrailError.microphoneAccessDenied
        }
    }

    public func start(handler: @escaping BufferHandler) throws {
        try installTapAndStart(handler)
        // The engine stops when the input device changes (headset plugged in, AirPods connected...).
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            try? self?.installTapAndStart(handler)
        }
    }

    public func stop() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        configurationObserver = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    private func installTapAndStart(_ handler: @escaping BufferHandler) throws {
        engine.stop()
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw TalktrailError.noInputDevice }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, time in
            handler(buffer, time.isHostTimeValid ? time.hostTime : mach_absolute_time())
        }
        engine.prepare()
        try engine.start()
    }
}
