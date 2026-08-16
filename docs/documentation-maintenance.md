# Documentation maintenance

The rule: **a change under `lib/` (or `pubspec.yaml`) is not finished until the docs
that describe it are true again.** This page says what to update, and describes the
automation that reminds you.

## What to update when

| You changed | Re-read and fix |
| --- | --- |
| a provider in `study_provider.dart` (added, renamed, removed, changed a method) | CLAUDE.md "State" list, `docs/architecture.md` provider graph |
| eval signs, thresholds, accuracy formula, review loop | CLAUDE.md "Engine eval convention" + "Move classification", `docs/evaluation.md` |
| `EngineService` API, either implementation, `CloudEvalService` | CLAUDE.md "Engine abstraction", `docs/architecture.md` engine layer |
| `MoveNode` / `MoveTree` / `GameEntry` fields | `docs/data-model.md`, plus CLAUDE.md if an invariant changed |
| SQLite schema, `version`, `onUpgrade`, CRUD signatures | CLAUDE.md "Persistence", `docs/data-model.md` schema block |
| PGN parsing or export behaviour | `docs/data-model.md` PGN section |
| screens, widgets, layout breakpoints, theme | `docs/ui-map.md`, CLAUDE.md "UI layout" |
| files added/moved/deleted under `lib/` | CLAUDE.md repository map |
| `pubspec.yaml` deps, SDK constraint, `dependency_overrides` | CLAUDE.md "Project" + "Conventions" |
| CI workflow, build flags | CLAUDE.md "Project" / "Common commands" |

Keep the docs descriptive, not aspirational: they should say what the code does
today. If you find an existing statement that was already wrong, fix it in passing.

## The Claude Code hooks

Configured in [`.claude/settings.json`](../.claude/settings.json), backed by two
scripts in `.claude/hooks/`.

### 1. `PostToolUse` → `mark-docs-stale.sh`

Matches `Write|Edit|MultiEdit|NotebookEdit`. It reads the tool payload from stdin,
takes `tool_input.file_path`, and if the path is `lib/**.dart`, `pubspec.yaml`, or
`packages/*/lib/**.dart`, appends it to a per-session scratch file:

```
.claude/.docs-stale-<session_id>
```

Doc files themselves are ignored, so updating `docs/` never re-arms the reminder.
The script always exits 0 — it can never block a tool call.

### 2. `Stop` → `docs-freshness-reminder.sh`

When a turn ends, this checks for a non-empty scratch file. If there is one, it
deletes it and returns:

```json
{ "decision": "block", "reason": "…list of changed files + what to reconcile…" }
```

`decision: "block"` hands control back to Claude with that reason instead of ending
the turn, so the doc pass happens inside the same turn as the code change.

Two loop guards: the scratch file is deleted as the block is emitted (so the next
Stop is clean), and if `stop_hook_active` is already true the hook clears state and
exits 0 without blocking. The reminder therefore fires **at most once per turn**.

### State files

`.claude/.docs-stale-*` are session scratch files and are gitignored. They are safe
to delete at any time. `.claude/settings.json`, `.claude/hooks/`, and
`.claude/commands/` are checked in and shared by the team.

If you edit `.claude/settings.json` during a session, Claude Code may not pick the
change up until you open `/hooks` once or restart the session.

## `/update-docs`

`.claude/commands/update-docs.md` — a slash command that audits **all** of
`CLAUDE.md` and `docs/` against the current code, rather than only the files touched
this turn. Use it after a large refactor, after merging a branch, or when the docs
feel stale in a way the per-turn hook wouldn't have caught.

## Git-side check (optional, for human commits)

The hooks above only cover edits made through Claude Code. For everything else:

```bash
scripts/check-docs-freshness.sh     # inspect the staged diff, warn on drift
scripts/install-git-hooks.sh        # install it as .git/hooks/pre-commit
```

The check compares staged paths: if the commit touches `lib/` or `pubspec.yaml` but
no `CLAUDE.md` / `docs/**.md`, it prints a warning listing the files. It **exits 0**
— it warns, it does not block a commit. Set `DOCS_CHECK_STRICT=1` to make it fail
instead, or `git commit --no-verify` to skip it entirely.

## Turning it off

- One turn: nothing to do — the reminder fires once and clears itself.
- Permanently: delete the `hooks` block from `.claude/settings.json` (or the whole
  file), and `rm .git/hooks/pre-commit` if you installed it.
- Temporarily for a session: `claude --settings '{"disableAllHooks": true}'`.
