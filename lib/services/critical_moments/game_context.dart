import 'package:dartchess/dartchess.dart';
import 'critical_types.dart';

/// Whole-game facts the per-ply gates need: repetition, progress, eval drops,
/// and the clock distribution.
///
/// Built once per game and passed into scoring, so no gate has to re-derive
/// history from the ply list.
class GameContext {
  final List<PlyData> plies;
  final Side userSide;

  /// Position-key -> first ply index at which it appeared.
  final Map<String, int> _firstSeen = {};

  /// ply index -> consecutive plies without a capture or pawn move, ending here.
  final List<int> _noProgress = [];

  /// ply index -> centipawns the move played at that ply gave away.
  final Map<int, int> _lossAtPly = {};

  GameContext({required this.plies, required this.userSide}) {
    _buildRepetition();
    _buildNoProgress();
    _buildLosses();
  }

  /// Position identity for repetition: the FEN without halfmove/fullmove
  /// counters, which is what "same position" means in chess.
  static String positionKey(String fen) {
    final parts = fen.split(' ');
    return parts.length >= 4 ? parts.take(4).join(' ') : fen;
  }

  void _buildRepetition() {
    for (final ply in plies) {
      _firstSeen.putIfAbsent(positionKey(ply.fenBefore), () => ply.ply);
    }
  }

  void _buildNoProgress() {
    var run = 0;
    for (final ply in plies) {
      if (_wasProgress(ply)) {
        run = 0;
      } else {
        run++;
      }
      _noProgress.add(run);
    }
  }

  /// A capture or a pawn move resets the shuffling counter.
  static bool _wasProgress(PlyData ply) {
    try {
      final pos = Chess.fromSetup(Setup.parseFen(ply.fenBefore));
      final move = NormalMove.fromUci(ply.movePlayedUci);
      if (pos.board.roleAt(move.from) == Role.pawn) return true;
      if (pos.board.pieceAt(move.to) != null) return true;
      return false;
    } catch (_) {
      return true; // Unknown — assume progress rather than damp wrongly.
    }
  }

  void _buildLosses() {
    for (final ply in plies) {
      final search = ply.best;
      if (search == null || search.pvs.isEmpty) continue;

      // What the position was worth to the mover before they moved.
      final bestCp = search.pvs.first.normalisedCp;

      // What it was worth after — read from the next ply's search, which is
      // scored from the opponent's perspective, so negate.
      final next = _plyAt(ply.ply + 1);
      final nextSearch = next?.best;
      if (nextSearch == null || nextSearch.pvs.isEmpty) continue;
      final afterCp = -nextSearch.pvs.first.normalisedCp;

      final loss = bestCp - afterCp;
      if (loss > 0) _lossAtPly[ply.ply] = loss;
    }
  }

  PlyData? _plyAt(int plyIndex) {
    for (final p in plies) {
      if (p.ply == plyIndex) return p;
    }
    return null;
  }

  /// True when this exact position occurred earlier in the game.
  bool positionSeenBefore(String fen, int currentPly) {
    final first = _firstSeen[positionKey(fen)];
    return first != null && first < currentPly;
  }

  /// Consecutive plies up to [plyIndex] with no capture and no pawn move.
  int noProgressPlies(int plyIndex) {
    final idx = plies.indexWhere((p) => p.ply == plyIndex);
    if (idx < 0 || idx >= _noProgress.length) return 0;
    return _noProgress[idx];
  }

  /// True when the move played at [plyIndex] dropped eval by more than [cp].
  bool plyLostOver(int plyIndex, int cp) => (_lossAtPly[plyIndex] ?? 0) > cp;

  /// Own-move times in the ply range [from, to], stepping by 2 (own moves only).
  List<double> timesForPlies(int from, int to) {
    final out = <double>[];
    for (int p = from; p <= to; p += 2) {
      final ply = _plyAt(p);
      final t = ply?.timeSpentSec;
      if (ply != null && ply.side == userSide && t != null) out.add(t);
    }
    return out;
  }

  /// The n-th quartile boundary of own-move times (1 = lower quartile).
  double gameTimeQuartile(int n) {
    final times = <double>[
      for (final p in plies)
        if (p.side == userSide && p.timeSpentSec != null) p.timeSpentSec!,
    ]..sort();
    if (times.isEmpty) return 0.0;
    final idx = ((times.length - 1) * n / 4).round().clamp(0, times.length - 1);
    return times[idx];
  }
}
