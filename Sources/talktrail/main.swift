import Foundation
import TalktrailCore

let usage = """
talktrail — transcribe llamadas en esta Mac (micrófono + audio del sistema). Nada sale del equipo.

USO
  talktrail record [opciones]                Graba y transcribe hasta Ctrl+C
  talktrail transcribe <audio> [opciones]    Transcribe un archivo de audio existente
  talktrail locales                          Lista los idiomas disponibles
  talktrail fetch-models <carpeta>           Descarga los modelos de identificación de personas
                                             (solo para empaquetar la app; la app nunca descarga nada)

OPCIONES
  -l, --locale <código>     Idioma: es-ES, es-MX, en-US… (por defecto, el del sistema)
  -o, --output <carpeta>    Carpeta de transcripciones (por defecto ~/Documents/Transcripciones)
  -d, --duration <seg>      Detener automáticamente tras N segundos
      --no-mic              No transcribir el micrófono
      --no-system           No transcribir el audio del sistema
      --me <nombre>         Etiqueta del micrófono (por defecto "Yo")
      --them <nombre>       Etiqueta del audio del sistema (por defecto "Remoto")
      --no-speakers         No separar a las personas (sin diarización)
"""

struct Options {
    var command = ""
    var positional: [String] = []
    var locale = Locale.current
    var output = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Documents/Transcripciones", isDirectory: true)
    var duration: TimeInterval?
    var microphone = true
    var systemAudio = true
    var microphoneLabel = "Yo"
    var systemAudioLabel = "Remoto"
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
        guard let value = iterator.next() else { fail("falta el valor de \(flag)") }
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
            guard let seconds = TimeInterval(value(for: argument)), seconds > 0 else { fail("duración inválida") }
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
            fail("opción desconocida \(argument)\n\n\(usage)")
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
    guard options.microphone || options.systemAudio else { fail("--no-mic y --no-system juntos no dejan nada que grabar") }
    var configuration = RecordingSession.Configuration(locale: options.locale, outputDirectory: options.output)
    configuration.captureMicrophone = options.microphone
    configuration.captureSystemAudio = options.systemAudio
    configuration.microphoneLabel = options.microphoneLabel
    configuration.systemAudioLabel = options.systemAudioLabel
    configuration.identifySpeakers = options.identifySpeakers

    let session = RecordingSession(configuration: configuration, onLine: printLine, onStatus: status)
    do {
        let draft = try await session.start()
        status("Grabando. Borrador en vivo en \(draft.path)")
        status(options.duration.map { "Se detendrá en \(Int($0)) s (o Ctrl+C)." } ?? "Ctrl+C para terminar.")
        await waitForStop(after: options.duration)
        status("Terminando la transcripción…")
        if let url = await session.stop() {
            status("Listo: \(url.path)")
        }
    } catch {
        fail(error.localizedDescription)
    }

case "transcribe":
    guard let path = options.positional.first else { fail("indica el archivo de audio\n\n\(usage)") }
    do {
        let url = try await FileTranscription.transcribe(
            file: URL(fileURLWithPath: (path as NSString).expandingTildeInPath),
            locale: options.locale,
            outputDirectory: options.output,
            identifySpeakers: options.identifySpeakers,
            onLine: printLine,
            onStatus: status
        )
        status("Listo: \(url.path)")
    } catch {
        fail(error.localizedDescription)
    }

case "locales":
    let installed = Set(await SpeechModel.installedLocales().map(\.identifier))
    for locale in await SpeechModel.supportedLocales().sorted(by: { $0.identifier < $1.identifier }) {
        let name = Locale.current.localizedString(forIdentifier: locale.identifier) ?? ""
        print("\(locale.identifier.padding(toLength: 8, withPad: " ", startingAt: 0)) \(name)\(installed.contains(locale.identifier) ? "  (instalado)" : "")")
    }

case "fetch-models":
    guard let path = options.positional.first else { fail("indica la carpeta de destino\n\n\(usage)") }
    do {
        let directory = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        status("Descargando los modelos en \(directory.path)…")
        try await SpeakerDiarization.downloadModels(to: directory)
        status("Listo")
    } catch {
        fail(error.localizedDescription)
    }

case "":
    print(usage)

default:
    fail("comando desconocido \"\(options.command)\"\n\n\(usage)")
}
