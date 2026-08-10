// Profile editor: public/private wiki sections and completeness.
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../models/profile.dart';
import '../../providers/providers.dart';
import '../../services/api_service.dart';
import '../../theme.dart';
import '../../widgets/ayma_button.dart';
import '../../widgets/ayma_text_field.dart';

// ─── ProfileScreen ────────────────────────────────────────────────────────────

class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key});

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  bool _editingBasic = false;
  bool _saving = false;

  final _bioCtrl = TextEditingController();
  final _notesCtrl = TextEditingController();
  final _agentNameCtrl = TextEditingController();
  final _nameCtrl = TextEditingController();
  final _ageCtrl = TextEditingController();
  final _locationCtrl = TextEditingController();

  String? _voicePref;
  bool? _matchingPaused;
  String? _genderVal;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    _bioCtrl.dispose();
    _notesCtrl.dispose();
    _agentNameCtrl.dispose();
    _nameCtrl.dispose();
    _ageCtrl.dispose();
    _locationCtrl.dispose();
    super.dispose();
  }

  Future<void> _save(UserProfile profile) async {
    setState(() => _saving = true);
    try {
      final ageInt = int.tryParse(_ageCtrl.text.trim());
      await ApiService.updateProfile({
        if (_nameCtrl.text.trim().isNotEmpty)
          'display_name': _nameCtrl.text.trim(),
        'profile_public': _bioCtrl.text.trim(),
        'profile_private': _notesCtrl.text.trim(),
        'agent_name': _agentNameCtrl.text.trim(),
        if (ageInt != null) 'age': ageInt,
        if (_locationCtrl.text.trim().isNotEmpty)
          'location_region': _locationCtrl.text.trim(),
        if (_genderVal != null) 'gender': _genderVal,
        if (_voicePref != null) 'voice_preference': _voicePref,
        if (_matchingPaused != null) 'matching_paused': _matchingPaused,
      });
      ref.invalidate(profileProvider);
      ref.invalidate(publicProfileProvider(profile.id));
      ref.invalidate(insightsProvider);
      if (mounted) setState(() => _editingBasic = false);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Save failed: $e')));
      }
    }
    if (mounted) setState(() => _saving = false);
  }

  @override
  Widget build(BuildContext context) {
    final profileAsync = ref.watch(profileProvider);

    return Scaffold(
      backgroundColor: context.ac.bg,
      body: profileAsync.when(
        loading: () => Center(
          child: CircularProgressIndicator(
              strokeWidth: 1.5, color: context.ac.accent),
        ),
        error: (e, _) => Center(
          child: Text('Error: $e',
              style: TextStyle(color: context.ac.fgDim)),
        ),
        data: (profile) {
          if (profile == null) {
            return Center(
              child: Text('No profile found.',
                  style: TextStyle(color: context.ac.fgMute)),
            );
          }

          if (_editingBasic) {
            return _EditFormView(
              profile: profile,
              bioCtrl: _bioCtrl,
              notesCtrl: _notesCtrl,
              agentNameCtrl: _agentNameCtrl,
              nameCtrl: _nameCtrl,
              ageCtrl: _ageCtrl,
              locationCtrl: _locationCtrl,
              voicePref: _voicePref,
              matchingPaused: _matchingPaused,
              genderVal: _genderVal,
              saving: _saving,
              onSave: () => _save(profile),
              onBack: () => setState(() => _editingBasic = false),
              onVoiceChanged: (v) => setState(() => _voicePref = v),
              onMatchingPausedChanged: (v) =>
                  setState(() => _matchingPaused = v),
              onGenderChanged: (v) => setState(() => _genderVal = v),
            );
          }

          return SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  child: Row(
                    children: [
                      Expanded(child: _TopTabs(controller: _tabController)),
                      const SizedBox(width: 8),
                      InkWell(
                        onTap: () => context.push('/settings'),
                        borderRadius: BorderRadius.circular(18),
                        child: Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            color: context.ac.bgElev,
                            borderRadius: BorderRadius.circular(18),
                            border: Border.all(
                                color: context.ac.lineSoft, width: 0.5),
                          ),
                          child: Icon(Icons.settings_outlined,
                              size: 17, color: context.ac.fgDim),
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: TabBarView(
                    controller: _tabController,
                    children: [
                      _PublicTabWithCompleteness(profile: profile),
                      _YourStoryPane(profile: profile),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

// ─── Pill Tab Bar ─────────────────────────────────────────────────────────────

class _TopTabs extends StatelessWidget {
  const _TopTabs({required this.controller});
  final TabController controller;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 44,
      decoration: BoxDecoration(
        color: const Color(0xFF14110F),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF282118), width: 0.5),
      ),
      child: TabBar(
        controller: controller,
        indicator: BoxDecoration(
          color: context.ac.fg,
          borderRadius: BorderRadius.circular(10),
        ),
        indicatorSize: TabBarIndicatorSize.tab,
        indicatorPadding: const EdgeInsets.all(4),
        dividerColor: Colors.transparent,
        labelColor: context.ac.bg,
        unselectedLabelColor: context.ac.fgMute,
        labelStyle: AymaFonts.sans(size: 13, weight: FontWeight.w600),
        unselectedLabelStyle: AymaFonts.sans(size: 13),
        tabs: const [
          Tab(text: 'Public'),
          Tab(text: 'Private'),
        ],
      ),
    );
  }
}

// ─── Shared story sections (Public + Private tabs) ───────────────────────────

class _StorySectionsHeader extends StatelessWidget {
  const _StorySectionsHeader({
    required this.profile,
    required this.title,
    required this.badge,
    required this.introLead,
    required this.introEmphasis,
  });

  final UserProfile profile;
  final String title;
  final String badge;
  final String introLead;
  final String introEmphasis;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${profile.displayName.isEmpty ? 'SHS' : profile.displayName.toUpperCase()} · SINCE APRIL 2026',
          style: AymaFonts.mono(size: 9, color: context.ac.fgMute),
        ).animate().fadeIn(duration: 250.ms),
        const SizedBox(height: 8),
        Text(
          title,
          style: AymaFonts.serif(size: 72, color: context.ac.fg),
        ).animate().fadeIn(duration: 320.ms),
        const SizedBox(height: 16),
        Row(
          children: [
            Text(
              '⬡ $badge',
              style: AymaFonts.mono(
                size: 10,
                color: context.ac.accent,
              ).copyWith(letterSpacing: 2.5),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Divider(
                color: context.ac.lineSoft,
                thickness: 0.5,
                height: 1,
              ),
            ),
            const SizedBox(width: 10),
            Text(
              'UPDATED AS WE TALK',
              style: AymaFonts.mono(
                size: 10,
                color: context.ac.fgMute,
              ).copyWith(letterSpacing: 2.0),
            ),
          ],
        ),
        const SizedBox(height: 16),
        RichText(
          text: TextSpan(
            children: [
              TextSpan(
                text: introLead,
                style: AymaFonts.serif(
                  size: 21,
                  color: context.ac.fgDim,
                  italic: true,
                ),
              ),
              TextSpan(
                text: introEmphasis,
                style: AymaFonts.serif(size: 21, color: context.ac.fg),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _WikiSectionRows extends StatelessWidget {
  const _WikiSectionRows({
    required this.insights,
    required this.scopeLabel,
  });

  final Map<String, dynamic> insights;
  final String scopeLabel;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _PrivateSectionRow(
          label: 'WHO YOU ARE',
          content: insights['about_me']?.toString() ?? '',
          sectionKey: 'about_me',
          title: 'Who you are',
          scopeLabel: scopeLabel,
        ),
        _PrivateSectionRow(
          label: "WHAT YOU'RE LOOKING FOR",
          content: insights['preferences']?.toString() ?? '',
          sectionKey: 'preferences',
          title: "What you're looking for",
          scopeLabel: scopeLabel,
        ),
        _PrivateSectionRow(
          label: 'YOUR LIFE RIGHT NOW',
          content: insights['context']?.toString() ?? '',
          sectionKey: 'context',
          title: 'Your life right now',
          scopeLabel: scopeLabel,
        ),
        _PrivateSectionRow(
          label: 'FOR MATCHING',
          content: insights['matching']?.toString() ?? '',
          sectionKey: 'matching',
          title: 'For matching',
          scopeLabel: scopeLabel,
        ),
      ],
    );
  }
}

// ─── Tab 1: Private Profile (wiki) ───────────────────────────────────────────

class _YourStoryPane extends ConsumerWidget {
  const _YourStoryPane({required this.profile});

  final UserProfile profile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final insightsAsync = ref.watch(insightsProvider);
    return insightsAsync.when(
      loading: () => Center(
        child: CircularProgressIndicator(
          strokeWidth: 1.5,
          color: context.ac.accent,
        ),
      ),
      error: (e, _) => Center(
        child: Text(
          'Error: $e',
          style: TextStyle(color: context.ac.fgMute),
        ),
      ),
      data: (insights) {
        final i = insights as Map<String, dynamic>? ?? const <String, dynamic>{};
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
          children: [
            _StorySectionsHeader(
              profile: profile,
              title: 'Just between us.',
              badge: 'PRIVATE',
              introLead: "What I've come to know about you — ",
              introEmphasis: 'only you can see this.',
            ),
            const SizedBox(height: 20),
            _WikiSectionRows(insights: i, scopeLabel: 'PRIVATE'),
          ],
        );
      },
    );
  }
}

// ─── Chat message data class ──────────────────────────────────────────────────

class _ChatMsg {
  _ChatMsg({required this.text, required this.isUser, this.applyText});

  final String text;
  final bool isUser;
  final String? applyText;
}

// ─── Private section row ──────────────────────────────────────────────────────

class _PrivateSectionRow extends StatelessWidget {
  const _PrivateSectionRow({
    required this.label,
    required this.content,
    required this.sectionKey,
    required this.title,
    this.scopeLabel = 'PRIVATE',
  });

  final String label;
  final String content;
  final String sectionKey;
  final String title;
  final String scopeLabel;

  @override
  Widget build(BuildContext context) {
    final hasContent = content.trim().isNotEmpty;
    return GestureDetector(
      onTap: () => Navigator.of(context).push(
        PageRouteBuilder(
          transitionDuration: const Duration(milliseconds: 260),
          pageBuilder: (_, __, ___) => _SectionDetailPage(
            label: label,
            content: content,
            sectionKey: sectionKey,
            title: title,
            scopeLabel: scopeLabel,
          ),
          transitionsBuilder: (_, animation, __, child) {
            final tween = Tween<Offset>(
              begin: const Offset(1, 0),
              end: Offset.zero,
            ).animate(
              CurvedAnimation(
                parent: animation,
                curve: Curves.easeOutCubic,
              ),
            );
            return SlideTransition(position: tween, child: child);
          },
        ),
      ),
      child: Container(
        decoration: const BoxDecoration(
          border: Border(
            top: BorderSide(color: Color(0xFF2A261F), width: 0.5),
          ),
        ),
        padding: const EdgeInsets.symmetric(vertical: 22, horizontal: 2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  label,
                  style: AymaFonts.mono(
                    size: 11,
                    color: context.ac.fgMute,
                  ).copyWith(letterSpacing: 3.0),
                ),
                const Spacer(),
                Text(
                  '→',
                  style: AymaFonts.mono(size: 14, color: context.ac.accent),
                ),
              ],
            ),
            const SizedBox(height: 12),
            hasContent
                ? Text(
                    content,
                    style: AymaFonts.serif(size: 17, color: context.ac.fgDim),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  )
                : Text(
                    'Nothing here yet — keep chatting with Ayma!',
                    style: AymaFonts.serif(
                      size: 17,
                      color: context.ac.fgMute,
                      italic: true,
                    ),
                  ),
            const SizedBox(height: 10),
            Text(
              'TAP TO OPEN & EDIT',
              style: AymaFonts.mono(size: 10, color: context.ac.fgMute),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Section detail page ──────────────────────────────────────────────────────

class _SectionDetailPage extends StatefulWidget {
  const _SectionDetailPage({
    required this.label,
    required this.content,
    required this.sectionKey,
    required this.title,
    this.scopeLabel = 'PRIVATE',
  });

  final String label;
  final String content;
  final String sectionKey;
  final String title;
  final String scopeLabel;

  @override
  State<_SectionDetailPage> createState() => _SectionDetailPageState();
}

class _SectionDetailPageState extends State<_SectionDetailPage> {
  late TextEditingController _contentCtrl;
  final ScrollController _chatScrollCtrl = ScrollController();
  final TextEditingController _composeCtrl = TextEditingController();
  bool _chatOpen = false;
  bool _typing = false;
  final List<_ChatMsg> _messages = [];

  @override
  void initState() {
    super.initState();
    _contentCtrl = TextEditingController(text: widget.content);
    _messages.add(
      _ChatMsg(
        text: 'This is your "${widget.title}" page. Highlight any line to tweak it, or tell me what to change.',
        isUser: false,
      ),
    );
  }

  @override
  void dispose() {
    _contentCtrl.dispose();
    _composeCtrl.dispose();
    _chatScrollCtrl.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_chatScrollCtrl.hasClients) {
        _chatScrollCtrl.animateTo(
          _chatScrollCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _send(String draft) async {
    setState(() {
      _composeCtrl.clear();
      _messages.add(_ChatMsg(text: draft, isUser: true));
      _typing = true;
    });
    _scrollToBottom();
    try {
      final result = await ApiService.correctWikiSection(
        section: widget.sectionKey,
        feedback: draft,
      );
      final corrected = result['content']?.toString() ?? '';
      setState(() {
        _typing = false;
        _messages.add(
          _ChatMsg(
            text: "Updated. Here's the revision:",
            isUser: false,
            applyText: corrected,
          ),
        );
      });
      _scrollToBottom();
    } catch (e) {
      setState(() {
        _typing = false;
        _messages.add(
          _ChatMsg(
            text: 'Sorry, something went wrong: $e',
            isUser: false,
          ),
        );
      });
      _scrollToBottom();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.ac.bg,
      body: Stack(
        children: [
          Positioned.fill(
            child: Column(
              children: [
                Container(
                  decoration: BoxDecoration(
                    border: Border(
                      bottom: BorderSide(
                        color: context.ac.lineSoft,
                        width: 0.5,
                      ),
                    ),
                  ),
                  padding: const EdgeInsets.fromLTRB(22, 54, 22, 14),
                  child: Row(
                    children: [
                      GestureDetector(
                        onTap: () => Navigator.pop(context),
                        child: Container(
                          width: 42,
                          height: 42,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: context.ac.lineSoft.withValues(alpha: 0.12),
                              width: 1,
                            ),
                            color: context.ac.fg.withValues(alpha: 0.04),
                          ),
                          child: Center(
                            child: Text(
                              '←',
                              style: TextStyle(
                                color: context.ac.fg,
                                fontSize: 18,
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '⬡ ${widget.scopeLabel}',
                              style: AymaFonts.mono(
                                size: 10,
                                color: context.ac.accent,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              widget.label,
                              style: AymaFonts.mono(
                                size: 11,
                                color: context.ac.fgMute,
                              ).copyWith(letterSpacing: 3.0),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(24, 24, 24, 220),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.title,
                          style: AymaFonts.serif(size: 42, color: context.ac.fg),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Container(
                              width: 6,
                              height: 6,
                              decoration: BoxDecoration(
                                color: context.ac.accent,
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'HIGHLIGHT ANY LINE TO CHANGE IT — OR JUST ASK BELOW',
                                style: AymaFonts.mono(
                                  size: 10,
                                  color: context.ac.fgMute,
                                ).copyWith(letterSpacing: 1.5),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 24),
                        TextField(
                          controller: _contentCtrl,
                          maxLines: null,
                          style: AymaFonts.serif(
                            size: 19,
                            color: context.ac.fgDim,
                          ).copyWith(height: 1.68, letterSpacing: 0.1),
                          decoration: InputDecoration(
                            hintText: 'Nothing here yet — keep chatting with Ayma!',
                            hintStyle: AymaFonts.serif(
                              size: 19,
                              color: context.ac.fgMute,
                            ),
                            border: InputBorder.none,
                            isDense: true,
                            contentPadding: EdgeInsets.zero,
                            filled: false,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_chatOpen)
                  ClipRRect(
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(22),
                    ),
                    child: BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                      child: Container(
                        color: const Color(0xEB14100C),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Padding(
                              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                              child: Column(
                                children: [
                                  Row(
                                    children: [
                                      Text(
                                        'AYMA · ${widget.label}',
                                        style: AymaFonts.mono(
                                          size: 10,
                                          color: context.ac.fgMute,
                                        ),
                                      ),
                                      const Spacer(),
                                      GestureDetector(
                                        onTap: () => setState(() => _chatOpen = false),
                                        child: Icon(
                                          Icons.close,
                                          size: 16,
                                          color: context.ac.fgMute,
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 8),
                                ],
                              ),
                            ),
                            ConstrainedBox(
                              constraints: const BoxConstraints(maxHeight: 200),
                              child: ListView.builder(
                                controller: _chatScrollCtrl,
                                shrinkWrap: true,
                                itemCount: _messages.length + (_typing ? 1 : 0),
                                itemBuilder: (ctx, idx) {
                                  if (_typing && idx == _messages.length) {
                                    return Padding(
                                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                                      child: Row(
                                        children: [
                                          const SizedBox(width: 16),
                                          Text(
                                            '•••',
                                            style: AymaFonts.mono(
                                              size: 12,
                                              color: context.ac.fgMute,
                                            ),
                                          ),
                                        ],
                                      ),
                                    );
                                  }
                                  final msg = _messages[idx];
                                  return Padding(
                                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                                    child: Align(
                                      alignment: msg.isUser
                                          ? Alignment.centerRight
                                          : Alignment.centerLeft,
                                      child: Column(
                                        crossAxisAlignment: msg.isUser
                                            ? CrossAxisAlignment.end
                                            : CrossAxisAlignment.start,
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 12,
                                              vertical: 8,
                                            ),
                                            decoration: BoxDecoration(
                                              color: msg.isUser
                                                  ? context.ac.fg
                                                  : context.ac.lineSoft,
                                              borderRadius: BorderRadius.circular(14),
                                            ),
                                            child: Text(
                                              msg.text,
                                              style: AymaFonts.serif(
                                                size: 14.5,
                                                color: msg.isUser
                                                    ? context.ac.bg
                                                    : context.ac.fg,
                                              ),
                                            ),
                                          ),
                                          if (msg.applyText != null) ...[
                                            const SizedBox(height: 4),
                                            GestureDetector(
                                              onTap: () => setState(
                                                () => _contentCtrl.text = msg.applyText!,
                                              ),
                                              child: Container(
                                                padding: const EdgeInsets.symmetric(
                                                  horizontal: 10,
                                                  vertical: 5,
                                                ),
                                                decoration: BoxDecoration(
                                                  color: context.ac.accent.withValues(
                                                    alpha: 0.15,
                                                  ),
                                                  borderRadius: BorderRadius.circular(8),
                                                  border: Border.all(
                                                    color: context.ac.accent.withValues(
                                                      alpha: 0.3,
                                                    ),
                                                    width: 0.5,
                                                  ),
                                                ),
                                                child: Text(
                                                  'Apply',
                                                  style: AymaFonts.mono(
                                                    size: 10,
                                                    color: context.ac.accent,
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ],
                                        ],
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ),
                            const SizedBox(height: 8),
                          ],
                        ),
                      ),
                    ),
                  ),
                ClipRect(
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                    child: Container(
                      decoration: BoxDecoration(
                        color: const Color(0xF014100C),
                        border: Border(
                          top: BorderSide(
                            color: context.ac.lineSoft.withValues(alpha: 0.08),
                            width: 0.5,
                          ),
                        ),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(12, 10, 12, 28),
                        child: Row(
                          children: [
                            Expanded(
                              child: Container(
                                decoration: BoxDecoration(
                                  color: context.ac.lineSoft.withValues(alpha: 0.06),
                                  borderRadius: BorderRadius.circular(999),
                                  border: Border.all(
                                    color: context.ac.lineSoft.withValues(alpha: 0.10),
                                    width: 0.5,
                                  ),
                                ),
                                padding: const EdgeInsets.fromLTRB(16, 6, 6, 6),
                                child: TextField(
                                  controller: _composeCtrl,
                                  style: AymaFonts.sans(
                                    size: 14,
                                    color: context.ac.fg,
                                  ),
                                  decoration: InputDecoration(
                                    hintText: 'Tell Ayma what to change...',
                                    hintStyle: AymaFonts.sans(
                                      size: 14,
                                      color: context.ac.fgMute,
                                    ),
                                    border: InputBorder.none,
                                    isDense: true,
                                    contentPadding: EdgeInsets.zero,
                                    filled: false,
                                  ),
                                  maxLines: null,
                                  onTap: () => setState(() => _chatOpen = true),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            GestureDetector(
                              onTap: () {
                                final t = _composeCtrl.text.trim();
                                if (t.isEmpty) {
                                  return;
                                }
                                setState(() => _chatOpen = true);
                                _send(t);
                              },
                              child: Container(
                                width: 38,
                                height: 38,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: context.ac.accent,
                                ),
                                child: const Center(
                                  child: Text(
                                    '↑',
                                    style: TextStyle(
                                      color: Colors.black,
                                      fontSize: 18,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Tab 0: Public profile (same sections as Private) ─────────────────────────

class _PublicTabWithCompleteness extends ConsumerWidget {
  const _PublicTabWithCompleteness({required this.profile});

  final UserProfile profile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final completenessAsync = ref.watch(profileCompletenessProvider);
    final insightsAsync = ref.watch(insightsProvider);
    final pct = (completenessAsync.valueOrNull ?? 0.0).round();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Profile $pct% complete',
                style: AymaFonts.mono(size: 9, color: context.ac.fgMute),
              ),
              const SizedBox(height: 4),
              ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  value: pct / 100.0,
                  minHeight: 3,
                  backgroundColor: context.ac.lineSoft,
                  valueColor: AlwaysStoppedAnimation<Color>(context.ac.accent),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: insightsAsync.when(
            loading: () => Center(
              child: CircularProgressIndicator(
                strokeWidth: 1.5,
                color: context.ac.accent,
              ),
            ),
            error: (e, _) => Center(
              child: Text(
                'Error: $e',
                style: TextStyle(color: context.ac.fgMute),
              ),
            ),
            data: (insights) {
              final i =
                  insights as Map<String, dynamic>? ?? const <String, dynamic>{};
              return ListView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
                children: [
                  _StorySectionsHeader(
                    profile: profile,
                    title: 'What they see.',
                    badge: 'PUBLIC',
                    introLead: 'This is how you appear to others — ',
                    introEmphasis: 'tap any section to edit.',
                  ),
                  const SizedBox(height: 20),
                  _WikiSectionRows(insights: i, scopeLabel: 'PUBLIC'),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

// ─── Edit Form View ───────────────────────────────────────────────────────────

class _EditFormView extends StatelessWidget {
  const _EditFormView({
    required this.profile,
    required this.bioCtrl,
    required this.notesCtrl,
    required this.agentNameCtrl,
    required this.nameCtrl,
    required this.ageCtrl,
    required this.locationCtrl,
    required this.voicePref,
    required this.matchingPaused,
    required this.genderVal,
    required this.saving,
    required this.onSave,
    required this.onBack,
    required this.onVoiceChanged,
    required this.onMatchingPausedChanged,
    required this.onGenderChanged,
  });

  final UserProfile profile;
  final TextEditingController bioCtrl;
  final TextEditingController notesCtrl;
  final TextEditingController agentNameCtrl;
  final TextEditingController nameCtrl;
  final TextEditingController ageCtrl;
  final TextEditingController locationCtrl;
  final String? voicePref;
  final bool? matchingPaused;
  final String? genderVal;
  final bool saving;
  final VoidCallback onSave;
  final VoidCallback onBack;
  final ValueChanged<String> onVoiceChanged;
  final ValueChanged<bool> onMatchingPausedChanged;
  final ValueChanged<String?> onGenderChanged;

  static const _voiceOptions = ['Charon', 'Linden', 'March', 'Harbor', 'Ash'];
  static const _genderOptions = ['Man', 'Woman', 'Non-binary', 'Other'];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.ac.bg,
      appBar: AppBar(
        backgroundColor: context.ac.bg,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back_rounded, color: context.ac.fgDim),
          onPressed: onBack,
        ),
        title: Text('Edit profile',
            style: AymaFonts.serif(size: 20, color: context.ac.fg)),
        actions: [
          if (saving)
            Padding(
              padding: const EdgeInsets.all(14),
              child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: context.ac.accent)),
            )
          else
            TextButton(
              onPressed: onSave,
              child: Text('Save',
                  style: AymaFonts.sans(
                      size: 15,
                      color: context.ac.accent,
                      weight: FontWeight.w600)),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 48),
        children: [
          _FieldLabel('Name'),
          AymaTextField(
              controller: nameCtrl, label: 'Display name', maxLines: 1),
          const SizedBox(height: 16),
          _FieldLabel('Age'),
          AymaTextField(
              controller: ageCtrl,
              label: 'Age',
              maxLines: 1,
              keyboardType: TextInputType.number),
          const SizedBox(height: 16),
          _FieldLabel('Gender'),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _genderOptions.map((g) {
              final sel = genderVal == g;
              return _SelectChip(
                label: g,
                selected: sel,
                onTap: () => onGenderChanged(sel ? null : g),
              );
            }).toList(),
          ),
          const SizedBox(height: 16),
          _FieldLabel('Location'),
          AymaTextField(
              controller: locationCtrl, label: 'City or region', maxLines: 1),
          const SizedBox(height: 16),
          _FieldLabel('Agent name'),
          AymaTextField(
              controller: agentNameCtrl,
              label: "Your AI agent's name",
              maxLines: 1),
          const SizedBox(height: 16),
          _FieldLabel('Voice'),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _voiceOptions.map((v) {
              final sel = voicePref == v;
              return _SelectChip(
                label: v,
                selected: sel,
                onTap: () => onVoiceChanged(v),
              );
            }).toList(),
          ),
          const SizedBox(height: 16),
          _FieldLabel('Public bio'),
          AymaTextField(
              controller: bioCtrl,
              label: 'Visible to potential matches',
              maxLines: 5),
          const SizedBox(height: 16),
          _FieldLabel('Private notes'),
          const SizedBox(height: 4),
          Text(
            'Only visible to you — Ayma uses this to understand you better.',
            style: TextStyle(color: context.ac.fgMute, fontSize: 11),
          ),
          const SizedBox(height: 6),
          AymaTextField(
              controller: notesCtrl,
              label: 'Notes (only you see this)',
              maxLines: 5),
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              color: context.ac.bgElev,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: context.ac.lineSoft, width: 0.5),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Pause matching',
                          style:
                              AymaFonts.sans(size: 14, color: context.ac.fg)),
                      const SizedBox(height: 2),
                      Text('Hide your profile from new matches',
                          style: AymaFonts.sans(
                              size: 12, color: context.ac.fgMute)),
                    ],
                  ),
                ),
                Switch(
                  value: matchingPaused ?? false,
                  onChanged: onMatchingPausedChanged,
                  activeColor: context.ac.accent,
                  inactiveThumbColor: context.ac.fgMute,
                  inactiveTrackColor: context.ac.lineSoft,
                ),
              ],
            ),
          ),
          const SizedBox(height: 28),
          AymaButton(label: 'Save changes', loading: saving, onPressed: onSave),
          const SizedBox(height: 12),
          AymaButton(label: 'Cancel', outlined: true, onPressed: onBack),
        ],
      ),
    );
  }
}

// ─── Helper widgets ───────────────────────────────────────────────────────────

// ─── Wiki Correct Dialog ──────────────────────────────────────────────────────

class _WikiCorrectSheet extends StatefulWidget {
  const _WikiCorrectSheet({
    required this.label,
    required this.content,
    required this.sectionKey,
    required this.onCorrected,
  });
  final String label;
  final String content;
  final String sectionKey;
  final Future<void> Function(String correctedContent) onCorrected;

  @override
  State<_WikiCorrectSheet> createState() => _WikiCorrectSheetState();
}

class _WikiCorrectSheetState extends State<_WikiCorrectSheet> {
  late final TextEditingController _feedbackCtrl;
  bool _loading = false;
  String? _correctedContent;
  String? _error;

  @override
  void initState() {
    super.initState();
    _feedbackCtrl = TextEditingController();
  }

  @override
  void dispose() {
    _feedbackCtrl.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final fb = _feedbackCtrl.text.trim();
    if (fb.isEmpty) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await ApiService.correctWikiSection(
        section: widget.sectionKey,
        feedback: fb,
      );
      final corrected = result['content']?.toString() ?? '';
      setState(() {
        _correctedContent = corrected;
        _loading = false;
      });
      await widget.onCorrected(corrected);
      await Future.delayed(const Duration(milliseconds: 800));
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final displayContent = _correctedContent ?? widget.content;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: context.ac.lineSoft,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Row(
              children: [
                Expanded(
                  child: Text(
                    widget.label,
                    style: AymaFonts.mono(size: 9, color: context.ac.fgMute),
                  ),
                ),
                IconButton(
                  icon: Icon(Icons.close, size: 18, color: context.ac.fgMute),
                  onPressed: () => Navigator.of(context).pop(),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (_correctedContent != null)
              Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.green.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  'Corrected ✓',
                  style: AymaFonts.mono(size: 9, color: Colors.green),
                ),
              ),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 160),
              child: SingleChildScrollView(
                child: Text(
                  displayContent.isEmpty ? 'Nothing here yet.' : displayContent,
                  style: AymaFonts.serif(size: 15, color: context.ac.fg),
                ),
              ),
            ),
            const SizedBox(height: 14),
            Divider(
              color: context.ac.lineSoft.withValues(alpha: 0.6),
              thickness: 0.5,
              height: 1,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _feedbackCtrl,
              enabled: !_loading && _correctedContent == null,
              autofocus: true,
              style: AymaFonts.sans(size: 14, color: context.ac.fg),
              decoration: InputDecoration(
                hintText: 'What needs to change?',
                hintStyle: AymaFonts.sans(size: 14, color: context.ac.fgMute),
                border: InputBorder.none,
                isDense: true,
                contentPadding: EdgeInsets.zero,
              ),
              maxLines: null,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => _send(),
            ),
            const SizedBox(height: 14),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  _error!,
                  style: AymaFonts.mono(size: 9, color: Colors.red),
                ),
              ),
            Align(
              alignment: Alignment.centerRight,
              child: _loading
                  ? SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: context.ac.accent,
                      ),
                    )
                  : GestureDetector(
                      onTap: _correctedContent == null ? _send : null,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: context.ac.accent.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          'Send',
                          style: AymaFonts.sans(
                            size: 13,
                            color: context.ac.accent,
                            weight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FieldLabel extends StatelessWidget {
  const _FieldLabel(this.label);
  final String label;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(label.toUpperCase(),
            style: AymaFonts.mono(size: 9, color: context.ac.fgMute)),
      );
}

class _SelectChip extends StatelessWidget {
  const _SelectChip(
      {required this.label, required this.selected, required this.onTap});
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: selected
              ? context.ac.accent.withValues(alpha: 0.15)
              : context.ac.bgElev,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected
                ? context.ac.accent.withValues(alpha: 0.5)
                : context.ac.lineSoft,
            width: selected ? 1 : 0.5,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? context.ac.accent : context.ac.fgDim,
            fontSize: 13,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      ),
    );
  }
}
