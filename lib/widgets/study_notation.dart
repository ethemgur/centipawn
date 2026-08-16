import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/move_node.dart';
import '../providers/study_provider.dart';
import '../services/engine_types.dart';
import '../theme.dart';

class StudyNotation extends ConsumerStatefulWidget {
  const StudyNotation({super.key});

  @override
  ConsumerState<StudyNotation> createState() => _StudyNotationState();
}

class _StudyNotationState extends ConsumerState<StudyNotation> {
  final ScrollController _scrollController = ScrollController();
  final GlobalKey _activeKey = GlobalKey();
  MoveNode? _lastActiveNode;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _scheduleScrollToActive() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _activeKey.currentContext;
      if (ctx != null && _scrollController.hasClients) {
        Scrollable.ensureVisible(
          ctx,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeInOut,
          alignment: 0.5,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final moveTree = ref.watch(moveTreeProvider);
    final activeNode = ref.watch(activeNodeProvider);

    if (activeNode != _lastActiveNode) {
      _lastActiveNode = activeNode;
      _scheduleScrollToActive();
    }

    final movePairs = _collectMovePairs(moveTree.root);

    return Container(
      color: AppColors.scaffoldBg,
      child: ListView(
        controller: _scrollController,
        padding: const EdgeInsets.symmetric(vertical: 4),
        children: [
          ...movePairs.map(
            (pair) => _buildMovePairRow(pair, activeNode, ref, context),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Collect main-line pairs
  // ---------------------------------------------------------------------------

  List<_MovePair> _collectMovePairs(MoveNode root) {
    final pairs = <_MovePair>[];
    MoveNode? current = root;
    int moveNumber = 1;

    while (current != null && current.children.isNotEmpty) {
      final mainChild = current.children.first;
      final whiteVariations = current.children.length > 1
          ? current.children.skip(1).toList()
          : <MoveNode>[];

      String? blackSan;
      MoveNode? blackNode;
      List<MoveNode> blackVariations = [];

      if (mainChild.children.isNotEmpty) {
        final blackChild = mainChild.children.first;
        blackSan = blackChild.san;
        blackNode = blackChild;
        blackVariations = mainChild.children.length > 1
            ? mainChild.children.skip(1).toList()
            : [];
        current = blackChild;
      } else {
        current = null;
      }

      pairs.add(_MovePair(
        number: moveNumber,
        whiteSan: mainChild.san,
        whiteNode: mainChild,
        blackSan: blackSan,
        blackNode: blackNode,
        whiteVariations: whiteVariations,
        blackVariations: blackVariations,
      ));
      moveNumber++;
    }
    return pairs;
  }

  // ---------------------------------------------------------------------------
  // Move pair row
  // ---------------------------------------------------------------------------

  Widget _buildMovePairRow(
      _MovePair pair, MoveNode? activeNode, WidgetRef ref, BuildContext context) {
    final widgets = <Widget>[];

    Widget buildRow(MoveNode? whiteNode, String? whiteSan, MoveNode? blackNode,
        String? blackSan, bool showWhiteDots, bool showBlackDots) {
      return Container(
        decoration: BoxDecoration(
          border: Border(
            bottom:
                BorderSide(color: AppColors.divider.withValues(alpha: 0.5)),
          ),
        ),
        child: IntrinsicHeight(
          child: Row(
            children: [
              Container(
                width: 36,
                alignment: Alignment.center,
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  '${pair.number}',
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: AppColors.moveNumberColor,
                  ),
                ),
              ),
              VerticalDivider(
                  width: 1,
                  color: AppColors.divider.withValues(alpha: 0.5)),
              Expanded(
                child: whiteSan != null
                    ? _buildMoveCell(
                        whiteNode!, whiteSan, activeNode, ref, context)
                    : (showWhiteDots
                        ? const Padding(
                            padding: EdgeInsets.symmetric(
                                horizontal: 10, vertical: 8),
                            child: Text('...',
                                style: TextStyle(
                                    color: AppColors.moveText)))
                        : const SizedBox()),
              ),
              VerticalDivider(
                  width: 1,
                  color: AppColors.divider.withValues(alpha: 0.5)),
              Expanded(
                child: blackSan != null
                    ? _buildMoveCell(
                        blackNode!, blackSan, activeNode, ref, context)
                    : (showBlackDots
                        ? const Padding(
                            padding: EdgeInsets.symmetric(
                                horizontal: 10, vertical: 8),
                            child: Text('...',
                                style: TextStyle(
                                    color: AppColors.moveText)))
                        : const SizedBox()),
              ),
            ],
          ),
        ),
      );
    }

    final hasWhiteComment = pair.whiteNode.comments.isNotEmpty;
    final hasWhiteVariations = pair.whiteVariations.isNotEmpty;
    final splitWhiteBlack =
        (hasWhiteComment || hasWhiteVariations) && pair.blackSan != null;

    if (splitWhiteBlack) {
      // White move alone (dots placeholder on the black side).
      widgets.add(buildRow(
          pair.whiteNode, pair.whiteSan, null, null, false, true));
      if (hasWhiteComment) {
        widgets.add(
            _InlineCommentBlock(text: pair.whiteNode.comments.join('\n')));
      }
      // White variations sit between the white and black rows.
      widgets.addAll(pair.whiteVariations.map(
          (v) => _buildVariationBlock(v, activeNode, ref, context, 0)));
      // Black move alone (dots on white side to show move number context).
      widgets.add(buildRow(
          null, null, pair.blackNode, pair.blackSan, true, false));
    } else {
      widgets.add(buildRow(pair.whiteNode, pair.whiteSan, pair.blackNode,
          pair.blackSan, false, pair.blackSan == null));
      if (hasWhiteComment) {
        widgets.add(
            _InlineCommentBlock(text: pair.whiteNode.comments.join('\n')));
      }
      widgets.addAll(pair.whiteVariations.map(
          (v) => _buildVariationBlock(v, activeNode, ref, context, 0)));
    }

    if (pair.blackNode != null && pair.blackNode!.comments.isNotEmpty) {
      widgets.add(
          _InlineCommentBlock(text: pair.blackNode!.comments.join('\n')));
    }

    widgets.addAll(pair.blackVariations.map(
        (v) => _buildVariationBlock(v, activeNode, ref, context, 0)));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: widgets,
    );
  }

  // ---------------------------------------------------------------------------
  // Individual mainline move cell
  // ---------------------------------------------------------------------------

  Widget _buildMoveCell(
    MoveNode node,
    String san,
    MoveNode? activeNode,
    WidgetRef ref,
    BuildContext context,
  ) {
    final isActive = node == activeNode;
    // Derive quality from explicit field first, then fall back to glyphs NAG.
    final effectiveQuality = node.quality ??
        (node.glyphs.isNotEmpty ? _nagToQuality(node.glyphs.last) : null);
    final qualityColor =
        effectiveQuality != null ? _qualityColor(effectiveQuality) : null;
    // When a badge will be shown for quality-mappable glyphs, strip those glyphs
    // from the inline text to avoid the symbol appearing twice.
    final textGlyphs = effectiveQuality != null
        ? node.glyphs.where((g) => _nagToQuality(g) == null).toList()
        : node.glyphs;
    final nagColor =
        textGlyphs.isNotEmpty ? _nagColor(textGlyphs.last) : null;

    Widget cell = Container(
      key: isActive ? _activeKey : null,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      color: isActive ? AppColors.moveActiveBackground : Colors.transparent,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _formatSan(san, textGlyphs),
            style: TextStyle(
              fontSize: 14,
              fontWeight: isActive ? FontWeight.w600 : FontWeight.w500,
              color: qualityColor ?? nagColor ??
                  (isActive ? AppColors.moveActiveText : AppColors.moveText),
            ),
          ),
          if (effectiveQuality != null &&
              _qualityToSymbol(effectiveQuality).isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 6),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                decoration: BoxDecoration(
                  color: qualityColor,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  _qualityToSymbol(effectiveQuality),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
        ],
      ),
    );

    return GestureDetector(
      onTap: () => ref.read(activeNodeProvider.notifier).setNode(node),
      onLongPress: () => _showMoveActions(context, node, ref),
      child: cell,
    );
  }

  // ---------------------------------------------------------------------------
  // Variation block — recursive, renders each move individually
  // ---------------------------------------------------------------------------

  Widget _buildVariationBlock(
    MoveNode variationRoot,
    MoveNode? activeNode,
    WidgetRef ref,
    BuildContext context,
    int depth,
  ) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(
          left: BorderSide(
            color: AppColors.divider.withValues(alpha: 0.5),
            width: depth == 0 ? 2 : 1,
          ),
        ),
      ),
      margin: EdgeInsets.only(left: depth * 8.0),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        children: _buildVariationInlineWidgets(
            variationRoot, activeNode, ref, context, true, depth),
      ),
    );
  }

  List<Widget> _buildVariationInlineWidgets(
    MoveNode startNode,
    MoveNode? activeNode,
    WidgetRef ref,
    BuildContext context,
    bool isFirstInVariation,
    int depth,
  ) {
    final widgets = <Widget>[];
    MoveNode? current = startNode;
    bool first = isFirstInVariation;

    while (current != null) {
      final node = current;

      // Move number token
      if (!node.isBlackMove) {
        widgets.add(_varMoveNum('${node.moveNumber}.'));
      } else if (first) {
        widgets.add(_varMoveNum('${node.moveNumber}...'));
      }

      // Move chip
      widgets.add(_buildVariationMoveChip(node, activeNode, ref, context));

      // Comment after this move
      final visibleComments =
          node.comments.where((c) => c != '[eng]').toList();
      if (visibleComments.isNotEmpty) {
        widgets.add(_varComment(visibleComments.join(' ')));
      }

      // Sub-variations: children[1..] are alternatives at this node
      for (int i = 1; i < node.children.length; i++) {
        widgets.add(
          _SubVariationWidget(
            child: _buildVariationBlock(
                node.children[i], activeNode, ref, context, depth + 1),
          ),
        );
      }

      first = false;
      current = node.children.isNotEmpty ? node.children.first : null;
    }

    return widgets;
  }

  Widget _buildVariationMoveChip(
    MoveNode node,
    MoveNode? activeNode,
    WidgetRef ref,
    BuildContext context,
  ) {
    final isActive = node == activeNode;
    final effectiveQuality = node.quality ??
        (node.glyphs.isNotEmpty ? _nagToQuality(node.glyphs.last) : null);
    final qualityColor =
        effectiveQuality != null ? _qualityColor(effectiveQuality) : null;
    // Variation chips have no badge — show the symbol inline in text.
    // Prefer glyphs if present; otherwise synthesize from quality.
    final List<int> chipGlyphs;
    if (node.glyphs.isNotEmpty) {
      chipGlyphs = node.glyphs;
    } else if (effectiveQuality != null) {
      final nag = _qualityToNag(effectiveQuality);
      chipGlyphs = nag != null ? [nag] : const [];
    } else {
      chipGlyphs = const [];
    }
    final nagColor = chipGlyphs.isNotEmpty ? _nagColor(chipGlyphs.last) : null;

    return GestureDetector(
      onTap: () => ref.read(activeNodeProvider.notifier).setNode(node),
      onLongPress: () => _showMoveActions(context, node, ref),
      child: Container(
        key: isActive ? _activeKey : null,
        margin: const EdgeInsets.symmetric(horizontal: 1, vertical: 2),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        decoration: BoxDecoration(
          color: isActive
              ? AppColors.moveActiveBackground
              : Colors.transparent,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          _formatSan(node.san, chipGlyphs),
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color: isActive
                ? AppColors.moveActiveText
                : (qualityColor ?? nagColor ?? AppColors.variationText),
          ),
        ),
      ),
    );
  }

  Widget _varMoveNum(String text) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 2),
        child: Text(
          text,
          style: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: AppColors.moveNumberColor,
          ),
        ),
      );

  Widget _varComment(String text) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Text(
          '{ $text }',
          style: const TextStyle(
            fontSize: 11,
            color: AppColors.textSecondary,
            fontStyle: FontStyle.italic,
          ),
        ),
      );

  // ---------------------------------------------------------------------------
  // Persist the full tree (variations + comments + NAGs) back to the database.
  // ---------------------------------------------------------------------------

  void _saveTree(WidgetRef ref) {
    // Fire-and-forget — UI doesn't block on the DB write. `persist` refreshes
    // the selectedGame + list cache once the write returns.
    ref.read(moveTreeProvider.notifier).persist();
  }

  // ---------------------------------------------------------------------------
  // Move actions bottom sheet
  // ---------------------------------------------------------------------------

  void _showMoveActions(
      BuildContext context, MoveNode node, WidgetRef ref) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                  child: Text(
                    _formatSan(node.san, node.glyphs),
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary,
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 0),
                  child: Wrap(
                    spacing: 8,
                    children: [3, 1, 5, 6, 2, 4].map((nag) {
                      // Negative NAGs (?, ??, ?!) are expressed via node.quality
                      // (badge). Positive NAGs (!, !!, !?) via node.glyphs (SAN).
                      final nagQuality = _nagToQuality(nag);
                      final isSelected = node.glyphs.contains(nag) ||
                          (nagQuality != null && node.quality == nagQuality);
                      return ChoiceChip(
                        label: Text(
                          _nagToSymbol(nag),
                          style: TextStyle(
                            color: _nagColor(nag) ?? Colors.black,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        selected: isSelected,
                        onSelected: (selected) {
                          if (selected) {
                            node.glyphs.clear();
                            if (nagQuality != null) {
                              node.quality = nagQuality;
                            } else {
                              node.glyphs.add(nag);
                              node.quality = null;
                            }
                          } else {
                            node.glyphs.remove(nag);
                            if (nagQuality != null &&
                                node.quality == nagQuality) {
                              node.quality = null;
                            }
                          }
                          ref.read(moveTreeProvider.notifier).refresh();
                          _saveTree(ref);
                          Navigator.pop(context);
                        },
                      );
                    }).toList(),
                  ),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.comment_outlined,
                      color: AppColors.textSecondary),
                  title: const Text('Add / Edit comment'),
                  onTap: () {
                    Navigator.pop(context);
                    _editComment(context, node, ref);
                  },
                ),
                ListTile(
                  leading:
                      const Icon(Icons.delete_outline, color: Colors.red),
                  title: const Text(
                    'Delete from here',
                    style: TextStyle(color: Colors.red),
                  ),
                  onTap: () {
                    if (node.parent != null) {
                      node.parent!.removeChild(node);
                      ref.read(activeNodeProvider.notifier).setNode(node.parent);
                    }
                    ref.read(moveTreeProvider.notifier).refresh();
                    _saveTree(ref);
                    Navigator.pop(context);
                  },
                ),
                if (node.parent != null &&
                    !ref.read(moveTreeProvider).mainline.contains(node))
                  ListTile(
                    leading: const Icon(Icons.arrow_upward,
                        color: AppColors.textSecondary),
                    title: const Text('Promote to mainline'),
                    onTap: () {
                      node.promoteToMainline();
                      ref.read(moveTreeProvider.notifier).refresh();
                      _saveTree(ref);
                      Navigator.pop(context);
                    },
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _editComment(
      BuildContext context, MoveNode node, WidgetRef ref) {
    final controller =
        TextEditingController(text: node.comments.join('\n'));
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Edit Comment'),
        content: TextField(
          controller: controller,
          maxLines: 5,
          autofocus: true,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            hintText: 'Enter comment for this move...',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              node.comments.clear();
              if (controller.text.trim().isNotEmpty) {
                node.comments.add(controller.text.trim());
              }
              ref.read(moveTreeProvider.notifier).refresh();
              _saveTree(ref);
              Navigator.pop(context);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  String _qualityToSymbol(MoveQuality quality) {
    switch (quality) {
      case MoveQuality.blunder:
        return '??';
      case MoveQuality.mistake:
        return '?';
      case MoveQuality.inaccuracy:
        return '?!';
      default:
        return '';
    }
  }

  Color? _qualityColor(MoveQuality quality) {
    switch (quality) {
      case MoveQuality.blunder:
        return Colors.red.shade700;
      case MoveQuality.mistake:
        return Colors.red.shade700;
      case MoveQuality.inaccuracy:
        return Colors.orange.shade700;
      default:
        return null;
    }
  }

  String _nagToSymbol(int nag) {
    switch (nag) {
      case 1:
        return '!';
      case 2:
        return '?';
      case 3:
        return '!!';
      case 4:
        return '??';
      case 5:
        return '!?';
      case 6:
        return '?!';
      default:
        return '';
    }
  }

  MoveQuality? _nagToQuality(int nag) {
    switch (nag) {
      case 4: return MoveQuality.blunder;
      case 2: return MoveQuality.mistake;
      case 6: return MoveQuality.inaccuracy;
      default: return null;
    }
  }

  int? _qualityToNag(MoveQuality quality) {
    switch (quality) {
      case MoveQuality.blunder: return 4;
      case MoveQuality.mistake: return 2;
      case MoveQuality.inaccuracy: return 6;
      default: return null;
    }
  }

  Color? _nagColor(int nag) {
    switch (nag) {
      case 1:
      case 3:
        return Colors.green.shade700;
      case 2:
      case 4:
        return Colors.red.shade700;
      case 5:
      case 6:
        return Colors.orange.shade700;
      default:
        return null;
    }
  }

  String _formatSan(String san, [List<int> glyphs = const []]) {
    var text = san
        .replaceAll('K', '♔')
        .replaceAll('Q', '♕')
        .replaceAll('R', '♖')
        .replaceAll('B', '♗')
        .replaceAll('N', '♘');
    if (glyphs.isNotEmpty) {
      text += _nagToSymbol(glyphs.last);
    }
    return text;
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Wraps a sub-variation widget so it forces a full-width line break in Wrap.
class _SubVariationWidget extends StatelessWidget {
  final Widget child;
  const _SubVariationWidget({required this.child});

  @override
  Widget build(BuildContext context) {
    return SizedBox(width: double.infinity, child: child);
  }
}

class _MovePair {
  final int number;
  final String whiteSan;
  final MoveNode whiteNode;
  final String? blackSan;
  final MoveNode? blackNode;
  final List<MoveNode> whiteVariations;
  final List<MoveNode> blackVariations;

  _MovePair({
    required this.number,
    required this.whiteSan,
    required this.whiteNode,
    this.blackSan,
    this.blackNode,
    this.whiteVariations = const [],
    this.blackVariations = const [],
  });
}

class _InlineCommentBlock extends StatelessWidget {
  final String text;
  const _InlineCommentBlock({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(
          bottom: BorderSide(
              color: AppColors.divider.withValues(alpha: 0.5)),
        ),
      ),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 13,
          color: AppColors.textPrimary,
          height: 1.5,
        ),
      ),
    );
  }
}
