# Data model & persistence

## `MoveNode` / `MoveTree` (`lib/models/move_node.dart`)

A game is a tree, not a list. `MoveTree` holds a `root` node whose FEN is the
starting position; the root carries no move.

```dart
class MoveNode extends Equatable {  // ignore: must_be_immutable
  final String fen;      // position AFTER this move
  final String san;
  final String? uci;

  double? evaluation;    // pawns, White POV
  int? mate;             // signed mate-in-N, White POV; 0 = side to move is mated
  MoveQuality? quality;

  String? bestMoveUci;   // engine's preferred move at the PARENT position
  double? bestMoveEval;  // pawns, White POV, at the parent position
  int? bestMoveMate;

  final List<String> comments;
  final List<int> glyphs;     // NAGs
  final List<MoveNode> children;
  MoveNode? parent;
}
```

Invariants and gotchas:

- **`children.first` is the mainline**; later children are variations.
  `addChild` sets `parent`; `promoteChild` moves a child to index 0;
  `promoteToMainline` walks to the root promoting at every level.
- `MoveTree.mainline` walks `children.first` from the root and **excludes the root**.
- `MoveTree.lastMainlineNode` walks the same path and returns the leaf (the root
  itself when the tree is empty).
- `moveNumber` and `isBlackMove` are derived by counting depth up to the root:
  depth 1 = White's first move, so `isBlackMove` is `depth % 2 == 0`.
- The class is marked `// ignore: must_be_immutable` on purpose: Equatable over
  mutable analysis fields. The review writes evaluations straight onto existing
  nodes; making it immutable means restructuring that write-back path.
- Because nodes are mutated in place, Riverpod won't notice tree changes on its own —
  call `MoveTreeNotifier.refresh()` (see [architecture.md](architecture.md)).

## `GameEntry` (`lib/models/game_entry.dart`)

Metadata only — the moves live in `move_nodes`. Fields: `id`, `white`, `black`,
`event`, `result`, `year`, `isReviewed`, `tags` (stored comma-joined), `timeControl`,
`date`, `site`, `round`, `whiteElo`, `blackElo`, `openingCode`, `whiteAccuracy`,
`blackAccuracy`, and `lastFen`.

`lastFen` is a denormalized cache of the final mainline position so `GameListScreen`
can render a thumbnail board without loading a whole tree. `insertGame` and
`saveTree` refresh it; anything that changes the mainline's end must too.

`timeControl` holds a **class** (`Bullet`/`Blitz`/`Rapid`/`Classical`), not the raw
PGN string — `PgnParser.classifyTimeControl` maps base seconds to a bucket
(<180, <600, <1800, else).

`openingCode` is the `"C60: Ruy Lopez"` string from `OpeningService.detect`, split
back into `ECO` + `Opening` tags on PGN export.

## SQLite schema (`lib/services/database_service.dart`)

Database `centipawn.db`, **version 5**, two tables.

```sql
CREATE TABLE games (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  white TEXT NOT NULL, black TEXT NOT NULL, event TEXT NOT NULL,
  result TEXT NOT NULL, year TEXT NOT NULL,
  isReviewed INTEGER NOT NULL DEFAULT 0,
  tags TEXT NOT NULL DEFAULT '',
  timeControl TEXT NOT NULL DEFAULT '', date TEXT NOT NULL DEFAULT '',
  site TEXT NOT NULL DEFAULT '', round TEXT NOT NULL DEFAULT '',
  whiteElo TEXT NOT NULL DEFAULT '', blackElo TEXT NOT NULL DEFAULT '',
  openingCode TEXT NOT NULL DEFAULT '',
  whiteAccuracy REAL, blackAccuracy REAL,
  lastFen TEXT NOT NULL DEFAULT '<start position>'
);

CREATE TABLE move_nodes (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  gameId INTEGER NOT NULL,
  parentId INTEGER,             -- NULL for the root
  orderIndex INTEGER NOT NULL,  -- 0 = mainline child
  fen TEXT NOT NULL, san TEXT NOT NULL DEFAULT '', uci TEXT,
  evaluation REAL, mate INTEGER, quality TEXT,
  bestMoveUci TEXT, bestMoveEval REAL, bestMoveMate INTEGER,
  commentsJson TEXT NOT NULL DEFAULT '[]',
  glyphsJson TEXT NOT NULL DEFAULT '[]',
  FOREIGN KEY (gameId) REFERENCES games(id) ON DELETE CASCADE,
  FOREIGN KEY (parentId) REFERENCES move_nodes(id) ON DELETE CASCADE
);

CREATE INDEX idx_nodes_game ON move_nodes (gameId, parentId, orderIndex);
```

