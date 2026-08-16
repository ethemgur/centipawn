export 'move_evaluator.dart' show MoveQuality;

class EngineEvaluation {
  final double scoreCp; // Score in centipawns
  final int? mate;
  final List<String> pv; // Principal Variation moves
  final int depth;

  EngineEvaluation({required this.scoreCp, this.mate, this.pv = const [], this.depth = 0});
}

/// A batch of evaluations together with the FEN they were produced for.
///
/// Evaluations arrive asynchronously (streamed from Stockfish, awaited from the
/// Lichess cloud) while the user is free to keep moving through the game, so a
/// batch on its own says nothing about which position it describes. Carrying
/// [fen] alongside lets consumers discard results that belong to a position the
/// user has already left, instead of rendering them against the current board.
class PositionEvals {
  final String fen;
  final List<EngineEvaluation> evals;

  const PositionEvals(this.fen, this.evals);

  /// No evaluation available (nothing analysed yet, or the source came back
  /// empty). Never matches a real FEN, so it can't be mistaken for fresh data.
  static const PositionEvals none = PositionEvals('', []);

  bool get isEmpty => evals.isEmpty;
  bool get isNotEmpty => evals.isNotEmpty;

  /// True when this batch has results and they describe [currentFen].
  bool matches(String? currentFen) =>
      evals.isNotEmpty && currentFen != null && fen == currentFen;
}

/// Centipawn value standing in for a forced mate, so mate and cp scores can be
/// compared on one scale. Mate-in-1 is worth more than mate-in-10.
const int kMateSentinelCp = 10000;

/// One principal variation from a MultiPV search.
class PvLine {
  /// Full PV in UCI, best move first. Length varies with how deep the engine
  /// managed to fill the line.
  final List<String> movesUci;

  /// Score from the **side-to-move's** perspective, in centipawns. Meaningless
  /// when [mateIn] is set — use [normalisedCp] to compare lines.
  final int scoreCp;

  /// Signed distance to mate (positive = side to move mates), or null.
  final int? mateIn;

  const PvLine({required this.movesUci, required this.scoreCp, this.mateIn});

  bool get isMate => mateIn != null;

  String? get firstMoveUci => movesUci.isEmpty ? null : movesUci.first;

  /// Mate scores folded onto the centipawn scale so two lines can be
  /// subtracted. Without this, differencing a mate score against a cp score
  /// produces a number with no meaning.
  int get normalisedCp {
    final m = mateIn;
    if (m == null) return scoreCp;
    return m > 0 ? kMateSentinelCp - m : -kMateSentinelCp - m;
  }

  Map<String, dynamic> toJson() => {
        'movesUci': movesUci,
        'scoreCp': scoreCp,
        if (mateIn != null) 'mateIn': mateIn,
      };

  factory PvLine.fromJson(Map<String, dynamic> j) => PvLine(
        movesUci: (j['movesUci'] as List<dynamic>).cast<String>(),
        scoreCp: j['scoreCp'] as int,
        mateIn: j['mateIn'] as int?,
      );
}

/// Raw output of one engine search at one position.
///
/// [bestByDepth] is the part that is easy to lose: every completed
/// iterative-deepening iteration reports its own best move, and the depth at
/// which that stops changing is the signal for how hard the move is to find.
/// Capturing only the final depth throws that away and cannot be recovered
/// without searching again.
class SearchResult {
  final String fen;

  /// Depth actually reached (the last `info depth` seen), not the depth asked for.
  final int depth;

  /// Sorted best-first, length <= the MultiPV the search was run with.
  final List<PvLine> pvs;

  final int legalMoveCount;
  final bool inCheck;

  /// depth -> best move (UCI) at that depth, from `multipv 1` info lines.
  final Map<int, String> bestByDepth;

  const SearchResult({
    required this.fen,
    required this.depth,
    required this.pvs,
    required this.legalMoveCount,
    required this.inCheck,
    required this.bestByDepth,
  });

  bool get isEmpty => pvs.isEmpty;

  String? get bestMoveUci => pvs.isEmpty ? null : pvs.first.firstMoveUci;

  /// Gap between the best and second-best line on the normalised cp scale.
  /// Zero when there is no alternative to compare against.
  int get topTwoGapCp =>
      pvs.length < 2 ? 0 : pvs[0].normalisedCp - pvs[1].normalisedCp;

  Map<String, dynamic> toJson() => {
        'fen': fen,
        'depth': depth,
        'pvs': pvs.map((p) => p.toJson()).toList(),
        'legalMoveCount': legalMoveCount,
        'inCheck': inCheck,
        'bestByDepth':
            bestByDepth.map((k, v) => MapEntry(k.toString(), v)),
      };

  factory SearchResult.fromJson(Map<String, dynamic> j) => SearchResult(
        fen: j['fen'] as String,
        depth: j['depth'] as int,
        pvs: (j['pvs'] as List<dynamic>)
            .map((e) => PvLine.fromJson(e as Map<String, dynamic>))
            .toList(),
        legalMoveCount: j['legalMoveCount'] as int,
        inCheck: j['inCheck'] as bool,
        bestByDepth: (j['bestByDepth'] as Map<String, dynamic>)
            .map((k, v) => MapEntry(int.parse(k), v as String)),
      );
}
