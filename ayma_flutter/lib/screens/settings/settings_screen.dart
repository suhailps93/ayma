// App settings: voice/accent, privacy toggles, matching pause, and account management.
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../env.dart';
import '../../providers/providers.dart';
import '../../services/api_service.dart';
import '../../theme.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  bool _pauseLoading = false;
  bool _savingVoice = false;
  bool _clearingMemory = false;
  bool _previewingVoice = false;

  String? _voiceGender;
  String? _accentLocale;
  String? _voiceName;
  final TextEditingController _accentCtrl = TextEditingController();

  Map<String, List<String>> get _voicesByGender => Env.liveProvider == 'gemini'
      ? const {
          'female': ['Charon', 'Puck', 'Kore', 'Aoede'],
          'male': ['Fenrir'],
        }
      : const {
          'female': ['Linden', 'Harbor'],
          'male': ['March', 'Ash'],
        };

  @override
  void dispose() {
    _accentCtrl.dispose();
    super.dispose();
  }

  Future<void> _togglePause(bool value) async {
    setState(() => _pauseLoading = true);
    try {
      await updateProfile({'matching_paused': value}, ref);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not update: $e')),
        );
      }
    }
    if (mounted) setState(() => _pauseLoading = false);
  }

  Future<void> _toggleSimulationTranscript(bool value) async {
    final profile = ref.read(profileProvider).valueOrNull;
    final currentPrefs = Map<String, dynamic>.from(profile?.matchingPrefs ?? {});
    currentPrefs['show_simulation_transcript'] = value;
    try {
      await updateProfile({'matching_prefs': currentPrefs}, ref);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not update preference: $e')),
        );
      }
    }
  }

  Future<void> _deleteAccount() async {
    try {
      // Invalidate providers first to stop active listeners and prevent permission errors
      // during the data deletion phase.
      ref.invalidate(notificationsProvider);
      ref.invalidate(matchesProvider);
      ref.invalidate(profileProvider);
      ref.invalidate(insightsProvider);
      
      await ref.read(authControllerProvider).deleteAccount();
      if (mounted) context.go('/auth');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Delete failed: $e')),
        );
      }
    }
  }

  Future<void> _saveAymaVoiceSettings() async {
    final voiceGender = _voiceGender;
    final accentLocale = _accentCtrl.text.trim();
    final voiceName = _voiceName;
    if (voiceGender == null || accentLocale.isEmpty || voiceName == null) {
      return;
    }
    setState(() => _savingVoice = true);
    try {
      await ApiService.updateVoiceSettings(
        voiceGender: voiceGender,
        accentLocale: accentLocale,
        accentLabel: accentLocale,
      );
      await updateProfile({'voice_preference': voiceName}, ref);
      ref.invalidate(profileProvider);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Ayma voice settings updated')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not update voice settings: $e')),
        );
      }
    }
    if (mounted) setState(() => _savingVoice = false);
  }

  Future<void> _previewCurrentVoice() async {
    if (_previewingVoice) {
      return;
    }
    final voiceGender = _voiceGender;
    final accentLocale = _accentCtrl.text.trim();
    final voiceName = _voiceName;
    if (voiceGender == null || accentLocale.isEmpty || voiceName == null) {
      return;
    }

    setState(() => _previewingVoice = true);
    try {
      await ApiService.updateVoiceSettings(
        voiceGender: voiceGender,
        accentLocale: accentLocale,
        accentLabel: accentLocale,
      );
      await updateProfile({'voice_preference': voiceName}, ref);
      ref.invalidate(profileProvider);
      final audio = ref.read(audioServiceProvider);
      final ok = await audio.sendLivePrompt(
        'Speak exactly one short preview sentence in the selected language/accent "$accentLocale" and in a natural ${voiceGender.toLowerCase()} voice. '
        'Template meaning: "Hi, I am Ayma. This is your selected voice and accent preview."',
      );
      if (!ok && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not play voice preview')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Voice preview failed: $e')),
        );
      }
    }
    if (mounted) setState(() => _previewingVoice = false);
  }

  Future<void> _clearAymaKnowledge() async {
    setState(() => _clearingMemory = true);
    try {
      await ApiService.clearAymaKnowledge();
      await ref.read(audioServiceProvider).clearLocalTranscript();
      ref.invalidate(insightsProvider);
      ref.invalidate(profileProvider);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Ayma memory cleared successfully')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not clear Ayma memory: $e')),
        );
      }
    }
    if (mounted) setState(() => _clearingMemory = false);
  }

  void _confirmClearAymaKnowledge() {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: context.ac.bgCard,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          'Clear Ayma memory',
          style: TextStyle(color: context.ac.fg, fontSize: 18),
        ),
        content: Text(
          'This deletes everything Ayma learned from conversations and resets follow-up questions. Your account stays active.',
          style: TextStyle(color: context.ac.fgDim, fontSize: 13, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Cancel', style: TextStyle(color: context.ac.fgDim)),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _clearAymaKnowledge();
            },
            child:
                const Text('Clear', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
  }

  void _confirmDelete() {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: context.ac.bgCard,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          'Delete account',
          style: TextStyle(color: context.ac.fg, fontSize: 18),
        ),
        content: Text(
          'This permanently deletes your profile, matches, and all data. This cannot be undone.',
          style: TextStyle(color: context.ac.fgDim, fontSize: 13, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Cancel', style: TextStyle(color: context.ac.fgDim)),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _deleteAccount();
            },
            child:
                const Text('Delete', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final profileAsync = ref.watch(profileProvider);
    final currentUser = ref.watch(currentUserProvider);
    final profile = profileAsync.valueOrNull;
    final displayName = profile?.displayName ?? 'You';
    final matchingPaused = profile?.matchingPaused ?? false;
    final showSimulationTranscript = profile?.matchingPrefs['show_simulation_transcript'] as bool? ?? true;
    if (profile != null) {
      _voiceName ??= profile.voicePreference.isNotEmpty
          ? profile.voicePreference
          : 'Charon';
      _voiceGender ??= (profile.voicePreference.toLowerCase() == 'march' ||
              profile.voicePreference.toLowerCase() == 'ash' ||
              profile.voicePreference.toLowerCase() == 'fenrir')
          ? 'male'
          : 'female';
    }

    return Scaffold(
      backgroundColor: context.ac.bg,
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 120),
          children: [
            // Header
            Text(
              'Settings',
              style: AymaFonts.serif(size: 36, color: context.ac.fg),
            ).animate().fadeIn(duration: 400.ms),
            const SizedBox(height: 28),

            // Appearance section
            _SectionLabel('Appearance'),
            _AppearanceTile(),
            const SizedBox(height: 20),

            // Account section
            _SectionLabel('Account'),
            _Tile(
              icon: Icons.person_outline_rounded,
              title: displayName,
              subtitle: currentUser?.email ?? '',
              delay: 60,
            ),
            const SizedBox(height: 2),
            _Tile(
              icon: Icons.admin_panel_settings_outlined,
              title: 'Admin console',
              subtitle: 'Password-protected God view across all stored user data',
              onTap: () => context.push('/admin'),
              delay: 80,
            ),

            const SizedBox(height: 20),

            // Agent section
            _SectionLabel('Ayma'),
            FutureBuilder<Map<String, String>>(
              future: ApiService.getVoiceSettings(),
              builder: (context, snapshot) {
                final settings = snapshot.data;
                _accentLocale ??= settings?['accent_locale'] ?? 'en-US';
                if (_accentCtrl.text.isEmpty) {
                  _accentCtrl.text = _accentLocale!;
                }
                _voiceGender ??=
                    settings?['voice_gender'] ?? _voiceGender ?? 'female';
                final voices =
                    _voicesByGender[_voiceGender] ?? _voicesByGender['female']!;
                if (!voices.contains(_voiceName)) _voiceName = voices.first;

                return Container(
                  margin: const EdgeInsets.only(bottom: 2),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  decoration: BoxDecoration(
                    color: context.ac.bgElev,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: context.ac.lineSoft, width: 0.5),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.record_voice_over_rounded,
                              size: 18, color: context.ac.fgDim),
                          const SizedBox(width: 14),
                          Text(
                            'Voice & accent',
                            style:
                                TextStyle(color: context.ac.fg, fontSize: 14),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      _InlineTextInput(
                        label: 'Preferred language accent',
                        controller: _accentCtrl,
                        hintText: 'e.g. en-US, Spanish (Mexico), Hindi (India)',
                        onSubmitted: (_) => _previewCurrentVoice(),
                      ),
                      const SizedBox(height: 10),
                      _InlineDropdown<String>(
                        label: 'Ayma voice',
                        value: _voiceGender,
                        items: _voicesByGender.keys.toList(),
                        format: (value) =>
                            value == 'male' ? 'Male voices' : 'Female voices',
                        onChanged: (value) {
                          setState(() {
                            _voiceGender = value;
                            final nextVoices = _voicesByGender[value]!;
                            if (!nextVoices.contains(_voiceName)) {
                              _voiceName = nextVoices.first;
                            }
                          });
                          _previewCurrentVoice();
                        },
                      ),
                      const SizedBox(height: 10),
                      _InlineDropdown<String>(
                        label: 'Voice name',
                        value: _voiceName,
                        items: voices,
                        onChanged: (value) {
                          setState(() => _voiceName = value);
                          _previewCurrentVoice();
                        },
                      ),
                      const SizedBox(height: 12),
                      Align(
                        alignment: Alignment.centerRight,
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            TextButton(
                              onPressed: _savingVoice || _previewingVoice
                                  ? null
                                  : _previewCurrentVoice,
                              child: const Text('Play preview'),
                            ),
                            TextButton(
                              onPressed: _savingVoice || _previewingVoice
                                  ? null
                                  : _saveAymaVoiceSettings,
                              child: _savingVoice || _previewingVoice
                                  ? SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: context.ac.accent,
                                      ),
                                    )
                                  : const Text('Save Ayma settings'),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                )
                    .animate(delay: 140.ms)
                    .fadeIn(duration: 300.ms)
                    .slideX(begin: 0.03, end: 0);
              },
            ),
            const SizedBox(height: 2),
            _Tile(
              icon: Icons.auto_delete_rounded,
              title: 'Delete everything Ayma knows about me',
              subtitle: 'Clear Ayma memory and reset learned profile',
              titleColor: Colors.redAccent.shade100,
              trailing: _clearingMemory
                  ? SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: context.ac.accent,
                      ),
                    )
                  : null,
              onTap: _clearingMemory ? null : _confirmClearAymaKnowledge,
              delay: 180,
            ),

            const SizedBox(height: 20),

            // Privacy section
            _SectionLabel('Privacy'),
            _Tile(
              icon: Icons.visibility_off_outlined,
              title: 'Pause matching',
              subtitle: matchingPaused
                  ? 'Your profile is hidden'
                  : 'Temporarily hide your profile',
              trailing: _pauseLoading
                  ? SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: context.ac.accent),
                    )
                  : Switch(
                      value: matchingPaused,
                      onChanged: _togglePause,
                      activeColor: context.ac.accent,
                      inactiveThumbColor: context.ac.fgMute,
                      inactiveTrackColor: context.ac.lineSoft,
                    ),
              delay: 260,
            ),
            const SizedBox(height: 2),
            _Tile(
              icon: Icons.chat_bubble_outline_rounded,
              title: 'Show simulation transcripts',
              subtitle: 'Show chat logs between AI agents',
              trailing: Switch(
                value: showSimulationTranscript,
                onChanged: _toggleSimulationTranscript,
                activeColor: context.ac.accent,
                inactiveThumbColor: context.ac.fgMute,
                inactiveTrackColor: context.ac.lineSoft,
              ),
              delay: 280,
            ),
            const SizedBox(height: 2),
            _Tile(
              icon: Icons.delete_outline_rounded,
              title: 'Delete account',
              titleColor: Colors.redAccent.shade100,
              onTap: _confirmDelete,
              delay: 300,
            ),

            const SizedBox(height: 20),

            // About section
            _SectionLabel('About'),
            _Tile(
              icon: Icons.info_outline_rounded,
              title: 'Version',
              subtitle: '1.0.0',
              delay: 340,
            ),

            const SizedBox(height: 20),

            _SignOutTile(delay: 380),
          ],
        ),
      ),
    );
  }
}

