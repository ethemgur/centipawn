import 'dart:math' as math;
import 'critical_types.dart';
import 'game_context.dart';

/// Minimum surviving plies before a regression is worth running at all. A
/// two-predictor OLS on eight points is noise.
const int kMinRegressionPlies = 12;

class RegressionFit {
  /// [intercept, betaCriticality, betaMoveNumber]
  final List<double> coefficients;

  /// ply index -> residual of log(time+1).
  final Map<int, double> residuals;

  const RegressionFit({required this.coefficients, required this.residuals});
}

/// log(timeSpent + 1) ~ b0 + b1*criticalityPercentile + b2*moveNumber
///
/// `moveNumber` is not optional: time naturally compresses through a game, and
/// omitting it makes every late-game move look like a blind spot.
class TimeRegression {
  /// Plies excluded from the fit (but kept in the criticality output).
  static bool isExcluded(PlyData ply, bool zeroedOut) {
    if (zeroedOut) return true;
    final t = ply.timeSpentSec;
    if (t == null) return true;
    // Premoves and pre-planned recaptures carry no information about thought.
    if (t < 1.0) return true;
    // Book, even when the repertoire matcher did not catch it.
    if (ply.ply < 8) return true;
    final own = ply.clockRemainingSec;
    final opp = ply.opponentClockRemainingSec;
    if (own != null && own < kScrambleSec) return true;
    if (opp != null && opp < kScrambleSec) return true;
    return false;
  }

  /// Fits by normal equations with Gaussian elimination. Returns null when
  /// there is not enough data or the system is singular (e.g. every surviving
  /// ply shares one move number).
  static RegressionFit? fit(List<TimeObservation> observations) {
    if (observations.length < kMinRegressionPlies) return null;

    const k = 3; // intercept + 2 predictors
    final xtx = List.generate(k, (_) => List<double>.filled(k, 0.0));
    final xty = List<double>.filled(k, 0.0);

    for (final o in observations) {
      final row = [1.0, o.criticality, o.moveNumber];
      for (int i = 0; i < k; i++) {
        for (int j = 0; j < k; j++) {
          xtx[i][j] += row[i] * row[j];
        }
        xty[i] += row[i] * o.logTime;
      }
    }

    final beta = _solve(xtx, xty);
    if (beta == null) return null;

    final residuals = <int, double>{};
    for (final o in observations) {
      final predicted =
          beta[0] + beta[1] * o.criticality + beta[2] * o.moveNumber;
      residuals[o.ply] = o.logTime - predicted;
    }
    return RegressionFit(coefficients: beta, residuals: residuals);
  }

  /// Gaussian elimination with partial pivoting.
  static List<double>? _solve(List<List<double>> a, List<double> b) {
    final n = b.length;
    final m = [
      for (int i = 0; i < n; i++) [...a[i], b[i]],
    ];

    for (int col = 0; col < n; col++) {
      var pivot = col;
      for (int r = col + 1; r < n; r++) {
        if (m[r][col].abs() > m[pivot][col].abs()) pivot = r;
      }
      if (m[pivot][col].abs() < 1e-10) return null; // singular
      final tmp = m[col];
      m[col] = m[pivot];
      m[pivot] = tmp;

      for (int r = 0; r < n; r++) {
        if (r == col) continue;
        final factor = m[r][col] / m[col][col];
        for (int c = col; c <= n; c++) {
          m[r][c] -= factor * m[col][c];
        }
      }
    }
    return [for (int i = 0; i < n; i++) m[i][n] / m[i][i]];
  }

  /// Turns a residual into a verdict.
  ///
  /// The banking correction matters: a long think followed by fast moves means
  /// the player calculated ahead and cashed it in. That is good clock
  /// management, not waste.
  static TimeVerdict classify(
    double residual,
    PlyData ply,
    GameContext ctx,
  ) {
    if (residual < -1.0) return TimeVerdict.blindSpot;
    if (residual > 1.0) {
      // Step by own moves, not raw plies.
      final next3 = ctx.timesForPlies(ply.ply + 2, ply.ply + 6);
      if (next3.isNotEmpty) {
        final mean = next3.reduce((a, b) => a + b) / next3.length;
        if (mean < ctx.gameTimeQuartile(1)) return TimeVerdict.productiveThink;
      }
      return TimeVerdict.wasted;
    }
    return TimeVerdict.normal;
  }

  static TimeObservation observation({
    required int ply,
    required double timeSpentSec,
    required double criticalityPercentile,
    required int moveNumber,
  }) =>
      TimeObservation(
        ply: ply,
        logTime: math.log(timeSpentSec + 1),
        criticality: criticalityPercentile,
        moveNumber: moveNumber.toDouble(),
      );
}

/// One row of the design matrix. Build with [TimeRegression.observation].
class TimeObservation {
  final int ply;
  final double logTime;
  final double criticality;
  final double moveNumber;

  const TimeObservation({
    required this.ply,
    required this.logTime,
    required this.criticality,
    required this.moveNumber,
  });
}
