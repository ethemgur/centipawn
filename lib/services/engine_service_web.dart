import 'dart:async';
import 'engine_types.dart';

class EngineService {
  final _evaluationController = StreamController<List<EngineEvaluation>>.broadcast();

  Stream<List<EngineEvaluation>> get evaluationStream => _evaluationController.stream;
  bool get isReady => false;

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
