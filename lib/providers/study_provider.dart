import 'dart:math' show exp;
import 'package:flutter/material.dart' show Color, Colors;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dartchess/dartchess.dart';
import 'package:chessground/chessground.dart' show Shape, Circle, Arrow;
import '../models/move_node.dart';
import '../models/game_entry.dart';
import '../services/pgn_parser.dart';
import '../services/engine_service.dart';
import '../services/cloud_eval_service.dart';
import '../services/move_evaluator.dart';
import '../services/database_service.dart';
import '../services/opening_service.dart';
import '../services/auth_service.dart';
import '../services/critical_moments/critical_moments.dart';

// ---------------------------------------------------------------------------
// Auth state (streams the current Firebase user so widgets can react)
// ---------------------------------------------------------------------------

final authStateProvider = StreamProvider<User?>((ref) {
  return AuthService.instance.authStateChanges();
});

// ---------------------------------------------------------------------------
// Seed data (inserted into DB on first launch). Each seed pairs metadata
// with the PGN string parsed into a MoveTree at seed time.
// ---------------------------------------------------------------------------

class _SeedGame {
  final GameEntry metadata;
  final String pgn;
  const _SeedGame(this.metadata, this.pgn);
}

const _seedGames = <_SeedGame>[
  _SeedGame(
    GameEntry(
      white: 'P. Morphy',
      black: 'Duke of Brunswick',
      event: 'The Opera Game',
      result: '1-0',
      year: '1858',
    ),
    '1. e4 e5 2. Nf3 d6 3. d4 Bg4 4. dxe5 Bxf3 5. Qxf3 dxe5 '
    '6. Bc4 Nf6 7. Qb3 Qe7 8. Nc3 c6 9. Bg5 b5 10. Nxb5 cxb5 '
    '11. Bxb5+ Nbd7 12. O-O-O Rd8 13. Rxd7 Rxd7 14. Rd1 Qe6 '
    '15. Bxd7+ Nxd7 16. Qb8+ Nxb8 17. Rd8# 1-0',
  ),
  _SeedGame(
    GameEntry(
      white: 'A. Anderssen',
      black: 'L. Kieseritzky',
      event: 'The Immortal Game',
      result: '1-0',
      year: '1851',
    ),
    '1. e4 e5 2. f4 exf4 3. Bc4 Qh4+ 4. Kf1 b5 5. Bxb5 Nf6 '
    '6. Nf3 Qh6 7. d3 Nh5 8. Nh4 Qg5 9. Nf5 c6 10. g4 Nf6 '
    '11. Rg1 cxb5 12. h4 Qg6 13. h5 Qg5 14. Qf3 Ng8 '
    '15. Bxf4 Qf6 16. Nc3 Bc5 17. Nd5 Qxb2 18. Bd6 Bxg1 '
    '19. e5 Qxa1+ 20. Ke2 Na6 21. Nxg7+ Kd8 22. Qf6+ Nxf6 '
    '23. Be7# 1-0',
  ),
  _SeedGame(
    GameEntry(
      white: 'B. Spassky',
      black: 'R. Fischer',
      event: 'World Championship G6',
      result: '0-1',
      year: '1972',
    ),
    '1. c4 e6 2. Nf3 d5 3. d4 Nf6 4. Nc3 Be7 5. Bg5 O-O '
    '6. e3 h6 7. Bh4 b6 8. cxd5 Nxd5 9. Bxe7 Qxe7 '
    '10. Nxd5 exd5 11. Rc1 Be6 12. Qa4 c5 13. Qa3 Rc8 '
    '14. Bb5 a6 15. dxc5 bxc5 16. O-O Ra7 17. Be2 Nd7 '
    '18. Nd4 Qf8 19. Nxe6 fxe6 20. e4 d4 21. f4 Qe7 0-1',
  ),
  _SeedGame(
    GameEntry(
      white: 'Scholar',
      black: 'Student',
      event: "Scholar's Mate",
      result: '1-0',
      year: '',
    ),
    '1. e4 e5 2. Bc4 Nc6 3. Qh5 Nf6 4. Qxf7# 1-0',
  ),
  _SeedGame(
    GameEntry(
      white: 'White',
      black: 'Black',
      event: "Fool's Mate",
      result: '0-1',
      year: '',
    ),
    '1. f3 e5 2. g4 Qh4# 0-1',
  ),
];

const String _startFen =
    'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';

// ---------------------------------------------------------------------------
// Currently selected game
// ---------------------------------------------------------------------------

