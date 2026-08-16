import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:centipawn/services/critical_moments/critical_moments.dart';
import 'package:centipawn/services/pgn_parser.dart';

import 'fixtures.dart';

void main() {
  group('AnalysedGame serialization', () {
    test('round-trips everything scoring depends on', () {
      final original = AnalysedGame(
        userSide: Side.white,
        label: 'game-01',
        plies: [
          ply(
            ply: 0,
            fenBefore: startFen,
            movePlayedUci: 'e2e4',
            movePlayedSan: 'e4',
            timeSpentSec: 3.5,
            clockRemainingSec: 580,
            opponentClockRemainingSec: 600,
            previousMove: PreviousMove(
              uci: 'd7d5',
              wasCapture: true,
              toSquare: Square.fromName('d5'),
            ),
            deep: search(
              fen: startFen,
              pvs: [
                pv(['e2e4', 'e7e5'], cp: 35),
                pv(['d2d4'], cp: 10),
                pv(['g1f3'], mate: 6),
              ],
              legalMoveCount: 20,
              inCheck: true,
              bestByDepth: settlingAt(settleDepth: 11, maxDepth: 28),
            ),
          ),
        ],
      );

      final restored = AnalysedGame.decode(original.encode());
      final a = original.plies.single;
      final b = restored.plies.single;

      expect(restored.userSide, Side.white);
      expect(restored.label, 'game-01');
      expect(b.ply, a.ply);
      expect(b.moveNumber, a.moveNumber);
      expect(b.side, a.side);
      expect(b.fenBefore, a.fenBefore);
      expect(b.movePlayedUci, a.movePlayedUci);
      expect(b.timeSpentSec, a.timeSpentSec);
      expect(b.clockRemainingSec, a.clockRemainingSec);
      expect(b.opponentClockRemainingSec, a.opponentClockRemainingSec);
      expect(b.previousMove!.uci, a.previousMove!.uci);
      expect(b.previousMove!.wasCapture, isTrue);
      expect(b.previousMove!.toSquare, a.previousMove!.toSquare);

      // bestByDepth is the piece most easily lost in transit, and
      // depth-to-settle is meaningless without it.
      expect(b.deep!.bestByDepth, a.deep!.bestByDepth);
      expect(b.deep!.bestByDepth.length, 28);
      expect(b.deep!.legalMoveCount, 20);
      expect(b.deep!.inCheck, isTrue);
      expect(b.deep!.pvs.map((p) => p.movesUci),
          a.deep!.pvs.map((p) => p.movesUci));
      expect(b.deep!.pvs[2].mateIn, 6);
      expect(b.deep!.pvs[2].normalisedCp, a.deep!.pvs[2].normalisedCp);
    });

    test('scoring a restored fixture matches scoring the original', () {
      final plies = [
        for (int i = 0; i < 12; i++)
          ply(
            ply: i * 2,
            fenBefore: startFen,
            timeSpentSec: 5.0 + i,
            deep: search(
              fen: startFen,
              pvs: [
                pv(['e2e4', 'e7e5', 'g1f3', 'b8c6', 'f1b5', 'a7a6', 'b5c6',
                    'd7c6'], cp: 40 + i * 10),
                pv(['d2d4', 'd7d5', 'c2c4', 'e7e6', 'b1c3', 'g8f6', 'c1g5',
                    'f8e7'], cp: 0),
              ],
              bestByDepth: settlingAt(settleDepth: 8 + i, maxDepth: 28),
            ),
          )
      ];
      final game = AnalysedGame(plies: plies, userSide: Side.white);

      final before = CriticalMoments.scoreOnly(game);
      final after = CriticalMoments.scoreOnly(AnalysedGame.decode(game.encode()));

      expect(after.allScored.length, before.allScored.length);
      for (int i = 0; i < before.allScored.length; i++) {
        expect(after.allScored[i].ply, before.allScored[i].ply);
        expect(after.allScored[i].rawScore,
            closeTo(before.allScored[i].rawScore, 1e-12));
      }
    });
  });

  group('SearchCache', () {
    test('keys on fen, depth and multiPv together', () {
      final cache = SearchCache();
      final a = search(fen: startFen, pvs: [pv(['e2e4'], cp: 20)], depth: 15);
      final b = search(fen: startFen, pvs: [pv(['d2d4'], cp: 25)], depth: 28);
      cache.put(startFen, 15, 3, a);
      cache.put(startFen, 28, 5, b);

      expect(cache.get(startFen, 15, 3)!.bestMoveUci, 'e2e4');
      expect(cache.get(startFen, 28, 5)!.bestMoveUci, 'd2d4');
      // A different multiPv is a different search, not a cache hit.
      expect(cache.get(startFen, 15, 5), isNull);
      expect(cache.size, 2);
    });

    test('survives a JSON round trip so re-scoring never re-searches', () {
      final cache = SearchCache()
        ..put(startFen, 28, 5,
            search(fen: startFen, pvs: [pv(['e2e4'], cp: 20)], depth: 28));
      final restored = SearchCache()..loadJson(cache.toJson());
      expect(restored.get(startFen, 28, 5)!.bestMoveUci, 'e2e4');
    });
  });

  group('PlyBuilder', () {
    test('derives time spent from clock comments', () {
      final tree = PgnParser.parsePgn(
        '1. e4 {[%clk 0:03:00]} e5 {[%clk 0:03:00]} '
        '2. Nf3 {[%clk 0:02:52]} Nc6 {[%clk 0:02:45]} '
        '3. Bb5 {[%clk 0:02:30]} a6 {[%clk 0:02:44]} *',
      );
      final plies = PlyBuilder.fromMainline(tree.mainline);

      expect(plies, hasLength(6));
      // First move of each side has no previous reading to difference against.
      expect(plies[0].timeSpentSec, isNull);
      expect(plies[1].timeSpentSec, isNull);
      expect(plies[2].timeSpentSec, 8.0); // 180 -> 172
      expect(plies[3].timeSpentSec, 15.0); // 180 -> 165
      expect(plies[4].timeSpentSec, 22.0); // 172 -> 150
    });

    test('adds the increment back', () {
      final tree = PgnParser.parsePgn(
        '1. e4 {[%clk 0:03:00]} e5 {[%clk 0:03:00]} '
        '2. Nf3 {[%clk 0:02:58]} Nc6 {[%clk 0:03:00]} *',
      );
      final plies = PlyBuilder.fromMainline(tree.mainline, incrementSec: 2);
      // Clock fell 2s but 2s was added back, so 4s of thought.
      expect(plies[2].timeSpentSec, 4.0);
    });

    test('leaves time unknown rather than negative', () {
      final tree = PgnParser.parsePgn(
        '1. e4 {[%clk 0:03:00]} e5 {[%clk 0:03:00]} '
        '2. Nf3 {[%clk 0:03:30]} Nc6 {[%clk 0:03:00]} *',
      );
      final plies = PlyBuilder.fromMainline(tree.mainline);
      expect(plies[2].timeSpentSec, isNull);
    });

    test('tracks side, move number and the previous capture', () {
      final tree = PgnParser.parsePgn('1. e4 d5 2. exd5 Qxd5 *');
      final plies = PlyBuilder.fromMainline(tree.mainline);

      expect(plies[0].side, Side.white);
      expect(plies[1].side, Side.black);
      expect(plies[2].moveNumber, 2);
      expect(plies[2].movePlayedUci, 'e4d5');
      // Qxd5 recaptures on the square exd5 landed on.
      expect(plies[3].previousMove!.wasCapture, isTrue);
      expect(plies[3].previousMove!.toSquare, Square.fromName('d5'));
    });

    test('marks book plies from a repertoire', () {
      final tree = PgnParser.parsePgn('1. e4 c6 2. d4 d5 3. Nc3 dxe4 *');
      final repertoire = RepertoireMatcher()..addLine(['e4', 'c6', 'd4', 'd5']);
      final plies = PlyBuilder.fromMainline(tree.mainline, repertoire: repertoire);

      expect(plies.map((p) => p.inBook).toList(),
          [true, true, true, true, false, false]);
    });

    test('handles a game with no clock tags at all', () {
      final tree = PgnParser.parsePgn('1. e4 e5 2. Nf3 Nc6 *');
      final plies = PlyBuilder.fromMainline(tree.mainline);
      expect(plies, hasLength(4));
      expect(plies.every((p) => p.timeSpentSec == null), isTrue);
    });
  });

  group('Stage A flagging', () {
    SearchResult withGap(int gap) => search(
          fen: startFen,
          pvs: [pv(['e2e4'], cp: gap), pv(['d2d4'], cp: 0)],
          depth: 15,
        );

    test('flags on the absolute threshold even in a quiet game', () {
      // All spreads tiny; only the one above 0.05 (>15cp) qualifies absolutely,
      // but the percentile rule still contributes.
      final plies = [
        for (int i = 0; i < 10; i++)
          ply(ply: i * 2, fenBefore: startFen, deep: withGap(i == 4 ? 60 : 2))
      ];
      for (final p in plies) {
        p.deep = null; // Stage A has only the shallow result
      }
      final flagged =
          CriticalMomentAnalyzer.flagForDeepAnalysis(plies, Side.white);
      expect(flagged.map((p) => p.ply), contains(8));
    });

    test('flags the top slice even when nothing crosses the threshold', () {
      final plies = [
        for (int i = 0; i < 10; i++)
          ply(ply: i * 2, fenBefore: startFen, deep: withGap(i))
      ];
      for (final p in plies) {
        p.deep = null;
      }
      final flagged =
          CriticalMomentAnalyzer.flagForDeepAnalysis(plies, Side.white);
      // 20% of 10 plies = 2, all with spread far below the absolute threshold.
      expect(flagged.length, greaterThanOrEqualTo(2));
      expect(flagged.map((p) => p.ply), contains(18));
    });

    test('ignores opponent plies', () {
      final plies = [
        ply(ply: 0, fenBefore: startFen, deep: withGap(200)),
        ply(
          ply: 1,
          fenBefore: startFen,
          side: Side.black,
          deep: withGap(300),
        ),
      ];
      for (final p in plies) {
        p.deep = null;
      }
      final flagged =
          CriticalMomentAnalyzer.flagForDeepAnalysis(plies, Side.white);
      expect(flagged.map((p) => p.ply), [0]);
    });
  });
}
