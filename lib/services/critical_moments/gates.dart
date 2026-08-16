import 'package:dartchess/dartchess.dart';
import 'critical_types.dart';
import 'game_context.dart';

/// Outcome of a zero-out gate. A gate either passes or kills the ply outright —
/// there is no partial credit at this stage.
class GateResult {
  final bool zeroed;
  final String? reason;

  const GateResult._(this.zeroed, this.reason);

  static const GateResult pass = GateResult._(false, null);
  static GateResult zero(String reason) => GateResult._(true, reason);
}

/// Which damps are active. All of them are toggleable because during validation
/// you need to see the undamped ranking to check the damps are not suppressing
/// genuine content.
class DampConfig {
  final bool decided;
  final bool shuffling;
  final bool scramble;
  final bool postBlunder;
  final bool endgameRun;

  const DampConfig({
    this.decided = true,
    this.shuffling = true,
    this.scramble = true,
    this.postBlunder = true,
    this.endgameRun = true,
  });

  static const DampConfig all = DampConfig();
  static const DampConfig none = DampConfig(
    decided: false,
    shuffling: false,
    scramble: false,
    postBlunder: false,
    endgameRun: false,
  );
}

class DampResult {
  final double multiplier;
  final List<String> fired;
  const DampResult(this.multiplier, this.fired);
}

/// Zero-out gates, §6.
///
/// **Ordering matters.** These run before any component is computed and before
/// damps, and short-circuit on the first hit. A zeroed ply is also dropped from
/// the game's percentile distribution entirely rather than entered as a zero.
class ZeroOutGates {
  /// Runs the gates in spec order and returns the first that fires.
  static GateResult evaluate(PlyData ply, GameContext ctx) {
    if (ply.inBook) return GateResult.zero('book');

    final search = ply.best;
    if (search == null || search.pvs.isEmpty) {
      return GateResult.zero('no_analysis');
    }

    if (search.legalMoveCount == 1) {
      return GateResult.zero('forced:single_legal');
    }

    final checkEvasion = _checkEvasion(search);
    if (checkEvasion.zeroed) return checkEvasion;

    final recapture = _recapture(ply, search);
    if (recapture.zeroed) return recapture;

    final mate = _mateExecution(search);
    if (mate.zeroed) return mate;

    return GateResult.pass;
  }

  /// A large raw gap when in check with almost no replies means the
  /// alternatives lose material outright — forced in practice, even though it
  /// is technically a choice.
  ///
  /// Deliberately uses the raw cp gap, not the clamped spread: the clamp would
  /// erase exactly the distinction this gate is testing for.
  static GateResult _checkEvasion(SearchResult search) {
    if (!search.inCheck || search.legalMoveCount > 3) return GateResult.pass;
    if (search.pvs.length < 2) return GateResult.zero('forced:check_evasion');
    if (search.topTwoGapCp > 300) return GateResult.zero('forced:check_evasion');
    return GateResult.pass;
  }

  /// Three-way classification, not a blanket filter.
  ///
  /// The single-recapturer-but-not-best branch is where zwischenzugs live;
  /// zeroing it silently loses real content, which is why this is a classifier
  /// rather than `if (isRecapture) skip`.
  static GateResult _recapture(PlyData ply, SearchResult search) {
    final prev = ply.previousMove;
    if (prev == null || !prev.wasCapture) return GateResult.pass;

    final Position pos;
    try {
      pos = Chess.fromSetup(Setup.parseFen(ply.fenBefore));
    } catch (_) {
      return GateResult.pass;
    }

    final target = prev.toSquare;
    final recapturers = <NormalMove>[];
    for (final entry in pos.legalMoves.entries) {
      if (entry.value.has(target)) {
        recapturers.add(NormalMove(from: entry.key, to: target));
      }
    }
    if (recapturers.isEmpty) return GateResult.pass;

    final best = search.bestMoveUci;
    if (recapturers.length == 1) {
      final only = recapturers.first;
      // Compare on from/to only — the engine may specify a promotion piece.
      final matchesBest = best != null &&
          best.length >= 4 &&
          best.substring(0, 4) == only.uci.substring(0, 4);
      if (matchesBest) return GateResult.zero('forced:recapture_single');
      // A zwischenzug exists, or the recapture loses. Real decision.
      return GateResult.pass;
    }

    // TODO(boost): multiple recapturers is a genuine choice of structure and
    // carried a 1.4x boost in the original design. Boosts are out of scope for
    // v1 — revisit once the base ranking validates.
    return GateResult.pass;
  }

