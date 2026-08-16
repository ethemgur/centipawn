import 'dart:math' as math;
import 'package:dartchess/dartchess.dart' show Side;
import 'critical_types.dart';
import 'difficulty.dart';
import 'divergence.dart';
import 'game_context.dart';
import 'gates.dart';
import 'time_regression.dart';

/// Weights and toggles, all in one place so a validation sweep can vary them
/// without recompiling the scorer.
class ScoringConfig {
  final double difficultyFloor;
  final double divergenceWeight;
  final double rawCap;
  final int spreadCapCp;
  final int divergencePlies;
  final DampConfig damps;

  /// Fraction of scored plies reported, capped at [maxMoments].
  final double reportFraction;
  final int maxMoments;

  /// Percentile above which a ply counts as "high scoring" for endgame run
  /// suppression.
  final double endgameRunPercentile;

  const ScoringConfig({
    this.difficultyFloor = kDifficultyFloor,
    this.divergenceWeight = kDivergenceWeight,
    this.rawCap = kRawCap,
    this.spreadCapCp = kSpreadCapCp,
    this.divergencePlies = kDivergencePlies,
    this.damps = DampConfig.all,
    this.reportFraction = 0.15,
    this.maxMoments = 8,
    this.endgameRunPercentile = 75.0,
  });

  ScoringConfig copyWith({
    double? difficultyFloor,
    double? divergenceWeight,
    double? rawCap,
    int? spreadCapCp,
    DampConfig? damps,
    double? reportFraction,
    int? maxMoments,
  }) =>
      ScoringConfig(
        difficultyFloor: difficultyFloor ?? this.difficultyFloor,
        divergenceWeight: divergenceWeight ?? this.divergenceWeight,
        rawCap: rawCap ?? this.rawCap,
        spreadCapCp: spreadCapCp ?? this.spreadCapCp,
        divergencePlies: divergencePlies,
        damps: damps ?? this.damps,
        reportFraction: reportFraction ?? this.reportFraction,
        maxMoments: maxMoments ?? this.maxMoments,
        endgameRunPercentile: endgameRunPercentile,
      );
}

/// Stage C: scoring, gates, ranking and time regression.
///
/// **Pure.** No engine calls, no I/O. Takes the Stage A+B data and returns
/// scored output, so it is re-runnable in milliseconds against frozen fixtures
/// while weights are tuned.
class CriticalMomentScorer {
  final ScoringConfig config;
  final DifficultyProvider difficultyProvider;

  const CriticalMomentScorer({
    this.config = const ScoringConfig(),
    this.difficultyProvider = const HeuristicDifficultyProvider(),
  });

  /// Consequence: how much the choice is worth, saturating at [spreadCapCp].
  double spread(SearchResult search) {
    if (search.pvs.length < 2) return 0.0; // only one line to speak of
    final diff = search.topTwoGapCp;
    return diff.clamp(0, config.spreadCapCp) / config.spreadCapCp;
  }

  CriticalMomentReport score(List<PlyData> plies, Side userSide) {
    final ctx = GameContext(plies: plies, userSide: userSide);
    final userPlies = plies.where((p) => p.side == userSide).toList()
      ..sort((a, b) => a.ply.compareTo(b.ply));

    // Sequential mate-run suppression is a whole-game judgement, so it is
    // resolved before the per-ply gates run.
    final mateRun = ZeroOutGates.mateRunPlies(plies, userSide);

    final zeroed = <ZeroedPly>[];
    final scored = <_ScoredPly>[];

    for (final ply in userPlies) {
      // Zero-outs first, short-circuiting — before any component is computed.
      final gate = mateRun.contains(ply.ply)
          ? GateResult.zero('forced:mate_run')
          : ZeroOutGates.evaluate(ply, ctx);

      if (gate.zeroed) {
        zeroed.add(ZeroedPly(
          ply: ply.ply,
          moveNumber: ply.moveNumber,
          movePlayedSan: ply.movePlayedSan,
          reason: gate.reason!,
        ));
        continue;
      }

      final search = ply.best!;
      final twoPliesAgo = _findPly(userPlies, ply.ply - 2);

      final s = spread(search);
      final difficulty = difficultyProvider.compute(ply, twoPliesAgo);
      final div = Divergence.compute(search, plies: config.divergencePlies);
      final damp = DampGates.evaluate(ply, ctx, config: config.damps);

      final breakdown = ScoreBreakdown(
        spread: s,
        difficultyDts: difficulty.dts,
        difficultyChar: difficulty.character,
        difficultyNov: difficulty.novelty,
        difficultyCombined: difficulty.combined,
        divergence: div,
        gateMultiplier: damp.multiplier,
      );

      scored.add(_ScoredPly(
        ply: ply,
        breakdown: breakdown,
        rawScore: _composite(breakdown, damp.multiplier),
        gatesFired: damp.fired,
      ));
    }

    if (config.damps.endgameRun) _suppressEndgameRuns(scored);

    _assignPercentiles(scored);

    final moments = [
      for (final s in scored)
        CriticalMoment(
          ply: s.ply.ply,
          moveNumber: s.ply.moveNumber,
          side: s.ply.side,
          movePlayedSan: s.ply.movePlayedSan,
          fenBefore: s.ply.fenBefore,
          bestMoveUci: s.ply.best?.bestMoveUci,
          rawScore: s.rawScore,
          criticalityPercentile: s.percentile,
          breakdown: s.breakdown,
          gatesFired: s.gatesFired,
          timeSpentSec: s.ply.timeSpentSec,
        )
    ];

    final withTime = _applyTimeRegression(moments, plies, ctx);

    final ranked = [...withTime]
      ..sort((a, b) => b.rawScore.compareTo(a.rawScore));

    final reportCount = ranked.isEmpty
        ? 0
        : math.min(
            config.maxMoments,
            math.max(1, (config.reportFraction * ranked.length).ceil()),
          );

    return CriticalMomentReport(
      moments: ranked.take(reportCount).toList(),
      allScored: ranked,
      zeroed: zeroed,
      meanResidualTopQuartile: _meanTopQuartileResidual(withTime),
      regressionRan: withTime.any((m) => m.timeResidual != null),
    );
  }

