// Reusable public profile card: photos, bio, structured answers, and action buttons.
import 'package:flutter/material.dart';

import '../theme.dart';

class PublicProfileView extends StatefulWidget {
  const PublicProfileView({
    super.key,
    required this.photos,
    required this.name,
    required this.age,
    required this.gender,
    required this.location,
    required this.interestedIn,
    required this.bio,
    this.uploadingPhoto = false,
    this.onAddPhoto,
    this.onStartEdit,
    this.onToggleLocked,
    this.profilePublicLocked = false,
    this.showEditControls = false,
    this.onDeletePhoto,
    this.onReorderPhotos,
    this.extraPills = const <String>[],
    this.isOnline = true,
    this.bottom,
    this.pendingAiSuggestion,
    this.userHasEditedBio = false,
    this.profileData = const <String, dynamic>{},
    this.onBioSaved,
    this.onSuggestionAccepted,
    this.onSuggestionDeclined,
  });

  final List<String> photos;
  final String name;
  final int? age;
  final String gender;
  final String location;
  final String interestedIn;
  final String bio;
  final bool uploadingPhoto;
  final VoidCallback? onAddPhoto;
  final VoidCallback? onStartEdit;
  final VoidCallback? onToggleLocked;
  final bool profilePublicLocked;
  final bool showEditControls;
  final ValueChanged<String>? onDeletePhoto;
  final ValueChanged<List<String>>? onReorderPhotos;
  final List<String> extraPills;
  final bool isOnline;
  final Widget? bottom;
  final String? pendingAiSuggestion;
  final bool userHasEditedBio;
  final Map<String, dynamic> profileData;
  final Future<void> Function(String)? onBioSaved;
  final Future<void> Function(String)? onSuggestionAccepted;
  final VoidCallback? onSuggestionDeclined;

  @override
  State<PublicProfileView> createState() => _PublicProfileViewState();
}

