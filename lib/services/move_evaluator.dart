import 'dart:math';

enum MoveQuality {
  best,
  excellent,
  good,
  inaccuracy,
  mistake,
  blunder,
}

class ChessEvaluation {
  final int cp; // Centipawns
  final int? mate; // Mate in X

  ChessEvaluation({required this.cp, this.mate});

  /// Parses UCI engine score string (e.g., "cp 150" or "mate 3").
  factory ChessEvaluation.parse(String score) {
    final parts = score.split(' ');
    if (parts.length >= 2) {
      final value = int.tryParse(parts[1]) ?? 0;
      if (parts[0] == 'cp') {
        return ChessEvaluation(cp: value);
      } else if (parts[0] == 'mate') {
        return ChessEvaluation(cp: value > 0 ? 10000 : -10000, mate: value);
      }
    }
    return ChessEvaluation(cp: 0);
  }

  /// Converts evaluation to centipawns, handling mate scores as extreme values.
  int get centipawns {
    if (mate != null) {
      return mate! > 0 ? 10000 : -10000;
    }
    return cp;
  }
}

class MoveEvaluator {
  /// Converts a raw centipawn value into a win probability percentage (0.0 to 100.0)
  /// using the Lichess logistic curve formula.
  static double cpToWinProb(int cp) {
    // Standard Lichess formula: WDL = 50 + 50 * (2 / (1 + exp(-0.00368208 * cp)) - 1)
    return 50 + 50 * (2 / (1 + exp(-0.00368208 * cp)) - 1);
  }

  /// Classifies a move by comparing the best possible evaluation and the actual evaluation.
  /// 
  /// [bestEval]: Evaluation of the best move suggested by the engine.
  /// [actualEval]: Evaluation of the move actually played.
  /// [isWhiteTurn]: Whether it was White's turn when the move was made.
  /// 
  /// Returns a [MoveQuality] based on the Win Probability drop.
  static MoveQuality? classifyMove(
    ChessEvaluation bestEval,
    ChessEvaluation actualEval,
    bool isWhiteTurn,
  ) {
    // Convert evaluations to Win Probabilities.
    // Centipawns are absolute (positive for White, negative for Black).
    // Win Prob is also absolute (100% = White wins, 0% = Black wins).
    double bestWinProb = cpToWinProb(bestEval.centipawns);
    double actualWinProb = cpToWinProb(actualEval.centipawns);

    // Calculate the drop relative to the active player.
    double drop;
    if (isWhiteTurn) {
      // White wants to maximize WinProb. Loss = Best - Actual.
      drop = bestWinProb - actualWinProb;
    } else {
      // Black wants to minimize WinProb (maximize their own win chance).
      // Black WinProb = 100 - White WinProb.
      // Loss = (100 - Best) - (100 - Actual) = Actual - Best.
      drop = actualWinProb - bestWinProb;
    }

    // Ensure drop is not negative due to engine noise
    drop = max(0.0, drop);

    return classifyByWpDrop(drop);
  }

  /// Classifies a move directly from its win-probability drop (already in
  /// percentage points, clamped to 0..100). Exposed so the game-review code
  /// can reclassify earlier moves when horizon-shift redistribution pushes a
  /// phantom drop backward onto them.
  static MoveQuality? classifyByWpDrop(double drop) {
    if (drop >= 20.0) return MoveQuality.blunder;
    if (drop >= 10.0) return MoveQuality.mistake;
    if (drop >= 5.0) return MoveQuality.inaccuracy;
    return null;
  }
}

/*
UNIT TESTS (Edge Cases):

1. Completely winning endgame:
   Best: +8.0 cp (99.9% win), Actual: +6.0 cp (99.5% win)
   Drop: 0.4% -> null (Not classified despite 2.0 cp drop — already winning)

2. Small slip:
   Best: +0.5 cp (54.6% win), Actual: -0.3 cp (47.2% win)
   Drop: 7.4% -> null (below 5% inaccuracy threshold — wait, 7.4% >= 5%)
   -> MoveQuality.inaccuracy

3. Moderate drop:
   Best: +0.5 cp (54.6% win), Actual: -1.5 cp (36.7% win)
   Drop: 17.9% -> MoveQuality.mistake (Drop is between 10% and 20%)

4. Large drop:
   Best: 0.0 cp (50.0% win), Actual: -2.5 cp (28.4% win)
   Drop: 21.6% -> MoveQuality.blunder (Drop is 20% or more)

5. Huge blunder:
   Best: mate 3 (100% win), Actual: cp 200 (67.4% win)
   Drop: 32.6% -> MoveQuality.blunder (Drop is 20% or more)
*/
