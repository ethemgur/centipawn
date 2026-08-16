import 'package:dartchess/dartchess.dart';
import '../opening_service.dart';

/// Matches game prefixes against the user's own repertoire.
///
/// Deliberately not a fixed ply cutoff: departure ply varies enormously — a
/// Caro-Kann Advance can be book to move 15, a sideline can leave book at move
/// 4. Built as a reusable object rather than an inline boolean because the
/// repertoire-defection feature needs the departure ply too.
class RepertoireMatcher {
  final _TrieNode _root = _TrieNode();

  /// True when nothing was loaded and the ECO fallback is in use, so validation
  /// can account for the weaker signal.
  bool get usingFallback => _lineCount == 0;

  int _lineCount = 0;
  int get lineCount => _lineCount;

  RepertoireMatcher();

  /// Builds a matcher from PGN text containing one or more repertoire lines.
  /// Variations are included — a repertoire is a tree, not a list of games.
  factory RepertoireMatcher.fromPgn(String pgnText) {
    final matcher = RepertoireMatcher();
    for (final game in _splitGames(pgnText)) {
      matcher._addPgnGame(game);
    }
    return matcher;
  }

  /// Adds one line given as SAN moves from the start position.
  void addLine(List<String> sanMoves) {
    var node = _root;
    for (final san in sanMoves) {
      node = node.children.putIfAbsent(san, _TrieNode.new);
    }
    node.terminal = true;
    _lineCount++;
  }

  /// The ply at which [sanMoves] leaves the repertoire, or `sanMoves.length`
  /// when the whole line stays in book.
  ///
  /// This is the value the defection feature wants; [isInBook] is the thin
  /// wrapper over it.
  int departurePly(List<String> sanMoves) {
    if (usingFallback) return _fallbackDeparturePly(sanMoves);

    var node = _root;
    for (int i = 0; i < sanMoves.length; i++) {
      final next = node.children[sanMoves[i]];
      if (next == null) return i;
      node = next;
    }
    return sanMoves.length;
  }

  /// True when the move at [plyIndex] is still inside the repertoire.
  bool isInBook(List<String> sanMoves, int plyIndex) =>
      plyIndex < departurePly(sanMoves);

  /// Marks `inBook` for every ply of a game in one pass.
  List<bool> classify(List<String> sanMoves) {
    final departure = departurePly(sanMoves);
    return [for (int i = 0; i < sanMoves.length; i++) i < departure];
  }

  /// Fallback when no repertoire file is loaded: treat the longest prefix that
  /// still matches a known ECO opening as book. Much weaker than a real
  /// repertoire — callers should surface `usingFallback` in gate attribution.
  int _fallbackDeparturePly(List<String> sanMoves) =>
      OpeningService.longestBookPrefix(sanMoves);

  void _addPgnGame(String pgn) {
    final movetext = pgn.replaceAll(RegExp(r'\[[^\]]*\]'), '');
    final moves = _mainlineSan(movetext);
    if (moves.isNotEmpty) addLine(moves);
  }

  /// Extracts the mainline SAN tokens, validating each against a real position
  /// so malformed input cannot poison the trie.
  static List<String> _mainlineSan(String movetext) {
    final cleaned = movetext
        .replaceAll(RegExp(r'\{[^}]*\}'), ' ')
        .replaceAll(RegExp(r'\([^)]*\)'), ' ')
        .replaceAll(RegExp(r'\$\d+'), ' ');

    var pos = Chess.initial as Position;
    final out = <String>[];
    for (final raw in cleaned.split(RegExp(r'\s+'))) {
      final token = raw.trim();
      if (token.isEmpty) continue;
      if (RegExp(r'^\d+\.+$').hasMatch(token)) continue;
      if (const ['1-0', '0-1', '1/2-1/2', '*'].contains(token)) continue;

      final san = token.replaceAll(RegExp(r'[!?]+$'), '');
      final move = pos.parseSan(san);
      if (move == null) break;
      final (next, normalised) = pos.makeSan(move);
      out.add(normalised);
      pos = next;
    }
    return out;
  }

  static Iterable<String> _splitGames(String pgnText) sync* {
    final chunks = pgnText.split(RegExp(r'\n\s*\n(?=\s*\[)'));
    for (final chunk in chunks) {
      if (chunk.trim().isNotEmpty) yield chunk;
    }
  }
}

class _TrieNode {
  final Map<String, _TrieNode> children = {};
  bool terminal = false;
}