class _InlineDropdown<T> extends StatelessWidget {
  const _InlineDropdown({
    required this.label,
    required this.value,
    required this.items,
    required this.onChanged,
    this.format,
  });

  final String label;
  final T? value;
  final List<T> items;
  final ValueChanged<T?> onChanged;
  final String Function(T value)? format;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(color: context.ac.fgMute, fontSize: 12),
        ),
        const SizedBox(height: 6),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: context.ac.bgCard,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: context.ac.lineSoft, width: 0.5),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<T>(
              value: value,
              isExpanded: true,
              dropdownColor: context.ac.bgCard,
              iconEnabledColor: context.ac.fgDim,
              style: TextStyle(color: context.ac.fg, fontSize: 13),
              items: items
                  .map(
                    (item) => DropdownMenuItem<T>(
                      value: item,
                      child: Text(format?.call(item) ?? item.toString()),
                    ),
                  )
                  .toList(),
              onChanged: onChanged,
            ),
          ),
        ),
      ],
    );
  }
}

class _InlineTextInput extends StatelessWidget {
  const _InlineTextInput({
    required this.label,
    required this.controller,
    required this.hintText,
    this.onSubmitted,
  });

  final String label;
  final TextEditingController controller;
  final String hintText;
  final ValueChanged<String>? onSubmitted;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(color: context.ac.fgMute, fontSize: 12),
        ),
        const SizedBox(height: 6),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: context.ac.bgCard,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: context.ac.lineSoft, width: 0.5),
          ),
          child: TextField(
            controller: controller,
            onSubmitted: onSubmitted,
            style: TextStyle(color: context.ac.fg, fontSize: 13),
            decoration: InputDecoration(
              hintText: hintText,
              hintStyle:
                  TextStyle(color: context.ac.fgMute, fontSize: 12),
              border: InputBorder.none,
              isDense: true,
            ),
          ),
        ),
      ],
    );
  }
}

