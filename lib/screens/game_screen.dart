import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show DisplayFeatureType;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:chessground/chessground.dart' show Shape;
import 'package:dartchess/dartchess.dart';
import '../theme.dart';
import '../models/game_entry.dart';
import '../models/move_node.dart';
import '../providers/study_provider.dart';
import '../services/engine_types.dart';
import '../services/critical_moments/critical_moments.dart'
    show CriticalMoment, TimeVerdict;
import '../services/move_evaluator.dart';
import '../widgets/chess_board.dart';
import '../widgets/study_notation.dart';
import '../widgets/eval_bar.dart';
import '../widgets/eval_chart.dart';
import '../widgets/responsive_layout.dart';
import '../widgets/edit_game_metadata_dialog.dart';
import '../services/pgn_parser.dart';

enum _AppBarAction { analyse, export }


int _evalCpGs(EngineEvaluation e) {
  if (e.mate != null) return e.mate! > 0 ? 10000 : -10000;
  return (e.scoreCp * 100).round();
}

List<EngineEvaluation> _filterByWinProbGs(List<EngineEvaluation> evals) {
  if (evals.length <= 1) return evals;
  final bestWp = MoveEvaluator.cpToWinProb(_evalCpGs(evals.first));
  return [
    evals.first,
    ...evals.skip(1).where(
          (e) => bestWp - MoveEvaluator.cpToWinProb(_evalCpGs(e)) <= 10.0,
        ),
  ];
}

IconData timeControlIcon(String tc) {
  switch (tc.toLowerCase()) {
    case 'bullet': return Icons.bolt;
    case 'blitz': return Icons.whatshot;
    case 'rapid': return Icons.speed;
    case 'classical': return Icons.hourglass_bottom;
    default: return Icons.timer_outlined;
  }
}

class GameScreen extends ConsumerWidget {
  final GameEntry game;

