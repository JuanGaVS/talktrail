import CoreAudio
import Foundation

public enum TalktrailError: LocalizedError {
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
            return "Core Audio falló al \(operation) (OSStatus \(status) \(fourCC(status)))."
        case .noInputDevice:
            return "No hay ningún micrófono disponible."
        case .microphoneAccessDenied:
            return "Sin permiso de micrófono. Actívalo en Ajustes del Sistema > Privacidad y seguridad > Micrófono."
        case .transcriberUnavailable:
            return "La transcripción en el dispositivo no está disponible en esta Mac."
        case let .unsupportedLocale(identifier):
            return "El idioma \"\(identifier)\" no está soportado. Ejecuta `talktrail locales` para ver la lista."
        case .noAnalyzerFormat:
            return "No se pudo determinar el formato de audio para el modelo de voz."
        case let .outputFile(path):
            return "No se pudo crear el archivo de transcripción en \(path)."
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
