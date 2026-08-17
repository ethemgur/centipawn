# Evaluation & game review

The most convention-heavy part of the codebase. Get a sign wrong here and the eval
bar, eval chart, and move labels all lie in ways that look plausible.

## Sign conventions

| Where | Convention |
| --- | --- |
| Stockfish `info … score cp/mate` | side-to-move POV |
| `EngineEvaluation.scoreCp` | **pawns**, side-to-move POV |
| `EngineEvaluation.mate` | mate-in-N, side-to-move POV |
| `PvLine.scoreCp` | **raw centipawns**, side-to-move POV |
| Lichess `/api/cloud-eval` response | White POV (converted to side-to-move inside `CloudEvalService`) — **currently unused**, see below |
| `ReviewNotifier._toCpWhitePerspective` output | **centipawns, White POV**, mate = `±10000` |
| `MoveNode.evaluation` | **pawns, White POV** |
| `MoveNode.mate` | signed mate-in-N, White POV |
| `MoveNode.bestMoveEval` | pawns, White POV, at the **parent** position |
| `MoveEvaluator.classifyMove` inputs | `ChessEvaluation` in centipawns, White POV |

`mate == 0` means "the side to move has just been mated". `EvalChart` and `EvalBar`
special-case it; `_terminalEval` produces it for checkmate positions.

`ReviewNotifier._isWhiteToMove(fen)` reads the side to move from the FEN itself, not
from the node's depth in the tree, so a game starting from a black-to-move position
doesn't get every evaluation sign-flipped.

## Where an evaluation comes from

`ReviewNotifier._fetchEval(engine, fen, depth:)`, in order:

1. **Terminal position** — `_terminalEval(fen)` asks dartchess. Checkmate →
   `EngineEvaluation(scoreCp: 0, mate: 0, depth: 99)`; stalemate or insufficient
   material → `scoreCp: 0, depth: 99`. The engine is not consulted.
   Without this, the final position of a decisive game gets no eval and the
   mating move looks like it threw away a won game.
2. **Cloud** — `CloudEvalService.evaluateBest(fen)`, **skipped while
   `kUseCloudEval` is false** (it is). See "Cloud eval is off" below.
3. **Local engine** — `await engine.ensureReady()` (which lazily loads the wasm
   module on web) then `runSearch(fen, depth: depth, multiPv: kAnalysisMultiPv)`
   at the depth from the settings slider (`analysisDepth(ref)`, capped at 12 on
   web where the engine is single-threaded wasm). The raw `SearchResult` is
   stored in `analysisCacheProvider`; `_toEvaluation` takes its top line and
   converts **raw centipawns → pawns**. Returns **null** rather than a 0.00
   placeholder when the search produced no lines.
4. **`null`** — nothing could evaluate it: no engine on this platform
   (Windows/macOS/Linux today), or one that failed to load.

### Cloud eval is off

`kUseCloudEval = false` in `study_provider.dart` disables the Lichess path in
both `_fetchEval` and `cloudEvalProvider` (which returns `PositionEvals.none`
immediately). `CloudEvalService` and the provider are left intact, so restoring
it is a one-line change.

Why: the cloud answers faster for cached positions but reports a single line and
no per-depth best move, so it cannot fill the shared search cache. Mixing the two
meant critical-moment detection had to re-search whatever the cloud had answered
— paying twice for the same position. One engine as the single source also makes
the numbers on the eval bar, in the review, and in critical moments agree.

### One search, two consumers

The review searches the root position plus the position after every mainline
move. Critical-moment Stage A needs the position *before* every mainline move —
which is the root plus `mainline[0..n-2].fen`, a subset. So the review caches
every `SearchResult` under `(fen, depth, multiPv)` in `analysisCacheProvider`,
and `CriticalMomentsNotifier.run` passes that same cache to `CriticalMoments.run`
with a matching `shallowDepth`/`shallowMultiPv`. Stage A then costs nothing and
only Stage B (deeper, flagged plies only) does real work.

The reuse hinges on the two agreeing on the FEN string exactly;
`test/critical_moments/cache_reuse_test.dart` pins that. A mismatch is not
*wrong* — the cache misses and Stage A searches the game again — just twice as
slow, silently.

`startReview` clears the cache first, so re-analysing an edited game re-searches
rather than replaying results for a tree that has since changed.

A `null` eval is load-bearing. The node keeps `evaluation`/`mate`/`quality` null, the
"previous eval" chain is broken (`prevCpWhite = null`), and the counter in
`ReviewProgress.unevaluatedMoves` increments so the UI can say how many positions
were skipped. **Never substitute 0.00** — it reads as a dead-equal position and
manufactures a huge drop on both the move into it and the move out of it.

## Win probability and classification

`MoveEvaluator` (`lib/services/move_evaluator.dart`):

```dart
cpToWinProb(cp) = 50 + 50 * (2 / (1 + exp(-0.00368208 * cp)) - 1)   // Lichess curve
```

`classifyByWpDrop(drop /* percentage points */)`:

