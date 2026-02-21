import Foundation

/// Manages Ollama lifecycle: checking status, starting, and pulling models.
struct OllamaService: Sendable {
    let shell: ShellRunner
    let environment: Environment

    private static let apiURL = Constants.Ollama.apiTagsURL

    /// Whether the Ollama API is responding.
    func isRunning() -> Bool {
        shell.shell("curl -s --max-time 2 \(Self.apiURL)").succeeded
    }

    /// Whether the nomic-embed-text model is available.
    func hasEmbeddingModel() -> Bool {
        let result = shell.run(Constants.CLI.env, arguments: ["ollama", "list"])
        return result.succeeded && result.stdout.contains(Constants.Ollama.embeddingModel)
    }

    /// Attempt to start Ollama via brew services, then macOS app.
    /// Returns true if Ollama is running after attempts.
    func start() -> Bool {
        if isRunning() { return true }

        let brew = Homebrew(shell: shell, environment: environment)
        if brew.isPackageInstalled("ollama") {
            brew.startService("ollama")
            if waitUntilRunning(seconds: 10) { return true }
        }

        shell.shell("open -a Ollama")
        return waitUntilRunning(seconds: 10)
    }

    /// Pull the nomic-embed-text model if not already present.
    /// Returns the result of the pull, or nil if already installed.
    func pullEmbeddingModelIfNeeded() -> ShellResult? {
        guard !hasEmbeddingModel() else { return nil }
        return shell.run(Constants.CLI.env, arguments: ["ollama", "pull", Constants.Ollama.embeddingModel])
    }

    /// Poll until the API responds or timeout elapses.
    func waitUntilRunning(seconds: Int) -> Bool {
        for _ in 0..<seconds {
            if isRunning() { return true }
            Thread.sleep(forTimeInterval: 1)
        }
        return false
    }
}
