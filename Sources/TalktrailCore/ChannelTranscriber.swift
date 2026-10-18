import AVFoundation
import Speech

/// On-device speech models. Apple downloads a model once per language; audio never leaves the Mac.
public enum SpeechModel {
    public static func supportedLocales() async -> [Locale] {
        await SpeechTranscriber.supportedLocales
    }

    public static func installedLocales() async -> [Locale] {
        await SpeechTranscriber.installedLocales
    }

    public static func supportedLocale(equivalentTo locale: Locale) async -> Locale? {
        await SpeechTranscriber.supportedLocale(equivalentTo: locale)
    }

    /// Resolves `requested` to a supported locale and installs its model if needed.
    static func prepare(_ requested: Locale, onStatus: @Sendable (String) -> Void) async throws -> Locale {
        guard SpeechTranscriber.isAvailable else { throw TalktrailError.transcriberUnavailable }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested) else {
            throw TalktrailError.unsupportedLocale(requested.identifier)
        }
        let transcriber = makeTranscriber(locale)
        if await AssetInventory.status(forModules: [transcriber]) < .installed {
            onStatus(localized("Downloading the speech model for %@ (first time only)…", locale.identifier))
            // Reserving keeps the model from being purged; it is not required to use it.
            _ = try? await AssetInventory.reserve(locale: locale)
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
        }
        return locale
    }

    static func makeTranscriber(_ locale: Locale) -> SpeechTranscriber {
        // Word time ranges let each phrase be stamped with when its first word was spoken.
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )
    }
}

/// Transcribes one side of the conversation (the microphone or the system audio) with its own analyzer.
final class ChannelTranscriber: @unchecked Sendable {
    let label: String
    /// The channel's audio, kept only when speakers will be identified after the call.
    let recording: AudioRecording?
    private let analyzer: SpeechAnalyzer
    private let analyzerFormat: AVAudioFormat
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private var results: Task<Void, Never>?

    // Capture-thread state, guarded by `lock`.
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var timelineOrigin: TimeInterval?
    private var anchor: TimeInterval = 0
    private var framesSinceAnchor: AVAudioFramePosition = 0

    init(
        label: String,
        locale: Locale,
        transcript: TranscriptFile,
        recordsAudio: Bool = false,
        onStatus: @escaping @Sendable (String) -> Void
    ) async throws {
        let transcriber = SpeechModel.makeTranscriber(locale)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw TalktrailError.noAnalyzerFormat
        }
        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        self.label = label
        self.analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzerFormat = format
        self.input = continuation
        self.recording = recordsAudio ? try AudioRecording(format: format) : nil

        await transcript.register(label)
        try await analyzer.prepareToAnalyze(in: format)
        await analyzer.setVolatileRangeChangedHandler { [weak self] range, changedStart, _ in
            // Everything before the volatile range is final, even if it produced no text.
            guard changedStart, let self else { return }
            let finalized = self.sessionTime(range.start)
            Task {
                // The phrase that was just finalized is delivered separately; give it time to arrive so
                // phrases from the other channel are not written ahead of it.
                try? await Task.sleep(for: .seconds(1))
                await transcript.markFinalized(label, through: finalized)
            }
        }
        try await analyzer.start(inputSequence: stream)

