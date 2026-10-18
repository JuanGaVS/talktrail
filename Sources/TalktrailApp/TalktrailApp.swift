import AppKit
import Observation
import TalktrailCore
import SwiftUI

/// Menu bar app: start/stop a call transcription that is written to ~/Documents/Transcripciones.
///
/// Running as an app (not inside a terminal) matters: macOS grants the microphone and system-audio
/// permissions to the app itself, using the usage descriptions in its Info.plist.
@main
struct TalktrailApp: App {
    @State private var recorder = Recorder()

    var body: some Scene {
        MenuBarExtra {
            RecorderMenu(recorder: recorder)
        } label: {
            Image(systemName: recorder.symbolName)
        }
        .menuBarExtraStyle(.menu)
    }
}

struct RecorderMenu: View {
    @Bindable var recorder: Recorder

    var body: some View {
        if recorder.isRecording {
            Button("Detener transcripción") { Task { await recorder.stop() } }
                .disabled(recorder.isBusy)
        } else {
            Button("Iniciar transcripción") { Task { await recorder.start() } }
                .disabled(recorder.isBusy || !(recorder.captureMicrophone || recorder.captureSystemAudio))
        }
        Text(recorder.status)

        Divider()

        Picker("Idioma", selection: $recorder.localeIdentifier) {
            ForEach(recorder.locales, id: \.self) { identifier in
                Text(Locale.current.localizedString(forIdentifier: identifier) ?? identifier).tag(identifier)
            }
        }
        .pickerStyle(.menu)
        .disabled(recorder.isRecording || recorder.isBusy)
        Toggle("Micrófono (Yo)", isOn: $recorder.captureMicrophone)
            .disabled(recorder.isRecording || recorder.isBusy)
        Toggle("Audio de la llamada (Remoto)", isOn: $recorder.captureSystemAudio)
            .disabled(recorder.isRecording || recorder.isBusy)
        Toggle("Identificar a cada persona al terminar", isOn: $recorder.identifySpeakers)
            .disabled(recorder.isRecording || recorder.isBusy || !recorder.captureSystemAudio)

        Divider()

        Button("Abrir última transcripción") {
            if let url = recorder.lastTranscript { NSWorkspace.shared.open(url) }
        }
        .disabled(recorder.lastTranscript == nil)
        Button("Abrir carpeta de transcripciones") {
            try? FileManager.default.createDirectory(at: recorder.outputDirectory, withIntermediateDirectories: true)
            NSWorkspace.shared.open(recorder.outputDirectory)
        }

        Divider()

        Button("Salir") { Task { await recorder.quit() } }
            .keyboardShortcut("q")
    }
}

@MainActor
@Observable
final class Recorder {
    private(set) var isRecording = false
    private(set) var isBusy = false
    private(set) var hasWarning = false
    private(set) var status = "Listo" {
        didSet { FileHandle.standardError.write(Data("› \(status)\n".utf8)) }
    }
    private(set) var lastTranscript: URL?
    private(set) var locales: [String] = []
    var localeIdentifier: String {
        didSet { UserDefaults.standard.set(localeIdentifier, forKey: "locale") }
    }
    var captureMicrophone: Bool {
        didSet { UserDefaults.standard.set(captureMicrophone, forKey: "captureMicrophone") }
    }
    var captureSystemAudio: Bool {
        didSet { UserDefaults.standard.set(captureSystemAudio, forKey: "captureSystemAudio") }
    }
    var identifySpeakers: Bool {
        didSet { UserDefaults.standard.set(identifySpeakers, forKey: "identifySpeakers") }
    }
    let outputDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Documents/Transcripciones", isDirectory: true)
    private var session: RecordingSession?

    var symbolName: String {
        if hasWarning { return "exclamationmark.triangle" }
        return isRecording ? "record.circle.fill" : "waveform"
    }

    init() {
        let defaults = UserDefaults.standard
        localeIdentifier = defaults.string(forKey: "locale") ?? Locale.current.identifier
        captureMicrophone = defaults.object(forKey: "captureMicrophone") as? Bool ?? true
        captureSystemAudio = defaults.object(forKey: "captureSystemAudio") as? Bool ?? true
        identifySpeakers = defaults.object(forKey: "identifySpeakers") as? Bool ?? true
        Task {
            await loadLocales()
            await handleLaunchArguments()
        }
    }

    func start() async {
        guard session == nil, !isBusy else { return }
        isBusy = true
        hasWarning = false
        status = "Preparando…"

        var configuration = RecordingSession.Configuration(
            locale: Locale(identifier: localeIdentifier), outputDirectory: outputDirectory
        )
        configuration.captureMicrophone = captureMicrophone
        configuration.captureSystemAudio = captureSystemAudio
        configuration.identifySpeakers = identifySpeakers
        let session = RecordingSession(configuration: configuration, onLine: { _ in }) { [weak self] message in
            Task { @MainActor in
                self?.status = message
                if message.hasPrefix("Aviso") || message.hasPrefix("Error") { self?.hasWarning = true }
            }
        }
        do {
            let url = try await session.start()
            self.session = session
            lastTranscript = url
            isRecording = true
            status = "Transcribiendo → \(url.lastPathComponent)"
        } catch {
            hasWarning = true
            status = "Error: \(error.localizedDescription)"
        }
        isBusy = false
    }

    func stop() async {
        guard let session else { return }
        self.session = nil
        isBusy = true
        status = "Terminando la transcripción…"
        if let url = await session.stop() {
            lastTranscript = url
        }
        isRecording = false
        isBusy = false
        status = "Guardado: \(lastTranscript?.lastPathComponent ?? "")"
    }

    func quit() async {
        await stop()
        NSApplication.shared.terminate(nil)
    }

    private func loadLocales() async {
        locales = await SpeechModel.supportedLocales().map(\.identifier).sorted()
        if !locales.contains(localeIdentifier) {
            let match = await SpeechModel.supportedLocale(equivalentTo: Locale(identifier: localeIdentifier))
            localeIdentifier = match?.identifier ?? (locales.contains("es_ES") ? "es_ES" : locales.first ?? "es_ES")
        }
    }

    /// `--record [--duration <s>]` starts right away and, with a duration, stops and quits afterwards.
    /// Useful for scripted runs.
    private func handleLaunchArguments() async {
        let arguments = CommandLine.arguments
        guard arguments.contains("--record") else { return }
        await start()
        guard let index = arguments.firstIndex(of: "--duration"), index + 1 < arguments.count,
              let seconds = Double(arguments[index + 1]) else { return }
        try? await Task.sleep(for: .seconds(seconds))
        await quit()
    }
}
