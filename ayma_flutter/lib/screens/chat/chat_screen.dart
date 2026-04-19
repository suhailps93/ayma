import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../env.dart';
import '../../providers/providers.dart';
import '../../services/audio_service.dart';
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

  @override
  void initState() {
    super.initState();
    _audioService = ref.read(audioServiceProvider);
    _textCtrl.addListener(() => setState(() {}));
    WidgetsBinding.instance.addPostFrameCallback((_) => _autoConnect());
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

  Future<void> _autoConnect() async {
    if (_audioService.state != SessionState.disconnected) return;
    if (ref.read(currentUserProvider) == null) return;
    try {
      await _audioService.connect(Env.wsUrl);
      _startTimer();
    } catch (_) {}
  }

  Future<void> _toggleVoice() async {
    if (_audioService.state == SessionState.disconnected) {
      await _autoConnect();
    } else {
      _audioService.disconnect();
      _stopTimer();
      setState(() => _sessionDuration = Duration.zero);
    }
  }

  Future<void> _sendText() async {
    final text = _textCtrl.text.trim();
    if (_drafts.isNotEmpty && _drafts.every((d) => d.remoteUrl == null)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Attachment is still preparing...')),
        );
      }
      return;
    }
    final ready = _drafts.where((d) => d.remoteUrl != null).toList();
    if (text.isEmpty && ready.isEmpty) return;

    final message = text.isEmpty ? 'Please analyze what I just shared.' : text;
    final attachments = [
      for (final d in ready)
        {
          'url': d.remoteUrl!,
          'kind': d.kind == _DraftKind.image ? 'image' : 'video',
          'filename': d.filename
        },
    ];
    _textCtrl.clear();

    if (_audioService.state == SessionState.disconnected) {
      await _autoConnect();
      await Future.delayed(const Duration(milliseconds: 600));
    }
    await _audioService.sendText(message, attachments: attachments);
    if (mounted && ready.isNotEmpty) {
      setState(() => _drafts.removeWhere((d) => d.remoteUrl != null));
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(
          _scrollCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
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
      final res = await BackendService.uploadFileBytes(
        '/api/media/upload',
        bytes,
        filename: draft.filename,
      ) as Map<String, dynamic>;
      final url = res['photo_url'] as String?;
      final status = (res['media_type'] as String?) == 'video'
          ? 'Video attached'
          : 'Photo attached';
      final i = _drafts.indexWhere((d) => d.id == draft.id);
      if (i != -1) {
        setState(() =>
            _drafts[i] = _drafts[i].copyWith(status: status, remoteUrl: url));
      }
      if (draft.kind == _DraftKind.image) ref.invalidate(insightsProvider);
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
    final transcript = _audioService.transcript;

    if (transcriptN != _lastTranscriptCount) {
      _lastTranscriptCount = transcriptN;
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

            // ── Draft thumbnails ────────────────────────────────────
            if (_drafts.isNotEmpty)
              SizedBox(
                height: 68,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  itemCount: _drafts.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 8),
                  itemBuilder: (_, i) {
                    final d = _drafts[i];
                    return Stack(
                      children: [
                        Container(
                          width: 54,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(10),
                            color: AymaColors.bgElev,
                            border: Border.all(
                                color: AymaColors.lineSoft, width: 0.5),
                          ),
                          child: d.kind == _DraftKind.image &&
                                  d.previewBytes != null
                              ? ClipRRect(
                                  borderRadius: BorderRadius.circular(10),
                                  child: Image.memory(d.previewBytes!,
                                      fit: BoxFit.cover))
                              : const Icon(Icons.videocam_rounded,
                                  color: AymaColors.accent),
                        ),
                        Positioned(
                          top: 2,
                          right: 2,
                          child: GestureDetector(
                            onTap: () => _removeDraft(d.id),
                            child: Container(
                              width: 14,
                              height: 14,
                              decoration: const BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: Colors.black54),
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

            // ── Input bar (always visible) ──────────────────────────
            _InputBar(
              state: state,
              muted: muted,
              textCtrl: _textCtrl,
              focusNode: _focusNode,
              inputVolume: inputVol,
              outputVolume: outputVol,
              hasAttachment: _drafts.isNotEmpty,
              onMicTap: _toggleVoice,
              onSend: _sendText,
              onAttach: _showMediaSheet,
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
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Opacity(
        opacity: isLatest ? 1.0 : 0.5,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(isAyma ? 'AYMA' : 'YOU',
                style: AymaFonts.mono(
                    size: 9,
                    color: isAyma ? AymaColors.accent : AymaColors.fgMute,
                    letterSpacing: 0.2)),
            const SizedBox(height: 4),
            Text(line.text,
                style: isAyma
                    ? AymaFonts.serif(
                        size: 20, italic: true, color: AymaColors.fg)
                    : AymaFonts.sans(size: 16, color: AymaColors.fgDim)
                        .copyWith(height: 1.55)),
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
  final VoidCallback onMicTap;
  final Future<void> Function() onSend;
  final VoidCallback onAttach;

  const _InputBar({
    required this.state,
    required this.muted,
    required this.textCtrl,
    required this.focusNode,
    required this.inputVolume,
    required this.outputVolume,
    required this.hasAttachment,
    required this.onMicTap,
    required this.onSend,
    required this.onAttach,
  });

  @override
  State<_InputBar> createState() => _InputBarState();
}

class _InputBarState extends State<_InputBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _glowCtrl;
  late final Animation<double> _glow;

  @override
  void initState() {
    super.initState();
    _glowCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1600))
      ..repeat(reverse: true);
    _glow = CurvedAnimation(parent: _glowCtrl, curve: Curves.easeInOut);
  }

  @override
  void dispose() {
    _glowCtrl.dispose();
    super.dispose();
  }

  bool get _aymaActive => widget.state == SessionState.speaking;
  bool get _voiceActive =>
      widget.state == SessionState.listening ||
      widget.state == SessionState.speaking ||
      widget.state == SessionState.thinking;
  bool get _hasText => widget.textCtrl.text.trim().isNotEmpty;
  bool get _canSend => _hasText || widget.hasAttachment;

  double get _volume => _aymaActive ? widget.outputVolume : widget.inputVolume;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _glow,
      builder: (_, __) {
        final g = _voiceActive ? (0.55 + _glow.value * 0.45) : 0.0;
        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFF15120F),
                    borderRadius: BorderRadius.circular(32),
                    border: Border(
                      left: BorderSide(
                        color: AymaColors.accent
                            .withValues(alpha: _voiceActive ? 0.9 : 0.22),
                        width: 1.0,
                      ),
                      right: BorderSide(
                        color: AymaColors.accent
                            .withValues(alpha: _voiceActive ? 0.9 : 0.22),
                        width: 1.0,
                      ),
                      bottom: BorderSide(
                        color: AymaColors.accent
                            .withValues(alpha: _voiceActive ? 0.9 : 0.22),
                        width: 1.0,
                      ),
                    ),
                    boxShadow: _voiceActive
                        ? [
                            BoxShadow(
                              color:
                                  AymaColors.accent.withValues(alpha: g * 0.2),
                              blurRadius: 14 + g * 8,
                            ),
                            BoxShadow(
                              color:
                                  AymaColors.accent.withValues(alpha: g * 0.08),
                              blurRadius: 24,
                              spreadRadius: 1,
                            ),
                          ]
                        : null,
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(32),
                    child: SizedBox(
                      height: 60,
                      child: Stack(
                        children: [
                          Positioned.fill(
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  colors: [
                                    AymaColors.accent.withValues(
                                      alpha: _aymaActive ? 0.035 : 0.012,
                                    ),
                                    Colors.transparent,
                                  ],
                                ),
                              ),
                            ),
                          ),
                          Positioned(
                            top: 0,
                            left: 0,
                            right: 0,
                            height: 18,
                            child: _WaveformBg(
                              volume: _volume,
                              glow: _glow,
                              active: _aymaActive,
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(10, 11, 10, 5),
                            child: Row(
                              children: [
                                _PillAttachButton(
                                  onTap: widget.onAttach,
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: _aymaActive && !_hasText
                                      ? _WaveHintText(state: widget.state)
                                      : TextField(
                                          controller: widget.textCtrl,
                                          focusNode: widget.focusNode,
                                          style: const TextStyle(
                                              color: AymaColors.fg,
                                              fontSize: 14,
                                              height: 1.4),
                                          cursorColor: AymaColors.accent,
                                          minLines: 1,
                                          maxLines: 4,
                                          onSubmitted: (_) {
                                            if (_canSend) {
                                              widget.onSend();
                                            }
                                          },
                                          decoration: InputDecoration(
                                            isCollapsed: true,
                                            border: InputBorder.none,
                                            enabledBorder: InputBorder.none,
                                            focusedBorder: InputBorder.none,
                                            contentPadding: EdgeInsets.zero,
                                            hintText: _voiceActive
                                                ? 'Listening...'
                                                : 'Speak or type to Ayma',
                                            hintStyle: TextStyle(
                                                color: AymaColors.fgMute,
                                                fontSize: 14,
                                                fontStyle: _voiceActive
                                                    ? FontStyle.italic
                                                    : FontStyle.normal),
                                          ),
                                        ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              _DockActionCircle(
                icon: _canSend
                    ? Icons.arrow_upward_rounded
                    : Icons.mic_none_rounded,
                onTap: _canSend ? () => widget.onSend() : widget.onMicTap,
                active: _canSend || _voiceActive,
              ),
            ],
          ),
        );
      },
    );
  }
}

class _DockActionCircle extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final bool active;

  const _DockActionCircle({
    required this.icon,
    required this.onTap,
    required this.active,
  });

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: const Color(0xFF17130F),
            border: Border.all(
              color: active
                  ? AymaColors.accent.withValues(alpha: 0.45)
                  : AymaColors.lineSoft.withValues(alpha: 0.9),
              width: 0.9,
            ),
            boxShadow: active
                ? [
                    BoxShadow(
                      color: AymaColors.accent.withValues(alpha: 0.18),
                      blurRadius: 18,
                    ),
                  ]
                : null,
          ),
          child: Icon(
            icon,
            size: 22,
            color: active ? AymaColors.accent : AymaColors.fgDim,
          ),
        ),
      );
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
          width: 34,
          height: 34,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.02),
            shape: BoxShape.circle,
          ),
          child: const Icon(
            Icons.attach_file_rounded,
            size: 17,
            color: AymaColors.fgMute,
          ),
        ),
      );
}

