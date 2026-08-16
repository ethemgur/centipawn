import 'package:dartchess/dartchess.dart';

/// Static exchange evaluation.
///
/// dartchess exposes no SEE, so this is the standard swap-off algorithm:
/// repeatedly take the least-valuable attacker of the target square,
/// alternating sides, then negamax the resulting material sequence back to the
/// root. X-rays are handled by recomputing sliding attacks against the reduced
/// occupancy after each capture.
///
/// The naive alternative ("captures a lower-valued piece") misfires badly on
/// defended pieces, which is the exact case the sacrifice term cares about.
class See {
  /// Centipawn values used for the swap-off only. The king is given a value
  /// large enough that using it as an attacker is never profitable, but it can
  /// still be the last recapturer.
  static const Map<Role, int> pieceValue = {
    Role.pawn: 100,
    Role.knight: 320,
    Role.bishop: 330,
    Role.rook: 500,
    Role.queen: 900,
    Role.king: 20000,
  };

  /// Net material for the side to move after the exchange sequence on
  /// [move]'s destination square plays out.
  ///
  /// A quiet move scores 0 when the destination is undefended and negative when
  /// the moved piece can be won — which is what makes it a sacrifice.
  static int evaluate(Position pos, NormalMove move) {
    final board = pos.board;
    final target = move.to;
    final movingPiece = board.pieceAt(move.from);
    if (movingPiece == null) return 0;

    final capturedPiece = board.pieceAt(target);
    // En passant: the captured pawn is not on the destination square.
    final isEnPassant = movingPiece.role == Role.pawn &&
        capturedPiece == null &&
        pos.epSquare == target;

    final gains = <int>[];
    gains.add(capturedPiece != null
        ? (pieceValue[capturedPiece.role] ?? 0)
        : (isEnPassant ? pieceValue[Role.pawn]! : 0));

    // Occupancy after the moving piece has left its origin square.
    var occupied = board.occupied.withoutSquare(move.from);
    if (isEnPassant) {
      final capturedPawnSquare = Square(
          target.value + (movingPiece.color == Side.white ? -8 : 8));
      occupied = occupied.withoutSquare(capturedPawnSquare);
    }

    // Promotion changes what sits on the square for the rest of the exchange.
    var valueOnSquare =
        pieceValue[move.promotion ?? movingPiece.role] ?? 0;
    if (move.promotion != null) {
      gains[0] += (pieceValue[move.promotion!] ?? 0) - pieceValue[Role.pawn]!;
    }

    var sideToCapture = movingPiece.color.opposite;
    var depth = 0;

    while (true) {
      final attacker =
          _leastValuableAttacker(board, target, sideToCapture, occupied);
      if (attacker == null) break;

      // A king may not capture into a square the other side still attacks, so
      // the exchange simply stops here. Without this the sequence "wins" the
      // king for 20000 and the negamax comes back with nonsense.
      if (attacker.role == Role.king) {
        final remaining = occupied.withoutSquare(attacker.square);
        if (_hasAttacker(board, target, sideToCapture.opposite, remaining)) {
          break;
        }
      }

      depth++;
      // What this side nets by capturing, given what the opponent just gained.
      gains.add(valueOnSquare - gains[depth - 1]);

      // Speculative pruning: if even winning the piece outright leaves this
      // side behind, the sequence stops here in practice.
      if (gains[depth] < 0 && gains[depth - 1] < 0) break;

      valueOnSquare = pieceValue[attacker.role] ?? 0;
      occupied = occupied.withoutSquare(attacker.square);
      sideToCapture = sideToCapture.opposite;
    }

    // Negamax the sequence back: each side stops capturing when continuing
    // would cost more than standing pat.
    for (int i = gains.length - 1; i > 0; i--) {
      if (-gains[i] < gains[i - 1]) gains[i - 1] = -gains[i];
    }
    return gains[0];
  }

  /// True when [move] gives up material by static exchange — a quiet move onto
  /// a square where the piece can be won, or a capture that loses the follow-up.
  static bool isSacrifice(Position pos, NormalMove move) =>
      evaluate(pos, move) < 0;

  static bool _hasAttacker(
    Board board,
    Square target,
    Side side,
    SquareSet occupied,
  ) =>
      _leastValuableAttacker(board, target, side, occupied) != null;

  static _Attacker? _leastValuableAttacker(
    Board board,
    Square target,
    Side side,
    SquareSet occupied,
  ) {
    _Attacker? best;
    int bestValue = 1 << 30;

    for (final role in Role.values) {
      final candidates =
          board.byRole(role) & board.bySide(side) & occupied;
      if (candidates.isEmpty) continue;
      final value = pieceValue[role] ?? 0;
      if (value >= bestValue) continue;

      for (final square in candidates.squares) {
        if (!_attacksSquare(board, square, role, side, target, occupied)) {
          continue;
        }
        best = _Attacker(square, role);
        bestValue = value;
        break;
      }
    }
    return best;
  }

  /// Whether a piece of [role] on [from] attacks [target] under [occupied].
  /// Recomputed per step so a rook behind a rook joins the exchange once the
  /// piece in front of it has been removed.
  static bool _attacksSquare(
    Board board,
    Square from,
    Role role,
    Side side,
    Square target,
    SquareSet occupied,
  ) {
    switch (role) {
      case Role.pawn:
        return pawnAttacks(side, from).has(target);
      case Role.knight:
        return knightAttacks(from).has(target);
      case Role.bishop:
        return bishopAttacks(from, occupied).has(target);
      case Role.rook:
        return rookAttacks(from, occupied).has(target);
      case Role.queen:
        return queenAttacks(from, occupied).has(target);
      case Role.king:
        return kingAttacks(from).has(target);
    }
  }
}

class _Attacker {
  final Square square;
  final Role role;
  const _Attacker(this.square, this.role);
}
