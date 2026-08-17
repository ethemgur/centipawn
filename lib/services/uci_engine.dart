import 'dart:async';
import 'package:dartchess/dartchess.dart';
import 'package:flutter/foundation.dart';
import 'engine_types.dart';

/// Thrown when an engine cannot be started on this platform, carrying a reason
/// fit to show a user.
///
/// Distinct from "this platform has no engine at all" ([UciTransport.isSupported]):
/// this is a real engine that failed to load — a missing asset, a blocked
/// worker, an out-of-memory instantiate.
class EngineUnavailable implements Exception {
  final String reason;
  const EngineUnavailable(this.reason);

  @override
  String toString() => reason;
}

/// A duplex line channel to a UCI engine process, worker, or binary.
///
/// This is the *only* platform-specific surface of the engine layer. Everything
/// about the UCI protocol itself lives in [UciEngine], so a new platform costs
/// one transport and no protocol code.
abstract class UciTransport {
  /// Whether this platform can run an engine at all. Cheap and synchronous —
  /// must not fetch or spawn anything.
  bool get isSupported;

  /// Idempotent lazy start. Resolves once the channel accepts commands.
  ///
  /// Throws [EngineUnavailable] on failure, and the failure is sticky: a second
  /// call returns the same error rather than retrying an expensive load.
  Future<void> start();

  /// Sends one UCI command (no trailing newline).
  void send(String command);

  /// Inbound engine output, one UCI line per event.
  Stream<String> get lines;

  /// Search threads to request. The web build is single-threaded and ignores
  /// this, but sending it keeps the handshake identical across transports.
  int get threads;

  /// Transposition table size in MB. Much smaller on web, where the wasm heap
  /// is bounded and mobile Safari kills tabs that grow it aggressively.
  int get hashMb;

  Future<void> dispose();
}

/// The UCI protocol, independent of how bytes reach the engine.
///
/// Extracted from what used to be two copies of this logic (one per platform).
/// Every guard here exists because it was a bug once:
///
/// - the search-generation check drops the tail Stockfish flushes after `stop`,
///   which would otherwise show the previous position's eval;
/// - the `readyok` barrier drains a prior search before starting the next;
/// - `_expectingBestmove` distinguishes the `bestmove` from `go depth` from the
///   one `stop` emits;
/// - `upperbound`/`lowerbound` lines are skipped in the MultiPV path because
///   they are unresolved fail-soft scores that read as the engine changing its
///   mind, which corrupts depth-to-settle.
///
/// **Two score units, deliberately.** [EngineEvaluation.scoreCp] is in **pawns**
/// (the streaming path divides by 100) because that is what the eval bar and
/// `combinedEvalProvider` consume. [PvLine.scoreCp] is in **raw centipawns**
/// because `PvLine.normalisedCp` folds mate onto a centipawn scale. Do not
/// "unify" these without changing every consumer; `test/engine/uci_engine_test.dart`
/// pins both.
class UciEngine {
  final UciTransport transport;

  UciEngine(this.transport);

  final _evaluationController = StreamController<PositionEvals>.broadcast();
  StreamSubscription<String>? _lineSubscription;

  Stream<PositionEvals> get evaluationStream => _evaluationController.stream;

  /// Whether an engine could run here. Known synchronously, before any load.
  bool get isSupported => transport.isSupported;

  /// Whether the engine is loaded and has completed its handshake.
  bool get isReady => _handshakeDone;

  /// Why the engine could not be started, once a start has failed.
  String? get unavailableReason => _unavailableReason;

  bool _handshakeDone = false;
  String? _unavailableReason;
  Completer<bool>? _initCompleter;
  bool _disposed = false;

  // ── Streaming analysis state ──────────────────────────────────────────────
  final Map<int, EngineEvaluation> _currentEvals = {};
  Completer<void>? _readyCompleter;
  // Bumped on each analyzePosition call. Info lines whose generation does not
  // match _activeSearchGeneration are tail output from a prior search and are
  // dropped.
  int _searchGeneration = 0;
  int _activeSearchGeneration = 0;
  // FEN of the search whose info lines are currently being accepted. Emitted
  // with every batch so consumers can tell which position an eval describes.
  String _analyzingFen = '';

  // ── Depth-limited search state ────────────────────────────────────────────
  Completer<EngineEvaluation?>? _depthSearchCompleter;
  EngineEvaluation? _lastDepthEval;
  bool _expectingBestmove = false;