class SelectedGameNotifier extends Notifier<GameEntry?> {
  @override
  GameEntry? build() => null;

  void select(GameEntry game) => state = game;
  void update(GameEntry game) => state = game;
}

final selectedGameProvider = NotifierProvider<SelectedGameNotifier, GameEntry?>(
  () => SelectedGameNotifier(),
);

// ---------------------------------------------------------------------------
// Game list (backed by SQLite — metadata only)
// ---------------------------------------------------------------------------

class GameListNotifier extends AsyncNotifier<List<GameEntry>> {
  @override
  Future<List<GameEntry>> build() async {
    var games = await DatabaseService.getAllGames();
    if (games.isEmpty) {
      for (final seed in _seedGames) {
        final tree = PgnParser.parsePgn(seed.pgn);
        final lastFen = tree.lastMainlineNode.fen;
        await DatabaseService.insertGame(
          seed.metadata.copyWith(lastFen: lastFen),
          tree,
        );
      }
      games = await DatabaseService.getAllGames();
    }
    return games;
  }

  /// Create a brand-new empty game (used by the "+" FAB).
  Future<GameEntry> addBlankGame(GameEntry metadata) async {
    final tree = MoveTree(initialFen: _startFen);
    final saved = await DatabaseService.insertGame(metadata, tree);
    state = AsyncData(await DatabaseService.getAllGames());
    return saved;
  }

  /// Import a game from PGN text — parses metadata from headers, builds the
  /// move tree, and persists both. Returns the saved row.
  Future<GameEntry> importFromPgn(String pgn) async {
    final tree = PgnParser.parsePgn(pgn);
    final h = PgnParser.parseHeaders(pgn);
    final tc = PgnParser.classifyTimeControl(h['TimeControl']) ?? '';
    final metadata = GameEntry(
      white: h['White'] ?? '',
      black: h['Black'] ?? '',
      event: h['Event'] ?? 'Imported Game',
      result: h['Result'] ?? '*',
      year: h['Date']?.split('.').first ?? '',
      date: h['Date'] ?? '',
      site: h['Site'] ?? '',
      round: h['Round'] ?? '',
      whiteElo: h['WhiteElo'] ?? '',
      blackElo: h['BlackElo'] ?? '',
      timeControl: tc,
    );
    final saved = await DatabaseService.insertGame(metadata, tree);
    state = AsyncData(await DatabaseService.getAllGames());
    return saved;
  }

  Future<void> updateMetadata(GameEntry game) async {
    await DatabaseService.updateGameMetadata(game);
    state = AsyncData(await DatabaseService.getAllGames());
  }

  Future<void> deleteGame(int id) async {
    await DatabaseService.deleteGame(id);
    state = AsyncData(await DatabaseService.getAllGames());
  }

  Future<void> refresh() async {
    state = AsyncData(await DatabaseService.getAllGames());
  }
}

final gameListProvider = AsyncNotifierProvider<GameListNotifier, List<GameEntry>>(
  () => GameListNotifier(),
);

// ---------------------------------------------------------------------------
// Move Tree (loaded from DB for the selected game)
// ---------------------------------------------------------------------------

class MoveTreeNotifier extends Notifier<MoveTree> {
  @override
  MoveTree build() => MoveTree(initialFen: _startFen);

  /// Replace the in-memory tree with [tree] — does not persist.
  void setTree(MoveTree tree) {
    state = tree;
  }

  /// Async: load the tree for [gameId] from the DB.
  Future<void> loadFromDb(int gameId) async {
    state = await DatabaseService.loadMoveTree(gameId);
  }

  /// Replace the tree with the result of parsing [pgn]. Does not persist.
  /// Use [GameListNotifier.importFromPgn] when you want to save a new game.
  void loadPgn(String pgn) {
    state = PgnParser.parsePgn(pgn);
  }

  /// Trigger a rebuild in notation/chart widgets without resetting the tree.
  void refresh() {
    state = MoveTree.withRoot(state.root);
  }

  /// Persist the current tree to the DB for the selected game. Refreshes
  /// the selected-game row + the list cache so cached fields like `lastFen`
  /// stay in sync. No-op when no game is selected.
  Future<bool> persist() async {
    final game = ref.read(selectedGameProvider);
    if (game?.id == null) return false;
    await DatabaseService.saveTree(game!.id!, state);
    final refreshed = await DatabaseService.getGame(game.id!);
    if (refreshed != null) {
      ref.read(selectedGameProvider.notifier).update(refreshed);
    }
    await ref.read(gameListProvider.notifier).refresh();
    return true;
  }
}

