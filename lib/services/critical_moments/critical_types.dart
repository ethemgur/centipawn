import 'package:dartchess/dartchess.dart' show Side, Square;
import '../engine_types.dart';

export '../engine_types.dart' show PvLine, SearchResult, kMateSentinelCp;

// ---------------------------------------------------------------------------
// Tunable constants
// ---------------------------------------------------------------------------

/// Spread saturates here. Load-bearing: uncapped, one position where a move
/// hangs a queen dominates the ranking for the whole game. Past three pawns the
/// answer to "does this choice matter" is already yes.
const int kSpreadCapCp = 300;

/// Difficulty never fully zeroes a moment out. A position most players find
/// easily may still be one *this* player missed, and a fully multiplicative
/// difficulty term would erase it. Do not remove to tidy up the ranking.
const double kDifficultyFloor = 0.25;

const double kDivergenceWeight = 0.6;
const double kRawCap = 2.0;
const int kDivergencePlies = 12;
const int kScrambleSec = 60;
const double kNoveltyDefault = 0.5;

/// Sub-weights of the heuristic difficulty blend. Reasoned, not fitted — see
/// `tool/validate_critical_moments.dart`.
const double kDtsWeight = 0.45;
const double kCharWeight = 0.30;
const double kNoveltyWeight = 0.25;

/// Damps multiply together; this floor stops a ply that trips several at once
/// from being silently equivalent to a zero-out.
const double kDampFloor = 0.05;

/// Stage A flags a ply for deep analysis above this preliminary spread.
const double kStageAAbsoluteThreshold = 0.05;

/// ...or if it lands in the top slice of the game by preliminary spread.
const double kStageAPercentile = 0.20;

const int kShallowDepth = 15;
const int kShallowMultiPv = 3;
const int kDeepDepth = 28;
const int kDeepMultiPv = 5;

// ---------------------------------------------------------------------------
// Ply input
// ---------------------------------------------------------------------------

/// The move that led into this position, used by the recapture gate.
class PreviousMove {
  final String uci;
  final bool wasCapture;
  final Square toSquare;

  const PreviousMove({
    required this.uci,
    required this.wasCapture,
    required this.toSquare,
  });

  Map<String, dynamic> toJson() =>
      {'uci': uci, 'wasCapture': wasCapture, 'toSquare': toSquare.value};

  factory PreviousMove.fromJson(Map<String, dynamic> j) => PreviousMove(
        uci: j['uci'] as String,
        wasCapture: j['wasCapture'] as bool,
        toSquare: Square(j['toSquare'] as int),
      );
}

/// One ply of the game with everything scoring needs.
///
/// Mutable in two narrow places ([deep], [inBook]) because they are filled in
/// by later pipeline stages; everything else is set at construction.
class PlyData {
  /// 0-indexed from the start of the game.
  final int ply;
  final int moveNumber;
  final Side side;
  final String fenBefore;
  final String movePlayedUci;
  final String movePlayedSan;

  /// Seconds spent on this move. Negative or null clocks mean "unknown" and
  /// exclude the ply from the time regression rather than being guessed at.
  final double? timeSpentSec;
  final int? clockRemainingSec;
  final int? opponentClockRemainingSec;

  final PreviousMove? previousMove;

  /// Set by [RepertoireMatcher]. Book plies never reach the engine.
  bool inBook;

  /// Filled by Stage A. Present unless [inBook] (book plies never reach the
  /// engine) or analysis has not run yet.
  SearchResult? shallow;

  /// Filled by Stage B, and only when Stage A flagged this ply.
  SearchResult? deep;

  PlyData({
    required this.ply,
    required this.moveNumber,
    required this.side,
    required this.fenBefore,
    required this.movePlayedUci,
    required this.movePlayedSan,
    this.timeSpentSec,
    this.clockRemainingSec,
    this.opponentClockRemainingSec,
    this.previousMove,
    this.inBook = false,
    this.shallow,
    this.deep,
  });

  /// Best available search for this ply — deep when it exists, shallow otherwise.
  SearchResult? get best => deep ?? shallow;

