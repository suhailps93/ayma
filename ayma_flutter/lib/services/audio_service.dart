// Voice and text chat orchestration powered by LiveKit Cloud and LiveKit Agents.
import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:permission_handler/permission_handler.dart';
import 'package:livekit_client/livekit_client.dart';

import '../config/audio_config.dart';
import '../env.dart';
import 'backend_service.dart';

enum SessionState {
  disconnected,
  connecting,
  ready,
  listening,
  thinking,
  speaking,
}

enum TextChatFailure {
  none,
  noConnection,
  quotaExhausted,
  serverError,
}

class TranscriptLine {
  final String text;
  final bool isUser;
  final DateTime time;
  final List<Map<String, dynamic>>? attachments;

  TranscriptLine(
    this.text, {
    required this.isUser,
    DateTime? time,
    this.attachments,
  }) : time = time ?? DateTime.now();

  Map<String, dynamic> toMap() => {
        'text': text,
        'is_user': isUser,
        'time': time.toIso8601String(),
        if (attachments != null) 'attachments': attachments,
      };

  static TranscriptLine fromMap(Map<String, dynamic> map) {
    final parsedTime = DateTime.tryParse(map['time'] as String? ?? '');
    return TranscriptLine(
      (map['text'] as String? ?? '').trim(),
      isUser: (map['is_user'] as bool?) ?? false,
      time: parsedTime,
      attachments: (map['attachments'] as List?)?.cast<Map<String, dynamic>>(),
    );
  }
}

/// Orchestrates LiveKit Room connection, audio track publishing, remote participant
/// track subscription, and data channel messages for the Ayma app.
class AymaAudioService extends ChangeNotifier {
  Room? _room;
  EventsListener<RoomEvent>? _listener;
  Timer? _volumeTimer;
  final Set<String> _completedTextMessageIds = <String>{};

  SessionState _state = SessionState.disconnected;
  SessionState get state => _state;

  double _inputVolume = 0;
  double _outputVolume = 0;
  double _rawInputVolume = 0;
  double get inputVolume => _inputVolume;
  double get outputVolume => _outputVolume;
  double get rawInputVolume => _rawInputVolume;

  bool _userTalking = false;
  bool get userTalking => _userTalking;

  bool _muted = false;
  bool _speakerMuted = false;
  bool get muted => _muted;
  bool get speakerMuted => _speakerMuted;

  final List<TranscriptLine> _transcript = [];
  List<TranscriptLine> get transcript => List.unmodifiable(_transcript);

  final List<Map<String, String>> _history = [];

  TextChatFailure _textChatFailure = TextChatFailure.none;
  TextChatFailure get textChatFailure => _textChatFailure;

  final _speechToText = stt.SpeechToText();
  bool _sttAvailable = false;
  bool _wakeWordListening = false;
  bool get wakeWordListening => _wakeWordListening;

  Timer? _persistDebounce;

  String get _transcriptStorageKey {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? 'guest';
    return 'ayma.chat.transcript.$uid';
  }

  AymaAudioService() {
    unawaited(initForUser());
  }

  Future<void> initForUser() async {
    await _restoreTranscript();
  }

  // ── Connection Lifecycle ───────────────────────────────────────────────────

