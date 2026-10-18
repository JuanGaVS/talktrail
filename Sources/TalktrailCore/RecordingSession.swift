import AVFoundation

/// Records a call (microphone + everything the Mac plays) and transcribes it into a local file.
///
/// While the call runs, phrases are appended to a draft in the user's temporary folder, labelled by
/// channel. When it stops, the remote audio is diarized on the device, each remote phrase is attributed to
/// "Speaker 1", "Speaker 2"…, the final transcript is written and the draft and temporary audio are deleted.
public final class RecordingSession: @unchecked Sendable {
    public struct Configuration: Sendable {
        public var locale: Locale
        public var outputDirectory: URL
        public var captureMicrophone = true
        public var captureSystemAudio = true
        /// Tell the remote participants apart after the call.
        public var identifySpeakers = true
        public var microphoneLabel = localized("Me")
        public var systemAudioLabel = localized("Remote")
        public var speakerLabel = localized("Speaker")

        public init(locale: Locale, outputDirectory: URL = Self.defaultOutputDirectory) {
            self.locale = locale
            self.outputDirectory = outputDirectory
        }

        /// `~/Documents/Transcripts`, with the folder name in the user's language.
        public static var defaultOutputDirectory: URL {
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Documents", isDirectory: true)
                .appendingPathComponent(localized("Transcripts"), isDirectory: true)
        }
    }

    public let configuration: Configuration
    private let onLine: @Sendable (String) -> Void
    private let onStatus: @Sendable (String) -> Void
    private var microphone: MicrophoneCapture?
    private var systemAudio: SystemAudioCapture?
    private var channels: [ChannelTranscriber] = []
    private var systemChannel: ChannelTranscriber?
    private var transcript: TranscriptFile?
    private var locale: Locale?
    private var flushTask: Task<Void, Never>?

    /// - Parameters:
    ///   - onLine: Called with each transcript line as it is written to the draft.
    ///   - onStatus: Called with progress and warning messages.
    public init(
        configuration: Configuration,
        onLine: @escaping @Sendable (String) -> Void,
        onStatus: @escaping @Sendable (String) -> Void
    ) {
        self.configuration = configuration
        self.onLine = onLine
        self.onStatus = onStatus
    }

    /// Starts capturing and returns the draft being written.
    public func start() async throws -> URL {
        do {
            return try await startCapturing()
        } catch {
            await stop(discarding: true)
            throw error
        }
    }

    /// Stops capturing, identifies the speakers and returns the final transcript (nil if none was started).
    @discardableResult
    public func stop() async -> URL? {
        await stop(discarding: false)
    }

    @discardableResult
    private func stop(discarding: Bool) async -> URL? {
        microphone?.stop()
        systemAudio?.stop()
        microphone = nil
        systemAudio = nil
        await withTaskGroup(of: Void.self) { group in
            for channel in channels {
                group.addTask { await channel.finish() }
            }
        }
        flushTask?.cancel()
        defer {
            systemChannel?.recording?.delete()
            channels = []
            systemChannel = nil
            transcript = nil
        }
        guard let transcript else { return nil }

        let draft = transcript.url
        let format = transcript.format
        var segments = await transcript.close()
        let end = Date()
        if discarding {
            try? FileManager.default.removeItem(at: draft)
            return nil
        }

        var participants = configuration.systemAudioLabel
        if let channel = systemChannel, let recording = channel.recording {
            participants = await SpeakerDiarization.identifySpeakers(
                in: recording.url, segments: &segments, channel: configuration.systemAudioLabel,
                offset: channel.origin, label: configuration.speakerLabel, onStatus: onStatus
            ) ?? participants
        }

        var channelsField: [String] = []
        if configuration.captureMicrophone { channelsField.append(localized("%@ (microphone)", configuration.microphoneLabel)) }
        if configuration.captureSystemAudio { channelsField.append(localized("%@ (call audio)", participants)) }
        do {
            let url = try TranscriptStorage.write(
                segments, format: format, title: localized("Transcript"),
                fields: [
                    (localized("Language"), locale?.identifier ?? ""),
                    (localized("Participants"), channelsField.joined(separator: " · ")),
                ],
                end: end, in: configuration.outputDirectory
            )
            try? FileManager.default.removeItem(at: draft)
            return url
        } catch {
            onStatus(localized("Error: %@. The draft is kept at %@", error.localizedDescription, draft.path))
            return draft
        }
    }