class _PublicProfileViewState extends State<PublicProfileView> {
  int _page = 0;
  late final PageController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = PageController();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final photos = widget.photos;
    final hasPhotos = photos.isNotEmpty;
    return ListView(
      padding: const EdgeInsets.fromLTRB(0, 8, 0, 8),
      children: [
        Container(
          height: 520,
          decoration: BoxDecoration(
            color: const Color(0xFF14110F),
            borderRadius: BorderRadius.circular(0),
          ),
          clipBehavior: Clip.hardEdge,
          child: hasPhotos
              ? Stack(
                  children: [
                    PageView.builder(
                      controller: _ctrl,
                      itemCount: photos.length,
                      onPageChanged: (i) => setState(() => _page = i),
                      itemBuilder: (_, i) => Image.network(
                        photos[i],
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => Container(
                          color: AymaColors.bgCard,
                          child: const Center(
                            child: Icon(Icons.broken_image_outlined,
                                color: AymaColors.fgMute),
                          ),
                        ),
                      ),
                    ),
                    if (hasPhotos && widget.showEditControls)
                      Positioned(
                        right: 8,
                        top: 8,
                        child: InkWell(
                          onTap: () =>
                              widget.onDeletePhoto?.call(photos[_page]),
                          borderRadius: BorderRadius.circular(16),
                          child: Container(
                            padding: const EdgeInsets.all(6),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.55),
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(Icons.delete_outline_rounded,
                                size: 16, color: Colors.white),
                          ),
                        ),
                      ),
                    if (widget.showEditControls)
                      Positioned(
                        left: 10,
                        top: 10,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 6),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.35),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                                color: Colors.white.withValues(alpha: 0.18),
                                width: 0.5),
                          ),
                          child: Text(
                            'PREVIEW · WHAT OTHERS SEE',
                            style: AymaFonts.mono(size: 8, color: Colors.white),
                          ),
                        ),
                      ),
                    Positioned(
                      left: 14,
                      right: 14,
                      bottom: 18,
                      child: Container(
                        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(14),
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Colors.black.withValues(alpha: 0.05),
                              Colors.black.withValues(alpha: 0.58),
                            ],
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.baseline,
                              textBaseline: TextBaseline.alphabetic,
                              children: [
                                Flexible(
                                  child: Text(
                                    widget.name.isNotEmpty
                                        ? widget.name
                                        : 'Someone',
                                    style: AymaFonts.serif(
                                        size: 44, color: Colors.white),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                if (widget.age != null) ...[
                                  const SizedBox(width: 8),
                                  Text(
                                    '· ${widget.age}',
                                    style: const TextStyle(
                                      color: Colors.white70,
                                      fontSize: 22,
                                      fontWeight: FontWeight.w300,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                            const SizedBox(height: 6),
                            Row(
                              children: [
                                Container(
                                  width: 8,
                                  height: 8,
                                  decoration: BoxDecoration(
                                    color: widget.isOnline
                                        ? const Color(0xFF46D96A)
                                        : Colors.white38,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                                const SizedBox(width: 7),
                                Text(
                                  widget.isOnline ? 'Active now' : 'Offline',
                                  style: const TextStyle(
                                      color: Colors.white70, fontSize: 16),
                                ),
                                if (widget.location.isNotEmpty) ...[
                                  const SizedBox(width: 8),
                                  const Text('·',
                                      style: TextStyle(
                                          color: Colors.white54, fontSize: 16)),
                                  const SizedBox(width: 8),
                                  Flexible(
                                    child: Text(
                                      widget.location,
                                      style: const TextStyle(
                                          color: Colors.white70, fontSize: 16),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                )
              : Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.photo_outlined,
                          color: context.ac.fgMute, size: 28),
                      const SizedBox(height: 8),
                      Text('No photos yet',
                          style: AymaFonts.sans(
                              size: 13, color: context.ac.fgMute)),
                    ],
                  ),
                ),
        ),
        Container(
          margin: const EdgeInsets.fromLTRB(14, 10, 14, 0),
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.35),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
                color: Colors.white.withValues(alpha: 0.12), width: 0.5),
          ),
          child: SizedBox(
            height: 70,
            child: widget.showEditControls
                ? ReorderableListView.builder(
                    scrollDirection: Axis.horizontal,
                    buildDefaultDragHandles: false,
                    itemCount: photos.length + 1,
                    onReorder: (oldIndex, newIndex) {
                      if (oldIndex == photos.length ||
                          newIndex == photos.length) {
                        return;
                      }
                      final ordered = List<String>.from(photos);
                      setState(() {
                        if (newIndex > oldIndex) newIndex -= 1;
                        final moved = ordered.removeAt(oldIndex);
                        ordered.insert(newIndex, moved);
                      });
                      widget.onReorderPhotos?.call(ordered);
                    },
                    itemBuilder: (_, i) {
                      final isAddTile = i == photos.length;
                      if (isAddTile) {
                        return Container(
                          key: const ValueKey('add_tile'),
                          width: 66,
                          margin: const EdgeInsets.only(right: 8),
                          child: InkWell(
                            onTap: widget.uploadingPhoto
                                ? null
                                : widget.onAddPhoto,
                            borderRadius: BorderRadius.circular(12),
                            child: Container(
                              decoration: BoxDecoration(
                                color: context.ac.bgCard,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                    color: context.ac.lineSoft, width: 0.5),
                              ),
                              child: Center(
                                child: widget.uploadingPhoto
                                    ? SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          color: context.ac.accent,
                                        ),
                                      )
                                    : Icon(Icons.add_rounded,
                                        color: context.ac.fg, size: 20),
                              ),
                            ),
                          ),
                        );
                      }
                      final selected = _page == i;
                      return Container(
                        key: ValueKey('photo_${i}_${photos[i]}'),
                        width: 72,
                        margin: const EdgeInsets.only(right: 8),
                        child: ReorderableDragStartListener(
                          index: i,
                          child: _ThumbTile(
                            url: photos[i],
                            selected: selected,
                            main: i == 0,
                            onTap: () {
                              _ctrl.animateToPage(
                                i,
                                duration: const Duration(milliseconds: 180),
                                curve: Curves.easeOut,
                              );
                              setState(() => _page = i);
                            },
                          ),
                        ),
                      );
                    },
                  )
                : ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: photos.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 8),
                    itemBuilder: (_, i) {
                      final selected = _page == i;
                      return SizedBox(
                        width: 72,
                        child: _ThumbTile(
                          url: photos[i],
                          selected: selected,
                          main: i == 0,
                          onTap: () {
                            _ctrl.animateToPage(
                              i,
                              duration: const Duration(milliseconds: 180),
                              curve: Curves.easeOut,
                            );
                            setState(() => _page = i);
                          },
                        ),
                      );
                    },
                  ),
          ),
        ),
        const SizedBox(height: 0),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final tag
                in widget.extraPills.where((t) => t.trim().isNotEmpty))
              _Pill(text: tag),
            if (widget.location.isNotEmpty) _Pill(text: widget.location),
            if (widget.gender.isNotEmpty) _Pill(text: widget.gender),
            if (widget.interestedIn.isNotEmpty)
              _Pill(text: widget.interestedIn),
          ],
        ),
        const SizedBox(height: 14),
        if (widget.showEditControls)
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF1A110D),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                  color: AymaColors.accent.withValues(alpha: 0.2), width: 0.5),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 16,
                  height: 16,
                  margin: const EdgeInsets.only(top: 2),
                  decoration: const BoxDecoration(
                    color: AymaColors.accent,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'I wrote this from our conversations.',
                        style: AymaFonts.sans(size: 13, color: AymaColors.fg),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        "Tap anything to edit. I'll suggest tweaks after we talk again.",
                        style:
                            AymaFonts.sans(size: 12, color: AymaColors.fgMute),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                if (widget.onToggleLocked != null)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: const Color(0xFF231C17),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      widget.profilePublicLocked
                          ? 'Resume AI'
                          : 'Pause profile',
                      style: AymaFonts.sans(size: 11, color: AymaColors.fgDim),
                    ),
                  ),
              ],
            ),
          ),
        const SizedBox(height: 16),
        if (widget.bio.isNotEmpty)
          Container(
            padding: const EdgeInsets.only(left: 12),
            decoration: BoxDecoration(
              border: Border(
                left: BorderSide(
                    color: AymaColors.accent.withValues(alpha: 0.8), width: 2),
              ),
            ),
            child: Text(
              '"${_quoteFromBio(widget.bio)}"',
              style:
                  AymaFonts.serif(size: 36, color: AymaColors.fg, italic: true),
            ),
          ),
        _AboutYouSection(
          bio: widget.bio,
          profileData: widget.profileData,
          showEditControls: widget.showEditControls,
          pendingAiSuggestion: widget.pendingAiSuggestion,
          userHasEditedBio: widget.userHasEditedBio,
          onBioSaved: widget.onBioSaved,
          onSuggestionAccepted: widget.onSuggestionAccepted,
          onSuggestionDeclined: widget.onSuggestionDeclined,
        ),
        if (widget.bottom != null) ...[
          const SizedBox(height: 16),
          widget.bottom!,
        ],
      ],
    );
  }
}

