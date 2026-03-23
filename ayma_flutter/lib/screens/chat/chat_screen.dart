import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/providers.dart';
import '../../services/audio_service.dart';
import '../../theme.dart';
import '../../widgets/voice_orb.dart';
import '../../env.dart';

class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key});

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final _textCtrl     = TextEditingController();
  final _scrollCtrl   = ScrollController();
  bool _showTranscript = true;
  late final AymaAudioService _audioService;

  @override
  void initState() {
    super.initState();
    _audioService = ref.read(audioServiceProvider);
    WidgetsBinding.instance.addPostFrameCallback((_) => _autoConnect());
  }

  Future<void> _autoConnect() async {
    final audio = _audioService;
    if (audio.state != SessionState.disconnected) return;
    final user = ref.read(currentUserProvider);
    if (user == null) return;
    await audio.connect(Env.wsUrl);
  }

  @override
  void dispose() {
    _audioService.disconnect(notify: false);
    _textCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
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

  @override
  Widget build(BuildContext context) {
    final audio     = ref.watch(audioServiceProvider);
    final state     = audio.state;
    final transcript = audio.transcript;

    // Auto scroll on new messages
    if (transcript.isNotEmpty) _scrollToBottom();

    return Scaffold(
      backgroundColor: AymaColors.bg,
      body: SafeArea(
        child: Column(
          children: [
            // Top bar
            _TopBar(
              state: state,
              muted: audio.muted,
              speakerMuted: audio.speakerMuted,
              showTranscript: _showTranscript,
              onMute: audio.toggleMute,
              onSpeaker: audio.toggleSpeaker,
              onToggleTranscript: () => setState(() => _showTranscript = !_showTranscript),
              onDisconnect: () {
                audio.disconnect();
              },
              onConnect: _autoConnect,
            ),

            // Orb area
            Expanded(
              flex: 3,
              child: Center(
                child: VoiceOrb(
                  state: state,
                  inputVolume: audio.inputVolume,
                  outputVolume: audio.outputVolume,
                  onTap: () {
                    if (state == SessionState.disconnected) {
                      _autoConnect();
                    }
                  },
                ),
              ),
            ),

            // Transcript
            if (_showTranscript && transcript.isNotEmpty)
              Expanded(
                flex: 2,
                child: _TranscriptPanel(
                  transcript: transcript,
                  scrollCtrl: _scrollCtrl,
                ),
              ),

            // Text input
            _TextInputBar(
              ctrl: _textCtrl,
              enabled: state != SessionState.disconnected &&
                       state != SessionState.connecting,
              onSend: (text) {
                audio.sendText(text);
                _textCtrl.clear();
              },
            ),
          ],
        ),
      ),
    );
  }
}

// ── Sub-widgets ───────────────────────────────────────────────────────────────

class _TopBar extends StatelessWidget {
  final SessionState state;
  final bool muted, speakerMuted, showTranscript;
  final VoidCallback onMute, onSpeaker, onToggleTranscript, onDisconnect, onConnect;
  const _TopBar({
    required this.state, required this.muted, required this.speakerMuted,
    required this.showTranscript, required this.onMute, required this.onSpeaker,
    required this.onToggleTranscript, required this.onDisconnect, required this.onConnect,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          // Status chip
          _StatusChip(state: state),
          const Spacer(),
          // Controls
          _IconBtn(
            icon: showTranscript ? Icons.chat_bubble_rounded : Icons.chat_bubble_outline_rounded,
            active: showTranscript,
            onTap: onToggleTranscript,
            tooltip: 'Transcript',
          ),
          const SizedBox(width: 4),
          _IconBtn(
            icon: speakerMuted ? Icons.volume_off_rounded : Icons.volume_up_rounded,
            active: !speakerMuted,
            onTap: onSpeaker,
            tooltip: speakerMuted ? 'Unmute speaker' : 'Mute speaker',
          ),
          const SizedBox(width: 4),
          _IconBtn(
            icon: muted ? Icons.mic_off_rounded : Icons.mic_rounded,
            active: !muted,
            onTap: onMute,
            tooltip: muted ? 'Unmute mic' : 'Mute mic',
          ),
          const SizedBox(width: 4),
          if (state == SessionState.disconnected)
            _IconBtn(
              icon: Icons.power_settings_new_rounded,
              active: false,
              onTap: onConnect,
              tooltip: 'Connect',
              color: AymaColors.accent,
            )
          else
            _IconBtn(
              icon: Icons.close_rounded,
              active: false,
              onTap: onDisconnect,
              tooltip: 'Disconnect',
            ),
        ],
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  final SessionState state;
  const _StatusChip({required this.state});

  String get _label {
    switch (state) {
      case SessionState.disconnected: return 'Offline';
      case SessionState.connecting:   return 'Connecting...';
      case SessionState.ready:        return 'Ready';
      case SessionState.listening:    return 'Listening';
      case SessionState.thinking:     return 'Thinking';
      case SessionState.speaking:     return 'Speaking';
    }
  }

  Color get _color {
    switch (state) {
      case SessionState.disconnected: return AymaColors.textTertiary;
      case SessionState.connecting:   return Colors.orange.shade300;
      case SessionState.ready:
      case SessionState.listening:    return Colors.green.shade300;
      case SessionState.thinking:     return Colors.blue.shade300;
      case SessionState.speaking:     return AymaColors.accent;
    }
  }

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 6, height: 6,
        decoration: BoxDecoration(shape: BoxShape.circle, color: _color),
      ),
      const SizedBox(width: 6),
      Text(_label, style: TextStyle(color: _color, fontSize: 12, fontWeight: FontWeight.w500)),
    ],
  );
}

