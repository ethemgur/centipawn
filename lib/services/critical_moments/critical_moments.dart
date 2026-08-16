import 'package:dartchess/dartchess.dart' show Side;
import '../../models/move_node.dart';
import '../engine_service.dart';
import 'analysed_game.dart';
import 'analyzer.dart';
import 'critical_types.dart';
import 'ply_builder.dart';
import 'repertoire_matcher.dart';
import 'scorer.dart';

export 'analysed_game.dart' show AnalysedGame;
export 'analyzer.dart' show AnalysisProgress, CriticalMomentAnalyzer, SearchCache;
export 'critical_types.dart';
export 'difficulty.dart' show DifficultyProvider, HeuristicDifficultyProvider;
export 'gates.dart' show DampConfig;
export 'ply_builder.dart' show PlyBuilder;
export 'repertoire_matcher.dart' show RepertoireMatcher;
export 'scorer.dart' show CriticalMomentScorer, ScoringConfig;

/// End-to-end entry point: PGN mainline in, ranked moments out.
///
/// The three stages stay independently usable — this only wires them together
/// for the common case.
class CriticalMoments {
  final EngineService engine;
  final ScoringConfig config;
  final RepertoireMatcher? repertoire;

  const CriticalMoments({
    required this.engine,
    this.config = const ScoringConfig(),
    this.repertoire,
  });

  /// Analyses [mainline] from [userSide]'s perspective.
  ///
  /// Requires a local engine — see [CriticalMomentAnalyzer.analyze].
  Future<CriticalMomentReport> run(
    List<MoveNode> mainline,
    Side userSide, {
    String initialFen = kStartFen,
    int incrementSec = 0,
    SearchCache? cache,
    void Function(AnalysisProgress)? onProgress,
  }) async {
    final plies = PlyBuilder.fromMainline(
      mainline,
      initialFen: initialFen,
      incrementSec: incrementSec,
      repertoire: repertoire,
    );

    final analyzer = CriticalMomentAnalyzer(engine: engine, cache: cache);
    await analyzer.analyze(plies, userSide, onProgress: onProgress);

    return CriticalMomentScorer(config: config).score(plies, userSide);
  }

  /// Stage C only, against already-analysed plies. Pure and fast — this is what
  /// weight tuning calls in a loop.
  static CriticalMomentReport scoreOnly(
    AnalysedGame game, {
    ScoringConfig config = const ScoringConfig(),
  }) =>
      CriticalMomentScorer(config: config).score(game.plies, game.userSide);
}
