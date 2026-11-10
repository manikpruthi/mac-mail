import Foundation

/// Shared input-safety helpers: strict address validation and control-character stripping.
enum MailSafety {

    /// Strict addr-spec check for anything placed on an SMTP envelope or a header. Rejects
    /// CR/LF/controls, whitespace, and the separators that would let one address become two.
    static func isValidAddrSpec(_ s: String) -> Bool {
        guard !s.isEmpty, s.count <= 254 else { return false }
        guard s.firstIndex(of: "@") != nil, s.firstIndex(of: "@") == s.lastIndex(of: "@") else { return false }
        let parts = s.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return false }
        // Dots separate atoms and labels: none may lead, trail or repeat ("a..b@x.com", "a@x..com").
        // A domain without a dot ("user@localhost") is valid syntax and stays accepted.
        for part in parts where part.hasPrefix(".") || part.hasSuffix(".") || part.contains("..") { return false }
        for ch in s.utf8 {
            switch ch {
            case 33...126: // printable ASCII
                switch ch {
                case UInt8(ascii: "<"), UInt8(ascii: ">"), UInt8(ascii: "\""),
                     UInt8(ascii: ","), UInt8(ascii: ";"), UInt8(ascii: ":"), UInt8(ascii: "\\"):
                    return false
                default: break
                }
            default: return false // controls, space, DEL, non-ASCII
            }
        }
        return true
    }

    /// Removes all C0 control characters and DEL (used before writing header values).
    static func stripControls(_ s: String) -> String {
        guard s.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else { return s }
        return String(String.UnicodeScalarView(s.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7f }))
    }
}