  // ── MultiPV analysis search (runSearch) ───────────────────────────────────
  Completer<SearchResult>? _multiPvCompleter;
  final Map<int, PvLine> _multiPvLines = {};
  final Map<int, String> _multiPvBestByDepth = {};
  int _multiPvMaxDepth = 0;

  /// Serialises runSearch calls — a game sweep issues hundreds back to back and
  /// one engine answers one search at a time.
  Future<void> _searchQueue = Future<void>.value();

  /// Upper bound on a single [runSearch]. Depth 28 on a phone is seconds, not
  /// minutes; anything past this is a stuck engine, not a slow one.
  static const Duration searchTimeout = Duration(seconds: 90);

  /// Time allowed for the engine to load and answer the initial handshake.
  /// Generous: instantiating a 7 MB wasm module on a cold mobile browser is
  /// slow. This is the backstop that catches failure modes nothing else does.
  static const Duration handshakeTimeout = Duration(seconds: 20);

  /// Loads the engine if needed and completes the UCI handshake.
  ///
  /// Returns false when no engine can run here — check [unavailableReason] for
  /// why. Concurrent callers share one load rather than racing.
  Future<bool> ensureReady() {
    if (_handshakeDone) return Future.value(true);
    if (!transport.isSupported) {
      _unavailableReason ??= 'No chess engine is available on this platform.';
      return Future.value(false);
    }
    final existing = _initCompleter;
    if (existing != null) return existing.future;

    final completer = Completer<bool>();
    _initCompleter = completer;
    _initialise().then(
      (ok) => completer.complete(ok),
      onError: (Object e) {
        _unavailableReason = e is EngineUnavailable ? e.reason : '$e';
        completer.complete(false);
      },
    );
    return completer.future;
  }

  Future<bool> _initialise() async {
    await transport.start();
    _lineSubscription = transport.lines.listen(handleLine);

    send('uci');
    // On phones, more than ~3 threads triggers thermal throttling within
    // seconds and tanks sustained NPS. The transport picks the number.
    send('setoption name Threads value ${transport.threads}');
    send('setoption name Hash value ${transport.hashMb}');
    send('setoption name MultiPV value 3');
    send('ucinewgame');

    _readyCompleter = Completer<void>();
    send('isready');
    var timedOut = false;
    await _readyCompleter!.future.timeout(
      handshakeTimeout,
      onTimeout: () {
        timedOut = true;
        _readyCompleter = null;
      },
    );
    if (timedOut) {
      throw const EngineUnavailable(
        'The chess engine did not respond to the initial handshake. '
        'It may have failed to load.',
      );
    }
    _handshakeDone = true;
    return true;
  }

  @visibleForTesting
  void send(String command) => transport.send(command);

  /// Feeds one line of engine output through the protocol. Public for tests.
  @visibleForTesting
  void handleLine(String line) {
    final trimmed = line.trim();
    if (trimmed == 'readyok') {
      _readyCompleter?.complete();
      _readyCompleter = null;
      return;
    }
    if (_multiPvCompleter != null) {
      _handleMultiPvOutput(line);
      return;
    }
    // When a depth-limited search finishes, the engine outputs "bestmove ...".
    // Only complete if we sent "go depth" — ignores the bestmove from `stop`.
    if (line.startsWith('bestmove')) {
      if (_expectingBestmove &&
          _depthSearchCompleter != null &&
          !_depthSearchCompleter!.isCompleted) {
        _expectingBestmove = false;
        // No info line seen means nothing evaluated this position. Null, never
        // 0.00 — a fabricated dead-equal score produces huge phantom swings.
        _depthSearchCompleter!.complete(_lastDepthEval);
        _depthSearchCompleter = null;
        _lastDepthEval = null;
      }
      return;
    }

    if (line.startsWith('info') && line.contains('score')) {
      final parts = line.split(' ');

      int pvIndex = 1;
      double cp = 0.0;
      int? mate;
      List<String> pv = [];
      int depth = 0;

      for (int i = 0; i < parts.length; i++) {
        if (parts[i] == 'depth') {
          depth = int.tryParse(parts[i + 1]) ?? 0;
        }
        if (parts[i] == 'multipv') {
          pvIndex = int.tryParse(parts[i + 1]) ?? 1;
        }
        if (parts[i] == 'score') {
          if (parts[i + 1] == 'cp') {
            // Pawns — see the class doc on the two score units.
            cp = (int.tryParse(parts[i + 2]) ?? 0) / 100.0;
          } else if (parts[i + 1] == 'mate') {
            mate = int.tryParse(parts[i + 2]);
          }
        }
        if (parts[i] == 'pv') {
          pv = parts.sublist(i + 1);
          break;
        }
      }

      final eval =
          EngineEvaluation(scoreCp: cp, mate: mate, pv: pv, depth: depth);

      // If we're in a depth-limited search, just track the latest eval.
      if (_depthSearchCompleter != null) {
        _lastDepthEval = eval;
        return;
      }

      // Drop info lines that belong to a search we've since cancelled — these
      // arrive between `stop` and the new `go` and would otherwise be shown
      // as the current position's eval.
      if (_searchGeneration != _activeSearchGeneration) {
        return;
      }

      _currentEvals[pvIndex] = eval;

      final sortedKeys = _currentEvals.keys.toList()..sort();
      final evals = sortedKeys.map((k) => _currentEvals[k]!).toList();
      _evaluationController.add(PositionEvals(_analyzingFen, evals));
    }
  }

