import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../providers/providers.dart';
import '../../services/audio_service.dart';
import '../../services/firestore_service.dart';
import '../../services/backend_service.dart';
import '../../theme.dart';

enum _DraftKind { image, video }

class _DraftAttachment {
  final String id;
  final _DraftKind kind;
  final String filename;
  final Uint8List? previewBytes;
  final String status;
  final String? remoteUrl;

  const _DraftAttachment({
    required this.id,
    required this.kind,
    required this.filename,
    required this.status,
    this.previewBytes,
    this.remoteUrl,
  });

  _DraftAttachment copyWith({String? status, String? remoteUrl}) =>
      _DraftAttachment(
        id: id,
        kind: kind,
        filename: filename,
        previewBytes: previewBytes,
        status: status ?? this.status,
        remoteUrl: remoteUrl ?? this.remoteUrl,
      );
}

class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key});

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final _textCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  final _focusNode = FocusNode();
  final _picker = ImagePicker();
  late final AymaAudioService _audioService;

  int _lastTranscriptCount = 0;
  final List<_DraftAttachment> _drafts = [];

  Timer? _sessionTimer;
  Duration _sessionDuration = Duration.zero;
  bool _voiceActionInFlight = false;
  bool _sendingText = false;
  bool _initialScrollDone = false;

  @override
  void initState() {
    super.initState();
    _audioService = ref.read(audioServiceProvider);
    _textCtrl.addListener(() => setState(() {}));
  }

  void _startTimer() {
    _sessionTimer?.cancel();
    _sessionDuration = Duration.zero;
    _sessionTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(() => _sessionDuration += const Duration(seconds: 1));
      }
    });
  }

  void _stopTimer() {
    _sessionTimer?.cancel();
    _sessionTimer = null;
  }

  Future<bool> _autoConnect() async {
    if (_audioService.state != SessionState.disconnected) return true;
    try {
      await _audioService.connect(userInitiated: true);
      _startTimer();
      return _audioService.state != SessionState.disconnected;
    } catch (_) {}
    return false;
  }

  Future<void> _toggleVoice() async {
    if (_voiceActionInFlight) return;
    _voiceActionInFlight = true;
    if (_audioService.state == SessionState.disconnected) {
      final started = await _autoConnect();
      if (!started && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not start voice session. Please try again.'),
          ),
        );
      }
    } else {
      _audioService.disconnect();
      _stopTimer();
      setState(() => _sessionDuration = Duration.zero);
    }
    _voiceActionInFlight = false;
  }

  Future<void> _sendText() async {
    if (_sendingText) return;
    final text = _textCtrl.text.trim();
    if (_drafts.isEmpty && text.isEmpty) return;
    _sendingText = true;
    try {

      // If there are pending uploads, wait a bit instead of showing a snackbar.
      if (_drafts.isNotEmpty &&
          _drafts
              .any((d) => d.remoteUrl == null && d.status != 'Upload failed')) {
        int retries = 0;
        while (_drafts.any(
                (d) => d.remoteUrl == null && d.status != 'Upload failed') &&
            retries < 40) {
          await Future<void>.delayed(const Duration(milliseconds: 500));
          retries++;
        }
      }

      final failed = _drafts.where((d) => d.status == 'Upload failed').toList();
      if (failed.isNotEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content: Text('Some attachments failed to upload. '
                    'Please remove them or try again.')),
          );
        }
        return;
      }

      if (_drafts.any((d) => d.remoteUrl == null)) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content: Text('Attachment upload timed out. Please try again.')),
          );
        }
        return;
      }

      final ready = _drafts.where((d) => d.remoteUrl != null).toList();
      if (text.isEmpty && ready.isEmpty) return;

      final message = text;
      final attachments = [
        for (final d in ready)
          {
            'url': d.remoteUrl!,
            'kind': d.kind == _DraftKind.image ? 'image' : 'video',
            'filename': d.filename
          },
      ];

      // Clear UI state BEFORE the async call (or immediately after clearing text)
      _textCtrl.clear();
      final idsToRemove = ready.map((d) => d.id).toSet();
      setState(() => _drafts.removeWhere((d) => idsToRemove.contains(d.id)));

      final sent = await _audioService.sendText(message, attachments: attachments);
      if (!sent && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Message sent locally, but reply generation failed.'),
          ),
        );
      }
    } finally {
      _sendingText = false;
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        final max = _scrollCtrl.position.maxScrollExtent;
        _scrollCtrl.jumpTo(max);
        Future<void>.delayed(const Duration(milliseconds: 90), () {
          if (_scrollCtrl.hasClients) {
            _scrollCtrl.jumpTo(_scrollCtrl.position.maxScrollExtent);
          }
        });
      }
    });
  }

  Future<void> _pickImage(ImageSource source) async {
    Navigator.of(context).maybePop();
    final picked = await _picker.pickImage(
        source: source, imageQuality: 90, maxWidth: 1800);
    if (picked == null) return;
    final bytes = await picked.readAsBytes();
    final draft = _DraftAttachment(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      kind: _DraftKind.image,
      filename: picked.name,
      previewBytes: bytes,
      status: 'Processing...',
    );
    setState(() {
      _drafts.insert(0, draft);
    });
    await _uploadDraft(draft, bytes);
  }

  Future<void> _pickVideo(ImageSource source) async {
    Navigator.of(context).maybePop();
    final picked = await _picker.pickVideo(
        source: source, maxDuration: const Duration(minutes: 3));
    if (picked == null) return;
    final bytes = await picked.readAsBytes();
    final draft = _DraftAttachment(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      kind: _DraftKind.video,
      filename: picked.name,
      status: 'Uploading...',
    );
    setState(() {
      _drafts.insert(0, draft);
    });
    await _uploadDraft(draft, bytes);
  }

  Future<void> _uploadDraft(_DraftAttachment draft, Uint8List bytes) async {
    try {
      final url = await BackendService.uploadMedia(bytes, draft.filename);
      if (draft.kind == _DraftKind.image) {
        await FirestoreService.saveMediaRecord(photoUrl: url);
        ref.invalidate(insightsProvider);
      }
      final status = draft.kind == _DraftKind.video ? 'Video attached' : 'Photo attached';
      final i = _drafts.indexWhere((d) => d.id == draft.id);
      if (i != -1) {
        setState(() =>
            _drafts[i] = _drafts[i].copyWith(status: status, remoteUrl: url));
      }
    } catch (e) {
      final i = _drafts.indexWhere((d) => d.id == draft.id);
      if (i != -1) {
        setState(
            () => _drafts[i] = _drafts[i].copyWith(status: 'Upload failed'));
      }
    }
  }

  void _removeDraft(String id) =>
      setState(() => _drafts.removeWhere((d) => d.id == id));

  void _showMediaSheet() {
    final bottomInset = MediaQuery.viewPaddingOf(context).bottom;
    showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => Padding(
        padding: EdgeInsets.only(bottom: 56 + bottomInset),
        child: _MediaSheet(
          onPhotoCamera: () => _pickImage(ImageSource.camera),
          onPhotoGallery: () => _pickImage(ImageSource.gallery),
          onVideoCamera: () => _pickVideo(ImageSource.camera),
          onVideoGallery: () => _pickVideo(ImageSource.gallery),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _sessionTimer?.cancel();
    _textCtrl.dispose();
    _scrollCtrl.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  String get _timerLabel {
    final m =
        _sessionDuration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s =
        _sessionDuration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(audioServiceProvider.select((a) => a.state));
    final transcriptN =
        ref.watch(audioServiceProvider.select((a) => a.transcript.length));
    final muted = ref.watch(audioServiceProvider.select((a) => a.muted));
    final inputVol =
        ref.watch(audioServiceProvider.select((a) => a.inputVolume));
    final outputVol =
        ref.watch(audioServiceProvider.select((a) => a.outputVolume));
    final userTalking =
        ref.watch(audioServiceProvider.select((a) => a.userTalking));
    final transcript = _audioService.transcript;

    if (transcriptN != _lastTranscriptCount) {
      _lastTranscriptCount = transcriptN;
      _scrollToBottom();
    }
    if (!_initialScrollDone && transcript.isNotEmpty) {
      _initialScrollDone = true;
      _scrollToBottom();
    }

    final connected = state != SessionState.disconnected;
    return Scaffold(
      backgroundColor: AymaColors.bg,
      resizeToAvoidBottomInset: true,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            // ── Top bar ─────────────────────────────────────────────
            _TopBar(
              connected: connected,
              timerLabel: connected ? 'Session · $_timerLabel' : 'Offline',
            ),

            // ── Transcript ──────────────────────────────────────────
            Expanded(
              child: _TranscriptArea(
                transcript: transcript,
                scrollCtrl: _scrollCtrl,
              ),
            ),

            // ── Input bar / dock (always visible) ───────────────────
            _InputBar(
              state: state,
              muted: muted,
              textCtrl: _textCtrl,
              focusNode: _focusNode,
              inputVolume: inputVol,
              outputVolume: outputVol,
              userTalking: userTalking,
              hasAttachment: _drafts.isNotEmpty,
              drafts: _drafts,
              onMicTap: _toggleVoice,
              onSend: _sendText,
              onAttach: _showMediaSheet,
              onRemoveDraft: _removeDraft,
            ),
          ],
        ),
      ),
    );
  }
}