  const GameScreen({super.key, required this.game});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen<ReviewProgress>(reviewProvider, (previous, next) {
      if (!next.isRunning && next.isCompleted && (previous?.isRunning ?? false)) {
        final skipped = next.unevaluatedMoves;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              skipped == 0
                  ? 'Analysis complete!'
                  : 'Analysis complete — $skipped '
                      '${skipped == 1 ? 'position' : 'positions'} '
                      'could not be evaluated',
            ),
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 4),
          ),
        );
      }
    });

    return Scaffold(
      backgroundColor: AppColors.scaffoldBg,
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Consumer(
          builder: (context, ref, child) {
            final currentGame = ref.watch(selectedGameProvider) ?? game;

            return InkWell(
              onTap: () => showEditGameMetadataDialog(context, ref, currentGame),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          currentGame.title,
                          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (currentGame.timeControl.isNotEmpty) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.blue.shade100,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(timeControlIcon(currentGame.timeControl), size: 10, color: Colors.blue.shade700),
                              const SizedBox(width: 3),
                              Text(
                                currentGame.timeControl,
                                style: TextStyle(fontSize: 10, color: Colors.blue.shade700),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                  if (currentGame.event.isNotEmpty)
                    Text(
                      currentGame.event,
                      style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            );
          },
        ),
        actions: [
          Consumer(
            builder: (context, ref, _) {
              final tree = ref.watch(moveTreeProvider);
              final currentGame = ref.watch(selectedGameProvider) ?? game;
              final reviewProgress = ref.watch(reviewProvider);
              final analysisLabel = reviewProgress.isCompleted
                  ? 'Re-analyse game'
                  : 'Analyse game';
              return PopupMenuButton<_AppBarAction>(
                icon: const Icon(Icons.more_vert),
                onSelected: (action) {
                  switch (action) {
                    case _AppBarAction.analyse:
                      // Review first (cloud-backed, quick), then the
                      // critical-moment pass, which needs the local engine and
                      // is much heavier.
                      () async {
                        await ref.read(reviewProvider.notifier).startReview();
                        await ref.read(criticalMomentsProvider.notifier).run();
                      }();
                    case _AppBarAction.export:
                      final shapes = ref
                          .read(customShapesProvider.notifier)
                          .shapesForGame(currentGame.id);
                      showDialog(
                        context: context,
                        builder: (_) => _ExportPgnDialog(
                          tree: tree,
                          game: currentGame,
                          shapes: shapes,
                        ),
                      );
                  }
                },
                itemBuilder: (_) => [
                  PopupMenuItem(
                    value: _AppBarAction.analyse,
                    child: Row(
                      children: [
                        Icon(
                          reviewProgress.isCompleted
                              ? Icons.refresh
                              : Icons.analytics_outlined,
                          size: 18,
                          color: AppColors.textSecondary,
                        ),
                        const SizedBox(width: 12),
                        Text(analysisLabel),
                      ],
                    ),
                  ),
                  PopupMenuItem(
                    value: _AppBarAction.export,
                    child: const Row(
                      children: [
                        Icon(Icons.download_outlined, size: 18,
                            color: AppColors.textSecondary),
                        SizedBox(width: 12),
                        Text('Export PGN'),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        ],
      ),
      body: Stack(
        children: [
          _GameBody(isFoldFlexMode: _isFoldFlexMode(context)),
          const _ReviewProgressToast(),
        ],
      ),
      bottomNavigationBar: _isFoldFlexMode(context) ? null : const _GameBottomBar(),
    );
  }

  static bool _isFoldFlexMode(BuildContext context) {
    final features = MediaQuery.of(context).displayFeatures;
    return features.any((f) =>
        (f.type == DisplayFeatureType.hinge || f.type == DisplayFeatureType.fold) &&
        f.bounds.width > f.bounds.height);
  }
}

class _GameBody extends ConsumerWidget {
  final bool isFoldFlexMode;
  const _GameBody({this.isFoldFlexMode = false});

  /// Minimum width-to-height ratio of the body before the 3-column layout is
  /// worth using. Each column only gets a third of the width, so on a square
  /// or portrait-ish viewport (a resized browser window, a tablet) that leaves
  /// a cramped board — those get the 2-column board/notation split instead.
  static const double _threeColumnMinAspect = 1.5;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Fold flex mode keeps the existing top/bottom pane layout.
    if (isFoldFlexMode) return _buildStackedLayout(context, ref);

    // Measure the actual body box (excludes app bar and bottom nav) rather
    // than the raw screen orientation: a 1000×1000 browser window counts as
    // "landscape" but is nowhere near wide enough for three columns.
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final height = constraints.maxHeight;
        final isWide =
            height > 0 && width / height >= _threeColumnMinAspect;

        if (isWide) {
          return _buildLandscapeLayout(context, ref, constraints);
        }
        // Keep the board (and both player bars) inside the viewport instead of
        // letting a 60%-of-width board push the lower bar off-screen.
        return _buildStackedLayout(
          context,
          ref,
          maxBoardSize: height > 140 ? height - 60 : null,
        );
      },
    );
  }

  /// Board (plus chart/toolbars) alongside the notation on wide-enough
  /// screens, stacked vertically on phones — see [ResponsiveLayout].
  Widget _buildStackedLayout(
    BuildContext context,
    WidgetRef ref, {
    double? maxBoardSize,
  }) {
    return ResponsiveLayout(
      boardWidget: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const _PlayerBar(isTop: true),
          _BoardWithEval(maxSize: maxBoardSize),
          const _PlayerBar(isTop: false),
          if (!isFoldFlexMode) const EvalChart(),
          if (!isFoldFlexMode) _buildBoardToolbar(context, ref),
          if (!isFoldFlexMode) const _BoardEditToolbar(),
          // Engine suggested lines sit below the toolbar
          if (!isFoldFlexMode) const _EngineAnalysisBox(),
              const _CriticalMomentsBox(),
          if (!isFoldFlexMode) const _SectionDivider(),
        ],
      ),
      notationWidget: const _NotationPanel(),
      foldControlsWidget: isFoldFlexMode ? _buildFoldControls(context, ref) : null,
    );
  }

  Widget _buildLandscapeLayout(
      BuildContext context, WidgetRef ref, BoxConstraints constraints) {
    // Constraints come from the Scaffold body, not an estimate — this
    // eliminates the overflow caused by AppBar/nav rounding.
    final availableWidth = constraints.maxWidth;
    final availableHeight = constraints.maxHeight;

    // Equal thirds minus the 2 one-pixel dividers.
    final colWidth = (availableWidth - 2) / 3;

    // Board must fit both the column width (minus the 24 px eval-bar strip)
    // and the column height (minus two player bars, measured at 30 px each).
    final boardSize = math.max(
      80.0,
      math.min(colWidth - 24, availableHeight - 30.0 * 2),
    );

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ── Left column: eval chart → spacer → toolbar → color picker → engine lines ──
        SizedBox(
          width: colWidth,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const EvalChart(),
              const Spacer(),
              _buildBoardToolbar(context, ref),
              const _BoardEditToolbar(),
              const _EngineAnalysisBox(),
              const _CriticalMomentsBox(),
            ],
          ),
        ),
        const VerticalDivider(width: 1, thickness: 1, color: AppColors.divider),
        // ── Center column: player bar → board → player bar ──
        SizedBox(
          width: colWidth,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const _PlayerBar(isTop: true),
              _BoardWithEval(forcedSize: boardSize),
              const _PlayerBar(isTop: false),
            ],
          ),
        ),
        const VerticalDivider(width: 1, thickness: 1, color: AppColors.divider),
        // ── Right column: notation (Expanded takes the exact remainder) ──
        Expanded(child: _NotationPanel()),
      ],
    );
  }

  Widget _buildFoldControls(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(activeNodeProvider.notifier);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const EvalChart(),
        _buildBoardToolbar(context, ref),
        const _BoardEditToolbar(),
        const _EngineAnalysisBox(),
              const _CriticalMomentsBox(),
        Builder(
          builder: (context) {
            final bottomInset = MediaQuery.of(context).padding.bottom;
            return Container(
              height: 64 + bottomInset,
              decoration: const BoxDecoration(
                color: AppColors.scaffoldBg,
                border: Border(top: BorderSide(color: AppColors.divider)),
              ),
              child: Padding(
                padding: EdgeInsets.only(bottom: bottomInset),
                child: Row(
                  children: [
                    Expanded(
                      child: _RepeatNavButton(
                        onAction: notifier.goBack,
                        icon: Icons.chevron_left,
                        label: 'Back',
                      ),
                    ),
                    Expanded(
                      child: _RepeatNavButton(
                        onAction: notifier.goForward,
                        icon: Icons.chevron_right,
                        label: 'Next',
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ],
    );
  }

  Widget _buildBoardToolbar(BuildContext context, WidgetRef ref) {
    final engineOn = ref.watch(engineRunningProvider);
    final threatOn = ref.watch(showThreatArrowProvider);

    return Container(
      color: AppColors.scaffoldBg,
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton(
            icon: const Icon(Icons.flip_camera_android_outlined, size: 20),
            color: AppColors.textSecondary,
            onPressed: () {
              ref.read(boardFlippedProvider.notifier).toggle();
            },
          ),
          IconButton(
            icon: Icon(
              engineOn ? Icons.memory : Icons.memory_outlined,
              size: 20,
              color: engineOn ? AppColors.primary : AppColors.textSecondary,
            ),
            onPressed: () {
              ref.read(engineRunningProvider.notifier).toggle();
            },
          ),
          Tooltip(
            message: threatOn
                ? 'Hide opponent response arrow'
                : 'Show opponent response arrow (red)',
            child: IconButton(
              icon: Icon(
                Icons.gps_fixed,
                size: 20,
                color: threatOn ? Colors.red.shade600 : AppColors.textSecondary,
              ),
              onPressed: () {
                ref.read(showThreatArrowProvider.notifier).toggle();
              },
            ),
          ),
          // ── Board drawing toggle ─────────────────────────────────────────
          Consumer(
            builder: (context, ref, _) {
              final editOn = ref.watch(boardEditModeProvider);
              return IconButton(
                icon: Icon(
                  Icons.edit_outlined,
                  size: 20,
                  color: editOn ? AppColors.primary : AppColors.textSecondary,
                ),
                tooltip: editOn ? 'Exit drawing mode' : 'Draw on board',
                onPressed: () {
                  ref.read(boardEditModeProvider.notifier).setMode(!editOn);
                },
              );
            },
          ),
        ],
      ),
    );
  }
}

class _SectionDivider extends StatelessWidget {
  const _SectionDivider();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 1,
      decoration: BoxDecoration(
        color: AppColors.divider,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 6,
            offset: const Offset(0, 3),
          ),
        ],
      ),
    );
  }
}

