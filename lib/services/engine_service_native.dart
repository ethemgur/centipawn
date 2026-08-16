import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:stockfish/stockfish.dart';
import 'engine_types.dart';
import 'move_evaluator.dart';

class EngineService {
  Stockfish? _stockfish;
  StreamSubscription? _stdoutSubscription;
  final _evaluationController = StreamController<List<EngineEvaluation>>.broadcast();

  Stream<List<EngineEvaluation>> get evaluationStream => _evaluationController.stream;
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

  void _handleEngineOutput(String line) {
    final trimmed = line.trim();
    if (trimmed == 'readyok') {
      _readyCompleter?.complete();
      _readyCompleter = null;
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
      _evaluationController.add(evals);
    }
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
    _evaluationController.add([]);
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
