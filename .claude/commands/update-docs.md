---
description: Audit CLAUDE.md and docs/ against the current code and fix any drift
---

Audit this repository's documentation against the code as it exists right now, and
fix everything that has drifted. This is the full sweep — unlike the per-turn Stop
hook, do not limit yourself to files changed recently.

Documents in scope:

- `CLAUDE.md`
- `docs/architecture.md`
- `docs/evaluation.md`
- `docs/data-model.md`
- `docs/ui-map.md`
- `docs/documentation-maintenance.md`

Check each of these against the source, and correct any mismatch:

1. **Repository map** in CLAUDE.md — every file under `lib/` listed, nothing listed
   that no longer exists.
2. **Providers** — the list in CLAUDE.md and the graph in `docs/architecture.md`
   match the providers actually declared in `lib/providers/study_provider.dart`,
   including notifier method names and defaults.
3. **Engine API** — `analyzePosition` / `evaluatePosition` / `isReady` /
   `isAvailable` / `stop` / `dispose` signatures identical in
   `engine_service_native.dart` and `engine_service_web.dart`, and described
   correctly in CLAUDE.md and `docs/architecture.md`.
4. **Eval conventions** — sign conventions, `mate == 0` semantics, the null-eval
   rule, and the classification thresholds in `docs/evaluation.md` match
   `move_evaluator.dart` and `ReviewNotifier`.
5. **Accuracy and redistribution** — the formulas quoted in `docs/evaluation.md`
   match the code character for character.
6. **Schema** — table definitions, column list, `version`, and the `onUpgrade`
   strategy in `docs/data-model.md` match `database_service.dart`.
7. **Models** — `MoveNode` / `MoveTree` / `GameEntry` fields and invariants in
   `docs/data-model.md`.
8. **PGN** — parse and export behaviour in `docs/data-model.md` matches
   `pgn_parser.dart`.
9. **UI** — screens, widget list, layout breakpoints, and theme notes in
   `docs/ui-map.md` match `lib/screens/` and `lib/widgets/`.
10. **Commands and deps** — `flutter` commands, SDK constraint, dependencies,
    `dependency_overrides`, and CI build flags in CLAUDE.md match `pubspec.yaml`,
    `analysis_options.yaml`, and `.github/workflows/`.

Rules:

- Read the code before changing a doc; do not trust the existing prose.
- Prefer editing in place over rewriting whole files.
- Keep the documented behaviour descriptive of today's code — no plans or wishes.
- Do not change any code to match a doc. If the code looks wrong, note it in your
  reply instead of editing it.
- Finish with a short summary of what drifted, or state plainly that the docs were
  already accurate.
