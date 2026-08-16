import 'package:dartchess/dartchess.dart';
import '../../models/move_node.dart';
import 'critical_types.dart';
import 'repertoire_matcher.dart';

/// Turns a game into the [PlyData] skeleton that Stage A fills with analysis.
///
/// Handles the clock bookkeeping: PGN records the clock *remaining after* a
/// move, so time spent is the difference against that side's previous reading,
/// plus any increment.
class PlyBuilder {
  /// Builds from a mainline of [MoveNode]s (the app's own game representation).
  ///
  /// [incrementSec] is added back when deriving time spent; pass the game's
  /// increment so a 3+2 blitz game does not read as though every move was
  /// instant.
  static List<PlyData> fromMainline(
    List<MoveNode> mainline, {
    String initialFen = kStartFen,
    int incrementSec = 0,
    RepertoireMatcher? repertoire,
  }) {
    if (mainline.isEmpty) return const [];

    Position pos;
    try {
      pos = Chess.fromSetup(Setup.parseFen(initialFen));
    } catch (_) {
      return const [];
    }

    final sanMoves = [for (final node in mainline) node.san];
    final bookFlags = repertoire?.classify(sanMoves) ??
        List<bool>.filled(sanMoves.length, false);

    final out = <PlyData>[];
    // Last clock reading seen for each side, for the time-spent difference.
    final lastClock = <Side, int?>{Side.white: null, Side.black: null};
    PreviousMove? previous;

    for (int i = 0; i < mainline.length; i++) {
      final node = mainline[i];
      final move = pos.parseSan(node.san);
      if (move is! NormalMove) break;

      final side = pos.turn;
      final clockSec = _clockSeconds(node);
      final prevClock = lastClock[side];

      double? timeSpent;
      if (clockSec != null && prevClock != null) {
        final spent = (prevClock - clockSec + incrementSec).toDouble();
        // A negative reading means the increment guess was wrong or the tag is
        // unreliable; leave it unknown rather than feed noise to the regression.
        if (spent >= 0) timeSpent = spent;
      }
      if (clockSec != null) lastClock[side] = clockSec;

      final wasCapture = pos.board.pieceAt(move.to) != null ||
          (pos.board.roleAt(move.from) == Role.pawn && pos.epSquare == move.to);

      out.add(PlyData(
        ply: i,
        moveNumber: pos.fullmoves,
        side: side,
        fenBefore: pos.fen,
        movePlayedUci: move.uci,
        movePlayedSan: node.san,
        timeSpentSec: timeSpent,
        clockRemainingSec: clockSec,
        opponentClockRemainingSec: lastClock[side.opposite],
        previousMove: previous,
        inBook: i < bookFlags.length && bookFlags[i],
      ));

      previous = PreviousMove(
        uci: move.uci,
        wasCapture: wasCapture,
        toSquare: move.to,
      );
      pos = pos.play(move);
    }
    return out;
  }

  /// Reads `[%clk H:MM:SS]` out of a node's comments.
  static int? _clockSeconds(MoveNode node) {
    for (final comment in node.comments) {
      final parsed = PgnComment.fromPgn(comment);
      final clock = parsed.clock;
      if (clock != null) return clock.inSeconds;
    }
    return null;
  }
}

const String kStartFen =
    'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';
