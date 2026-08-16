import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/study_provider.dart';
import '../services/move_evaluator.dart';
import '../theme.dart';

/// A line chart that shows centipawn evaluation across the game.
/// Middle axis = 0. Up = White advantage. Down = Black advantage.
/// Only visible after a review has been completed.
class EvalChart extends ConsumerWidget {
  const EvalChart({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final reviewProgress = ref.watch(reviewProvider);
    final tree = ref.watch(moveTreeProvider);
    final activeNode = ref.watch(activeNodeProvider);

    // Only show after review has completed
    if (reviewProgress.isRunning || !reviewProgress.isCompleted) {
      return const SizedBox.shrink();
    }

    final mainline = tree.mainline;
    if (mainline.isEmpty) return const SizedBox.shrink();

    // Build evaluation and quality data points
    final evals = <double>[];
    final qualities = <MoveQuality?>[];
    for (final node in mainline) {
      if (node.mate != null) {
        if (node.mate == 0) {
          evals.add(node.evaluation! > 0 ? 10.0 : -10.0);
        } else {
          evals.add(node.mate! > 0 ? 10.0 : -10.0);
        }
      } else if (node.evaluation != null) {
        evals.add(node.evaluation!);
      } else {
        evals.add(evals.isEmpty ? 0.0 : evals.last);
      }
      qualities.add(node.quality);
    }

    if (evals.isEmpty) return const SizedBox.shrink();

    int activeIndex = -1;
    if (activeNode != null) {
      activeIndex = mainline.indexOf(activeNode);
    }

    return Container(
      height: 60,
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: AppColors.evalBlack,
        borderRadius: BorderRadius.circular(4),
      ),
      child: GestureDetector(
        onTapDown: (details) {
          final box = context.findRenderObject() as RenderBox;
          final localX = details.localPosition.dx;
          final width = box.size.width;
          final moveIndex = ((localX / width) * mainline.length).floor().clamp(0, mainline.length - 1);
          ref.read(activeNodeProvider.notifier).setNode(mainline[moveIndex]);
        },
        onHorizontalDragUpdate: (details) {
          final box = context.findRenderObject() as RenderBox;
          final localX = details.localPosition.dx;
          final width = box.size.width;
          final moveIndex = ((localX / width) * mainline.length).floor().clamp(0, mainline.length - 1);
          ref.read(activeNodeProvider.notifier).setNode(mainline[moveIndex]);
        },
        child: CustomPaint(
          size: Size.infinite,
          painter: _EvalChartPainter(
            evaluations: evals,
            qualities: qualities,
            activeIndex: activeIndex,
          ),
        ),
      ),
    );
  }
}

class _EvalChartPainter extends CustomPainter {
  final List<double> evaluations;
  final List<MoveQuality?> qualities;
  final int activeIndex;

  static const double _maxEval = 3.5;

  _EvalChartPainter({
    required this.evaluations,
    required this.qualities,
    required this.activeIndex,
  });

  double _evalY(double eval, double midY) =>
      midY - (eval.clamp(-_maxEval, _maxEval) / _maxEval) * (midY - 4);

  @override
  void paint(Canvas canvas, Size size) {
    if (evaluations.isEmpty) return;

    final width = size.width;
    final height = size.height;
    final midY = height / 2;

    final stepX = evaluations.length > 1
        ? width / (evaluations.length - 1)
        : width;

    double x(int i) => evaluations.length > 1 ? i * stepX : width / 2;

    // --- Filled area: white fill below the eval line (background = evalBlack) ---
    final fillPath = Path()..moveTo(0, height);
    for (int i = 0; i < evaluations.length; i++) {
      fillPath.lineTo(x(i), _evalY(evaluations[i], midY));
    }
    final lastX = x(evaluations.length - 1);
    fillPath..lineTo(lastX, height)..close();

    canvas.drawPath(fillPath,
        Paint()..color = Colors.white..style = PaintingStyle.fill);

    // --- Zero line ---
    canvas.drawLine(
      Offset(0, midY),
      Offset(width, midY),
      Paint()
        ..color = const Color(0xFF888888)
        ..strokeWidth = 1.0,
    );

    // --- ±2 reference lines ---
    final refLinePaint = Paint()
      ..color = const Color(0xFF888888).withValues(alpha: 0.6)
      ..strokeWidth = 0.8;
    final y2pos = _evalY(2.0, midY);
    final y2neg = _evalY(-2.0, midY);
    canvas.drawLine(Offset(0, y2pos), Offset(width, y2pos), refLinePaint);
    canvas.drawLine(Offset(0, y2neg), Offset(width, y2neg), refLinePaint);

    // --- Active move marker ---
    if (activeIndex >= 0 && activeIndex < evaluations.length) {
      final ax = x(activeIndex);
      canvas.drawLine(
        Offset(ax, 0),
        Offset(ax, height),
        Paint()..color = AppColors.primary.withValues(alpha: 0.55)..strokeWidth = 1.5,
      );

      final ay = _evalY(evaluations[activeIndex], midY);
      canvas.drawCircle(Offset(ax, ay), 4,
          Paint()..color = AppColors.primary..style = PaintingStyle.fill);
      canvas.drawCircle(Offset(ax, ay), 4,
          Paint()..color = Colors.white..style = PaintingStyle.stroke..strokeWidth = 1.5);
    }

    // --- Severity markers (dots near top edge) ---
    for (int i = 0; i < qualities.length && i < evaluations.length; i++) {
      final q = qualities[i];
      if (q == null) continue;
      Color? dotColor;
      if (q == MoveQuality.blunder) {
        dotColor = Colors.red.shade600;
      } else if (q == MoveQuality.mistake) {
        dotColor = Colors.red.shade600;
      } else if (q == MoveQuality.inaccuracy) {
        dotColor = Colors.orange.shade700;
      }
      if (dotColor != null) {
        final dotY = _evalY(evaluations[i], midY);
        canvas.drawCircle(
          Offset(x(i), dotY),
          3,
          Paint()..color = dotColor..style = PaintingStyle.fill,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_EvalChartPainter old) =>
      old.evaluations != evaluations ||
      old.qualities != qualities ||
      old.activeIndex != activeIndex;
}