  Map<String, dynamic> toJson() => {
        'ply': ply,
        'moveNumber': moveNumber,
        'side': side == Side.white ? 'white' : 'black',
        'fenBefore': fenBefore,
        'movePlayedUci': movePlayedUci,
        'movePlayedSan': movePlayedSan,
        if (timeSpentSec != null) 'timeSpentSec': timeSpentSec,
        if (clockRemainingSec != null) 'clockRemainingSec': clockRemainingSec,
        if (opponentClockRemainingSec != null)
          'opponentClockRemainingSec': opponentClockRemainingSec,
        if (previousMove != null) 'previousMove': previousMove!.toJson(),
        'inBook': inBook,
        if (shallow != null) 'shallow': shallow!.toJson(),
        if (deep != null) 'deep': deep!.toJson(),
      };

  factory PlyData.fromJson(Map<String, dynamic> j) => PlyData(
        ply: j['ply'] as int,
        moveNumber: j['moveNumber'] as int,
        side: j['side'] == 'white' ? Side.white : Side.black,
        fenBefore: j['fenBefore'] as String,
        movePlayedUci: j['movePlayedUci'] as String,
        movePlayedSan: j['movePlayedSan'] as String,
        timeSpentSec: (j['timeSpentSec'] as num?)?.toDouble(),
        clockRemainingSec: j['clockRemainingSec'] as int?,
        opponentClockRemainingSec: j['opponentClockRemainingSec'] as int?,
        previousMove: j['previousMove'] == null
            ? null
            : PreviousMove.fromJson(
                j['previousMove'] as Map<String, dynamic>),
        inBook: j['inBook'] as bool? ?? false,
        shallow: j['shallow'] == null
            ? null
            : SearchResult.fromJson(j['shallow'] as Map<String, dynamic>),
        deep: j['deep'] == null
            ? null
            : SearchResult.fromJson(j['deep'] as Map<String, dynamic>),
      );
}

// ---------------------------------------------------------------------------
// Scoring output
// ---------------------------------------------------------------------------

/// Every component that fed the composite. Not optional: validation depends on
/// being able to answer "why did this rank first", and reconstructing it after
/// the fact is guesswork.
class ScoreBreakdown {
  final double spread;
  final double difficultyDts;
  final double difficultyChar;
  final double difficultyNov;
  final double difficultyCombined;
  final double divergence;
  final double gateMultiplier;

  const ScoreBreakdown({
    required this.spread,
    required this.difficultyDts,
    required this.difficultyChar,
    required this.difficultyNov,
    required this.difficultyCombined,
    required this.divergence,
    required this.gateMultiplier,
  });

  static const ScoreBreakdown zero = ScoreBreakdown(
    spread: 0,
    difficultyDts: 0,
    difficultyChar: 0,
    difficultyNov: 0,
    difficultyCombined: 0,
    divergence: 0,
    gateMultiplier: 0,
  );

  Map<String, dynamic> toJson() => {
        'spread': spread,
        'difficultyDts': difficultyDts,
        'difficultyChar': difficultyChar,
        'difficultyNov': difficultyNov,
        'difficultyCombined': difficultyCombined,
        'divergence': divergence,
        'gateMultiplier': gateMultiplier,
      };

  @override
  String toString() => 'spread=${spread.toStringAsFixed(3)} '
      'dts=${difficultyDts.toStringAsFixed(3)} '
      'char=${difficultyChar.toStringAsFixed(3)} '
      'nov=${difficultyNov.toStringAsFixed(3)} '
      'diff=${difficultyCombined.toStringAsFixed(3)} '
      'div=${divergence.toStringAsFixed(3)} '
      'damp=${gateMultiplier.toStringAsFixed(3)}';
}

enum TimeVerdict {
  /// Moved fast at a genuine branch point. The headline finding.
  blindSpot,

  /// Long think that did not buy a later speed-up.
  wasted,

  /// Long think followed by fast moves — calculated ahead and cashed it in.
  productiveThink,

  normal,
}