There is **no** PGN text column and **no** `analysisJson` column; both were replaced
by the `move_nodes` table. `quality` is stored as `MoveQuality.name`.

### Migration strategy: reseed-only

`onUpgrade` drops both tables and recreates the schema, whatever the version delta.
`GameListNotifier.build()` then re-seeds the five famous games because the list comes
back empty. **User games are destroyed by a version bump.** That is the deliberate
current choice for a pre-1.0 app; if that stops being acceptable, `onUpgrade` is the
one place to change.

If you alter the schema: bump `version`, update `_createSchema`, and update
`_nodeToMap`/`_nodeFromRow` and `GameEntry.toMap`/`fromMap` in step.

### API surface

| Method | Behaviour |
| --- | --- |
| `insertGame(game, tree)` | one transaction: insert row (stamping `lastFen`), write the whole tree, return the row with `id` |
| `updateGameMetadata(game)` | `games` row only |
| `saveTree(gameId, tree)` | transaction: delete all node rows for the game, rewrite the tree, refresh `lastFen` |
| `getAllGames()` | ordered `id DESC` |
| `getGame(id)` / `deleteGame(id)` | single row / row + its nodes |
| `loadMoveTree(gameId)` | rebuilds the tree; returns an empty tree if there are no rows |

`loadMoveTree` builds all nodes first and wires parents in a second pass, sorting
siblings by `orderIndex`, so row order in the result set doesn't matter. `_writeTreeTx`
recurses depth-first and writes each child's index as `orderIndex`.

## Seed data

`_seedGames` in `study_provider.dart` — the Opera Game, the Immortal Game, Fischer–
Spassky G6, Scholar's Mate, Fool's Mate. Inserted by `GameListNotifier.build()` only
when `getAllGames()` comes back empty, so they reappear after a schema reset.

## PGN (`lib/services/pgn_parser.dart`)

### Parsing

`parsePgn(pgn, {initialFen})` strips `[Tag "…"]` headers, tokenizes, and walks moves
with dartchess. It handles:

- `(` / `)` variations — the current node and position are pushed, the walk resumes
  from the parent, and `)` pops.
- `{comment}` blocks (attached to the current node), `$N` NAGs, move numbers, and
  result tokens.
- Trailing annotation symbols on a move (`!!`, `??`, `!?`, `?!`, `!`, `?`) mapped to
  NAGs 3/4/5/6/1/2.
- An unparseable move is skipped with a `debugPrint` warning, not an exception.

`parseHeaders(pgn)` returns the tag map; `GameListNotifier.importFromPgn` uses it to
build the `GameEntry`.

### Exporting

| Function | Output |
| --- | --- |
| `exportMainline(tree)` | plain mainline move list, no headers |
| `exportMovetext(tree, {shapes})` | full movetext: variations, comments, NAGs |
| `exportPgn(tree, {game, clean, shapes})` | seven-tag roster + optional Elo/TimeControl/ECO tags, then movetext (`clean: true` = mainline only) |

Details worth knowing:

- A node's exported NAG is `glyphs.last` if present, otherwise the NAG mapped from
  `quality` (`best→3`, `excellent→1`, `inaccuracy→6`, `mistake→2`, `blunder→4`).
- `[eng]`-tagged comments (the `BestLineAnnotator` marker) are filtered out.
- User-drawn shapes are emitted as `[%csl …]` / `[%cal …]` annotations when a
  `shapes` map (FEN → shapes) is passed; `CustomShapesNotifier.shapesForGame(gameId)`
  produces one.