  /// Accumulates one search's `info` lines into [_multiPvLines] and
  /// [_multiPvBestByDepth], completing the pending future on `bestmove`.
  void _handleMultiPvOutput(String line) {
    if (line.startsWith('bestmove')) {
      final completer = _multiPvCompleter;
      _multiPvCompleter = null;
      if (completer != null && !completer.isCompleted) {
        final indices = _multiPvLines.keys.toList()..sort();
        completer.complete(SearchResult(
          fen: _analyzingFen,
          depth: _multiPvMaxDepth,
          pvs: [for (final i in indices) _multiPvLines[i]!],
          // Filled in by runSearch, which has the position parsed.
          legalMoveCount: 0,
          inCheck: false,
          bestByDepth: Map<int, String>.from(_multiPvBestByDepth),
        ));
      }
      return;
    }

    if (!line.startsWith('info') || !line.contains(' score ')) return;
    // Fail-soft/fail-high lines carry a bound, not a resolved score. Letting
    // them into bestByDepth makes the engine look like it changed its mind
    // mid-iteration and inflates depth-to-settle.
    if (line.contains('upperbound') || line.contains('lowerbound')) return;

    final parts = line.split(' ');
    int depth = 0;
    int pvIndex = 1;
    int scoreCp = 0;
    int? mateIn;
    List<String> pv = const [];

    for (int i = 0; i < parts.length - 1; i++) {
      switch (parts[i]) {
        case 'depth':
          depth = int.tryParse(parts[i + 1]) ?? 0;
        case 'multipv':
          pvIndex = int.tryParse(parts[i + 1]) ?? 1;
        case 'score':
          if (parts[i + 1] == 'cp' && i + 2 < parts.length) {
            // Raw centipawns — see the class doc on the two score units.
            scoreCp = int.tryParse(parts[i + 2]) ?? 0;
          } else if (parts[i + 1] == 'mate' && i + 2 < parts.length) {
            mateIn = int.tryParse(parts[i + 2]);
          }
        case 'pv':
          pv = parts.sublist(i + 1);
      }
      if (parts[i] == 'pv') break;
    }

    if (pv.isEmpty) return;
    if (depth > _multiPvMaxDepth) _multiPvMaxDepth = depth;

    _multiPvLines[pvIndex] =
        PvLine(movesUci: pv, scoreCp: scoreCp, mateIn: mateIn);

    // Only the top line defines "what the engine currently thinks is best".
    if (pvIndex == 1 && depth > 0) _multiPvBestByDepth[depth] = pv.first;
  }

