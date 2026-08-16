import 'dart:async';
import 'engine_types.dart';

class EngineService {
  final _evaluationController = StreamController<PositionEvals>.broadcast();

  /// Never emits — see [isAvailable]. On web the only real evaluation source is
  /// `CloudEvalService`, so nothing may depend on this stream producing a value
  /// before it treats an eval as usable.
  Stream<PositionEvals> get evaluationStream => _evaluationController.stream;
  bool get isReady => false;

  /// No Stockfish build ships with the web app, so nothing here can actually
  /// evaluate a position — [evaluatePosition] returns a placeholder. Callers
  /// must check this before treating a returned score as real analysis.
  bool get isAvailable => false;

  EngineService();

  void analyzePosition(String fen) {
    // No-op on web
  }

  Future<EngineEvaluation> evaluatePosition(String fen, {int depth = 12}) async {
    return EngineEvaluation(scoreCp: 0);
  }

  void stop() {
    // No-op on web
  }

  void dispose() {
    _evaluationController.close();
  }

  static MoveQuality getMoveLabel(double previousCp, double newCp) {
    return MoveQuality.good;
  }
}