class _EngineAnalysisBox extends ConsumerStatefulWidget {
  const _EngineAnalysisBox();

  @override
  ConsumerState<_EngineAnalysisBox> createState() => _EngineAnalysisBoxState();
}

class _EngineAnalysisBoxState extends ConsumerState<_EngineAnalysisBox> {
  bool _expanded = true;

  static const _startFen =
      'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';

  /// Convert a list of UCI moves (e.g. ["e2e4", "g8f6"]) to SAN strings
  /// starting from [fen], using dartchess for move validation and SAN generation.
  List<String> _pvToSan(String fen, List<String> pv) {
    Position pos;
    try {
      pos = Chess.fromSetup(Setup.parseFen(fen));
    } catch (_) {
      return [];
    }

    final result = <String>[];
    for (final uci in pv) {
      if (uci.length < 4) break;

      final from = Square.fromName(uci.substring(0, 2));
      final to = Square.fromName(uci.substring(2, 4));

      Role? promo;
      if (uci.length >= 5) {
        promo = switch (uci[4]) {
          'q' => Role.queen,
          'r' => Role.rook,
          'b' => Role.bishop,
          'n' => Role.knight,
          _ => null,
        };
      }

      final move = NormalMove(from: from, to: to, promotion: promo);

      // Stop if the move is not legal in this position.
      if (!pos.isLegal(move)) break;

      final (newPos, san) = pos.makeSan(move);
      result.add(san);
      pos = newPos;
    }
    return result;
  }

