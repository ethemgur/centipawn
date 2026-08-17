import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:chessground/chessground.dart';
import 'package:dartchess/dartchess.dart';
import '../theme.dart';
import '../providers/study_provider.dart';
import '../models/game_entry.dart';
import '../widgets/edit_game_metadata_dialog.dart';
import 'game_screen.dart';
import 'settings_screen.dart';

class GameListScreen extends ConsumerStatefulWidget {
  const GameListScreen({super.key});

  @override
  ConsumerState<GameListScreen> createState() => _GameListScreenState();
}

class _GameListScreenState extends ConsumerState<GameListScreen> {
  String _selectedTag = '';
  String _selectedTimeControl = '';
  String _selectedOpening = '';
  String _searchQuery = '';
  bool _showSearch = false;
  bool _isScrolled = false;
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(() {
      final scrolled = _scrollController.offset > 0;
      if (scrolled != _isScrolled) setState(() => _isScrolled = scrolled);
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  bool get _hasActiveFilters =>
      _selectedTag.isNotEmpty ||
      _selectedTimeControl.isNotEmpty ||
      _selectedOpening.isNotEmpty;

  void _clearAllFilters() => setState(() {
        _selectedTag = '';
        _selectedTimeControl = '';
        _selectedOpening = '';
      });

  @override
  Widget build(BuildContext context) {
    final gamesAsync = ref.watch(gameListProvider);

    return Scaffold(
      backgroundColor: AppColors.scaffoldBg,
      appBar: AppBar(
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: _isScrolled
              ? const Divider(height: 1, thickness: 1)
              : const SizedBox.shrink(),
        ),
        title: _showSearch
            ? TextField(
                controller: _searchController,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: 'Search games…',
                  border: InputBorder.none,
                  hintStyle: TextStyle(color: AppColors.textHint),
                ),
                style: const TextStyle(
                    color: AppColors.textPrimary, fontSize: 16),
                onChanged: (v) => setState(() => _searchQuery = v),
              )
            : const Text('My Games'),
        actions: [
          IconButton(
            icon: Icon(
                _showSearch ? Icons.close : Icons.search_outlined),
            tooltip: _showSearch ? 'Close search' : 'Search',
            onPressed: () => setState(() {
              _showSearch = !_showSearch;
              if (!_showSearch) {
                _searchQuery = '';
                _searchController.clear();
              }
            }),
          ),
          IconButton(
            icon: Badge(
              isLabelVisible: _hasActiveFilters,
              smallSize: 7,
              child: const Icon(Icons.tune_outlined),
            ),
            tooltip: 'Filter',
            onPressed: () => _showFilterSheet(context),
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Settings',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SettingsScreen()),
            ),
          ),
        ],
      ),
      body: gamesAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, s) => Center(child: Text('Error: $e')),
        data: (games) {
          final filteredGames = games.where((g) {
            if (_selectedTag.isNotEmpty &&
                !g.tags.contains(_selectedTag)) {
              return false;
            }
            if (_selectedTimeControl.isNotEmpty &&
                g.timeControl != _selectedTimeControl) {
              return false;
            }
            if (_selectedOpening.isNotEmpty &&
                g.openingCode != _selectedOpening) {
              return false;
            }
            if (_searchQuery.isNotEmpty) {
              final q = _searchQuery.toLowerCase();
              if (!g.white.toLowerCase().contains(q) &&
                  !g.black.toLowerCase().contains(q) &&
                  !g.event.toLowerCase().contains(q) &&
                  !g.openingCode.toLowerCase().contains(q)) {
                return false;
              }
            }
            return true;
          }).toList();

          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_hasActiveFilters)
                _ActiveFiltersBar(
                  selectedTimeControl: _selectedTimeControl,
                  selectedTag: _selectedTag,
                  selectedOpening: _selectedOpening,
                  onRemoveTimeControl: () =>
                      setState(() => _selectedTimeControl = ''),
                  onRemoveTag: () => setState(() => _selectedTag = ''),
                  onRemoveOpening: () =>
                      setState(() => _selectedOpening = ''),
                  onClearAll: _clearAllFilters,
                ),
              Expanded(
                child: filteredGames.isEmpty
                    ? Center(
                        child: Text(
                          _hasActiveFilters || _searchQuery.isNotEmpty
                              ? 'No games match the current filters.'
                              : 'No games yet.',
                          style: const TextStyle(
                              color: AppColors.textSecondary, fontSize: 14),
                        ),
                      )
                    : ListView.separated(
                        controller: _scrollController,
                        padding:
                            const EdgeInsets.only(top: 4, bottom: 80),
                        itemCount: filteredGames.length,
                        separatorBuilder: (_, index) =>
                            const Divider(height: 1, indent: 16),
                        itemBuilder: (_, index) {
                          final g = filteredGames[index];
                          return Dismissible(
                            key: ValueKey(g.id),
                            direction: DismissDirection.endToStart,
                            background: Container(
                              color: Colors.red.shade600,
                              alignment: Alignment.centerRight,
                              padding: const EdgeInsets.only(right: 20),
                              child: const Icon(Icons.delete_outline,
                                  color: Colors.white),
                            ),
                            onDismissed: (_) {
                              if (g.id != null) {
                                ref
                                    .read(gameListProvider.notifier)
                                    .deleteGame(g.id!);
                              }
                            },
                            child: _GameTile(game: g),
                          );
                        },
                      ),
              ),
            ],
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () async {
          final blank = GameEntry(
            white: '',
            black: '',
            event: 'New Game',
            result: '*',
            year: DateTime.now().year.toString(),
          );

          final saved =
              await ref.read(gameListProvider.notifier).addBlankGame(blank);
          ref.read(selectedGameProvider.notifier).select(saved);
          await ref.read(moveTreeProvider.notifier).loadFromDb(saved.id!);
          ref.invalidate(activeNodeProvider);
          ref.invalidate(reviewProvider);
          // Moments are keyed by ply into *this* game's mainline; leaving the
          // previous game's report would badge unrelated moves.
          ref.invalidate(criticalMomentsProvider);

          if (context.mounted) {
            Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => GameScreen(game: saved)),
            );
          }
        },
        backgroundColor: AppColors.primary,
        elevation: 4,
        child: const Icon(Icons.add, color: Colors.white),
      ),
    );
  }

  void _showFilterSheet(BuildContext context) {
    final games = ref.read(gameListProvider).maybeWhen(
          data: (v) => v,
          orElse: () => <GameEntry>[],
        );
    final allTags =
        games.expand((g) => g.tags).toSet().toList()..sort();
    final allOpenings = games
        .where((g) => g.openingCode.isNotEmpty)
        .map((g) => g.openingCode)
        .toSet()
        .toList()
      ..sort();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: AppColors.border,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Filter',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    if (_hasActiveFilters)
                      TextButton(
                        onPressed: () {
                          _clearAllFilters();
                          setSheet(() {});
                        },
                        style: TextButton.styleFrom(
                            foregroundColor: AppColors.primary),
                        child: const Text('Clear all'),
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                _sheetSection(
                  label: 'Time Control',
                  chips: ['Bullet', 'Blitz', 'Rapid', 'Classical']
                      .map((tc) => _SheetChip(
                            label: tc,
                            icon: timeControlIcon(tc),
                            selected: _selectedTimeControl == tc,
                            onTap: () {
                              setState(() => _selectedTimeControl =
                                  _selectedTimeControl == tc ? '' : tc);
                              setSheet(() {});
                            },
                          ))
                      .toList(),
                ),
                if (allTags.isNotEmpty) ...[
                  const SizedBox(height: 20),
                  _sheetSection(
                    label: 'Tag',
                    chips: allTags
                        .map((tag) => _SheetChip(
                              label: tag,
                              selected: _selectedTag == tag,
                              onTap: () {
                                setState(() => _selectedTag =
                                    _selectedTag == tag ? '' : tag);
                                setSheet(() {});
                              },
                            ))
                        .toList(),
                  ),
                ],
                if (allOpenings.isNotEmpty) ...[
                  const SizedBox(height: 20),
                  _sheetSection(
                    label: 'Opening',
                    chips: allOpenings
                        .map((op) => _SheetChip(
                              label: op,
                              selected: _selectedOpening == op,
                              onTap: () {
                                setState(() => _selectedOpening =
                                    _selectedOpening == op ? '' : op);
                                setSheet(() {});
                              },
                            ))
                        .toList(),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _sheetSection({
    required String label,
    required List<Widget> chips,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label.toUpperCase(),
          style: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: AppColors.textSecondary,
            letterSpacing: 0.8,
          ),
        ),
        const SizedBox(height: 10),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: chips
                .expand((c) => [c, const SizedBox(width: 8)])
                .toList()
              ..removeLast(),
          ),
        ),
      ],
    );
  }
}

