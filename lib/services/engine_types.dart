export 'move_evaluator.dart' show MoveQuality;

class EngineEvaluation {
  final double scoreCp; // Score in centipawns
  final int? mate;
  final List<String> pv; // Principal Variation moves
  final int depth;

  EngineEvaluation({required this.scoreCp, this.mate, this.pv = const [], this.depth = 0});
}

/// A batch of evaluations together with the FEN they were produced for.
///
/// Evaluations arrive asynchronously (streamed from Stockfish, awaited from the
/// Lichess cloud) while the user is free to keep moving through the game, so a
/// batch on its own says nothing about which position it describes. Carrying
/// [fen] alongside lets consumers discard results that belong to a position the
/// user has already left, instead of rendering them against the current board.
class PositionEvals {
  final String fen;
  final List<EngineEvaluation> evals;

  const PositionEvals(this.fen, this.evals);

  /// No evaluation available (nothing analysed yet, or the source came back
  /// empty). Never matches a real FEN, so it can't be mistaken for fresh data.
  static const PositionEvals none = PositionEvals('', []);

  bool get isEmpty => evals.isEmpty;
  bool get isNotEmpty => evals.isNotEmpty;

  /// True when this batch has results and they describe [currentFen].
  bool matches(String? currentFen) =>
      evals.isNotEmpty && currentFen != null && fen == currentFen;
}
