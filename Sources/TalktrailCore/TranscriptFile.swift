import Foundation

/// A finished phrase from one side of the conversation.
struct Segment {
    var speaker: String
    /// Seconds since the session started.
    var start: TimeInterval
    var text: String
    /// The phrase's words with their timing, used to split it between speakers after diarization.
    var words: [Word] = []
}

struct Word {
    /// The word as transcribed, including its surrounding spaces and punctuation.
    let text: String
    /// Seconds since the session started.
    let start: TimeInterval
    let end: TimeInterval
}

/// How transcripts are laid out in Markdown.
struct TranscriptFormat {
    enum Clock {
        /// Timestamps show the time of day (live calls).
        case wallClock
        /// Timestamps show the offset from the start (audio files).
        case elapsed
    }

    let start: Date
    let clock: Clock

    func header(title: String, fields: [(String, String)]) -> String {
        var text = "# \(title)\n\n"
        text += "- **\(localized("Started")):** \(Self.format(start, "yyyy-MM-dd HH:mm:ss"))\n"
        for (key, value) in fields {
            text += "- **\(key):** \(value)\n"
        }
        return text + "\n---\n\n"
    }

    func line(for segment: Segment) -> String {
        let seconds = max(0, segment.start).rounded()
        let timestamp: String
        switch clock {
        case .wallClock:
            timestamp = Self.format(start.addingTimeInterval(seconds), "HH:mm:ss")
        case .elapsed:
            let total = Int(seconds)
            timestamp = String(format: "%02d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
        }
        return "**[\(timestamp)] \(segment.speaker):** \(segment.text)"
    }

    func footer(end: Date) -> String {
        let minutes = Int((end.timeIntervalSince(start) / 60).rounded())
        let ended = localized("Ended: %@ · duration %ld min", Self.format(end, "yyyy-MM-dd HH:mm:ss"), minutes)
        return "---\n\n_\(ended)_\n"
    }

    /// "transcript-2026-10-17_10-12-25", with the first word in the user's language.
    func fileName() -> String {
        "\(localized("transcript"))-\(Self.format(start, "yyyy-MM-dd_HH-mm-ss"))"
    }

    private static func format(_ date: Date, _ pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}

enum TranscriptStorage {
    /// Creates `<name>.md` (or `<name>-2.md`, … if taken) readable only by the user. Files are only
    /// ever created and appended to, never overwritten.
    static func create(in directory: URL, name: String) throws -> (URL, FileHandle) {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var url = directory.appendingPathComponent("\(name).md")
        var descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_APPEND, 0o600)
        var suffix = 2
        while descriptor < 0, errno == EEXIST, suffix < 100 {
            url = directory.appendingPathComponent("\(name)-\(suffix).md")
            descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_APPEND, 0o600)
            suffix += 1
        }
        guard descriptor >= 0 else { throw TalktrailError.outputFile(url.path) }
        return (url, FileHandle(fileDescriptor: descriptor, closeOnDealloc: true))
    }

