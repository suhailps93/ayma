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
    this.bottom,
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
  final Widget? bottom;

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
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 120),
      children: [
        Container(
          height: 250,
          decoration: BoxDecoration(
            color: AymaColors.bgElev,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: AymaColors.lineSoft, width: 0.5),
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
                    if (photos.length > 1)
                      Positioned(
                        left: 12,
                        right: 12,
                        bottom: 10,
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: List.generate(photos.length, (i) {
                            return AnimatedContainer(
                              duration: const Duration(milliseconds: 180),
                              margin: const EdgeInsets.symmetric(horizontal: 3),
                              width: _page == i ? 18 : 5,
                              height: 5,
                              decoration: BoxDecoration(
                                color: _page == i
                                    ? AymaColors.fg
                                    : AymaColors.fg.withValues(alpha: 0.35),
                                borderRadius: BorderRadius.circular(99),
                              ),
                            );
                          }),
                        ),
                      ),
                  ],
                )
              : Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.photo_outlined,
                          color: AymaColors.fgMute, size: 28),
                      const SizedBox(height: 8),
                      Text('No photos yet',
                          style: AymaFonts.sans(size: 13, color: AymaColors.fgMute)),
                    ],
                  ),
                ),
        ),
        if (widget.showEditControls) ...[
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: widget.uploadingPhoto ? null : widget.onAddPhoto,
              icon: widget.uploadingPhoto
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: AymaColors.accent,
                      ),
                    )
                  : const Icon(Icons.add_a_photo_outlined, size: 16),
              label: Text(widget.uploadingPhoto ? 'Uploading…' : 'Add photo'),
            ),
          ),
        ],
        const SizedBox(height: 24),
        Text('BASICS', style: AymaFonts.mono(size: 9, color: AymaColors.fgMute)),
        const SizedBox(height: 10),
        Container(
          decoration: BoxDecoration(
            color: AymaColors.bgElev,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: AymaColors.lineSoft, width: 0.5),
          ),
          child: Column(
            children: [
              _BasicRow(label: 'Name', value: widget.name.isNotEmpty ? widget.name : '—', onTap: widget.onStartEdit),
              const _RowDivider(),
              _BasicRow(label: 'Age', value: widget.age != null ? '${widget.age}' : '—', onTap: widget.onStartEdit),
              const _RowDivider(),
              _BasicRow(label: 'Gender', value: widget.gender.isNotEmpty ? widget.gender : '—', onTap: widget.onStartEdit),
              const _RowDivider(),
              _BasicRow(label: 'Location', value: widget.location.isNotEmpty ? widget.location : '—', onTap: widget.onStartEdit),
              const _RowDivider(),
              _BasicRow(label: 'Interested in', value: widget.interestedIn.isNotEmpty ? widget.interestedIn : '—', onTap: widget.onStartEdit),
            ],
          ),
        ),
        const SizedBox(height: 24),
        Text('PUBLIC BIO', style: AymaFonts.mono(size: 9, color: AymaColors.fgMute)),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: AymaColors.bgElev,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: AymaColors.lineSoft, width: 0.5),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (widget.showEditControls) ...[
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('What others see',
                        style: AymaFonts.sans(size: 12, color: AymaColors.fgMute)),
                    if (widget.onStartEdit != null)
                      GestureDetector(
                        onTap: widget.onStartEdit,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.edit_outlined,
                                size: 11, color: AymaColors.fgMute),
                            const SizedBox(width: 4),
                            Text('Edit',
                                style: AymaFonts.sans(
                                    size: 11, color: AymaColors.fgMute)),
                          ],
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
              ],
              widget.bio.isNotEmpty
                  ? Text(widget.bio,
                      style: const TextStyle(
                          color: AymaColors.fg, fontSize: 14, height: 1.65))
                  : Text(
                      'No public bio yet.',
                      style: TextStyle(
                          color: AymaColors.fgMute,
                          fontSize: 13,
                          height: 1.6,
                          fontStyle: FontStyle.italic),
                    ),
              if (widget.showEditControls) ...[
                const SizedBox(height: 14),
                Divider(
                    color: AymaColors.lineSoft.withValues(alpha: 0.6),
                    thickness: 0.5,
                    height: 1),
                const SizedBox(height: 12),
                GestureDetector(
                  onTap: widget.onToggleLocked,
                  child: Row(
                    children: [
                      Text(
                        widget.profilePublicLocked ? 'User edited' : 'AI written',
                        style: TextStyle(
                          color: widget.profilePublicLocked
                              ? Colors.green.shade400
                              : AymaColors.accent,
                          fontSize: 10,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
        if (widget.bottom != null) ...[
          const SizedBox(height: 16),
          widget.bottom!,
        ],
      ],
    );
  }
}

class _BasicRow extends StatelessWidget {
  const _BasicRow({required this.label, required this.value, this.onTap});
  final String label;
  final String value;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            SizedBox(
              width: 100,
              child: Text(label,
                  style: AymaFonts.sans(size: 12, color: AymaColors.fgMute)),
            ),
            Expanded(
              child: Text(value,
                  textAlign: TextAlign.right,
                  style: AymaFonts.sans(size: 14, color: AymaColors.fg)),
            ),
          ],
        ),
      ),
    );
  }
}

class _RowDivider extends StatelessWidget {
  const _RowDivider();
  @override
  Widget build(BuildContext context) =>
      Divider(height: 1, color: AymaColors.lineSoft.withValues(alpha: 0.8));
}
