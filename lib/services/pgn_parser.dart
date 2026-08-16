import 'package:chessground/chessground.dart' show Arrow, Circle, Shape;
import 'package:dartchess/dartchess.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Color;
import '../models/game_entry.dart';
import '../models/move_node.dart';
import '../services/move_evaluator.dart';

class PgnParser {
  static const String startFen =
      'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';

  static MoveTree parsePgn(String pgn, {String initialFen = startFen}) {
    final tree = MoveTree(initialFen: initialFen);

    // Strip PGN header tags (e.g. [White "Kasparov"]) then tokenise.
    //
    // Anchored to whole lines on purpose: a blanket `\[.*?\]` also eats the
    // bracketed annotations that live *inside* comments — `[%clk 0:03:00]`,
    // `[%eval ...]`, `[%cal ...]` — which are the only record of how long a
    // move took.
    final String movetext = pgn
        .replaceAll(RegExp(r'^\s*\[\s*\w+\s+"[^"]*"\s*\]\s*$', multiLine: true), '')
        .trim();
    final tokens = _tokenize(movetext);

    MoveNode currentNode = tree.root;

    // dartchess positions are immutable — no need to clone for variations,
    // just save and restore the reference.
    Position pos = Chess.fromSetup(Setup.parseFen(initialFen));
    final List<MoveNode> savedNodes = [];
    final List<Position> savedPositions = [];

    const glyphMap = {
      '!!': 3,
      '??': 4,
      '!?': 5,
      '?!': 6,
      '!': 1,
      '?': 2,
    };

    for (int i = 0; i < tokens.length; i++) {
      final String token = tokens[i].trim();
      if (token.isEmpty) continue;

      if (token == '(') {
        savedNodes.add(currentNode);
        savedPositions.add(pos);

        if (currentNode.parent != null) {
          currentNode = currentNode.parent!;
          pos = Chess.fromSetup(Setup.parseFen(currentNode.fen));
        } else {
          currentNode = tree.root;
          pos = Chess.fromSetup(Setup.parseFen(tree.root.fen));
        }
      } else if (token == ')') {
        if (savedNodes.isNotEmpty) {
          currentNode = savedNodes.removeLast();
          pos = savedPositions.removeLast();
        }
      } else if (token.startsWith('{') && token.endsWith('}')) {
        currentNode.comments.add(token.substring(1, token.length - 1).trim());
      } else if (token.startsWith('\$')) {
        final nag = int.tryParse(token.substring(1));
        if (nag != null) currentNode.glyphs.add(nag);
      } else if (RegExp(r'^[0-9]+\.+$').hasMatch(token)) {
        // Move-number token like "1." or "3..." — skip.
      } else if (['1-0', '0-1', '1/2-1/2', '*'].contains(token)) {
        // Game result — skip.
      } else {
        // It's a move. Strip any trailing annotation glyph symbol first.
        String cleanMove = token;
        int? moveGlyph;
        for (final entry in glyphMap.entries) {
          if (token.endsWith(entry.key)) {
            cleanMove = token.substring(0, token.length - entry.key.length);
            moveGlyph = entry.value;
            break;
          }
        }

        final Move? move = pos.parseSan(cleanMove);
        if (move != null) {
          final (newPos, san) = pos.makeSan(move);
          pos = newPos;

          String? uci;
          if (move is NormalMove) {
            final promoStr = move.promotion == null ? '' : switch (move.promotion!) {
              Role.queen => 'q',
              Role.rook => 'r',
              Role.bishop => 'b',
              Role.knight => 'n',
              _ => '',
            };
            uci = '${move.from.name}${move.to.name}$promoStr';
          }
          final newNode = MoveNode(fen: pos.fen, san: san, uci: uci);
          if (moveGlyph != null) newNode.glyphs.add(moveGlyph);
          currentNode.addChild(newNode);
          currentNode = newNode;
        } else {
          debugPrint('PGN Parse Warning: could not parse "$cleanMove" at ${pos.fen}');
        }
      }
    }

    return tree;
  }

  /// Extracts PGN header tag values (e.g. [White "Kasparov"]) into a map.
  static Map<String, String> parseHeaders(String pgn) {
    final headers = <String, String>{};
    final re = RegExp(r'\[(\w+)\s+"([^"]*)"\]');
    for (final m in re.allMatches(pgn)) {
      headers[m.group(1)!] = m.group(2)!;
    }
    return headers;
  }

