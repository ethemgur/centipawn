// Validation harness for critical-moment detection.
//
// Build this before tuning anything. Procedure: run on ~30 of your own games,
// take the top 5 moments each, hand-label whether each was actually a decision
// point, and iterate. Target >= 70% precision.
//
// The weights in the spec are reasoned, not fitted. `kDivergenceWeight` in
// particular is a guess, and it carries more load now that Maia is deferred.
// The difficulty sub-weights are unvalidated too. Your own games are the only
// ground truth for a tool built for yourself.
//
// Usage:
//   dart run tool/validate_critical_moments.dart \
//       --fixtures test/critical_moments/data \
//       --labels labels.json \
//       [--top 5] [--divergence-weight 0.6] [--difficulty-floor 0.25] \
//       [--no-damps] [--sweep divergence-weight:0.0,0.3,0.6,0.9,1.2]
//
// labels.json maps a fixture id to the plies that were genuinely decisions:
//   { "game-01": [24, 38, 57], "game-02": [12, 40] }

import 'dart:convert';
import 'dart:io';

// Stage C only, on purpose: these libraries pull in neither Flutter nor the
// engine, so this harness runs under a plain `dart run`.
import 'package:centipawn/services/critical_moments/analysed_game.dart';
import 'package:centipawn/services/critical_moments/critical_types.dart';
import 'package:centipawn/services/critical_moments/gates.dart';
import 'package:centipawn/services/critical_moments/scorer.dart';

void main(List<String> args) {
  final opts = _Options.parse(args);
  if (opts.help) {
    stdout.writeln(_usage);
    return;
  }

  final games = _loadFixtures(opts.fixturesDir);
  if (games.isEmpty) {
    stderr.writeln('No fixtures found in ${opts.fixturesDir}. '
        'Capture some with tool/capture_critical_fixture.dart first.');
    exitCode = 1;
    return;
  }

  final labels = _loadLabels(opts.labelsPath);
  if (labels.isEmpty) {
    stderr.writeln('No labels found at ${opts.labelsPath}; '
        'reporting rankings only.\n');
  }

  if (opts.sweep != null) {
    _runSweep(games, labels, opts);
    return;
  }

  final result = _evaluate(games, labels, opts.config, opts.top);
  _printReport(result, opts);
}

// ---------------------------------------------------------------------------

class _Evaluation {
  int truePositives = 0;
  int falsePositives = 0;
  int labelled = 0;
  int gamesScored = 0;
  int gamesWithLabels = 0;

  /// Gate name -> how many false positives carried that gate.
  final Map<String, int> falsePositiveGates = {};

  /// Zero-out reason -> how many labelled moments it swallowed.
  final Map<String, int> missedByGate = {};

  final List<String> lines = [];

  double get precision =>
      truePositives + falsePositives == 0
          ? 0
          : truePositives / (truePositives + falsePositives);

  double get recall => labelled == 0 ? 0 : truePositives / labelled;
}

_Evaluation _evaluate(
  Map<String, AnalysedGame> games,
  Map<String, Set<int>> labels,
  ScoringConfig config,
  int top,
) {
  final ev = _Evaluation();

  for (final entry in games.entries) {
    final id = entry.key;
    final game = entry.value;
    final report = CriticalMomentScorer(config: config).score(game.plies, game.userSide);
    ev.gamesScored++;

    final picks = report.allScored.take(top).toList();
    final truth = labels[id];

    ev.lines.add('── $id  (${report.allScored.length} scored, '
        '${report.zeroed.length} zeroed)');
    for (final m in picks) {
      final hit = truth == null
          ? ' '
          : truth.contains(m.ply)
              ? '✓'
              : '✗';
      ev.lines.add('   $hit  ${m.moveNumber}. ${m.movePlayedSan}  '
          'raw=${m.rawScore.toStringAsFixed(3)}  '
          'pct=${m.criticalityPercentile.toStringAsFixed(0)}  '
          '${m.breakdown}  '
          '${m.gatesFired.isEmpty ? '' : m.gatesFired.join(',')}  '
          '${m.verdict.name}');
    }

    if (truth == null) continue;
    ev.gamesWithLabels++;
    ev.labelled += truth.length;

    for (final m in picks) {
      if (truth.contains(m.ply)) {
        ev.truePositives++;
      } else {
        ev.falsePositives++;
        // Attribute the false positive to whatever damps let it through, so a
        // bad rule can be identified rather than guessed at.
        for (final g in m.gatesFired) {
          ev.falsePositiveGates.update(g, (v) => v + 1, ifAbsent: () => 1);
        }
        if (m.gatesFired.isEmpty) {
          ev.falsePositiveGates.update('(none)', (v) => v + 1,
              ifAbsent: () => 1);
        }
      }
    }

    // A labelled moment that a zero-out gate removed is the most damaging kind
    // of miss, and the gate log says exactly which rule is responsible.
    final pickedPlies = picks.map((m) => m.ply).toSet();
    for (final ply in truth) {
      if (pickedPlies.contains(ply)) continue;
      for (final z in report.zeroed) {
        if (z.ply == ply) {
          ev.missedByGate.update(z.reason, (v) => v + 1, ifAbsent: () => 1);
        }
      }
    }
  }
  return ev;
}

