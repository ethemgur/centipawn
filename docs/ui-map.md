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
- `_NotationPanel` — wraps `StudyNotation` and `EvalChart`.
- `_GameBottomBar`, `_RepeatNavButton` (press-and-hold repeat for move stepping),
  `_ReviewProgressToast`, `_PlayerBar`, `_AccuracyBadge`, `_BoardEditToolbar`,
  `_ExportPgnDialog` (clean / annotated tabs → `PgnParser.exportPgn`), `_SectionDivider`.
- `_AppBarAction` enum: `analyse` (starts `reviewProvider.startReview`), `export`.
- Free functions `_evalCpGs` / `_filterByWinProbGs` mirror the arrow-filtering logic
  in `ChessBoard`; `timeControlIcon` maps the time-control class to an icon.

### `SettingsScreen` (`lib/screens/settings_screen.dart`)

`ConsumerWidget`, three sections: **Analysis** (review-depth slider, 6–20, writes
`reviewDepthProvider`), **Player Profile** ("my names", picked from names appearing
in the user's games, writes `myNamesProvider`), **Account** (`authStateProvider` —
sign in / out, link to `LoginScreen`).

### `LoginScreen` (`lib/screens/login_screen.dart`)

Plain `StatefulWidget` with a tab controller: email/password sign-in and sign-up plus
Google sign-in, all via `AuthService`.

## Widgets

| Widget | Notes |
| --- | --- |
| `ChessBoard` | Wraps chessground. Handles promotion via chessground's selector (`_pendingPromotion`), engine-suggestion arrows, and a drawing overlay when `boardEditModeProvider` is on (tap = circle, drag = arrow, written to `customShapesProvider`). Alternatives are filtered to within 10 pp win probability of the best line and faded/thinned by drop and rank. |
| `StudyNotation` | Move-pair rows, variation blocks, sub-variations, comments and NAG glyphs; auto-scrolls the active node into view. Tapping a move calls `activeNodeProvider.setNode`. |
| `EvalBar` | 24 px vertical bar. `evaluation` in pawns (White +), `mate`, `isFlipped`. Ratio is `0.5 + (eval/3)*0.45` clamped to 0.05–0.95; mate pins to an end. The score is printed on the leading side's section whenever it is non-zero once rounded to one decimal (so `0.1` shows; a level `0.0` and the pre-analysis default stay blank); mates show `M<n>`. |
| `EvalChart` | Custom-painted line chart over the mainline, zero-line in the middle, quality markers. Renders **only after a completed review** (`reviewProvider.isCompleted`). Mates plot as ±10.0; a null eval repeats the previous point. |
| `ResponsiveLayout` | Layout switch — see below. |
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