// ── Top bar ──────────────────────────────────────────────────────────────────

class _TopBar extends StatelessWidget {
  final bool connected;
  final String timerLabel;

  const _TopBar({
    required this.connected,
    required this.timerLabel,
  });

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 14, 24, 4),
        child: Row(
          children: [
            Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: connected
                        ? AymaColors.accent
                        : AymaColors.fgMute.withValues(alpha: 0.7))),
            const SizedBox(width: 10),
            Text(timerLabel.toUpperCase(),
                style: AymaFonts.mono(
                    size: 10, color: AymaColors.fgDim, letterSpacing: 0.18)),
          ],
        ),
      );
}

// ── Transcript ────────────────────────────────────────────────────────────────

class _TranscriptArea extends StatelessWidget {
  final List<TranscriptLine> transcript;
  final ScrollController scrollCtrl;

  const _TranscriptArea({required this.transcript, required this.scrollCtrl});

  @override
  Widget build(BuildContext context) {
    if (transcript.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                  height: 0.5,
                  color: AymaColors.lineSoft.withValues(alpha: 0.75)),
              const SizedBox(height: 20),
              Text("Tonight's conversation",
                  style: AymaFonts.mono(size: 10, color: AymaColors.fgMute)),
              const SizedBox(height: 20),
              Text('Your conversation begins when you start speaking.',
                  textAlign: TextAlign.center,
                  style: AymaFonts.serif(
                      size: 18, italic: true, color: AymaColors.fgDim)),
            ],
          ),
        ),
      );
    }

    return ListView.builder(
      controller: scrollCtrl,
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
      itemCount: transcript.length,
      itemBuilder: (_, i) {
        final line = transcript[i];
        return _TranscriptEntry(
                line: line, isLatest: i == transcript.length - 1)
            .animate()
            .fadeIn(duration: 220.ms)
            .slideY(begin: 0.03, end: 0);
      },
    );
  }
}

