# Critical moment detection

Identifies up to a handful of moments in a game where the player faced a real
decision, and correlates those against time spent.

**Not a blunder detector.** A blunder is a move that lost eval. A critical
moment is a position where the choice *mattered* and *was hard*. They overlap
but are not the same thing, and the module must not be allowed to collapse into
the former — most of the design below exists to keep them apart.

Lives in `lib/services/critical_moments/`.

## Pipeline

```
PGN mainline
 └─> PlyBuilder                 PlyData per ply, clocks parsed from [%clk]
      └─> Stage A  (analyzer)   every non-book ply, depth 15, MultiPV 3
           └─> Stage B          flagged plies only, depth 28, MultiPV 5
                └─> Stage C     scoring + gates + ranking + time regression
                     └─> CriticalMomentReport
```

Analysis runs from **one player's perspective**. Opponent plies are searched for
eval continuity — the loss and novelty terms read them — but are never scored or
reported.

**Stage C is pure.** No engine calls, no I/O. It takes Stage A+B data and
returns scored output, so it re-runs in milliseconds against frozen fixtures
while weights are tuned. Keep it that way: `analysed_game.dart`,
`critical_types.dart`, `scorer.dart`, `gates.dart`, `difficulty.dart`,
`divergence.dart`, `see.dart`, `move_character.dart`, `game_context.dart` and
`time_regression.dart` import neither Flutter nor the engine, which is what lets
`tool/validate_critical_moments.dart` run under a plain `dart run`.

## Where it runs from

`criticalMomentsProvider` (in `study_provider.dart`) drives it. The game
screen's **Analyse game** action runs the review first (cloud-backed, quick),
then this pass. `_CriticalMomentsBox` under the board lists the top moments;
tapping one jumps to that ply.

The analysed side comes from `myNamesProvider` — whichever player the user
identifies with, falling back to White. Live analysis is toggled off for the
duration, because it and this share one engine process.

## Engine requirement

Needs `EngineService.runSearch(fen, depth:, multiPv:)` — MultiPV output *plus*
the best move at every completed iterative-deepening depth. The Lichess
cloud-eval endpoint exposes neither, so this needs a **real engine**:

| Platform | Status |
| --- | --- |
| Android, iOS | Stockfish via FFI, full depths |
| Web | Stockfish WASM in a Worker, **reduced depth and width** (Stage A depth 12/MultiPV 3, Stage B depth 16/MultiPV 3) |
| Windows, macOS, Linux | no engine yet — `isSupported` is false |

`analyze()` throws `StateError` when no engine can run or when one fails to
load, carrying the real reason; that surfaces as
`CriticalMomentsState.unavailableReason` and the box says so in as many words.
An empty list would read as "this game had no critical moments", which is a
different and false claim.

Web depths and MultiPV widths come from `kShallowDepthWeb`/`kDeepDepthWeb` and
`kShallowMultiPvWeb`/`kDeepMultiPvWeb`, threaded through `CriticalMoments.run`
from `criticalMomentsProvider` — deliberately *not* from `critical_types.dart`,
which imports neither Flutter nor the engine so that
`tool/validate_critical_moments.dart` still runs under a plain `dart run`.
`CriticalMomentsState` carries the depths and `_CriticalMomentsBox` prints them
(`as White · depth 12/16`), so a web report is never mistaken for a native one.
Results at web depths are genuinely noisier: depth-to-settle is measured over a
shorter range and Stage A flags a slightly different set of plies.

**MultiPV width, not depth, was the first bottleneck found.** A real run
against a 23-move tactical game measured Stage B (then depth 20, MultiPV 5) at
9-22 **seconds** a ply — ~230s for one game. Narrowing MultiPV 5 → 3 (scoring
never reads past `pvs[2]`, so this is free) got that to ~180s; the deep depth
also coming down from 20 to 16 got the same game to ~62s, with the top-ranked
moment unchanged throughout — see the constants' doc comments in
`critical_types.dart` for the numbers. If web analysis ever feels slow again,
measure before changing a constant — depth and MultiPV width do not cost the
same, and Stage A was never the problem.

A single search is bounded by a 90 s timeout that returns whatever depth was
reached. Without it a wedged engine stalls the whole sweep with no symptom
beyond a progress bar that stops moving.

`bestByDepth` is easy to lose: capture every `info depth N ... multipv 1 ... pv`
line, not just the final depth. Recovering it means searching again.
`upperbound`/`lowerbound` lines are skipped — they are unresolved fail-soft
scores and would look like the engine changing its mind mid-iteration.

