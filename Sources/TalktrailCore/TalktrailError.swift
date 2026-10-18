import CoreAudio
import Foundation

public enum TalktrailError: LocalizedError {
    /// A Core Audio call failed. The operation completes "Core Audio failed to …".
    case coreAudio(OSStatus, String)
    case noInputDevice
    case microphoneAccessDenied
    case transcriberUnavailable
    case unsupportedLocale(String)
    case noAnalyzerFormat
    case outputFile(String)

    public var errorDescription: String? {
        switch self {
        case let .coreAudio(status, operation):
            return localized("Core Audio failed to %@ (OSStatus %d %@).", operation, status, fourCC(status))
        case .noInputDevice:
            return localized("No microphone is available.")
        case .microphoneAccessDenied:
            return localized("No microphone permission. Turn it on in System Settings > Privacy & Security > Microphone.")
        case .transcriberUnavailable:
            return localized("On-device transcription is not available on this Mac.")
        case let .unsupportedLocale(identifier):
            return localized("The language \"%@\" is not supported. Run `talktrail locales` to see the list.", identifier)
        case .noAnalyzerFormat:
            return localized("Could not determine the audio format for the speech model.")
        case let .outputFile(path):
            return localized("Could not create the transcript file at %@.", path)
        }
    }
}

func check(_ status: OSStatus, _ operation: String) throws {
    guard status == noErr else { throw TalktrailError.coreAudio(status, operation) }
}

/// Core Audio errors are usually four-character codes ('who?', '!dev', ...).
private func fourCC(_ status: OSStatus) -> String {
    let bytes = withUnsafeBytes(of: UInt32(bitPattern: status).bigEndian, Array.init)
    guard bytes.allSatisfy({ (0x20...0x7E).contains($0) }) else { return "" }
    return "'\(String(decoding: bytes, as: UTF8.self))'"
}