  /// Build a PGN-style line string with move numbers from a list of SAN moves
  /// starting at [fen].
  String _formatPvLine(String fen, List<String> sanMoves) {
    if (sanMoves.isEmpty) return '';
    final parts = fen.split(' ');
    bool isBlack = parts.length > 1 && parts[1] == 'b';
    int moveNum = parts.length > 5 ? (int.tryParse(parts[5]) ?? 1) : 1;

    final buf = StringBuffer();
    for (int i = 0; i < sanMoves.length; i++) {
      if (i > 0) buf.write(' ');
      if (!isBlack) {
        buf.write('$moveNum. ');
      } else if (i == 0) {
        buf.write('$moveNum... ');
      }
      buf.write(_formatSan(sanMoves[i]));
      if (isBlack) moveNum++;
      isBlack = !isBlack;
    }
    return buf.toString();
  }

  String _formatSan(String san) => san
      .replaceAll('K', '♔')
      .replaceAll('Q', '♕')
      .replaceAll('R', '♖')
      .replaceAll('B', '♗')
      .replaceAll('N', '♘');

  @override
  Widget build(BuildContext context) {
    final liveEvals = ref.watch(combinedEvalProvider);
    final isRunning = ref.watch(engineRunningProvider);
    final activeNode = ref.watch(activeNodeProvider);
    final isExpanded = _expanded;

    if (!isRunning) {
      return const SizedBox();
    }

    final evals = _filterByWinProbGs(liveEvals);
    final fen = activeNode?.fen ?? _startFen;
    final isBlackTurn = activeNode != null && activeNode.fen.contains(' b ');

    // Always render exactly 3 rows so the layout doesn't shift when fewer
    // alternatives are available (e.g. only 1 legal move exists).
    const kRowHeight = 28.0;
    final rows = List.generate(3, (i) {
      if (i >= evals.length) {
        return const SizedBox(height: kRowHeight);
      }
      final eval = evals[i];
      double score = eval.scoreCp;
      int? mate = eval.mate;
      if (isBlackTurn) {
        score = -score;
        if (mate != null) mate = -mate;
      }

      final scoreStr = mate != null
          ? '${mate >= 0 ? '+' : '-'}M${mate.abs()}'
          : '${score >= 0 ? '+' : ''}${score.toStringAsFixed(1)}';

      final sanMoves = _pvToSan(fen, eval.pv);
      final pvStr = _formatPvLine(fen, sanMoves);
      final isPositive = mate != null ? mate >= 0 : score >= 0;
      final pillBg = isPositive ? Colors.white : const Color(0xFF2E2E2E);
      final pillFg = isPositive ? const Color(0xFF1A1A1A) : Colors.white;

      return SizedBox(
        height: kRowHeight,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: pillBg,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: isPositive ? const Color(0xFFD0D0D0) : const Color(0xFF2E2E2E),
                ),
              ),
              child: Text(
                scoreStr,
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 11,
                  color: pillFg,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                pvStr,
                style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      );
    });

    return Container(
      color: AppColors.scaffoldBg,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Collapse/expand header
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Row(
                children: [
                  const Icon(Icons.memory, size: 13, color: AppColors.textSecondary),
                  const SizedBox(width: 5),
                  const Text(
                    'Suggested lines',
                    style: TextStyle(fontSize: 11, color: AppColors.textSecondary),
                  ),
                  if (evals.isNotEmpty && evals.first.depth > 0) ...[
                    const SizedBox(width: 6),
                    Text(
                      'depth ${evals.first.depth > 30 ? '30+' : evals.first.depth}',
                      style: const TextStyle(fontSize: 10, color: AppColors.textSecondary),
                    ),
                  ],
                  const Spacer(),
                  Icon(
                    isExpanded ? Icons.expand_less : Icons.expand_more,
                    size: 16,
                    color: AppColors.textSecondary,
                  ),
                ],
              ),
            ),
          ),
          if (isExpanded)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: rows,
              ),
            ),
        ],
      ),
    );
  }
}