Searches are serialised through a queue; one Stockfish process answers one
search at a time, and a game sweep issues hundreds back to back.

## Components

All return 0..1.

| Component | What it measures | Notes |
| --- | --- | --- |
| **Spread** | Consequence: cp gap between the best two lines | Capped at `kSpreadCapCp = 300`. The cap is load-bearing — uncapped, one hung queen dominates the whole game's ranking. |
| **Depth-to-settle** | Difficulty: shallowest depth after which the engine never changes its mind, mapped over depths 4–20 | Best at depth 3 = a human sees it instantly; only surfaces at 22 = never going to be found over the board. Absorbs what would otherwise be a separate "depth instability" term — do **not** add that back, it double-counts. Returns 0 on searches with fewer than 6 iterations. |
| **Move character** | Difficulty: move types humans underweight | quiet +0.30, retreat +0.25, sacrifice (SEE < 0) +0.25, into-pawn-attack +0.20, then capped at 0.3 for forcing moves (check / only capture / recapture) since those are the first thing anyone looks at. |
| **Continuation novelty** | Difficulty: was this idea already on the board two plies ago? | If the engine's current pick was already its projected continuation, the player is executing a plan, not deciding. Cheapest genuinely novel signal here, and it survives the Maia integration. |
| **Path divergence** | How structurally different the two best lines are | Walks both PVs 12 plies using moves already in hand (**no re-search**) and compares pawn skeleton (0.35), queens on/off (0.30), material (0.20), king commitment (0.15). |

Divergence is what catches the target case: two moves a few centipawns apart,
one keeping queens on and one entering a rook endgame. Spread calls that
irrelevant; divergence calls it the game. With Maia deferred it carries
proportionally more weight than the original design intended — that is
deliberate, and it is also why `kDivergenceWeight` is the first thing to tune.

Difficulty blends as `0.45*dts + 0.30*char + 0.25*novelty`, behind
`DifficultyProvider`. A `MaiaDifficultyProvider` replaces
`HeuristicDifficultyProvider` later without touching the composite — do not
inline the blend into the scorer.

### Static exchange evaluation

dartchess exposes no SEE, so `see.dart` implements the standard swap-off:
repeatedly take the least-valuable attacker, alternating sides, recomputing
sliding attacks against the reduced occupancy so x-rays join the exchange, then
negamax back. A king may not capture into a still-defended square — without that
guard the sequence "wins" the king for 20000 and the result is nonsense.

Returning 0 would disable only the sacrifice term. Do **not** approximate it
with "captures a lower-valued piece", which misfires badly on defended pieces —
exactly the case the term cares about.

## Gates

### Zero-outs (§6)

Run **before** any component is computed and before damps, short-circuiting on
the first hit. A zeroed ply is dropped from the percentile distribution
entirely, not entered as a zero — including them compresses everything else into
the top decile and makes percentiles meaningless in forced-sequence-heavy games.

| Gate | Fires when |
| --- | --- |
| `book` | `RepertoireMatcher` says the ply is still in the user's repertoire |
| `forced:single_legal` | one legal move |
| `forced:check_evasion` | in check, ≤3 replies, **raw** cp gap > 300 |
| `forced:recapture_single` | exactly one recapturer *and* it is the engine's choice |
| `forced:mate_execution` | best two lines are both mates of the same sign |
| `forced:mate_run` | mate distance shrinking monotonically after the entry ply |

`mateRunPlies` walks the **analysed side's plies only**. Scores are from the
side to move, so on the opponent's plies a winning mate reads as negative;
walking every ply resets the run on each of them, and then every one of our own
plies looks like a fresh entry into the net and nothing is ever suppressed. That
was a real bug — with the seeded games, all of which end in forced mates, the
mating sequence filled the report.

Two of these are classifiers rather than filters, on purpose:

- **Recapture.** One recapturer but the engine prefers something else means a
  zwischenzug exists or the recapture loses — a real decision, kept. Multiple
  recapturers is a genuine choice of structure, also kept. (That branch carried
  a 1.4× boost in the original design; boosts are out of scope for v1 and there
  is a `TODO(boost)` marker on it.)
- **Mate.** Only *execution* is suppressed. The entry into the mating net is
  caught normally, because at that ply the alternatives are not mate scores.

The check-evasion gate deliberately uses the raw cp gap, not the clamped spread:
the clamp erases exactly the distinction it is testing for.

### Damps (§7)

Multipliers applied after components, so the moments stay in the ranking and
merely stop crowding everything else out. Multiplied together, floored at
`kDampFloor`.

