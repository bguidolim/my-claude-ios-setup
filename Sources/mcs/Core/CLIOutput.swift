import Foundation

/// Terminal output with ANSI color support and structured logging.
struct CLIOutput: Sendable {
    let colorsEnabled: Bool

    init(colorsEnabled: Bool? = nil) {
        if let explicit = colorsEnabled {
            self.colorsEnabled = explicit
        } else {
            self.colorsEnabled = isatty(STDOUT_FILENO) != 0
        }
    }

    // MARK: - ANSI Codes

    private var red: String { colorsEnabled ? "\u{1B}[0;31m" : "" }
    private var green: String { colorsEnabled ? "\u{1B}[0;32m" : "" }
    private var yellow: String { colorsEnabled ? "\u{1B}[1;33m" : "" }
    private var blue: String { colorsEnabled ? "\u{1B}[0;34m" : "" }
    private var cyan: String { colorsEnabled ? "\u{1B}[0;36m" : "" }
    private var bold: String { colorsEnabled ? "\u{1B}[1m" : "" }
    private var dim: String { colorsEnabled ? "\u{1B}[2m" : "" }
    private var reset: String { colorsEnabled ? "\u{1B}[0m" : "" }

    // MARK: - Logging

    func info(_ message: String) {
        write("\(blue)[INFO]\(reset) \(message)\n")
    }

    func success(_ message: String) {
        write("\(green)[OK]\(reset) \(message)\n")
    }

    func warn(_ message: String) {
        write("\(yellow)[WARN]\(reset) \(message)\n")
    }

    func error(_ message: String) {
        write("\(red)[ERROR]\(reset) \(message)\n", to: .standardError)
    }

    func header(_ title: String) {
        let bar = "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        write("\n\(bold)\(bar)\(reset)\n")
        write("\(bold)  \(title)\(reset)\n")
        write("\(bold)\(bar)\(reset)\n")
    }

    func step(_ current: Int, of total: Int, _ message: String) {
        let divider = "──────────────────────────────────────────"
        write("\n\(bold)[\(current)/\(total)] \(message)\(reset)\n")
        write("\(dim)\(divider)\(reset)\n")
    }

    func plain(_ message: String) {
        write("\(message)\n")
    }

    func dimmed(_ message: String) {
        write("  \(dim)\(message)\(reset)\n")
    }

    // MARK: - Prompts

    /// Ask a yes/no question. Returns true for yes, false for no.
    func askYesNo(_ prompt: String, default defaultValue: Bool = true) -> Bool {
        let hint = defaultValue ? "[Y/n]" : "[y/N]"
        while true {
            write("  \(prompt) \(hint): ")
            guard let answer = readLine()?.trimmingCharacters(in: .whitespaces) else {
                return defaultValue
            }
            if answer.isEmpty {
                return defaultValue
            }
            switch answer.lowercased() {
            case "y", "yes":
                return true
            case "n", "no":
                return false
            default:
                write("  Please answer y or n.\n")
            }
        }
    }

    // MARK: - Output

    private enum OutputTarget {
        case standardOutput
        case standardError
    }

    private func write(_ string: String, to target: OutputTarget = .standardOutput) {
        let data = Data(string.utf8)
        switch target {
        case .standardOutput:
            FileHandle.standardOutput.write(data)
        case .standardError:
            FileHandle.standardError.write(data)
        }
    }
}
