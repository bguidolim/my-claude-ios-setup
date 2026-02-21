import Foundation

/// Template content contributed by the Core tech pack.
enum CoreTemplates {
    /// Symlink note — included when CLAUDE.md is a symlink in the project.
    /// Prevents Claude from redundantly re-reading the original file.
    static let symlinkNote = """
        > **Note:** `CLAUDE.md` is a symlink — its content is already loaded at session start. \
        Do not re-read the original file via tool calls.
        """

    /// KB search mandate — only injected when continuous learning is installed.
    /// Instructs Claude to search the project knowledge base before starting work.
    static let continuousLearningSection = """
        ## MANDATORY — Before Starting Any Task

        Before writing code, planning, or exploring — **always search the knowledge base first**:

        1. **Search the KB** — call `search_docs` with library `__REPO_NAME__` and keywords \
        relevant to the task. Try multiple keyword variations if needed.
        2. **Read matching memories** — review any relevant results for full context \
        (architecture decisions, gotchas, patterns from past sessions).

        Only after these steps, proceed with discovery and implementation.
        """
}