class _IconBtn extends StatelessWidget {
  final IconData icon;
  final bool active;
  final VoidCallback onTap;
  final String tooltip;
  final Color? color;
  const _IconBtn({required this.icon, required this.active, required this.onTap,
      required this.tooltip, this.color});

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: GestureDetector(
      onTap: onTap,
      child: Container(
        width: 36, height: 36,
        decoration: BoxDecoration(
          color: active
              ? (color ?? AymaColors.accent).withValues(alpha: 0.12)
              : AymaColors.surface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AymaColors.border),
        ),
        child: Icon(icon,
            size: 18,
            color: active
                ? (color ?? AymaColors.accent)
                : AymaColors.textTertiary),
      ),
    ),
  );
}

class _TranscriptPanel extends StatelessWidget {
  final List<TranscriptLine> transcript;
  final ScrollController scrollCtrl;
  const _TranscriptPanel({required this.transcript, required this.scrollCtrl});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: AymaColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AymaColors.border),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: ListView.builder(
          controller: scrollCtrl,
          padding: const EdgeInsets.all(12),
          itemCount: transcript.length,
          itemBuilder: (_, i) {
            final line = transcript[i];
            return _TranscriptBubble(line: line);
          },
        ),
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
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        mainAxisAlignment: isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!isUser) ...[
            Container(
              width: 20, height: 20,
              decoration: BoxDecoration(
                color: AymaColors.accent.withValues(alpha: 0.15),
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.auto_awesome, size: 11, color: AymaColors.accent),
            ),
            const SizedBox(width: 6),
          ],
          Flexible(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: isUser
                    ? AymaColors.accent.withValues(alpha: 0.15)
                    : AymaColors.card,
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(12),
                  topRight: const Radius.circular(12),
                  bottomLeft: Radius.circular(isUser ? 12 : 2),
                  bottomRight: Radius.circular(isUser ? 2 : 12),
                ),
                border: isUser
                    ? Border.all(color: AymaColors.accent.withValues(alpha: 0.2))
                    : null,
              ),
              child: Text(
                line.text,
                style: TextStyle(
                  color: isUser ? AymaColors.accent : AymaColors.textPrimary,
                  fontSize: 13,
                  height: 1.5,
                ),
              ),
            ),
          ),
          if (isUser) const SizedBox(width: 6),
        ],
      ),
    ).animate().fadeIn(duration: 300.ms).slideY(begin: 0.1, end: 0);
  }
}

class _TextInputBar extends StatelessWidget {
  final TextEditingController ctrl;
  final bool enabled;
  final ValueChanged<String> onSend;
  const _TextInputBar({required this.ctrl, required this.enabled, required this.onSend});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: ctrl,
              enabled: enabled,
              style: TextStyle(color: AymaColors.textPrimary, fontSize: 14),
              cursorColor: AymaColors.accent,
              onSubmitted: (v) { if (v.trim().isNotEmpty) onSend(v.trim()); },
              decoration: InputDecoration(
                hintText: enabled ? 'Type a message...' : 'Not connected',
                hintStyle: TextStyle(color: AymaColors.textTertiary, fontSize: 14),
                filled: true,
                fillColor: AymaColors.surface,
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide: BorderSide(color: AymaColors.border)),
                enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide: BorderSide(color: AymaColors.border)),
                focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide: BorderSide(color: AymaColors.accent, width: 1.5)),
                disabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide: BorderSide(color: AymaColors.border.withValues(alpha: 0.4))),
              ),
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: enabled
                ? () {
                    final text = ctrl.text.trim();
                    if (text.isNotEmpty) { onSend(text); ctrl.clear(); }
                  }
                : null,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: 44, height: 44,
              decoration: BoxDecoration(
                color: enabled ? AymaColors.accent : AymaColors.surface,
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.arrow_upward_rounded,
                  size: 20,
                  color: enabled ? Colors.white : AymaColors.textTertiary),
            ),
          ),
        ],
      ),
    );
  }
}
