export 'move_evaluator.dart' show MoveQuality;

class EngineEvaluation {
  final double scoreCp; // Score in centipawns
  final int? mate;
  final List<String> pv; // Principal Variation moves
  final int depth;

  EngineEvaluation({required this.scoreCp, this.mate, this.pv = const [], this.depth = 0});
}