    private func startCapturing() async throws -> URL {
        let config = configuration
        AudioRecording.removeLeftovers()
        for url in TranscriptStorage.recoverDrafts(into: config.outputDirectory) {
            onStatus(localized("Recovered an unfinished transcript from a previous session: %@", url.lastPathComponent))
        }
        let locale = try await SpeechModel.prepare(config.locale, onStatus: onStatus)
        self.locale = locale
        if config.captureMicrophone {
            try await MicrophoneCapture.requestAccess()
        }

        var sources: [String] = []
        if config.captureMicrophone { sources.append(localized("%@ = microphone", config.microphoneLabel)) }
        if config.captureSystemAudio { sources.append(localized("%@ = system audio", config.systemAudioLabel)) }
        let sessionHostTime = mach_absolute_time()
        let format = TranscriptFormat(start: Date(), clock: .wallClock)
        let transcript = try TranscriptFile(
            directory: TranscriptStorage.draftsDirectory,
            format: format,
            name: format.fileName(),
            title: localized("Transcript (live draft)"),
            fields: [(localized("Language"), locale.identifier), (localized("Channels"), sources.joined(separator: " · "))],
            echoFilter: config.captureMicrophone && config.captureSystemAudio
                ? .init(microphone: config.microphoneLabel, systemAudio: config.systemAudioLabel)
                : nil,
            onLine: onLine
        )
        self.transcript = transcript

        let sessionTime = { (hostTime: UInt64) in
            AVAudioTime.seconds(forHostTime: hostTime) - AVAudioTime.seconds(forHostTime: sessionHostTime)
        }

        if config.captureMicrophone {
            let channel = try await ChannelTranscriber(
                label: config.microphoneLabel, locale: locale, transcript: transcript, onStatus: onStatus
            )
            channels.append(channel)
            let meter = LevelMeter(label: config.microphoneLabel, report: onStatus)
            let microphone = MicrophoneCapture()
            self.microphone = microphone
            try microphone.start { buffer, hostTime in
                meter?.inspect(buffer)
                channel.append(buffer, at: sessionTime(hostTime))
            }
        }

        if config.captureSystemAudio {
            let channel = try await ChannelTranscriber(
                label: config.systemAudioLabel, locale: locale, transcript: transcript,
                recordsAudio: config.identifySpeakers, onStatus: onStatus
            )
            channels.append(channel)
            systemChannel = channel
            let monitor = SilenceMonitor(after: 45) { [onStatus] in
                onStatus(localized("Warning: the system audio is still silent. If something has played already, check System Settings > Privacy & Security > Screen & System Audio Recording."))
            }
            let meter = LevelMeter(label: config.systemAudioLabel, report: onStatus)
            let systemAudio = SystemAudioCapture()
            self.systemAudio = systemAudio
            try systemAudio.start { buffer, hostTime in
                monitor.inspect(buffer)
                meter?.inspect(buffer)
                channel.append(buffer, at: sessionTime(hostTime))
            }
        }

        flushTask = Task {
            // Releases held phrases when one side stays silent for a long time.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                await transcript.flush()
            }
        }
        return transcript.url
    }
}

/// With `TALKTRAIL_DEBUG=1`, reports each channel's peak level every few seconds to troubleshoot capture.
private final class LevelMeter: @unchecked Sendable {
    private let label: String
    private let report: @Sendable (String) -> Void
    private var peak: Float = 0
    private var buffers = 0
    private var lastReport = Date()

    init?(label: String, report: @escaping @Sendable (String) -> Void) {
        guard ProcessInfo.processInfo.environment["TALKTRAIL_DEBUG"] == "1" else { return nil }
        self.label = label
        self.report = report
    }

    func inspect(_ buffer: AVAudioPCMBuffer) {
        buffers += 1
        peak = max(peak, buffer.peak)
        let now = Date()
        guard now.timeIntervalSince(lastReport) >= 3 else { return }
        let decibels = peak > 0 ? String(format: "%.0f dBFS", 20 * log10(peak)) : "silence"
        report("[debug] \(label): \(buffers) buffers, \(buffer.format.sampleRate) Hz × \(buffer.format.channelCount), peak \(decibels)")
        peak = 0
        buffers = 0
        lastReport = now
    }
}

/// Warns once if a source has delivered nothing but digital silence for a while, which is what a process
/// tap does when the system-audio permission is missing.
private final class SilenceMonitor: @unchecked Sendable {
    private let limit: TimeInterval
    private let warn: () -> Void
    private var firstBuffer: Date?
    private var done = false

    init(after limit: TimeInterval, warn: @escaping () -> Void) {
        self.limit = limit
        self.warn = warn
    }

    func inspect(_ buffer: AVAudioPCMBuffer) {
        guard !done else { return }
        let now = Date()
        let start = firstBuffer ?? now
        firstBuffer = start
        if buffer.containsSignal {
            done = true
        } else if now.timeIntervalSince(start) > limit {
            done = true
            warn()
        }
    }
}

private extension AVAudioPCMBuffer {
    var containsSignal: Bool {
        floatChannelData == nil || peak > 0
    }

    /// Largest absolute sample value (0...1) for float buffers; 0 for other formats.
    var peak: Float {
        guard let channels = floatChannelData else { return 0 }
        let samples = Int(frameLength) * (format.isInterleaved ? Int(format.channelCount) : 1)
        let channelCount = format.isInterleaved ? 1 : Int(format.channelCount)
        var peak: Float = 0
        for channel in 0..<channelCount {
            for index in 0..<samples {
                peak = max(peak, abs(channels[channel][index]))
            }
        }
        return peak
    }
}
