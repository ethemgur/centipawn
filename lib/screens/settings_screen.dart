import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/game_entry.dart';
import '../providers/study_provider.dart';
import '../services/auth_service.dart';
import '../theme.dart';
import 'login_screen.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authAsync = ref.watch(authStateProvider);
    final depth = ref.watch(reviewDepthProvider);
    final myNames = ref.watch(myNamesProvider);
    final gamesAsync = ref.watch(gameListProvider);

    return Scaffold(
      backgroundColor: AppColors.scaffoldBg,
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          // ── Analysis section ─────────────────────────────────────────────
          _SectionHeader('Analysis'),
          ListTile(
            leading: const Icon(Icons.speed_outlined),
            title: const Text('Review depth'),
            subtitle: Text('Depth $depth — higher is stronger but slower'),
            trailing: SizedBox(
              width: 160,
              child: Slider(
                value: depth.toDouble(),
                min: 6,
                max: 20,
                divisions: 7,
                label: '$depth',
                onChanged: (v) =>
                    ref.read(reviewDepthProvider.notifier).setDepth(v.round()),
              ),
            ),
          ),
          const Divider(),
          // ── Player profile section ────────────────────────────────────────
          _SectionHeader('Player Profile'),
          ListTile(
            leading: const Icon(Icons.person_pin_outlined),
            title: const Text('My names'),
            subtitle: myNames.isEmpty
                ? const Text('Not set — tap to select your name(s) from your games')
                : Text(myNames.join(', ')),
            onTap: () => _showMyNamesDialog(context, ref, gamesAsync.asData?.value ?? []),
          ),
          const Divider(),
          // ── Account section ─────────────────────────────────────────────
          _SectionHeader('Account'),
          authAsync.when(
            loading: () => const ListTile(
              leading: CircularProgressIndicator(),
              title: Text('Loading…'),
            ),
            error: (_, _) => const ListTile(title: Text('Error loading account')),
            data: (user) {
              final isAnon = user == null || user.isAnonymous;
              if (isAnon) {
                return Column(
                  children: [
                    ListTile(
                      leading: const Icon(Icons.person_outline),
                      title: const Text('Guest'),
                      subtitle: const Text('Sign in to back up your games'),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 8),
                      child: SizedBox(
                        width: double.infinity,
                        height: 44,
                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.primary,
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                          icon: const Icon(Icons.login, size: 18),
                          label: const Text('Sign In / Create Account'),
                          onPressed: () async {
                            final ok = await Navigator.of(context).push<bool>(
                              MaterialPageRoute(
                                  builder: (_) => const LoginScreen()),
                            );
                            if (ok == true && context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                    content: Text('Signed in successfully')),
                              );
                            }
                          },
                        ),
                      ),
                    ),
                  ],
                );
              }
              return Column(
                children: [
                  ListTile(
                    leading: const Icon(Icons.person),
                    title: Text(user.email ?? user.displayName ?? 'Signed in'),
                    subtitle: const Text('Your account'),
                  ),
                  ListTile(
                    leading: const Icon(Icons.logout, color: Colors.red),
                    title: const Text('Sign Out',
                        style: TextStyle(color: Colors.red)),
                    onTap: () async {
                      final confirm = await showDialog<bool>(
                        context: context,
                        builder: (ctx) => AlertDialog(
                          title: const Text('Sign Out'),
                          content: const Text('Are you sure you want to sign out?'),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(ctx, false),
                              child: const Text('Cancel'),
                            ),
                            TextButton(
                              onPressed: () => Navigator.pop(ctx, true),
                              child: const Text('Sign Out',
                                  style: TextStyle(color: Colors.red)),
                            ),
                          ],
                        ),
                      );
                      if (confirm == true) {
                        await AuthService.instance.signOut();
                        await AuthService.instance.ensureSignedIn();
                      }
                    },
                  ),
                ],
              );
            },
          ),
          const Divider(),
          // ── About section ────────────────────────────────────────────────
          _SectionHeader('About'),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('Centipawn'),
            subtitle: const Text('Chess study & analysis app  ·  v1.0.0'),
          ),
          ListTile(
            leading: const Icon(Icons.bolt_outlined),
            title: const Text('Engine'),
            subtitle: const Text('Stockfish — runs locally on device'),
          ),
          ListTile(
            leading: const Icon(Icons.storage_outlined),
            title: const Text('Storage'),
            subtitle: const Text('Games stored locally in SQLite'),
          ),
          ListTile(
            leading: const Icon(Icons.gavel_outlined),
            title: const Text('Licenses'),
            subtitle: const Text('Open source licenses'),
            onTap: () => showLicensePage(
              context: context,
              applicationName: 'Centipawn',
              applicationVersion: '1.0.0',
              applicationLegalese: '© 2024 Centipawn contributors\nLicensed under GNU GPL v3.0',
            ),
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }
}

void _showMyNamesDialog(
    BuildContext context, WidgetRef ref, List<GameEntry> games) {
  // Collect all unique player names from the game list.
  final allNames = <String>{};
  for (final g in games) {
    if (g.white.isNotEmpty) allNames.add(g.white);
    if (g.black.isNotEmpty) allNames.add(g.black);
  }
  final sorted = allNames.toList()..sort();
  final current = Set<String>.from(ref.read(myNamesProvider));

  showDialog<void>(
    context: context,
    builder: (ctx) {
      return StatefulBuilder(
        builder: (ctx, setState) {
          return AlertDialog(
            title: const Text('My Names'),
            content: sorted.isEmpty
                ? const Text('Import some games first to see player names.')
                : SizedBox(
                    width: double.maxFinite,
                    child: ListView(
                      shrinkWrap: true,
                      children: sorted.map((name) {
                        return CheckboxListTile(
                          title: Text(name),
                          value: current.contains(name),
                          onChanged: (checked) {
                            setState(() {
                              if (checked == true) {
                                current.add(name);
                              } else {
                                current.remove(name);
                              }
                            });
                          },
                        );
                      }).toList(),
                    ),
                  ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: () {
                  ref.read(myNamesProvider.notifier).setNames(current.toList());
                  Navigator.pop(ctx);
                },
                child: const Text('Save'),
              ),
            ],
          );
        },
      );
    },
  );
}

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader(this.title);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        title.toUpperCase(),
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: AppColors.textSecondary,
          letterSpacing: 0.8,
        ),
      ),
    );
  }
}