        let debug = ProcessInfo.processInfo.environment["TALKTRAIL_DEBUG"] == "1"
        results = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self else { return }
                    let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty {
                        let words = self.words(in: result.text)
                        // A result's range can include the silence or noise before the first word.
                        let start = words.first?.start ?? self.sessionTime(result.range.start)
                        if debug {
                            let timing = words.map { String(format: "%@@%.2f", $0.text.trimmingCharacters(in: .whitespaces), $0.start) }
                            onStatus("[debug] \(label): " + timing.joined(separator: " "))
                        }
                        await transcript.add(Segment(speaker: label, start: start, text: text, words: words))
                    }
                    await transcript.markFinalized(label, through: self.sessionTime(result.resultsFinalizationTime))
                }
            } catch {
                onStatus(localized("Error transcribing \"%@\": %@", label, error.localizedDescription))
            }
        }
    }

    /// Feeds captured audio. `time` is when the buffer's first frame was captured, in seconds since the
    /// session started.
    func append(_ buffer: AVAudioPCMBuffer, at time: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }

        let origin = timelineOrigin ?? time
        timelineOrigin = origin
        guard let converted = convert(buffer) else { return }

        // The analyzer times audio by counting samples. If capture was interrupted (e.g. the input device
        // changed), tell it where this buffer belongs so timestamps stay aligned with the clock.
        let channelTime = time - origin
        let expected = anchor + Double(framesSinceAnchor) / analyzerFormat.sampleRate
        var startTime: CMTime?
        if channelTime - expected > 0.5 {
            // Keep the recording on the same timeline as the transcript.
            recording?.writeSilence(seconds: channelTime - expected)
            anchor = channelTime
            framesSinceAnchor = 0
            startTime = CMTime(seconds: channelTime, preferredTimescale: CMTimeScale(analyzerFormat.sampleRate))
        }
        framesSinceAnchor += AVAudioFramePosition(converted.frameLength)
        recording?.write(converted)
        input.yield(AnalyzerInput(buffer: converted, bufferStartTime: startTime))
    }

    /// Session time of the channel's first sample; the recording starts there.
    var origin: TimeInterval {
        lock.withLock { timelineOrigin ?? 0 }
    }

    /// Stops accepting audio and waits until every pending phrase has been delivered.
    func finish() async {
        input.finish()
        lock.withLock { recording?.close() }
        let analyzer = analyzer
        // Finalizing never returns if the analyzer was never given audio.
        guard lock.withLock({ timelineOrigin != nil }) else {
            await analyzer.cancelAndFinishNow()
            await results?.value
            return
        }
        let finalized = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                (try? await analyzer.finalizeAndFinishThroughEndOfInput()) != nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(30))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        if !finalized {
            await analyzer.cancelAndFinishNow()
        }
        await results?.value
    }

    /// The timed words of a result. Untimed runs (spaces, punctuation) stay attached to their word.
    private func words(in text: AttributedString) -> [Word] {
        var words: [Word] = []
        var leading = ""
        for run in text.runs {
            let piece = String(text[run.range].characters)
            if let range = run.audioTimeRange {
                words.append(Word(text: leading + piece, start: sessionTime(range.start), end: sessionTime(range.end)))
                leading = ""
            } else if let last = words.popLast() {
                words.append(Word(text: last.text + piece, start: last.start, end: last.end))
            } else {
                leading += piece
            }
        }
        // The first word's range also covers the silence before the phrase (up to a second), which would
        // stamp the phrase early and can attribute it to the previous speaker.
        if let first = words.first, first.end - first.start > Self.longestWordOnset {
            words[0] = Word(text: first.text, start: first.end - Self.longestWordOnset, end: first.end)
        }
        return words
    }

    private static let longestWordOnset: TimeInterval = 0.5

    private func sessionTime(_ channelTime: CMTime) -> TimeInterval {
        let origin = lock.withLock { timelineOrigin ?? 0 }
        return origin + (channelTime.isNumeric ? channelTime.seconds : 0)
    }

    /// Converts capture buffers (any rate and channel count) to the format the speech model expects.
    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: analyzerFormat)
            converter?.downmix = true
        }
        guard let converter else { return nil }

        let ratio = analyzerFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: capacity) else { return nil }

        var consumed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, output.frameLength > 0 else { return nil }
        return output
    }
}

/// A channel's audio in a private temporary file (16 kHz mono), deleted once speakers are identified.
final class AudioRecording: @unchecked Sendable {
    let url: URL
    private let format: AVAudioFormat
    private var file: AVAudioFile?

    init(format: AVAudioFormat) throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("talktrail-\(UUID().uuidString).caf")
        self.format = format
        file = try AVAudioFile(
            forWriting: url, settings: format.settings,
            commonFormat: format.commonFormat, interleaved: format.isInterleaved
        )
    }

    func write(_ buffer: AVAudioPCMBuffer) {
        try? file?.write(from: buffer)
    }

    func writeSilence(seconds: TimeInterval) {
        let frames = AVAudioFrameCount(seconds * format.sampleRate)
        guard frames > 0, let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        silence.frameLength = frames
        for buffer in UnsafeMutableAudioBufferListPointer(silence.mutableAudioBufferList) {
            memset(buffer.mData, 0, Int(buffer.mDataByteSize))
        }
        write(silence)
    }

    func close() {
        file?.close()
        file = nil
    }

    func delete() {
        close()
        try? FileManager.default.removeItem(at: url)
    }

    /// Removes recordings left behind by a session that crashed. Files of a running session are written
    /// to continuously, so anything untouched for ten minutes is abandoned.
    static func removeLeftovers() {
        let directory = FileManager.default.temporaryDirectory
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasPrefix("talktrail-") && name.hasSuffix(".caf") {
            let url = directory.appendingPathComponent(name)
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < Date(timeIntervalSinceNow: -600) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}