final moveTreeProvider = NotifierProvider<MoveTreeNotifier, MoveTree>(() {
  return MoveTreeNotifier();
});

// ---------------------------------------------------------------------------
// Engine Service
// ---------------------------------------------------------------------------

final engineProvider = Provider<EngineService>((ref) {
  final service = EngineService();
  ref.onDispose(() => service.dispose());
  return service;
});

final engineEvaluationProvider = StreamProvider<PositionEvals>((ref) {
  return ref.watch(engineProvider).evaluationStream;
});

/// Fires a one-shot Lichess cloud-eval request whenever the active node or
/// engine-running state changes. Returns [PositionEvals.none] on cache miss or
/// network failure so callers can fall back gracefully.
final cloudEvalProvider =
    FutureProvider.autoDispose<PositionEvals>((ref) async {
  final node = ref.watch(activeNodeProvider);
  final isRunning = ref.watch(engineRunningProvider);
  if (!isRunning || node == null) return PositionEvals.none;

  final result = await CloudEvalService.evaluate(node.fen, multiPv: 3);
  return result == null ? PositionEvals.none : PositionEvals(node.fen, result);
});

/// Merges [engineEvaluationProvider] (local Stockfish, streaming) with
/// [cloudEvalProvider] (Lichess cache, one-shot) and returns the evals for the
/// **current** position — never a leftover from the position the user just
/// left, so callers can render the result directly.
///
/// Both sources are matched against the active node's FEN before being
/// considered: an in-flight `FutureProvider` keeps serving its previous value
/// while it reloads, and the engine stream keeps its last event until the next
/// one arrives, so without the FEN check either can hand back the previous
/// position's numbers.
///
/// Of the sources that do describe the current position, whichever has the
/// higher depth on its principal variation wins. In practice: the local engine
/// provides quick early-depth updates while the cloud request is in flight; the
/// cloud result overrides once it arrives (typically depth 30+); the local
/// engine takes over again once it surpasses the cloud depth. On web there is
/// no local engine at all, so the cloud is the only source — which is why this
/// must not require the engine stream to have emitted.
final combinedEvalProvider =
    Provider.autoDispose<List<EngineEvaluation>>((ref) {
  final fen = ref.watch(activeNodeProvider)?.fen;
  if (fen == null) return const [];

  final local = ref.watch(engineEvaluationProvider).value ?? PositionEvals.none;
  final cloud = ref.watch(cloudEvalProvider).value ?? PositionEvals.none;

  final localList =
      local.matches(fen) ? local.evals : const <EngineEvaluation>[];
  final cloudList =
      cloud.matches(fen) ? cloud.evals : const <EngineEvaluation>[];

  if (cloudList.isEmpty) return localList;
  if (localList.isEmpty) return cloudList;

  return cloudList.first.depth > localList.first.depth ? cloudList : localList;
});

class EngineRunningNotifier extends Notifier<bool> {
  @override
  bool build() => true;

  void toggle() {
    state = !state;
    if (state) {
      final current = ref.read(activeNodeProvider);
      if (current != null) {
        ref.read(engineProvider).analyzePosition(current.fen);
      }
    } else {
      ref.read(engineProvider).stop();
    }
  }
}

final engineRunningProvider = NotifierProvider<EngineRunningNotifier, bool>(
  () => EngineRunningNotifier(),
);

// ---------------------------------------------------------------------------
// Active Node (current board position in the tree)
// ---------------------------------------------------------------------------

class ActiveNodeNotifier extends Notifier<MoveNode?> {
  @override
  MoveNode? build() {
    final root = ref.read(moveTreeProvider).root;
    Future.microtask(() {
      if (ref.read(engineRunningProvider)) {
        ref.read(engineProvider).analyzePosition(root.fen);
      }
    });
    return root;
  }

  void setNode(MoveNode? node) {
    state = node;
    if (node != null && ref.read(engineRunningProvider)) {
      ref.read(engineProvider).analyzePosition(node.fen);
    }
  }

  void goForward() {
    final current = state;
    if (current != null && current.children.isNotEmpty) {
      setNode(current.children.first);
    }
  }

  void goBack() {
    final current = state;
    if (current?.parent != null) {
      setNode(current!.parent);
    }
  }

  void goFirst() {
    setNode(ref.read(moveTreeProvider).root);
  }

  void goLast() {
    setNode(ref.read(moveTreeProvider).lastMainlineNode);
  }

