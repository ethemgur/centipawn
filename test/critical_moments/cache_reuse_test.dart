import 'package:flutter_test/flutter_test.dart';
import 'package:centipawn/services/engine_types.dart';
import 'package:centipawn/services/critical_moments/analyzer.dart';
import 'package:centipawn/services/critical_moments/ply_builder.dart';
import 'package:centipawn/services/pgn_parser.dart';

/// The review and the critical-moment sweep share one [SearchCache] so the game
/// is searched once instead of twice. That only works if the two agree, string
/// for string, on how a position is spelled: the review caches under
/// `MoveNode.fen`, Stage A looks up `PlyData.fenBefore`, and the cache key is
/// the raw FEN. A one-character difference — a halfmove clock, an en-passant
/// square written as `-` versus a square name — turns every lookup into a miss
/// and silently doubles the work without changing a single result, which is
/// exactly the kind of regression nothing else in the suite would catch.
void main() {
  const pgn = '''
[Event "Cache reuse"]
[White "A"]
[Black "B"]
[Result "*"]

1. e4 e5 2. Nf3 Nc6 3. Bb5 a6 4. Ba4 Nf6 5. O-O Be7 6. Re1 b5 7. Bb3 d6
8. c3 O-O 9. h3 Nb8 10. d4 Nbd7 *
''';

  test('every fenBefore Stage A searches is a FEN the review already cached',
      () {
    final tree = PgnParser.parsePgn(pgn);
    final mainline = tree.mainline;
    expect(mainline, isNotEmpty);

    final plies = PlyBuilder.fromMainline(mainline, initialFen: tree.root.fen);
    expect(plies.length, mainline.length,
        reason: 'the builder must not stop early on a legal game');

    // What the review puts in the cache: the root, then the position after
    // each mainline move.
    final reviewed = <String>{
      tree.root.fen,
      for (final node in mainline) node.fen,
    };

    for (final ply in plies) {
      expect(reviewed, contains(ply.fenBefore),
          reason: 'ply ${ply.ply} (${ply.movePlayedSan}) would miss the cache '
              'and be re-searched');
    }
  });

  test('fenBefore is the previous node\'s fen, position by position', () {
    final tree = PgnParser.parsePgn(pgn);
    final mainline = tree.mainline;
    final plies = PlyBuilder.fromMainline(mainline, initialFen: tree.root.fen);

    expect(plies.first.fenBefore, tree.root.fen);
    for (int i = 1; i < plies.length; i++) {
      expect(plies[i].fenBefore, mainline[i - 1].fen,
          reason: 'ply $i should start from the position after ply ${i - 1}');
    }
  });

  test('a cached result is returned instead of being re-searched', () async {
    final cache = SearchCache();
    const fen = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';
    const result = SearchResult(
      fen: fen,
      depth: 16,
      pvs: [PvLine(movesUci: ['e2e4'], scoreCp: 30)],
      legalMoveCount: 20,
      inCheck: false,
      bestByDepth: {16: 'e2e4'},
    );

    cache.put(fen, 16, 3, result);

    expect(cache.get(fen, 16, 3), same(result));
    // Depth and width are part of the key on purpose: a mismatch must miss
    // rather than hand back a search run at settings the caller didn't ask for.
    expect(cache.get(fen, 15, 3), isNull);
    expect(cache.get(fen, 16, 5), isNull);
  });
}
