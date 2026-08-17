# CLAUDE.md

Guidance for Claude Code (claude.ai/code) when working in this repository.

## Project

Centipawn is a Flutter chess study/analysis app. It imports PGN games, plays them
out on an interactive board, evaluates positions (local Stockfish only — native
via FFI, web via WebAssembly; the Lichess cloud-eval client is still there but
switched off, see `kUseCloudEval`), and runs a "game review" that classifies every mainline
move and computes per-side accuracy. State is Riverpod; games and their move trees
are persisted in a local SQLite database via `sqflite`.

Dart SDK `^3.10.1`. Targets Android, iOS, web, Windows, macOS, Linux. The web build
is deployed to Firebase Hosting on every push to `main`
(`.github/workflows/firebase-hosting-merge.yml`, Flutter 3.38.3, `--wasm`).

## Git workflow

Deployment is push-triggered off `main` — nothing else builds or ships the web app.
After finishing a change on a branch, merge it into `main` and push `main` before
ending the turn (fast-forward when possible; otherwise merge normally). A branch
left unmerged has not shipped, no matter how complete the work looks.

## Common commands

```
flutter pub get                       # install deps
flutter run                           # default device
flutter run -d chrome                 # web (Stockfish wasm worker, sqlite3-wasm)
flutter run -d windows                # desktop — note: no chess engine there yet
flutter analyze                       # lint / static analysis (flutter_lints)
dart format lib                       # formatting; there is no separate format step
flutter test                          # unit tests (UCI protocol, Stage C, PGN, web assets)
flutter build apk|ios|web|windows     # production builds
flutter build web --wasm --release    # what CI builds
```

## Repository map

```
lib/
  main.dart                  Firebase init → anonymous sign-in → GameListScreen
  theme.dart                 AppColors + buildAppTheme() (light-only Lichess-ish palette)
  firebase_options.dart      generated
  models/
    game_entry.dart          GameEntry — per-game metadata row
    move_node.dart           MoveNode / MoveTree — the game as a tree
  providers/
    study_provider.dart      ALL app state (~970 lines, single source of truth)
  services/
    engine_service.dart      single EngineService over UciEngine + transport
    uci_engine.dart          the whole UCI protocol, platform-neutral
    uci_transport.dart       conditional export: native | web
    uci_transport_native.dart / _web.dart   stockfish FFI | Web Worker + wasm
    stockfish_web_assets.dart  names/sizes of the committed web/ artifacts
    engine_types.dart        EngineEvaluation, PositionEvals, PvLine, SearchResult
    cloud_eval_service.dart  Lichess /api/cloud-eval client
    move_evaluator.dart      win-probability math + move classification
    best_line_annotator.dart attaches engine PV as a variation
    opening_service.dart     ECO detection by longest SAN prefix
    pgn_parser.dart          PGN parse + export (movetext, mainline, full PGN)
    database_service.dart    sqflite schema v5 + CRUD + tree load/save
    database_factory_setup*.dart  web needs an sqlite3-wasm factory; native no-op
    auth_service.dart        FirebaseAuth wrapper (anon / email / Google)
  screens/                   game_list, game, settings, login
  widgets/                   chess_board, study_notation, eval_bar, eval_chart,
                             responsive_layout, edit_game_metadata_dialog
web/                         index.html + committed wasm blobs (sqlite3,
                             stockfish-18-lite-single.{js,wasm})
packages/dartchess/          vendored dartchess 0.12.3 (dependency_overrides)
test/                        unit tests; critical_moments/data holds JSON fixtures
tool/                        validate_critical_moments.dart, capture_critical_fixture.dart
docs/                        deep-dive docs — see below
```

## Deep-dive docs

Read the relevant one before changing that area; keep them current (see
"Documentation upkeep").

| Doc | Covers |
| --- | --- |
| [docs/architecture.md](docs/architecture.md) | Provider graph, load/save lifecycle, engine + cloud eval layer |
| [docs/evaluation.md](docs/evaluation.md) | Eval sign conventions, review pipeline, classification, accuracy |
| [docs/data-model.md](docs/data-model.md) | `MoveNode`/`MoveTree`, `GameEntry`, SQLite schema, PGN I/O |
| [docs/ui-map.md](docs/ui-map.md) | Screens, widgets, responsive layout, theming |
| [docs/critical-moments.md](docs/critical-moments.md) | Critical-moment detection: stages, components, gates, time regression |
| [docs/documentation-maintenance.md](docs/documentation-maintenance.md) | What to update when, and how the doc hooks work |
| [docs/react-migration-assessment.md](docs/react-migration-assessment.md) | Whether to port to React/TS, and what would change the answer |

## Architecture essentials

### Engine abstraction

There is **one** `EngineService` for every platform (`lib/services/engine_service.dart`).
The UCI protocol lives in `lib/services/uci_engine.dart` and is shared; only the
*transport* is platform-specific, picked by a conditional export:

```dart
// services/uci_transport.dart
export 'uci_transport_native.dart' if (dart.library.js_interop) 'uci_transport_web.dart';
```

