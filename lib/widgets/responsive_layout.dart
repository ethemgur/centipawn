import 'dart:ui';
import 'package:flutter/material.dart';

/// Detects the hinge of the Samsung Z Fold and applies correct layout:
///  • Unfolded / book posture: 60/40 Horizontal Split (Board left, Notation right)
///  • Flex Mode (laptop posture / horizontal hinge): 50/50 Vertical Split;
///    [foldControlsWidget] is shown at the bottom of the lower pane.
///  • Folded / phone: Standard vertical stack
class ResponsiveLayout extends StatelessWidget {
  final Widget boardWidget;
  final Widget notationWidget;

  /// Shown below the notation panel only in Z Fold flex (laptop) mode.
  /// Typically contains nav buttons + board toolbar.
  final Widget? foldControlsWidget;

  const ResponsiveLayout({
    super.key,
    required this.boardWidget,
    required this.notationWidget,
    this.foldControlsWidget,
  });

  @override
  Widget build(BuildContext context) {
    final displayFeatures = MediaQuery.of(context).displayFeatures;
    final hasHinge = displayFeatures.any(
        (f) => f.type == DisplayFeatureType.hinge || f.type == DisplayFeatureType.fold);

    if (hasHinge) {
      final hinge = displayFeatures.firstWhere(
          (f) => f.type == DisplayFeatureType.hinge || f.type == DisplayFeatureType.fold);

      if (hinge.bounds.width > hinge.bounds.height) {
        // Horizontal hinge (Flex Mode / Laptop posture) -> 50/50 Vertical Split
        return Column(
          children: [
            Expanded(
              child: SingleChildScrollView(child: boardWidget),
            ),
            SizedBox(height: hinge.bounds.height),
            Expanded(
              child: Column(
                children: [
                  Expanded(child: notationWidget),
                  ?foldControlsWidget,
                ],
              ),
            ),
          ],
        );
      } else {
        // Vertical hinge (Book posture) -> 60/40 Horizontal Split
        return Row(
          children: [
            Expanded(flex: 6, child: SingleChildScrollView(child: boardWidget)),
            SizedBox(width: hinge.bounds.width),
            Expanded(flex: 4, child: notationWidget),
          ],
        );
      }
    }

    // No hinge detected: use width to determine layout
    final screenWidth = MediaQuery.of(context).size.width;
    if (screenWidth > 600) {
      // Tablet / unfolded — 60/40 horizontal
      return Row(
        children: [
          Expanded(flex: 6, child: SingleChildScrollView(child: boardWidget)),
          const SizedBox(width: 16),
          Expanded(flex: 4, child: notationWidget),
        ],
      );
    } else {
      // Phone / folded — vertical stack (board scrollable, notation fills rest)
      return Column(
        children: [
          SingleChildScrollView(child: boardWidget),
          Expanded(child: notationWidget),
        ],
      );
    }
  }
}