class _TranscriptEntry extends StatelessWidget {
  final TranscriptLine line;
  final bool isLatest;
  const _TranscriptEntry({required this.line, required this.isLatest});

  @override
  Widget build(BuildContext context) {
    final isAyma = !line.isUser;
    final hasAttachments =
        line.attachments != null && line.attachments!.isNotEmpty;

    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Opacity(
        opacity: isLatest ? 1.0 : 0.72,
        child: Column(
          crossAxisAlignment:
              isAyma ? CrossAxisAlignment.start : CrossAxisAlignment.end,
          children: [
            Text(
              isAyma ? 'AYMA' : 'YOU',
              style: AymaFonts.mono(
                size: 9,
                color: isAyma ? AymaColors.accent : AymaColors.fgMute,
                letterSpacing: 0.2,
              ),
            ),
            const SizedBox(height: 5),
            if (hasAttachments) ...[
              for (final att in line.attachments!)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _MediaBubble(attachment: att),
                ),
            ],
            if (isAyma)
              MarkdownBody(
                data: line.text,
                styleSheet: MarkdownStyleSheet(
                  p: AymaFonts.serif(size: 20, italic: true, color: AymaColors.fg),
                  strong: AymaFonts.serif(size: 20, italic: false, color: AymaColors.fg)
                      .copyWith(fontWeight: FontWeight.w700),
                  em: AymaFonts.serif(size: 20, italic: true, color: AymaColors.fg),
                  listBullet: AymaFonts.serif(size: 20, italic: true, color: AymaColors.fg),
                  blockSpacing: 8,
                  listIndent: 16,
                ),
                softLineBreak: true,
              )
            else if (line.text.isNotEmpty)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                decoration: BoxDecoration(
                  color: AymaColors.bgCard,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: AymaColors.lineSoft.withValues(alpha: 0.6),
                    width: 0.5,
                  ),
                ),
                child: Text(
                  line.text,
                  textAlign: TextAlign.right,
                  style: AymaFonts.elegantSans(size: 15, color: AymaColors.fg)
                      .copyWith(height: 1.5),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _MediaBubble extends StatelessWidget {
  final Map<String, dynamic> attachment;
  const _MediaBubble({required this.attachment});

  @override
  Widget build(BuildContext context) {
    var url = attachment['url'] as String?;
    final kind = attachment['kind'] as String?;
    if (url == null) return const SizedBox.shrink();

    Widget content;
    if (url.startsWith('http')) {
      content = Image.network(
        url,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => Container(
          color: AymaColors.bgElev,
          child: const Center(
              child: Icon(Icons.broken_image_rounded, color: AymaColors.fgDim)),
        ),
      );
    } else if (url.startsWith('gs://')) {
      // For now show placeholder for GCS since direct loading needs auth
      content = Container(
        color: AymaColors.bgElev,
        child: const Center(
          child: Icon(Icons.cloud_done_rounded, color: AymaColors.fgDim),
        ),
      );
    } else {
      // Local path
      final file = File(url);
      if (file.existsSync()) {
        content = Image.file(file, fit: BoxFit.cover);
      } else {
        content = Container(color: AymaColors.bgElev);
      }
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: 200,
        height: 150,
        color: AymaColors.bgCard,
        child: Stack(
          children: [
            Positioned.fill(child: content),
            if (kind == 'video')
              const Center(
                child: Icon(Icons.play_circle_fill_rounded,
                    color: Colors.white70, size: 42),
              ),
          ],
        ),
      ),
    );
  }
}

// ── Input bar ─────────────────────────────────────────────────────────────────
// Always visible. Shows waveform when Ayma is speaking; text input otherwise.

class _InputBar extends StatefulWidget {
  final SessionState state;
  final bool muted;
  final TextEditingController textCtrl;
  final FocusNode focusNode;
  final double inputVolume;
  final double outputVolume;
  final bool hasAttachment;
  final List<_DraftAttachment> drafts;
  final bool userTalking;
  final VoidCallback onMicTap;
  final Future<void> Function() onSend;
  final VoidCallback onAttach;
  final ValueChanged<String> onRemoveDraft;

  const _InputBar({
    required this.state,
    required this.muted,
    required this.textCtrl,
    required this.focusNode,
    required this.inputVolume,
    required this.outputVolume,
    required this.userTalking,
    required this.hasAttachment,
    required this.drafts,
    required this.onMicTap,
    required this.onSend,
    required this.onAttach,
    required this.onRemoveDraft,
  });

  @override
  State<_InputBar> createState() => _InputBarState();
}

// ── Composer geometry — single source of truth for painter + content ──────────
// Constraint: _kWaveBaseY + _kShellR < _kShellH - _kShellR (valid arc segments)
// With these values: 18+24=42 < 72-24=48 ✓
const double _kShellH = 72.0;
const double _kShellR = 24.0; // reduced so corner arcs are geometrically valid
const double _kWaveBaseY =
    18.0; // wave oscillates around this y inside the pill
const double _kHPad = 14.0;

class _InputBarState extends State<_InputBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _glowCtrl;
  late final Animation<double> _glow;

  @override
  void initState() {
    super.initState();
    _glowCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1200))
      ..repeat();
    _glow = CurvedAnimation(parent: _glowCtrl, curve: Curves.linear);
  }

