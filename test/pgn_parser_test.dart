import 'package:flutter_test/flutter_test.dart';
import 'package:centipawn/services/pgn_parser.dart';

void main() {
  group('header stripping', () {
    test('removes tag pairs', () {
      final tree = PgnParser.parsePgn('''
[Event "Test"]
[White "A"]
[Black "B"]
[Result "1-0"]

1. e4 e5 2. Nf3 1-0
''');
      expect(tree.mainline.map((n) => n.san), ['e4', 'e5', 'Nf3']);
    });

    test('keeps bracketed annotations inside comments', () {
      // A blanket [.*?] strip also eats these, which silently destroys the
      // clock data the critical-moment time analysis runs on.
      final tree = PgnParser.parsePgn(
        '[Event "Test"]\n\n1. e4 {[%clk 0:03:00]} e5 {[%clk 0:02:58]} *',
      );
      expect(tree.mainline.first.comments.single, '[%clk 0:03:00]');
      expect(tree.mainline[1].comments.single, '[%clk 0:02:58]');
    });

    test('keeps eval and arrow annotations too', () {
      final tree = PgnParser.parsePgn(
        '1. e4 {[%eval 0.24] [%cal Ge2e4] a good move} *',
      );
      expect(tree.mainline.single.comments.single,
          '[%eval 0.24] [%cal Ge2e4] a good move');
    });

    test('a tag-like string inside a comment is not treated as a header', () {
      final tree = PgnParser.parsePgn('1. e4 {[Event "not a header"]} e5 *');
      expect(tree.mainline.map((n) => n.san), ['e4', 'e5']);
      expect(tree.mainline.first.comments.single, '[Event "not a header"]');
    });

    test('handles headers with no blank line before the movetext', () {
      final tree = PgnParser.parsePgn('[Event "Test"]\n1. e4 e5 *');
      expect(tree.mainline.map((n) => n.san), ['e4', 'e5']);
    });
  });

  group('display filtering', () {
    test('hides machine annotations but keeps the prose', () {
      expect(PgnParser.displayComment('[%clk 0:03:00] good move'), 'good move');
      expect(PgnParser.displayComment('[%eval 0.24] [%cal Ge2e4]'), '');
      expect(PgnParser.displayComment('a plain comment'), 'a plain comment');
    });

    test('drops comments that were nothing but annotations', () {
      // An imported Lichess game carries a clock on every single move; showing
      // those in the notation would bury any real annotation.
      expect(PgnParser.displayComments(['[%clk 0:03:00]']), isEmpty);
      expect(PgnParser.displayComments(['[eng]']), isEmpty);
      expect(
        PgnParser.displayComments(['[%clk 0:03:00] the point', '[eng]']),
        ['the point'],
      );
    });

    test('an imported game with clocks shows no comment noise', () {
      final tree = PgnParser.parsePgn(
        '1. e4 {[%clk 0:03:00]} e5 {[%clk 0:02:58] surprising} *',
      );
      // Raw comments survive for export and clock parsing...
      expect(tree.mainline.first.comments.single, '[%clk 0:03:00]');
      // ...but nothing is shown for the bare clock.
      expect(PgnParser.displayComments(tree.mainline.first.comments), isEmpty);
      expect(PgnParser.displayComments(tree.mainline[1].comments),
          ['surprising']);
    });
  });

  group('round trip', () {
    test('parses variations and glyphs', () {
      final tree = PgnParser.parsePgn('1. e4 e5 2. Nf3 (2. Bc4 Nc6) 2... Nc6 *');
      expect(tree.mainline.map((n) => n.san), ['e4', 'e5', 'Nf3', 'Nc6']);
      final second = tree.mainline[1];
      expect(second.children.length, 2);
      expect(second.children[1].san, 'Bc4');
    });
  });
}