  /// Classifies a PGN TimeControl string to Bullet / Blitz / Rapid / Classical.
  static String? classifyTimeControl(String? tc) {
    if (tc == null || tc.isEmpty || tc == '-' || tc == '?') return null;
    int? seconds;
    if (tc.contains('/')) {
      seconds = int.tryParse(tc.split('/').last);
    } else if (tc.contains('+')) {
      seconds = int.tryParse(tc.split('+').first);
    } else {
      seconds = int.tryParse(tc);
    }
    if (seconds == null) return null;
    if (seconds < 180) return 'Bullet';
    if (seconds < 600) return 'Blitz';
    if (seconds < 1800) return 'Rapid';
    return 'Classical';
  }

  /// Exports the full move tree (mainline + variations + comments + NAGs)
  /// as PGN movetext without headers. Pass [shapes] (FEN → shapes) to include
  /// CSL/CAL board-annotation comments.
  static String exportMovetext(
    MoveTree tree, {
    Map<String, List<Shape>>? shapes,
  }) {
    final sb = StringBuffer();
    _exportNode(tree.root, sb, false, shapes);
    return sb.toString().trim();
  }

  /// Exports just the mainline of [tree] as a plain move-list string.
  static String exportMainline(MoveTree tree) {
    final mainline = tree.mainline;
    if (mainline.isEmpty) return '';
    final buffer = StringBuffer();
    for (int i = 0; i < mainline.length; i++) {
      final node = mainline[i];
      if (!node.isBlackMove) buffer.write('${node.moveNumber}. ');
      buffer.write('${node.san} ');
    }
    return buffer.toString().trim();
  }

  /// Exports a full PGN with the seven-tag roster plus any optional metadata
  /// drawn from [game] (Elos, time control, accuracies, etc.). The tree's
  /// game result wins over the row's result if both are set.
  ///
  /// When [clean] is true, variations, comments, NAGs, and the Annotator tag
  /// are omitted — only the mainline moves are exported.
  static String exportPgn(
    MoveTree tree, {
    GameEntry? game,
    bool clean = false,
    Map<String, List<Shape>>? shapes,
  }) {
    final sb = StringBuffer();
    final headers = <String, String>{
      'Event': game?.event.isNotEmpty == true ? game!.event : 'Centipawn Game',
      'Site': game?.site.isNotEmpty == true ? game!.site : 'Centipawn',
      'Date': game?.date.isNotEmpty == true
          ? game!.date
          : DateTime.now().toIso8601String().substring(0, 10).replaceAll('-', '.'),
      'Round': game?.round.isNotEmpty == true ? game!.round : '-',
      'White': game?.white.isNotEmpty == true ? game!.white : 'White',
      'Black': game?.black.isNotEmpty == true ? game!.black : 'Black',
      'Result': game?.result.isNotEmpty == true ? game!.result : '*',
    };
    if (game != null) {
      if (game.whiteElo.isNotEmpty) headers['WhiteElo'] = game.whiteElo;
      if (game.blackElo.isNotEmpty) headers['BlackElo'] = game.blackElo;
      if (game.timeControl.isNotEmpty) headers['TimeControl'] = game.timeControl;
      if (game.openingCode.isNotEmpty) {
        final parts = game.openingCode.split(': ');
        headers['ECO'] = parts[0];
        if (parts.length > 1) headers['Opening'] = parts.sublist(1).join(': ');
      }
    }

    for (final entry in headers.entries) {
      sb.writeln('[${entry.key} "${entry.value.replaceAll('"', r'\"')}"]');
    }
    sb.writeln();
    sb.write(clean ? exportMainline(tree) : exportMovetext(tree, shapes: shapes));
    sb.write(' ${headers['Result']}');
    return sb.toString().trim();
  }

  // ---------------------------------------------------------------------------
  // Internal helpers
  // ---------------------------------------------------------------------------

  static List<String> _tokenize(String text) {
    final List<String> tokens = [];
    final StringBuffer current = StringBuffer();
    bool inComment = false;

    for (int i = 0; i < text.length; i++) {
      final char = text[i];
      if (char == '{') {
        if (current.isNotEmpty && !inComment) {
          tokens.add(current.toString());
          current.clear();
        }
        inComment = true;
        current.write(char);
      } else if (char == '}') {
        current.write(char);
        tokens.add(current.toString());
        current.clear();
        inComment = false;
      } else if (inComment) {
        current.write(char);
      } else if (char == '(' || char == ')') {
        if (current.isNotEmpty) {
          tokens.add(current.toString());
          current.clear();
        }
        tokens.add(char);
      } else if (char == '.') {
        current.write(char);
        if (i + 1 < text.length && text[i + 1] != '.') {
          tokens.add(current.toString());
          current.clear();
        }
      } else if (RegExp(r'\s').hasMatch(char)) {
        if (current.isNotEmpty) {
          tokens.add(current.toString());
          current.clear();
        }
      } else {
        current.write(char);
      }
    }
    if (current.isNotEmpty) tokens.add(current.toString());
    return tokens;
  }