  @override
  void dispose() {
    _glowCtrl.dispose();
    super.dispose();
  }

  bool get _aymaActive =>
      widget.state == SessionState.speaking || widget.userTalking;
  bool get _voiceActive =>
      widget.state == SessionState.listening ||
      widget.state == SessionState.speaking ||
      widget.state == SessionState.thinking ||
      widget.state == SessionState.ready;
  bool get _hasText => widget.textCtrl.text.trim().isNotEmpty;
  bool get _canSend =>
      _hasText ||
      (widget.hasAttachment && widget.drafts.every((d) => d.remoteUrl != null));

  double get _volume => widget.state == SessionState.speaking
      ? widget.outputVolume
      : widget.inputVolume;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _glow,
      builder: (_, __) {
        final g = _voiceActive ? (0.55 + _glow.value * 0.45) : 0.0;
        // ClipRect stops the box shadow from bleeding upward into the transcript.
        // Box shadows are painted on the parent canvas layer and ignore the
        // Container's own clipBehavior — an outer ClipRect is the only fix.
        // Bottom padding (14) is inside the clip so the downward glow is visible.
        return ClipRect(
            child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.drafts.isNotEmpty)
                _DraftDockStrip(
                  drafts: widget.drafts,
                  onRemoveDraft: widget.onRemoveDraft,
                ),
              // Shell: no background on the outer Container — background lives
              // inside ClipRRect so it can never leak outside the pill shape.
              // Voice-active glow is drawn by the painter (canvas-bounded),
              // not via boxShadow (which bleeds through ClipRect on Impeller/iOS).
              DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(_kShellR),
                  boxShadow: _voiceActive
                      ? null // painter handles glow; no upward-bleeding shadow
                      : [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.30),
                            blurRadius: 12,
                            offset: const Offset(0, 6),
                          ),
                        ],
                ),
                child: CustomPaint(
                  foregroundPainter: _ComposerOutlinePainter(
                    phase: _glow.value,
                    volume: _volume,
                    active: _aymaActive,
                    isAiTalking: widget.state == SessionState.speaking,
                    isUserTalking: widget.userTalking,
                    glowStrength: g,
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(_kShellR),
                    child: ColoredBox(
                      color: AymaColors.bg,
                      child: SizedBox(
                        height: _kShellH,
                        child: Padding(
                          padding: const EdgeInsets.only(top: _kWaveBaseY),
                          child: SizedBox(
                            height: _kShellH - _kWaveBaseY,
                            child: Center(
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: _kHPad),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.center,
                                  children: [
                                    _PillAttachButton(onTap: widget.onAttach),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: _aymaActive && !_hasText
                                          ? _WaveHintText(state: widget.state)
                                          : TextField(
                                              controller: widget.textCtrl,
                                              focusNode: widget.focusNode,
                                              style: AymaFonts.elegantSans(
                                                size: 14.5,
                                                color: AymaColors.fg,
                                              ).copyWith(height: 1.1),
                                              cursorColor: AymaColors.accent,
                                              keyboardType:
                                                  TextInputType.multiline,
                                              textInputAction: _canSend
                                                  ? TextInputAction.send
                                                  : TextInputAction.newline,
                                              minLines: 1,
                                              maxLines: 4,
                                              onSubmitted: (_) {
                                                if (_canSend) widget.onSend();
                                              },
                                              decoration: InputDecoration(
                                                isCollapsed: true,
                                                border: InputBorder.none,
                                                enabledBorder: InputBorder.none,
                                                focusedBorder: InputBorder.none,
                                                filled:
                                                    true, // must be true to apply fillColor
                                                fillColor: Colors.transparent,
                                                contentPadding: EdgeInsets.zero,
                                                hintText: _voiceActive
                                                    ? 'Listening...'
                                                    : 'Speak or type to Ayma',
                                                hintStyle: AymaFonts.elegantSans(
                                                  size: 14.5,
                                                  color: AymaColors.fgMute,
                                                ).copyWith(
                                                  fontStyle: _voiceActive
                                                      ? FontStyle.italic
                                                      : FontStyle.normal,
                                                ),
                                              ),
                                            ),
                                    ),
                                    const SizedBox(width: 12),
                                    _DockActionCircle(
                                      icon: _canSend
                                          ? Icons.arrow_upward_rounded
                                          : _voiceActive
                                              ? Icons.mic_rounded
                                              : Icons.mic_none_rounded,
                                      onTap: _canSend
                                          ? () => widget.onSend()
                                          : widget.onMicTap,
                                      active: _canSend || _voiceActive,
                                      live: !_canSend && _voiceActive,
                                      send: _canSend,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ), // SizedBox
                    ), // ColoredBox
                  ), // ClipRRect
                ), // CustomPaint
              ), // DecoratedBox
            ],
          ),
        )); // closes ClipRect > Padding > Column
      },
    );
  }
}