  double _composite(ScoreBreakdown b, double damp) {
    final raw = b.spread *
        (config.difficultyFloor +
            (1 - config.difficultyFloor) * b.difficultyCombined) *
        (1 + config.divergenceWeight * b.divergence) *
        damp;
    return raw.clamp(0.0, config.rawCap);
  }

  static PlyData? _findPly(List<PlyData> plies, int index) {
    for (final p in plies) {
      if (p.ply == index) return p;
    }
    return null;
  }

  /// In a simplified endgame a run of consecutive high-scoring plies usually
  /// reflects one plan, not several decisions. Keep the highest of each run of
  /// four or more and damp the rest, so a single rook endgame cannot bury the
  /// middlegame decision that actually lost the game.
  void _suppressEndgameRuns(List<_ScoredPly> scored) {
    if (scored.length < 4) return;

    final threshold = _percentileValue(
      scored.map((s) => s.rawScore).toList(),
      config.endgameRunPercentile,
    );

    var runStart = 0;
    while (runStart < scored.length) {
      if (!_isRunMember(scored[runStart], threshold)) {
        runStart++;
        continue;
      }
      var runEnd = runStart;
      while (runEnd + 1 < scored.length &&
          // Consecutive own moves are two plies apart.
          scored[runEnd + 1].ply.ply == scored[runEnd].ply.ply + 2 &&
          _isRunMember(scored[runEnd + 1], threshold)) {
        runEnd++;
      }

      final length = runEnd - runStart + 1;
      if (length >= 4) {
        var peak = runStart;
        for (int i = runStart; i <= runEnd; i++) {
          if (scored[i].rawScore > scored[peak].rawScore) peak = i;
        }
        for (int i = runStart; i <= runEnd; i++) {
          if (i == peak) continue;
          scored[i].rawScore *= 0.3;
          scored[i].gatesFired.add('damp:endgame_run');
        }
      }
      runStart = runEnd + 1;
    }
  }

  bool _isRunMember(_ScoredPly s, double threshold) =>
      s.rawScore >= threshold &&
      s.rawScore > 0 &&
      DampGates.isSimplifiedEndgame(s.ply.fenBefore);

  static double _percentileValue(List<double> values, double percentile) {
    if (values.isEmpty) return 0.0;
    final sorted = [...values]..sort();
    final idx = ((sorted.length - 1) * percentile / 100).round();
    return sorted[idx.clamp(0, sorted.length - 1)];
  }

  /// Percent rank within the game, over scored plies only.
  ///
  /// Zeroed plies are excluded from the distribution rather than entered as
  /// zeros: including them compresses everything else into the top decile and
  /// makes the percentiles meaningless in forced-sequence-heavy games.
  static void _assignPercentiles(List<_ScoredPly> scored) {
    if (scored.isEmpty) return;
    if (scored.length == 1) {
      scored.first.percentile = 100.0;
      return;
    }
    final sorted = [...scored]..sort((a, b) => a.rawScore.compareTo(b.rawScore));
    for (int i = 0; i < sorted.length; i++) {
      sorted[i].percentile = 100.0 * i / (sorted.length - 1);
    }
  }

  List<CriticalMoment> _applyTimeRegression(
    List<CriticalMoment> moments,
    List<PlyData> plies,
    GameContext ctx,
  ) {
    final byPly = {for (final p in plies) p.ply: p};
    final observations = <TimeObservation>[];

    for (final m in moments) {
      final ply = byPly[m.ply];
      if (ply == null) continue;
      if (TimeRegression.isExcluded(ply, false)) continue;
      observations.add(TimeRegression.observation(
        ply: m.ply,
        timeSpentSec: ply.timeSpentSec!,
        criticalityPercentile: m.criticalityPercentile,
        moveNumber: m.moveNumber,
      ));
    }

    final fit = TimeRegression.fit(observations);
    if (fit == null) return moments;

    return [
      for (final m in moments)
        if (fit.residuals[m.ply] == null)
          m
        else
          m.copyWith(
            timeResidual: fit.residuals[m.ply],
            verdict: TimeRegression.classify(
              fit.residuals[m.ply]!,
              byPly[m.ply]!,
              ctx,
            ),
          )
    ];
  }

  /// One number describing whether the player allocates time where it matters.
  static double? _meanTopQuartileResidual(List<CriticalMoment> moments) {
    final residuals = <double>[
      for (final m in moments)
        if (m.criticalityPercentile >= 75 && m.timeResidual != null)
          m.timeResidual!,
    ];
    if (residuals.isEmpty) return null;
    return residuals.reduce((a, b) => a + b) / residuals.length;
  }
}

/// Mutable scratch record used while scoring; converted to [CriticalMoment].
class _ScoredPly {
  final PlyData ply;
  final ScoreBreakdown breakdown;
  double rawScore;
  double percentile = 0.0;
  final List<String> gatesFired;

  _ScoredPly({
    required this.ply,
    required this.breakdown,
    required this.rawScore,
    required this.gatesFired,
  });
}