  /// Make a move from the UI board. Handles both regular moves and
  /// promotions, persists the updated tree to the DB.
  void makeMove(NormalMove move) {
    final current = state;
    if (current == null) return;

    final pos = Chess.fromSetup(Setup.parseFen(current.fen));
    if (!pos.isLegal(move)) return;

    final (newPos, san) = pos.makeSan(move);

    // Navigate to an existing child if this move is already in the tree.
    for (final child in current.children) {
      if (child.san == san) {
        setNode(child);
        ref.read(moveTreeProvider.notifier).refresh();
        return;
      }
    }

    // New move: append as a child (first child = mainline, others = variations).
    final newNode = MoveNode(fen: newPos.fen, san: san);
    current.addChild(newNode);
    setNode(newNode);

    // Persist asynchronously — the UI doesn't need to wait on the write.
    ref.read(moveTreeProvider.notifier).persist();
    ref.read(moveTreeProvider.notifier).refresh();
  }
}

final activeNodeProvider = NotifierProvider<ActiveNodeNotifier, MoveNode?>(
  () => ActiveNodeNotifier(),
);

// ---------------------------------------------------------------------------
// Board orientation
// ---------------------------------------------------------------------------

class BoardFlippedNotifier extends Notifier<bool> {
  @override
  bool build() => false;
  void toggle() => state = !state;
}

final boardFlippedProvider = NotifierProvider<BoardFlippedNotifier, bool>(
  () => BoardFlippedNotifier(),
);

// ---------------------------------------------------------------------------
// Show threat (opponent-response) arrow on the board
// ---------------------------------------------------------------------------

class ShowThreatArrowNotifier extends Notifier<bool> {
  @override
  bool build() => false;
  void toggle() => state = !state;
}

final showThreatArrowProvider = NotifierProvider<ShowThreatArrowNotifier, bool>(
  () => ShowThreatArrowNotifier(),
);

// ---------------------------------------------------------------------------
// Review depth
// ---------------------------------------------------------------------------

class ReviewDepthNotifier extends Notifier<int> {
  static const _key = 'reviewDepth';

  @override
  int build() {
    _load();
    return 16;
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    state = prefs.getInt(_key) ?? 16;
  }

  Future<void> setDepth(int depth) async {
    state = depth;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_key, depth);
  }
}

final reviewDepthProvider = NotifierProvider<ReviewDepthNotifier, int>(
  () => ReviewDepthNotifier(),
);

// ---------------------------------------------------------------------------
// My Names — player names the user identifies with (for "Me" filter)
// ---------------------------------------------------------------------------

class MyNamesNotifier extends Notifier<List<String>> {
  static const _key = 'myNames';

  @override
  List<String> build() {
    _load();
    return [];
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    state = prefs.getStringList(_key) ?? [];
  }

  Future<void> setNames(List<String> names) async {
    state = List.unmodifiable(names);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_key, names);
  }
}

final myNamesProvider = NotifierProvider<MyNamesNotifier, List<String>>(
  () => MyNamesNotifier(),
);

// ---------------------------------------------------------------------------
// Game Review Logic
// ---------------------------------------------------------------------------

class ReviewProgress {
  final int total;
  final int current;
  final bool isRunning;
  final bool isCompleted;
  final double? whiteAccuracy;
  final double? blackAccuracy;

  /// Mainline moves no evaluation source could rate (position not in the
  /// Lichess cloud cache and no local engine available — the web build has
  /// no Stockfish). Those moves are left unclassified rather than guessed at.
  final int unevaluatedMoves;

  ReviewProgress({
    required this.total,
    required this.current,
    required this.isRunning,
    this.isCompleted = false,
    this.whiteAccuracy,
    this.blackAccuracy,
    this.unevaluatedMoves = 0,
  });
}

class ReviewNotifier extends Notifier<ReviewProgress> {
  @override
  ReviewProgress build() => ReviewProgress(
        total: 0,
        current: 0,
        isRunning: false,
        isCompleted: false,
      );

  int _toCpWhitePerspective(
    EngineEvaluation eval, {
    required bool isWhiteToMove,
  }) {
    if (eval.mate != null) {
      // `mate: 0` means the side to move has just been mated, so it counts as
      // a negative mate score for that side (same as Stockfish's output).
      final mateSign = eval.mate! > 0 ? 1 : -1;
      final whiteMateSign = isWhiteToMove ? mateSign : -mateSign;
      return whiteMateSign * 10000;
    }
    final cp = (eval.scoreCp * 100).toInt();
    return isWhiteToMove ? cp : -cp;
  }