class _DraftDockStrip extends StatelessWidget {
  final List<_DraftAttachment> drafts;
  final ValueChanged<String> onRemoveDraft;

  const _DraftDockStrip({
    required this.drafts,
    required this.onRemoveDraft,
  });

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(left: 10, right: 10, bottom: 6),
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
        decoration: BoxDecoration(
          color: const Color(0xFF17130F),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
          border: Border.all(
            color: AymaColors.lineSoft.withValues(alpha: 0.9),
            width: 0.8,
          ),
        ),
        child: SizedBox(
          height: 54,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: drafts.length,
            separatorBuilder: (_, __) => const SizedBox(width: 8),
            itemBuilder: (_, i) {
              final d = drafts[i];
              final ready = d.remoteUrl != null;
              return Stack(
                children: [
                  Container(
                    width: 54,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      color: AymaColors.bgElev,
                      border: Border.all(
                        color: ready
                            ? AymaColors.accent.withValues(alpha: 0.35)
                            : AymaColors.lineSoft,
                        width: 0.7,
                      ),
                    ),
                    child: d.kind == _DraftKind.image && d.previewBytes != null
                        ? ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            child: Image.memory(d.previewBytes!,
                                fit: BoxFit.cover),
                          )
                        : const Icon(Icons.videocam_rounded,
                            color: AymaColors.accent),
                  ),
                  Positioned(
                    left: 6,
                    right: 6,
                    bottom: 4,
                    child: Text(
                      ready ? 'Ready' : '...',
                      textAlign: TextAlign.center,
                      style: AymaFonts.mono(
                        size: 6.5,
                        color: ready ? AymaColors.accent : AymaColors.fgMute,
                        letterSpacing: 0.08,
                      ),
                    ),
                  ),
                  Positioned(
                    top: 2,
                    right: 2,
                    child: GestureDetector(
                      onTap: () => onRemoveDraft(d.id),
                      child: Container(
                        width: 14,
                        height: 14,
                        decoration: const BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.black54,
                        ),
                        child: const Icon(Icons.close,
                            size: 9, color: Colors.white),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      );
}

class _DockActionCircle extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final bool active;
  final bool live;
  final bool send;

  const _DockActionCircle({
    required this.icon,
    required this.onTap,
    required this.active,
    this.live = false,
    this.send = false,
  });

  @override
  Widget build(BuildContext context) {
    final ringColor = send
        ? AymaColors.accent
        : live
            ? AymaColors.accent
            : active
                ? AymaColors.accent.withValues(alpha: 0.65)
                : AymaColors.lineSoft.withValues(alpha: 0.85);

    final iconColor = live
        ? const Color(0xFF1A1208)
        : active
            ? AymaColors.accent
            : AymaColors.fgDim;

    final outerSize = live ? 42.0 : 36.0;
    final iconSize = live ? 18.0 : 15.0;

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: outerSize,
        height: outerSize,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: live
              ? AymaColors.accent
              : active
                  ? AymaColors.accent.withValues(alpha: 0.15)
                  : AymaColors.bg,
          border: Border.all(
            color: ringColor,
            width: live ? 1.2 : 0.85,
          ),
        ),
        child: Icon(icon, size: iconSize, color: iconColor),
      ),
    );
  }
}

