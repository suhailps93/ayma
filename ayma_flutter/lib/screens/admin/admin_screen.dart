import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/providers.dart';
import '../../services/api_service.dart';
import '../../theme.dart';

class AdminScreen extends ConsumerStatefulWidget {
  const AdminScreen({super.key});

  @override
  ConsumerState<AdminScreen> createState() => _AdminScreenState();
}

class _AdminScreenState extends ConsumerState<AdminScreen> {
  final _passwordCtrl = TextEditingController();
  final _searchCtrl = TextEditingController();
  final _genderCtrl = TextEditingController();
  final _communityCtrl = TextEditingController();
  final _intentCtrl = TextEditingController();
  final _minAgeCtrl = TextEditingController();
  final _maxAgeCtrl = TextEditingController();

  bool _unlocking = false;
  bool _loadingUsers = false;
  bool _loadingDetail = false;
  String? _adminPassword;
  String? _selectedUserId;
  String? _error;

  bool? _onboardingComplete;
  bool? _matchingPaused;
  bool? _hasPhotos;
  bool? _hasMatches;
  bool? _hasMessages;

  List<Map<String, dynamic>> _users = const [];
  Map<String, dynamic>? _detail;

  bool get _isUnlocked => (_adminPassword ?? '').isNotEmpty;

  @override
  void dispose() {
    _passwordCtrl.dispose();
    _searchCtrl.dispose();
    _genderCtrl.dispose();
    _communityCtrl.dispose();
    _intentCtrl.dispose();
    _minAgeCtrl.dispose();
    _maxAgeCtrl.dispose();
    super.dispose();
  }

  Future<void> _unlock() async {
    final password = _passwordCtrl.text.trim();
    if (password.isEmpty) {
      setState(() => _error = 'Enter the admin password.');
      return;
    }
    setState(() {
      _unlocking = true;
      _error = null;
    });
    try {
      _adminPassword = password;
      await _loadUsers();
    } catch (e) {
      _adminPassword = null;
      setState(() => _error = '$e');
    }
    if (mounted) {
      setState(() => _unlocking = false);
    }
  }