  /// Connects to a unified LiveKit room session using signed credentials from the bootstrap API.
  Future<void> connect({bool userInitiated = false}) async {
    if (_state != SessionState.disconnected) {
      await _disconnectTransport();
    }
    _setState(SessionState.connecting);

    // Enforce mic permission natively
    if (!kIsWeb) {
      final permission = await Permission.microphone.request();
      if (!permission.isGranted) {
        _setState(SessionState.disconnected);
        throw Exception('Microphone permission denied');
      }
    }

    try {
      // Call bootstrap endpoint to get ephemeral LiveKit room configuration
      final bootstrap = await _bootstrapForProvider();
      final wsUrl = bootstrap['websocket_url'] as String? ?? '';
      final token = bootstrap['token'] as String? ?? '';

      if (wsUrl.isEmpty || token.isEmpty) {
        throw Exception(
            'Missing LiveKit URL or AccessToken from bootstrap response.');
      }

      final r = Room();
      _room = r;

      // Connect natively to room
      await r.connect(wsUrl, token);

      // Enable microphone only for explicit voice sessions.
      await _setMicrophoneEnabled(!_muted);

      // Wire event listeners
      final l = r.createListener();
      _listener = l;

      l.on<DataReceivedEvent>((event) {
        final reply = utf8.decode(event.data);
        debugPrint(
          'DEBUG: Intercepted data track response'
          ' topic=${event.topic ?? ''}'
          ' from=${event.participant?.identity ?? 'unknown'}: $reply',
        );

        try {
          final payload = jsonDecode(reply);
          if (payload is Map<String, dynamic>) {
            final type = payload['type'] as String? ?? '';
            final text = (payload['text'] as String? ?? '').trim();
            final isFinal = (payload['is_final'] as bool?) ?? false;
            if (text.isNotEmpty && isFinal) {
              if (type == 'user_transcript') {
                _addTranscript(text, isUser: true);
                _userTalking = false;
                notifyListeners();
                return;
              }
              if (type == 'agent_transcript') {
                final clientMessageId =
                    (payload['client_message_id'] as String? ?? '').trim();
                if (clientMessageId.isNotEmpty &&
                    _completedTextMessageIds.contains(clientMessageId)) {
                  debugPrint(
                    'DEBUG: Ignoring late LiveKit text reply for $clientMessageId',
                  );
                  return;
                }
                if (clientMessageId.isNotEmpty) {
                  _completedTextMessageIds.add(clientMessageId);
                }
                _addTranscript(text, isUser: false);
                _setState(SessionState.listening);
                return;
              }
            }
          }
        } catch (_) {}

        _addTranscript(reply, isUser: false);
        _setState(SessionState.listening);
      });

      l.on<ParticipantConnectedEvent>((event) {
        debugPrint(
          'DEBUG: LiveKit participant connected'
          ' identity=${event.participant.identity}'
          ' sid=${event.participant.sid}',
        );
      });

      l.on<TrackSubscribedEvent>((event) {
        debugPrint(
          'DEBUG: LiveKit track subscribed'
          ' kind=${event.track.kind}'
          ' participant=${event.participant.identity}',
        );
      });

      l.on<RoomDisconnectedEvent>((event) {
        debugPrint('DEBUG: Room disconnected natively.');
        _handleRoomDisconnect();
      });

      // Start the amplitude and speaking status loop
      _startVolumeLoop();

      _setState(SessionState.ready);
      _setState(SessionState.listening);
    } catch (e) {
      debugPrint('DEBUG: LiveKit connection failed: $e');
      await _disconnectTransport();
      _setState(SessionState.disconnected);
      rethrow;
    }
  }

  /// Disconnects from the LiveKit room session and cleans up tracks and event listeners.
  void disconnect({bool notify = true}) {
    unawaited(_disconnectTransport());
    _setState(SessionState.disconnected, notify: notify);
  }

  Future<void> _disconnectTransport() async {
    _volumeTimer?.cancel();
    _volumeTimer = null;
    await _listener?.dispose();
    _listener = null;
    await _setMicrophoneEnabled(false);
    await _room?.disconnect();
    _room = null;
    _inputVolume = 0;
    _outputVolume = 0;
    _rawInputVolume = 0;
    _userTalking = false;
  }

  void _handleRoomDisconnect() {
    disconnect();
  }

  // ── Periodic Volume & Speaking Status Check ───────────────────────────────

