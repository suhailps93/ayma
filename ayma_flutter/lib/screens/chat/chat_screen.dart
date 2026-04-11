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
import '../../widgets/voice_orb.dart';

enum _SurfaceMode { text, voice, camera, screen }

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

  _DraftAttachment copyWith({
    String? status,
    String? remoteUrl,
  }) {
    return _DraftAttachment(
      id: id,
      kind: kind,
      filename: filename,
      previewBytes: previewBytes,
      status: status ?? this.status,
      remoteUrl: remoteUrl ?? this.remoteUrl,
    );
  }
}

class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key});

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final _textCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  final _inputFocusNode = FocusNode();
  final _picker = ImagePicker();
  late final AymaAudioService _audioService;

  _SurfaceMode _mode = _SurfaceMode.voice;
  bool _showTranscript = true;
  bool _screenShareActive = false;
  bool _uploadingMedia = false;
  int _lastTranscriptCount = 0;
  final List<_DraftAttachment> _drafts = [];

  @override
  void initState() {
    super.initState();
    _audioService = ref.read(audioServiceProvider);
    WidgetsBinding.instance.addPostFrameCallback((_) => _autoConnect());
  }

  Future<void> _autoConnect() async {
    if (_audioService.state != SessionState.disconnected) return;
    final user = ref.read(currentUserProvider);
    if (user == null) return;
    try {
      await _audioService.connect(Env.wsUrl);
    } catch (_) {}
  }

  Future<void> _toggleVoice() async {
    if (_audioService.state == SessionState.disconnected) {
      setState(() => _mode = _SurfaceMode.voice);
      await _autoConnect();
      return;
    }
    _audioService.disconnect();
  }

  Future<void> _sendCurrentText() async {
    final text = _textCtrl.text.trim();
    final readyDrafts = _drafts.where((d) => d.remoteUrl != null).toList();
    if (text.isEmpty && readyDrafts.isEmpty) return;

    final message = text.isEmpty ? 'Please analyze what I just shared.' : text;
    final attachments = [
      for (final draft in readyDrafts)
        {
          'url': draft.remoteUrl!,
          'kind': draft.kind == _DraftKind.image ? 'image' : 'video',
          'filename': draft.filename,
        },
    ];
    _textCtrl.clear();
    setState(() {});
    await _audioService.sendText(message, attachments: attachments);
    if (mounted && readyDrafts.isNotEmpty) {
      setState(() {
        _drafts.removeWhere((d) => d.remoteUrl != null);
      });
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(
          _scrollCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _showMediaSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => _MediaSheet(
        onPhotoCamera: () => _pickImage(ImageSource.camera),
        onPhotoGallery: () => _pickImage(ImageSource.gallery),
        onVideoCamera: () => _pickVideo(ImageSource.camera),
        onVideoGallery: () => _pickVideo(ImageSource.gallery),
      ),
    );
  }

  Future<void> _pickImage(ImageSource source) async {
    Navigator.of(context).maybePop();
    final picked = await _picker.pickImage(
      source: source,
      imageQuality: 90,
      maxWidth: 1800,
    );
    if (picked == null) return;
    final bytes = await picked.readAsBytes();
    final draft = _DraftAttachment(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      kind: _DraftKind.image,
      filename: picked.name,
      previewBytes: bytes,
      status: 'Processing photo...',
    );
    setState(() {
      _mode = _SurfaceMode.camera;
      _drafts.insert(0, draft);
      _uploadingMedia = true;
    });
    await _uploadDraft(draft, bytes);
  }

  Future<void> _pickVideo(ImageSource source) async {
    Navigator.of(context).maybePop();
    final picked = await _picker.pickVideo(source: source, maxDuration: const Duration(minutes: 3));
    if (picked == null) return;
    final bytes = await picked.readAsBytes();
    final draft = _DraftAttachment(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      kind: _DraftKind.video,
      filename: picked.name,
      status: 'Uploading video...',
    );
    setState(() {
      _mode = _SurfaceMode.camera;
      _drafts.insert(0, draft);
      _uploadingMedia = true;
    });
    await _uploadDraft(draft, bytes);
  }

  Future<void> _uploadDraft(_DraftAttachment draft, Uint8List bytes) async {
    try {
      final response = await BackendService.uploadFileBytes(
        '/api/media/upload',
        bytes,
        filename: draft.filename,
      ) as Map<String, dynamic>;
      final url = response['photo_url'] as String?;
      final status = (response['media_type'] as String?) == 'video'
          ? 'Video attached'
          : 'Photo analyzed for Ayma';
      final index = _drafts.indexWhere((d) => d.id == draft.id);
      if (index != -1) {
        setState(() {
          _drafts[index] = _drafts[index].copyWith(status: status, remoteUrl: url);
        });
      }
      if (draft.kind == _DraftKind.image) {
        ref.invalidate(insightsProvider);
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(status)),
        );
      }
    } catch (e) {
      final index = _drafts.indexWhere((d) => d.id == draft.id);
      if (index != -1) {
        setState(() {
          _drafts[index] = _drafts[index].copyWith(status: 'Upload failed');
        });
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Media upload failed: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _uploadingMedia = false);
      }
    }
  }

  void _removeDraft(String id) {
    setState(() {
      _drafts.removeWhere((d) => d.id == id);
    });
  }

  void _toggleScreenShare() {
    setState(() {
      _mode = _SurfaceMode.screen;
      _screenShareActive = !_screenShareActive;
    });
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _screenShareActive
                ? 'Screen-share mode enabled in chat UI'
                : 'Screen-share mode ended',
          ),
        ),
      );
    }
  }

  @override
  void dispose() {
    _textCtrl.dispose();
    _scrollCtrl.dispose();
    _inputFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(audioServiceProvider.select((audio) => audio.state));
    final transcriptCount =
        ref.watch(audioServiceProvider.select((audio) => audio.transcript.length));
    final muted = ref.watch(audioServiceProvider.select((audio) => audio.muted));
    final speakerMuted =
        ref.watch(audioServiceProvider.select((audio) => audio.speakerMuted));
    final transcript = _audioService.transcript;
    final inputVolume =
        ref.watch(audioServiceProvider.select((audio) => audio.inputVolume));
    final outputVolume =
        ref.watch(audioServiceProvider.select((audio) => audio.outputVolume));
    final isWide = MediaQuery.sizeOf(context).width >= 960;

    if (transcriptCount != _lastTranscriptCount) {
      _lastTranscriptCount = transcriptCount;
      if (transcriptCount > 0) _scrollToBottom();
    }

    return Scaffold(
      backgroundColor: AymaColors.bg,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
          child: Column(
            children: [
              _ChatHeader(
                mode: _mode,
                state: state,
                showTranscript: _showTranscript,
                onToggleTranscript: () => setState(() => _showTranscript = !_showTranscript),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: isWide
                    ? Row(
                        children: [
                          Expanded(
                            flex: 8,
                            child: _LiveStage(
                              mode: _mode,
                              state: state,
                              muted: muted,
                              speakerMuted: speakerMuted,
                              screenShareActive: _screenShareActive,
                              inputVolume: inputVolume,
                              outputVolume: outputVolume,
                              drafts: _drafts,
                              uploadingMedia: _uploadingMedia,
                              onMute: _audioService.toggleMute,
                              onSpeaker: _audioService.toggleSpeaker,
                              onReconnect: _toggleVoice,
                            ),
                          ),
                          if (_showTranscript) ...[
                            const SizedBox(width: 12),
                            Expanded(
                              flex: 5,
                              child: _TranscriptSurface(
                                transcript: transcript,
                                scrollCtrl: _scrollCtrl,
                              ),
                            ),
                          ],
                        ],
                      )
                    : Column(
                        children: [
                          Expanded(
                            flex: _showTranscript ? 5 : 1,
                            child: _LiveStage(
                              mode: _mode,
                              state: state,
                              muted: muted,
                              speakerMuted: speakerMuted,
                              screenShareActive: _screenShareActive,
                              inputVolume: inputVolume,
                              outputVolume: outputVolume,
                              drafts: _drafts,
                              uploadingMedia: _uploadingMedia,
                              onMute: _audioService.toggleMute,
                              onSpeaker: _audioService.toggleSpeaker,
                              onReconnect: _toggleVoice,
                            ),
                          ),
                          if (_showTranscript) ...[
                            const SizedBox(height: 12),
                            Expanded(
                              flex: 4,
                              child: _TranscriptSurface(
                                transcript: transcript,
                                scrollCtrl: _scrollCtrl,
                              ),
                            ),
                          ],
                        ],
                      ),
              ),
              const SizedBox(height: 12),
              _ComposerDock(
                ctrl: _textCtrl,
                focusNode: _inputFocusNode,
                state: state,
                drafts: _drafts,
                mode: _mode,
                screenShareActive: _screenShareActive,
                onTextChanged: () => setState(() => _mode = _SurfaceMode.text),
                onSend: _sendCurrentText,
                onRemoveDraft: _removeDraft,
                onOpenMedia: _showMediaSheet,
                onToggleVoice: _toggleVoice,
                onToggleScreen: _toggleScreenShare,
                onEnterText: () {
                  setState(() => _mode = _SurfaceMode.text);
                  _inputFocusNode.requestFocus();
                },
                onEnterCamera: () async {
                  setState(() => _mode = _SurfaceMode.camera);
                  await _showMediaSheet();
                },
                onToggleTranscript: () => setState(() => _showTranscript = !_showTranscript),
                showTranscript: _showTranscript,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ChatHeader extends StatelessWidget {
  final _SurfaceMode mode;
  final SessionState state;
  final bool showTranscript;
  final VoidCallback onToggleTranscript;

  const _ChatHeader({
    required this.mode,
    required this.state,
    required this.showTranscript,
    required this.onToggleTranscript,
  });

  String get _modeLabel {
    switch (mode) {
      case _SurfaceMode.text:
        return 'Text';
      case _SurfaceMode.voice:
        return 'Live';
      case _SurfaceMode.camera:
        return 'Camera';
      case _SurfaceMode.screen:
        return 'Screen';
    }
  }

  String get _stateLabel {
    switch (state) {
      case SessionState.disconnected:
        return 'offline';
      case SessionState.connecting:
        return 'connecting';
      case SessionState.ready:
        return 'ready';
      case SessionState.listening:
        return 'listening';
      case SessionState.thinking:
        return 'thinking';
      case SessionState.speaking:
        return 'speaking';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: AymaColors.surface,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: AymaColors.border, width: 0.5),
            ),
            child: Row(
              children: [
                Container(
                  width: 26,
                  height: 26,
                  decoration: const BoxDecoration(
                    gradient: AymaColors.orbGradient,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.auto_awesome, color: Colors.black, size: 14),
                ),
                const SizedBox(width: 10),
                Text(
                  'Ayma',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: AymaColors.textPrimary,
                        fontWeight: FontWeight.w600,
                      ),
                ),
                const SizedBox(width: 8),
                Text(
                  '$_modeLabel • $_stateLabel',
                  style: const TextStyle(
                    color: AymaColors.textSecondary,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 10),
        _HeaderAction(
          icon: showTranscript ? Icons.chat_rounded : Icons.chat_bubble_outline_rounded,
          active: showTranscript,
          onTap: onToggleTranscript,
        ),
      ],
    ).animate().fadeIn(duration: 300.ms).slideY(begin: -0.05, end: 0);
  }
}

class _HeaderAction extends StatelessWidget {
  final IconData icon;
  final bool active;
  final VoidCallback onTap;

  const _HeaderAction({
    required this.icon,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(
          color: active ? AymaColors.gold.withValues(alpha: 0.12) : AymaColors.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: active ? AymaColors.gold.withValues(alpha: 0.28) : AymaColors.border,
            width: 0.5,
          ),
        ),
        child: Icon(icon, color: active ? AymaColors.gold : AymaColors.textSecondary),
      ),
    );
  }
}

class _LiveStage extends StatelessWidget {
  final _SurfaceMode mode;
  final SessionState state;
  final bool muted;
  final bool speakerMuted;
  final bool screenShareActive;
  final double inputVolume;
  final double outputVolume;
  final bool uploadingMedia;
  final List<_DraftAttachment> drafts;
  final VoidCallback onMute;
  final VoidCallback onSpeaker;
  final VoidCallback onReconnect;

  const _LiveStage({
    required this.mode,
    required this.state,
    required this.muted,
    required this.speakerMuted,
    required this.screenShareActive,
    required this.inputVolume,
    required this.outputVolume,
    required this.uploadingMedia,
    required this.drafts,
    required this.onMute,
    required this.onSpeaker,
    required this.onReconnect,
  });

  @override
  Widget build(BuildContext context) {
    return HudPanel(
      glowing: state == SessionState.listening || state == SessionState.speaking,
      padding: const EdgeInsets.all(18),
      child: Stack(
        children: [
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    AymaColors.gold.withValues(alpha: 0.07),
                    Colors.transparent,
                    AymaColors.goldGlow.withValues(alpha: 0.6),
                  ],
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                ),
              ),
            ),
          ),
          Positioned(
            top: 0,
            right: 0,
            child: Row(
              children: [
                _StageChip(
                  label: muted ? 'Mic muted' : 'Mic open',
                  active: !muted,
                  icon: muted ? Icons.mic_off_rounded : Icons.mic_rounded,
                  onTap: onMute,
                ),
                const SizedBox(width: 8),
                _StageChip(
                  label: speakerMuted ? 'Speaker muted' : 'Speaker on',
                  active: !speakerMuted,
                  icon: speakerMuted ? Icons.volume_off_rounded : Icons.volume_up_rounded,
                  onTap: onSpeaker,
                ),
              ],
            ),
          ),
          Center(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 260),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              child: switch (mode) {
                _SurfaceMode.voice => _VoiceStage(
                    key: const ValueKey('voice'),
                    state: state,
                    inputVolume: inputVolume,
                    outputVolume: outputVolume,
                    onReconnect: onReconnect,
                  ),
                _SurfaceMode.camera => _CameraStage(
                    key: const ValueKey('camera'),
                    drafts: drafts,
                    uploadingMedia: uploadingMedia,
                  ),
                _SurfaceMode.screen => _ScreenStage(
                    key: const ValueKey('screen'),
                    active: screenShareActive,
                  ),
                _SurfaceMode.text => _TextStage(
                    key: const ValueKey('text'),
                    state: state,
                  ),
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _StageChip extends StatelessWidget {
  final String label;
  final bool active;
  final IconData icon;
  final VoidCallback onTap;

  const _StageChip({
    required this.label,
    required this.active,
    required this.icon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: AymaColors.surface.withValues(alpha: 0.84),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: active ? AymaColors.gold.withValues(alpha: 0.28) : AymaColors.border,
            width: 0.5,
          ),
        ),
        child: Row(
          children: [
            Icon(icon, size: 14, color: active ? AymaColors.gold : AymaColors.textTertiary),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                color: active ? AymaColors.textPrimary : AymaColors.textSecondary,
                fontSize: 11,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _VoiceStage extends StatelessWidget {
  final SessionState state;
  final double inputVolume;
  final double outputVolume;
  final VoidCallback onReconnect;

  const _VoiceStage({
    super.key,
    required this.state,
    required this.inputVolume,
    required this.outputVolume,
    required this.onReconnect,
  });

  String get _title {
    switch (state) {
      case SessionState.disconnected:
        return 'Tap to reconnect live';
      case SessionState.connecting:
        return 'Connecting Ayma Live';
      case SessionState.ready:
        return 'Ayma is ready';
      case SessionState.listening:
        return 'Ayma is listening';
      case SessionState.thinking:
        return 'Ayma is thinking';
      case SessionState.speaking:
        return 'Ayma is speaking';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        VoiceOrb(
          size: 170,
          state: state,
          inputVolume: inputVolume,
          outputVolume: outputVolume,
          onTap: onReconnect,
        ),
        const SizedBox(height: 18),
        Text(
          _title,
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
                color: AymaColors.textPrimary,
              ),
        ),
        const SizedBox(height: 8),
        const SizedBox(
          width: 320,
          child: Text(
            'One surface for live voice, text fallback, photo and video sharing, and screen-share style coaching.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AymaColors.textSecondary,
              fontSize: 13,
              height: 1.5,
            ),
          ),
        ),
      ],
    );
  }
}

class _TextStage extends StatelessWidget {
  final SessionState state;
  const _TextStage({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 420),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.keyboard_alt_rounded,
            size: 40,
            color: AymaColors.gold.withValues(alpha: 0.85),
          ),
          const SizedBox(height: 14),
          Text(
            'Type naturally',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  color: AymaColors.textPrimary,
                ),
          ),
          const SizedBox(height: 8),
          Text(
            state == SessionState.disconnected
                ? 'Text keeps working even when live voice is offline.'
                : 'Text and live voice share the same conversation surface.',
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: AymaColors.textSecondary,
              fontSize: 13,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}

class _CameraStage extends StatelessWidget {
  final List<_DraftAttachment> drafts;
  final bool uploadingMedia;

  const _CameraStage({
    super.key,
    required this.drafts,
    required this.uploadingMedia,
  });

  @override
  Widget build(BuildContext context) {
    final primary = drafts.isNotEmpty ? drafts.first : null;
    if (primary == null) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: const [
          Icon(Icons.videocam_rounded, size: 40, color: AymaColors.gold),
          SizedBox(height: 14),
          Text(
            'Capture or share media',
            style: TextStyle(color: AymaColors.textPrimary, fontSize: 22),
          ),
          SizedBox(height: 8),
          Text(
            'Open the dock to add photos or short videos to the conversation.',
            textAlign: TextAlign.center,
            style: TextStyle(color: AymaColors.textSecondary, fontSize: 13, height: 1.5),
          ),
        ],
      );
    }

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 420),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: Container(
              width: double.infinity,
              height: 240,
              decoration: BoxDecoration(
                color: AymaColors.surface,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: AymaColors.border, width: 0.5),
              ),
              child: primary.kind == _DraftKind.image && primary.previewBytes != null
                  ? Image.memory(primary.previewBytes!, fit: BoxFit.cover)
                  : Stack(
                      children: [
                        Positioned.fill(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                colors: [
                                  AymaColors.gold.withValues(alpha: 0.18),
                                  AymaColors.surface,
                                ],
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                              ),
                            ),
                          ),
                        ),
                        const Center(
                          child: Icon(
                            Icons.play_circle_fill_rounded,
                            size: 56,
                            color: AymaColors.gold,
                          ),
                        ),
                      ],
                    ),
            ),
          ),
          const SizedBox(height: 14),
          Text(
            primary.filename,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: AymaColors.textPrimary,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            uploadingMedia ? 'Uploading...' : primary.status,
            style: const TextStyle(color: AymaColors.textSecondary, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

class _ScreenStage extends StatelessWidget {
  final bool active;
  const _ScreenStage({super.key, required this.active});

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 460),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AymaColors.surface,
              borderRadius: BorderRadius.circular(22),
              border: Border.all(
                color: active ? AymaColors.gold.withValues(alpha: 0.4) : AymaColors.border,
                width: 0.5,
              ),
            ),
            child: Column(
              children: [
                Row(
                  children: [
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: active ? AymaColors.success : AymaColors.textTertiary,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      active ? 'Screen-share mode active' : 'Screen-share mode ready',
                      style: const TextStyle(
                        color: AymaColors.textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Container(
                  height: 180,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: AymaColors.border, width: 0.5),
                    gradient: LinearGradient(
                      colors: [
                        AymaColors.gold.withValues(alpha: 0.12),
                        AymaColors.surface,
                        AymaColors.surface,
                      ],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                  ),
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: List.generate(
                              5,
                              (i) => Padding(
                                padding: EdgeInsets.only(bottom: i == 4 ? 0 : 12),
                                child: Container(
                                  height: i.isEven ? 20 : 14,
                                  width: double.infinity - (i * 34),
                                  decoration: BoxDecoration(
                                    color: AymaColors.gold.withValues(alpha: i.isEven ? 0.15 : 0.08),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const Center(
                        child: Icon(Icons.present_to_all_rounded, size: 42, color: AymaColors.gold),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Text(
            active
                ? 'Ayma can stay beside the conversation while you guide the interaction.'
                : 'Use this mode when you want a shared, guided session feel.',
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: AymaColors.textSecondary,
              fontSize: 13,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}

class _TranscriptSurface extends StatelessWidget {
  final List<TranscriptLine> transcript;
  final ScrollController scrollCtrl;

  const _TranscriptSurface({
    required this.transcript,
    required this.scrollCtrl,
  });

  @override
  Widget build(BuildContext context) {
    return HudPanel(
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
            child: Row(
              children: const [
                Icon(Icons.chat_bubble_outline_rounded, size: 16, color: AymaColors.gold),
                SizedBox(width: 8),
                Text(
                  'Conversation',
                  style: TextStyle(
                    color: AymaColors.textPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          Container(height: 0.5, color: AymaColors.border),
          Expanded(
            child: transcript.isEmpty
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        'Your live transcript and text replies appear here.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: AymaColors.textTertiary,
                          fontSize: 13,
                          height: 1.5,
                        ),
                      ),
                    ),
                  )
                : ListView.builder(
                    controller: scrollCtrl,
                    padding: const EdgeInsets.all(14),
                    itemCount: transcript.length,
                    itemBuilder: (_, i) => _TranscriptBubble(line: transcript[i]),
                  ),
          ),
        ],
      ),
    );
  }
}

class _TranscriptBubble extends StatelessWidget {
  final TranscriptLine line;
  const _TranscriptBubble({required this.line});

  @override
  Widget build(BuildContext context) {
    final isUser = line.isUser;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        mainAxisAlignment: isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        children: [
          Flexible(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: isUser
                    ? AymaColors.gold.withValues(alpha: 0.1)
                    : AymaColors.surface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: isUser
                      ? AymaColors.gold.withValues(alpha: 0.25)
                      : AymaColors.border,
                  width: 0.5,
                ),
              ),
              child: Text(
                line.text,
                style: TextStyle(
                  color: isUser ? AymaColors.goldBright : AymaColors.textPrimary,
                  fontSize: 13,
                  height: 1.5,
                ),
              ),
            ),
          ),
        ],
      ),
    ).animate().fadeIn(duration: 220.ms).slideY(begin: 0.06, end: 0);
  }
}

class _ComposerDock extends StatelessWidget {
  final TextEditingController ctrl;
  final FocusNode focusNode;
  final SessionState state;
  final List<_DraftAttachment> drafts;
  final _SurfaceMode mode;
  final bool screenShareActive;
  final bool showTranscript;
  final VoidCallback onTextChanged;
  final Future<void> Function() onSend;
  final void Function(String id) onRemoveDraft;
  final Future<void> Function() onOpenMedia;
  final Future<void> Function() onToggleVoice;
  final VoidCallback onToggleScreen;
  final VoidCallback onEnterText;
  final Future<void> Function() onEnterCamera;
  final VoidCallback onToggleTranscript;

  const _ComposerDock({
    required this.ctrl,
    required this.focusNode,
    required this.state,
    required this.drafts,
    required this.mode,
    required this.screenShareActive,
    required this.showTranscript,
    required this.onTextChanged,
    required this.onSend,
    required this.onRemoveDraft,
    required this.onOpenMedia,
    required this.onToggleVoice,
    required this.onToggleScreen,
    required this.onEnterText,
    required this.onEnterCamera,
    required this.onToggleTranscript,
  });

  @override
  Widget build(BuildContext context) {
    final hasText = ctrl.text.trim().isNotEmpty;
    final hasReadyDrafts = drafts.any((d) => d.remoteUrl != null);
    final busy = state == SessionState.connecting || state == SessionState.thinking;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (drafts.isNotEmpty) ...[
          _DraftStrip(drafts: drafts, onRemove: onRemoveDraft),
          const SizedBox(height: 10),
        ],
        if (mode == _SurfaceMode.text || hasText)
          Container(
            padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
            decoration: BoxDecoration(
              color: AymaColors.surface,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: AymaColors.border, width: 0.5),
            ),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: ctrl,
                    focusNode: focusNode,
                    enabled: !busy,
                    style: const TextStyle(color: AymaColors.textPrimary, fontSize: 14),
                    cursorColor: AymaColors.gold,
                    minLines: 1,
                    maxLines: 5,
                    onChanged: (_) => onTextChanged(),
                    onSubmitted: (_) {
                      if (!busy && ctrl.text.trim().isNotEmpty) onSend();
                    },
                    decoration: const InputDecoration(
                      isCollapsed: true,
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      disabledBorder: InputBorder.none,
                      hintText: 'Message Ayma',
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                GestureDetector(
                  onTap: !busy && (hasText || hasReadyDrafts) ? onSend : null,
                  child: Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: !busy && (hasText || hasReadyDrafts)
                          ? AymaColors.gold
                          : AymaColors.card,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.arrow_upward_rounded,
                      color: !busy && (hasText || hasReadyDrafts)
                          ? Colors.black
                          : AymaColors.textTertiary,
                    ),
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: AymaColors.surface,
            borderRadius: BorderRadius.circular(28),
            border: Border.all(color: AymaColors.border, width: 0.5),
            boxShadow: const [
              BoxShadow(
                color: Color(0x33000000),
                blurRadius: 18,
                offset: Offset(0, 8),
              ),
            ],
          ),
          child: Row(
            children: [
              _DockButton(
                icon: Icons.camera_alt_rounded,
                active: mode == _SurfaceMode.camera,
                onTap: onEnterCamera,
              ),
              _DockButton(
                icon: Icons.add_photo_alternate_outlined,
                active: drafts.isNotEmpty,
                onTap: onOpenMedia,
              ),
              Expanded(
                child: _PrimaryDockButton(
                  state: state,
                  onTap: onToggleVoice,
                ),
              ),
              _DockButton(
                icon: Icons.keyboard_rounded,
                active: mode == _SurfaceMode.text || hasText,
                onTap: onEnterText,
              ),
              _DockButton(
                icon: Icons.present_to_all_rounded,
                active: screenShareActive,
                onTap: onToggleScreen,
              ),
              _DockButton(
                icon: showTranscript ? Icons.view_agenda_rounded : Icons.view_stream_outlined,
                active: showTranscript,
                onTap: onToggleTranscript,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _DraftStrip extends StatelessWidget {
  final List<_DraftAttachment> drafts;
  final void Function(String id) onRemove;

  const _DraftStrip({
    required this.drafts,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 88,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: drafts.length,
        separatorBuilder: (_, __) => const SizedBox(width: 10),
        itemBuilder: (context, i) {
          final draft = drafts[i];
          return Container(
            width: 182,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AymaColors.surface,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: AymaColors.border, width: 0.5),
            ),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Container(
                    width: 54,
                    height: 54,
                    color: AymaColors.card,
                    child: draft.kind == _DraftKind.image && draft.previewBytes != null
                        ? Image.memory(draft.previewBytes!, fit: BoxFit.cover)
                        : const Icon(Icons.videocam_rounded, color: AymaColors.gold),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        draft.filename,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AymaColors.textPrimary,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        draft.status,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AymaColors.textSecondary,
                          fontSize: 11,
                          height: 1.3,
                        ),
                      ),
                    ],
                  ),
                ),
                GestureDetector(
                  onTap: () => onRemove(draft.id),
                  child: const Icon(Icons.close_rounded, size: 16, color: AymaColors.textTertiary),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _DockButton extends StatelessWidget {
  final IconData icon;
  final bool active;
  final VoidCallback onTap;

  const _DockButton({
    required this.icon,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        width: 42,
        height: 42,
        decoration: BoxDecoration(
          color: active ? AymaColors.gold.withValues(alpha: 0.16) : Colors.transparent,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Icon(
          icon,
          color: active ? AymaColors.goldBright : AymaColors.textSecondary,
          size: 20,
        ),
      ),
    );
  }
}

class _PrimaryDockButton extends StatelessWidget {
  final SessionState state;
  final Future<void> Function() onTap;

  const _PrimaryDockButton({
    required this.state,
    required this.onTap,
  });

  String get _label {
    switch (state) {
      case SessionState.disconnected:
        return 'Start Live';
      case SessionState.connecting:
        return 'Connecting';
      case SessionState.ready:
        return 'Live Ready';
      case SessionState.listening:
        return 'Listening';
      case SessionState.thinking:
        return 'Thinking';
      case SessionState.speaking:
        return 'Speaking';
    }
  }

  @override
  Widget build(BuildContext context) {
    final active = state != SessionState.disconnected;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 48,
        margin: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(22),
          gradient: active
              ? const LinearGradient(
                  colors: [Color(0xFF17345C), Color(0xFF0A0F18), Color(0xFF132C53)],
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                )
              : LinearGradient(
                  colors: [
                    AymaColors.card,
                    AymaColors.surface,
                  ],
                ),
          border: Border.all(
            color: active ? AymaColors.gold.withValues(alpha: 0.35) : AymaColors.border,
            width: 0.6,
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              active ? Icons.graphic_eq_rounded : Icons.mic_none_rounded,
              color: active ? AymaColors.goldBright : AymaColors.textSecondary,
            ),
            const SizedBox(width: 8),
            Text(
              _label,
              style: TextStyle(
                color: active ? AymaColors.textPrimary : AymaColors.textSecondary,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

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
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.all(12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AymaColors.surface,
        borderRadius: BorderRadius.circular(26),
        border: Border.all(color: AymaColors.border, width: 0.5),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: AymaColors.textTertiary,
              borderRadius: BorderRadius.circular(4),
            ),
          ),
          const SizedBox(height: 14),
          const Text(
            'Share into the conversation',
            style: TextStyle(
              color: AymaColors.textPrimary,
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(child: _MediaTile(icon: Icons.photo_camera_back_rounded, title: 'Take Photo', onTap: onPhotoCamera)),
              const SizedBox(width: 10),
              Expanded(child: _MediaTile(icon: Icons.collections_rounded, title: 'Photo Library', onTap: onPhotoGallery)),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(child: _MediaTile(icon: Icons.videocam_rounded, title: 'Record Video', onTap: onVideoCamera)),
              const SizedBox(width: 10),
              Expanded(child: _MediaTile(icon: Icons.video_library_rounded, title: 'Video Library', onTap: onVideoGallery)),
            ],
          ),
        ],
      ),
    );
  }
}

class _MediaTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final Future<void> Function() onTap;

  const _MediaTile({
    required this.icon,
    required this.title,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
        decoration: BoxDecoration(
          color: AymaColors.card,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: AymaColors.border, width: 0.5),
        ),
        child: Column(
          children: [
            Icon(icon, size: 24, color: AymaColors.gold),
            const SizedBox(height: 10),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: AymaColors.textPrimary,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