class _PillAttachButton extends StatelessWidget {
  final VoidCallback onTap;

  const _PillAttachButton({
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          width: 38,
          height: 38,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: AymaColors.bg,
            border: Border.all(
              color: AymaColors.lineSoft.withValues(alpha: 0.9),
              width: 0.8,
            ),
          ),
          child: const Icon(
            Icons.attach_file_rounded,
            size: 18,
            color: AymaColors.fgMute,
          ),
        ),
      );
}

class _ComposerOutlinePainter extends CustomPainter {
  final double phase;
  final double volume;
  final bool active;
  final bool isAiTalking;
  final bool isUserTalking;
  final double glowStrength; // 0–1, drives outer glow replacing box shadow

  const _ComposerOutlinePainter({
    required this.phase,
    required this.volume,
    required this.active,
    required this.isAiTalking,
    required this.isUserTalking,
    this.glowStrength = 0.0,
  });

  // Wave radiates upward from y=0 (top edge of the pill).
  // The ClipRRect handles the pill shape; this painter only draws border strokes.
  // All geometry derives from _kShellR so it matches the ClipRRect exactly.
  @override
  void paint(Canvas canvas, Size size) {
    final level = volume.clamp(0.0, 1.0);
    // AI talks on top, User talks on bottom
    final bool aiTalking = isAiTalking && level > 0.005;
    final bool userTalking = isUserTalking && level > 0.005;

    final freqMod = 1.0 + level * 0.45;
    final speedMod = 1.0 + level * 0.6;

    final goldShader = const LinearGradient(
      begin: Alignment.centerLeft,
      end: Alignment.centerRight,
      colors: [
        Color(0xFF7A5520),
        Color(0xFFF1D08B),
        Color(0xFFD2A23C),
        Color(0xFF6D4B18),
      ],
      stops: [0.0, 0.36, 0.66, 1.0],
    ).createShader(Offset.zero & size);

    void drawEdgeWaves(bool talking, bool atBottom) {
      final amp = talking ? (6.0 + level * 14.0) : 0.0;

      void drawWave(double a, double phaseShift, double freq, double detailFreq,
          [double opacity = 1.0]) {
        final path = _buildBorderPath(
          size,
          amplitude: a,
          phaseShift: (phase * speedMod) + phaseShift,
          frequency: freq * freqMod,
          detailFrequency: detailFreq * freqMod,
          atBottom: atBottom,
        );
        final paint = Paint()
          ..shader = goldShader
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.0
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round;

        if (opacity < 1.0) {
          paint.colorFilter = ColorFilter.mode(
            Colors.white.withValues(alpha: opacity),
            BlendMode.modulate,
          );
        }
        canvas.drawPath(path, paint);
      }

      if (talking) {
        drawWave(amp * 0.55, 0.35, 1.3, 2.6, 0.28);
        drawWave(amp * 0.75, -0.25, 2.4, 4.2, 0.45);
      }
      drawWave(amp, 0.0, 1.85, 3.4, 1.0);
    }

    // If both talk, they might overlap or draw over each other, but this follows the logic:
    // User talk animations happen on bottom border, AI on top.
    if (userTalking) {
      drawEdgeWaves(true, true);
    }
    if (aiTalking || (!userTalking)) {
      // Draw top edge waves if AI is talking, OR if nothing is happening (static border)
      drawEdgeWaves(aiTalking, false);
    }
  }

