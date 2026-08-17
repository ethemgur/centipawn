# UI map

`main.dart` → `GameListScreen` → `GameScreen`. `SettingsScreen` and `LoginScreen`
are pushed from the list screen / settings.

## Screens

### `GameListScreen` (`lib/screens/game_list_screen.dart`)

`ConsumerStatefulWidget`. Watches `gameListProvider`. Local (non-Riverpod) state
holds the filters: `_selectedTag`, `_selectedTimeControl`, `_selectedOpening`,
`_searchQuery`, plus `_showSearch` / `_isScrolled` for the app-bar behaviour.

Private pieces: `_ActiveFiltersBar` (removable chips), `_SheetChip` (filter sheet),
`_GameTile` (row: `_MiniChessBoard` thumbnail from `GameEntry.lastFen`, players,
result, accuracy/tag mini-badges), `_MiniChessBoard`.

Entry points for new games: the "+" FAB → `GameListNotifier.addBlankGame`, and PGN
import → `GameListNotifier.importFromPgn`.

### `GameScreen` (`lib/screens/game_screen.dart`)

The big one (~1300 lines). `ConsumerWidget` that listens to `reviewProvider` to show
the "Analysis complete" snackbar (including the count of positions nothing could
evaluate).

Structure:

- `_GameBody` — chooses `_buildStackedLayout` or `_buildLandscapeLayout`, delegating
  to `ResponsiveLayout` for the fold/tablet cases; supplies `_buildFoldControls` and
  `_buildBoardToolbar`.
- `_BoardWithEval` — `EvalBar` + `ChessBoard` + `_PlayerBar`s.
- `_EngineAnalysisBox` — `ConsumerStatefulWidget` rendering `combinedEvalProvider`
  lines (always for the current position — the provider FEN-matches for you).
  Renders **every** line the engine reports, up to `kAnalysisMultiPv` = 3. It used
  to drop alternatives more than 10 pp of win probability behind the best, which
  blanked rows 2 and 3 in exactly the positions where the alternative is most
  worth seeing. Arrow filtering still happens, in `ChessBoard`, where clutter is
  the real cost.
- `_CriticalMomentsBox` — *status only*: a progress bar while the pass runs, the
  reason it couldn't run (no engine on this platform, or one that failed to
  load), or a one-line summary of how many moves were marked. The moments
  themselves are badged on the moves in `StudyNotation`. The subtitle names the
  analysed side and, when the depths were reduced, the depths used
  (`as White · depth 12/16`) so a web report is never mistaken for a native one.
  See [critical-moments.md](critical-moments.md).
- `_NotationPanel` — wraps `StudyNotation` and `EvalChart`.
- `_GameBottomBar`, `_RepeatNavButton` (press-and-hold repeat for move stepping),
  `_ReviewProgressToast`, `_PlayerBar`, `_AccuracyBadge`, `_BoardEditToolbar`,
  `_ExportPgnDialog` (clean / annotated tabs → `PgnParser.exportPgn`), `_SectionDivider`.
- `_AppBarAction` enum: `analyse` (runs `reviewProvider.startReview`, then
  `criticalMomentsProvider.run`), `export`.
- Free function `timeControlIcon` maps the time-control class to an icon.

### `SettingsScreen` (`lib/screens/settings_screen.dart`)

`ConsumerWidget`, three sections: **Analysis** ("Engine depth" slider, 6–20, writes
`reviewDepthProvider` — it governs live analysis, the review, and critical moments
alike), **Player Profile** ("my names", picked from names appearing
in the user's games, writes `myNamesProvider`), **Account** (`authStateProvider` —
sign in / out, link to `LoginScreen`).

### `LoginScreen` (`lib/screens/login_screen.dart`)

Plain `StatefulWidget` with a tab controller: email/password sign-in and sign-up plus
Google sign-in, all via `AuthService`.

## Widgets

| Widget | Notes |
| --- | --- |
| `ChessBoard` | Wraps chessground. Handles promotion via chessground's selector (`_pendingPromotion`), engine-suggestion arrows, and a drawing overlay when `boardEditModeProvider` is on (tap = circle, drag = arrow, written to `customShapesProvider`). Alternatives are filtered to within 10 pp win probability of the best line and faded/thinned by drop and rank. |
| `StudyNotation` | Move-pair rows, variation blocks, sub-variations, comments and NAG glyphs; auto-scrolls the active node into view. Tapping a move calls `activeNodeProvider.setNode`. Comments render through `PgnParser.displayComments`, which hides `[%clk]`/`[%eval]`/`[%cal]` machine annotations; the edit dialog shows the raw text so editing cannot drop them. Mainline cells also carry a `_CriticalMomentBadge` — see below. |
| `EvalBar` | 24 px vertical bar. `evaluation` in pawns (White +), `mate`, `isFlipped`. Ratio is `0.5 + (eval/3)*0.45` clamped to 0.05–0.95; mate pins to an end. The score is printed on the leading side's section whenever it is non-zero once rounded to one decimal (so `0.1` shows; a level `0.0` and the pre-analysis default stay blank); mates show `M<n>`. |
| `EvalChart` | Custom-painted line chart over the mainline, zero-line in the middle, quality markers. Renders **only after a completed review** (`reviewProvider.isCompleted`). Mates plot as ±10.0; a null eval repeats the previous point. |
| `ResponsiveLayout` | Layout switch — see below. |

#### Critical-moment badges in the notation

`_collectMovePairs` carries a mainline half-move index (`whitePly`/`blackPly`)
alongside each move, because that index is the key
`criticalMomentsByPlyProvider` reports moments under. `_buildMoveCell` looks the
ply up and appends a `_CriticalMomentBadge` (outlined, purple, showing the
criticality percentile); tapping the badge opens a sheet explaining the number,
and swallows the tap so it doesn't also navigate.

The badge is deliberately shaped unlike the quality badge next to it: quality
judges the *move*, criticality describes the *position*, and a move can be both
critical and correct. Two similar-looking pills would read as two grades of the
same thing.

Node identity is not used as the key: `MoveNode` is `Equatable` over mutable
fields, so its hash changes the moment a review writes an evaluation into the
tree. `game_list_screen.dart` invalidates `criticalMomentsProvider` when a game
is opened, so the previous game's plies can't badge unrelated moves.
| `edit_game_metadata_dialog.dart` | `showEditGameMetadataDialog(context, ref, game)`, reachable from the game-screen title and from list tiles. |

## Responsive layout

`ResponsiveLayout(boardWidget, notationWidget, foldControlsWidget)` reads
`MediaQuery.displayFeatures`:

1. **Horizontal hinge** (flex/laptop posture) → 50/50 vertical split, with
   `foldControlsWidget` under the notation pane.
2. **Vertical hinge** (book posture) → 60/40 board/notation row.
3. No hinge, width > 600 → 60/40 row.
4. Otherwise → vertical stack (scrollable board, notation fills the rest).

## Theming

`lib/theme.dart` — `AppColors` (a light, Lichess-flavoured palette: navy primary,
`F0D9B5`/`B58863` board, move-notation and eval-bar colours) and `buildAppTheme()`
(Material 3, `Brightness.light`, seeded `ColorScheme`, flat app bar and cards,
Roboto). **There is no dark theme**; adding one means giving `AppColors` a
brightness-aware form, since widgets reference the constants directly.
