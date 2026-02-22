import Foundation

/// Template content contributed by the Core tech pack.
enum CoreTemplates {
    /// Symlink note — included when CLAUDE.md is a symlink in the project.
    /// Prevents Claude from redundantly re-reading the original file.
    static let symlinkNote = """
        > **Note:** `CLAUDE.md` is a symlink — its content is already loaded at session start. \
        Do not re-read the original file via tool calls.
        """

    /// Serena code-editing preference — only injected when Serena MCP server is installed.
    /// Instructs Claude to prefer Serena's symbolic tools for code editing tasks.
    /// Tool names are sourced from Serena's MCP interface; update if Serena's API changes.
    static let serenaSection = """
        ## Code Editing — Prefer Serena's Symbolic Tools

        When Serena's tools are available and the language is supported, **prefer Serena's \
        symbolic code-editing tools** over the built-in file tools:

        - **Navigation**: Use `find_symbol`, `find_referencing_symbols`, and `get_symbols_overview` \
        instead of Grep/Glob for locating code.
        - **Editing**: Use `replace_symbol_body`, `insert_after_symbol`, `insert_before_symbol`, \
        and `rename_symbol` instead of Edit for modifying code.
        - **Context**: Use `get_symbols_overview` to understand file structure before making changes.
        - **Before removing or renaming** any symbol, verify it is unused via `find_referencing_symbols`.

        Serena auto-detects the project's languages. For files or languages Serena does not support, \
        fall back to the standard Read, Edit, Grep, and Glob tools.
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
