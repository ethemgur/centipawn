import 'dart:convert';
import 'package:dartchess/dartchess.dart' show Side;
import 'critical_types.dart';

/// A game frozen after Stage A+B, for regression fixtures and offline tuning.
///
/// Deliberately free of any engine or Flutter import: Stage C is pure, so a
/// fixture plus the scorer must be runnable from a plain `dart run` with no
/// Stockfish and no Flutter binding. That is what makes weight tuning a
/// sub-second loop instead of a re-analysis.
class AnalysedGame {
  final List<PlyData> plies;
  final Side userSide;
  final String? label;

  const AnalysedGame({
    required this.plies,
    required this.userSide,
    this.label,
  });

  Map<String, dynamic> toJson() => {
        'userSide': userSide == Side.white ? 'white' : 'black',
        if (label != null) 'label': label,
        'plies': plies.map((p) => p.toJson()).toList(),
      };

  factory AnalysedGame.fromJson(Map<String, dynamic> j) => AnalysedGame(
        userSide: j['userSide'] == 'white' ? Side.white : Side.black,
        label: j['label'] as String?,
        plies: (j['plies'] as List<dynamic>)
            .map((e) => PlyData.fromJson(e as Map<String, dynamic>))
            .toList(),
      );

  String encode() => const JsonEncoder.withIndent('  ').convert(toJson());

  static AnalysedGame decode(String json) =>
      AnalysedGame.fromJson(jsonDecode(json) as Map<String, dynamic>);
}
