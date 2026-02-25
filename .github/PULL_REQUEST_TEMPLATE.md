## Summary

<!--
What does this PR do and why? One to three sentences.
-->

## Changes

<!--
Bullet list of what changed. Focus on the "what" — the summary covers the "why".
-->

-

## Test plan

- [ ] `swift test` passes locally
- [ ] Affected commands verified with a real pack (e.g. `mcs sync`, `mcs doctor`)

<details>
<summary>Checklist for engine changes</summary>

Only check items that apply to this PR. Delete irrelevant ones.

- [ ] `.shellCommand` components have `supplementaryDoctorChecks` defined (`deriveDoctorCheck()` returns `nil` for shell actions)
- [ ] Any `fix()` implementation does cleanup/migration only — never installs or registers resources
- [ ] State migrations are guarded by `isNeeded()` to stay idempotent with `mcs sync`
- [ ] `CLAUDE.md` updated if architecture, commands, or subsystems changed
- [ ] `MCSVersion.current` bumped in `Sources/mcs/CLI.swift` for user-visible changes

</details>
