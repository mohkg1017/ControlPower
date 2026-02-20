import Foundation

extension Error {
    var controlPowerSanitizedDescription: String {
        let sanitized = localizedDescription
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sanitized.isEmpty else {
            return "Unknown error"
        }
        return String(sanitized.prefix(200))
    }
}
