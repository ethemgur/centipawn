import 'package:flutter_test/flutter_test.dart';
import 'package:centipawn/services/engine_types.dart';
import 'package:centipawn/services/uci_engine.dart';

import 'fake_uci_transport.dart';

const startFen = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';
const checkFen = '4k3/8/8/8/8/8/4r3/4K3 w - - 0 1';

void main() {
  group('handshake', () {
    test('sends the options the transport asks for, in order', () async {
      final t = FakeUciTransport(threads: 3, hashMb: 256);
      final engine = UciEngine(t);

      expect(await engine.ensureReady(), isTrue);
      expect(t.sent, [
        'uci',
        'setoption name Threads value 3',
        'setoption name Hash value 256',
        'setoption name MultiPV value 3',
        'ucinewgame',
        'isready',
      ]);
      expect(engine.isReady, isTrue);
    });

    test('web-style transport tuning is honoured', () async {
      final t = FakeUciTransport(threads: 1, hashMb: 32);
      await UciEngine(t).ensureReady();
      expect(t.sent, contains('setoption name Threads value 1'));
      expect(t.sent, contains('setoption name Hash value 32'));
    });

    test('concurrent callers share one load', () async {
      final t = FakeUciTransport();
      final engine = UciEngine(t);
      await Future.wait([
        engine.ensureReady(),
        engine.ensureReady(),
        engine.ensureReady(),
      ]);
      expect(t.startCalls, 1);
    });

    test('an unsupported platform never starts the transport', () async {
      final t = FakeUciTransport(isSupported: false);
      final engine = UciEngine(t);

      expect(engine.isSupported, isFalse);
      expect(await engine.ensureReady(), isFalse);
      expect(t.startCalls, 0);
      expect(engine.unavailableReason, isNotNull);
    });

    test('a failed load is sticky and carries its reason', () async {
      final t = FakeUciTransport(
        startError: const EngineUnavailable('wasm is not a WebAssembly module'),
      );
      final engine = UciEngine(t);

      expect(await engine.ensureReady(), isFalse);
      expect(engine.unavailableReason, contains('WebAssembly'));
      expect(await engine.ensureReady(), isFalse);
      // Does not retry an expensive load on every call.
      expect(t.startCalls, 1);
    });
  });

  group('score units — the 100x tripwire', () {
    // The streaming path reports pawns (the eval bar consumes them); the
    // MultiPV path reports raw centipawns (PvLine.normalisedCp is a centipawn
    // scale). Same input line, two units, on purpose.

    test('streaming reports pawns', () async {
      final t = FakeUciTransport();
      final engine = UciEngine(t);
      final seen = <PositionEvals>[];
      engine.evaluationStream.listen(seen.add);

      await engine.analyzePosition(startFen);
      await settle();
      t.emit('info depth 12 multipv 1 score cp 34 pv e2e4 e7e5');
      await settle();

      final evals = seen.where((e) => e.evals.isNotEmpty).toList();
      expect(evals, isNotEmpty);
      expect(evals.last.evals.first.scoreCp, closeTo(0.34, 1e-9));
      expect(evals.last.fen, startFen);
    });

    test('MultiPV reports raw centipawns', () async {
      final t = FakeUciTransport();
      final engine = UciEngine(t);

      final future = engine.runSearch(startFen, depth: 12, multiPv: 3);
      await settle();
      t.emit('info depth 12 multipv 1 score cp 34 pv e2e4 e7e5');
      t.emit('bestmove e2e4');
      final result = await future;

      expect(result.pvs.first.scoreCp, 34);
    });
  });

  group('info parsing', () {
    test('mate scores survive both paths', () async {
      final t = FakeUciTransport();
      final engine = UciEngine(t);

      final future = engine.runSearch(startFen, depth: 12);
      await settle();
      t.emit('info depth 12 multipv 1 score mate 3 pv d1h5 e8e7');
      t.emit('bestmove d1h5');
      final result = await future;

      expect(result.pvs.first.mateIn, 3);
      expect(result.pvs.first.normalisedCp, kMateSentinelCp - 3);
    });

    test('bound lines never reach bestByDepth', () async {
      final t = FakeUciTransport();
      final engine = UciEngine(t);

      final future = engine.runSearch(startFen, depth: 12);
      await settle();
      t.emit('info depth 8 multipv 1 score cp 50 upperbound pv d2d4');
      t.emit('info depth 9 multipv 1 score cp 20 lowerbound pv c2c4');
      t.emit('info depth 10 multipv 1 score cp 30 pv e2e4');
      t.emit('bestmove e2e4');
      final result = await future;

      expect(result.bestByDepth.containsKey(8), isFalse);
      expect(result.bestByDepth.containsKey(9), isFalse);
      expect(result.bestByDepth[10], 'e2e4');
    });

    test('only multipv 1 defines the best move at a depth', () async {
      final t = FakeUciTransport();
      final engine = UciEngine(t);

      final future = engine.runSearch(startFen, depth: 12, multiPv: 2);
      await settle();
      t.emit('info depth 10 multipv 1 score cp 30 pv e2e4');
      t.emit('info depth 10 multipv 2 score cp 10 pv d2d4');
      t.emit('bestmove e2e4');
      final result = await future;

      expect(result.bestByDepth[10], 'e2e4');
      expect(result.pvs, hasLength(2));
      expect(result.pvs[1].scoreCp, 10);
    });

    test('pvs come back sorted by multipv index', () async {
      final t = FakeUciTransport();
      final engine = UciEngine(t);

      final future = engine.runSearch(startFen, depth: 12, multiPv: 3);
      await settle();
      t.emit('info depth 10 multipv 3 score cp 5 pv c2c4');
      t.emit('info depth 10 multipv 1 score cp 30 pv e2e4');
      t.emit('info depth 10 multipv 2 score cp 10 pv d2d4');
      t.emit('bestmove e2e4');
      final result = await future;

      expect(result.pvs.map((p) => p.movesUci.first), ['e2e4', 'd2d4', 'c2c4']);
    });

    test('fills legal move count and check from dartchess, not the engine',
        () async {
      final t = FakeUciTransport();
      final engine = UciEngine(t);

      final future = engine.runSearch(checkFen, depth: 8);
      await settle();
      t.emit('info depth 8 multipv 1 score cp -900 pv e1d1');
      t.emit('bestmove e1d1');
      final result = await future;

      expect(result.inCheck, isTrue);
      expect(result.legalMoveCount, greaterThan(0));
      expect(result.fen, checkFen);
    });
  });

  group('live analysis width and depth', () {
    // Live analysis used to hardcode `MultiPV 1` and `go infinite`, which is
    // why the "Suggested lines" box only ever filled its first row, and why the
    // single-threaded wasm build kept a core pinned forever on one position.

    test('asks for the MultiPV it was given', () async {
      final t = FakeUciTransport();
      final engine = UciEngine(t);

      await engine.analyzePosition(startFen, multiPv: 3);

      expect(t.sent, contains('setoption name MultiPV value 3'));
    });

    test('bounds the search when a max depth is given', () async {
      final t = FakeUciTransport();
      final engine = UciEngine(t);

      await engine.analyzePosition(startFen, maxDepth: 16);

      expect(t.sent, contains('go depth 16'));
      expect(t.sent, isNot(contains('go infinite')));
    });

    test('searches until stopped when no max depth is given', () async {
      final t = FakeUciTransport();
      final engine = UciEngine(t);

      await engine.analyzePosition(startFen);

      expect(t.sent, contains('go infinite'));
    });
  });

  group('generation guard', () {
    test('a superseded position never emits evals', () async {
      const fenB = 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1';
      final t = FakeUciTransport();
      final engine = UciEngine(t);
      final seen = <PositionEvals>[];
      engine.evaluationStream.listen(seen.add);

      // Two positions in flight; the second supersedes the first.
      final a = engine.analyzePosition(startFen);
      final b = engine.analyzePosition(fenB);
      await Future.wait([a, b]);
      await settle();

      // A stale line arriving now must not be attributed to anything.
      t.emit('info depth 12 multipv 1 score cp 900 pv a2a3');
      await settle();

      final nonEmpty = seen.where((e) => e.evals.isNotEmpty);
      expect(nonEmpty.every((e) => e.fen == fenB), isTrue,
          reason: 'an eval was attributed to a superseded position');
    });

    test('each new position first clears with an empty batch', () async {
      final t = FakeUciTransport();
      final engine = UciEngine(t);
      final seen = <PositionEvals>[];
      engine.evaluationStream.listen(seen.add);

      await engine.analyzePosition(startFen);
      await settle();

      expect(seen.first.fen, startFen);
      expect(seen.first.evals, isEmpty,
          reason: 'must clear the previous position without claiming this one');
    });
  });

  group('depth-limited search', () {
    test('returns the last eval seen', () async {
      final t = FakeUciTransport();
      final engine = UciEngine(t);

      final future = engine.evaluatePosition(startFen, depth: 12);
      await settle();
      t.emit('info depth 11 multipv 1 score cp 20 pv e2e4');
      t.emit('info depth 12 multipv 1 score cp 34 pv e2e4');
      t.emit('bestmove e2e4');

      final eval = await future;
      expect(eval, isNotNull);
      expect(eval!.scoreCp, closeTo(0.34, 1e-9));
      expect(eval.depth, 12);
    });

    test('returns null rather than a fabricated 0.00 when nothing evaluated',
        () async {
      // CLAUDE.md: never substitute 0.00 — it reads as dead-equal and
      // fabricates huge swings on the surrounding moves.
      final t = FakeUciTransport();
      final engine = UciEngine(t);

      final future = engine.evaluatePosition(startFen, depth: 12);
      await settle();
      t.emit('bestmove e2e4'); // no info line at all
      expect(await future, isNull);
    });

    test('returns null when no engine can run', () async {
      final engine = UciEngine(FakeUciTransport(isSupported: false));
      expect(await engine.evaluatePosition(startFen), isNull);
    });

    test('a bestmove from stop does not resolve a pending search', () async {
      final t = FakeUciTransport();
      final engine = UciEngine(t);
      await engine.ensureReady();

      // A stray bestmove with no depth search outstanding must be ignored
      // rather than completing the next one prematurely.
      t.emit('bestmove x');
      await settle();

      final future = engine.evaluatePosition(startFen, depth: 12);
      await settle();
      t.emit('info depth 12 multipv 1 score cp 15 pv e2e4');
      t.emit('bestmove e2e4');
      expect((await future)!.scoreCp, closeTo(0.15, 1e-9));
    });
  });

  group('runSearch', () {
    test('serialises — the second search waits for the first', () async {
      final t = FakeUciTransport();
      final engine = UciEngine(t);
      await engine.ensureReady();
      t.clearSent();

      final first = engine.runSearch(startFen, depth: 10);
      final second = engine.runSearch(checkFen, depth: 10);
      await settle();

      expect(t.sent.where((c) => c.startsWith('position fen')), hasLength(1),
          reason: 'the second search started before the first finished');

      t.emit('info depth 10 multipv 1 score cp 30 pv e2e4');
      t.emit('bestmove e2e4');
      await first;
      await settle();

      expect(t.sent.where((c) => c.startsWith('position fen')), hasLength(2));
      t.emit('info depth 10 multipv 1 score cp -900 pv e1d1');
      t.emit('bestmove e1d1');
      await second;
    });

    test('one failure does not poison the rest of a sweep', () async {
      final t = FakeUciTransport();
      final engine = UciEngine(t);

      // An unparseable FEN throws inside the locked section.
      await expectLater(engine.runSearch('not-a-fen', depth: 8), throwsA(anything));

      final future = engine.runSearch(startFen, depth: 8);
      await settle();
      t.emit('info depth 8 multipv 1 score cp 12 pv e2e4');
      t.emit('bestmove e2e4');
      expect((await future).pvs.first.scoreCp, 12);
    });

    test('throws with the real reason when the engine cannot load', () async {
      final engine = UciEngine(FakeUciTransport(
        startError: const EngineUnavailable('worker script failed to load'),
      ));
      await expectLater(
        engine.runSearch(startFen),
        throwsA(isA<StateError>().having(
            (e) => e.message, 'message', contains('worker script'))),
      );
    });

    test('requests the MultiPV it was asked for', () async {
      final t = FakeUciTransport();
      final engine = UciEngine(t);

      final future = engine.runSearch(startFen, depth: 14, multiPv: 5);
      await settle();
      t.emit('info depth 14 multipv 1 score cp 20 pv e2e4');
      t.emit('bestmove e2e4');
      await future;

      expect(t.sent, contains('setoption name MultiPV value 5'));
      expect(t.sent, contains('go depth 14'));
    });
  });

  group('lifecycle', () {
    test('dispose tears down the transport', () async {
      final t = FakeUciTransport();
      final engine = UciEngine(t);
      await engine.ensureReady();
      await engine.dispose();
      expect(t.disposed, isTrue);
    });

    test('stop before the engine loads is a no-op, not a crash', () {
      final engine = UciEngine(FakeUciTransport());
      expect(engine.stop, returnsNormally);
    });
  });
}
