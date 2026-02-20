---
name: continuous-learning
description: |
  Continuous learning system that monitors all user requests and interactions to identify
  learning opportunities and project decisions. Active during: (1) Every user request and task,
  (2) All coding sessions and problem-solving activities, (3) When discovering solutions, patterns,
  or techniques, (4) When making architectural or design decisions, (5) When establishing best
  practices or preferences, (6) During /retrospective sessions. Automatically evaluates whether
  current work contains valuable knowledge or decisions and saves memories as files in
  <project>/.claude/memories/.
allowed-tools:
  - Write
  - Read
  - Glob
  - Edit
  - Bash
  - mcp__docs-mcp-server__search_docs
  - mcp__docs-mcp-server__list_libraries
  - AskUserQuestion
  - TaskCreate
  - TaskUpdate
  - TaskList
---

# Continuous Learning Skill

Extract reusable knowledge from work sessions and save it as memory files in `<project>/.claude/memories/`.

## Memory Categories

### Learnings (`learning_<topic>_<specific>`)

Knowledge discovered through debugging, investigation, or problem-solving that wasn't obvious beforehand.

**Extract when:**
- Solution required significant investigation (not a documentation lookup)
- Error message was misleading — root cause was non-obvious
- Discovered a workaround for a tool/framework limitation
- Found a workflow optimization through experimentation

**Examples:** `learning_swiftui_task_cancellation_on_view_dismiss`, `learning_core_data_batch_insert_memory_spike`, `learning_xcode_preview_crash_missing_environment`

### Decisions (`decision_<domain>_<topic>`)

Deliberate choices about how the project should work.

**Extract when:**
- Architectural choice made (patterns, structures, dependencies)
- Convention or style preference established
- Tool/library selected over alternatives with reasoning
- User says "let's use X", "I prefer Y", "from now on..."
- Trade-off resolved between competing concerns

**Domain prefixes:**

| Domain | Examples |
|--------|----------|
| `architecture` | `decision_architecture_mvvm_coordinators` |
| `codestyle` | `decision_codestyle_naming_conventions` |
| `tooling` | `decision_tooling_swiftlint_config` |
| `testing` | `decision_testing_snapshot_strategy` |
| `networking` | `decision_networking_retry_policy` |
| `ui` | `decision_ui_design_system` |
| `data` | `decision_data_core_data_vs_swiftdata` |
| `project` | `decision_project_minimum_ios_version` |

---

## Extraction Workflow

### Step 1: Evaluate the Current Task

After completing any task, ask:
- Did this require non-obvious investigation or debugging?
- Was a choice made about architecture, patterns, or approach?
- Did the user express a preference or convention?
- Would future sessions benefit from having this documented?

If NO to all → skip. If YES to any → continue.

### Step 2: Search Existing Knowledge

**Always search docs-mcp-server first** (semantic search across documentation and project memories):

```
mcp__docs-mcp-server__search_docs(library: "<project>", query: "<topic>")
```

**Fall back to file listing** if search_docs returns no results:

```
Glob(pattern: ".claude/memories/*.md")
```

Determine if: update an existing memory, cross-reference related memories, or knowledge is already captured.

### Step 3: Research (When Appropriate)

**For general topics** — use Claude Code's built-in web search:
```
WebSearch(query: "<topic> best practices <current year>")
```

**Skip research for:** project-specific conventions, personal preferences, time-sensitive captures.

### Step 4: Structure and Save

Read [references/templates.md](references/templates.md) for the full template structures.

**For learnings:** Use the Learning Memory Template (Problem → Trigger Conditions → Solution → Verification → Example → Notes → References).

**For decisions:** Use the ADR-Inspired Template for complex trade-offs, or the Simplified Template for straightforward preferences.

**Save:**
```
Write(file_path: "<project>/.claude/memories/<category>_<topic>_<specific>.md", content: "<structured markdown>")
```

**Update existing:**
```
Edit(file_path: "<project>/.claude/memories/<existing_name>.md", old_string: "<section to update>", new_string: "<updated section>")
```

---

## Quality Gates

Before saving any memory, verify:
- [ ] Name follows the correct pattern (`learning_` or `decision_<domain>_`)
- [ ] Content uses the appropriate template from references/templates.md
- [ ] Solution is verified to work (not theoretical)
- [ ] Content is specific enough to be actionable
- [ ] Content is general enough to be reusable
- [ ] No sensitive information (credentials, internal URLs)
- [ ] Does not duplicate existing memories
- [ ] References included if external sources were consulted

---

## Retrospective Mode

When `/retrospective` is invoked:

1. Review conversation history for extractable knowledge
2. Search existing memories via `search_docs` (fall back to `Glob(".claude/memories/*.md")` if unavailable)
3. List candidates with brief justifications
4. Extract top 1-3 highest-value memories
5. Report what was created and why

---

## Tool Reference

| Tool | Purpose |
|------|---------|
| `mcp__docs-mcp-server__search_docs` | **Primary:** Semantic search across docs and memories |
| `mcp__docs-mcp-server__list_libraries` | List indexed libraries |
| `Glob` | **Fallback:** List all memory files (`.claude/memories/*.md`) |
| `Read` | Read a specific memory file |
| `Write` | Create new memory file |
| `Edit` | Update existing memory file |
| `Bash` | Remove outdated memory file (`rm`) |
| `WebSearch` | Built-in web search for general topics |
