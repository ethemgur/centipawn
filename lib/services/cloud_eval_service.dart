import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'engine_types.dart';

/// Wraps the Lichess cloud-eval endpoint.
///
/// Lichess pre-computes Stockfish analysis (depth 20–99+) for millions of
/// positions and serves results in <100 ms. We use it as the primary source
/// during game review and live analysis, with local Stockfish as fallback
/// whenever a position isn't cached (HTTP 404) or the network is unavailable.
///
/// Eval convention: Lichess reports scores from **White's perspective**
/// (positive = White winning). We normalise to **side-to-move perspective**
/// before returning so the result is a drop-in replacement for
/// [EngineEvaluation] coming from the local engine.
///
/// Rate limits: Lichess asks for ≤ 1 req/s without authentication. The game
/// review loop naturally respects this because every cache-miss falls back to
/// the local engine (several seconds). No explicit throttle is needed.
class CloudEvalService {
  /// Minimum depth we're willing to accept from the cloud.
  /// Lichess common-position cache typically returns depth 30–99; anything
  /// below [_minAcceptableDepth] probably isn't useful enough to trust over
  /// the local engine.
  static const int _minAcceptableDepth = 20;

  static final http.Client _client = http.Client();

  /// Fetches the cloud evaluation for [fen].
  ///
  /// Returns `null` if:
  /// - the position isn't cached (HTTP 404),
  /// - the network is unreachable,
  /// - the returned depth is below [_minAcceptableDepth], or
  /// - any parse error occurs.
  ///
  /// [multiPv] controls how many lines are returned (1–3). Pass 1 for game
  /// review (classification only needs the best line) and 3 for live display.
  static Future<List<EngineEvaluation>?> evaluate(
    String fen, {
    int multiPv = 1,
  }) async {
    try {
      final uri = Uri.https('lichess.org', '/api/cloud-eval', {
        'fen': fen,
        'multiPv': '$multiPv',
      });

      final response = await _client
          .get(uri, headers: {'Accept': 'application/json'})
          .timeout(const Duration(seconds: 5));

      if (response.statusCode == 404) return null; // not cached
      if (response.statusCode == 429) {
        // Rate-limited — let caller fall back to local engine.
        debugPrint('[CloudEval] rate-limited (429)');
        return null;
      }
      if (response.statusCode != 200) return null;

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final depth = (data['depth'] as num?)?.toInt() ?? 0;
      if (depth < _minAcceptableDepth) return null;

      final pvs = data['pvs'] as List<dynamic>?;
      if (pvs == null || pvs.isEmpty) return null;

      // Lichess reports scores from White's perspective; convert to
      // side-to-move so our existing _toCpWhitePerspective logic works.
      final isWhiteToMove = _isWhiteToMove(fen);

      final evals = <EngineEvaluation>[];
      for (final pvRaw in pvs) {
        final pv = pvRaw as Map<String, dynamic>;
        final moves = (pv['moves'] as String? ?? '')
            .split(' ')
            .where((m) => m.isNotEmpty)
            .toList();

        if (pv.containsKey('mate')) {
          final cloudMate = (pv['mate'] as num).toInt();
          // Convert: positive cloudMate = White mates.
          final sideMate = isWhiteToMove ? cloudMate : -cloudMate;
          evals.add(EngineEvaluation(
            scoreCp: 0,
            mate: sideMate,
            pv: moves,
            depth: depth,
          ));
        } else {
          final cloudCp = (pv['cp'] as num).toDouble(); // centipawns, white POV
          final sideCp = isWhiteToMove ? cloudCp : -cloudCp;
          evals.add(EngineEvaluation(
            scoreCp: sideCp / 100.0, // engine convention: pawns
            pv: moves,
            depth: depth,
          ));
        }
      }
      return evals.isEmpty ? null : evals;
    } catch (e) {
      // Network error, timeout, JSON parse failure — all fall back silently.
      debugPrint('[CloudEval] error: $e');
      return null;
    }
  }

  /// Convenience wrapper for game review: returns the single best evaluation,
  /// or `null` if unavailable.
  static Future<EngineEvaluation?> evaluateBest(String fen) async {
    final results = await evaluate(fen, multiPv: 1);
    return results?.firstOrNull;
  }

  static bool _isWhiteToMove(String fen) {
    final parts = fen.split(' ');
    return parts.length < 2 || parts[1] == 'w';
  }
}
