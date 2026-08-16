import 'dart:math' as math;
import 'package:dartchess/dartchess.dart';
import 'see.dart';

/// Move-type predicates plus the "move character" difficulty component.
///
/// The premise: humans systematically underweight certain kinds of move. A
/// quiet move, a retreat, a sacrifice, a piece stepping into a pawn's reach —
/// each is a move type that does not volunteer itself during calculation.
class MoveCharacter {
  /// True when [move] removes an enemy piece, en passant included.
  static bool isCapture(Position pos, NormalMove move) {
    if (pos.board.pieceAt(move.to) != null) return true;
    return pos.board.roleAt(move.from) == Role.pawn && pos.epSquare == move.to;
  }

  static bool givesCheck(Position pos, NormalMove move) {
    try {
      return pos.play(move).isCheck;
    } catch (_) {
      return false;
    }
  }

  /// A piece moving to a rank strictly closer to its own back rank.
  ///
  /// Pawns are exempt — they cannot retreat, and treating a pawn push as one
  /// would invert the signal. A rook lift along a rank is not a retreat either,
  /// because the rank does not change.
  static bool isRetreat(Position pos, NormalMove move) {
    final piece = pos.board.pieceAt(move.from);
    if (piece == null || piece.role == Role.pawn) return false;

    final fromRank = move.from.rank.value;
    final toRank = move.to.rank.value;
    return piece.color == Side.white ? toRank < fromRank : toRank > fromRank;
  }

  /// A non-pawn landing on a square an enemy pawn attacks in the resulting
  /// position. Evaluated after the move so a pawn that was pinned or captured
  /// by the move itself does not count.
  static bool movesIntoPawnAttack(Position pos, NormalMove move) {
    final piece = pos.board.pieceAt(move.from);
    if (piece == null || piece.role == Role.pawn) return false;

    final Position after;
    try {
      after = pos.play(move);
    } catch (_) {
      return false;
    }

    final enemyPawns =
        after.board.byRole(Role.pawn) & after.board.bySide(piece.color.opposite);
    for (final pawnSquare in enemyPawns.squares) {
      if (pawnAttacks(piece.color.opposite, pawnSquare).has(move.to)) {
        return true;
      }
    }
    return false;
  }

  /// True when [move] is the only capture available in the position.
  static bool isOnlyCapture(Position pos, NormalMove move) {
    if (!isCapture(pos, move)) return false;
    var captures = 0;
    for (final entry in pos.legalMoves.entries) {
      for (final to in entry.value.squares) {
        final candidate = NormalMove(from: entry.key, to: to);
        if (isCapture(pos, candidate)) {
          captures++;
          if (captures > 1) return false;
        }
      }
    }
    return captures == 1;
  }

  /// True when [move] recaptures on the square the opponent just captured on.
  static bool isRecapture(NormalMove move, Square? lastCaptureSquare) =>
      lastCaptureSquare != null && move.to == lastCaptureSquare;

  /// Move-character difficulty, 0..1.
  ///
  /// [lastCaptureSquare] is the square the opponent's previous move captured
  /// on, or null when it was not a capture — needed for the forcing-move cap.
  static double difficulty(
    Position pos,
    NormalMove move, {
    Square? lastCaptureSquare,
  }) {
    final capture = isCapture(pos, move);
    final check = givesCheck(pos, move);

    double c = 0.0;
    if (!capture && !check) c += 0.30; // quiet
    if (isRetreat(pos, move)) c += 0.25;
    if (!capture && See.isSacrifice(pos, move)) c += 0.25;
    if (movesIntoPawnAttack(pos, move)) c += 0.20;

    c = c.clamp(0.0, 1.0);

    // Forcing moves are the first thing anyone looks at, whatever the component
    // flags say. Applied after, so it caps rather than competes.
    if (check ||
        isOnlyCapture(pos, move) ||
        isRecapture(move, lastCaptureSquare)) {
      c = math.min(c, 0.3);
    }
    return c;
  }
}