class CriticalMoment {
  final int ply;
  final int moveNumber;
  final Side side;
  final String movePlayedSan;
  final String fenBefore;

  /// Engine's preferred move at this position, for display alongside the played move.
  final String? bestMoveUci;

  final double rawScore;

  /// 0..100 within this game, over non-zeroed plies of the analysed side only.
  final double criticalityPercentile;

  final ScoreBreakdown breakdown;

  /// Damp gates that fired, e.g. `damp:repetition`. Empty when none did.
  final List<String> gatesFired;

  /// Null when the ply was excluded from the regression (see §9.1) or the
  /// regression was skipped for lack of data.
  final double? timeResidual;

  final TimeVerdict verdict;

  final double? timeSpentSec;

  const CriticalMoment({
    required this.ply,
    required this.moveNumber,
    required this.side,
    required this.movePlayedSan,
    required this.fenBefore,
    required this.bestMoveUci,
    required this.rawScore,
    required this.criticalityPercentile,
    required this.breakdown,
    required this.gatesFired,
    this.timeResidual,
    this.verdict = TimeVerdict.normal,
    this.timeSpentSec,
  });

  CriticalMoment copyWith({
    double? criticalityPercentile,
    double? timeResidual,
    TimeVerdict? verdict,
    double? rawScore,
    List<String>? gatesFired,
  }) =>
      CriticalMoment(
        ply: ply,
        moveNumber: moveNumber,
        side: side,
        movePlayedSan: movePlayedSan,
        fenBefore: fenBefore,
        bestMoveUci: bestMoveUci,
        rawScore: rawScore ?? this.rawScore,
        criticalityPercentile:
            criticalityPercentile ?? this.criticalityPercentile,
        breakdown: breakdown,
        gatesFired: gatesFired ?? this.gatesFired,
        timeResidual: timeResidual ?? this.timeResidual,
        verdict: verdict ?? this.verdict,
        timeSpentSec: timeSpentSec,
      );

  Map<String, dynamic> toJson() => {
        'ply': ply,
        'moveNumber': moveNumber,
        'side': side == Side.white ? 'white' : 'black',
        'movePlayedSan': movePlayedSan,
        'bestMoveUci': bestMoveUci,
        'rawScore': rawScore,
        'criticalityPercentile': criticalityPercentile,
        'breakdown': breakdown.toJson(),
        'gatesFired': gatesFired,
        'timeResidual': timeResidual,
        'verdict': verdict.name,
      };
}

/// A ply removed from scoring by a zero-out gate, retained so that a false
/// negative can be traced to the rule responsible.
class ZeroedPly {
  final int ply;
  final int moveNumber;
  final String movePlayedSan;
  final String reason;

  const ZeroedPly({
    required this.ply,
    required this.moveNumber,
    required this.movePlayedSan,
    required this.reason,
  });

  Map<String, dynamic> toJson() => {
        'ply': ply,
        'moveNumber': moveNumber,
        'movePlayedSan': movePlayedSan,
        'reason': reason,
      };

  @override
  String toString() => '$moveNumber. $movePlayedSan (ply $ply) → $reason';
}

/// Full result of Stage C.
class CriticalMomentReport {
  final List<CriticalMoment> moments;

  /// Every scored ply, ranked — `moments` is the top slice of this.
  final List<CriticalMoment> allScored;

  final List<ZeroedPly> zeroed;

  /// Mean time residual over top-quartile-criticality plies. Null when the
  /// regression was skipped. Negative = systematically under-thinking the
  /// moments that matter.
  final double? meanResidualTopQuartile;

  final bool regressionRan;

  const CriticalMomentReport({
    required this.moments,
    required this.allScored,
    required this.zeroed,
    this.meanResidualTopQuartile,
    this.regressionRan = false,
  });

  Map<String, dynamic> toJson() => {
        'moments': moments.map((m) => m.toJson()).toList(),
        'zeroed': zeroed.map((z) => z.toJson()).toList(),
        'meanResidualTopQuartile': meanResidualTopQuartile,
        'regressionRan': regressionRan,
      };
}
