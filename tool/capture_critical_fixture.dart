// Freezes an analysed game (Stage A + B output) as a JSON fixture.
//
// Stage C is pure, so a fixture gives sub-second tests and weight sweeps over
// the whole scoring pipeline with no engine in the loop. Capture these early —
// it makes tuning iterative instead of painful.
//
// **Needs a real engine**, so it must run on a platform where the `stockfish`
// package works (desktop or mobile), not on web and not in a plain `dart run`
// without the plugin. Wire it to a debug menu item or a `flutter test
// integration_test` target rather than expecting `dart run` to work.
//
// Typical use from inside the app (e.g. a hidden debug action):
//
//   final json = await captureFixture(
//     engine: ref.read(engineProvider),
//     mainline: ref.read(moveTreeProvider).mainline,
//     userSide: Side.white,
//     label: 'game-01',
//   );
//   await File('test/critical_moments/data/game-01.json').writeAsString(json);

import 'package:dartchess/dartchess.dart' show Side;

import 'package:centipawn/models/move_node.dart';
import 'package:centipawn/services/engine_service.dart';
import 'package:centipawn/services/critical_moments/critical_moments.dart';

/// Runs Stage A + B over [mainline] and returns the encoded [AnalysedGame].
///
/// [incrementSec] should be the game's increment so time-spent figures are
/// right; [repertoire] marks book plies so they are skipped entirely.
Future<String> captureFixture({
  required EngineService engine,
  required List<MoveNode> mainline,
  required Side userSide,
  String? label,
  int incrementSec = 0,
  RepertoireMatcher? repertoire,
  void Function(AnalysisProgress)? onProgress,
}) async {
  final plies = PlyBuilder.fromMainline(
    mainline,
    incrementSec: incrementSec,
    repertoire: repertoire,
  );

  final analyzer = CriticalMomentAnalyzer(engine: engine);
  await analyzer.analyze(plies, userSide, onProgress: onProgress);

  return AnalysedGame(plies: plies, userSide: userSide, label: label).encode();
}
