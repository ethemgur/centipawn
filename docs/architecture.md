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
                                              │            persists tree + accuracies
                                              ▼
                                     criticalMomentsProvider ──► ranked decision points
                                       (needs runSearch; web runs shallower)
```

Supporting state: `engineRunningProvider` (live analysis on/off, default **true**;
the critical-moment pass toggles it off for its duration, since it and live
analysis share one engine process),
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

One `EngineService` for every platform. The UCI protocol is shared
(`uci_engine.dart`); only the transport differs.

```
EngineService ──► UciEngine (protocol: guards, barriers, parsers, queue)
                      │
                      ▼
                 UciTransport            ← the only platform-specific part
                   ├─ NativeUciTransport  stockfish pub package (FFI), Android/iOS
                   └─ WebUciTransport     Web Worker + stockfish-18-lite-single.wasm
```

### The protocol (`uci_engine.dart`)

- Handshake on first use: `uci`, `setoption Threads/Hash` (values from the
  transport), `setoption MultiPV 3`, `ucinewgame`, `isready`. Guarded by one
  completer so concurrent callers share a single load, with a 20 s timeout —
  the backstop that catches failure modes nothing else predicts.
- `analyzePosition(fen)` — infinite search for live analysis. Bumps
  `_searchGeneration`; info lines whose generation doesn't match are dropped,
  or the tail flushed after `stop` leaks the previous position's eval into the
  new one. Emits an empty `PositionEvals` tagged with the new FEN first, so the
  previous position clears without this one being claimed.
- `evaluatePosition(fen, depth:)` — one-shot depth-limited search, used by the
  review. Completes on `bestmove`, and only when `_expectingBestmove` is set, so
  the `bestmove` from a `stop` can't resolve the wrong future. Returns **null**
  when nothing evaluated the position — never a 0.00 placeholder.
- `runSearch(fen, depth:, multiPv:)` — the analysis-grade search behind
  critical-moment detection. MultiPV plus `bestByDepth`, the best move at each
  completed iteration (`upperbound`/`lowerbound` lines skipped — they are
  unresolved and would read as the engine changing its mind). Serialised through
  a queue, bounded by a 90 s timeout that returns whatever depth was reached.

### Transports

**Native** (`uci_transport_native.dart`) wraps the `stockfish` pub package.
`isSupported` is **Android and iOS only** — the package ships plugin code for
those two and falls back to `DynamicLibrary.process()` elsewhere, where the
symbol lookup throws. Threads: 3 (2 on <6-core devices — more triggers thermal
throttling on phones). Hash: 256 MB.

**Web** (`uci_transport_web.dart`) runs `stockfish-18-lite-single` in a Web
Worker. Threads 1, Hash 32 MB (bounded wasm heap; mobile Safari kills tabs that
grow it). The single-threaded build is what keeps this simple: the
multi-threaded one needs `SharedArrayBuffer` → cross-origin isolation → which
would break CanvasKit loading from gstatic and sever popup OAuth via
`COOP: same-origin`. **No response headers are needed.**

Loading is lazy: the 7.3 MB module is fetched on first analysis, not at startup.
Three independent guards make a failure loud rather than a hang — the wasm magic
bytes are checked before the worker is spawned (the hosting SPA rewrite answers
a missing file with `index.html` at HTTP 200), `Worker.onerror` catches a bad
script, and the handshake timeout catches everything else. Failures are sticky
and carry a message written for a person.

It must be a **classic** worker: the glue calls `importScripts`, which does not
exist in `type: "module"` workers.

The artifacts are committed under `web/` and copied verbatim by
`flutter build web`, the same route `web/sqlite3.wasm` takes.
`test/engine/web_assets_test.dart` pins their sizes and magic bytes so a missing
file fails the build rather than production. Stockfish is GPL-3.0; see
`web/STOCKFISH-LICENSE.txt`.

## Platform-conditional files

Two conditional exports select an implementation at compile time:

```dart
// services/uci_transport.dart
export 'uci_transport_native.dart' if (dart.library.js_interop) 'uci_transport_web.dart';

// services/database_factory_setup.dart
export 'database_factory_setup_native.dart' if (dart.library.js_interop) 'database_factory_setup_web.dart';
```

When you touch either API, change both sides and keep shared types in the neutral
file (`engine_types.dart`).

`DatabaseService._initDatabase` also branches on `kIsWeb`: the web factory has no
filesystem, so it opens the bare name `centipawn.db` (stored in IndexedDB) instead of
joining `getDatabasesPath()`.