  void _startVolumeLoop() {
    _volumeTimer?.cancel();
    _volumeTimer = Timer.periodic(
      const Duration(milliseconds: AudioConfig.uiMeterUpdateIntervalMs),
      (timer) {
        final r = _room;
        if (r == null || _state == SessionState.disconnected) {
          timer.cancel();
          return;
        }

        // Parse volume metrics
        final localLevel = r.localParticipant?.audioLevel ?? 0.0;
        _inputVolume = localLevel;
        _rawInputVolume = localLevel;

        double remoteLevel = 0.0;
        bool remoteSpeaking = false;
        for (final p in r.remoteParticipants.values) {
          if (p.audioLevel > remoteLevel) {
            remoteLevel = p.audioLevel;
          }
          if (p.isSpeaking) {
            remoteSpeaking = true;
          }
        }
        _outputVolume = remoteLevel;

        // Sync speaking states
        if (remoteSpeaking && _state != SessionState.speaking) {
          _setState(SessionState.speaking);
        } else if (!remoteSpeaking && _state == SessionState.speaking) {
          _setState(SessionState.listening);
        }

        // VAD user speaking detection
        final localSpeaking = r.localParticipant?.isSpeaking ?? false;
        if (localSpeaking && !_userTalking) {
          _userTalking = true;

          // User started talking -> Interruption check!
          // Flush local playing audio tracks immediately if speaking
          if (_state == SessionState.speaking) {
            debugPrint(
                'DEBUG: Interruption detected. Flushing remote audio playback.');
            flushLocalPlayback();
          }
          notifyListeners();
        } else if (!localSpeaking && _userTalking) {
          _userTalking = false;
          notifyListeners();
        }

        notifyListeners();
      },
    );
  }

  /// Silences playback tracks instantly by disabling WebRTC MediaStreamTrack.
  void flushLocalPlayback() {
    final r = _room;
    if (r == null) return;
    for (final participant in r.remoteParticipants.values) {
      for (final pub in participant.audioTrackPublications) {
        final track = pub.track;
        if (track != null) {
          try {
            track.mediaStreamTrack.enabled = false;
            // Re-enable track after brief duration to capture subsequent model speech
            Future.delayed(
              const Duration(
                  milliseconds: AudioConfig.livekitTrackFlushDelayMs),
              () {
                track.mediaStreamTrack.enabled = true;
              },
            );
          } catch (e) {
            debugPrint(
                'DEBUG: Error disabling audio track for interruption: $e');
          }
        }
      }
    }
  }

  // ── Text messaging over REST ───────────────────────────────────────────────

