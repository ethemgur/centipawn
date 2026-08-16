import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:centipawn/services/critical_moments/critical_moments.dart';
import 'package:centipawn/services/critical_moments/game_context.dart';
import 'package:centipawn/services/critical_moments/gates.dart';

import 'fixtures.dart';

/// A position where black has just captured on e5 and white has exactly one
/// recapture (the d4 pawn), plus other legal moves.
const String recaptureFen =
    'rnbqkbnr/pppp1ppp/8/4p3/3P4/8/PPP1PPPP/RNBQKBNR w KQkq - 0 3';

GameContext ctxFor(List<PlyData> plies) =>
    GameContext(plies: plies, userSide: Side.white);

void main() {
  group('zero-out gates', () {
    test('a single legal move is not a decision', () {
      // Black king on h8 in check from the rook, only one flight square.
      final p = ply(
        ply: 0,
        fenBefore: '7k/8/8/8/8/8/6R1/6RK b - - 0 1',
        side: Side.black,
        deep: search(
          fen: '7k/8/8/8/8/8/6R1/6RK b - - 0 1',
          pvs: [pv(['h8h7'], cp: -900)],
          legalMoveCount: 1,
        ),
      );
      final gate = ZeroOutGates.evaluate(p, ctxFor([p]));
      expect(gate.zeroed, isTrue);
      expect(gate.reason, 'forced:single_legal');
    });

    test('book plies are zeroed before anything else runs', () {
      final p = ply(
        ply: 0,
        fenBefore: startFen,
        inBook: true,
        deep: search(fen: startFen, pvs: [
          pv(['e2e4'], cp: 500),
          pv(['d2d4'], cp: 0),
        ]),
      );
      expect(ZeroOutGates.evaluate(p, ctxFor([p])).reason, 'book');
    });

    test('a check evasion with a huge gap and few replies is forced', () {
      const fen = '4k3/8/8/8/8/8/4r3/4K3 w - - 0 1';
      final p = ply(
        ply: 0,
        fenBefore: fen,
        deep: search(
          fen: fen,
          pvs: [pv(['e1d1'], cp: -50), pv(['e1f1'], cp: -900)],
          legalMoveCount: 3,
          inCheck: true,
        ),
      );
      expect(ZeroOutGates.evaluate(p, ctxFor([p])).reason,
          'forced:check_evasion');
    });

    test('a check evasion with a real choice is kept', () {
      const fen = '4k3/8/8/8/8/8/4r3/4K3 w - - 0 1';
      final p = ply(
        ply: 0,
        fenBefore: fen,
        deep: search(
          fen: fen,
          pvs: [pv(['e1d1'], cp: -50), pv(['e1f1'], cp: -90)],
          legalMoveCount: 3,
          inCheck: true,
        ),
      );
      expect(ZeroOutGates.evaluate(p, ctxFor([p])).zeroed, isFalse);
    });

    test('the check-evasion gate uses the raw gap, not the clamped spread', () {
      // 400cp is past the 300 spread cap, so a clamped comparison could never
      // tell this apart from a 300cp gap.
      const fen = '4k3/8/8/8/8/8/4r3/4K3 w - - 0 1';
      SearchResult withGap(int gap) => search(
            fen: fen,
            pvs: [pv(['e1d1'], cp: 0), pv(['e1f1'], cp: -gap)],
            legalMoveCount: 2,
            inCheck: true,
          );
      expect(
        ZeroOutGates.evaluate(
                ply(ply: 0, fenBefore: fen, deep: withGap(400)), ctxFor([]))
            .zeroed,
        isTrue,
      );
      expect(
        ZeroOutGates.evaluate(
                ply(ply: 0, fenBefore: fen, deep: withGap(250)), ctxFor([]))
            .zeroed,
        isFalse,
      );
    });

    test('the only recapture, when it is also best, is forced', () {
      final p = ply(
        ply: 4,
        fenBefore: recaptureFen,
        previousMove: PreviousMove(
          uci: 'd5e5',
          wasCapture: true,
          toSquare: Square.fromName('e5'),
        ),
        deep: search(
          fen: recaptureFen,
          pvs: [pv(['d4e5'], cp: 40), pv(['g1f3'], cp: -60)],
        ),
      );
      expect(ZeroOutGates.evaluate(p, ctxFor([p])).reason,
          'forced:recapture_single');
    });

    test('a zwischenzug survives the recapture gate', () {
      // Only one piece can recapture, but the engine prefers something else —
      // this is exactly where zwischenzugs live and must not be zeroed.
      final p = ply(
        ply: 4,
        fenBefore: recaptureFen,
        previousMove: PreviousMove(
          uci: 'd5e5',
          wasCapture: true,
          toSquare: Square.fromName('e5'),
        ),
        deep: search(
          fen: recaptureFen,
          pvs: [pv(['d1h5'], cp: 200), pv(['d4e5'], cp: 40)],
        ),
      );
      expect(ZeroOutGates.evaluate(p, ctxFor([p])).zeroed, isFalse);
    });

    test('mate execution is zeroed but the entry into the net is not', () {
      const fen = '6k1/5ppp/8/8/8/8/5PPP/R5K1 w - - 0 1';
      final execution = ply(
        ply: 0,
        fenBefore: fen,
        deep: search(fen: fen, pvs: [
          pv(['a1a8'], mate: 2),
          pv(['a1a7'], mate: 4),
        ]),
      );
      expect(ZeroOutGates.evaluate(execution, ctxFor([])).reason,
          'forced:mate_execution');

      final entry = ply(
        ply: 0,
        fenBefore: fen,
        deep: search(fen: fen, pvs: [
          pv(['a1a8'], mate: 2),
          pv(['a1a7'], cp: 120),
        ]),
      );
      expect(ZeroOutGates.evaluate(entry, ctxFor([])).zeroed, isFalse);
    });

    test('opposite-signed mates are a real decision', () {
      const fen = '6k1/5ppp/8/8/8/8/5PPP/R5K1 w - - 0 1';
      final p = ply(
        ply: 0,
        fenBefore: fen,
        deep: search(fen: fen, pvs: [
          pv(['a1a8'], mate: 2),
          pv(['a1a7'], mate: -3),
        ]),
      );
      expect(ZeroOutGates.evaluate(p, ctxFor([])).zeroed, isFalse);
    });

    test('a shrinking mate run is zeroed after the entry ply', () {
      final plies = [
        for (int i = 0; i < 5; i++)
          ply(
            ply: i * 2,
            fenBefore: middlegameFen,
            deep: search(
              fen: middlegameFen,
              pvs: [pv(['a1a8'], mate: 5 - i)],
            ),
          )
      ];
      final zeroed = ZeroOutGates.mateRunPlies(plies, Side.white);
      // Entry (ply 0) kept; the execution that follows is suppressed.
      expect(zeroed.contains(0), isFalse);
      expect(zeroed, containsAll([2, 4, 6, 8]));
    });
  });

  group('damp gates', () {
    test('a decided position is damped', () {
      final p = ply(
        ply: 20,
        fenBefore: middlegameFen,
        deep: search(fen: middlegameFen, pvs: [
          pv(['e2e4'], cp: 900),
          pv(['d2d4'], cp: 700),
          pv(['g1f3'], cp: 650),
        ]),
      );
      final r = DampGates.evaluate(p, ctxFor([p]));
      expect(r.fired, contains('damp:decided'));
      expect(r.multiplier, closeTo(0.2, 1e-9));
    });

    test('conversion technique escapes the decided damp', () {
      // Winning, but the third-best move throws it away — a real test of technique.
      final p = ply(
        ply: 20,
        fenBefore: middlegameFen,
        deep: search(fen: middlegameFen, pvs: [
          pv(['e2e4'], cp: 900),
          pv(['d2d4'], cp: 400),
          pv(['g1f3'], cp: 20),
        ]),
      );
      expect(DampGates.evaluate(p, ctxFor([p])).fired, isEmpty);
    });

    test('a mutual time scramble is damped', () {
      final p = ply(
        ply: 60,
        fenBefore: middlegameFen,
        clockRemainingSec: 20,
        opponentClockRemainingSec: 30,
        deep: search(fen: middlegameFen, pvs: [
          pv(['e2e4'], cp: 50),
          pv(['d2d4'], cp: 0),
        ]),
      );
      expect(DampGates.evaluate(p, ctxFor([p])).fired, contains('damp:scramble'));
    });

    test('only one side short of time is not a scramble', () {
      final p = ply(
        ply: 60,
        fenBefore: middlegameFen,
        clockRemainingSec: 20,
        opponentClockRemainingSec: 600,
        deep: search(fen: middlegameFen, pvs: [
          pv(['e2e4'], cp: 50),
          pv(['d2d4'], cp: 0),
        ]),
      );
      expect(DampGates.evaluate(p, ctxFor([p])).fired, isEmpty);
    });

    test('damps are individually toggleable for validation', () {
      final p = ply(
        ply: 20,
        fenBefore: middlegameFen,
        deep: search(fen: middlegameFen, pvs: [
          pv(['e2e4'], cp: 900),
          pv(['d2d4'], cp: 700),
          pv(['g1f3'], cp: 650),
        ]),
      );
      final off = DampGates.evaluate(p, ctxFor([p]), config: DampConfig.none);
      expect(off.multiplier, 1.0);
      expect(off.fired, isEmpty);
    });

    test('recognises a simplified endgame', () {
      expect(DampGates.isSimplifiedEndgame(endgameFen), isTrue);
      expect(DampGates.isSimplifiedEndgame(middlegameFen), isFalse);
      expect(DampGates.isSimplifiedEndgame(startFen), isFalse);
    });
  });

  group('composite and ranking', () {
    SearchResult sr({required int gap, int settle = 1}) => search(
          fen: middlegameFen,
          pvs: [
            pv(['h2h3', 'a7a6', 'g1f3', 'b8c6', 'f1e2', 'g8f6', 'e1g1'],
                cp: gap),
            pv(['a2a3', 'd7d5', 'b1c3', 'g8f6', 'c1g5', 'f8e7', 'e2e3'], cp: 0),
          ],
          bestByDepth:
              settlingAt(settleDepth: settle, maxDepth: 28, finalBest: 'h2h3'),
        );

    test('a bigger spread outranks a smaller one, all else equal', () {
      final plies = [
        ply(ply: 0, fenBefore: middlegameFen, deep: sr(gap: 30)),
        ply(ply: 2, fenBefore: middlegameFen, deep: sr(gap: 250)),
      ];
      final report = const CriticalMomentScorer().score(plies, Side.white);
      expect(report.allScored.first.ply, 2);
    });

    test('the difficulty floor keeps an easy-but-consequential move alive', () {
      // Zero difficulty everywhere: the moment must still score, or a position
      // most players find would vanish even when this player missed it.
      final plies = [
        ply(ply: 0, fenBefore: middlegameFen, deep: sr(gap: 300, settle: 1)),
      ];
      final report = const CriticalMomentScorer().score(plies, Side.white);
      expect(report.allScored.single.rawScore, greaterThan(0.0));
      expect(report.allScored.single.breakdown.difficultyCombined,
          lessThan(0.5));
    });

    test('raw score is capped', () {
      final plies = [
        ply(
          ply: 0,
          fenBefore: middlegameFen,
          deep: sr(gap: 5000, settle: 28),
        ),
      ];
      final report = const CriticalMomentScorer().score(plies, Side.white);
      expect(report.allScored.single.rawScore, lessThanOrEqualTo(kRawCap));
    });

    test('zeroed plies are excluded from the distribution, not entered as 0',
        () {
      // Ten forced plies plus two real ones. If the forced plies entered as
      // zeros, both real plies would sit in the top decile.
      final plies = <PlyData>[
        for (int i = 0; i < 10; i++)
          ply(
            ply: i * 2,
            fenBefore: middlegameFen,
            inBook: true,
            deep: sr(gap: 100),
          ),
        ply(ply: 20, fenBefore: middlegameFen, deep: sr(gap: 40)),
        ply(ply: 22, fenBefore: middlegameFen, deep: sr(gap: 250)),
      ];
      final report = const CriticalMomentScorer().score(plies, Side.white);
      expect(report.zeroed, hasLength(10));
      expect(report.allScored, hasLength(2));
      // Percentiles span the full range over the two surviving plies.
      final percentiles =
          report.allScored.map((m) => m.criticalityPercentile).toList()..sort();
      expect(percentiles.first, 0.0);
      expect(percentiles.last, 100.0);
    });

    test('reports at most maxMoments and at least one', () {
      final plies = [
        for (int i = 0; i < 100; i++)
          ply(ply: i * 2, fenBefore: middlegameFen, deep: sr(gap: 50 + i)),
      ];
      final report = const CriticalMomentScorer().score(plies, Side.white);
      // 15% of 100 plies is 15, capped at the reported five.
      expect(report.moments.length, 5);
      expect(report.allScored.length, 100);
    });

    test('only the analysed side is scored', () {
      final plies = [
        ply(ply: 0, fenBefore: middlegameFen, deep: sr(gap: 100)),
        ply(
          ply: 1,
          fenBefore: middlegameFen,
          side: Side.black,
          deep: sr(gap: 300),
        ),
      ];
      final report = const CriticalMomentScorer().score(plies, Side.white);
      expect(report.allScored, hasLength(1));
      expect(report.allScored.single.ply, 0);
    });

    test('the breakdown is populated for every scored moment', () {
      final plies = [
        ply(ply: 0, fenBefore: middlegameFen, deep: sr(gap: 120, settle: 12)),
      ];
      final m = const CriticalMomentScorer().score(plies, Side.white).allScored.single;
      expect(m.breakdown.spread, greaterThan(0));
      expect(m.breakdown.difficultyCombined, greaterThan(0));
      expect(m.breakdown.gateMultiplier, greaterThan(0));
      expect(m.bestMoveUci, 'h2h3');
    });

    test('divergence lifts a low-spread moment above a higher-spread one', () {
      // The target case: two moves close in eval, one changing the game's
      // character completely. Spread alone would rank these the other way.
      // PV moves are walked onto the position, so they must be legal from it.
      final structural = search(
        fen: startFen,
        pvs: [
          // Ruy Lopez exchange: doubled c-pawns, queens on.
          pv(['e2e4', 'e7e5', 'g1f3', 'b8c6', 'f1b5', 'a7a6', 'b5c6', 'd7c6'],
              cp: 20),
          // Queen's Gambit Declined: a completely different structure.
          pv(['d2d4', 'd7d5', 'c2c4', 'e7e6', 'b1c3', 'g8f6', 'c1g5', 'f8e7'],
              cp: 5),
        ],
        bestByDepth: settlingAt(settleDepth: 1, maxDepth: 28, finalBest: 'e2e4'),
      );
      // Both lines reach the same place — bigger eval gap, no structural stake.
      final flat = search(
        fen: startFen,
        pvs: [
          pv(['h2h3', 'a7a6', 'g1f3', 'b8c6', 'f1e2', 'g8f6', 'd2d3'], cp: 25),
          pv(['h2h3', 'a7a6', 'g1f3', 'b8c6', 'f1e2', 'g8f6', 'd2d3'], cp: 0),
        ],
        bestByDepth: settlingAt(settleDepth: 1, maxDepth: 28, finalBest: 'h2h3'),
      );

      final report = const CriticalMomentScorer().score([
        ply(ply: 0, fenBefore: startFen, deep: structural),
        ply(ply: 2, fenBefore: startFen, deep: flat),
      ], Side.white);

      expect(report.allScored.first.breakdown.divergence, greaterThan(0));
      expect(report.allScored.first.ply, 0);
    });
  });

  group('endgame run suppression', () {
    test('keeps the peak of a long run and damps the rest', () {
      SearchResult sr(int gap) => search(
            fen: endgameFen,
            pvs: [pv(['f2f4'], cp: gap), pv(['g2g3'], cp: 0)],
            bestByDepth:
                settlingAt(settleDepth: 10, maxDepth: 28, finalBest: 'f2f4'),
          );
      // Six consecutive high-scoring endgame plies, peak in the middle.
      final plies = [
        for (int i = 0; i < 6; i++)
          ply(
            ply: i * 2,
            fenBefore: endgameFen,
            deep: sr(i == 3 ? 290 : 250),
          )
      ];

      // Every ply shares one FEN, which legitimately trips the repetition damp.
      // Turn the others off so this asserts the run rule and nothing else.
      const onlyRunDamp = DampConfig(
        decided: false,
        shuffling: false,
        scramble: false,
        postBlunder: false,
      );
      final damped = const CriticalMomentScorer(
        config: ScoringConfig(damps: onlyRunDamp),
      ).score(plies, Side.white);
      final undamped = const CriticalMomentScorer(
        config: ScoringConfig(damps: DampConfig.none),
      ).score(plies, Side.white);

      final suppressed = damped.allScored
          .where((m) => m.gatesFired.contains('damp:endgame_run'))
          .toList();
      expect(suppressed, hasLength(5));
      expect(damped.allScored.first.ply, 6); // the peak survives
      expect(undamped.allScored
          .every((m) => !m.gatesFired.contains('damp:endgame_run')), isTrue);
    });

    test('leaves a short run alone', () {
      SearchResult sr() => search(
            fen: endgameFen,
            pvs: [pv(['f2f4'], cp: 250), pv(['g2g3'], cp: 0)],
          );
      final plies = [
        for (int i = 0; i < 3; i++)
          ply(ply: i * 2, fenBefore: endgameFen, deep: sr())
      ];
      final report = const CriticalMomentScorer().score(plies, Side.white);
      expect(
        report.allScored.any((m) => m.gatesFired.contains('damp:endgame_run')),
        isFalse,
      );
    });

    test('does not fire in a middlegame', () {
      SearchResult sr() => search(
            fen: middlegameFen,
            pvs: [pv(['h2h3'], cp: 250), pv(['a2a3'], cp: 0)],
          );
      final plies = [
        for (int i = 0; i < 8; i++)
          ply(ply: i * 2, fenBefore: middlegameFen, deep: sr())
      ];
      final report = const CriticalMomentScorer().score(plies, Side.white);
      expect(
        report.allScored.any((m) => m.gatesFired.contains('damp:endgame_run')),
        isFalse,
      );
    });
  });
}