    /// Live drafts live in the user's private temporary folder until the final transcript is written.
    static var draftsDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Talktrail-drafts", isDirectory: true)
    }

    /// Moves drafts left behind by a session that crashed into `directory`, as `…-recovered.md`. Drafts
    /// of a running session are written to as it goes, so anything untouched for ten minutes is abandoned.
    @discardableResult
    static func recoverDrafts(into directory: URL) -> [URL] {
        let drafts = (try? FileManager.default.contentsOfDirectory(
            at: draftsDirectory, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        return drafts.compactMap { draft -> URL? in
            let modified = (try? draft.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            let name = draft.deletingPathExtension().lastPathComponent + "-" + localized("recovered")
            guard draft.pathExtension == "md", let modified, modified < Date(timeIntervalSinceNow: -600),
                  let contents = try? Data(contentsOf: draft),
                  let (url, handle) = try? create(in: directory, name: name)
            else { return nil }
            defer { try? handle.close() }
            guard (try? handle.write(contentsOf: contents)) != nil else { return nil }
            try? FileManager.default.removeItem(at: draft)
            return url
        }
    }

    /// Writes a complete transcript in one go, in chronological order.
    static func write(
        _ segments: [Segment],
        format: TranscriptFormat,
        title: String,
        fields: [(String, String)],
        end: Date,
        in directory: URL
    ) throws -> URL {
        let (url, handle) = try create(in: directory, name: format.fileName())
        defer { try? handle.close() }
        var text = format.header(title: title, fields: fields)
        for segment in segments.sorted(by: { $0.start < $1.start }) {
            text += format.line(for: segment) + "\n\n"
        }
        text += format.footer(end: end)
        try handle.write(contentsOf: Data(text.utf8))
        try handle.synchronize()
        return url
    }
}

/// Appends finished phrases from every channel to a local Markdown draft in chronological order, while
/// the call is still going on.
///
/// Each channel finalizes phrases independently, so a phrase from one side can arrive after a later phrase
/// from the other. Phrases are held until every channel has finalized past them (or for at most `maxHold`
/// seconds) and then written oldest-first. Every write is flushed to disk, so an interrupted session keeps
/// everything transcribed up to that point.
actor TranscriptFile {
    /// Without headphones the microphone also hears the call from the speakers. Microphone phrases that
    /// repeat a remote phrase spoken at the same moment are dropped.
    struct EchoFilter {
        let microphone: String
        let systemAudio: String
    }

    let url: URL
    let format: TranscriptFormat
    private let handle: FileHandle
    private let onLine: @Sendable (String) -> Void
    private let echoFilter: EchoFilter?
    private let maxHold: TimeInterval = 45
    private let echoWindow: TimeInterval = 5
    private var pending: [(segment: Segment, receivedAt: Date)] = []
    private var finalizedThrough: [String: TimeInterval] = [:]
    private var recentSystemAudio: [Segment] = []
    private var written: [Segment] = []
    private var closed = false

    init(
        directory: URL,
        format: TranscriptFormat,
        name: String,
        title: String,
        fields: [(String, String)],
        echoFilter: EchoFilter? = nil,
        onLine: @escaping @Sendable (String) -> Void
    ) throws {
        (url, handle) = try TranscriptStorage.create(in: directory, name: name)
        self.format = format
        self.echoFilter = echoFilter
        self.onLine = onLine
        try handle.write(contentsOf: Data(format.header(title: title, fields: fields).utf8))
        try handle.synchronize()
    }

    func register(_ speaker: String) {
        finalizedThrough[speaker] = finalizedThrough[speaker] ?? 0
    }

    func add(_ segment: Segment) {
        pending.append((segment, Date()))
        flush()
    }

    func markFinalized(_ speaker: String, through time: TimeInterval) {
        finalizedThrough[speaker] = max(finalizedThrough[speaker] ?? 0, time)
        flush()
    }

    /// Writes every phrase that can no longer be preceded by a phrase still in progress.
    func flush(force: Bool = false) {
        guard !closed else { return }
        let horizon = finalizedThrough.values.min() ?? .infinity
        let now = Date()
        pending.sort { $0.segment.start < $1.segment.start }

        var ready = 0
        for item in pending {
            // Microphone phrases wait a bit longer so the remote phrase they might echo can arrive first.
            let settle = item.segment.speaker == echoFilter?.microphone ? echoWindow : 0
            guard force || item.segment.start + settle <= horizon || now.timeIntervalSince(item.receivedAt) >= maxHold else { break }
            ready += 1
        }
        guard ready > 0 else { return }

        let released = pending.prefix(ready).map(\.segment)
        pending.removeFirst(ready)
        if let echoFilter {
            recentSystemAudio += released.filter { $0.speaker == echoFilter.systemAudio }
            recentSystemAudio.removeAll { $0.start < released[released.count - 1].start - 120 }
        }
        let kept = released.filter { !isEcho($0) }
        guard !kept.isEmpty else { return }
        written += kept
        let lines = kept.map(format.line(for:))
        lines.forEach(onLine)
        write(lines.map { $0 + "\n\n" }.joined())
    }

    /// Writes the remaining phrases, closes the draft and returns every phrase it contains.
    func close() -> [Segment] {
        flush(force: true)
        write(format.footer(end: Date()))
        closed = true
        try? handle.close()
        return written
    }

    private func isEcho(_ segment: Segment) -> Bool {
        guard let echoFilter, segment.speaker == echoFilter.microphone else { return false }
        let words = Self.words(segment.text)
        guard !words.isEmpty else { return false }
        // Echo is near-simultaneous; short phrases ("yes", "ok") need a tighter match to count as one.
        let window = words.count < 4 ? 1.0 : echoWindow
        let remote = (recentSystemAudio + pending.map(\.segment).filter { $0.speaker == echoFilter.systemAudio })
            .filter { abs($0.start - segment.start) <= window }
            .sorted { $0.start < $1.start }
            .flatMap { Self.words($0.text) }
        guard !remote.isEmpty else { return false }
        return Double(Self.commonSubsequenceLength(words, remote)) / Double(words.count) >= 0.7
    }

    private static func words(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// Length of the longest common subsequence: shared words in the same order.
    private static func commonSubsequenceLength(_ a: [String], _ b: [String]) -> Int {
        var previous = [Int](repeating: 0, count: b.count + 1)
        for word in a {
            var current = [Int](repeating: 0, count: b.count + 1)
            for (index, other) in b.enumerated() {
                current[index + 1] = word == other ? previous[index] + 1 : max(previous[index + 1], current[index])
            }
            previous = current
        }
        return previous[b.count]
    }

    private func write(_ text: String) {
        do {
            try handle.write(contentsOf: Data(text.utf8))
            try handle.synchronize()
        } catch {
            onLine(localized("⚠️ Could not write to %@: %@", url.path, error.localizedDescription))
        }
    }
}