/// The top critical moments, or the reason there aren't any to show.
///
/// Separate from `_EngineAnalysisBox`: that one describes the position in front
/// of you, this one describes the game as a whole.
class _CriticalMomentsBox extends ConsumerWidget {
  const _CriticalMomentsBox();

  static const _rowHeight = 30.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(criticalMomentsProvider);

    if (state.isRunning) {
      return _shell(
        context,
        subtitle: state.stage == 'deep' ? 'deep pass' : 'scanning',
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: LinearProgressIndicator(
            value: state.fraction == 0 ? null : state.fraction,
            minHeight: 3,
            backgroundColor: AppColors.divider,
          ),
        ),
      );
    }

    if (state.unavailableReason != null) {
      return _shell(
        context,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
          child: Text(
            state.unavailableReason!,
            style: const TextStyle(fontSize: 11, color: AppColors.textSecondary),
          ),
        ),
      );
    }

    final report = state.report;
    if (report == null) return const SizedBox.shrink();

    if (report.moments.isEmpty) {
      return _shell(
        context,
        child: const Padding(
          padding: EdgeInsets.fromLTRB(8, 0, 8, 8),
          child: Text(
            'No decision points stood out — every move was forced, book, or '
            'already decided.',
            style: TextStyle(fontSize: 11, color: AppColors.textSecondary),
          ),
        ),
      );
    }

    final side = state.analysedSide == Side.black ? 'Black' : 'White';
    // Web searches shallower than native, so results are noisier. Say which
    // depths produced this report rather than letting the two pass for each
    // other.
    final depths = state.isReducedDepth
        ? ' · depth ${state.shallowDepth}/${state.deepDepth}'
        : '';

    return _shell(
      context,
      subtitle: 'as $side$depths',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final m in report.moments) _row(context, ref, m),
        ],
      ),
    );
  }

  Widget _shell(BuildContext context,
      {required Widget child, String? subtitle}) {
    return Container(
      color: AppColors.scaffoldBg,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              children: [
                const Icon(Icons.crisis_alert,
                    size: 13, color: AppColors.textSecondary),
                const SizedBox(width: 5),
                const Text(
                  'Critical moments',
                  style:
                      TextStyle(fontSize: 11, color: AppColors.textSecondary),
                ),
                if (subtitle != null) ...[
                  const SizedBox(width: 6),
                  Text(
                    subtitle,
                    style: const TextStyle(
                        fontSize: 10, color: AppColors.textSecondary),
                  ),
                ],
              ],
            ),
          ),
          child,
        ],
      ),
    );
  }

  Widget _row(BuildContext context, WidgetRef ref, CriticalMoment m) {
    final verdict = _verdictLabel(m.verdict);

    return SizedBox(
      height: _rowHeight,
      child: InkWell(
        onTap: () => _jumpTo(ref, m.ply),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: [
              SizedBox(
                width: 52,
                child: Text(
                  '${m.moveNumber}${m.side == Side.white ? '.' : '...'} '
                  '${m.movePlayedSan}',
                  style: const TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w600),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 6),
              // Criticality, not eval loss — a moment can rank high on a move
              // that was played correctly.
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  '${m.criticalityPercentile.round()}',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    color: AppColors.primary,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              if (verdict != null)
                Expanded(
                  child: Text(
                    verdict.$1,
                    style: TextStyle(fontSize: 10, color: verdict.$2),
                    overflow: TextOverflow.ellipsis,
                  ),
                )
              else
                const Spacer(),
              Icon(Icons.chevron_right,
                  size: 14, color: AppColors.textSecondary),
            ],
          ),
        ),
      ),
    );
  }

  static (String, Color)? _verdictLabel(TimeVerdict v) => switch (v) {
        TimeVerdict.blindSpot => ('moved fast here', Colors.red.shade600),
        TimeVerdict.wasted => ('long think', Colors.orange.shade700),
        TimeVerdict.productiveThink =>
          ('thought, then banked it', Colors.green.shade700),
        TimeVerdict.normal => null,
      };

  /// Walks the mainline to [ply] and selects that node.
  void _jumpTo(WidgetRef ref, int ply) {
    final mainline = ref.read(moveTreeProvider).mainline;
    if (ply < 0 || ply >= mainline.length) return;
    ref.read(activeNodeProvider.notifier).setNode(mainline[ply]);
  }
}

