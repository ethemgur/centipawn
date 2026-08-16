import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:chessground/chessground.dart';
import 'package:dartchess/dartchess.dart';
import 'package:fast_immutable_collections/fast_immutable_collections.dart';
import '../providers/study_provider.dart';
import '../services/engine_types.dart';
import '../services/move_evaluator.dart';

/// Interactive chess board backed by the lichess chessground package.
///
/// Promotion is handled automatically: when a pawn reaches the back rank,
/// chessground shows a piece-selector overlay and fires [onPromotionSelection].
/// Engine suggestion arrows are rendered via chessground's shape layer.
/// When [boardEditModeProvider] is true, an overlay intercepts touches so the
/// user can tap to place circle highlights and drag to draw arrows.
class ChessBoard extends ConsumerStatefulWidget {
  const ChessBoard({super.key});

  @override
  ConsumerState<ChessBoard> createState() => _ChessBoardState();
}

class _ChessBoardState extends ConsumerState<ChessBoard> {
  /// Set when a pawn move to the promotion rank is detected; cleared once the
  /// user picks a piece (or cancels). While non-null, chessground renders the
  /// promotion selector overlay.
  NormalMove? _pendingPromotion;

  // ── drawing state ──────────────────────────────────────────────────────────
  Square? _dragStartSquare;
  Square? _dragCurrentSquare;
  /// Shown live while the user is dragging an arrow.
  Shape? _dragPreviewShape;

  int _evalCp(EngineEvaluation e) {
    if (e.mate != null) return e.mate! > 0 ? 10000 : -10000;
    return (e.scoreCp * 100).round();
  }

  List<EngineEvaluation> _filterByWinProb(List<EngineEvaluation> evals) {
    if (evals.length <= 1) return evals;
    final bestWp = MoveEvaluator.cpToWinProb(_evalCp(evals.first));
    return [
      evals.first,
      ...evals.skip(1).where(
            (e) => bestWp - MoveEvaluator.cpToWinProb(_evalCp(e)) <= 10.0,
          ),
    ];
  }

  /// Maps a win-probability drop (0–10 pp) to arrow opacity and scale.
  /// Best move: full opacity + full scale. Alternatives fade and thin out.
  /// [rank] caps the maximum alpha/scale so alternatives are always visually
  /// subordinate to the best move even when their score is nearly equal.
  (double alpha, double scale) _arrowVisuals(double wpDrop, {int rank = 0}) {
    final t = (wpDrop / 10.0).clamp(0.0, 1.0);
    final rawAlpha = 0.65 - t * 0.35;
    final rawScale = 1.0 - t * 0.55;
    final (maxAlpha, maxScale) = switch (rank) {
      1 => (0.42, 0.72),
      2 => (0.28, 0.55),
      _ => (0.65, 1.0),
    };
    final alpha = rawAlpha.clamp(0.22, maxAlpha);
    final scale = rawScale.clamp(0.35, maxScale);
    return (alpha, scale);
  }

  /// Builds the set of arrow shapes for engine suggestions.
  ISet<Shape> _buildEngineShapes(List<EngineEvaluation> evals, bool showThreat) {
    final shapes = <Shape>[];
    final filtered = _filterByWinProb(evals);
    final bestWp = filtered.isNotEmpty
        ? MoveEvaluator.cpToWinProb(_evalCp(filtered.first))
        : 50.0;

    for (int i = 0; i < filtered.length && i < 3; i++) {
      final pv = filtered[i].pv;
      if (pv.isEmpty || pv[0].length < 4) continue;
      final wpDrop = bestWp - MoveEvaluator.cpToWinProb(_evalCp(filtered[i]));
      final (alpha, scale) = _arrowVisuals(wpDrop, rank: i);
      shapes.add(Arrow(
        color: Colors.green.shade600.withValues(alpha: alpha),
        orig: Square.fromName(pv[0].substring(0, 2)),
        dest: Square.fromName(pv[0].substring(2, 4)),
        scale: scale,
      ));
    }

    // Red threat arrow: 2nd move of the best principal variation
    if (showThreat && filtered.isNotEmpty) {
      final bestPv = filtered.first.pv;
      if (bestPv.length >= 2 && bestPv[1].length >= 4) {
        shapes.add(Arrow(
          color: Colors.red.shade600.withValues(alpha: 0.52),
          orig: Square.fromName(bestPv[1].substring(0, 2)),
          dest: Square.fromName(bestPv[1].substring(2, 4)),
          scale: 0.85,
        ));
      }
    }

    return ISet(shapes);
  }

  /// Returns true when [move] is a pawn reaching its promotion rank.
  bool _isPromotionMove(Position pos, NormalMove move) {
    return move.promotion == null &&
        pos.board.roleAt(move.from) == Role.pawn &&
        ((move.to.rank == Rank.eighth && pos.turn == Side.white) ||
            (move.to.rank == Rank.first && pos.turn == Side.black));
  }

  /// Converts a local board offset to a [Square], accounting for board flip.
  Square? _posToSquare(Offset pos, double boardSize, bool isFlipped) {
    final sq = boardSize / 8;
    final fileIdx = (pos.dx / sq).floor();
    final rankIdx = (pos.dy / sq).floor();
    if (fileIdx < 0 || fileIdx > 7 || rankIdx < 0 || rankIdx > 7) return null;
    final file = isFlipped ? 7 - fileIdx : fileIdx;
    final rank = isFlipped ? rankIdx : 7 - rankIdx;
    return Square.fromName('${String.fromCharCode(97 + file)}${rank + 1}');
  }

