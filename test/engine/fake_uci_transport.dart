import 'dart:async';
import 'package:centipawn/services/uci_engine.dart';

/// A [UciTransport] that records what was sent and lets a test push engine
/// output back, so the whole UCI protocol can be exercised with no plugin, no
/// browser and no isolate.
class FakeUciTransport implements UciTransport {
  FakeUciTransport({
    this.isSupported = true,
    this.threads = 2,
    this.hashMb = 256,
    this.startError,
    this.autoReadyOk = true,
  });

  @override
  final bool isSupported;
  @override
  final int threads;
  @override
  final int hashMb;

  /// When set, [start] fails with this — the "engine could not load" path.
  final EngineUnavailable? startError;

  /// Answer `isready` with `readyok` automatically. Turn off to exercise the
  /// barrier timeouts.
  final bool autoReadyOk;

  /// Every command the engine sent, in order.
  final List<String> sent = [];

  final _lines = StreamController<String>.broadcast();
  @override
  Stream<String> get lines => _lines.stream;

  bool started = false;
  bool disposed = false;
  int startCalls = 0;

  @override
  Future<void> start() async {
    startCalls++;
    if (startError != null) throw startError!;
    started = true;
  }

  @override
  void send(String command) {
    sent.add(command);
    if (command == 'isready' && autoReadyOk) {
      // Answer on a later microtask, as a real engine would.
      scheduleMicrotask(() => emit('readyok'));
    }
  }

  /// Pushes one line of engine output into the protocol.
  void emit(String line) {
    if (!_lines.isClosed) _lines.add(line);
  }

  void emitAll(Iterable<String> lines) => lines.forEach(emit);

  /// Commands sent since the marker, for asserting ordering within one search.
  List<String> sentAfter(String marker) {
    final i = sent.lastIndexOf(marker);
    return i < 0 ? const [] : sent.sublist(i + 1);
  }

  void clearSent() => sent.clear();

  @override
  Future<void> dispose() async {
    disposed = true;
    await _lines.close();
  }
}

/// Lets the engine's pending microtasks (line delivery, barrier completion) run.
Future<void> settle([int rounds = 8]) async {
  for (var i = 0; i < rounds; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}
