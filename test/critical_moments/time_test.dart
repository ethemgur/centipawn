import 'dart:math' as math;
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:centipawn/services/critical_moments/critical_moments.dart';
import 'package:centipawn/services/critical_moments/game_context.dart';
import 'package:centipawn/services/critical_moments/time_regression.dart';

import 'fixtures.dart';

void main() {
  group('OLS fit', () {
    /// Criticality that is deliberately *not* a linear function of move number,
    /// so the two predictors are separable.
    double crit(int i) => (i * 37 % 100).toDouble();

    test('recovers known coefficients from noiseless data', () {
      // log(t+1) = 1.0 + 0.02*criticality + (-0.01)*moveNumber
      final observations = [
        for (int i = 0; i < 30; i++)
          TimeRegression.observation(
            ply: i * 2,
            timeSpentSec:
                math.exp(1.0 + 0.02 * crit(i) - 0.01 * (i + 10)) - 1,
            criticalityPercentile: crit(i),
            moveNumber: i + 10,
          )
      ];
      final fit = TimeRegression.fit(observations)!;
      expect(fit.coefficients[0], closeTo(1.0, 1e-6));
      expect(fit.coefficients[1], closeTo(0.02, 1e-6));
      expect(fit.coefficients[2], closeTo(-0.01, 1e-6));
    });

    test('refuses to fit collinear predictors instead of returning nonsense',
        () {
      // moveNumber constant: the normal equations are singular.
      final observations = [
        for (int i = 0; i < 20; i++)
          TimeRegression.observation(
            ply: i * 2,
            timeSpentSec: math.exp(0.5 + 0.01 * (i * 5.0)) - 1,
            criticalityPercentile: i * 5.0,
            moveNumber: 10,
          )
      ];
      expect(TimeRegression.fit(observations), isNull);

      // criticality a linear function of moveNumber: also singular.
      final collinear = [
        for (int i = 0; i < 20; i++)
          TimeRegression.observation(
            ply: i * 2,
            timeSpentSec: 10.0 + i,
            criticalityPercentile: i * 3.0,
            moveNumber: i + 10,
          )
      ];
      expect(TimeRegression.fit(collinear), isNull);
    });

    test('refuses to fit fewer than twelve points', () {
      final observations = [
        for (int i = 0; i < 8; i++)
          TimeRegression.observation(
            ply: i * 2,
            timeSpentSec: 10.0 + i,
            criticalityPercentile: i * 10.0,
            moveNumber: i + 5,
          )
      ];
      expect(TimeRegression.fit(observations), isNull);
    });

    test('isolates the ply that broke the pattern', () {
      // 19 well-behaved plies plus one where the player moved instantly at a
      // high-criticality moment.
      final observations = <TimeObservation>[
        for (int i = 0; i < 20; i++)
          TimeRegression.observation(
            ply: i * 2,
            timeSpentSec: i == 15
                ? 1.2
                : math.exp(1.0 + 0.02 * crit(i) - 0.005 * (i + 10)) - 1,
            criticalityPercentile: crit(i),
            moveNumber: i + 10,
          )
      ];
      final fit = TimeRegression.fit(observations)!;
      final outlier = fit.residuals[30]!;
      expect(outlier, lessThan(-1.0));
      // Every other residual is small by comparison.
      for (final entry in fit.residuals.entries) {
        if (entry.key == 30) continue;
        expect(entry.value.abs(), lessThan(outlier.abs()));
      }
    });
  });

  group('regression exclusions', () {
    PlyData p({
      int plyIndex = 20,
      double? time = 10,
      int? clock = 600,
      int? oppClock = 600,
    }) =>
        ply(
          ply: plyIndex,
          fenBefore: middlegameFen,
          timeSpentSec: time,
          clockRemainingSec: clock,
          opponentClockRemainingSec: oppClock,
          deep: search(fen: middlegameFen, pvs: [pv(['e2e4'], cp: 20)]),
        );

    test('drops premoves', () {
      expect(TimeRegression.isExcluded(p(time: 0.4), false), isTrue);
      expect(TimeRegression.isExcluded(p(time: 1.5), false), isFalse);
    });

    test('drops the opening', () {
      expect(TimeRegression.isExcluded(p(plyIndex: 6), false), isTrue);
      expect(TimeRegression.isExcluded(p(plyIndex: 8), false), isFalse);
    });

    test('drops either side being in a scramble', () {
      expect(TimeRegression.isExcluded(p(clock: 30), false), isTrue);
      expect(TimeRegression.isExcluded(p(oppClock: 30), false), isTrue);
    });

    test('drops zeroed plies and unknown times', () {
      expect(TimeRegression.isExcluded(p(), true), isTrue);
      expect(TimeRegression.isExcluded(p(time: null), false), isTrue);
    });
  });

  group('verdicts', () {
    GameContext ctxWithTimes(List<double> times) => GameContext(
          plies: [
            for (int i = 0; i < times.length; i++)
              ply(
                ply: i * 2,
                fenBefore: middlegameFen,
                timeSpentSec: times[i],
                deep: search(fen: middlegameFen, pvs: [pv(['e2e4'], cp: 20)]),
              )
          ],
          userSide: Side.white,
        );

    test('a large negative residual is a blind spot', () {
      final ctx = ctxWithTimes(List.filled(10, 20.0));
      final subject = ctx.plies.first;
      expect(TimeRegression.classify(-1.5, subject, ctx), TimeVerdict.blindSpot);
    });

    test('a long think followed by fast moves is productive, not wasted', () {
      // 60s think, then the next three own moves come almost instantly —
      // calculation banked and cashed in. The rest of the game supplies a
      // realistic spread so the lower quartile is not defined by the banked
      // moves themselves.
      final ctx = ctxWithTimes([
        60, // subject
        1, 1, 1, // banked
        5, 5, 5,
        ...List.filled(13, 30.0),
      ]);
      final subject = ctx.plies.first;
      expect(TimeRegression.classify(1.5, subject, ctx),
          TimeVerdict.productiveThink);
    });

    test('a long think followed by more long thinks is wasted', () {
      final ctx = ctxWithTimes(List.filled(10, 40.0));
      final subject = ctx.plies.first;
      expect(TimeRegression.classify(1.5, subject, ctx), TimeVerdict.wasted);
    });

    test('a small residual is normal', () {
      final ctx = ctxWithTimes(List.filled(10, 20.0));
      expect(TimeRegression.classify(0.4, ctx.plies.first, ctx),
          TimeVerdict.normal);
    });
  });

  group('GameContext', () {
    test('treats positions differing only in move counters as identical', () {
      expect(
        GameContext.positionKey('8/5pk1/8/8/8/8/5PK1/8 w - - 0 40'),
        GameContext.positionKey('8/5pk1/8/8/8/8/5PK1/8 w - - 9 55'),
      );
    });

    test('counts plies without a capture or pawn move', () {
      // Knight shuffling back and forth from a quiet position.
      final plies = [
        for (int i = 0; i < 8; i++)
          ply(
            ply: i * 2,
            fenBefore: middlegameFen,
            movePlayedUci: 'f3g1',
            deep: search(fen: middlegameFen, pvs: [pv(['f3g1'], cp: 10)]),
          )
      ];
      final ctx = GameContext(plies: plies, userSide: Side.white);
      expect(ctx.noProgressPlies(0), 1);
      expect(ctx.noProgressPlies(14), 8);
    });

    test('a pawn move resets the no-progress counter', () {
      final plies = [
        for (int i = 0; i < 4; i++)
          ply(
            ply: i * 2,
            fenBefore: middlegameFen,
            movePlayedUci: i == 2 ? 'h2h3' : 'f3g1',
            deep: search(fen: middlegameFen, pvs: [pv(['f3g1'], cp: 10)]),
          )
      ];
      final ctx = GameContext(plies: plies, userSide: Side.white);
      expect(ctx.noProgressPlies(4), 0);
      expect(ctx.noProgressPlies(6), 1);
    });
  });

  group('RepertoireMatcher', () {
    test('reports the departure ply for a loaded line', () {
      final m = RepertoireMatcher()
        ..addLine(['e4', 'c6', 'd4', 'd5', 'e5', 'Bf5']);
      expect(m.departurePly(['e4', 'c6', 'd4', 'd5', 'e5', 'Bf5', 'Nf3']), 6);
      expect(m.departurePly(['e4', 'c6', 'd4', 'Nf6']), 3);
      expect(m.departurePly(['d4']), 0);
    });

    test('handles a repertoire tree with shared prefixes', () {
      final m = RepertoireMatcher()
        ..addLine(['e4', 'c5', 'Nf3', 'd6'])
        ..addLine(['e4', 'c5', 'Nf3', 'Nc6']);
      expect(m.departurePly(['e4', 'c5', 'Nf3', 'Nc6', 'Bb5']), 4);
      expect(m.departurePly(['e4', 'c5', 'Nf3', 'e6']), 3);
    });

    test('classify marks exactly the in-book plies', () {
      final m = RepertoireMatcher()..addLine(['e4', 'e5', 'Nf3']);
      expect(m.classify(['e4', 'e5', 'Nf3', 'Nc6', 'Bb5']),
          [true, true, true, false, false]);
    });

    test('parses lines out of PGN', () {
      final m = RepertoireMatcher.fromPgn('''
[Event "Repertoire"]

1. e4 c6 2. d4 d5 3. e5 Bf5 *
''');
      expect(m.lineCount, 1);
      expect(m.usingFallback, isFalse);
      expect(m.departurePly(['e4', 'c6', 'd4', 'd5', 'e5', 'Bf5', 'Nf3']), 6);
    });

    test('falls back to the ECO book and says so', () {
      final m = RepertoireMatcher();
      expect(m.usingFallback, isTrue);
      // Departure is derived from the built-in opening table, not a cutoff.
      expect(m.departurePly(['e4', 'e5', 'Nf3', 'Nc6']), greaterThan(0));
      expect(m.departurePly(['a3', 'h6']), 0);
    });

    test('does not use a fixed ply cutoff', () {
      // A deep repertoire line stays in book well past any sane fixed cutoff.
      final deepLine = [
        'e4', 'c6', 'd4', 'd5', 'e5', 'Bf5', 'Nf3', 'e6',
        'Be2', 'c5', 'Be3', 'Qb6', 'Nc3', 'Nc6', 'O-O', 'cxd4',
      ];
      final m = RepertoireMatcher()..addLine(deepLine);
      expect(m.departurePly(deepLine), 16);
    });
  });
}
