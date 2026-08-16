import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/game_entry.dart';
import '../providers/study_provider.dart';

/// Shows a dialog allowing the user to edit all metadata for a [GameEntry].
/// Persists the change to the DB (if the game has an id) and updates the
/// selected-game provider if the edited game is currently selected.
Future<void> showEditGameMetadataDialog(
  BuildContext context,
  WidgetRef ref,
  GameEntry game,
) {
  final whiteCtrl = TextEditingController(text: game.white);
  final blackCtrl = TextEditingController(text: game.black);
  final whiteEloCtrl = TextEditingController(text: game.whiteElo);
  final blackEloCtrl = TextEditingController(text: game.blackElo);
  final eventCtrl = TextEditingController(text: game.event);
  final siteCtrl = TextEditingController(text: game.site);
  final dateCtrl = TextEditingController(text: game.date);
  final roundCtrl = TextEditingController(text: game.round);
  final tagsCtrl = TextEditingController(text: game.tags.join(', '));

  String selectedResult = game.result.isEmpty ? '*' : game.result;
  String selectedTimeControl = game.timeControl;

  const results = ['*', '1-0', '0-1', '1/2-1/2'];
  const timeControls = ['', 'Bullet', 'Blitz', 'Rapid', 'Classical'];

  return showDialog(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: const Text('Edit Game Metadata'),
        content: SizedBox(
          width: 400,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: TextField(
                        controller: whiteCtrl,
                        decoration: const InputDecoration(labelText: 'White'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      flex: 2,
                      child: TextField(
                        controller: whiteEloCtrl,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(labelText: 'White Elo'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: TextField(
                        controller: blackCtrl,
                        decoration: const InputDecoration(labelText: 'Black'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      flex: 2,
                      child: TextField(
                        controller: blackEloCtrl,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(labelText: 'Black Elo'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: eventCtrl,
                  decoration: const InputDecoration(labelText: 'Event'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: siteCtrl,
                  decoration: const InputDecoration(labelText: 'Site / Location'),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: GestureDetector(
                        onTap: () async {
                          DateTime? initial;
                          try {
                            final parts = dateCtrl.text.split('.');
                            if (parts.length == 3) {
                              initial = DateTime(
                                int.parse(parts[0]),
                                int.parse(parts[1]),
                                int.parse(parts[2]),
                              );
                            }
                          } catch (_) {}
                          final picked = await showDatePicker(
                            context: context,
                            initialDate: initial ?? DateTime.now(),
                            firstDate: DateTime(1800),
                            lastDate: DateTime(2100),
                          );
                          if (picked != null) {
                            setState(() {
                              dateCtrl.text =
                                  '${picked.year}.${picked.month.toString().padLeft(2, '0')}.${picked.day.toString().padLeft(2, '0')}';
                            });
                          }
                        },
                        child: AbsorbPointer(
                          child: TextField(
                            controller: dateCtrl,
                            decoration: const InputDecoration(
                              labelText: 'Date',
                              suffixIcon: Icon(Icons.calendar_today, size: 16),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: roundCtrl,
                        decoration: const InputDecoration(labelText: 'Round'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: selectedResult,
                  decoration: const InputDecoration(labelText: 'Result'),
                  items: results
                      .map((r) => DropdownMenuItem(value: r, child: Text(r)))
                      .toList(),
                  onChanged: (v) {
                    if (v != null) setState(() => selectedResult = v);
                  },
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: selectedTimeControl,
                  decoration: const InputDecoration(labelText: 'Time Control'),
                  items: timeControls
                      .map((tc) => DropdownMenuItem(
                            value: tc,
                            child: Text(tc.isEmpty ? 'None' : tc),
                          ))
                      .toList(),
                  onChanged: (v) {
                    if (v != null) setState(() => selectedTimeControl = v);
                  },
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: tagsCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Tags (comma separated)',
                    hintText: 'e.g. tournament, sicilian, tactic',
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              final newTags = tagsCtrl.text
                  .split(',')
                  .map((t) => t.trim())
                  .where((t) => t.isNotEmpty)
                  .toList();

              final dateStr = dateCtrl.text.trim();
              final derivedYear = dateStr.split('.').firstOrNull ?? game.year;

              final updated = game.copyWith(
                white: whiteCtrl.text.trim(),
                black: blackCtrl.text.trim(),
                whiteElo: whiteEloCtrl.text.trim(),
                blackElo: blackEloCtrl.text.trim(),
                event: eventCtrl.text.trim(),
                site: siteCtrl.text.trim(),
                date: dateStr,
                year: derivedYear,
                round: roundCtrl.text.trim(),
                result: selectedResult,
                timeControl: selectedTimeControl,
                tags: newTags,
              );

              if (updated.id != null) {
                await ref.read(gameListProvider.notifier).updateMetadata(updated);
              }
              final selected = ref.read(selectedGameProvider);
              if (selected != null && selected.id == updated.id) {
                ref.read(selectedGameProvider.notifier).update(updated);
              }

              if (context.mounted) Navigator.pop(context);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    ),
  );
}