  // Traces the full pill border with a wave across the top edge (y≈0).
  // Corner arcs match _kShellR so the stroke sits exactly on the ClipRRect boundary.
  Path _buildBorderPath(
    Size size, {
    required double amplitude,
    required double phaseShift,
    required double frequency,
    required double detailFrequency,
    bool atBottom = false,
  }) {
    const r = _kShellR;
    const topBaselineY = _kWaveBaseY;
    final w = size.width;
    final h = size.height;
    final waveLeft = r;
    final waveRight = w - r;
    final waveWidth = waveRight - waveLeft;

    final path = Path();

    // Top edge
    path.moveTo(waveLeft, topBaselineY);
    if (!atBottom) {
      const step = 2.0;
      for (double x = waveLeft; x <= waveRight; x += step) {
        final t = (x - waveLeft) / waveWidth;
        path.lineTo(
            x,
            _waveY(t,
                baselineY: topBaselineY,
                amplitude: amplitude,
                phaseShift: phaseShift,
                frequency: frequency,
                detailFrequency: detailFrequency,
                isTop: true));
      }
    }
    path.lineTo(waveRight, topBaselineY);

    // top-right corner
    path.arcToPoint(Offset(w, topBaselineY + r),
        radius: const Radius.circular(r), clockwise: true);
    // right side
    path.lineTo(w, h - r);
    // bottom-right corner
    path.arcToPoint(Offset(w - r, h),
        radius: const Radius.circular(r), clockwise: true);

    // Bottom edge
    if (atBottom) {
      const step = 2.0;
      for (double x = waveRight; x >= waveLeft; x -= step) {
        final t = (waveRight - x) / waveWidth;
        path.lineTo(
            x,
            _waveY(t,
                baselineY: h,
                amplitude: amplitude,
                phaseShift: phaseShift,
                frequency: frequency,
                detailFrequency: detailFrequency,
                isTop: false));
      }
    }
    path.lineTo(waveLeft, h);

    // bottom-left corner
    path.arcToPoint(Offset(0, h - r),
        radius: const Radius.circular(r), clockwise: true);
    // left side
    path.lineTo(0, topBaselineY + r);
    // top-left corner
    path.arcToPoint(Offset(waveLeft, topBaselineY),
        radius: const Radius.circular(r), clockwise: true);

    path.close();
    return path;
  }

