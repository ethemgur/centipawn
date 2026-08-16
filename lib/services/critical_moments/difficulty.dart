import 'package:dartchess/dartchess.dart';
import 'critical_types.dart';
import 'move_character.dart';

/// Per-component difficulty numbers, kept separate so the breakdown can report
/// each one and validation can attribute a bad ranking to the right term.
class DifficultyParts {
  final double dts;
  final double character;
  final double novelty;
  final double combined;

  const DifficultyParts({
    required this.dts,
    required this.character,
    required this.novelty,
    required this.combined,
  });

  static const DifficultyParts zero =
      DifficultyParts(dts: 0, character: 0, novelty: 0, combined: 0);
}

/// The seam a `MaiaDifficultyProvider` slots into later without touching the
/// composite. Do not inline the blend into the scorer.
abstract class DifficultyProvider {
  DifficultyParts compute(PlyData ply, PlyData? twoPliesAgo);
}

/// Stockfish-only difficulty. Runs fully on-device, which is the point.
class HeuristicDifficultyProvider implements DifficultyProvider {
  const HeuristicDifficultyProvider();

  @override
  DifficultyParts compute(PlyData ply, PlyData? twoPliesAgo) {
    final search = ply.best;
    if (search == null || search.pvs.isEmpty) return DifficultyParts.zero;

    final dts = depthToSettle(search);
    final character = moveCharacter(ply, search);
    final novelty = continuationNovelty(ply, twoPliesAgo);

    final combined = (kDtsWeight * dts +
            kCharWeight * character +
            kNoveltyWeight * novelty)
        .clamp(0.0, 1.0);

    return DifficultyParts(
      dts: dts,
      character: character,
      novelty: novelty,
      combined: combined,
    );
  }

  /// Shallowest depth after which the engine never changes its mind, mapped to
  /// 0..1 over depths 4..20.
  ///
  /// A move that is best at depth 3 and stays best is one a human sees
  /// instantly. A move that only surfaces at depth 22 was never going to be
  /// found over the board. This also absorbs what would otherwise be a separate
  /// "depth instability" factor — adding that back as its own multiplier would
  /// double-count.
  static double depthToSettle(SearchResult search) {
    final finalBest = search.bestMoveUci;
    if (finalBest == null) return 0.0;

    final depths = search.bestByDepth.keys.toList()..sort();
    // Very forced positions terminate early; too few iterations to say anything.
    if (depths.length < 6) return 0.0;

    var settle = depths.last;
    for (int i = depths.length - 1; i >= 0; i--) {
      if (search.bestByDepth[depths[i]] != finalBest) break;
      settle = depths[i];
    }
    return ((settle - 4) / 16.0).clamp(0.0, 1.0);
  }

  /// Move-character difficulty for the engine's top move at this ply.
  static double moveCharacter(PlyData ply, SearchResult search) {
    final bestUci = search.bestMoveUci;
    if (bestUci == null) return 0.0;

    final Position pos;
    final NormalMove move;
    try {
      pos = Chess.fromSetup(Setup.parseFen(ply.fenBefore));
      move = NormalMove.fromUci(bestUci);
    } catch (_) {
      return 0.0;
    }
    if (!pos.isLegal(move)) return 0.0;

    final prev = ply.previousMove;
    return MoveCharacter.difficulty(
      pos,
      move,
      lastCaptureSquare: (prev != null && prev.wasCapture) ? prev.toSquare : null,
    );
  }

  /// Was this idea already on the board two plies ago?
  ///
  /// If the engine's current recommendation was already its projected
  /// continuation, the player is executing a plan they already had rather than
  /// making a decision. A newly-appeared best move means an idea materialised
  /// that was not visible before. Cheapest genuinely novel signal here, and it
  /// survives the eventual Maia integration.
  static double continuationNovelty(PlyData current, PlyData? twoPliesAgo) {
    if (twoPliesAgo == null) return kNoveltyDefault;

    final prevSearch = twoPliesAgo.best;
    if (prevSearch == null || prevSearch.pvs.isEmpty) return kNoveltyDefault;

    final prevPv = prevSearch.pvs.first.movesUci;
    if (prevPv.length < 3) return kNoveltyDefault;

    final currentSearch = current.best;
    final actualBest = currentSearch?.bestMoveUci;
    if (actualBest == null) return kNoveltyDefault;

    // prevPv[2] is our move two plies on: ours, theirs, ours.
    return prevPv[2] == actualBest ? 0.3 : 1.0;
  }
}
