import Foundation

enum TemplateEngine {
    /// Substitute placeholders in a template string.
    /// Placeholders are in the format `__PLACEHOLDER_NAME__`.
    static func substitute(
        template: String,
        values: [String: String],
        emitWarnings: Bool = true
    ) -> String {
        var result = template

        // Replace all provided placeholders
        for (key, value) in values {
            let placeholder = "__\(key)__"
            result = result.replacingOccurrences(of: placeholder, with: value)
        }

        // Strip <!-- EDIT: ... --> comment lines
        let lines = result.components(separatedBy: "\n")
        let filtered = lines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !trimmed.hasPrefix("<!-- EDIT:") || !trimmed.hasSuffix("-->")
        }
        result = filtered.joined(separator: "\n")

        // Warn about unreplaced placeholders
        let unreplaced = findUnreplacedPlaceholders(in: result)
        if emitWarnings, !unreplaced.isEmpty {
            let message = "Unreplaced placeholders found: \(unreplaced.joined(separator: ", "))"
            FileHandle.standardError.write(Data("[WARN] \(message)\n".utf8))
        }

        return result
    }

    /// Find any remaining `__PLACEHOLDER__` tokens in a string.
    static func findUnreplacedPlaceholders(in text: String) -> [String] {
        var placeholders: [String] = []
        let pattern = "__[A-Z][A-Z0-9_]+__"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, range: range)
        for match in matches {
            if let r = Range(match.range, in: text) {
                let placeholder = String(text[r])
                if !placeholders.contains(placeholder) {
                    placeholders.append(placeholder)
                }
            }
        }
        return placeholders
    }
}
