import 'dart:async';
import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter_test/flutter_test.dart';
import 'package:centipawn/services/engine_service.dart';
import 'package:centipawn/services/critical_moments/analyzer.dart';
import 'package:centipawn/services/critical_moments/critical_types.dart';

import '../engine/fake_uci_transport.dart';
import 'fixtures.dart';

/// Answers every `go depth N` with a one-line result at that depth, so a whole
/// sweep completes without hand-scripting each ply.
///
/// `FakeUciTransport.send` only records what was sent — [lines] carries the
/// engine's *inbound* output, not the commands going out, so responding to a
/// specific outbound command needs overriding `send` rather than listening.
class _AutoAnsweringTransport extends FakeUciTransport {
  /// Builds the `info` line(s) to answer a `go depth N` with. Defaults to one
  /// flat line; reassign per test for a real spread.
  Iterable<String> Function(int depth) infoLines =
      (depth) => ['info depth $depth multipv 1 score cp 300 pv e2e4'];

  @override
  void send(String command) {
    super.send(command);
    if (!command.startsWith('go depth ')) return;
    final depth = int.parse(command.substring('go depth '.length));
    for (final line in infoLines(depth)) {
      scheduleMicrotask(() => emit(line));
    }
    scheduleMicrotask(() => emit('bestmove e2e4'));
  }
}

void main() {
  group('CriticalMomentAnalyzer honours the depth/MultiPV it is given', () {
    late _AutoAnsweringTransport transport;
    late EngineService engine;

    setUp(() {
      transport = _AutoAnsweringTransport();
      engine = EngineService.withTransport(transport);
    });

    test('Stage A sends the shallow depth and MultiPV it was passed',
        () async {
      // A single-ply game always clears the percentile flagging rule
      // (ceil(1 * 0.2) = 1, i.e. itself), so Stage B also runs here — this
      // only asserts that Stage A's own command went out correctly.
      final plies = [
        ply(ply: 0, fenBefore: startFen, deep: search(fen: startFen, pvs: [])),
      ];
      final analyzer = CriticalMomentAnalyzer(engine: engine);

      await analyzer.analyze(
        plies,
        Side.white,
        shallowDepth: 9,
        shallowMultiPv: 2,
      );

      expect(transport.sent, contains('go depth 9'));
      expect(transport.sent, contains('setoption name MultiPV value 2'));
    });

    test('Stage B sends the deep depth and MultiPV it was passed', () async {
      // A wide Stage A spread (300cp) clears the 15cp absolute-threshold gate
      // on its own, so this single-ply game is flagged for Stage B regardless
      // of the percentile rule.
      transport.infoLines = (depth) => [
            'info depth $depth multipv 1 score cp 300 pv e2e4',
            'info depth $depth multipv 2 score cp 0 pv d2d4',
          ];

      final plies = [
        ply(ply: 0, fenBefore: startFen, deep: search(fen: startFen, pvs: [])),
      ];
      final analyzer = CriticalMomentAnalyzer(engine: engine);

      await analyzer.analyze(
        plies,
        Side.white,
        shallowDepth: 9,
        shallowMultiPv: 2,
        deepDepth: 17,
        deepMultiPv: 4,
      );

      expect(transport.sent, contains('go depth 17'));
      expect(transport.sent, contains('setoption name MultiPV value 4'));
      expect(plies.single.deep, isNotNull,
          reason: 'a 300cp Stage A spread must flag the ply for Stage B');
    });

    test('defaults to the shared native constants when nothing is passed',
        () async {
      final plies = [
        ply(ply: 0, fenBefore: startFen, deep: search(fen: startFen, pvs: [])),
      ];
      final analyzer = CriticalMomentAnalyzer(engine: engine);

      await analyzer.analyze(plies, Side.white);

      expect(transport.sent, contains('go depth $kShallowDepth'));
      expect(transport.sent,
          contains('setoption name MultiPV value $kShallowMultiPv'));
    });
  });

  group('web constants', () {
    // These exist because a real browser run measured the cost: Stage B at
    // the native depth/width (20/5) took 9-22s *a ply* on the single-threaded
    // wasm build, and a sharp game ran the whole sweep to ~230s. Narrowing
    // MultiPV alone only got to ~180s; the depth cut is what got a real game
    // to ~62s (critical_types.dart has the full story). If either of these
    // needs to move, remeasure in a browser before changing it — do not
    // tighten them back toward the native values on a hunch.
    test('are strictly lighter than the native depths', () {
      expect(kShallowDepthWeb, lessThan(kShallowDepth));
      expect(kDeepDepthWeb, lessThan(kDeepDepth));
    });

    test('deep MultiPV stays wide enough for gates.dart to read pvs[2]', () {
      // The conversion-technique damp gate reads a 3rd line when present.
      // Narrower than 3 silently disables that check on web.
      expect(kDeepMultiPvWeb, greaterThanOrEqualTo(3));
    });

    test('pins the measured values so a change is deliberate', () {
      expect(kShallowDepthWeb, 12);
      expect(kDeepDepthWeb, 16);
      expect(kShallowMultiPvWeb, 3);
      expect(kDeepMultiPvWeb, 3);
    });
  });
}
