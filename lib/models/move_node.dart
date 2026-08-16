import 'package:equatable/equatable.dart';
import '../services/engine_types.dart';

// ignore: must_be_immutable
class MoveNode extends Equatable {
  final String fen;
  final String san;
  final String? uci;
  double? evaluation;
  int? mate;
  MoveQuality? quality;

  /// Engine's preferred move at the parent position (UCI), i.e. what the
  /// engine wanted instead of the move actually played to reach this node.
  /// Used by the critical-moment finder to detect missed wins.
  String? bestMoveUci;

  /// Engine eval (pawns, White POV) at the parent position — the eval the
  /// mover *would have got* by playing [bestMoveUci]. Companion to the field
  /// above; together they let us compute "best vs. played" deltas.
  double? bestMoveEval;

  /// Mate-in-N (signed, White POV) the parent position would have led to via
  /// [bestMoveUci]. Null when the best line was not a forced mate.
  int? bestMoveMate;

  final List<String> comments;
  final List<int> glyphs; // NAGs
  final List<MoveNode> children;
  MoveNode? parent;

  MoveNode({
    required this.fen,
    this.san = '',
    this.uci,
    this.evaluation,
    this.mate,
    this.quality,
    this.bestMoveUci,
    this.bestMoveEval,
    this.bestMoveMate,
    List<String>? comments,
    List<int>? glyphs,
    List<MoveNode>? children,
    this.parent,
  })  : comments = comments ?? [],
        glyphs = glyphs ?? [],
        children = children ?? [];

  void addChild(MoveNode child) {
    child.parent = this;
    children.add(child);
  }

  void promoteChild(MoveNode child) {
    if (children.contains(child)) {
      children.remove(child);
      children.insert(0, child);
    }
  }

  // Promote this node all the way to the root so the full path becomes the mainline.
  void promoteToMainline() {
    MoveNode? node = this;
    while (node != null && node.parent != null) {
      node.parent!.promoteChild(node);
      node = node.parent;
    }
  }

  void removeChild(MoveNode child) {
    children.remove(child);
  }

  MoveNode? get mainlineChild => children.isNotEmpty ? children.first : null;

  /// Walk up to the root, counting half-moves to determine the full move number.
  int get moveNumber {
    int depth = 0;
    MoveNode? n = this;
    while (n?.parent != null) {
      depth++;
      n = n!.parent;
    }
    return (depth + 1) ~/ 2; // 1-indexed move number
  }

  /// Returns true if this node is a black move (even depth from root = white, odd = black).
  bool get isBlackMove {
    int depth = 0;
    MoveNode? n = this;
    while (n?.parent != null) {
      depth++;
      n = n!.parent;
    }
    return depth % 2 == 0; // depth 1 = white's first move, depth 2 = black's first, etc.
  }

  @override
  List<Object?> get props => [
        fen, san, uci, evaluation, mate, quality,
        bestMoveUci, bestMoveEval, bestMoveMate,
        comments, glyphs, children,
      ];
}

class MoveTree {
  final MoveNode root;

  MoveTree({required String initialFen}) : root = MoveNode(fen: initialFen);

  MoveTree.withRoot(this.root);

  /// Collect all mainline nodes (excluding root).
  List<MoveNode> get mainline {
    final nodes = <MoveNode>[];
    MoveNode? current = root;
    while (current != null && current.children.isNotEmpty) {
      current = current.children.first;
      nodes.add(current);
    }
    return nodes;
  }

  /// Get the last node in the mainline.
  MoveNode get lastMainlineNode {
    MoveNode current = root;
    while (current.children.isNotEmpty) {
      current = current.children.first;
    }
    return current;
  }
}
