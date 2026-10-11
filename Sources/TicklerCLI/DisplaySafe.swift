import Foundation

/// Stored text (titles, notes, link labels) can come from anywhere, so terminal output never prints it raw:
/// an escape sequence in a title would otherwise drive the user's terminal. `--json` output does not use this.
extension String {
    /// Control characters (C0, DEL, C1) become U+FFFD; tab and newline stay, for multi-line notes.
    var displaySafe: String {
        String(String.UnicodeScalarView(unicodeScalars.map { scalar in
            scalar.properties.generalCategory == .control && scalar != "\t" && scalar != "\n" ? "\u{FFFD}" : scalar
        }))
    }

    /// For single-line fields: every line break (and tab) turns into a space first, then `displaySafe`.
    var displaySafeLine: String {
        split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .joined(separator: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .displaySafe
    }
}