class _BoardWithEval extends ConsumerWidget {
  /// When provided (landscape 3-col layout), skips LayoutBuilder sizing.
  final double? forcedSize;

  /// Upper bound on the board's edge when sizing from the available width —
  /// used to keep a wide board from growing taller than the viewport.
  final double? maxSize;

  const _BoardWithEval({this.forcedSize, this.maxSize});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final liveEvals = ref.watch(combinedEvalProvider);
    final activeNode = ref.watch(activeNodeProvider);
    final isRunning = ref.watch(engineRunningProvider);
    final isFlipped = ref.watch(boardFlippedProvider);

    // Seed from the node's stored analysis so the bar never jumps through
    // zero while the engine is warming up for the new position.
    double evaluation = activeNode?.evaluation ?? 0.0;
    int? mate = activeNode?.mate;

    // combinedEvalProvider only yields evals matching this position's FEN, so
    // the bar can never flicker to the wrong side during the gap where
    // activeNode has updated but a source still carries the previous position.
    if (isRunning && liveEvals.isNotEmpty) {
      final eval = liveEvals.first;
      evaluation = eval.scoreCp;
      mate = eval.mate;

      final isBlackToMove = activeNode != null && activeNode.fen.contains(' b ');

      if (mate == 0) {
        evaluation = isBlackToMove ? 100.0 : -100.0;
      } else {
        if (isBlackToMove) {
          evaluation = -evaluation;
          if (mate != null) mate = -mate;
        }
      }
    }

    // Landscape 3-col layout passes an exact size — skip LayoutBuilder.
    if (forcedSize != null) {
      final s = forcedSize!;
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 24, height: s, child: EvalBar(evaluation: evaluation, mate: mate, isFlipped: isFlipped)),
          SizedBox(width: s, height: s, child: const ChessBoard()),
        ],
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        var boardSize = constraints.maxWidth - 24;
        if (maxSize != null && boardSize > maxSize!) {
          boardSize = math.max(80.0, maxSize!);
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              width: 24,
              height: boardSize,
              child: EvalBar(evaluation: evaluation, mate: mate, isFlipped: isFlipped),
            ),
            SizedBox(
              width: boardSize,
              height: boardSize,
              child: const ChessBoard(),
            ),
          ],
        );
      },
    );
  }
}

class _NotationPanel extends ConsumerStatefulWidget {
  const _NotationPanel();

  @override
  ConsumerState<_NotationPanel> createState() => _NotationPanelState();
}

class _NotationPanelState extends ConsumerState<_NotationPanel> {
  final TextEditingController _pgnController = TextEditingController();

  @override
  void dispose() {
    _pgnController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tree = ref.watch(moveTreeProvider);
    
    if (tree.mainline.isEmpty) {
      return Expanded(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            children: [
              Expanded(
                child: TextField(
                  controller: _pgnController,
                  maxLines: null,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    hintText: 'Make a move on the board to start, or paste PGN text here...',
                    filled: true,
                    fillColor: Colors.white,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: Colors.white,
                ),
                onPressed: () async {
                  final raw = _pgnController.text.trim();
                  if (raw.isEmpty) return;

                  // Parse into a tree + headers, then merge into the current
                  // game's row (preserving the same id) and persist.
                  final tree = PgnParser.parsePgn(raw);
                  final h = PgnParser.parseHeaders(raw);
                  final tc = PgnParser.classifyTimeControl(h['TimeControl']);

                  ref.read(moveTreeProvider.notifier).setTree(tree);
                  ref.invalidate(activeNodeProvider);

                  final currentGame = ref.read(selectedGameProvider);
                  if (currentGame != null) {
                    final updated = currentGame.copyWith(
                      white: h['White']?.isNotEmpty == true ? h['White']! : currentGame.white,
                      black: h['Black']?.isNotEmpty == true ? h['Black']! : currentGame.black,
                      event: h['Event']?.isNotEmpty == true ? h['Event']! : currentGame.event,
                      result: h['Result']?.isNotEmpty == true ? h['Result']! : currentGame.result,
                      date: h['Date']?.isNotEmpty == true ? h['Date']! : currentGame.date,
                      year: h['Date']?.split('.').first.isNotEmpty == true
                          ? h['Date']!.split('.').first
                          : currentGame.year,
                      site: h['Site']?.isNotEmpty == true ? h['Site']! : currentGame.site,
                      round: h['Round']?.isNotEmpty == true ? h['Round']! : currentGame.round,
                      whiteElo: h['WhiteElo']?.isNotEmpty == true ? h['WhiteElo']! : currentGame.whiteElo,
                      blackElo: h['BlackElo']?.isNotEmpty == true ? h['BlackElo']! : currentGame.blackElo,
                      timeControl: tc ?? currentGame.timeControl,
                      lastFen: tree.lastMainlineNode.fen,
                    );
                    ref.read(selectedGameProvider.notifier).update(updated);
                    if (updated.id != null) {
                      await ref
                          .read(gameListProvider.notifier)
                          .updateMetadata(updated);
                      await ref.read(moveTreeProvider.notifier).persist();
                    }
                  }
                },
                child: const Text('Import PGN'),
              ),
            ],
          ),
        ),
      );
    }

    return const Column(
      children: [
        Expanded(child: StudyNotation()),
      ],
    );
  }
}

