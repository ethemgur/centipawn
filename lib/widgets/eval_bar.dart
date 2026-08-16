import 'package:flutter/material.dart';
import '../theme.dart';

/// Slim vertical evaluation bar (sits to the left of the board).
/// White advantage = white portion grows from bottom (or top when flipped).
/// The bar animates smoothly between evaluations.
class EvalBar extends StatelessWidget {
  final double evaluation; // positive = white advantage, in pawns
  final int? mate;
  final bool isFlipped;

  const EvalBar({super.key, this.evaluation = 0.0, this.mate, this.isFlipped = false});

  double _targetRatio() {
    if (mate != null) {
      if (mate == 0) return evaluation > 0 ? 1.0 : 0.0;
      return mate! > 0 ? 1.0 : 0.0;
    }
    return (0.5 + (evaluation / 3.0) * 0.45).clamp(0.05, 0.95);
  }

  @override
  Widget build(BuildContext context) {
    final targetRatio = _targetRatio();

    // Round before deciding whether to show a score: an eval of 0.04 renders as
    // "0.0", which reads as dead-equal and is not worth a label.
    final double rounded = (evaluation * 10).roundToDouble() / 10;

    final String label;
    if (mate != null) {
      label = 'M${mate!.abs()}';
    } else {
      label = rounded.abs().toStringAsFixed(1);
    }

    // Show the score on the leading side's section for *any* non-zero eval —
    // a 0.1 edge is still information. Only an exactly level position (and the
    // pre-analysis default of 0.0) goes unlabelled.
    final bool whiteLabel = rounded > 0 || (mate != null && mate! > 0);
    final bool blackLabel = rounded < 0 || (mate != null && mate! < 0);

    return SizedBox(
      width: 24,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final totalHeight = constraints.maxHeight;

          return TweenAnimationBuilder<double>(
            tween: Tween<double>(end: targetRatio),
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
            builder: (context, ratio, _) {
              final whiteHeight = totalHeight * ratio;
              final blackHeight = totalHeight - whiteHeight;

              final blackSection = SizedBox(
                height: blackHeight,
                width: 24,
                child: ColoredBox(
                  color: AppColors.evalBlack,
                  child: blackLabel
                      ? Align(
                          alignment: isFlipped ? Alignment.bottomCenter : Alignment.topCenter,
                          child: Padding(
                            padding: isFlipped
                                ? const EdgeInsets.only(bottom: 2)
                                : const EdgeInsets.only(top: 2),
                            child: Text(
                              label,
                              style: const TextStyle(
                                fontSize: 9,
                                fontWeight: FontWeight.w700,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        )
                      : null,
                ),
              );

              final whiteSection = SizedBox(
                height: whiteHeight,
                width: 24,
                child: ColoredBox(
                  color: AppColors.evalWhite,
                  child: whiteLabel
                      ? Align(
                          alignment: isFlipped ? Alignment.topCenter : Alignment.bottomCenter,
                          child: Padding(
                            padding: isFlipped
                                ? const EdgeInsets.only(top: 2)
                                : const EdgeInsets.only(bottom: 2),
                            child: Text(
                              label,
                              style: const TextStyle(
                                fontSize: 9,
                                fontWeight: FontWeight.w700,
                                color: Colors.black87,
                              ),
                            ),
                          ),
                        )
                      : null,
                ),
              );

              return Column(
                children: isFlipped
                    ? [whiteSection, blackSection]
                    : [blackSection, whiteSection],
              );
            },
          );
        },
      ),
    );
  }
}