  /// Sends text through the production REST backend.
  ///
  /// Text mode is intentionally separate from LiveKit voice mode: typing must
  /// not connect a room, request microphone access, or trigger spoken output.
  Future<bool> sendText(
    String text, {
    List<Map<String, String>> attachments = const [],
  }) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty && attachments.isEmpty) return false;

    final attachmentSummary = attachments.isEmpty
        ? ''
        : '\n\nShared attachments:\n${attachments.map((a) => '- ${a['kind'] ?? 'file'}: ${a['filename'] ?? a['url'] ?? 'attachment'}').join('\n')}';
    final historyText = trimmed.isEmpty
        ? attachmentSummary.trim()
        : '$trimmed$attachmentSummary';

    if (_room != null || _state != SessionState.disconnected) {
      await _disconnectTransport();
      _setState(SessionState.disconnected);
    }

    _addTranscript(
      trimmed.isEmpty
          ? '[Shared ${attachments.length} attachment${attachments.length == 1 ? '' : 's'}]'
          : trimmed,
      isUser: true,
      historyText: historyText,
      attachments: attachments,
      allowRecentDuplicate: true,
    );

    return _sendTextViaRestFallback(historyText);
  }

  Future<bool> _sendTextViaRestFallback(String userText) async {
    _setState(SessionState.thinking);
    try {
      final response = await BackendService.chat(messages: _history);
      if (response.trim().isEmpty) {
        throw Exception('Empty fallback response');
      }
      _addTranscript(response, isUser: false);
      await BackendService.postTurn(
        sessionId: 'rest_${DateTime.now().millisecondsSinceEpoch}',
        messages: [
          {'role': 'user', 'text': userText},
          {'role': 'model', 'text': response},
        ],
      );
      _setTextChatFailure(TextChatFailure.none);
      _setState(SessionState.disconnected);
      return true;
    } catch (e) {
      debugPrint('DEBUG: REST text fallback failed: $e');
      _setTextChatFailure(
        e.toString().contains('quota_exhausted')
            ? TextChatFailure.quotaExhausted
            : TextChatFailure.serverError,
      );
      _setState(
          _room == null ? SessionState.disconnected : SessionState.listening);
      return false;
    }
  }

  /// Sends a text prompt request with the topic set to "speak" so the agent
  /// speaks the response out programmatically.
  Future<bool> sendLivePrompt(String prompt) async {
    final text = prompt.trim();
    if (text.isEmpty) return false;

    if (_room == null || _state == SessionState.disconnected) {
      await connect(userInitiated: true);
    }

    final deadline = DateTime.now()
        .add(const Duration(seconds: AudioConfig.retryDeadlineSeconds));
    final delayDur =
        const Duration(milliseconds: AudioConfig.retryPollIntervalMs);
    while (_state == SessionState.connecting &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(delayDur);
    }

    if (_room == null || _state == SessionState.disconnected) return false;

    _addTranscript(text, isUser: true, allowRecentDuplicate: true);

    try {
      final payload = utf8.encode(text);
      await _room?.localParticipant?.publishData(
        payload,
        reliable: true,
        topic: 'speak',
      );
      return true;
    } catch (e) {
      debugPrint('DEBUG: sendLivePrompt failed: $e');
      return false;
    }
  }

  // ── Wake Word Detection ────────────────────────────────────────────────────

  Future<void> startWakeWordListening() async {
    if (_state != SessionState.disconnected || _wakeWordListening) return;
    _sttAvailable = await _speechToText.initialize(onError: (_) {});
    if (!_sttAvailable) return;
    _wakeWordListening = true;
    notifyListeners();
    _listenForWakeWord();
  }

  void _listenForWakeWord() {
    if (!_wakeWordListening || _state != SessionState.disconnected) return;
    _speechToText.listen(
      onResult: (result) {
        final words = result.recognizedWords.toLowerCase();
        if (words.contains('hey ayma') ||
            words.contains('hi ayma') ||
            words.contains('okay ayma') ||
            words.contains('ok ayma')) {
          stopWakeWordListening();
          unawaited(connect(userInitiated: true));
        }
      },
      listenFor: const Duration(seconds: AudioConfig.wakeWordListenForSeconds),
      pauseFor: const Duration(seconds: AudioConfig.wakeWordPauseForSeconds),
      partialResults: true,
      onSoundLevelChange: null,
      cancelOnError: false,
      listenMode: stt.ListenMode.dictation,
    );
    _speechToText.statusListener = (status) {
      if (status == 'done' || status == 'notListening') {
        if (_wakeWordListening && _state == SessionState.disconnected) {
          Future.delayed(
              const Duration(milliseconds: AudioConfig.wakeWordDelayMs),
              _listenForWakeWord);
        }
      }
    };
  }

  void stopWakeWordListening() {
    if (!_wakeWordListening) return;
    _wakeWordListening = false;
    _speechToText.stop();
    notifyListeners();
  }

  void stopSpeaking() {
    if (_state == SessionState.speaking) {
      flushLocalPlayback();
    }
  }

  // ── Transcript Persistence & Helpers ───────────────────────────────────────

  Future<void> clearLocalTranscript() async {
    _transcript.clear();
    _history.clear();
    await _persistTranscript();
    notifyListeners();
  }

  Future<void> _restoreTranscript() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      _transcript.clear();
      _history.clear();
      notifyListeners();
      return;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_transcriptStorageKey);
      _transcript.clear();
      _history.clear();
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw) as List<dynamic>;
        _transcript.addAll(decoded
            .whereType<Map<String, dynamic>>()
            .map(TranscriptLine.fromMap)
            .where((l) => l.text.isNotEmpty));
        for (final line in _transcript) {
          _history.add({
            'role': line.isUser ? 'user' : 'model',
            'text': _stamp(line.time, line.text),
          });
        }
        _trimHistory();
      }
      notifyListeners();
    } catch (_) {}
  }

  Future<void> _persistTranscript() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _transcriptStorageKey,
        jsonEncode(_transcript.map((l) => l.toMap()).toList()),
      );
    } catch (_) {}
  }

  void _schedulePersistTranscript() {
    _persistDebounce?.cancel();
    _persistDebounce =
        Timer(const Duration(milliseconds: AudioConfig.persistDebounceMs), () {
      unawaited(_persistTranscript());
    });
  }

  void _addTranscript(
    String text, {
    required bool isUser,
    String? historyText,
    List<Map<String, dynamic>>? attachments,
    bool allowRecentDuplicate = false,
  }) {
    final normalized = text.trim();
    if (normalized.isEmpty && (attachments == null || attachments.isEmpty)) {
      return;
    }

    if (_transcript.isNotEmpty) {
      final last = _transcript.last;
      final isDuplicate = last.isUser == isUser &&
          last.text.trim() == normalized &&
          DateTime.now().difference(last.time) <
              const Duration(seconds: AudioConfig.duplicatePreventSeconds);
      if (isDuplicate && !allowRecentDuplicate) return;
    }

    final now = DateTime.now();
    _transcript.add(
      TranscriptLine(normalized,
          isUser: isUser, time: now, attachments: attachments),
    );
    _trimTranscriptIfNeeded();

    _history.add({
      'role': isUser ? 'user' : 'model',
      'text': _stamp(now, (historyText ?? normalized).trim()),
    });
    _trimHistory();
    _schedulePersistTranscript();
    notifyListeners();
  }

  void _trimHistory() {
    if (_history.length > AudioConfig.maxHistoryLength) {
      _history.removeRange(0, _history.length - AudioConfig.maxHistoryLength);
    }
  }

  void _trimTranscriptIfNeeded() {
    if (_transcript.length <= AudioConfig.maxTranscriptLines) return;
    _transcript.removeRange(
        0, _transcript.length - AudioConfig.maxTranscriptLines);
  }

  String _stamp(DateTime time, String text) =>
      '[${time.toIso8601String()}] $text';

  Future<Map<String, dynamic>> _bootstrapForProvider() async {
    if (Env.liveProvider != 'gemini' && Env.openAiApiKey.isNotEmpty) {
      try {
        return await BackendService.bootstrap().timeout(
            const Duration(seconds: AudioConfig.bootstrapTimeoutSeconds));
      } catch (_) {
        return <String, dynamic>{};
      }
    }
    return BackendService.bootstrap();
  }

  // ── Mute Controls ──────────────────────────────────────────────────────────

  void toggleMute() {
    setMuted(!_muted);
  }

  void setMuted(bool muted) {
    if (_muted == muted) return;
    _muted = muted;
    unawaited(_setMicrophoneEnabled(!_muted));
    notifyListeners();
  }

  Future<void> _setMicrophoneEnabled(bool enabled) async {
    final participant = _room?.localParticipant;
    if (participant == null) return;
    await participant.setMicrophoneEnabled(enabled);
    for (final pub in participant.audioTrackPublications) {
      final track = pub.track;
      if (track != null) {
        track.mediaStreamTrack.enabled = enabled;
      }
    }
  }

  void toggleSpeaker() {
    _speakerMuted = !_speakerMuted;
    final r = _room;
    if (r == null) return;
    for (final participant in r.remoteParticipants.values) {
      for (final pub in participant.audioTrackPublications) {
        final track = pub.track;
        if (track != null) {
          track.mediaStreamTrack.enabled = !_speakerMuted;
        }
      }
    }
    notifyListeners();
  }

  void _setState(SessionState next, {bool notify = true}) {
    final changed = _state != next;
    _state = next;
    if (changed && next != SessionState.speaking) _outputVolume = 0;
    if (notify && changed) notifyListeners();
  }

  void _setTextChatFailure(TextChatFailure f) {
    if (_textChatFailure == f) return;
    _textChatFailure = f;
    notifyListeners();
  }

  @override
  void dispose() {
    stopWakeWordListening();
    _speechToText.stop();
    _persistDebounce?.cancel();
    _volumeTimer?.cancel();
    unawaited(_disconnectTransport());
    super.dispose();
  }
}