String _quoteFromBio(String bio) {
  final text = bio.trim();
  if (text.isEmpty) return '';
  if (text.length <= 90) return text;
  return '${text.substring(0, 90).trimRight()}…';
}

class _Pill extends StatelessWidget {
  const _Pill({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF14110F),
        borderRadius: BorderRadius.circular(99),
        border: Border.all(color: const Color(0xFF2A221B), width: 0.5),
      ),
      child: Text(
        text,
        style: AymaFonts.sans(size: 12, color: AymaColors.fgDim),
      ),
    );
  }
}

class _ThumbTile extends StatelessWidget {
  const _ThumbTile({
    required this.url,
    required this.selected,
    required this.main,
    required this.onTap,
  });

  final String url;
  final bool selected;
  final bool main;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        clipBehavior: Clip.hardEdge,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? AymaColors.accent : AymaColors.lineSoft,
            width: selected ? 1.0 : 0.5,
          ),
        ),
        child: Stack(
          children: [
            Positioned.fill(
              child: Image.network(
                url,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => Container(
                  color: AymaColors.bgCard,
                  child: const Icon(Icons.broken_image_outlined,
                      color: AymaColors.fgMute, size: 16),
                ),
              ),
            ),
            if (main)
              Positioned(
                left: 4,
                top: 4,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                  decoration: BoxDecoration(
                    color: AymaColors.accent.withValues(alpha: 0.9),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(Icons.star_rounded,
                      size: 10, color: Colors.black),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ─── About You Section ────────────────────────────────────────────────────────

class _AboutYouSection extends StatefulWidget {
  const _AboutYouSection({
    required this.bio,
    required this.profileData,
    required this.showEditControls,
    this.pendingAiSuggestion,
    this.userHasEditedBio = false,
    this.onBioSaved,
    this.onSuggestionAccepted,
    this.onSuggestionDeclined,
  });

  final String bio;
  final Map<String, dynamic> profileData;
  final bool showEditControls;
  final String? pendingAiSuggestion;
  final bool userHasEditedBio;
  final Future<void> Function(String)? onBioSaved;
  final Future<void> Function(String)? onSuggestionAccepted;
  final VoidCallback? onSuggestionDeclined;

  @override
  State<_AboutYouSection> createState() => _AboutYouSectionState();
}

class _AboutYouSectionState extends State<_AboutYouSection> {
  bool _editing = false;
  bool _reviewingSuggestion = false;
  late TextEditingController _editCtrl;
  late TextEditingController _suggestionCtrl;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _editCtrl = TextEditingController(text: widget.bio);
    _suggestionCtrl =
        TextEditingController(text: widget.pendingAiSuggestion ?? '');
  }

  @override
  void didUpdateWidget(_AboutYouSection old) {
    super.didUpdateWidget(old);
    if (old.bio != widget.bio && !_editing) {
      _editCtrl.text = widget.bio;
    }
    if (old.pendingAiSuggestion != widget.pendingAiSuggestion) {
      _suggestionCtrl.text = widget.pendingAiSuggestion ?? '';
    }
  }

  @override
  void dispose() {
    _editCtrl.dispose();
    _suggestionCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    await widget.onBioSaved?.call(_editCtrl.text.trim());
    if (mounted) {
      setState(() {
        _editing = false;
        _saving = false;
      });
    }
  }

  Future<void> _acceptSuggestion() async {
    setState(() => _saving = true);
    await widget.onSuggestionAccepted?.call(_suggestionCtrl.text.trim());
    if (mounted) {
      setState(() {
        _reviewingSuggestion = false;
        _saving = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.profileData;

    final career = _str(p, ['job', 'occupation', 'career']);
    final company = _str(p, ['company', 'employer']);
    final height = _str(p, ['height_text', 'height']);
    final religion = _str(p, ['religion']);
    final relGoal = _str(p, ['relationship_goal']);
    final lifestyle = _str(p, ['lifestyle']);

    final hasPending = widget.pendingAiSuggestion?.isNotEmpty ?? false;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 18),

        // Section header
        Row(
          children: [
            Expanded(
              child: Text(
                'ABOUT YOU',
                style: TextStyle(
                  fontFamily: 'JetBrains Mono',
                  fontSize: 9,
                  letterSpacing: 1.8,
                  color: context.ac.fgMute,
                ),
              ),
            ),
            if (widget.showEditControls && !_editing && !_reviewingSuggestion)
              GestureDetector(
                onTap: () {
                  _editCtrl.text = widget.bio;
                  setState(() => _editing = true);
                },
                child: Text(
                  'Edit',
                  style: TextStyle(fontSize: 12, color: context.ac.accent),
                ),
              ),
          ],
        ),
        const SizedBox(height: 12),

        // Pending Ayma suggestion banner
        if (hasPending && widget.showEditControls && !_reviewingSuggestion)
          GestureDetector(
            onTap: () => setState(() => _reviewingSuggestion = true),
            child: Container(
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: context.ac.accentFaint,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: context.ac.accentSoft, width: 0.8),
              ),
              child: Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: context.ac.accent,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Ayma updated your bio — tap to review',
                      style: TextStyle(fontSize: 13, color: context.ac.fg),
                    ),
                  ),
                  Icon(Icons.chevron_right_rounded,
                      size: 16, color: context.ac.fgMute),
                ],
              ),
            ),
          ),

        // Suggestion review UI
        if (_reviewingSuggestion) ...[
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: context.ac.bgCard,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: context.ac.accentSoft, width: 0.8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  "AYMA'S SUGGESTION",
                  style: TextStyle(
                    fontFamily: 'JetBrains Mono',
                    fontSize: 9,
                    letterSpacing: 1.8,
                    color: context.ac.accent,
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _suggestionCtrl,
                  maxLines: null,
                  style: TextStyle(
                      fontSize: 14, color: context.ac.fg, height: 1.6),
                  decoration: InputDecoration(
                    border: InputBorder.none,
                    isDense: true,
                    hintText: 'Edit suggestion...',
                    hintStyle: TextStyle(color: context.ac.fgMute),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: GestureDetector(
                        onTap: () {
                          widget.onSuggestionDeclined?.call();
                          setState(() => _reviewingSuggestion = false);
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          decoration: BoxDecoration(
                            color: context.ac.bgElev,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                                color: context.ac.lineSoft, width: 0.5),
                          ),
                          child: Text(
                            'Decline',
                            textAlign: TextAlign.center,
                            style:
                                TextStyle(fontSize: 13, color: context.ac.fgDim),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: GestureDetector(
                        onTap: _saving ? null : _acceptSuggestion,
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          decoration: BoxDecoration(
                            color: context.ac.accent,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: _saving
                              ? const Center(
                                  child: SizedBox(
                                    width: 14,
                                    height: 14,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 1.5, color: Colors.black),
                                  ))
                              : const Text(
                                  'Use this',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                      fontSize: 13,
                                      color: Colors.black,
                                      fontWeight: FontWeight.w600),
                                ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
        ],

        // Inline edit mode
        if (_editing) ...[
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: context.ac.bgCard,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: context.ac.accent, width: 0.8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: _editCtrl,
                  maxLines: null,
                  autofocus: true,
                  style: TextStyle(
                      fontSize: 14, color: context.ac.fg, height: 1.6),
                  decoration: InputDecoration(
                    border: InputBorder.none,
                    isDense: true,
                    hintText: 'Write something about yourself...',
                    hintStyle: TextStyle(color: context.ac.fgMute),
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => setState(() => _editing = false),
                      child: Text('Cancel',
                          style: TextStyle(color: context.ac.fgMute)),
                    ),
                    const SizedBox(width: 8),
                    TextButton(
                      onPressed: _saving ? null : _save,
                      child: _saving
                          ? SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                  strokeWidth: 1.5, color: context.ac.accent))
                          : Text('Save',
                              style: TextStyle(
                                  color: context.ac.accent,
                                  fontWeight: FontWeight.w600)),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ] else ...[
          // Structured sections — only show if data exists
          if (career.isNotEmpty)
            _ProfileDetailRow(
                label: 'CAREER',
                value: company.isNotEmpty ? '$career · $company' : career),
          if (relGoal.isNotEmpty)
            _ProfileDetailRow(label: 'LOOKING FOR', value: relGoal),
          if (height.isNotEmpty)
            _ProfileDetailRow(label: 'HEIGHT', value: height),
          if (religion.isNotEmpty)
            _ProfileDetailRow(label: 'RELIGION', value: religion),
          if (lifestyle.isNotEmpty)
            _ProfileDetailRow(label: 'LIFESTYLE', value: lifestyle),

        ],
      ],
    );
  }

  String _str(Map<String, dynamic> p, List<String> keys) {
    for (final k in keys) {
      final v = (p[k] as String?)?.trim();
      if (v != null && v.isNotEmpty) return v;
    }
    return '';
  }
}

class _ProfileDetailRow extends StatelessWidget {
  const _ProfileDetailRow({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontFamily: 'JetBrains Mono',
              fontSize: 9,
              letterSpacing: 1.8,
              color: context.ac.fgMute,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: TextStyle(fontSize: 15, color: context.ac.fg, height: 1.5),
          ),
        ],
      ),
    );
  }
}
