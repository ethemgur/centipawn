import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
// The transport itself imports package:web, which does not compile on the VM,
// so the shared asset constants are the source of truth for both.
import 'package:centipawn/services/stockfish_web_assets.dart';

/// Guards the two committed Stockfish artifacts.
///
/// They are plain files in `web/`, copied verbatim by `flutter build web` (the
/// same route `web/sqlite3.wasm` already takes). Nothing else notices if they
/// go missing — the hosting rewrite would serve `index.html` with a 200 and the
/// engine would die confusingly in production. This fails the build instead.
void main() {
  group('Stockfish web assets', () {
    test('the worker script is present and is JavaScript', () {
      final file = File('web/$kStockfishScriptName');
      expect(file.existsSync(), isTrue,
          reason: 'web/$kStockfishScriptName is missing');
      expect(file.lengthSync(), kStockfishScriptBytes);

      final head = file.readAsStringSync().substring(0, 64);
      expect(head.trimLeft().startsWith('<'), isFalse,
          reason: 'looks like HTML, not the engine glue');
      expect(head, contains('Stockfish'));
    });

    test('the wasm module is present and starts with the wasm magic', () {
      final file = File('web/$kStockfishWasmName');
      expect(file.existsSync(), isTrue,
          reason: 'web/$kStockfishWasmName is missing');
      expect(file.lengthSync(), kStockfishWasmBytes);

      final magic = file.openSync().readSync(4);
      expect(magic, kWasmMagic,
          reason: r'not a WebAssembly module (expected \0asm)');
    });

    test('the licence ships with the binary', () {
      // Stockfish is GPL-3.0 and the web build serves it to every visitor.
      expect(File('web/STOCKFISH-LICENSE.txt').existsSync(), isTrue);
    });
  });
}