// ── Helpers ───────────────────────────────────────────────────────────────────

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Text(
          text.toUpperCase(),
          style: AymaFonts.mono(size: 9, color: context.ac.fgMute),
        ),
      );
}

class _Tile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback? onTap;
  final Color? titleColor;
  final Widget? trailing;
  final int delay;

  const _Tile({
    required this.icon,
    required this.title,
    this.subtitle,
    this.onTap,
    this.titleColor,
    this.trailing,
    this.delay = 0,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 2),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: context.ac.bgElev,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: context.ac.lineSoft, width: 0.5),
        ),
        child: Row(
          children: [
            Icon(icon, size: 18, color: titleColor ?? context.ac.fgDim),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: titleColor ?? context.ac.fg,
                      fontSize: 14,
                    ),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle!,
                      style: TextStyle(color: context.ac.fgMute, fontSize: 12),
                    ),
                  ],
                ],
              ),
            ),
            if (trailing != null)
              trailing!
            else if (onTap != null)
              Icon(Icons.chevron_right_rounded,
                  size: 16, color: context.ac.fgMute),
          ],
        ),
      ),
    )
        .animate(delay: Duration(milliseconds: delay))
        .fadeIn(duration: 300.ms)
        .slideX(begin: 0.03, end: 0);
  }
}

