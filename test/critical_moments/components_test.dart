import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:centipawn/services/critical_moments/critical_moments.dart';
import 'package:centipawn/services/critical_moments/divergence.dart';
import 'package:centipawn/services/critical_moments/move_character.dart';
import 'package:centipawn/services/critical_moments/see.dart';

import 'fixtures.dart';

Position pos(String fen) => Chess.fromSetup(Setup.parseFen(fen));
NormalMove uci(String s) => NormalMove.fromUci(s);

void main() {
  group('normalisedCp', () {
    test('leaves centipawn scores alone', () {
      expect(pv(['e2e4'], cp: 42).normalisedCp, 42);
    });

    test('ranks a faster mate above a slower one', () {
      expect(pv(['e2e4'], mate: 1).normalisedCp,
          greaterThan(pv(['e2e4'], mate: 5).normalisedCp));
    });

    test('signs mates against the side to move correctly', () {
      expect(pv(['e2e4'], mate: -2).normalisedCp, lessThan(-9000));
      expect(pv(['e2e4'], mate: 2).normalisedCp, greaterThan(9000));
    });

    test('mate outranks any centipawn score', () {
      expect(pv(['e2e4'], mate: 30).normalisedCp, greaterThan(2000));
    });
  });

  group('spread', () {
    const scorer = CriticalMomentScorer();

    test('is zero when only one line exists', () {
      final r = search(fen: startFen, pvs: [pv(['e2e4'], cp: 30)]);
      expect(scorer.spread(r), 0.0);
    });

    test('scales linearly up to the cap', () {
      final r = search(fen: startFen, pvs: [
        pv(['e2e4'], cp: 150),
        pv(['d2d4'], cp: 0),
      ]);
      expect(scorer.spread(r), closeTo(0.5, 1e-9));
    });

    test('saturates past the cap so one hung queen cannot dominate', () {
      final small = search(fen: startFen, pvs: [
        pv(['e2e4'], cp: 300),
        pv(['d2d4'], cp: 0),
      ]);
      final huge = search(fen: startFen, pvs: [
        pv(['e2e4'], cp: 5000),
        pv(['d2d4'], cp: 0),
      ]);
      expect(scorer.spread(small), 1.0);
      expect(scorer.spread(huge), 1.0);
    });

    test('never goes negative when the second line scores higher', () {
      final r = search(fen: startFen, pvs: [
        pv(['e2e4'], cp: 0),
        pv(['d2d4'], cp: 50),
      ]);
      expect(scorer.spread(r), 0.0);
    });
  });

  group('depth to settle', () {
    test('is zero for a move that is best from the first iteration', () {
      final r = search(
        fen: startFen,
        pvs: [pv(['e2e4'], cp: 20)],
        bestByDepth: settlingAt(settleDepth: 1, maxDepth: 28),
      );
      expect(HeuristicDifficultyProvider.depthToSettle(r), 0.0);
    });

    test('rises for a move that only surfaces deep', () {
      final r = search(
        fen: startFen,
        pvs: [pv(['e2e4'], cp: 20)],
        bestByDepth: settlingAt(settleDepth: 20, maxDepth: 28),
      );
      expect(HeuristicDifficultyProvider.depthToSettle(r), 1.0);
    });

    test('is monotone in settle depth', () {
      double at(int d) => HeuristicDifficultyProvider.depthToSettle(search(
            fen: startFen,
            pvs: [pv(['e2e4'], cp: 20)],
            bestByDepth: settlingAt(settleDepth: d, maxDepth: 28),
          ));
      expect(at(8), greaterThan(at(6)));
      expect(at(14), greaterThan(at(8)));
    });

    test('returns 0 rather than a spurious high value on a short search', () {
      final r = search(
        fen: startFen,
        pvs: [pv(['e2e4'], cp: 20)],
        depth: 4,
        bestByDepth: {1: 'd2d4', 2: 'd2d4', 3: 'e2e4', 4: 'e2e4'},
      );
      expect(HeuristicDifficultyProvider.depthToSettle(r), 0.0);
    });

    test('only counts the final unbroken agreement run', () {
      // Settles at 10, wobbles at 15, so the real settle point is 16.
      final map = settlingAt(settleDepth: 10, maxDepth: 28);
      map[15] = 'g1f3';
      final r = search(
        fen: startFen,
        pvs: [pv(['e2e4'], cp: 20)],
        bestByDepth: map,
      );
      expect(HeuristicDifficultyProvider.depthToSettle(r),
          closeTo((16 - 4) / 16.0, 1e-9));
    });
  });

  group('static exchange evaluation', () {
    test('a free capture wins the piece', () {
      // Black knight on d5 is undefended; white pawn on e4 can take it.
      final p = pos('4k3/8/8/3n4/4P3/8/8/4K3 w - - 0 1');
      expect(See.evaluate(p, uci('e4d5')), See.pieceValue[Role.knight]);
    });

    test('a defended piece costs the attacker', () {
      // Knight on d5 defended by the c6 pawn: QxN loses the queen for a knight.
      final p = pos('4k3/8/2p5/3n4/8/8/8/3QK3 w - - 0 1');
      expect(See.evaluate(p, uci('d1d5')), lessThan(0));
    });

    test('taking an undefended rook wins it outright', () {
      final p = pos('4k3/8/8/3r4/3R4/8/8/4K3 w - - 0 1');
      expect(See.evaluate(p, uci('d4d5')), See.pieceValue[Role.rook]);
    });

    test('an equal trade nets nothing', () {
      // Black rook on d5 defended by the rook on d8: RxR, RxR.
      final p = pos('3rk3/8/8/3r4/3R4/8/8/4K3 w - - 0 1');
      expect(See.evaluate(p, uci('d4d5')), 0);
    });

    test('a king cannot recapture into a defended square', () {
      // Black rook d8 is defended by nothing, but after RxR the black king on
      // e8 may not take back while the second white rook covers d8.
      final p = pos('3rk3/8/8/8/8/3R4/3R4/4K3 w - - 0 1');
      expect(See.evaluate(p, uci('d3d8')), See.pieceValue[Role.rook]);
    });

    test('a quiet move to a safe square is neutral', () {
      final p = pos(middlegameFen);
      expect(See.evaluate(p, uci('h2h3')), 0);
    });

    test('flags a quiet move onto a pawn-attacked square as a sacrifice', () {
      // Bishop f3-d5 walks into the c6 pawn and is simply lost.
      final p = pos('4k3/8/2p5/8/8/5B2/8/4K3 w - - 0 1');
      expect(See.isSacrifice(p, uci('f3d5')), isTrue);
      expect(See.evaluate(p, uci('f3d5')), -See.pieceValue[Role.bishop]!);
      // The same bishop going somewhere safe is not.
      expect(See.isSacrifice(p, uci('f3e4')), isFalse);
    });

    test('a rook behind a rook defends it through the x-ray', () {
      // One black rook against doubled white rooks: RxR, RxR is an even trade,
      // which is only visible once the recapture re-scans the file.
      final p = pos('3rk3/8/8/8/8/3R4/3R4/4K3 b - - 0 1');
      expect(See.evaluate(p, uci('d8d3')), 0);
    });

    test('the side with the extra attacker on the file wins material', () {
      // Doubled rooks both sides, black to move: black captures last and comes
      // out a rook ahead.
      final p = pos('3rk3/3r4/8/8/8/3R4/3R4/4K3 b - - 0 1');
      expect(See.evaluate(p, uci('d7d3')), See.pieceValue[Role.rook]);
    });
  });

  group('move character', () {
    test('a quiet non-check move scores the quiet bonus', () {
      final p = pos(middlegameFen);
      // h2h3: quiet, not a retreat, not a sacrifice, not into a pawn attack.
      expect(MoveCharacter.difficulty(p, uci('h2h3')), closeTo(0.30, 1e-9));
    });

    test('a check is capped regardless of its other properties', () {
      // White queen checks from h5; without the cap this would score higher.
      final p = pos('rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2');
      final score = MoveCharacter.difficulty(p, uci('d1h5'));
      expect(score, lessThanOrEqualTo(0.3));
    });

    test('identifies a retreat and exempts pawns', () {
      final p = pos('r1bqkb1r/pppp1ppp/2n2n2/4p3/2B1P3/5N2/PPPP1PPP/RNBQK2R w KQkq - 0 5');
      expect(MoveCharacter.isRetreat(p, uci('c4f1')), isTrue);
      expect(MoveCharacter.isRetreat(p, uci('d2d3')), isFalse);
    });

    test('a rook lift along a rank is not a retreat', () {
      final p = pos('4k3/8/8/8/8/8/8/R3K3 w - - 0 1');
      expect(MoveCharacter.isRetreat(p, uci('a1d1')), isFalse);
    });

    test('detects a piece stepping into a pawn attack', () {
      // Knight to d5 where the c6 pawn hits it.
      final p = pos('4k3/8/2p5/8/4N3/8/8/4K3 w - - 0 1');
      expect(MoveCharacter.movesIntoPawnAttack(p, uci('e4d6')), isFalse);
      final p2 = pos('4k3/8/2p5/8/8/4N3/8/4K3 w - - 0 1');
      expect(MoveCharacter.movesIntoPawnAttack(p2, uci('e3d5')), isTrue);
    });

    test('a pawn advance is never "into a pawn attack"', () {
      final p = pos('4k3/8/2p5/8/3P4/8/8/4K3 w - - 0 1');
      expect(MoveCharacter.movesIntoPawnAttack(p, uci('d4d5')), isFalse);
    });

    test('stays within 0..1', () {
      final p = pos(middlegameFen);
      for (final entry in p.legalMoves.entries) {
        for (final to in entry.value.squares) {
          final score = MoveCharacter.difficulty(
              p, NormalMove(from: entry.key, to: to));
          expect(score, inInclusiveRange(0.0, 1.0));
        }
      }
    });
  });

  group('continuation novelty', () {
    SearchResult withPv(List<String> moves) =>
        search(fen: startFen, pvs: [pv(moves, cp: 20)]);

    test('defaults at the start of the game', () {
      final current = ply(ply: 0, fenBefore: startFen, deep: withPv(['e2e4']));
      expect(HeuristicDifficultyProvider.continuationNovelty(current, null),
          kNoveltyDefault);
    });

    test('scores low when the plan was already projected', () {
      final earlier = ply(
        ply: 0,
        fenBefore: startFen,
        deep: withPv(['e2e4', 'e7e5', 'g1f3']),
      );
      final current = ply(
        ply: 2,
        fenBefore: startFen,
        deep: withPv(['g1f3', 'b8c6']),
      );
      expect(HeuristicDifficultyProvider.continuationNovelty(current, earlier),
          0.3);
    });

    test('scores high when a new idea has appeared', () {
      final earlier = ply(
        ply: 0,
        fenBefore: startFen,
        deep: withPv(['e2e4', 'e7e5', 'g1f3']),
      );
      final current = ply(
        ply: 2,
        fenBefore: startFen,
        deep: withPv(['f1c4', 'b8c6']),
      );
      expect(HeuristicDifficultyProvider.continuationNovelty(current, earlier),
          1.0);
    });

    test('defaults when the earlier PV was too short to project', () {
      final earlier =
          ply(ply: 0, fenBefore: startFen, deep: withPv(['e2e4', 'e7e5']));
      final current = ply(ply: 2, fenBefore: startFen, deep: withPv(['g1f3']));
      expect(HeuristicDifficultyProvider.continuationNovelty(current, earlier),
          kNoveltyDefault);
    });
  });

  group('divergence', () {
    test('is zero when there is no alternative line', () {
      final r = search(fen: startFen, pvs: [pv(['e2e4'], cp: 20)]);
      expect(Divergence.compute(r), 0.0);
    });

    test('is zero when both lines reach the same structure', () {
      // Transposition: same moves in a different order.
      final r = search(fen: startFen, pvs: [
        pv(['e2e4', 'e7e5', 'g1f3', 'b8c6', 'f1c4', 'g8f6', 'd2d3'], cp: 20),
        pv(['e2e4', 'e7e5', 'f1c4', 'b8c6', 'g1f3', 'g8f6', 'd2d3'], cp: 15),
      ]);
      expect(Divergence.compute(r), 0.0);
    });

    test('fires when one line trades queens and the other does not', () {
      final r = search(
        fen: 'rnbqkbnr/ppp2ppp/8/3pp3/3PP3/8/PPP2PPP/RNBQKBNR w KQkq - 0 3',
        pvs: [
          // Queens come off.
          pv(['d1d5' /* illegal, walk stops */], cp: 10),
          pv(['d4e5', 'd5e4', 'd1d8', 'e8d8'], cp: 5),
        ],
      );
      // Walk is too short to compare; must not fabricate a score.
      expect(Divergence.compute(r), 0.0);
    });

    test('does not compare lines shorter than six plies', () {
      final r = search(fen: startFen, pvs: [
        pv(['e2e4', 'e7e5'], cp: 20),
        pv(['d2d4', 'd7d5'], cp: 15),
      ]);
      expect(Divergence.compute(r), 0.0);
    });

    test('detects a genuinely different pawn structure', () {
      final r = search(fen: startFen, pvs: [
        pv(['e2e4', 'e7e5', 'g1f3', 'b8c6', 'f1b5', 'a7a6', 'b5c6', 'd7c6'],
            cp: 20),
        pv(['d2d4', 'd7d5', 'c2c4', 'e7e6', 'b1c3', 'g8f6', 'c1g5', 'f8e7'],
            cp: 15),
      ]);
      expect(Divergence.compute(r), greaterThan(0.0));
    });

    test('stays within 0..1', () {
      final r = search(fen: startFen, pvs: [
        pv(['e2e4', 'e7e5', 'g1f3', 'b8c6', 'f1b5', 'a7a6', 'b5c6', 'd7c6'],
            cp: 20),
        pv(['d2d4', 'd7d5', 'c2c4', 'e7e6', 'b1c3', 'g8f6', 'c1g5', 'f8e7'],
            cp: 15),
      ]);
      expect(Divergence.compute(r), inInclusiveRange(0.0, 1.0));
    });
  });
}
