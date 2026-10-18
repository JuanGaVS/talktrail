import FluidAudio
import Foundation

/// Works out who spoke when, on the device, with FluidAudio's offline pipeline (pyannote segmentation,
/// WeSpeaker embeddings and VBx clustering on Core ML). It runs once over the whole call after it ends,
/// which is more accurate than labelling speakers live.
public enum SpeakerDiarization {
    /// A stretch of audio spoken by one person. Speakers are numbered 1, 2… in order of appearance.
    struct Turn {
        let speaker: Int
        let start: TimeInterval
        let end: TimeInterval
    }

    static let modelFolder = "speaker-diarization"

    /// The bundled models: `$TALKTRAIL_MODELS`, the app's `Resources/Models`, or `Models` next to the CLI.
    public static var modelsDirectory: URL? {
        var candidates: [URL] = []
        if let path = ProcessInfo.processInfo.environment["TALKTRAIL_MODELS"] {
            candidates.append(URL(fileURLWithPath: path))
        }
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("Models"))
        }
        if let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() {
            candidates.append(executable.deletingLastPathComponent().appendingPathComponent("Models"))
        }
        return candidates.first {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent(modelFolder).path)
        }
    }

    /// Downloads the models into `directory`. Only used when building the app, which ships them.
    public static func downloadModels(to directory: URL) async throws {
        ModelHub.offlineMode = false
        _ = try await OfflineDiarizerModels.load(from: directory)
    }

    /// Diarizes `audio` and attributes `channel`'s phrases to "<label> 1", "<label> 2"…
    /// Returns a description of the participants found, or nil if speakers could not be identified.
    static func identifySpeakers(
        in audio: URL,
        segments: inout [Segment],
        channel: String,
        offset: TimeInterval,
        label: String,
        onStatus: @escaping @Sendable (String) -> Void
    ) async -> String? {
        guard let models = modelsDirectory else {
            onStatus("Aviso: faltan los modelos de identificación de personas; se guarda sin separar voces.")
            return nil
        }
        onStatus("Identificando a las personas…")
        do {
            let turns = try await turns(in: audio, models: models) { fraction in
                onStatus("Identificando a las personas… \(Int(fraction * 100)) %")
            }
            if ProcessInfo.processInfo.environment["TALKTRAIL_DEBUG"] == "1" {
                for turn in turns {
                    onStatus(String(format: "[debug] turno %@ %d: %.2f–%.2f s", label, turn.speaker, turn.start, turn.end))
                }
            }
            let count = Set(turns.map(\.speaker)).count
            guard count > 0 else { return nil }
            segments = assign(turns, to: segments, channel: channel, offset: offset) { "\(label) \($0)" }
            return count == 1 ? "\(label) 1" : "\(label) 1–\(count)"
        } catch {
            onStatus("Aviso: no se pudo identificar a las personas (\(error.localizedDescription)).")
            return nil
        }
    }

    static func turns(
        in audio: URL,
        models directory: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [Turn] {
        // The models are bundled; never reach out to the network for them.
        ModelHub.offlineMode = true
        let manager = OfflineDiarizerManager(config: .default)
        manager.initialize(models: try await OfflineDiarizerModels.load(from: directory))
        let result = try await manager.process(audio) { done, total in
            progress(Double(done) / Double(max(total, 1)))
        }

        var numbers: [String: Int] = [:]
        return result.segments
            .sorted { $0.startTimeSeconds < $1.startTimeSeconds }
            .map { segment in
                let number = numbers[segment.speakerId] ?? numbers.count + 1
                numbers[segment.speakerId] = number
                return Turn(
                    speaker: number,
                    start: TimeInterval(segment.startTimeSeconds),
                    end: TimeInterval(segment.endTimeSeconds)
                )
            }
    }

    /// Relabels the phrases of `channel` with the person speaking each word, splitting a phrase where the
    /// speaker changes. `offset` converts turn times (seconds into the channel's audio) to session time.
    static func assign(
        _ turns: [Turn],
        to segments: [Segment],
        channel: String,
        offset: TimeInterval,
        name: (Int) -> String
    ) -> [Segment] {
        guard !turns.isEmpty else { return segments }
        let turns = turns.map { Turn(speaker: $0.speaker, start: $0.start + offset, end: $0.end + offset) }

        return segments.flatMap { segment -> [Segment] in
            guard segment.speaker == channel else { return [segment] }
            guard !segment.words.isEmpty else {
                let speaker = speaker(at: segment.start, segment.start + 1, in: turns, previous: nil)
                return [Segment(speaker: name(speaker), start: segment.start, text: segment.text)]
            }

            var pieces: [(speaker: Int, words: [Word])] = []
            for word in segment.words {
                let speaker = speaker(at: word.start, word.end, in: turns, previous: pieces.last?.speaker)
                if pieces.last?.speaker == speaker {
                    pieces[pieces.count - 1].words.append(word)
                } else {
                    pieces.append((speaker, [word]))
                }
            }
            return pieces.map { piece in
                Segment(
                    speaker: name(piece.speaker),
                    start: piece.words[0].start,
                    text: piece.words.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines),
                    words: piece.words
                )
            }
        }
    }

    /// The speaker who overlaps the interval the most; otherwise the previous word's speaker; otherwise
    /// the nearest turn.
    private static func speaker(at start: TimeInterval, _ end: TimeInterval, in turns: [Turn], previous: Int?) -> Int {
        var overlap: [Int: TimeInterval] = [:]
        for turn in turns where turn.start < end && turn.end > start {
            overlap[turn.speaker, default: 0] += min(end, turn.end) - max(start, turn.start)
        }
        if let best = overlap.max(by: { $0.value < $1.value }) {
            return best.key
        }
        if let previous {
            return previous
        }
        let middle = (start + end) / 2
        return turns.min {
            distance(from: middle, to: $0) < distance(from: middle, to: $1)
        }!.speaker
    }

    private static func distance(from time: TimeInterval, to turn: Turn) -> TimeInterval {
        time < turn.start ? turn.start - time : max(0, time - turn.end)
    }
}