  /// Returns null when no move on that side could be evaluated, so the UI can
  /// hide the badge instead of showing a fabricated 100%.
  double? _calcAccuracy(double totalWpDrop, int moveCount) {
    if (moveCount == 0) return null;
    final avg = totalWpDrop / moveCount;
    return (103.1668 * exp(-0.04354 * avg) - 3.1668).clamp(0.0, 100.0);
  }

  /// Side to move in [fen]. Read from the position itself rather than from the
  /// node's depth in the tree, so games that start from a black-to-move FEN
  /// don't get every evaluation sign-flipped.
  bool _isWhiteToMove(String fen) {
    final parts = fen.split(' ');
    return parts.length < 2 || parts[1] == 'w';
  }

  /// Evaluation for a position that is already over. Checkmate is reported as
  /// `mate: 0` from the side-to-move's perspective (matching what Stockfish
  /// prints for a mated position); stalemate and dead draws are 0.00.
  ///
  /// Without this, the final position of a decisive game gets no eval at all
  /// on web (Lichess doesn't cache mated positions and the stub engine returns
  /// 0.00), which reads as "the mating move threw away a won game".
  EngineEvaluation? _terminalEval(String fen) {
    Position pos;
    try {
      pos = Chess.fromSetup(Setup.parseFen(fen));
    } catch (_) {
      return null;
    }
    if (pos.isCheckmate) {
      return EngineEvaluation(scoreCp: 0, mate: 0, depth: 99);
    }
    if (pos.isStalemate || pos.isInsufficientMaterial) {
      return EngineEvaluation(scoreCp: 0, depth: 99);
    }
    return null;
  }

  /// Tries the Lichess cloud-eval cache first; falls back to the local engine.
  ///
  /// Cloud results are typically depth 30–99 and arrive in < 100 ms for cached
  /// positions (most openings and common middlegame positions). If the cloud
  /// returns nothing — position not cached, network down, or depth too shallow
  /// — we evaluate locally at [localDepth].
  ///
  /// Returns null when neither source can answer: on web there is no local
  /// Stockfish, and its stub returns a 0.00 score that would otherwise be
  /// mistaken for a dead-equal position and produce huge phantom eval swings.
  Future<EngineEvaluation?> _fetchEval(
    EngineService engine,
    String fen, {
    required int localDepth,
  }) async {
    final terminal = _terminalEval(fen);
    if (terminal != null) return terminal;

    final cloud = await CloudEvalService.evaluateBest(fen);
    if (cloud != null) return cloud;

    if (!engine.isAvailable) return null;
    return engine.evaluatePosition(fen, depth: localDepth);
  }

  /// Restore progress state from a previously reviewed game — called after
  /// the tree has been loaded from the DB so the UI shows accuracy badges
  /// without having to re-run the engine.
  void markCompleted() {
    final tree = ref.read(moveTreeProvider);
    final mainline = tree.mainline;
    final hasAnalysis = mainline.any((n) => n.quality != null);
    if (!hasAnalysis) return;

    final game = ref.read(selectedGameProvider);
    state = ReviewProgress(
      total: mainline.length,
      current: mainline.length,
      isRunning: false,
      isCompleted: true,
      whiteAccuracy: game?.whiteAccuracy,
      blackAccuracy: game?.blackAccuracy,
    );
  }