  double _waveY(
    double t, {
    required double baselineY,
    required double amplitude,
    required double phaseShift,
    required double frequency,
    required double detailFrequency,
    required bool isTop,
  }) {
    if (amplitude <= 0.01) return baselineY;
    final gaussian = math.exp(-math.pow((t - 0.5) * 4.3, 2).toDouble());
    final carrier = math.sin(
        (t * math.pi * 2 * frequency) + ((phase + phaseShift) * math.pi * 2));
    final detail = math.sin(
        (t * math.pi * 2 * detailFrequency) - ((phase * 0.75) * math.pi * 2));
    // isTop wave moves UP (negative y), isBottom wave moves DOWN (positive y)
    final lift = (isTop ? 1 : -1) * amplitude * gaussian * (carrier + detail * 0.42);
    return baselineY - lift;
  }

  @override
  bool shouldRepaint(_ComposerOutlinePainter old) =>
      old.phase != phase ||
      old.volume != volume ||
      old.active != active ||
      old.isAiTalking != isAiTalking ||
      old.isUserTalking != isUserTalking ||
      old.glowStrength != glowStrength;
}

// Subtle hint text shown in the field when Ayma is speaking & no user text
class _WaveHintText extends StatelessWidget {
  final SessionState state;
  const _WaveHintText({required this.state});

  @override
  Widget build(BuildContext context) => Text(
        state == SessionState.thinking ? 'Thinking...' : 'Ayma is speaking...',
        style: const TextStyle(
            color: AymaColors.fgMute,
            fontSize: 14,
            fontStyle: FontStyle.italic),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      );
}

// ── Media sheet ───────────────────────────────────────────────────────────────

class _MediaSheet extends StatelessWidget {
  final Future<void> Function() onPhotoCamera;
  final Future<void> Function() onPhotoGallery;
  final Future<void> Function() onVideoCamera;
  final Future<void> Function() onVideoGallery;

  const _MediaSheet({
    required this.onPhotoCamera,
    required this.onPhotoGallery,
    required this.onVideoCamera,
    required this.onVideoGallery,
  });

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.all(12),
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
        decoration: BoxDecoration(
          color: AymaColors.bgElev,
          borderRadius: BorderRadius.circular(26),
          border: Border.all(color: AymaColors.lineSoft, width: 0.5),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
                child: Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                        color: AymaColors.fgMute,
                        borderRadius: BorderRadius.circular(4)))),
            const SizedBox(height: 20),
            Text('SHARE WITH AYMA',
                style: AymaFonts.mono(size: 10, color: AymaColors.fgMute)),
            const SizedBox(height: 12),
            Text('What are you showing me?', style: AymaFonts.serif(size: 26)),
            const SizedBox(height: 20),
            Row(children: [
              Expanded(
                  child: _MediaTile(
                      icon: Icons.photo_camera_rounded,
                      title: 'Take Photo',
                      onTap: onPhotoCamera)),
              const SizedBox(width: 10),
              Expanded(
                  child: _MediaTile(
                      icon: Icons.collections_rounded,
                      title: 'Gallery',
                      onTap: onPhotoGallery)),
            ]),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(
                  child: _MediaTile(
                      icon: Icons.videocam_rounded,
                      title: 'Record Video',
                      onTap: onVideoCamera)),
              const SizedBox(width: 10),
              Expanded(
                  child: _MediaTile(
                      icon: Icons.video_library_rounded,
                      title: 'Videos',
                      onTap: onVideoGallery)),
            ]),
          ],
        ),
      );
}

class _MediaTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final Future<void> Function() onTap;
  const _MediaTile(
      {required this.icon, required this.title, required this.onTap});

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 18),
          decoration: BoxDecoration(
            color: AymaColors.bgCard,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: AymaColors.lineSoft, width: 0.5),
          ),
          child: Column(children: [
            Icon(icon, size: 24, color: AymaColors.accent),
            const SizedBox(height: 10),
            Text(title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: AymaColors.fg,
                    fontSize: 12,
                    fontWeight: FontWeight.w500)),
          ]),
        ),
      );
}
