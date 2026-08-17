import 'engine_types.dart';
import 'uci_engine.dart';
import 'uci_transport.dart';

export 'engine_types.dart';
export 'uci_engine.dart' show EngineUnavailable, UciEngine, UciTransport;

/// The app's engine handle.
///
/// There is **one** implementation for every platform now. The protocol lives
/// in [UciEngine] and only the transport is platform-specific, so the two
/// implementations can no longer drift — which they had: `analyzePosition`
/// returned `Future<void>` on native and `void` on web, and `getMoveLabel`
/// differed in nullability.
///
/// Platform reality, which callers should not assume away:
/// - **Android / iOS** — Stockfish via FFI (the `stockfish` pub package).
/// - **Web** — Stockfish WebAssembly in a Web Worker, loaded lazily on first
///   use. Slower than native, so analysis depths are reduced; see
///   `docs/critical-moments.md`.
/// - **Windows / macOS / Linux** — no engine yet. [isSupported] is false and
///   the UI says so rather than failing at first search.
class EngineService {
  final UciEngine _engine;

  EngineService() : _engine = UciEngine(createUciTransport());

  /// Injects a transport — for tests and for a future desktop implementation.
  EngineService.withTransport(UciTransport transport)
      : _engine = UciEngine(transport);

  Stream<PositionEvals> get evaluationStream => _engine.evaluationStream;

  /// Whether an engine can run on this platform at all. Synchronous and cheap;
  /// on web it is true *before* the 7 MB module has been fetched.
  bool get isSupported => _engine.isSupported;

  /// Whether the engine is loaded and has finished its handshake.
  bool get isReady => _engine.isReady;

  /// Why the engine could not start, once a start has failed.
  String? get unavailableReason => _engine.unavailableReason;

  /// Loads the engine if needed. False means no analysis is possible — see
  /// [unavailableReason].
  Future<bool> ensureReady() => _engine.ensureReady();

  /// Live analysis, streaming [multiPv] lines to [evaluationStream] and
  /// stopping at [maxDepth] (null searches until stopped).
  Future<void> analyzePosition(String fen, {int multiPv = 3, int? maxDepth}) =>
      _engine.analyzePosition(fen, multiPv: multiPv, maxDepth: maxDepth);

  /// Returns null when nothing could evaluate the position — never a 0.00
  /// placeholder, which would read as dead-equal and fabricate huge swings.
  Future<EngineEvaluation?> evaluatePosition(String fen, {int depth = 12}) =>
      _engine.evaluatePosition(fen, depth: depth);

  /// Bounded MultiPV search with the best move at every completed depth.
  /// Throws [StateError] when no engine can run.
  Future<SearchResult> runSearch(String fen, {int depth = 15, int multiPv = 3}) =>
      _engine.runSearch(fen, depth: depth, multiPv: multiPv);

  void stop() => _engine.stop();

  Future<void> dispose() => _engine.dispose();
}