  Future<void> _loadUsers() async {
    final password = _adminPassword;
    if (password == null || password.isEmpty) {
      return;
    }
    setState(() {
      _loadingUsers = true;
      _error = null;
    });
    try {
      final users = await ApiService.getAdminUsers(
        adminPassword: password,
        query: _searchCtrl.text,
        gender: _blankToNull(_genderCtrl.text),
        communityProfile: _blankToNull(_communityCtrl.text),
        intentType: _blankToNull(_intentCtrl.text),
        onboardingComplete: _onboardingComplete,
        matchingPaused: _matchingPaused,
        hasPhotos: _hasPhotos,
        hasMatches: _hasMatches,
        hasMessages: _hasMessages,
        minAge: _parseInt(_minAgeCtrl.text),
        maxAge: _parseInt(_maxAgeCtrl.text),
      );
      if (!mounted) return;
      setState(() {
        _users = users;
        if (_users.isEmpty) {
          _selectedUserId = null;
          _detail = null;
        } else if (_selectedUserId == null ||
            !_users.any((user) => '${user['id']}' == _selectedUserId)) {
          _selectedUserId = '${_users.first['id']}';
        }
      });
      if (_selectedUserId != null) {
        await _loadDetail(_selectedUserId!);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    }
    if (mounted) {
      setState(() => _loadingUsers = false);
    }
  }

  Future<void> _loadDetail(String userId) async {
    final password = _adminPassword;
    if (password == null || password.isEmpty) return;
    setState(() {
      _selectedUserId = userId;
      _loadingDetail = true;
      _error = null;
    });
    try {
      final detail = await ApiService.getAdminUserDetail(
        userId: userId,
        adminPassword: password,
      );
      if (!mounted) return;
      setState(() => _detail = detail);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    }
    if (mounted) {
      setState(() => _loadingDetail = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentUser = ref.watch(currentUserProvider);
    final signedInAs = currentUser?.id ?? 'signed out';

    return Scaffold(
      backgroundColor: context.ac.bg,
      appBar: AppBar(
        title: Text('Admin Console', style: AymaFonts.serif(size: 28)),
        actions: [
          if (_isUnlocked)
            IconButton(
              onPressed: _loadingUsers ? null : _loadUsers,
              icon: const Icon(Icons.refresh_rounded),
            ),
        ],
      ),
      body: !_isUnlocked
          ? _buildUnlockView(context, signedInAs)
          : _buildConsole(context),
    );
  }

  Widget _buildUnlockView(BuildContext context, String signedInAs) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Card(
          margin: const EdgeInsets.all(24),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('God view', style: AymaFonts.serif(size: 32, color: context.ac.fg)),
                const SizedBox(height: 8),
                Text(
                  'Open from any profile or while signed out. Current session: $signedInAs.',
                  style: TextStyle(color: context.ac.fgDim, fontSize: 14, height: 1.5),
                ),
                const SizedBox(height: 8),
                Text(
                  'This page exposes all stored user data if the password is correct.',
                  style: TextStyle(color: context.ac.fgMute, fontSize: 12, height: 1.5),
                ),
                const SizedBox(height: 20),
                TextField(
                  controller: _passwordCtrl,
                  obscureText: true,
                  onSubmitted: (_) => _unlock(),
                  decoration: const InputDecoration(
                    labelText: 'Admin password',
                    prefixIcon: Icon(Icons.lock_outline_rounded),
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _error!,
                    style: const TextStyle(color: Colors.redAccent, fontSize: 12),
                  ),
                ],
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _unlocking ? null : _unlock,
                    icon: _unlocking
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.admin_panel_settings_outlined),
                    label: const Text('Unlock admin console'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildConsole(BuildContext context) {
    final wide = MediaQuery.of(context).size.width >= 1100;
    final listPane = Column(
      children: [
        _buildFilters(context),
        Expanded(
          child: Card(
            margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: _loadingUsers
                ? const Center(child: CircularProgressIndicator())
                : _users.isEmpty
                    ? Center(
                        child: Text(
                          'No users matched these filters.',
                          style: TextStyle(color: context.ac.fgDim),
                        ),
                      )
                    : ListView.separated(
                        itemCount: _users.length,
                        separatorBuilder: (_, __) => Divider(color: context.ac.lineSoft),
                        itemBuilder: (context, index) {
                          final user = _users[index];
                          final id = '${user['id']}';
                          final selected = id == _selectedUserId;
                          return ListTile(
                            selected: selected,
                            selectedTileColor: context.ac.accent.withValues(alpha: 0.08),
                            onTap: () => _loadDetail(id),
                            title: Text(
                              (user['display_name'] as String?)?.trim().isNotEmpty == true
                                  ? '${user['display_name']}'
                                  : id,
                              style: TextStyle(color: context.ac.fg),
                            ),
                            subtitle: Text(
                              [
                                id,
                                '${user['community_profile'] ?? ''}',
                                '${user['intent_type'] ?? ''}',
                              ].where((part) => part.trim().isNotEmpty).join(' • '),
                              style: TextStyle(color: context.ac.fgMute, fontSize: 12),
                            ),
                            trailing: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Text(
                                  'msg ${user['message_count'] ?? 0} • match ${user['match_count'] ?? 0}',
                                  style: AymaFonts.mono(size: 8, color: context.ac.fgMute),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  'photo ${user['photo_count'] ?? 0} • unread ${user['unread_notifications'] ?? 0}',
                                  style: AymaFonts.mono(size: 8, color: context.ac.fgMute),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
          ),
        ),
      ],
    );

    final detailPane = _buildDetailPane(context);

    return Column(
      children: [
        if (_error != null)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.redAccent.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Colors.redAccent.withValues(alpha: 0.3)),
            ),
            child: Text(_error!, style: const TextStyle(color: Colors.redAccent)),
          ),
        Expanded(
          child: wide
              ? Row(
                  children: [
                    Expanded(flex: 4, child: listPane),
                    Expanded(flex: 6, child: detailPane),
                  ],
                )
              : Column(
                  children: [
                    Expanded(flex: 4, child: listPane),
                    Expanded(flex: 6, child: detailPane),
                  ],
                ),
        ),
      ],
    );
  }

  Widget _buildFilters(BuildContext context) {
    return Card(
      margin: const EdgeInsets.all(16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Filters', style: AymaFonts.mono(size: 9, color: context.ac.fgMute)),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                _filterField(_searchCtrl, 'Search user / bio / city', width: 240),
                _filterField(_genderCtrl, 'Gender', width: 130),
                _filterField(_communityCtrl, 'Community', width: 180),
                _filterField(_intentCtrl, 'Intent', width: 150),
                _filterField(_minAgeCtrl, 'Min age', width: 100, number: true),
                _filterField(_maxAgeCtrl, 'Max age', width: 100, number: true),
                _triStateFilter(
                  label: 'Onboarding',
                  value: _onboardingComplete,
                  onChanged: (value) => setState(() => _onboardingComplete = value),
                ),
                _triStateFilter(
                  label: 'Paused',
                  value: _matchingPaused,
                  onChanged: (value) => setState(() => _matchingPaused = value),
                ),
                _triStateFilter(
                  label: 'Has photos',
                  value: _hasPhotos,
                  onChanged: (value) => setState(() => _hasPhotos = value),
                ),
                _triStateFilter(
                  label: 'Has matches',
                  value: _hasMatches,
                  onChanged: (value) => setState(() => _hasMatches = value),
                ),
                _triStateFilter(
                  label: 'Has messages',
                  value: _hasMessages,
                  onChanged: (value) => setState(() => _hasMessages = value),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                FilledButton.icon(
                  onPressed: _loadingUsers ? null : _loadUsers,
                  icon: const Icon(Icons.search_rounded),
                  label: const Text('Apply'),
                ),
                const SizedBox(width: 12),
                TextButton(
                  onPressed: _loadingUsers
                      ? null
                      : () {
                          _searchCtrl.clear();
                          _genderCtrl.clear();
                          _communityCtrl.clear();
                          _intentCtrl.clear();
                          _minAgeCtrl.clear();
                          _maxAgeCtrl.clear();
                          setState(() {
                            _onboardingComplete = null;
                            _matchingPaused = null;
                            _hasPhotos = null;
                            _hasMatches = null;
                            _hasMessages = null;
                          });
                          _loadUsers();
                        },
                  child: const Text('Reset'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDetailPane(BuildContext context) {
    final detail = _detail;
    if (_loadingDetail) {
      return const Center(child: CircularProgressIndicator());
    }
    if (detail == null) {
      return Center(
        child: Text(
          'Select a user to inspect.',
          style: TextStyle(color: context.ac.fgDim),
        ),
      );
    }

    final user = (detail['user'] as Map?)?.cast<String, dynamic>() ?? const {};
    final stats = (detail['stats'] as Map?)?.cast<String, dynamic>() ?? const {};
    final media = ((detail['media'] as List?) ?? const []).cast<Map<String, dynamic>>();
    final memories =
        ((detail['memories'] as List?) ?? const []).cast<Map<String, dynamic>>();
    final threads =
        ((detail['dm_threads'] as List?) ?? const []).cast<Map<String, dynamic>>();
    final matches =
        ((detail['matches'] as List?) ?? const []).cast<Map<String, dynamic>>();

    return ListView(
      padding: const EdgeInsets.fromLTRB(0, 16, 16, 16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  (user['display_name'] as String?)?.trim().isNotEmpty == true
                      ? '${user['display_name']}'
                      : '${user['id']}',
                  style: AymaFonts.serif(size: 30, color: context.ac.fg),
                ),
                const SizedBox(height: 6),
                SelectableText(
                  '${user['id']}',
                  style: AymaFonts.mono(size: 9, color: context.ac.fgMute),
                ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: stats.entries
                      .map((entry) => _StatChip(
                            label: entry.key,
                            value: '${entry.value}',
                          ))
                      .toList(),
                ),
                const SizedBox(height: 14),
                Text(
                  (detail['agent_data_notes'] as Map?)?['stored_agent_history_source']
                          as String? ??
                      '',
                  style: TextStyle(color: context.ac.fgDim, fontSize: 13, height: 1.5),
                ),
              ],
            ),
          ),
        ),
        if (media.isNotEmpty)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Photos', style: AymaFonts.serif(size: 22)),
                  const SizedBox(height: 12),
                  SizedBox(
                    height: 160,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: media.length,
                      separatorBuilder: (_, __) => const SizedBox(width: 12),
                      itemBuilder: (context, index) {
                        final item = media[index];
                        return SizedBox(
                          width: 140,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(14),
                                  child: Image.network(
                                    '${item['photo_url']}',
                                    width: 140,
                                    fit: BoxFit.cover,
                                    errorBuilder: (_, __, ___) => Container(
                                      color: context.ac.bgElev,
                                      alignment: Alignment.center,
                                      child: Icon(
                                        Icons.broken_image_outlined,
                                        color: context.ac.fgMute,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                (item['caption'] as String?)?.trim().isNotEmpty == true
                                    ? '${item['caption']}'
                                    : 'No caption',
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(color: context.ac.fgDim, fontSize: 12),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        _JsonSection(title: 'User row', data: user),
        _JsonSection(title: 'Skills', data: detail['skills']),
        _JsonSection(title: 'Questions', data: detail['questions']),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Agent memory audit', style: AymaFonts.serif(size: 22)),
                const SizedBox(height: 10),
                if (memories.isEmpty)
                  Text('No stored post-turn memories.', style: TextStyle(color: context.ac.fgDim))
                else
                  ...memories.take(30).map((memory) => Container(
                        width: double.infinity,
                        margin: const EdgeInsets.only(bottom: 12),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: context.ac.bgElev,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: context.ac.lineSoft),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${memory['created_at'] ?? ''} • ${memory['session_id'] ?? 'no-session'}',
                              style: AymaFonts.mono(size: 8, color: context.ac.fgMute),
                            ),
                            const SizedBox(height: 8),
                            SelectableText(
                              '${memory['text'] ?? ''}',
                              style: TextStyle(color: context.ac.fg, fontSize: 13, height: 1.45),
                            ),
                          ],
                        ),
                      )),
              ],
            ),
          ),
        ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Direct message threads', style: AymaFonts.serif(size: 22)),
                const SizedBox(height: 12),
                if (threads.isEmpty)
                  Text('No direct messages.', style: TextStyle(color: context.ac.fgDim))
                else
                  ...threads.map((thread) {
                    final messages =
                        ((thread['messages'] as List?) ?? const []).cast<Map<String, dynamic>>();
                    return ExpansionTile(
                      tilePadding: EdgeInsets.zero,
                      childrenPadding: const EdgeInsets.only(bottom: 12),
                      title: Text(
                        (thread['counterpart_display_name'] as String?)?.trim().isNotEmpty == true
                            ? '${thread['counterpart_display_name']}'
                            : '${thread['counterpart_user_id']}',
                      ),
                      subtitle: Text(
                        '${messages.length} messages',
                        style: TextStyle(color: context.ac.fgMute, fontSize: 12),
                      ),
                      children: messages.take(50).map((message) {
                        final outgoing = '${message['from_user_id']}' == '${user['id']}';
                        return Container(
                          width: double.infinity,
                          margin: const EdgeInsets.only(bottom: 8),
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: outgoing
                                ? context.ac.accent.withValues(alpha: 0.08)
                                : context.ac.bgElev,
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(color: context.ac.lineSoft),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '${message['created_at']} • ${outgoing ? 'sent' : 'received'}',
                                style: AymaFonts.mono(size: 8, color: context.ac.fgMute),
                              ),
                              const SizedBox(height: 6),
                              SelectableText('${message['text'] ?? ''}'),
                            ],
                          ),
                        );
                      }).toList(),
                    );
                  }),
              ],
            ),
          ),
        ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Matches and simulations', style: AymaFonts.serif(size: 22)),
                const SizedBox(height: 12),
                if (matches.isEmpty)
                  Text('No matches.', style: TextStyle(color: context.ac.fgDim))
                else
                  ...matches.map((match) => Container(
                        width: double.infinity,
                        margin: const EdgeInsets.only(bottom: 12),
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: context.ac.bgElev,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: context.ac.lineSoft),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${match['other_display_name'] ?? match['other_user_id']} • status ${match['status']} • score ${match['score']}',
                              style: TextStyle(color: context.ac.fg, fontSize: 14, fontWeight: FontWeight.w600),
                            ),
                            const SizedBox(height: 8),
                            if ((match['rationale'] as String?)?.isNotEmpty == true)
                              SelectableText('${match['rationale']}'),
                            if ((match['simulation'] as List?)?.isNotEmpty == true) ...[
                              const SizedBox(height: 10),
                              ...((match['simulation'] as List).cast<Map<String, dynamic>>()).map(
                                (line) => Padding(
                                  padding: const EdgeInsets.only(bottom: 6),
                                  child: SelectableText(
                                    '${line['turn_index']}. ${line['sender_uid']}: ${line['message_text']}',
                                    style: TextStyle(color: context.ac.fgDim, fontSize: 12, height: 1.4),
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      )),
              ],
            ),
          ),
        ),
        _JsonSection(title: 'Notifications', data: detail['notifications']),
        _JsonSection(title: 'All messages (flat)', data: detail['messages']),
      ],
    );
  }

  Widget _filterField(
    TextEditingController controller,
    String label, {
    double width = 160,
    bool number = false,
  }) {
    return SizedBox(
      width: width,
      child: TextField(
        controller: controller,
        keyboardType: number ? TextInputType.number : TextInputType.text,
        decoration: InputDecoration(labelText: label),
      ),
    );
  }

  Widget _triStateFilter({
    required String label,
    required bool? value,
    required ValueChanged<bool?> onChanged,
  }) {
    return SizedBox(
      width: 130,
      child: DropdownButtonFormField<bool?>(
        value: value,
        decoration: InputDecoration(labelText: label),
        items: const [
          DropdownMenuItem<bool?>(value: null, child: Text('Any')),
          DropdownMenuItem<bool?>(value: true, child: Text('Yes')),
          DropdownMenuItem<bool?>(value: false, child: Text('No')),
        ],
        onChanged: onChanged,
      ),
    );
  }

  int? _parseInt(String value) => int.tryParse(value.trim());

  String? _blankToNull(String value) {
    final text = value.trim();
    return text.isEmpty ? null : text;
  }
}

class _JsonSection extends StatelessWidget {
  const _JsonSection({
    required this.title,
    required this.data,
  });

  final String title;
  final Object? data;

  @override
  Widget build(BuildContext context) {
    final pretty = const JsonEncoder.withIndent('  ').convert(data);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: AymaFonts.serif(size: 22)),
            const SizedBox(height: 12),
            SelectableText(
              pretty,
              style: AymaFonts.mono(size: 9, color: context.ac.fgDim, letterSpacing: 0.05),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatChip extends StatelessWidget {
  const _StatChip({
    required this.label,
    required this.value,
  });

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: context.ac.bgElev,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: context.ac.lineSoft),
      ),
      child: Text(
        '$label: $value',
        style: AymaFonts.mono(size: 8, color: context.ac.fgDim),
      ),
    );
  }
}
