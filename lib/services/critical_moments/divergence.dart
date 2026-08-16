import 'dart:math' as math;
import 'package:dartchess/dartchess.dart';
import 'critical_types.dart';

/// Coarse fingerprint of a position, chosen so that two structurally different
/// futures compare unequal while move-order transpositions compare equal.
class PositionSignature {
  /// White pawn bitboard and black pawn bitboard — the pawn skeleton.
  final int whitePawns;
  final int blackPawns;

  /// Material by role and side, e.g. `RRBNPPPP/rrbnppp`.
  final String materialSig;

  final bool queensPresent;

  /// (white king left its start file, black king left its start file) — a
  /// proxy for "did this line commit the king" that survives PV truncation.
  final bool whiteKingMoved;
  final bool blackKingMoved;

  const PositionSignature({
    required this.whitePawns,
    required this.blackPawns,
    required this.materialSig,
    required this.queensPresent,
    required this.whiteKingMoved,
    required this.blackKingMoved,
  });

  bool get samePawnSkeletonKey => true;

  bool pawnSkeletonEquals(PositionSignature other) =>
      whitePawns == other.whitePawns && blackPawns == other.blackPawns;

  bool castledEquals(PositionSignature other) =>
      whiteKingMoved == other.whiteKingMoved &&
      blackKingMoved == other.blackKingMoved;
}

class Divergence {
  /// Walks [movesUci] onto the position in [fen] for at most [plies] moves and
  /// signs the result. Returns null when the line cannot be walked at all.
  ///
  /// Uses the PV moves already in hand — there is no re-search here, so this is
  /// close to free.
  static (PositionSignature, int)? walkAndSign(
    String fen,
    List<String> movesUci,
    int plies,
  ) {
    Position pos;
    try {
      pos = Chess.fromSetup(Setup.parseFen(fen));
    } catch (_) {
      return null;
    }

    var played = 0;
    for (final uci in movesUci) {
      if (played >= plies) break;
      final NormalMove move;
      try {
        move = NormalMove.fromUci(uci);
      } catch (_) {
        break;
      }
      if (!pos.isLegal(move)) break;
      pos = pos.play(move);
      played++;
    }
    return (_sign(pos), played);
  }

  static PositionSignature _sign(Position pos) {
    final board = pos.board;
    return PositionSignature(
      whitePawns: (board.byRole(Role.pawn) & board.white).value,
      blackPawns: (board.byRole(Role.pawn) & board.black).value,
      materialSig: _materialSignature(board),
      queensPresent: board.byRole(Role.queen).isNotEmpty,
      whiteKingMoved: _kingLeftStart(board, Side.white),
      blackKingMoved: _kingLeftStart(board, Side.black),
    );
  }

  static bool _kingLeftStart(Board board, Side side) {
    final king = board.kingOf(side);
    if (king == null) return true;
    final startFile = 4; // e-file
    return king.file.value != startFile;
  }

  static String _materialSignature(Board board) {
    const order = [
      Role.queen,
      Role.rook,
      Role.bishop,
      Role.knight,
      Role.pawn,
    ];
    const letters = {
      Role.queen: 'Q',
      Role.rook: 'R',
      Role.bishop: 'B',
      Role.knight: 'N',
      Role.pawn: 'P',
    };
    final buf = StringBuffer();
    for (final side in [Side.white, Side.black]) {
      if (side == Side.black) buf.write('/');
      for (final role in order) {
        final count = (board.byRole(role) & board.bySide(side)).size;
        final letter = letters[role]!;
        buf.write((side == Side.white ? letter : letter.toLowerCase()) * count);
      }
    }
    return buf.toString();
  }

  /// How structurally different the two best lines are, 0..1.
  ///
  /// This is the term that catches the target case the whole module exists for:
  /// two moves a few centipawns apart, one keeping queens on and one entering a
  /// rook endgame. Spread calls that irrelevant; divergence calls it the game.
  static double compute(SearchResult deep, {int plies = kDivergencePlies}) {
    if (deep.pvs.length < 2) return 0.0;

    final a = walkAndSign(deep.fen, deep.pvs[0].movesUci, plies);
    final b = walkAndSign(deep.fen, deep.pvs[1].movesUci, plies);
    if (a == null || b == null) return 0.0;

    // A truncated comparison is still informative at 8–11 plies; below 6 the
    // two lines have barely separated and any difference is noise.
    final common = math.min(a.$2, b.$2);
    if (common < 6) return 0.0;

    final (sigA, walkedA) = a;
    final (sigB, walkedB) = b;
    // Re-walk to the common length when one line ran out early, so we are not
    // comparing a 12-ply future against a 7-ply one.
    final PositionSignature left;
    final PositionSignature right;
    if (walkedA == walkedB) {
      left = sigA;
      right = sigB;
    } else {
      final ra = walkAndSign(deep.fen, deep.pvs[0].movesUci, common);
      final rb = walkAndSign(deep.fen, deep.pvs[1].movesUci, common);
      if (ra == null || rb == null) return 0.0;
      left = ra.$1;
      right = rb.$1;
    }

    double d = 0.0;
    if (!left.pawnSkeletonEquals(right)) d += 0.35;
    if (left.queensPresent != right.queensPresent) d += 0.30;
    if (left.materialSig != right.materialSig) d += 0.20;
    if (!left.castledEquals(right)) d += 0.15;
    return d;
  }
}