A `UciTransport` is just `isSupported` / `start()` / `send(String)` / `lines` /
`threads` / `hashMb` / `dispose()`. Everything subtle — search-generation guards,
the `readyok` barrier, `bestmove` discrimination, MultiPV assembly, `bestByDepth`
capture, the search queue and timeouts — is in `UciEngine` and shared. There used
to be two copies of that logic and they had already drifted (`analyzePosition`
returned `Future<void>` on one platform and `void` on the other). Adding a
platform now costs one transport and no protocol code.

`EngineService` exposes `evaluationStream` (of `PositionEvals`), `ensureReady()`,
`analyzePosition(fen, multiPv:, maxDepth:)`, `evaluatePosition(fen, depth:)`,
`runSearch(fen, depth:, multiPv:)`, `isSupported`, `isReady`,
`unavailableReason`, `stop()`, `dispose()`.

`analyzePosition` defaults to `multiPv: 3` and `maxDepth: null` (`go infinite`).
The app always passes both: three lines is what the suggested-lines box shows,
and bounding the depth is what stops the single-threaded web build pinning a core
forever on one position. It used to hardcode `MultiPV 1` + `go infinite`, which
is why only the first suggested line ever appeared.

**Two score units, on purpose.** `EngineEvaluation.scoreCp` is in **pawns** (the
eval bar and `combinedEvalProvider` consume them); `PvLine.scoreCp` is in **raw
centipawns** (`PvLine.normalisedCp` folds mate onto a centipawn scale). Both are
pinned by `test/engine/uci_engine_test.dart` — getting it wrong makes the eval
bar read 100x off.

**Engine availability is not uniform:**

| Platform | Engine |
| --- | --- |
| Android, iOS | Stockfish via FFI (`stockfish` pub package) |
| Web | Stockfish 18 WASM in a Web Worker, lazily loaded on first use |
| Windows, macOS, Linux | **none yet** — the `stockfish` package ships plugin code for android/ios only, so `isSupported` is false |

Loading is lazy on web (7.3 MB), so `isSupported` means "an engine can run here",
not "an engine is loaded". Await `ensureReady()` before treating a result as
analysis; it returns false and sets `unavailableReason` when the engine cannot
start. `evaluatePosition` returns **null** rather than a fabricated 0.00.

Web searches shallower than native — see `docs/critical-moments.md`.

### Move tree, not a move list

A game is a `MoveTree` of `MoveNode`s. Each node stores its own FEN, SAN, UCI,
`evaluation`/`mate`/`quality`, the parent position's `bestMoveUci`/`bestMoveEval`/
`bestMoveMate`, comments, NAGs, and children. First child = mainline, the rest are
variations.

- `MoveTree.mainline` walks `children.first` from root, **excluding the root**.
- `MoveNode.isBlackMove` and `moveNumber` are derived by walking up to the root —
  depth 1 = White's first move.
- New user moves go through `ActiveNodeNotifier.makeMove`, which navigates to an
  existing child when the SAN matches, otherwise appends a child and calls
  `MoveTreeNotifier.persist()` + `refresh()`.

### State: `lib/providers/study_provider.dart`

Everything lives here. The providers that matter most:

- `gameListProvider` (AsyncNotifier) — `GameEntry` rows; seeds 5 famous games when
  the DB is empty. Add/import/update/delete go through it.
- `selectedGameProvider` — the open `GameEntry`.
- `moveTreeProvider` — the tree; `loadFromDb`, `setTree`, `loadPgn`, `refresh`,
  `persist`.
- `activeNodeProvider` — current position; `goForward/goBack/goFirst/goLast/setNode/
  makeMove`. `setNode` kicks off `engine.analyzePosition(fen, multiPv:, maxDepth:)`
  when the engine is on.
- `engineRunningProvider` — live-analysis toggle (defaults **true**).
- `kUseCloudEval` (**false**), `kAnalysisMultiPv` (3), `analysisDepth(ref)`,
  `analysisCacheProvider` — the four knobs every analysis path reads. Cloud eval
  is off; depth comes from the settings slider, capped at `kShallowDepthWeb` on
  web; the cache is what stops the review and critical moments searching the same
  positions twice. See `docs/evaluation.md`.
- `engineEvaluationProvider` (stream, local) + `cloudEvalProvider` (one-shot,
  Lichess — currently short-circuits to `PositionEvals.none`) → merged by
  `combinedEvalProvider`. Both sources yield a
  `PositionEvals(fen, evals)`; the merge drops anything whose FEN isn't the active
  node's, then picks the higher depth. Its result is therefore always for the
  current position — widgets render it directly, with no freshness flag.
- `reviewProvider` — the game review; see `docs/evaluation.md`. Searches at
  `kAnalysisMultiPv` and fills `analysisCacheProvider`.
- `criticalMomentsProvider` — critical-moment detection; see
  `docs/critical-moments.md`. Runs on Android/iOS/web; Stage A reuses the
  review's cached searches, so only Stage B costs time. Desktop has no engine, so
  it sets `unavailableReason` instead of a report.