  /// If every reasonable move still mates, the execution is not a decision.
  /// The *entry* into the mating net is caught normally, because at that ply
  /// the alternatives are not mate scores.
  static GateResult _mateExecution(SearchResult search) {
    if (search.pvs.length < 2) return GateResult.pass;
    final a = search.pvs[0];
    final b = search.pvs[1];
    if (!a.isMate || !b.isMate) return GateResult.pass;
    if (a.mateIn!.sign != b.mateIn!.sign) return GateResult.pass;
    return GateResult.zero('forced:mate_execution');
  }

  /// Once a mate score appears and the distance to mate keeps shrinking, the
  /// rest of the game is execution. Without this the last six plies of every
  /// won game monopolise the report.
  ///
  /// Returns the set of ply indices to zero.
  static Set<int> mateRunPlies(List<PlyData> plies, Side userSide) {
    final zeroed = <int>{};
    int? runMateDistance;

    for (final ply in plies) {
      final search = ply.best;
      final top = (search == null || search.pvs.isEmpty) ? null : search.pvs.first;

      if (top == null || !top.isMate || top.mateIn! <= 0) {
        runMateDistance = null;
        continue;
      }

      final distance = top.mateIn!;
      if (runMateDistance == null) {
        // Entry into the mating net — this ply is the decision, keep it.
        runMateDistance = distance;
        continue;
      }
      if (distance <= runMateDistance) {
        if (ply.side == userSide) zeroed.add(ply.ply);
        runMateDistance = distance;
      } else {
        runMateDistance = distance;
      }
    }
    return zeroed;
  }
}

/// Damp gates, §7. Multipliers applied after components are computed — these
/// moments stay in the ranking, they just stop crowding out everything else.
class DampGates {
  static DampResult evaluate(
    PlyData ply,
    GameContext ctx, {
    DampConfig config = DampConfig.all,
  }) {
    final search = ply.best;
    if (search == null || search.pvs.isEmpty) {
      return const DampResult(1.0, []);
    }

    double m = 1.0;
    final fired = <String>[];

    // 7.1 Decided position.
    if (config.decided) {
      final e1 = search.pvs.first.normalisedCp.abs();
      final e3 = search.pvs.length > 2 ? search.pvs[2].normalisedCp.abs() : e1;
      if (e1 > 600) {
        // If most moves throw the win away, this is conversion technique and
        // genuinely a decision — do not damp it.
        final isConversionTest = e3 < 100;
        if (!isConversionTest) {
          m *= 0.2;
          fired.add('damp:decided');
        }
      }
    }

    // 7.2 Repetition / shuffling. Manoeuvring phases generate high spread on
    // "improve your worst piece" moves that are not really decisions.
    if (config.shuffling) {
      if (ctx.positionSeenBefore(ply.fenBefore, ply.ply) ||
          ctx.noProgressPlies(ply.ply) >= 6) {
        m *= 0.5;
        fired.add('damp:shuffling');
      }
    }

    // 7.3 Time scramble.
    if (config.scramble) {
      final own = ply.clockRemainingSec;
      final opp = ply.opponentClockRemainingSec;
      if (own != null && opp != null && own < kScrambleSec && opp < kScrambleSec) {
        m *= 0.4;
        fired.add('damp:scramble');
      }
    }

    // 7.4 Post-blunder inheritance: the plies after a blunder inherit inflated
    // spread from the new imbalance rather than presenting new decisions.
    if (config.postBlunder) {
      if (ctx.plyLostOver(ply.ply - 1, 200) ||
          ctx.plyLostOver(ply.ply - 2, 200)) {
        m *= 0.5;
        fired.add('damp:post_blunder');
      }
    }

    return DampResult(m.clamp(kDampFloor, 1.0), fired);
  }

  /// True when the position is a simplified endgame: no queens and at most six
  /// non-king pieces a side.
  static bool isSimplifiedEndgame(String fen) {
    try {
      final board = Chess.fromSetup(Setup.parseFen(fen)).board;
      if (board.byRole(Role.queen).isNotEmpty) return false;
      // `diff`, not `-`: SquareSet's operator- is numeric subtraction, and
      // `kings` is not a subset of `white`, so it would borrow into garbage.
      final white = board.white.diff(board.kings).size;
      final black = board.black.diff(board.kings).size;
      return white <= 6 && black <= 6;
    } catch (_) {
      return false;
    }
  }
}
