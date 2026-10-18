import Foundation

/// Returns user-facing text in the user's macOS language.
///
/// Keys are the English text itself, written as `String(format:)` formats (`%@` for strings, `%ld` for
/// integers). Translations live in `Resources/<language>.lproj/Localizable.strings`; a key without a
/// translation is shown in English. `scripts/check-localizations.py` keeps the Spanish file complete.
public func localized(_ key: String, _ arguments: CVarArg...) -> String {
    let format = Bundle.module.localizedString(forKey: key, value: nil, table: nil)
    return arguments.isEmpty ? format : String(format: format, arguments: arguments)
}