- `criticalMomentsByPlyProvider` — the moments keyed by mainline ply index, for
  the notation badges.
- `reviewDepthProvider`, `myNamesProvider` — persisted in `SharedPreferences`.
  `reviewDepthProvider` drives *all* analysis despite the name; read it through
  `analysisDepth(ref)`.
- `customShapesProvider` — user circles/arrows keyed by `g<gameId>::<fen>`.
- `boardFlippedProvider`, `boardEditModeProvider`, `drawColorProvider`,
  `showThreatArrowProvider`, `authStateProvider`.

### Engine eval convention

Stockfish and `CloudEvalService` both hand back scores from the **side-to-move's**
POV (`CloudEvalService` converts Lichess's White-POV numbers before returning;
it is unused while `kUseCloudEval` is false).
`ReviewNotifier._toCpWhitePerspective` normalizes to **centipawns from White's
perspective**, mate included (`±10000`).

Stored on `MoveNode`: `evaluation` is in **pawns** (cp/100), `mate` is signed from
White's POV. `mate == 0` means "the side to move has just been mated". Preserve
this — the eval bar and eval chart depend on it.

Game-over positions never reach the engine or the cloud: `ReviewNotifier._terminalEval`
answers them from dartchess (checkmate → `mate: 0`, stalemate/insufficient material
→ 0.00). A position nothing can evaluate yields a **null** eval, which leaves
`evaluation`/`quality` null and breaks the drop chain. Never substitute 0.00 — it
reads as dead-equal and fabricates huge swings on the surrounding moves.

### Move classification

`MoveEvaluator.classifyMove(ChessEvaluation best, ChessEvaluation actual, bool isWhiteTurn)`
converts both to win probability (Lichess logistic curve, `cpToWinProb`) and
classifies the drop via `classifyByWpDrop`: ≥20 pp blunder, ≥10 mistake, ≥5
inaccuracy, otherwise **null** (no label). `MoveQuality` also has `best`/`excellent`/
`good` values, used for NAG export but not produced by the review.

The review calls `classifyByWpDrop` directly so it can redistribute horizon-shift
drops backward onto the move that actually deviated — see `docs/evaluation.md`.

### Persistence

`DatabaseService` opens `centipawn.db` at **schema version 5**, two tables:
`games` (metadata, incl. `whiteAccuracy`/`blackAccuracy`/`openingCode`/`lastFen`)
and `move_nodes` (one row per node, `parentId` + `orderIndex`, index 0 = mainline).
There is no PGN column and no `analysisJson` column — analysis lives on the node rows.

`onUpgrade` is **reseed-only**: it drops both tables and recreates the schema, and
the game list re-seeds on next launch. If you change the schema, bump `version` and
keep (or deliberately replace) that strategy.

### UI layout

`main.dart` → `GameListScreen` → `GameScreen`. `widgets/responsive_layout.dart`
picks a layout from `MediaQuery.displayFeatures` (Z Fold hinge → book/flex postures)
falling back to width: >600 px = 60/40 board/notation row, otherwise a vertical stack.

## Conventions worth knowing

- `MoveNode` is `// ignore: must_be_immutable` because it uses Equatable despite
  mutable fields (`evaluation`, `mate`, `quality`, `bestMove*`, `children`). Don't
  "fix" this without restructuring how analysis is written back into the tree.
- After changing the tree's shape, call `MoveTreeNotifier.refresh()` (it rebuilds
  `MoveTree.withRoot(state.root)`) so notation/chart widgets rebuild — a mutation
  in place is invisible to Riverpod otherwise.
- `avoid_print: true` is enforced; use `debugPrint`.
- Piece SVGs live in `assets/` and are registered wholesale under
  `flutter.assets: - assets/` in `pubspec.yaml`.
- `packages/dartchess` is a vendored copy of dartchess 0.12.3 patched so
  `_popcnt64()` avoids 64-bit literals dart2js/dart2wasm can't represent. Don't
  drop the `dependency_overrides` entry without re-testing `flutter build web`.
- `BestLineAnnotator` marks its generated variation with the `[eng]` comment so
  re-reviews can replace it; `PgnParser` filters `[eng]` out of exports.

## Documentation upkeep

**When you change code under `lib/` (or `pubspec.yaml`), update the docs in the
same turn.** Concretely: re-read the section of `CLAUDE.md` and the `docs/` page
that covers the area you touched, and fix anything your change made untrue —
provider names, method signatures, schema version, eval conventions, file layout.

This is enforced by hooks in `.claude/settings.json`:

- a `PostToolUse` hook records every `lib/**.dart` / `pubspec.yaml` file you edit;
- a `Stop` hook blocks the end of the turn once with the list of those files and a
  reminder to reconcile the docs.

`/update-docs` runs a full audit of `CLAUDE.md` + `docs/` against the current code.
`scripts/check-docs-freshness.sh` reports the same drift for staged git changes and
can be installed as a pre-commit hook via `scripts/install-git-hooks.sh`. Details in
[docs/documentation-maintenance.md](docs/documentation-maintenance.md).