| Drop | `MoveQuality` |
| --- | --- |
| ≥ 20 | `blunder` |
| ≥ 10 | `mistake` |
| ≥ 5 | `inaccuracy` |
| otherwise | `null` (no label) |

`classifyMove(best, actual, isWhiteTurn)` is the convenience wrapper: it converts
both `ChessEvaluation`s to win probability and computes the drop from the mover's
side (`best - actual` for White, `actual - best` for Black), clamps at 0, then calls
`classifyByWpDrop`.

`MoveQuality` also declares `best`, `excellent`, and `good`. The review never assigns
them — they exist for the NAG mapping in `PgnParser._qualityToNag` and for the
notation widget. Only negative labels come out of a review.

## The review pipeline

`ReviewNotifier.startReview()` in `lib/providers/study_provider.dart`:

1. Bail if the mainline is empty. Remember the active node so it can be restored.
2. Turn live analysis off (`engineRunningProvider.toggle()`) so the review's
   depth-limited searches don't fight the infinite search.
3. Evaluate the **root** position to seed `prevCpWhite`, `prevBestMoveUci`, and
   `prevBestMateWhite`.
4. For each mainline node, in order:
   - Snapshot the parent position's numbers into `node.bestMoveUci` /
     `bestMoveEval` / `bestMoveMate` — these describe *what the mover could have
     played instead*, which is what the critical-moment UI reads.
   - `_fetchEval(node.fen)`. On `null`: mark unevaluated, null out the node's
     analysis fields, break the chain, and continue.
   - Convert to White-POV centipawns; write `node.evaluation` (pawns) and
     `node.mate`.
   - If there is no previous eval (game start or just after a gap), record the eval
     and skip classification — there is no drop to measure.
   - Otherwise compute the raw win-probability drop from the mover's side and
     classify (with the redistribution rule below).
   - Push a `ReviewProgress` update every iteration; the UI shows a progress toast.
5. Compute per-side accuracy, persist, restore.

### Horizon-shift redistribution

The problem: a player plays the engine's top choice, and two moves later the eval
craters. That drop is the engine seeing past its earlier horizon, not a mistake by
the player — but a naive per-move diff blames the move that happened to be on the
board when the eval moved.

The rule implemented in the loop:

- `matchedEngineTop = node.uci != null && node.uci == parentBestUci`.
- If the move **matched** the engine's top move and still shows a drop, the drop is
  added to that side's `horizonDebt` and the *last same-side move that actually
  deviated* is re-classified on `lastDevRawDrop + horizonDebt`. The matching move
  itself gets `quality = null`.
- If the move **deviated**, it is classified on its own raw drop and becomes the new
  debt target (`lastDevIdx`), with the debt window reset to 0.
- A `null` eval clears both sides' `lastDevIdx`, so blame never jumps across a gap.

Redistribution only changes *which move gets the label*. Accuracy uses the raw drop
on every move, and the per-side total is invariant under redistribution.

### Accuracy

```dart
_calcAccuracy(totalWpDrop, moveCount) =
    (103.1668 * exp(-0.04354 * (totalWpDrop / moveCount)) - 3.1668).clamp(0, 100)
```

Returns `null` when `moveCount == 0`, so the UI hides the badge rather than showing
a fabricated 100%.

### Persistence at the end of a review

`selectedGame.copyWith(isReviewed: true, whiteAccuracy:, blackAccuracy:,
openingCode: OpeningService.detect(mainline) ?? existing, lastFen:)` →
`updateGameMetadata`, then `saveTree(gameId, tree)` so the per-node analysis is
stored. Then `selectedGameProvider.update`, `gameListProvider.refresh()`,
`engine.analyzePosition(lastFen)`, `moveTreeProvider.refresh()` (so labels appear
without a re-click), and `activeNodeProvider.setNode(nodeBeforeReview)`.

Reloading a reviewed game does **not** re-run anything: the node rows carry
`evaluation`/`mate`/`quality`/`bestMove*`, and `ReviewNotifier.markCompleted()`
rebuilds the progress state from the tree plus the stored accuracies.

## Related pieces

- **`BestLineAnnotator.buildAndAttach`** — turns a PV (UCI list, capped at 5 plies)
  into a variation attached to the parent node, validating each move against
  dartchess and stopping at the first illegal one. The head node is tagged with the
  `[eng]` comment so a re-review can delete the previous engine line, and so
  `PgnParser` can filter it out of exports.
- **`OpeningService.detect(mainline)`** — longest-prefix SAN match against a
  hardcoded ~120-entry ECO table; returns `"C60: Ruy Lopez"` style strings or `null`.
  `longestBookPrefix(sans)` runs the same match but returns the matched length; it
  is the book fallback `RepertoireMatcher` uses when no repertoire file is loaded
  (see [critical-moments.md](critical-moments.md)).
- **Arrow filtering** — `ChessBoard._filterByWinProb` and the copy in
  `game_screen.dart` keep only alternatives within 10 pp of the best line's win
  probability, then fade/thin them by drop and rank.
