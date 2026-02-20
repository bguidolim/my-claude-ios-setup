# Memory Templates & Examples

Reference file for the continuous-learning skill. Load this when creating or updating memories
to use the appropriate template structure.

---

## Learning Memory Template

```markdown
## Problem
[Clear description of the problem]

## Trigger Conditions
[When does this occur? Include exact error messages, symptoms, scenarios]

## Solution
[Step-by-step solution]

## Verification
[How to verify the solution worked]

## Example
[Concrete code example]

## Notes
[Caveats, edge cases, related considerations]

## References
[Links to documentation, articles, resources]
```

---

## Decision Memory Template (ADR-Inspired)

Use for architectural decisions, tool choices, or patterns with meaningful trade-offs.

```markdown
## Decision
[One-sentence summary of what was decided]

## Context
[Why this decision was needed. What problem or question prompted it?]

## Options Considered
- **Option A**: [Brief description] - [Pros/Cons]
- **Option B**: [Brief description] - [Pros/Cons]

## Choice
[Which option was selected and why]

## Consequences
[What are the implications? What does this enable or prevent?]

## Scope
[Where does this apply? Whole project? Specific modules? Specific scenarios?]

## Examples
[Code examples showing the decision in practice]

## References
[Related documentation, discussions, or resources]
```

---

## Simplified Decision Template

Use for straightforward preferences without complex trade-offs.

```markdown
## Decision
[What was decided]

## Rationale
[Why this choice]

## Examples
[How to apply it]
```

---

## Example 1: Learning — SwiftUI Task Cancellation on View Dismiss

Save to `.claude/memories/learning_swiftui_task_cancellation_on_view_dismiss.md`:

```
Write(
  file_path: "<project>/.claude/memories/learning_swiftui_task_cancellation_on_view_dismiss.md",
  content: "## Problem
Network requests continued running after the user navigated away from a view, causing updates to deallocated state and occasional crashes.

## Trigger Conditions
- View uses `.task { }` or `Task { }` inside `onAppear` to load data
- User navigates back before the request completes
- Error: `Publishing changes from background threads is not allowed` or EXC_BAD_ACCESS
- More frequent on slow networks where requests take longer

## Solution
1. Use `.task { }` modifier instead of `onAppear` + manual `Task { }` — SwiftUI cancels `.task` automatically on view dismiss
2. For manual tasks, store the `Task` handle and cancel it in `onDisappear`
3. Check `Task.isCancelled` or use `try Task.checkCancellation()` inside async loops
4. Use `@MainActor` on the view model to ensure state updates happen on the main thread

## Verification
Navigate away mid-request; confirm no console warnings, no state updates after dismiss, and no crashes under Thread Sanitizer.

## Example
```swift
// Preferred: .task modifier handles cancellation automatically
struct ProfileView: View {
    @State private var profile: Profile?

    var body: some View {
        content
            .task {
                profile = try? await profileService.fetch()
            }
    }
}

// If manual Task is needed: cancel explicitly
struct SearchView: View {
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        content
            .onChange(of: query) { newValue in
                searchTask?.cancel()
                searchTask = Task {
                    try? await Task.sleep(for: .milliseconds(300))
                    guard !Task.isCancelled else { return }
                    await viewModel.search(newValue)
                }
            }
            .onDisappear { searchTask?.cancel() }
    }
}
```

## Notes
- `.task(id:)` restarts the task when the id value changes, cancelling the previous one
- `URLSession` tasks respect cooperative cancellation — they throw `CancellationError` automatically
- Combine pipelines need explicit `.handleEvents(receiveCancel:)` or `AnyCancellable` storage

## References
- https://developer.apple.com/documentation/swiftui/view/task(priority:_:)"
)
```

---

## Example 2: Decision — Use OSLog Over Print Statements

Save to `.claude/memories/decision_tooling_oslog_logging.md`:

```
Write(
  file_path: "<project>/.claude/memories/decision_tooling_oslog_logging.md",
  content: "## Decision
Use `os.Logger` (OSLog) instead of `print()` for all application logging.

## Context
Needed a consistent logging approach that works with Instruments, Console.app, and Xcode's log filters while providing structured metadata and privacy controls.

## Options Considered
- **print()**: Zero setup, visible in Xcode console — but no filtering, no log levels, no privacy, stripped in Release builds only if manually guarded
- **OSLog / os.Logger**: Native integration with Apple tools, log levels, privacy redaction, minimal performance cost when logs are not collected — requires iOS 14+ for the modern API

## Choice
OSLog chosen because:
1. Integrates with Console.app and Instruments for on-device debugging
2. Log levels (debug, info, error, fault) allow filtering noise in production
3. Privacy annotations redact sensitive data by default in non-debug contexts
4. Near-zero overhead when a log level is not being collected by the system

## Consequences
- All modules define a `Logger` extension with a subsystem and category
- `print()` calls should be migrated to the appropriate log level when touched
- Debug-only verbose logs use `.debug` level (not collected unless streaming)
- User-facing data must use `\(value, privacy: .private)` in log interpolations

## Scope
All application code. Third-party libraries keep their own logging.

## Examples
```swift
import OSLog

extension Logger {
    static let networking = Logger(subsystem: Bundle.main.bundleIdentifier!, category: \"Networking\")
    static let persistence = Logger(subsystem: Bundle.main.bundleIdentifier!, category: \"Persistence\")
}

// Usage
Logger.networking.info(\"Request completed: \\(endpoint) status=\\(statusCode)\")
Logger.networking.error(\"Request failed: \\(error.localizedDescription)\")
Logger.persistence.debug(\"Cache hit for key: \\(key, privacy: .private)\")
```

## References
- https://developer.apple.com/documentation/os/logger"
)
```

---

## Example 3: Simple Preference Decision

Save to `.claude/memories/decision_architecture_protocol_composition.md`:

```
Write(
  file_path: "<project>/.claude/memories/decision_architecture_protocol_composition.md",
  content: "## Decision
Prefer protocol composition over class inheritance for shared behavior across types.

## Rationale
- Reduces coupling — types depend on protocol contracts, not base class implementation details
- Makes testing easier — conform to protocols with lightweight mocks instead of subclassing
- Avoids fragile base class problems and deep inheritance hierarchies
- Works with both structs and classes, keeping the door open for value semantics

## Examples
```swift
// Preferred: protocol composition with dependency injection
protocol PaymentProcessing: Sendable {
    func charge(amount: Decimal) async throws -> Receipt
}

protocol InventoryChecking: Sendable {
    func reserve(itemID: String, quantity: Int) async throws
}

struct OrderService {
    let payment: PaymentProcessing
    let inventory: InventoryChecking
}

// Avoid: inheriting shared behavior from a base class
class OrderService: BaseService {  // unclear what BaseService provides
    override func execute() { }
}
```"
)
```
