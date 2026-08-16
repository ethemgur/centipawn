import 'dart:async';
import 'dart:js_interop';
import 'package:flutter/foundation.dart';
import 'package:web/web.dart' as web;
import 'stockfish_web_assets.dart';
import 'uci_engine.dart';

/// Runs Stockfish as a WebAssembly module inside a Web Worker.
///
/// Uses `stockfish-18-lite-single` — the single-threaded lite build. That
/// choice is what keeps this simple: multi-threaded Stockfish needs
/// `SharedArrayBuffer`, which needs cross-origin isolation, which would break
/// CanvasKit loading from gstatic and sever popup OAuth via `COOP: same-origin`.
/// Single-threaded needs no response headers at all.
///
/// **It must be a Worker.** A depth-20 search on the main thread freezes the UI
/// for its whole duration. (Note `database_factory_setup_web.dart` deliberately
/// runs sqlite on the main thread — that tradeoff does not transfer here.)
///
/// This is the only JS interop in the app, so it is written for a reader who
/// has not met `dart:js_interop` before.
class WebUciTransport implements UciTransport {
  web.Worker? _worker;
  final _lines = StreamController<String>.broadcast();

  @override
  Stream<String> get lines => _lines.stream;

  /// Every browser we target can run the wasm build.
  @override
  bool get isSupported => true;

  /// The single-threaded build ignores this; sent anyway so the handshake is
  /// identical across transports.
  @override
  int get threads => 1;

  /// Far below native's 256 MB. The wasm heap is bounded, and mobile Safari is
  /// aggressive about killing tabs that grow it. Plenty for the reduced depths
  /// the web build searches at.
  @override
  int get hashMb => 32;

  Completer<void>? _startCompleter;

  /// Resolves an asset against `<base href>` rather than the current URL.
  ///
  /// `Uri.base` is the *document* URL, so from a deep link like `/game/42` it
  /// would resolve to `/game/stockfish-…js` — which Firebase's SPA rewrite
  /// answers with index.html at HTTP 200, producing a baffling failure.
  /// `document.baseURI` honours the `<base href>` the build stamps in.
  Uri _assetUrl(String name) {
    final base = web.document.baseURI;
    return Uri.parse(base).resolve(name);
  }

  @override
  Future<void> start() {
    final existing = _startCompleter;
    if (existing != null) return existing.future;

    final completer = Completer<void>();
    _startCompleter = completer;
    _start(completer);
    return completer.future;
  }

  Future<void> _start(Completer<void> completer) async {
    try {
      // Probe the wasm before spawning the worker. If it is missing, the SPA
      // rewrite serves index.html with a 200 and the failure would otherwise
      // surface as an unhandled rejection *inside* the worker, where nothing
      // can report it.
      await _verifyWasmAsset();

      final worker = web.Worker(_assetUrl(kStockfishScriptName).toString().toJS);
      _worker = worker;

      worker.onmessage = ((web.MessageEvent event) {
        final data = event.data;
        // The glue also posts non-string objects (progress, module chatter).
        // An unguarded cast would throw inside an event callback, where the
        // error is unreportable.
        if (data.isA<JSString>()) {
          _lines.add((data as JSString).toDart);
        }
      }).toJS;

      worker.onerror = ((web.Event event) {
        _failStart(
          completer,
          'The Stockfish worker script failed to load. Check that '
          '$kStockfishScriptName is present in web/.',
        );
      }).toJS;

      if (!completer.isCompleted) completer.complete();
    } on EngineUnavailable catch (e) {
      _failStart(completer, e.reason);
    } catch (e) {
      _failStart(completer, 'Stockfish failed to start: $e');
    }
  }

  void _failStart(Completer<void> completer, String reason) {
    debugPrint('[Engine/web] $reason');
    if (!completer.isCompleted) {
      completer.completeError(EngineUnavailable(reason));
    }
  }

  /// Fetches the first bytes of the wasm and checks the module magic.
  ///
  /// Costs one request that the HTTP cache and the Flutter service worker both
  /// satisfy for the worker's own fetch moments later.
  Future<void> _verifyWasmAsset() async {
    final url = _assetUrl(kStockfishWasmName).toString();
    final web.Response response;
    try {
      response = await web.window.fetch(url.toJS).toDart;
    } catch (e) {
      throw EngineUnavailable('Could not fetch the Stockfish engine: $e');
    }
    if (!response.ok) {
      throw EngineUnavailable(
          'Could not fetch the Stockfish engine (HTTP ${response.status}).');
    }

    final buffer = await response.arrayBuffer().toDart;
    final bytes = Uint8List.view(buffer.toDart);
    if (bytes.length < 4 ||
        bytes[0] != kWasmMagic[0] ||
        bytes[1] != kWasmMagic[1] ||
        bytes[2] != kWasmMagic[2] ||
        bytes[3] != kWasmMagic[3]) {
      final contentType = response.headers.get('content-type') ?? 'unknown';
      throw EngineUnavailable(
        'The Stockfish engine file is not a WebAssembly module '
        '(served as "$contentType"). The hosting rewrite probably returned '
        'index.html — check that $kStockfishWasmName is present in web/.',
      );
    }
  }

  @override
  void send(String command) {
    _worker?.postMessage(command.toJS);
  }

  @override
  Future<void> dispose() async {
    _worker?.terminate();
    _worker = null;
    await _lines.close();
  }
}

UciTransport createUciTransport() => WebUciTransport();
