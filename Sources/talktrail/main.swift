import Foundation
import TalktrailCore

/// The help text, in the user's language (`cli.usage` in Localizable.strings).
let usage = localized("cli.usage")

struct Options {
    var command = ""
    var positional: [String] = []
    var locale = Locale.current
    var output = RecordingSession.Configuration.defaultOutputDirectory
    var duration: TimeInterval?
    var microphone = true
    var systemAudio = true
    /// nil keeps the default label ("Me", "Remote" or their translation).
    var microphoneLabel: String?
    var systemAudioLabel: String?
    var identifySpeakers = true
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

@Sendable func status(_ message: String) {
    FileHandle.standardError.write(Data("› \(message)\n".utf8))
}

func parse(_ arguments: [String]) -> Options {
    var options = Options()
    var iterator = arguments.makeIterator()
    func value(for flag: String) -> String {
        guard let value = iterator.next() else { fail(localized("missing value for %@", flag)) }
        return value
    }
    while let argument = iterator.next() {
        switch argument {
        case "-h", "--help", "help":
            print(usage)
            exit(0)
        case "-l", "--locale":
            options.locale = Locale(identifier: value(for: argument))
        case "-o", "--output":
            options.output = URL(fileURLWithPath: (value(for: argument) as NSString).expandingTildeInPath, isDirectory: true)
        case "-d", "--duration":
            guard let seconds = TimeInterval(value(for: argument)), seconds > 0 else { fail(localized("invalid duration")) }
            options.duration = seconds
        case "--no-mic":
            options.microphone = false
        case "--no-system":
            options.systemAudio = false
        case "--me":
            options.microphoneLabel = value(for: argument)
        case "--them":
            options.systemAudioLabel = value(for: argument)
        case "--no-speakers":
            options.identifySpeakers = false
        case _ where argument.hasPrefix("-"):
            fail(localized("unknown option %@", argument) + "\n\n" + usage)
        case _ where options.command.isEmpty:
            options.command = argument
        default:
            options.positional.append(argument)
        }
    }
    return options
}

/// Suspends until Ctrl+C, SIGTERM or the optional duration elapses.
func waitForStop(after duration: TimeInterval?) async {
    final class Once: @unchecked Sendable {
        var continuation: CheckedContinuation<Void, Never>?
        var sources: [DispatchSourceSignal] = []
        func fire() {
            continuation?.resume()
            continuation = nil
        }
    }
    let once = Once()
    await withCheckedContinuation { continuation in
        once.continuation = continuation
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { once.fire() }
            source.resume()
            once.sources.append(source)
        }
        if let duration {
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) { once.fire() }
        }
    }
}

let options = parse(Array(CommandLine.arguments.dropFirst()))
@Sendable func printLine(_ line: String) {
    print(line)
}

switch options.command {
case "record":
    guard options.microphone || options.systemAudio else { fail(localized("--no-mic and --no-system together leave nothing to record")) }
    var configuration = RecordingSession.Configuration(locale: options.locale, outputDirectory: options.output)
    configuration.captureMicrophone = options.microphone
    configuration.captureSystemAudio = options.systemAudio
    configuration.microphoneLabel = options.microphoneLabel ?? configuration.microphoneLabel
    configuration.systemAudioLabel = options.systemAudioLabel ?? configuration.systemAudioLabel
    configuration.identifySpeakers = options.identifySpeakers

    let session = RecordingSession(configuration: configuration, onLine: printLine, onStatus: status)
    do {
        let draft = try await session.start()
        status(localized("Recording. Live draft at %@", draft.path))
        status(options.duration.map { localized("Stopping in %ld s (or Ctrl+C).", Int($0)) } ?? localized("Press Ctrl+C to finish."))
        await waitForStop(after: options.duration)
        status(localized("Finishing the transcript…"))
        if let url = await session.stop() {
            status(localized("Done: %@", url.path))
        }
    } catch {
        fail(error.localizedDescription)
    }

case "transcribe":
    guard let path = options.positional.first else { fail(localized("specify the audio file") + "\n\n" + usage) }
    do {
        let url = try await FileTranscription.transcribe(
            file: URL(fileURLWithPath: (path as NSString).expandingTildeInPath),
            locale: options.locale,
            outputDirectory: options.output,
            identifySpeakers: options.identifySpeakers,
            onLine: printLine,
            onStatus: status
        )
        status(localized("Done: %@", url.path))
    } catch {
        fail(error.localizedDescription)
    }

case "locales":
    let installed = Set(await SpeechModel.installedLocales().map(\.identifier))
    for locale in await SpeechModel.supportedLocales().sorted(by: { $0.identifier < $1.identifier }) {
        let name = Locale.current.localizedString(forIdentifier: locale.identifier) ?? ""
        print("\(locale.identifier.padding(toLength: 8, withPad: " ", startingAt: 0)) \(name)\(installed.contains(locale.identifier) ? "  (\(localized("installed")))" : "")")
    }

case "fetch-models":
    guard let path = options.positional.first else { fail(localized("specify the destination folder") + "\n\n" + usage) }
    do {
        let directory = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        status(localized("Downloading the models to %@…", directory.path))
        try await SpeakerDiarization.downloadModels(to: directory)
        status(localized("Done"))
    } catch {
        fail(error.localizedDescription)
    }

case "":
    print(usage)

default:
    fail(localized("unknown command \"%@\"", options.command) + "\n\n" + usage)
}