// Waveform drawn behind text field when Ayma is speaking
class _WaveformBg extends StatefulWidget {
  final double volume;
  final Animation<double> glow;
  final bool active;

  const _WaveformBg({
    required this.volume,
    required this.glow,
    required this.active,
  });

  @override
  State<_WaveformBg> createState() => _WaveformBgState();
}

class _WaveformBgState extends State<_WaveformBg>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl =
        AnimationController(vsync: this, duration: const Duration(seconds: 2))
          ..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _ctrl,
        builder: (_, __) => CustomPaint(
          painter: _WavePainter(
            phase: _ctrl.value,
            volume: widget.volume,
            active: widget.active,
          ),
          size: Size.infinite,
        ),
      );
}

class _WavePainter extends CustomPainter {
  final double phase;
  final double volume;
  final bool active;

  const _WavePainter({
    required this.phase,
    required this.volume,
    required this.active,
  });

  @override
  void paint(Canvas canvas, Size size) {
    const outerInset = 14.0;
    final waveWidth = size.width * 0.56;
    final waveStart = (size.width - waveWidth) / 2;
    final waveEnd = waveStart + waveWidth;
    const baselineY = 1.1;
    final linePaint = Paint()
      ..color = AymaColors.accent.withValues(alpha: active ? 0.42 : 0.16)
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    if (!active) {
      canvas.drawLine(
        const Offset(outerInset, baselineY),
        Offset(size.width - outerInset, baselineY),
        linePaint,
      );
      return;
    }

    canvas.drawLine(
      const Offset(outerInset, baselineY),
      Offset(waveStart, baselineY),
      linePaint,
    );
    canvas.drawLine(
      Offset(waveEnd, baselineY),
      Offset(size.width - outerInset, baselineY),
      linePaint,
    );

    final amp = (14.0 + volume * 18.0).clamp(12.0, 28.0);
    final specs = [
      (freq: 1.8, amp: amp, phase: 0.0, opacity: 0.95, stroke: 1.9),
      (freq: 2.8, amp: amp * 0.45, phase: 0.22, opacity: 0.14, stroke: 0.75),
    ];

    for (final s in specs) {
      final paint = Paint()
        ..color = AymaColors.accent.withValues(alpha: s.opacity)
        ..strokeWidth = s.stroke
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round;

      final path = Path();
      final fullPhase = (phase + s.phase) * math.pi * 2;
      for (double x = waveStart; x <= waveEnd; x += 2) {
        final normalized = (x - waveStart) / (waveEnd - waveStart);
        final t = normalized * math.pi * 2 * s.freq;
        final centerBias = 1 - (normalized - 0.5).abs() * 2;
        final envelope =
            0.005 + math.pow(centerBias.clamp(0.0, 1.0), 3.2) * 1.08;
        final y = baselineY - math.sin(t + fullPhase) * s.amp * envelope;
        if (x == waveStart) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
      }
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(_WavePainter old) =>
      old.phase != phase || old.volume != volume || old.active != active;
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