  @override
  Widget build(BuildContext context) {
    final activeNode = ref.watch(activeNodeProvider);
    const startFen =
        'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';
    final fen = activeNode?.fen ?? startFen;

    final isFlipped = ref.watch(boardFlippedProvider);
    final evalsAsync = ref.watch(combinedEvalProvider);
    final isEngineRunning = ref.watch(engineRunningProvider);
    final showThreat = ref.watch(showThreatArrowProvider);
    final isEditMode = ref.watch(boardEditModeProvider);
    final drawColor = ref.watch(drawColorProvider);
    final gameId = ref.watch(selectedGameProvider.select((g) => g?.id));
    final shapeKey = 'g${gameId ?? -1}::$fen';
    final customShapes = ref.watch(
      customShapesProvider.select((m) => m[shapeKey] ?? const []),
    );

    // Parse the current position to supply legal moves and side-to-move.
    Position pos;
    try {
      pos = Chess.fromSetup(Setup.parseFen(fen));
    } catch (_) {
      pos = Chess.initial;
    }
    final capturedPos = pos;

    // Derive the last move so chessground can highlight from/to squares.
    NormalMove? lastMove;
    if (activeNode != null &&
        activeNode.parent != null &&
        activeNode.san.isNotEmpty) {
      try {
        final parentPos =
            Chess.fromSetup(Setup.parseFen(activeNode.parent!.fen));
        final m = parentPos.parseSan(activeNode.san);
        if (m is NormalMove) lastMove = m;
      } catch (_) {}
    }

    // Merge engine shapes + user shapes + live drag preview.
    final engineShapes =
        (isEngineRunning && evalsAsync.hasValue && evalsAsync.value!.isNotEmpty)
            ? _buildEngineShapes(evalsAsync.value!, showThreat)
            : ISet<Shape>();

    final allShapesList = <Shape>[
      ...engineShapes,
      ...customShapes,
      ?_dragPreviewShape,
    ];
    final allShapes = allShapesList.isNotEmpty ? ISet<Shape>(allShapesList) : ISet<Shape>();

    return AspectRatio(
      aspectRatio: 1,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final boardSize = constraints.maxWidth;

          return Stack(
            children: [
              Chessboard(
                size: boardSize,
                orientation: isFlipped ? Side.black : Side.white,
                fen: fen,
                lastMove: lastMove,
                game: isEditMode
                    ? null
                    : GameData(
                        playerSide: capturedPos.turn == Side.white
                            ? PlayerSide.white
                            : PlayerSide.black,
                        sideToMove: capturedPos.turn,
                        validMoves: capturedPos.legalMoves.map(
                          (square, squareSet) =>
                              MapEntry(square, squareSet.squares.toISet()),
                        ),
                        isCheck: capturedPos.isCheck,
                        onMove: (move, {bool? viaDragAndDrop}) {
                          if (move is! NormalMove) return;
                          if (_isPromotionMove(capturedPos, move)) {
                            setState(() => _pendingPromotion = move);
                          } else {
                            ref.read(activeNodeProvider.notifier).makeMove(move);
                          }
                        },
                        promotionMove: _pendingPromotion,
                        onPromotionSelection: (role) {
                          if (role != null && _pendingPromotion != null) {
                            ref.read(activeNodeProvider.notifier).makeMove(
                                  NormalMove(
                                    from: _pendingPromotion!.from,
                                    to: _pendingPromotion!.to,
                                    promotion: role,
                                  ),
                                );
                          }
                          setState(() => _pendingPromotion = null);
                        },
                      ),
                settings: const ChessboardSettings(
                  enableCoordinates: true,
                  animationDuration: Duration(milliseconds: 150),
                ),
                shapes: allShapes.isNotEmpty ? allShapes : null,
              ),

              // ── Drawing overlay (active only in edit mode) ──────────────────
              if (isEditMode)
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapUp: (details) {
                      final sq = _posToSquare(
                          details.localPosition, boardSize, isFlipped);
                      if (sq == null) return;
                      ref.read(customShapesProvider.notifier).toggleCircle(
                            gameId,
                            fen,
                            sq,
                            drawColor.withValues(alpha: 0.75),
                          );
                    },
                    onPanStart: (details) {
                      _dragStartSquare = _posToSquare(
                          details.localPosition, boardSize, isFlipped);
                      _dragCurrentSquare = _dragStartSquare;
                    },
                    onPanUpdate: (details) {
                      final sq = _posToSquare(
                          details.localPosition, boardSize, isFlipped);
                      if (sq != _dragCurrentSquare) {
                        setState(() {
                          _dragCurrentSquare = sq;
                          if (_dragStartSquare != null &&
                              sq != null &&
                              sq != _dragStartSquare) {
                            _dragPreviewShape = Arrow(
                              color: drawColor.withValues(alpha: 0.6),
                              orig: _dragStartSquare!,
                              dest: sq,
                            );
                          } else {
                            _dragPreviewShape = null;
                          }
                        });
                      }
                    },
                    onPanEnd: (details) {
                      final from = _dragStartSquare;
                      final to = _dragCurrentSquare;
                      setState(() => _dragPreviewShape = null);
                      if (from != null && to != null && from != to) {
                        ref.read(customShapesProvider.notifier).toggleArrow(
                              gameId,
                              fen,
                              from,
                              to,
                              drawColor.withValues(alpha: 0.85),
                            );
                      }
                      _dragStartSquare = null;
                      _dragCurrentSquare = null;
                    },
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
