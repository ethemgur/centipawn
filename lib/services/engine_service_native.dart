import 'dart:async';
import 'dart:io';
import 'package:dartchess/dartchess.dart';
import 'package:flutter/foundation.dart';
import 'package:stockfish/stockfish.dart';
import 'engine_types.dart';
import 'move_evaluator.dart';

class EngineService {
  Stockfish? _stockfish;
  StreamSubscription? _stdoutSubscription;
  final _evaluationController = StreamController<PositionEvals>.broadcast();

  Stream<PositionEvals> get evaluationStream => _evaluationController.stream;
  bool get isReady => _stockfish != null;

  /// True when a Stockfish instance was created successfully, i.e. the scores
  /// coming back from [evaluatePosition] are real analysis.
  bool get isAvailable => _stockfish != null;

  EngineService() {
    _initEngine();
  }

  void _initEngine() {
    try {
      _stockfish = Stockfish();
      _stdoutSubscription = _stockfish!.stdout.listen(_handleEngineOutput);
      
      _stockfish!.state.addListener(_onStateChange);
    } catch (e) {
      debugPrint('Failed to initialize Stockfish: $e');
      _stockfish = null;
    }
  }

  void _onStateChange() {
    if (_stockfish?.state.value == StockfishState.ready) {
      // On phones, more than ~3 threads triggers thermal throttling within
      // seconds and tanks sustained NPS. Cap at a steady number that the SoC
      // can hold without downclocking — Lichess Mobile uses a similar cap.
      final threads = Platform.numberOfProcessors >= 6 ? 3 : 2;
      _sendCommand('uci');
      _sendCommand('setoption name Threads value $threads');
      _sendCommand('setoption name Hash value 256');
      _sendCommand('setoption name MultiPV value 3');
      _sendCommand('ucinewgame');
      _sendCommand('isready');
      
      if (_pendingFen != null) {
        analyzePosition(_pendingFen!);
        _pendingFen = null;
      }
    }
  }

  String? _pendingFen;
  final Map<int, EngineEvaluation> _currentEvals = {};
  Completer<EngineEvaluation>? _depthSearchCompleter;
  EngineEvaluation? _lastDepthEval;
  bool _expectingBestmove = false;
  Completer<void>? _readyCompleter;
  // Bumped on each analyzePosition call. Info lines whose generation does not
  // match _activeSearchGeneration are tail output from a prior search and are
  // dropped — without this, Stockfish's flush after `stop` leaks the previous
  // position's eval into the new one.
  int _searchGeneration = 0;
  int _activeSearchGeneration = 0;
  // FEN of the search whose info lines are currently being accepted. Emitted
  // with every batch so consumers can tell which position an eval describes.
  String _analyzingFen = '';

  // ── MultiPV analysis search (runSearch) ───────────────────────────────────
  // Kept separate from the streaming/depth paths above: this one accumulates
  // every multipv line *and* the per-depth best move, and completes on bestmove.
  Completer<SearchResult>? _multiPvCompleter;
  final Map<int, PvLine> _multiPvLines = {};
  final Map<int, String> _multiPvBestByDepth = {};
  int _multiPvMaxDepth = 0;
  /// Serialises runSearch calls — a game sweep issues hundreds back to back and
  /// a single Stockfish process can only answer one at a time.
  Future<void> _searchQueue = Future<void>.value();

  /// Upper bound on a single [runSearch]. Depth 28 on a phone is seconds, not
  /// minutes; anything past this is a stuck process, not a slow one.
  static const Duration _searchTimeout = Duration(seconds: 90);

