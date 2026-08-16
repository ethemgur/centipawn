import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:stockfish/stockfish.dart';
import 'uci_engine.dart';

/// Talks to the `stockfish` pub package over its stdin/stdout FFI bridge.
///
/// **Android and iOS only.** The package declares plugin platforms for those
/// two; elsewhere it falls back to `DynamicLibrary.process()` and the symbol
/// lookup throws, which is why [isSupported] is false on desktop. Adding
/// desktop means one more `UciTransport` (a bundled binary over `Process`),
/// not any protocol work.
class NativeUciTransport implements UciTransport {
  Stockfish? _stockfish;
  final _lines = StreamController<String>.broadcast();
  StreamSubscription<String>? _stdoutSubscription;

  @override
  Stream<String> get lines => _lines.stream;

  /// Only Android and iOS ship the native library. Checking up front means the
  /// UI can say "no engine here" instead of failing at first search.
  @override
  bool get isSupported => Platform.isAndroid || Platform.isIOS;

  /// More than ~3 threads triggers thermal throttling on phones within seconds
  /// and tanks sustained NPS. Lichess Mobile uses a similar cap.
  @override
  int get threads => Platform.numberOfProcessors >= 6 ? 3 : 2;

  @override
  int get hashMb => 256;

  Completer<void>? _startCompleter;

  @override
  Future<void> start() {
    final existing = _startCompleter;
    if (existing != null) return existing.future;

    final completer = Completer<void>();
    _startCompleter = completer;

    if (!isSupported) {
      completer.completeError(const EngineUnavailable(
        'The bundled Stockfish supports Android and iOS only.',
      ));
      return completer.future;
    }

    try {
      final engine = Stockfish();
      _stockfish = engine;
      _stdoutSubscription = engine.stdout.listen(_lines.add);

      void onStateChange() {
        if (engine.state.value == StockfishState.ready &&
            !completer.isCompleted) {
          completer.complete();
        } else if (engine.state.value == StockfishState.error &&
            !completer.isCompleted) {
          completer.completeError(
              const EngineUnavailable('Stockfish failed to start.'));
        }
      }

      engine.state.addListener(onStateChange);
      _removeStateListener = () => engine.state.removeListener(onStateChange);
      // Already ready by the time we attached.
      onStateChange();
    } catch (e) {
      debugPrint('Failed to initialize Stockfish: $e');
      _stockfish = null;
      completer.completeError(EngineUnavailable('Stockfish failed to load: $e'));
    }
    return completer.future;
  }

  void Function()? _removeStateListener;

  @override
  void send(String command) {
    _stockfish?.stdin = command;
  }

  @override
  Future<void> dispose() async {
    await _stdoutSubscription?.cancel();
    _removeStateListener?.call();
    _stockfish?.dispose();
    _stockfish = null;
    await _lines.close();
  }
}

UciTransport createUciTransport() => NativeUciTransport();