// ── Active filters bar ────────────────────────────────────────────────────────

class _ActiveFiltersBar extends StatelessWidget {
  final String selectedTimeControl;
  final String selectedTag;
  final String selectedOpening;
  final VoidCallback onRemoveTimeControl;
  final VoidCallback onRemoveTag;
  final VoidCallback onRemoveOpening;
  final VoidCallback onClearAll;

  const _ActiveFiltersBar({
    required this.selectedTimeControl,
    required this.selectedTag,
    required this.selectedOpening,
    required this.onRemoveTimeControl,
    required this.onRemoveTag,
    required this.onRemoveOpening,
    required this.onClearAll,
  });

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: AppColors.surface,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    if (selectedTimeControl.isNotEmpty)
                      _chip(
                        selectedTimeControl,
                        onRemoveTimeControl,
                        icon: timeControlIcon(selectedTimeControl),
                      ),
                    if (selectedTag.isNotEmpty)
                      _chip(selectedTag, onRemoveTag),
                    if (selectedOpening.isNotEmpty)
                      _chip(selectedOpening, onRemoveOpening),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: onClearAll,
              child: const Text(
                'Clear all',
                style: TextStyle(
                  fontSize: 12,
                  color: AppColors.primary,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _chip(String label, VoidCallback onRemove, {IconData? icon}) {
    return Container(
      margin: const EdgeInsets.only(right: 6),
      padding: const EdgeInsets.fromLTRB(8, 4, 4, 4),
      decoration: BoxDecoration(
        color: AppColors.primaryLight,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 11, color: AppColors.primary),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: const TextStyle(
              fontSize: 12,
              color: AppColors.primary,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(width: 2),
          GestureDetector(
            onTap: onRemove,
            child: const Padding(
              padding: EdgeInsets.all(2),
              child: Icon(Icons.close, size: 12, color: AppColors.primary),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Sheet chip ────────────────────────────────────────────────────────────────

class _SheetChip extends StatelessWidget {
  final String label;
  final IconData? icon;
  final bool selected;
  final VoidCallback onTap;

  const _SheetChip({
    required this.label,
    this.icon,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? AppColors.primary : AppColors.surface,
          border: Border.all(
            color: selected ? AppColors.primary : AppColors.border,
          ),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 13,
                  color: selected
                      ? Colors.white
                      : AppColors.textSecondary),
              const SizedBox(width: 5),
            ],
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                color:
                    selected ? Colors.white : AppColors.textPrimary,
                fontWeight:
                    selected ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Game tile ─────────────────────────────────────────────────────────────────

class _GameTile extends ConsumerWidget {
  final GameEntry game;
  const _GameTile({required this.game});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListTile(
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: SizedBox(
          width: 52,
          height: 52,
          child: _MiniChessBoard(fen: game.lastFen),
        ),
      ),
      title: Text(
        game.title,
        style: const TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w600,
          color: AppColors.textPrimary,
        ),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 2),
          Row(
            children: [
              _resultText(game.result),
              if (game.event.isNotEmpty) ...[
                const Text(' · ',
                    style: TextStyle(
                        color: AppColors.textSecondary, fontSize: 12)),
                Flexible(
                  child: Text(
                    game.event,
                    style: const TextStyle(
                        fontSize: 13, color: AppColors.textSecondary),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
              if (_formatDate(game).isNotEmpty) ...[
                const Text(' · ',
                    style: TextStyle(
                        color: AppColors.textSecondary, fontSize: 12)),
                Text(
                  _formatDate(game),
                  style: const TextStyle(
                      fontSize: 12, color: AppColors.textSecondary),
                ),
              ],
            ],
          ),
          if (game.tags.isNotEmpty ||
              game.timeControl.isNotEmpty ||
              game.openingCode.isNotEmpty) ...[
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                if (game.openingCode.isNotEmpty)
                  _buildMiniTag(
                    game.openingCode,
                    Colors.green.shade50,
                    Colors.green.shade800,
                    icon: Icons.auto_stories_outlined,
                  ),
                if (game.timeControl.isNotEmpty)
                  _buildMiniTag(
                    game.timeControl,
                    Colors.blue.shade100,
                    Colors.blue.shade800,
                    icon: timeControlIcon(game.timeControl),
                  ),
                ...game.tags.map((t) => _buildMiniTag(
                    t, Colors.grey.shade200, Colors.grey.shade800)),
              ],
            ),
          ],
        ],
      ),
      onLongPress: () => showEditGameMetadataDialog(context, ref, game),
      onTap: () async {
        if (game.id == null) return;

        ref.read(selectedGameProvider.notifier).select(game);
        await ref.read(moveTreeProvider.notifier).loadFromDb(game.id!);
        ref.invalidate(activeNodeProvider);
        ref.invalidate(reviewProvider);
        // Moments are keyed by ply into *this* game's mainline; leaving the
        // previous game's report would badge unrelated moves.
        ref.invalidate(criticalMomentsProvider);

        if (game.isReviewed) {
          Future.microtask(
              () => ref.read(reviewProvider.notifier).markCompleted());
        }

        if (!context.mounted) return;
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => GameScreen(game: game)),
        );
      },
    );
  }

  Widget _resultText(String result) => Text(
        result,
        style: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: AppColors.textSecondary,
        ),
      );

  Widget _buildMiniTag(String text, Color bg, Color textCol,
      {IconData? icon}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
          color: bg, borderRadius: BorderRadius.circular(4)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 10, color: textCol),
            const SizedBox(width: 3),
          ],
          Text(
            text,
            style: TextStyle(
                fontSize: 10,
                color: textCol,
                fontWeight: FontWeight.w500),
          ),
        ],
      ),
    );
  }

  static String _formatDate(GameEntry game) {
    if (game.date.isNotEmpty) {
      final parts = game.date.split('.');
      if (parts.length >= 3) {
        final year = int.tryParse(parts[0]);
        final month = int.tryParse(parts[1]);
        final day = int.tryParse(parts[2]);
        if (year != null &&
            month != null &&
            day != null &&
            month >= 1 &&
            month <= 12 &&
            day >= 1 &&
            day <= 31) {
          const monthNames = [
            'January', 'February', 'March', 'April', 'May', 'June',
            'July', 'August', 'September', 'October', 'November',
            'December'
          ];
          return '$day ${monthNames[month - 1]} $year';
        }
      }
    }
    return game.year;
  }
}

// ── Mini board thumbnail ──────────────────────────────────────────────────────

class _MiniChessBoard extends StatelessWidget {
  final String fen;
  const _MiniChessBoard({required this.fen});

  @override
  Widget build(BuildContext context) {
    String validFen = fen;
    try {
      Chess.fromSetup(Setup.parseFen(fen));
    } catch (_) {
      validFen =
          'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';
    }

    return StaticChessboard(
      size: 52,
      orientation: Side.white,
      fen: validFen,
    );
  }
}
