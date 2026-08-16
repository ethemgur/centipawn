# Architecture

How the pieces fit together at runtime. See [data-model.md](data-model.md) for the
shapes being moved around and [evaluation.md](evaluation.md) for the analysis math.

## Startup

`lib/main.dart`:

1. `WidgetsFlutterBinding.ensureInitialized()`
2. `setUpDatabaseFactory()` — no-op on native, installs
   `databaseFactoryFfiWebNoWebWorker` on web (sqlite3-wasm on the main thread; the
   SharedWorker variant is deliberately avoided).
3. `Firebase.initializeApp(...)` then `AuthService.instance.ensureSignedIn()` —
   signs in **anonymously** if there is no current user, so the app always has a UID.
4. `runApp(ProviderScope(child: CentipawnApp()))`; home is `GameListScreen`.

Auth is currently identity-only: nothing in `DatabaseService` is scoped by UID, and
there is no cloud sync. `authStateProvider` exists so the settings screen can show
the account and offer sign-in/out.

## Provider graph

All providers live in `lib/providers/study_provider.dart`.

```
gameListProvider ──(user taps a game)──► selectedGameProvider
                                              │
                                              ▼
                                       moveTreeProvider ◄── DatabaseService.loadMoveTree
                                              │
                                              ▼
                                       activeNodeProvider ──► engineProvider.analyzePosition(fen)
                                              │                        │
                                              │                        ▼
                                              │              engineEvaluationProvider (stream)
                                              │                        │
                                              ├──► cloudEvalProvider ──┤
                                              │        (one-shot)      ▼
                                              │                combinedEvalProvider ──► board arrows,
                                              │                (FEN-matched only)       eval bar,
                                              │                                         analysis box
                                              │
                                              ▼
                                        reviewProvider ──► writes evals onto MoveNodes,
                                                           persists tree + accuracies
```

Supporting state: `engineRunningProvider` (live analysis on/off, default **true**),
`boardFlippedProvider`, `boardEditModeProvider`, `drawColorProvider`,
`showThreatArrowProvider`, `customShapesProvider`, `reviewDepthProvider`,
`myNamesProvider`, `authStateProvider`.

`reviewDepthProvider` and `myNamesProvider` are the only ones backed by
`SharedPreferences`; both load asynchronously in `build()` and emit a default first
(depth `16`, empty name list).

## Opening a game

1. `GameListScreen` tile tap → `selectedGameProvider.select(game)` and navigation to
   `GameScreen`.
2. `moveTreeProvider.loadFromDb(game.id)` rebuilds the tree from `move_nodes` rows.
3. `activeNodeProvider.setNode(...)` positions the board; if the engine is running
   this triggers `analyzePosition`.
4. `ReviewNotifier.markCompleted()` restores review UI state (accuracy badges, eval
   chart) when the loaded tree already has `quality` values — no re-run needed,
   because analysis is stored per node.

## Saving

There are two write paths and they are not interchangeable:

| Path | Writes | Used by |
| --- | --- | --- |
| `DatabaseService.updateGameMetadata(game)` | `games` row only | metadata dialog, review completion |
| `MoveTreeNotifier.persist()` → `DatabaseService.saveTree(id, tree)` | deletes and rewrites all `move_nodes` rows for the game, refreshes cached `lastFen` | `makeMove`, review completion |

`saveTree` is a full rewrite inside one transaction — there is no incremental node
update. That is fine at this data size, but it means a save is O(tree).

`MoveTreeNotifier.persist()` also re-reads the game row and pushes it into
`selectedGameProvider` plus `gameListProvider.refresh()`, so cached columns like
`lastFen` (used for the list thumbnail) stay in sync.

## Riverpod mutation caveat

`MoveNode` is mutable and `MoveTree` holds a reference to the same root, so mutating
the tree in place does **not** notify listeners. Two helpers exist for this:

- `MoveTreeNotifier.refresh()` — `state = MoveTree.withRoot(state.root)`, a new
  wrapper around the same root, which is enough to rebuild the notation and chart.
- Callers that append nodes (`ActiveNodeNotifier.makeMove`, `ReviewNotifier`) must
  call it explicitly after mutating.

## Engine layer

### Native (`engine_service_native.dart`)

Wraps the `stockfish` pub package.