class _AppearanceTile extends ConsumerWidget {
  const _AppearanceTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(themeModeProvider);
    final isDark = mode == ThemeMode.dark;
    return GestureDetector(
      onTap: () => ref.read(themeModeProvider.notifier).toggle(),
      child: Container(
        margin: const EdgeInsets.only(bottom: 2),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: context.ac.bgElev,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: context.ac.lineSoft, width: 0.5),
        ),
        child: Row(
          children: [
            Icon(
              isDark ? Icons.dark_mode_outlined : Icons.light_mode_outlined,
              size: 18,
              color: context.ac.fgDim,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                isDark ? 'Dark' : 'Light',
                style: TextStyle(color: context.ac.fg, fontSize: 14),
              ),
            ),
            Switch(
              value: isDark,
              onChanged: (_) => ref.read(themeModeProvider.notifier).toggle(),
              activeColor: context.ac.accent,
              inactiveThumbColor: context.ac.fgMute,
              inactiveTrackColor: context.ac.lineSoft,
            ),
          ],
        ),
      ),
    );
  }
}

class _SignOutTile extends ConsumerWidget {
  final int delay;
  const _SignOutTile({required this.delay});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return GestureDetector(
      onTap: () async {
        await ref.read(authControllerProvider).signOut();
        if (context.mounted) context.go('/auth');
      },
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          color: context.ac.bgElev,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: context.ac.lineSoft, width: 0.5),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.logout_rounded,
                size: 16, color: Colors.redAccent.shade100),
            const SizedBox(width: 8),
            Text(
              'Sign out',
              style: TextStyle(
                color: Colors.redAccent.shade100,
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    ).animate(delay: Duration(milliseconds: delay)).fadeIn(duration: 300.ms);
  }
}