  void _handleEngineOutput(String line) {
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
    // When a depth-limited search finishes, Stockfish outputs "bestmove ..."
    // Only complete if we sent "go depth" — ignores the bestmove emitted by "stop".
    if (line.startsWith('bestmove')) {
      if (_expectingBestmove && _depthSearchCompleter != null && !_depthSearchCompleter!.isCompleted) {
        _expectingBestmove = false;
        final eval = _lastDepthEval ?? EngineEvaluation(scoreCp: 0);
        _depthSearchCompleter!.complete(eval);
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

      final eval = EngineEvaluation(scoreCp: cp, mate: mate, pv: pv, depth: depth);

      // If we're in a depth-limited search, just track the latest eval
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
  /// Calls are serialised: the underlying process handles one search at a time,
  /// so a caller sweeping a whole game can simply await these in a loop.
  /// Throws [StateError] when no engine is available — check [isAvailable]
  /// first rather than treating a returned score as analysis.
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
    if (_stockfish == null) {
      throw StateError('No Stockfish engine available on this platform');
    }
    while (_stockfish!.state.value != StockfishState.ready) {
      await Future.delayed(const Duration(milliseconds: 100));
    }

    // dartchess answers these far more cheaply than the engine can.
    final position = Chess.fromSetup(Setup.parseFen(fen));
    final legalMoveCount = position.legalMoves.values
        .fold<int>(0, (sum, set) => sum + set.size);

    _sendCommand('stop');
    _readyCompleter = Completer<void>();
    _sendCommand('isready');
    await _readyCompleter!.future.timeout(
      const Duration(seconds: 2),
      onTimeout: () => _readyCompleter = null,
    );

    _multiPvLines.clear();
    _multiPvBestByDepth.clear();
    _multiPvMaxDepth = 0;
    _analyzingFen = fen;
    final completer = Completer<SearchResult>();
    _multiPvCompleter = completer;

    _sendCommand('setoption name MultiPV value $multiPv');
    _sendCommand('position fen $fen');
    _sendCommand('go depth $depth');

    // A search that never reports `bestmove` would hang the whole sweep with no
    // symptom beyond a progress bar that stops moving. Cut it loose and keep
    // whatever depth it did reach — a shallower result still scores.
    final raw = await completer.future.timeout(
      _searchTimeout,
      onTimeout: () {
        debugPrint('[Engine] runSearch timed out at depth $_multiPvMaxDepth');
        _multiPvCompleter = null;
        _sendCommand('stop');
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

  void _sendCommand(String command) {
    _stockfish?.stdin = command;
  }

  Future<void> analyzePosition(String fen) async {
    if (_stockfish == null) return;
    if (_stockfish!.state.value != StockfishState.ready) {
      _pendingFen = fen;
      return;
    }
    final gen = ++_searchGeneration;
    // While we drain the prior search, ignore any info lines that arrive.
    _activeSearchGeneration = 0;
    _currentEvals.clear();
    // Empty batch tagged with the new FEN: clears the previous position's evals
    // without ever claiming to have analysed this one.
    _evaluationController.add(PositionEvals(fen, const []));
    _sendCommand('stop');

    // Wait for Stockfish to flush bestmove/info from the prior search before
    // starting the new one. Otherwise the tail of the previous position's
    // analysis bleeds into the new position.
    _readyCompleter = Completer<void>();
    _sendCommand('isready');
    await _readyCompleter!.future.timeout(
      const Duration(seconds: 2),
      onTimeout: () {
        _readyCompleter = null;
      },
    );

    // Another analyzePosition call superseded us — bail.
    if (gen != _searchGeneration) return;

    _sendCommand('setoption name MultiPV value 1');
    _sendCommand('position fen $fen');
    _analyzingFen = fen;
    _activeSearchGeneration = gen;
    _sendCommand('go infinite');
  }

  Future<EngineEvaluation> evaluatePosition(String fen, {int depth = 12}) async {
    if (_stockfish == null) return EngineEvaluation(scoreCp: 0);
    
    while (_stockfish!.state.value != StockfishState.ready) {
      await Future.delayed(const Duration(milliseconds: 100));
    }

    // Cancel any previous depth search
    if (_depthSearchCompleter != null && !_depthSearchCompleter!.isCompleted) {
      _depthSearchCompleter!.complete(EngineEvaluation(scoreCp: 0));
    }

    _expectingBestmove = false;
    _sendCommand('stop');
    _sendCommand('setoption name MultiPV value 1');

    // Wait for Stockfish to flush any pending bestmove from the prior search
    // before we set up the new completer.
    _readyCompleter = Completer<void>();
    _sendCommand('isready');
    await _readyCompleter!.future.timeout(
      const Duration(seconds: 2),
      onTimeout: () {
        _readyCompleter = null;
      },
    );

    _depthSearchCompleter = Completer<EngineEvaluation>();
    _lastDepthEval = null;

    _sendCommand('position fen $fen');
    _expectingBestmove = true;
    _sendCommand('go depth $depth');

    return _depthSearchCompleter!.future;
  }

  void stop() {
    if (_stockfish == null) return;
    _sendCommand('stop');
  }

  void dispose() {
    _stdoutSubscription?.cancel();
    _stockfish?.state.removeListener(_onStateChange);
    _stockfish?.dispose();
    _evaluationController.close();
  }

  static MoveQuality? getMoveLabel(double previousCp, double newCp) {
    final prevEval = ChessEvaluation(cp: (previousCp * 100).toInt());
    final newEval = ChessEvaluation(cp: (newCp * 100).toInt());
    return MoveEvaluator.classifyMove(prevEval, newEval, true); // Simplified
  }
}
