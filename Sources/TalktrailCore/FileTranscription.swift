import AVFoundation

/// Transcribes an existing audio file with the same on-device pipeline used for live calls.
public enum FileTranscription {
    public static func transcribe(
        file: URL,
        locale: Locale,
        outputDirectory: URL,
        identifySpeakers: Bool = true,
        onLine: @escaping @Sendable (String) -> Void,
        onStatus: @escaping @Sendable (String) -> Void
    ) async throws -> URL {
        let locale = try await SpeechModel.prepare(locale, onStatus: onStatus)
        let audio = try AVAudioFile(forReading: file)
        let format = TranscriptFormat(start: Date(), clock: .elapsed)
        let label = localized("Audio")
        let transcript = try TranscriptFile(
            directory: TranscriptStorage.draftsDirectory,
            format: format,
            name: format.fileName(),
            title: localized("Transcript (draft)"),
            fields: [(localized("File"), file.lastPathComponent), (localized("Language"), locale.identifier)],
            onLine: onLine
        )
        let channel = try await ChannelTranscriber(
            label: label, locale: locale, transcript: transcript, onStatus: onStatus
        )

        let processingFormat = audio.processingFormat
        while audio.framePosition < audio.length {
            let position = audio.framePosition
            guard let buffer = AVAudioPCMBuffer(pcmFormat: processingFormat, frameCapacity: 16_384) else { break }
            try audio.read(into: buffer)
            guard buffer.frameLength > 0 else { break }
            channel.append(buffer, at: Double(position) / processingFormat.sampleRate)
        }
        await channel.finish()
        var segments = await transcript.close()

        var participants = label
        if identifySpeakers {
            participants = await SpeakerDiarization.identifySpeakers(
                in: file, segments: &segments, channel: label, offset: 0, label: localized("Speaker"), onStatus: onStatus
            ) ?? participants
        }
        let duration = Double(audio.length) / processingFormat.sampleRate
        let url = try TranscriptStorage.write(
            segments, format: format, title: localized("Transcript"),
            fields: [
                (localized("File"), file.lastPathComponent),
                (localized("Language"), locale.identifier),
                (localized("Participants"), participants),
            ],
            end: format.start.addingTimeInterval(duration), in: outputDirectory
        )
        try? FileManager.default.removeItem(at: transcript.url)
        return url
    }
}
