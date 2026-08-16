import 'package:dartchess/dartchess.dart';
import 'package:centipawn/services/critical_moments/critical_moments.dart';

/// Builders for hand-authored engine output.
///
/// These are *synthetic* — they encode the shape of Stockfish's output so the
/// scoring rules can be tested exactly, not the output of a real search. Real
/// frozen games belong in `test/critical_moments/data/` and are produced by
/// `tool/capture_critical_fixture.dart`.

/// A PV line, given as centipawns and a move list.
PvLine pv(List<String> moves, {int cp = 0, int? mate}) =>
    PvLine(movesUci: moves, scoreCp: cp, mateIn: mate);

/// Best-move-by-depth map that settles at [settleDepth] and runs to [maxDepth].
///
/// Below the settle depth the engine "prefers" a different move, which is what
/// depth-to-settle measures.
Map<int, String> settlingAt({
  required int settleDepth,
  required int maxDepth,
  String finalBest = 'e2e4',
  String earlyBest = 'd2d4',
}) =>
    {
      for (int d = 1; d <= maxDepth; d++)
        d: d >= settleDepth ? finalBest : earlyBest,
    };

SearchResult search({
  required String fen,
  required List<PvLine> pvs,
  int depth = 28,
  int legalMoveCount = 30,
  bool inCheck = false,
  Map<int, String>? bestByDepth,
}) =>
    SearchResult(
      fen: fen,
      depth: depth,
      pvs: pvs,
      legalMoveCount: legalMoveCount,
      inCheck: inCheck,
      bestByDepth: bestByDepth ??
          settlingAt(
            settleDepth: 1,
            maxDepth: depth,
            finalBest: pvs.isEmpty ? 'e2e4' : pvs.first.movesUci.first,
            earlyBest: pvs.isEmpty ? 'e2e4' : pvs.first.movesUci.first,
          ),
    );

PlyData ply({
  required int ply,
  required String fenBefore,
  required SearchResult deep,
  Side side = Side.white,
  int? moveNumber,
  String movePlayedUci = 'e2e4',
  String movePlayedSan = 'e4',
  double? timeSpentSec,
  int? clockRemainingSec,
  int? opponentClockRemainingSec,
  PreviousMove? previousMove,
  bool inBook = false,
}) =>
    PlyData(
      ply: ply,
      moveNumber: moveNumber ?? (ply ~/ 2) + 1,
      side: side,
      fenBefore: fenBefore,
      movePlayedUci: movePlayedUci,
      movePlayedSan: movePlayedSan,
      timeSpentSec: timeSpentSec,
      clockRemainingSec: clockRemainingSec,
      opponentClockRemainingSec: opponentClockRemainingSec,
      previousMove: previousMove,
      inBook: inBook,
      shallow: deep,
      deep: deep,
    );

/// Start position, white to move.
const String startFen =
    'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';

/// A quiet middlegame position, white to move.
const String middlegameFen =
    'r1bq1rk1/pp2bppp/2n1pn2/2pp4/3P1B2/2P1PN2/PP1N1PPP/R2QKB1R w KQ - 0 8';

/// King and pawn versus king and pawn, white to move. No queens, few pieces.
const String endgameFen = '8/5pk1/8/8/8/8/5PK1/8 w - - 0 40';

/// Builds a legal game of [count] white plies from the start position, each
/// with the supplied search result, so whole-game rules (runs, percentiles,
/// regression) can be exercised.
List<PlyData> buildGame({
  required int count,
  required SearchResult Function(int index) searchFor,
  double? Function(int index)? timeFor,
  String fen = middlegameFen,
}) {
  return [
    for (int i = 0; i < count; i++)
      ply(
        ply: i * 2,
        moveNumber: i + 1,
        fenBefore: fen,
        deep: searchFor(i),
        timeSpentSec: timeFor?.call(i),
        movePlayedSan: 'M$i',
      )
  ];
}