  static String _colorToPgnLetter(Color color) {
    final r = color.r, g = color.g, b = color.b;
    if (r > 0.7 && g > 0.7 && b < 0.4) return 'Y'; // yellow
    if (r > 0.6 && g < 0.4 && b < 0.4) return 'R'; // red
    if (r < 0.4 && g > 0.5 && b < 0.5) return 'G'; // green
    if (r < 0.4 && g < 0.6 && b > 0.6) return 'B'; // blue
    return 'G';
  }

  static String? _shapesToComment(List<Shape> nodeShapes) {
    if (nodeShapes.isEmpty) return null;
    final circles = nodeShapes.whereType<Circle>().toList();
    final arrows = nodeShapes.whereType<Arrow>().toList();
    final parts = <String>[];
    if (circles.isNotEmpty) {
      parts.add(
        '[%csl ${circles.map((c) => '${_colorToPgnLetter(c.color)}${c.orig.name}').join(',')}]',
      );
    }
    if (arrows.isNotEmpty) {
      parts.add(
        '[%cal ${arrows.map((a) => '${_colorToPgnLetter(a.color)}${a.orig.name}${a.dest.name}').join(',')}]',
      );
    }
    return parts.isEmpty ? null : parts.join('');
  }

  static int? _qualityToNag(MoveQuality? quality) {
    switch (quality) {
      case MoveQuality.best: return 3;
      case MoveQuality.excellent: return 1;
      case MoveQuality.inaccuracy: return 6;
      case MoveQuality.mistake: return 2;
      case MoveQuality.blunder: return 4;
      default: return null;
    }
  }

  static void _exportNode(
    MoveNode node,
    StringBuffer sb,
    bool needsMoveNumber,
    Map<String, List<Shape>>? shapes,
  ) {
    if (node.children.isEmpty) return;

    final mainChild = node.children.first;
    final variations = node.children.skip(1).toList();

    final isWhite = !mainChild.isBlackMove;
    if (isWhite) {
      sb.write('${mainChild.moveNumber}. ');
    } else if (needsMoveNumber) {
      sb.write('${mainChild.moveNumber}... ');
    }
    sb.write('${mainChild.san} ');
    final glyph = mainChild.glyphs.isNotEmpty
        ? mainChild.glyphs.last
        : _qualityToNag(mainChild.quality);
    if (glyph != null) sb.write('\$$glyph ');

    final shapeAnnotation = _shapesToComment(shapes?[mainChild.fen] ?? []);
    final visibleComments =
        mainChild.comments.where((c) => c != '[eng]').toList();
    final commentParts = [
      ?shapeAnnotation,
      ...visibleComments,
    ];
    if (commentParts.isNotEmpty) {
      sb.write('{${commentParts.join(' ')}} ');
    }

    for (final variation in variations) {
      _writeVariation(variation, sb, shapes);
    }

    final needsNumNext = variations.isNotEmpty ||
        (commentParts.isNotEmpty && !mainChild.isBlackMove);
    _exportNode(mainChild, sb, needsNumNext, shapes);
  }

  static void _writeVariation(
    MoveNode node,
    StringBuffer sb,
    Map<String, List<Shape>>? shapes,
  ) {
    sb.write('( ');
    final isWhite = !node.isBlackMove;
    if (isWhite) {
      sb.write('${node.moveNumber}. ');
    } else {
      sb.write('${node.moveNumber}... ');
    }
    sb.write('${node.san} ');
    final glyph = node.glyphs.isNotEmpty
        ? node.glyphs.last
        : _qualityToNag(node.quality);
    if (glyph != null) sb.write('\$$glyph ');

    final shapeAnnotation = _shapesToComment(shapes?[node.fen] ?? []);
    final visibleComments = node.comments.where((c) => c != '[eng]').toList();
    final commentParts = [
      ?shapeAnnotation,
      ...visibleComments,
    ];
    if (commentParts.isNotEmpty) {
      sb.write('{${commentParts.join(' ')}} ');
    }
    _exportNode(
      node,
      sb,
      commentParts.isNotEmpty && !node.isBlackMove,
      shapes,
    );
    sb.write(') ');
  }
}