  /// Runs one bounded MultiPV search and returns everything it produced,
  /// including the best move at every completed depth.
  ///
  /// Calls are serialised: one engine answers one search at a time, so a caller
  /// sweeping a whole game can simply await these in a loop.
  /// Throws [StateError] when no engine can run — check [isSupported] first
  /// rather than treating a returned score as analysis.
  Future<SearchResult> runSearch(
    String fen, {
    int depth = 15,
    int multiPv = 3,
  }) {
    final result = _searchQueue.then((_) => _runSearchLocked(
          fen,
          depth: depth,
          multiPv: multiPv,
        ));
    // Keep the chain alive even if one search fails, or every later search in
    // the sweep inherits the error.
    _searchQueue = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<SearchResult> _runSearchLocked(
    String fen, {
    required int depth,
    required int multiPv,
  }) async {
    if (!await ensureReady()) {
      throw StateError(
          _unavailableReason ?? 'No chess engine is available on this platform.');
    }

    // dartchess answers these far more cheaply than the engine can.
    final position = Chess.fromSetup(Setup.parseFen(fen));
    final legalMoveCount =
        position.legalMoves.values.fold<int>(0, (sum, set) => sum + set.size);

    send('stop');
    await _drainWithReadyBarrier();

    _multiPvLines.clear();
    _multiPvBestByDepth.clear();
    _multiPvMaxDepth = 0;
    _analyzingFen = fen;
    final completer = Completer<SearchResult>();
    _multiPvCompleter = completer;

    send('setoption name MultiPV value $multiPv');
    send('position fen $fen');
    send('go depth $depth');

    // A search that never reports `bestmove` would hang the whole sweep with no
    // symptom beyond a progress bar that stops moving. Cut it loose and keep
    // whatever depth it did reach — a shallower result still scores.
    final raw = await completer.future.timeout(
      searchTimeout,
      onTimeout: () {
        debugPrint('[Engine] runSearch timed out at depth $_multiPvMaxDepth');
        _multiPvCompleter = null;
        send('stop');
        final indices = _multiPvLines.keys.toList()..sort();
        return SearchResult(
          fen: fen,
          depth: _multiPvMaxDepth,
          pvs: [for (final i in indices) _multiPvLines[i]!],
          legalMoveCount: legalMoveCount,
          inCheck: position.isCheck,
          bestByDepth: Map<int, String>.from(_multiPvBestByDepth),
        );
      },
    );
    return SearchResult(
      fen: fen,
      depth: raw.depth,
      pvs: raw.pvs,
      legalMoveCount: legalMoveCount,
      inCheck: position.isCheck,
      bestByDepth: raw.bestByDepth,
    );
  }

  /// Waits for the engine to flush a prior search before the next one starts.
  /// Otherwise the tail of the previous position's analysis bleeds into the new
  /// position. Times out rather than blocking forever.
  Future<void> _drainWithReadyBarrier() async {
    _readyCompleter = Completer<void>();
    send('isready');
    await _readyCompleter!.future.timeout(
      const Duration(seconds: 2),
      onTimeout: () => _readyCompleter = null,
    );
  }

  /// Live analysis of [fen], streaming to [evaluationStream].
  ///
  /// [multiPv] lines are reported; [maxDepth] bounds the search (null searches
  /// until stopped). Bounding it means the engine settles and stops burning a
  /// core — on the single-threaded web build an unbounded `go infinite` never
  /// yields.
  Future<void> analyzePosition(
    String fen, {
    int multiPv = 3,
    int? maxDepth,
  }) async {
    final gen = ++_searchGeneration;
    // While we drain the prior search, ignore any info lines that arrive.
    _activeSearchGeneration = 0;
    _currentEvals.clear();
    // Empty batch tagged with the new FEN: clears the previous position's evals
    // without ever claiming to have analysed this one.
    _evaluationController.add(PositionEvals(fen, const []));

    // Loading the engine can take seconds on web. A newer position arriving in
    // the meantime supersedes this one — the generation check below covers it,
    // which is strictly better than the old single-slot pending-FEN stash that
    // silently dropped every position but the last.
    if (!await ensureReady()) return;
    if (gen != _searchGeneration) return;

    send('stop');
    await _drainWithReadyBarrier();

    // Another analyzePosition call superseded us — bail.
    if (gen != _searchGeneration) return;

    send('setoption name MultiPV value $multiPv');
    send('position fen $fen');
    _analyzingFen = fen;
    _activeSearchGeneration = gen;
    send(maxDepth == null ? 'go infinite' : 'go depth $maxDepth');
  }

  /// One-shot depth-limited search.
  ///
  /// Returns **null** when nothing could evaluate the position — never a 0.00
  /// placeholder, which reads as dead-equal and fabricates huge swings on the
  /// surrounding moves.
  Future<EngineEvaluation?> evaluatePosition(String fen,
      {int depth = 12}) async {
    if (!await ensureReady()) return null;

    // Cancel any previous depth search. Null, not a fabricated 0.00.
    if (_depthSearchCompleter != null && !_depthSearchCompleter!.isCompleted) {
      _depthSearchCompleter!.complete(null);
    }

    _expectingBestmove = false;
    send('stop');
    send('setoption name MultiPV value 1');
    await _drainWithReadyBarrier();

    _depthSearchCompleter = Completer<EngineEvaluation?>();
    _lastDepthEval = null;

    send('position fen $fen');
    _expectingBestmove = true;
    send('go depth $depth');

    return _depthSearchCompleter!.future;
  }

  void stop() {
    if (!_handshakeDone) return;
    send('stop');
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _lineSubscription?.cancel();
    await transport.dispose();
    await _evaluationController.close();
  }
}