void _printReport(_Evaluation ev, _Options opts) {
  stdout.writeln(ev.lines.join('\n'));
  stdout.writeln('');
  stdout.writeln('═══ Summary ═══');
  stdout.writeln('games scored      : ${ev.gamesScored}');
  stdout.writeln('games with labels : ${ev.gamesWithLabels}');
  if (ev.labelled == 0) {
    stdout.writeln('\nNo labels: nothing to score precision against.');
    return;
  }
  stdout.writeln('labelled moments  : ${ev.labelled}');
  stdout.writeln('true positives    : ${ev.truePositives}');
  stdout.writeln('false positives   : ${ev.falsePositives}');
  stdout.writeln('precision         : '
      '${(ev.precision * 100).toStringAsFixed(1)}%  (target >= 70%)');
  stdout.writeln('recall            : '
      '${(ev.recall * 100).toStringAsFixed(1)}%');

  if (ev.falsePositiveGates.isNotEmpty) {
    stdout.writeln('\nfalse positives by damp gate:');
    final sorted = ev.falsePositiveGates.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    for (final e in sorted) {
      stdout.writeln('  ${e.key.padRight(24)} ${e.value}');
    }
  }
  if (ev.missedByGate.isNotEmpty) {
    stdout.writeln('\nlabelled moments swallowed by a zero-out gate:');
    final sorted = ev.missedByGate.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    for (final e in sorted) {
      stdout.writeln('  ${e.key.padRight(24)} ${e.value}');
    }
  }
}

void _runSweep(
  Map<String, AnalysedGame> games,
  Map<String, Set<int>> labels,
  _Options opts,
) {
  final (name, values) = opts.sweep!;
  stdout.writeln('Sweeping $name over $values\n');
  stdout.writeln('value      precision   recall');
  for (final v in values) {
    final config = switch (name) {
      'divergence-weight' => opts.config.copyWith(divergenceWeight: v),
      'difficulty-floor' => opts.config.copyWith(difficultyFloor: v),
      'raw-cap' => opts.config.copyWith(rawCap: v),
      'spread-cap' => opts.config.copyWith(spreadCapCp: v.round()),
      _ => throw ArgumentError('Unknown sweep parameter: $name'),
    };
    final ev = _evaluate(games, labels, config, opts.top);
    stdout.writeln('${v.toStringAsFixed(3).padRight(10)} '
        '${(ev.precision * 100).toStringAsFixed(1).padLeft(8)}%   '
        '${(ev.recall * 100).toStringAsFixed(1).padLeft(6)}%');
  }
}

// ---------------------------------------------------------------------------

Map<String, AnalysedGame> _loadFixtures(String dir) {
  final directory = Directory(dir);
  if (!directory.existsSync()) return {};
  final out = <String, AnalysedGame>{};
  for (final file in directory.listSync().whereType<File>()) {
    if (!file.path.endsWith('.json')) continue;
    final id = file.uri.pathSegments.last.replaceAll('.json', '');
    try {
      out[id] = AnalysedGame.decode(file.readAsStringSync());
    } catch (e) {
      stderr.writeln('Skipping ${file.path}: $e');
    }
  }
  return out;
}

Map<String, Set<int>> _loadLabels(String path) {
  final file = File(path);
  if (!file.existsSync()) return {};
  final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  return json.map((k, v) =>
      MapEntry(k, (v as List<dynamic>).map((e) => e as int).toSet()));
}

class _Options {
  final String fixturesDir;
  final String labelsPath;
  final int top;
  final ScoringConfig config;
  final (String, List<double>)? sweep;
  final bool help;

  const _Options({
    required this.fixturesDir,
    required this.labelsPath,
    required this.top,
    required this.config,
    this.sweep,
    this.help = false,
  });

  static _Options parse(List<String> args) {
    String fixtures = 'test/critical_moments/data';
    String labels = 'labels.json';
    int top = 5;
    double divergenceWeight = kDivergenceWeight;
    double difficultyFloor = kDifficultyFloor;
    bool damps = true;
    (String, List<double>)? sweep;
    bool help = false;

    for (int i = 0; i < args.length; i++) {
      switch (args[i]) {
        case '--help' || '-h':
          help = true;
        case '--fixtures':
          fixtures = args[++i];
        case '--labels':
          labels = args[++i];
        case '--top':
          top = int.parse(args[++i]);
        case '--divergence-weight':
          divergenceWeight = double.parse(args[++i]);
        case '--difficulty-floor':
          difficultyFloor = double.parse(args[++i]);
        case '--no-damps':
          damps = false;
        case '--sweep':
          final spec = args[++i].split(':');
          sweep = (spec[0], spec[1].split(',').map(double.parse).toList());
      }
    }

    return _Options(
      fixturesDir: fixtures,
      labelsPath: labels,
      top: top,
      sweep: sweep,
      help: help,
      config: ScoringConfig(
        divergenceWeight: divergenceWeight,
        difficultyFloor: difficultyFloor,
        damps: damps ? DampConfig.all : DampConfig.none,
        // The harness always looks at a fixed top-N rather than the adaptive
        // report size, so precision is comparable across games.
        maxMoments: 1000,
        reportFraction: 1.0,
      ),
    );
  }
}

const _usage = '''
validate_critical_moments — precision/recall for critical-moment detection

  --fixtures <dir>            directory of AnalysedGame JSON (default test/critical_moments/data)
  --labels <file>             hand labels, {"gameId": [ply, ...]} (default labels.json)
  --top <n>                   moments to take per game (default 5)
  --divergence-weight <x>     override kDivergenceWeight
  --difficulty-floor <x>      override kDifficultyFloor
  --no-damps                  disable all damp gates, to see the raw ranking
  --sweep <name>:<v1,v2,...>  sweep one weight; name is one of
                              divergence-weight | difficulty-floor | raw-cap | spread-cap
''';