  Future<void> startReview() async {
    final tree = ref.read(moveTreeProvider);
    final engine = ref.read(engineProvider);
    final mainline = tree.mainline;

    if (mainline.isEmpty) return;

    final nodeBeforeReview = ref.read(activeNodeProvider);

    if (ref.read(engineRunningProvider)) {
      ref.read(engineRunningProvider.notifier).toggle();
    }

    final depth = ref.read(reviewDepthProvider);

    state = ReviewProgress(
      total: mainline.length + 1,
      current: 1,
      isRunning: true,
    );

    // Evaluate the starting position. A null eval means no source could rate
    // the position — every eval-derived number stays null until a real
    // evaluation arrives, so nothing is measured against a guess.
    final rootWhiteToMove = _isWhiteToMove(tree.root.fen);
    final rootEval = await _fetchEval(engine, tree.root.fen, localDepth: depth);
    int? prevCpWhite = rootEval == null
        ? null
        : _toCpWhitePerspective(rootEval, isWhiteToMove: rootWhiteToMove);
    String? prevBestMoveUci =
        (rootEval != null && rootEval.pv.isNotEmpty) ? rootEval.pv.first : null;
    final rootMate = rootEval?.mate;
    int? prevBestMateWhite =
        rootMate == null ? null : (rootWhiteToMove ? rootMate : -rootMate);

    double whiteTotalDrop = 0, blackTotalDrop = 0;
    int whiteMoveCount = 0, blackMoveCount = 0;
    int unevaluated = 0;

    // Horizon-shift redistribution state. When a move that *matched* the
    // engine's top recommendation later shows an eval drop, that drop is the
    // engine seeing past its previous horizon — not a real player mistake.
    // We carry such phantom drops backward to the last same-side move that
    // actually deviated from the engine, so blame lands on the move that
    // caused the bad position rather than on the forced sequence after it.
    int? whiteLastDevIdx;
    double whiteLastDevRawDrop = 0.0;
    double whiteHorizonDebt = 0.0;
    int? blackLastDevIdx;
    double blackLastDevRawDrop = 0.0;
    double blackHorizonDebt = 0.0;

    for (int i = 0; i < mainline.length; i++) {
      final node = mainline[i];

      // node.fen is the position *after* the move, so the side to move there
      // is the opponent of whoever played it.
      final isWhiteToMove = _isWhiteToMove(node.fen);
      final isWhiteMove = !isWhiteToMove;

      // Snapshot the parent position's numbers before this node's eval
      // overwrites them — they describe what the mover could have played
      // instead, which is what MoveNode.bestMove* document.
      final parentBestUci = prevBestMoveUci;
      final parentEvalWhite =
          prevCpWhite == null ? null : prevCpWhite / 100.0;
      final parentMateWhite = prevBestMateWhite;

      final eval = await _fetchEval(engine, node.fen, localDepth: depth);

      node.bestMoveUci = parentBestUci;
      node.bestMoveEval = parentEvalWhite;
      node.bestMoveMate = parentMateWhite;

      if (eval == null) {
        // Nothing could evaluate this position. Leave the move unclassified
        // and break the eval chain — a fabricated score here would show up as
        // a huge drop on this move and on the next one.
        unevaluated++;
        node.evaluation = null;
        node.mate = null;
        node.quality = null;
        prevCpWhite = null;
        prevBestMoveUci = null;
        prevBestMateWhite = null;
        whiteLastDevIdx = null;
        blackLastDevIdx = null;

        state = ReviewProgress(
          total: mainline.length + 1,
          current: i + 2,
          isRunning: true,
        );
        continue;
      }

      final cpWhite = _toCpWhitePerspective(eval, isWhiteToMove: isWhiteToMove);
      final matchedEngineTop =
          node.uci != null && node.uci == parentBestUci;

      node.mate = eval.mate != null
          ? (isWhiteToMove ? eval.mate! : -eval.mate!)
          : null;

      prevBestMoveUci = eval.pv.isNotEmpty ? eval.pv.first : null;
      prevBestMateWhite = node.mate;

      if (prevCpWhite == null) {
        // The position before this move has no eval (start of the game or
        // just after a gap), so there is no drop to measure against.
        node.evaluation = cpWhite / 100.0;
        node.quality = null;
        prevCpWhite = cpWhite;

        state = ReviewProgress(
          total: mainline.length + 1,
          current: i + 2,
          isRunning: true,
        );
        continue;
      }

      // Raw WP drop from this player's perspective.
      final wpBefore = MoveEvaluator.cpToWinProb(prevCpWhite);
      final wpAfter = MoveEvaluator.cpToWinProb(cpWhite);
      final rawDrop = (isWhiteMove
              ? wpBefore - wpAfter
              : wpAfter - wpBefore)
          .clamp(0.0, 100.0);

      // Accuracy stats use the raw drop on every move — redistribution only
      // affects which move gets labelled, not the side's overall accuracy
      // (the total drop on a side is invariant under redistribution).
      if (isWhiteMove) {
        whiteTotalDrop += rawDrop;
        whiteMoveCount++;
      } else {
        blackTotalDrop += rawDrop;
        blackMoveCount++;
      }

      // Classification with horizon-shift redistribution.
      // Only negative labels (inaccuracy/mistake/blunder) are assigned;
      // moves with no significant drop get null quality.
      if (matchedEngineTop) {
        // Player followed the engine — carry any phantom drop back onto the
        // last same-side deviation so the correct move isn't penalised.
        if (rawDrop > 0) {
          if (isWhiteMove && whiteLastDevIdx != null) {
            whiteHorizonDebt += rawDrop;
            mainline[whiteLastDevIdx].quality = MoveEvaluator.classifyByWpDrop(
              whiteLastDevRawDrop + whiteHorizonDebt,
            );
          } else if (!isWhiteMove && blackLastDevIdx != null) {
            blackHorizonDebt += rawDrop;
            mainline[blackLastDevIdx].quality = MoveEvaluator.classifyByWpDrop(
              blackLastDevRawDrop + blackHorizonDebt,
            );
          }
        }
        node.quality = null;
      } else {
        // Real deviation. Classify on its own drop and open a fresh debt
        // window so future phantom drops on this side land here.
        node.quality = MoveEvaluator.classifyByWpDrop(rawDrop);
        if (isWhiteMove) {
          whiteLastDevIdx = i;
          whiteLastDevRawDrop = rawDrop;
          whiteHorizonDebt = 0.0;
        } else {
          blackLastDevIdx = i;
          blackLastDevRawDrop = rawDrop;
          blackHorizonDebt = 0.0;
        }
      }
      node.evaluation = cpWhite / 100.0;
      prevCpWhite = cpWhite;

      state = ReviewProgress(
        total: mainline.length + 1,
        current: i + 2,
        isRunning: true,
      );
    }

    final whiteAccuracy = _calcAccuracy(whiteTotalDrop, whiteMoveCount);
    final blackAccuracy = _calcAccuracy(blackTotalDrop, blackMoveCount);

    state = ReviewProgress(
      total: mainline.length + 1,
      current: mainline.length + 1,
      isRunning: false,
      isCompleted: true,
      whiteAccuracy: whiteAccuracy,
      blackAccuracy: blackAccuracy,
      unevaluatedMoves: unevaluated,
    );

    // Persist tree + metadata.
    final selectedGame = ref.read(selectedGameProvider);
    if (selectedGame != null && selectedGame.id != null) {
      final openingCode = OpeningService.detect(mainline) ?? '';
      final updated = selectedGame.copyWith(
        isReviewed: true,
        whiteAccuracy: whiteAccuracy,
        blackAccuracy: blackAccuracy,
        openingCode: openingCode.isNotEmpty
            ? openingCode
            : selectedGame.openingCode,
        lastFen: tree.lastMainlineNode.fen,
      );
      await DatabaseService.updateGameMetadata(updated);
      await DatabaseService.saveTree(selectedGame.id!, tree);
      ref.read(selectedGameProvider.notifier).update(updated);
      await ref.read(gameListProvider.notifier).refresh();
    }

    // Restore standard engine analysis on the last position.
    engine.analyzePosition(mainline.last.fen);

    // Refresh notation so quality labels appear without a re-click.
    ref.read(moveTreeProvider.notifier).refresh();

    // Restore the position the user was on before the review started.
    ref.read(activeNodeProvider.notifier).setNode(nodeBeforeReview);
  }
}