- On `StockfishState.ready`: `uci`, `Threads` = 3 (or 2 on <6-core devices — more
  triggers thermal throttling on phones), `Hash 256`, `MultiPV 3`, `ucinewgame`,
  `isready`. A FEN requested before ready is stashed in `_pendingFen` and replayed.
- `analyzePosition(fen)` — infinite search for live analysis. Every call bumps
  `_searchGeneration`; info lines whose generation doesn't match
  `_activeSearchGeneration` are dropped. Without this, the tail Stockfish flushes
  after `stop` leaks the previous position's eval into the new one. The call also
  emits an empty batch on the stream, sends `stop`, waits for `readyok` (2 s timeout),
  then `setoption MultiPV 1` + `position fen` + `go infinite`, recording the FEN in
  `_analyzingFen` so every emitted batch is tagged with the position it describes.
- `evaluatePosition(fen, depth:)` — one-shot depth-limited search used by the review.
  Completes on `bestmove`, and only when `_expectingBestmove` is set, so the
  `bestmove` emitted by a `stop` doesn't resolve the wrong future.
- Parsed `info` lines become `EngineEvaluation(scoreCp /* pawns */, mate, pv, depth)`
  keyed by `multipv` index and pushed to `evaluationStream` sorted by index, wrapped
  in a `PositionEvals(fen, evals)`.

Note `analyzePosition` sets `MultiPV 1` even though init sets 3; the multi-line
arrows on the board come from whatever the current setting yields plus the cloud
provider's `multiPv: 3`.

### Web (`engine_service_web.dart`)

A stub. No Stockfish ships with the web build: `isAvailable`/`isReady` are `false`,
`analyzePosition` and `stop` do nothing, `evaluatePosition` returns `scoreCp: 0`, and
`evaluationStream` **never emits**. Callers **must** check `isAvailable` before
trusting a score — `ReviewNotifier._fetchEval` does exactly that and returns `null`
instead — and must never gate the display of an eval on the local stream having
produced something, or the whole feature silently disappears on web. (That was a
real bug: the eval bar and the suggested-lines box were dead on web while the board
arrows, which read `combinedEvalProvider` directly, worked fine.)

### Cloud (`cloud_eval_service.dart`)

`GET https://lichess.org/api/cloud-eval?fen=…&multiPv=…`, 5 s timeout.

- Returns `null` on 404 (not cached), 429, any non-200, depth `< 20`, or any parse
  or network error. Callers fall back.
- Lichess reports White-POV scores; the service flips them to **side-to-move POV**
  so the result is a drop-in replacement for a local `EngineEvaluation`. `scoreCp`
  is converted to pawns.
- No explicit throttle: during review every cache miss falls through to a
  multi-second local search, which naturally keeps requests under ~1/s.

### Merging local + cloud

Both sources hand back a **`PositionEvals(fen, evals)`** — the evals plus the FEN
they were computed for. That tagging is what makes staleness checkable: a
`FutureProvider` keeps serving its previous value while it reloads, and a stream
keeps its last event until the next one arrives, so either source can otherwise hand
back the previous position's numbers after the user has already moved on.

`combinedEvalProvider` watches both, discards whichever does not match
`activeNodeProvider`'s FEN, and of the rest returns the one with the greater `depth`
— as a plain `List<EngineEvaluation>`, empty when nothing has evaluated the current
position. In practice the local engine fills the first few hundred milliseconds, the
cloud result (depth 30+) takes over when it lands, and the local engine wins again if
it out-searches it. **On web the cloud is the only source**, so nothing downstream may
require the local stream to have emitted.

Because a non-empty result is by construction for the current position, widgets can
render it directly — there is no separate freshness flag to consult. Anything that
needs "is this eval for the board I'm showing?" should compare FENs, via
`PositionEvals.matches(fen)`.

## Platform-conditional files

Two conditional exports select an implementation at compile time:

```dart
// services/engine_service.dart
export 'engine_service_native.dart' if (dart.library.js_interop) 'engine_service_web.dart';

// services/database_factory_setup.dart
export 'database_factory_setup_native.dart' if (dart.library.js_interop) 'database_factory_setup_web.dart';
```

When you touch either API, change both sides and keep shared types in the neutral
file (`engine_types.dart`).

`DatabaseService._initDatabase` also branches on `kIsWeb`: the web factory has no
filesystem, so it opens the bare name `centipawn.db` (stored in IndexedDB) instead of
joining `getDatabasesPath()`.
