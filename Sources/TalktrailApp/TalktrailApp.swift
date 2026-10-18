import AppKit
import Observation
import TalktrailCore
import SwiftUI

/// Menu bar app: start/stop a call transcription that is written to ~/Documents/Transcripts.
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
            Button(localized("Stop transcription")) { Task { await recorder.stop() } }
                .disabled(recorder.isBusy)
        } else {
            Button(localized("Start transcription")) { Task { await recorder.start() } }
                .disabled(recorder.isBusy || !(recorder.captureMicrophone || recorder.captureSystemAudio))
        }
        Text(recorder.status)
        if let warning = recorder.warning {
            Text(warning)
        }

        Divider()

        Picker(localized("Language"), selection: $recorder.localeIdentifier) {
            ForEach(recorder.locales, id: \.self) { identifier in
                Text(Locale.current.localizedString(forIdentifier: identifier) ?? identifier).tag(identifier)
            }
        }
        .pickerStyle(.menu)
        .disabled(recorder.isRecording || recorder.isBusy)
        Toggle(localized("Microphone (%@)", localized("Me")), isOn: $recorder.captureMicrophone)
            .disabled(recorder.isRecording || recorder.isBusy)
        Toggle(localized("Call audio (%@)", localized("Remote")), isOn: $recorder.captureSystemAudio)
            .disabled(recorder.isRecording || recorder.isBusy)
        Toggle(localized("Identify each speaker when done"), isOn: $recorder.identifySpeakers)
            .disabled(recorder.isRecording || recorder.isBusy || !recorder.captureSystemAudio)

        Divider()

        Button(localized("Open last transcript")) {
            if let url = recorder.lastTranscript { NSWorkspace.shared.open(url) }
        }
        .disabled(recorder.lastTranscript == nil)
        Button(localized("Open transcripts folder")) {
            try? FileManager.default.createDirectory(at: recorder.outputDirectory, withIntermediateDirectories: true)
            NSWorkspace.shared.open(recorder.outputDirectory)
        }

        Divider()

        Button(localized("Quit")) { Task { await recorder.quit() } }
            .keyboardShortcut("q")
    }
}

@MainActor
@Observable
final class Recorder {
    private(set) var isRecording = false
    private(set) var isBusy = false
    /// The last warning or error. It stays in the menu, with a warning icon in the menu bar, until the next
    /// transcription starts, so later status updates ("Saved: …") don't hide it.
    private(set) var warning: String? {
        didSet { if let warning { FileHandle.standardError.write(Data("› \(warning)\n".utf8)) } }
    }
    private(set) var status = localized("Ready") {
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
    let outputDirectory = RecordingSession.Configuration.defaultOutputDirectory
    private var session: RecordingSession?

    var symbolName: String {
        if warning != nil { return "exclamationmark.triangle" }
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
        warning = nil
        status = localized("Preparing…")

        var configuration = RecordingSession.Configuration(
            locale: Locale(identifier: localeIdentifier), outputDirectory: outputDirectory
        )
        configuration.captureMicrophone = captureMicrophone
        configuration.captureSystemAudio = captureSystemAudio
        configuration.identifySpeakers = identifySpeakers
        let session = RecordingSession(configuration: configuration, onLine: { _ in }) { [weak self] message in
            Task { @MainActor in
                // Warnings and errors from TalktrailCore start with these words.
                if message.hasPrefix(localized("Warning")) || message.hasPrefix(localized("Error")) {
                    self?.warning = message
                } else {
                    self?.status = message
                }
            }
        }
        do {
            let url = try await session.start()
            self.session = session
            lastTranscript = url
            isRecording = true
            status = localized("Transcribing → %@", url.lastPathComponent)
        } catch {
            status = localized("Ready")
            warning = localized("Error: %@", error.localizedDescription)
        }
        isBusy = false
    }

    func stop() async {
        guard let session else { return }
        self.session = nil
        isBusy = true
        status = localized("Finishing the transcript…")
        if let url = await session.stop() {
            lastTranscript = url
        }
        isRecording = false
        isBusy = false
        status = localized("Saved: %@", lastTranscript?.lastPathComponent ?? "")
    }

    func quit() async {
        await stop()
        NSApplication.shared.terminate(nil)
    }

    private func loadLocales() async {
        locales = await SpeechModel.supportedLocales().map(\.identifier).sorted()
        if !locales.contains(localeIdentifier) {
            let match = await SpeechModel.supportedLocale(equivalentTo: Locale(identifier: localeIdentifier))
            localeIdentifier = match?.identifier ?? (locales.contains("en_US") ? "en_US" : locales.first ?? "en_US")
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