final reviewProvider = NotifierProvider<ReviewNotifier, ReviewProgress>(
  () => ReviewNotifier(),
);

// ─── Board drawing (highlight squares & arrows) ───────────────────────────────

class BoardEditModeNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  void setMode(bool value) => state = value;
}

final boardEditModeProvider = NotifierProvider<BoardEditModeNotifier, bool>(
  BoardEditModeNotifier.new,
);

class DrawColorNotifier extends Notifier<Color> {
  @override
  Color build() => Colors.red;

  void setColor(Color color) => state = color;
}

final drawColorProvider = NotifierProvider<DrawColorNotifier, Color>(
  DrawColorNotifier.new,
);

/// Stores user-drawn shapes keyed by game-id + FEN so each position in each
/// game has its own independent set of highlights/arrows.
class CustomShapesNotifier extends Notifier<Map<String, List<Shape>>> {
  @override
  Map<String, List<Shape>> build() => {};

  String _key(int? gameId, String fen) => 'g${gameId ?? -1}::$fen';

  List<Shape> shapesForNode(int? gameId, String fen) =>
      state[_key(gameId, fen)] ?? [];

  void _update(String key, List<Shape> shapes) {
    state = {...state, key: shapes};
  }

  void clearNode(int? gameId, String fen) {
    final key = _key(gameId, fen);
    final next = Map<String, List<Shape>>.from(state)..remove(key);
    state = next;
  }

  void toggleCircle(int? gameId, String fen, Square sq, Color color) {
    final key = _key(gameId, fen);
    final current = state[key] ?? [];
    final idx = current.indexWhere((s) => s is Circle && s.orig == sq);
    _update(
      key,
      idx >= 0
          ? (List<Shape>.from(current)..removeAt(idx))
          : [...current, Circle(color: color, orig: sq)],
    );
  }