class _GameBottomBar extends ConsumerWidget {
  const _GameBottomBar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(activeNodeProvider.notifier);
    final bottomInset = MediaQuery.of(context).padding.bottom;

    return Container(
      height: 72 + bottomInset,
      decoration: const BoxDecoration(
        color: AppColors.scaffoldBg,
        border: Border(top: BorderSide(color: AppColors.divider)),
      ),
      child: Padding(
        padding: EdgeInsets.only(bottom: bottomInset),
        child: Row(
          children: [
            Expanded(
              child: _RepeatNavButton(
                onAction: notifier.goBack,
                icon: Icons.chevron_left,
                label: 'Back',
              ),
            ),
            Expanded(
              child: _RepeatNavButton(
                onAction: notifier.goForward,
                icon: Icons.chevron_right,
                label: 'Next',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Floating progress toast shown while game review runs in the background
// ---------------------------------------------------------------------------

class _ReviewProgressToast extends ConsumerWidget {
  const _ReviewProgressToast();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final progress = ref.watch(reviewProvider);
    if (!progress.isRunning) return const SizedBox.shrink();

    final pct = progress.total > 0
        ? (progress.current / progress.total * 100).round()
        : 0;

    return Positioned(
      left: 16,
      right: 16,
      bottom: 16,
      child: Material(
        elevation: 6,
        borderRadius: BorderRadius.circular(8),
        color: Colors.grey.shade900,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      'Analysing game…',
                      style: TextStyle(color: Colors.white),
                    ),
                  ),
                  Text(
                    '$pct%',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              LinearProgressIndicator(
                value: progress.total > 0 ? progress.current / progress.total : 0,
                backgroundColor: Colors.white24,
                valueColor: const AlwaysStoppedAnimation(Colors.white),
                borderRadius: BorderRadius.circular(2),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Player name bar (shown above and below the board)
// ---------------------------------------------------------------------------

class _PlayerBar extends ConsumerWidget {
  /// [isTop] = true → rendered above the board (opponent side when unflipped).
  final bool isTop;
  const _PlayerBar({required this.isTop});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isFlipped = ref.watch(boardFlippedProvider);
    final game = ref.watch(selectedGameProvider);
    final review = ref.watch(reviewProvider);

    // top + not flipped = black at top; top + flipped = white at top
    final showWhite = isTop == isFlipped;

    if (game == null) return const SizedBox.shrink();

    final name = showWhite ? game.white : game.black;
    final elo = showWhite ? game.whiteElo : game.blackElo;
    final accuracy = review.isCompleted
        ? (showWhite ? review.whiteAccuracy : review.blackAccuracy)
        : null;

    return Container(
      color: AppColors.scaffoldBg,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      child: Row(
        children: [
          // Small square indicating piece colour
          Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(
              color: showWhite ? Colors.white : Colors.black87,
              border: Border.all(color: Colors.grey.shade400, width: 1.5),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              elo.isNotEmpty ? '$name ($elo)' : name,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: AppColors.textPrimary,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (accuracy != null) ...[
            const SizedBox(width: 8),
            _AccuracyBadge(accuracy: accuracy),
          ],
        ],
      ),
    );
  }
}

class _AccuracyBadge extends StatelessWidget {
  final double accuracy;
  const _AccuracyBadge({required this.accuracy});

  Color get _color {
    if (accuracy >= 90) return Colors.green.shade700;
    if (accuracy >= 75) return Colors.lightGreen.shade700;
    if (accuracy >= 60) return Colors.orange.shade700;
    return Colors.red.shade700;
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: _color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        '${accuracy.round()}%',
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: _color,
        ),
      ),
    );
  }
}

// ── Board drawing color picker ────────────────────────────────────────────────

class _BoardEditToolbar extends ConsumerWidget {
  const _BoardEditToolbar();

  static const _colors = [
    Colors.red,
    Colors.green,
    Colors.blue,
    Colors.yellow,
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isEditMode = ref.watch(boardEditModeProvider);
    if (!isEditMode) return const SizedBox.shrink();

    final selectedColor = ref.watch(drawColorProvider);

    return Container(
      color: AppColors.scaffoldBg,
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (final color in _colors)
            GestureDetector(
              onTap: () => ref.read(drawColorProvider.notifier).setColor(color),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                margin: const EdgeInsets.symmetric(horizontal: 5),
                width: 26,
                height: 26,
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: selectedColor == color
                        ? Colors.black87
                        : Colors.transparent,
                    width: 2.5,
                  ),
                  boxShadow: selectedColor == color
                      ? [BoxShadow(color: color.withValues(alpha: 0.5), blurRadius: 4)]
                      : null,
                ),
              ),
            ),
          const SizedBox(width: 8),
          IconButton(
            icon: const Icon(Icons.layers_clear_outlined, size: 18),
            color: AppColors.textSecondary,
            tooltip: 'Clear drawings',
            visualDensity: VisualDensity.compact,
            onPressed: () {
              const startFen =
                  'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';
              final fen = ref.read(activeNodeProvider)?.fen ?? startFen;
              final gameId = ref.read(selectedGameProvider)?.id;
              ref.read(customShapesProvider.notifier).clearNode(gameId, fen);
            },
          ),
        ],
      ),
    );
  }
}

// ── PGN export dialog ─────────────────────────────────────────────────────────

class _ExportPgnDialog extends StatefulWidget {
  final MoveTree tree;
  final GameEntry? game;
  final Map<String, List<Shape>> shapes;

  const _ExportPgnDialog({
    required this.tree,
    this.game,
    this.shapes = const {},
  });

  @override
  State<_ExportPgnDialog> createState() => _ExportPgnDialogState();
}

class _ExportPgnDialogState extends State<_ExportPgnDialog> {
  bool _clean = false;

  String get _pgn => PgnParser.exportPgn(
        widget.tree,
        game: widget.game,
        clean: _clean,
        shapes: widget.shapes,
      );

  void _copy(BuildContext context) {
    Clipboard.setData(ClipboardData(text: _pgn));
    Navigator.pop(context);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('PGN copied to clipboard'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  Widget _tab(String label, bool selected, VoidCallback onTap) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: selected ? Colors.white : Colors.transparent,
            border: Border(
              bottom: BorderSide(
                color: selected ? AppColors.primary : Colors.transparent,
                width: 2,
              ),
            ),
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
              color: selected ? AppColors.primary : AppColors.textSecondary,
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      titlePadding: EdgeInsets.zero,
      title: Container(
        decoration: BoxDecoration(
          color: Colors.grey.shade100,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
        ),
        child: Row(
          children: [
            _tab('Annotated', !_clean, () => setState(() => _clean = false)),
            _tab('Clean', _clean, () => setState(() => _clean = true)),
          ],
        ),
      ),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: SelectableText(
            _pgn,
            style: const TextStyle(fontSize: 12),
          ),
        ),
      ),
      actions: [
        ElevatedButton.icon(
          icon: const Icon(Icons.copy, size: 16),
          label: const Text('Copy'),
          onPressed: () => _copy(context),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Hold-to-repeat navigation button
// ---------------------------------------------------------------------------

class _RepeatNavButton extends StatefulWidget {
  final VoidCallback onAction;
  final IconData icon;
  final String label;

  const _RepeatNavButton({
    required this.onAction,
    required this.icon,
    required this.label,
  });

  @override
  State<_RepeatNavButton> createState() => _RepeatNavButtonState();
}

class _RepeatNavButtonState extends State<_RepeatNavButton> {
  Timer? _timer;

  void _startRepeating() {
    widget.onAction();
    _timer = Timer.periodic(const Duration(milliseconds: 120), (_) {
      widget.onAction();
    });
  }

  void _stopRepeating() {
    _timer?.cancel();
    _timer = null;
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onLongPressStart: (_) => _startRepeating(),
      onLongPressEnd: (_) => _stopRepeating(),
      onLongPressCancel: _stopRepeating,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: widget.onAction,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(widget.icon, color: AppColors.textSecondary, size: 24),
              const SizedBox(height: 2),
              Text(widget.label, style: const TextStyle(fontSize: 10, color: AppColors.textSecondary)),
            ],
          ),
        ),
      ),
    );
  }
}
