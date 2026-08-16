import 'dart:async';
import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter/foundation.dart';
import '../engine_service.dart';
import 'critical_types.dart';

/// Progress of a running analysis, streamed so the UI can show partial results.
class AnalysisProgress {
  final int completed;
  final int total;
  final String stage; // 'shallow' | 'deep'

  const AnalysisProgress({
    required this.completed,
    required this.total,
    required this.stage,
  });

  double get fraction => total == 0 ? 0 : completed / total;
}

/// Caches search results so re-scoring never re-searches.
///
/// Keyed by `(fen, depth, multiPv)` — the tuple that fully determines a search.
class SearchCache {
  final Map<String, SearchResult> _entries = {};

  static String key(String fen, int depth, int multiPv) =>
      '$fen|$depth|$multiPv';

  SearchResult? get(String fen, int depth, int multiPv) =>
      _entries[key(fen, depth, multiPv)];

  void put(String fen, int depth, int multiPv, SearchResult result) {
    _entries[key(fen, depth, multiPv)] = result;
  }

  int get size => _entries.length;
  void clear() => _entries.clear();

  Map<String, dynamic> toJson() =>
      _entries.map((k, v) => MapEntry(k, v.toJson()));

  void loadJson(Map<String, dynamic> json) {
    json.forEach((k, v) {
      _entries[k] = SearchResult.fromJson(v as Map<String, dynamic>);
    });
  }
}

/// Stages A and B: the only part of the pipeline that touches the engine.
///
/// Analyses from the perspective of one player. Opponent plies are searched for
/// eval continuity — the loss and novelty terms need them — but are never
/// scored or reported.
class CriticalMomentAnalyzer {
  final EngineService engine;
  final SearchCache cache;

  CriticalMomentAnalyzer({required this.engine, SearchCache? cache})
      : cache = cache ?? SearchCache();

  /// Runs both engine stages over [plies], mutating them in place.
  ///
  /// Throws [StateError] when no engine is available — on web there is no
  /// Stockfish and the cloud endpoint exposes neither MultiPV nor per-depth
  /// best moves, so there is nothing to fall back to.
  Future<void> analyze(
    List<PlyData> plies,
    Side userSide, {
    int shallowDepth = kShallowDepth,
    int deepDepth = kDeepDepth,
    void Function(AnalysisProgress)? onProgress,
  }) async {
    if (!engine.isAvailable) {
      throw StateError(
        'Critical-moment analysis needs a local engine; none is available '
        'on this platform.',
      );
    }

    final analysable = plies.where((p) => !p.inBook).toList();
    await _stageA(analysable, shallowDepth, onProgress);

    final flagged = flagForDeepAnalysis(analysable, userSide);
    await _stageB(flagged, deepDepth, onProgress);
  }

  /// Stage A: every non-book ply at shallow depth.
  Future<void> _stageA(
    List<PlyData> plies,
    int depth,
    void Function(AnalysisProgress)? onProgress,
  ) async {
    for (int i = 0; i < plies.length; i++) {
      final ply = plies[i];
      ply.shallow = await _search(ply.fenBefore, depth, kShallowMultiPv);
      onProgress?.call(AnalysisProgress(
        completed: i + 1,
        total: plies.length,
        stage: 'shallow',
      ));
    }
  }

  /// Stage B: flagged plies only, deeper and wider.
  Future<void> _stageB(
    List<PlyData> plies,
    int depth,
    void Function(AnalysisProgress)? onProgress,
  ) async {
    for (int i = 0; i < plies.length; i++) {
      final ply = plies[i];
      ply.deep = await _search(ply.fenBefore, depth, kDeepMultiPv);
      onProgress?.call(AnalysisProgress(
        completed: i + 1,
        total: plies.length,
        stage: 'deep',
      ));
    }
  }

  Future<SearchResult> _search(String fen, int depth, int multiPv) async {
    final cached = cache.get(fen, depth, multiPv);
    if (cached != null) return cached;
    final result = await engine.runSearch(fen, depth: depth, multiPv: multiPv);
    cache.put(fen, depth, multiPv, result);
    return result;
  }

  /// Preliminary spread from the shallow sweep, used only for flagging.
  static double prelimSpread(SearchResult? search) {
    if (search == null || search.pvs.length < 2) return 0.0;
    return search.topTwoGapCp.clamp(0, kSpreadCapCp) / kSpreadCapCp;
  }

  /// Union of an absolute threshold and a within-game percentile.
  ///
  /// Union, not intersection: the percentile rule alone flags eight plies in a
  /// dead-drawn game, and the absolute rule alone flags nothing in a quiet one.
  static List<PlyData> flagForDeepAnalysis(
    List<PlyData> plies,
    Side userSide, {
    double absoluteThreshold = kStageAAbsoluteThreshold,
    double percentile = kStageAPercentile,
  }) {
    final userPlies = plies.where((p) => p.side == userSide).toList();
    if (userPlies.isEmpty) return const [];

    final spreads = {
      for (final p in userPlies) p.ply: prelimSpread(p.shallow),
    };

    final sorted = [...userPlies]
      ..sort((a, b) => (spreads[b.ply] ?? 0).compareTo(spreads[a.ply] ?? 0));
    final topCount = (userPlies.length * percentile).ceil();
    final topPlies = sorted.take(topCount).map((p) => p.ply).toSet();

    return [
      for (final p in userPlies)
        if ((spreads[p.ply] ?? 0) > absoluteThreshold || topPlies.contains(p.ply))
          p
    ];
  }
}

/// Debug dump of which plies were flagged for deep analysis and why.
void debugDumpFlagging(List<PlyData> plies, Side userSide) {
  for (final p in plies.where((p) => p.side == userSide)) {
    debugPrint('ply ${p.ply} ${p.movePlayedSan}: '
        'prelim=${CriticalMomentAnalyzer.prelimSpread(p.shallow).toStringAsFixed(3)} '
        'deep=${p.deep != null}');
  }
}