  void toggleArrow(int? gameId, String fen, Square from, Square to, Color color) {
    final key = _key(gameId, fen);
    final current = state[key] ?? [];
    final idx = current.indexWhere(
      (s) => s is Arrow && s.orig == from && s.dest == to,
    );
    _update(
      key,
      idx >= 0
          ? (List<Shape>.from(current)..removeAt(idx))
          : [...current, Arrow(color: color, orig: from, dest: to)],
    );
  }

  /// Returns all shapes for [gameId], keyed by plain FEN (for PGN export).
  Map<String, List<Shape>> shapesForGame(int? gameId) {
    final prefix = 'g${gameId ?? -1}::';
    return {
      for (final e in state.entries)
        if (e.key.startsWith(prefix)) e.key.substring(prefix.length): e.value,
    };
  }
}

final customShapesProvider =
    NotifierProvider<CustomShapesNotifier, Map<String, List<Shape>>>(
  CustomShapesNotifier.new,
);

// ---------------------------------------------------------------------------
// Critical moments — see docs/critical-moments.md
// ---------------------------------------------------------------------------

/// State of a critical-moment run.
///
/// [unavailableReason] is set instead of [report] when the analysis cannot run
/// at all — on web there is no Stockfish, and the cloud endpoint exposes
/// neither MultiPV nor per-depth best moves, so there is nothing to fall back
/// to. Surfacing it is better than an empty list that looks like "no moments".
class CriticalMomentsState {
  final bool isRunning;
  final int completed;
  final int total;

  /// 'shallow' | 'deep', for the progress label.
  final String stage;

  final CriticalMomentReport? report;
  final String? unavailableReason;

  /// Side the report was produced for.
  final Side? analysedSide;

  const CriticalMomentsState({
    this.isRunning = false,
    this.completed = 0,
    this.total = 0,
    this.stage = '',
    this.report,
    this.unavailableReason,
    this.analysedSide,
  });

  bool get hasReport => report != null;

  double get fraction => total == 0 ? 0 : completed / total;
}

class CriticalMomentsNotifier extends Notifier<CriticalMomentsState> {
  @override
  CriticalMomentsState build() => const CriticalMomentsState();

  void clear() => state = const CriticalMomentsState();

  /// Which side to analyse from: whichever player the user identifies with
  /// (`myNamesProvider`), falling back to White.
  Side _sideForUser(GameEntry? game) {
    final names = ref.read(myNamesProvider).map((n) => n.toLowerCase()).toList();
    if (game == null || names.isEmpty) return Side.white;
    if (names.contains(game.black.toLowerCase())) return Side.black;
    return Side.white;
  }

  /// Runs Stage A+B+C over the current game's mainline.
  Future<void> run() async {
    final tree = ref.read(moveTreeProvider);
    final mainline = tree.mainline;
    if (mainline.isEmpty) return;

    final engine = ref.read(engineProvider);
    final game = ref.read(selectedGameProvider);
    final side = _sideForUser(game);

    if (!engine.isAvailable) {
      state = CriticalMomentsState(
        unavailableReason: 'Critical-moment analysis needs the local engine, '
            'which the web build does not ship. Open this game in the desktop '
            'or mobile app.',
        analysedSide: side,
      );
      return;
    }

    // Live analysis and this share one engine process; leave it off for the run.
    final wasRunning = ref.read(engineRunningProvider);
    if (wasRunning) ref.read(engineRunningProvider.notifier).toggle();

    state = CriticalMomentsState(
      isRunning: true,
      total: mainline.length,
      stage: 'shallow',
      analysedSide: side,
    );

    try {
      final report = await CriticalMoments(engine: engine).run(
        mainline,
        side,
        initialFen: tree.root.fen,
        onProgress: (p) {
          state = CriticalMomentsState(
            isRunning: true,
            completed: p.completed,
            total: p.total,
            stage: p.stage,
            analysedSide: side,
          );
        },
      );
      state = CriticalMomentsState(report: report, analysedSide: side);
    } catch (e) {
      state = CriticalMomentsState(
        unavailableReason: 'Critical-moment analysis failed: $e',
        analysedSide: side,
      );
    } finally {
      if (wasRunning && !ref.read(engineRunningProvider)) {
        ref.read(engineRunningProvider.notifier).toggle();
      }
    }
  }
}

final criticalMomentsProvider =
    NotifierProvider<CriticalMomentsNotifier, CriticalMomentsState>(
  CriticalMomentsNotifier.new,
);