| Gate | × | Fires when |
| --- | --- | --- |
| `damp:decided` | 0.2 | \|eval\| > 600 — unless the third-best move drops under 100, which makes it a conversion-technique test |
| `damp:shuffling` | 0.5 | position repeated, or ≥6 plies with no capture or pawn move |
| `damp:scramble` | 0.4 | **both** clocks under `kScrambleSec` |
| `damp:post_blunder` | 0.5 | either of the previous two plies gave away >200cp |
| `damp:endgame_run` | 0.3 | second pass: in a simplified endgame (no queens, ≤6 non-king pieces a side), a run of 4+ consecutive high-scoring own plies keeps only its peak |

Every damp is toggleable via `DampConfig`. During validation you want the
undamped ranking, to check the damps are not suppressing genuine content.

The endgame-run rule is sequential and runs after per-ply scoring. Without it a
single rook endgame produces eight consecutive flagged moments and buries the
middlegame decision that actually lost the game. "High-scoring" is defined as at
or above the 75th percentile of raw score within the game
(`ScoringConfig.endgameRunPercentile`) — the spec left the threshold open.

## Composite and ranking

```
raw = spread
    * (kDifficultyFloor + (1 - kDifficultyFloor) * difficulty)
    * (1 + kDivergenceWeight * divergence)
    * damp
```

clamped to `kRawCap`.

The **difficulty floor** is deliberate. Fully multiplicative difficulty means a
position most players find scores near zero — but the user might still have
missed it. Do not remove it to clean up the ranking. `kRawCap` stops one ply
that trips several multipliers at once from burying the rest of the game.

Ranking is by **percent rank within the game**, over scored plies of the
analysed side only. Absolute thresholds do not work: a quiet Carlsbad and a
Sicilian slugfest have completely different raw-score distributions, and one
cutoff flags thirty moments in the first and none in the second.

Reported set is `min(maxMoments, ceil(reportFraction * scoredPlyCount))`,
defaulting to `min(5, ceil(0.15 n))` — five is what a player can actually work
through after a game. `report.allScored` carries the full ranking;
`report.moments` is the top slice.

## Time correlation

```
log(timeSpent + 1) ~ b0 + b1*criticalityPercentile + b2*moveNumber
```

`moveNumber` is not optional — time compresses through a game, and omitting it
makes every late-game move look like a blind spot. Fitted by normal equations
with Gaussian elimination (no dependency); returns null on a singular system,
which is what collinear predictors produce.

Excluded from the fit but kept in the criticality output: time under 1s
(premoves), ply < 8 (book the matcher missed), either clock in a scramble, and
any zeroed ply. Under 12 surviving plies the regression is skipped entirely and
every `timeResidual` stays null — a two-predictor OLS on eight points is noise.

Verdicts: residual < −1 is **blindSpot** (moved fast at a genuine branch point —
the headline finding); > +1 is **wasted**, unless the next three *own* moves
average below the game's lower time quartile, in which case the think was banked
and cashed in (**productiveThink**).

`CriticalMomentReport.meanResidualTopQuartile` is the cross-game aggregate: one
number for whether the player allocates time where it matters, which can visibly
move with training.

## Validation

`ScoreBreakdown` and `gatesFired` are populated on every moment, and every
zeroed ply is retained in `report.zeroed` with its reason. This is not optional
— validation depends on answering "why did this rank first", and reconstructing
it after the fact is guesswork.

`tool/validate_critical_moments.dart` reports precision, recall, and a per-gate
false-positive breakdown against hand labels, with `--sweep` for weight sweeps
and `--no-damps` for the raw ranking. See `test/critical_moments/data/README.md`
for the capture-and-label loop.

**The weights are reasoned, not fitted.** `kDivergenceWeight = 0.6` is a guess,
and the difficulty sub-weights (0.45/0.30/0.25) are unvalidated. Run 30 of your
own games, label the top 5 per game, target ≥70% precision, and tune from there.
Your own games are the only ground truth for a tool built for yourself.

## Deferred

- **Maia.** `DifficultyProvider` is the seam. Adds the "natural but wrong" error
  class and opponent modelling. Until then everything runs Stockfish-only and
  fully on-device, which is a real advantage on the Fold.
- **Boost gates.** Only-move saves, structure-committing pawn moves, castling
  windows, queen-trade offers, pawn-endgame transitions, and the
  multiple-recapturer boost. Excluded from v1 so their effect is measurable
  against a validated baseline.
