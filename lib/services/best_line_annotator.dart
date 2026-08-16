import 'package:dartchess/dartchess.dart';
import '../models/move_node.dart';

class BestLineAnnotator {
  static const int _maxPvDepth = 5;

  // Internal marker so re-reviews can replace the previous engine variation.
  static const String _marker = '[eng]';

  /// Builds a best-line variation from [pv] starting at [parentNode.fen] and
  /// attaches it as a sibling of [playedNode]. Any existing engine-generated
  /// variation on [parentNode] is replaced first.
  static MoveNode? buildAndAttach({
    required MoveNode parentNode,
    required MoveNode playedNode,
    required List<String> pv,
  }) {
    if (pv.isEmpty) return null;

    // Remove any previously attached engine variation so re-reviews are clean.
    parentNode.children
        .removeWhere((c) => c.comments.contains(_marker));

    Position pos;
    try {
      pos = Chess.fromSetup(Setup.parseFen(parentNode.fen));
    } catch (_) {
      return null;
    }

    MoveNode? head;
    MoveNode? tail;
    final limit = pv.length < _maxPvDepth ? pv.length : _maxPvDepth;

    for (int i = 0; i < limit; i++) {
      final uci = pv[i];
      if (uci.length < 4) break;

      final from = Square.fromName(uci.substring(0, 2));
      final to = Square.fromName(uci.substring(2, 4));
      Role? promo;
      if (uci.length >= 5) {
        promo = switch (uci[4]) {
          'q' => Role.queen,
          'r' => Role.rook,
          'b' => Role.bishop,
          'n' => Role.knight,
          _ => null,
        };
      }

      final move = NormalMove(from: from, to: to, promotion: promo);
      if (!pos.isLegal(move)) break;

      final (newPos, san) = pos.makeSan(move);
      final node = MoveNode(
        fen: newPos.fen,
        san: san,
        uci: uci,
        comments: i == 0 ? [_marker] : [],
      );

      if (head == null) {
        head = node;
        tail = node;
      } else {
        tail!.addChild(node);
        tail = node;
      }

      pos = newPos;
    }

    if (head != null) {
      parentNode.addChild(head);
    }
    return head;
  }
}
