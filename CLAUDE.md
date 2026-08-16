# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Centipawn is a Flutter chess study/analysis app. It loads PGN games, plays them out on an interactive board, runs Stockfish for live position evaluation, and provides a "game review" feature that classifies every mainline move (blunder/mistake/inaccuracy/etc.). State is managed with Riverpod; games and their analysis are persisted in a local SQLite database via `sqflite`.

Dart SDK: `^3.10.1`. Flutter project targets Android, iOS, web, Windows, macOS, Linux.

## Common commands

```
flutter pub get                       # install deps
flutter run                           # run on the default device
flutter run -d chrome                 # run on web (uses engine_service_web.dart)
flutter run -d windows                # run native desktop (uses engine_service_native.dart)
flutter analyze                       # lint / static analysis (flutter_lints)
flutter test                          # run all tests (test/ dir is currently empty)
flutter test test/path/to/foo_test.dart -n "name"   # run a single test by name
flutter build apk|ios|web|windows     # production builds
```

There is no separate formatter step beyond `dart format`.

## Architecture

### Engine abstraction (conditional import)

`lib/services/engine_service.dart` is a thin re-export that selects the platform implementation at compile time:

```dart
export 'engine_service_native.dart' if (dart.library.js_interop) 'engine_service_web.dart';
```

Both implementations expose the same `EngineService` API (declared via `engine_types.dart`): `evaluationStream`, `analyzePosition(fen)`, `evaluatePosition(fen, depth:)`, `isAvailable`, `stop()`, `dispose()`. When adding or changing engine behavior, update **both** `_native` and `_web` files and keep types defined in `engine_types.dart`. Stockfish is provided by the `stockfish` pub package on native; the **web implementation is a no-op stub** — `isAvailable` is `false` there and `evaluatePosition` returns a placeholder 0.00, so on web the only real evaluation source is `CloudEvalService` (Lichess cloud eval). Never treat a score from an engine with `isAvailable == false` as analysis.

### Move tree, not a move list

A game is a `MoveTree` of `MoveNode`s (`lib/models/move_node.dart`), not a flat list. Each node stores its own FEN, SAN, optional engine `evaluation`/`mate`/`quality`, comments, NAGs, and children. The first child of a node is the mainline; subsequent children are variations. Helpful invariants:

- `MoveTree.mainline` walks `children.first` from root, **excluding the root**.
- `MoveNode.isBlackMove` and `moveNumber` are derived by walking up to root — depth from root determines colour (depth 1 = White's first move).
- New user moves go through `ActiveNodeNotifier.makeMove`, which promotes an existing child if the SAN matches, or appends a new mainline child and rewrites the game's PGN via `PgnParser.exportMainline`.

### State (Riverpod) — single source of truth in `lib/providers/study_provider.dart`

All app state flows through this file. Key providers and how they interact:

- `gameListProvider` (AsyncNotifier) — list of `GameEntry` rows from SQLite. Seeds 5 famous games on first launch if DB is empty.
- `selectedGameProvider` — the currently open `GameEntry`.
- `moveTreeProvider` — `MoveTree` built by `PgnParser.parsePgn` when a game is loaded.
- `activeNodeProvider` — current position in the tree; navigation methods (`goForward`, `goBack`, `goFirst`, `goLast`, `setNode`, `makeMove`) live here. Setting the node triggers `engineProvider.analyzePosition(fen)` if the engine is running.
- `engineRunningProvider` — on/off toggle for live analysis.
- `engineEvaluationProvider` — `StreamProvider` wrapping `engine.evaluationStream`.
- `reviewProvider` — runs game review: serializes per-mainline-node `{evaluation, mate, quality}` to JSON and persists to the `analysisJson` column via `DatabaseService.saveAnalysis`. Saved analysis is reapplied on load via `MoveTreeNotifier.applyAnalysis`.

### Engine eval convention

Stockfish reports score from the side-to-move's POV. `ReviewNotifier._toCpWhitePerspective` normalizes everything to **centipawns from White's perspective**, including mate scores (`±10000`). Stored `MoveNode.evaluation` is in **pawns** (cp/100), and `mate` is signed from White's perspective. Preserve this convention — the eval chart and bar depend on it. `mate == 0` means "the side to move has just been mated" and pairs with an `evaluation` of `±100.0`.

Game-over positions never reach the engine or the cloud: `ReviewNotifier._terminalEval` answers them from dartchess (checkmate → `mate: 0`, stalemate/dead draw → 0.00). Positions nothing can evaluate yield a `null` eval, which leaves `MoveNode.evaluation`/`quality` null and breaks the drop chain — never substitute 0.00, which reads as a dead-equal position and fabricates huge swings on the surrounding moves.

### Move classification

`MoveEvaluator.classifyMove(prevEvalWhitePOV, curEvalWhitePOV, isWhiteMove)` in `lib/services/move_evaluator.dart` produces a `MoveQuality`. Both inputs must already be in White's POV centipawns.

### Persistence

`DatabaseService` (sqflite) opens `centipawn.db` with schema version 3. Schema columns include PGN metadata (event/site/round/elos/timeControl/date), `tags`, `isReviewed`, and `analysisJson`. Bump `version` and add a migration in `onUpgrade` if you change the schema.

### UI layout

`main.dart` → `GameListScreen` → `GameScreen`. `widgets/responsive_layout.dart` switches between phone/tablet/desktop arrangements of the board, eval bar, eval chart, and notation pane.

## Conventions worth knowing

- `MoveNode` is marked `// ignore: must_be_immutable` because Equatable is used despite mutable fields (`evaluation`, `mate`, `quality`, `children`). Don't "fix" this without restructuring how analysis is written back to the tree.
- When a move is added or the tree changes shape, call `ref.invalidate(moveTreeProvider)` so dependent widgets (notably the notation widget) rebuild — see `ActiveNodeNotifier.makeMove`.
- Piece SVGs are in `assets/` (`wK.svg`, `bN.svg`, …) and registered under `flutter.assets: - assets/` in `pubspec.yaml`.
