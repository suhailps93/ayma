import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

import '../env.dart';
import 'audio_recorder_service.dart';
import 'audio_streamer_service.dart';
import 'backend_service.dart';
import 'firestore_service.dart';
import 'gemini_live_client.dart';
import 'openai_realtime_client.dart';

// ignore_for_file: deprecated_member_use

enum SessionState {
  disconnected,
  connecting,
  ready,
  listening,
  thinking,
  speaking,
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

// Orchestrates the selected live client + recorder + streamer while preserving
// the UI contract used by ChatScreen.
class AymaAudioService extends ChangeNotifier {
  String get _transcriptStorageKey {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? 'guest';
    return 'ayma.chat.transcript.$uid';
  }

  late final dynamic _client =
      Env.liveProvider == 'gemini' ? GeminiLiveClient() : OpenAiRealtimeClient();
  final _recorder = AudioRecorderService();
  final _streamer = AudioStreamerService();

  final List<StreamSubscription<dynamic>> _subs = [];

  SessionState _state = SessionState.disconnected;
  SessionState get state => _state;

  double _inputVolume = 0;
  double _outputVolume = 0;
  double _rawInputVolume = 0;
  double _smoothedInputVol = 0;
  Timer? _talkHoldoffTimer;
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

  String _pendingTurnUser = '';
  String _pendingTurnModel = '';
  Timer? _persistDebounce;
  Timer? _outputDecayTimer;
  int _audioBytesPerTurn = 0;
  static const int _maxTranscriptLines = 180;

  String? _providerApiKey;
  String? _systemPrompt;
  String _sessionId = DateTime.now().millisecondsSinceEpoch.toString();

  final _speechToText = stt.SpeechToText();
  bool _sttAvailable = false;
  bool _wakeWordListening = false;

  Future<void>? _connectFuture;

  DateTime _lastMeterUiUpdate = DateTime.fromMillisecondsSinceEpoch(0);

  final BytesBuilder _pendingMicAudio = BytesBuilder(copy: false);
  Timer? _micFlushTimer;
  static const _micFlushInterval = Duration(milliseconds: 120);

  AymaAudioService() {
    _wireClientStreams();
    _wireRecorderStreams();
    unawaited(initForUser());
  }

  Future<void> initForUser() async {
    await _restoreTranscript();
  }

  // ── Playback drain helper ─────────────────────────────────────────────────────

  void _schedulePlaybackEnd() {
    _outputDecayTimer?.cancel();
    // PCM 16-bit mono @ 24 kHz → 48 000 bytes per second
    const bytesPerMs = 48.0;
    final bufferedMs = (_audioBytesPerTurn / bytesPerMs).clamp(200.0, 8000.0);
    _audioBytesPerTurn = 0;
    // Let the wave stay alive for the estimated playback duration + 250 ms buffer
    _outputDecayTimer = Timer(Duration(milliseconds: bufferedMs.toInt() + 250), () {
      _outputDecayTimer = null;
      if (_state == SessionState.speaking || _state == SessionState.thinking) {
        _setState(SessionState.listening);
      }
      _outputVolume = 0;
      _notifyMetersThrottled();
    });
  }

  // ── Wire live-client events → session state ────────────────────────────────

  void _wireClientStreams() {
    // setupComplete → start mic (mirrors ControlTray useEffect on `connected`)
    _subs.add(_client.setupCompleteStream.listen((_) async {
      _setState(SessionState.ready);
      await _recorder.start();
      _setState(SessionState.listening);
    }));

    // audio → streamer (mirrors onAudio → audioStreamer.addPCM16 in useLiveAPI)
    _subs.add(_client.audioStream.listen((event) {
      final chunk = event as LiveAudioChunk;
      if (_speakerMuted) return;
      // Feed streamer first, before any UI work, to minimize delivery latency
      _audioBytesPerTurn += chunk.data.lengthInBytes;
      unawaited(_streamer.addPcm16(chunk.data, mimeType: chunk.mimeType));
      if (_state != SessionState.speaking) {
        _setState(SessionState.speaking);
      }
      final now = DateTime.now();
      if (now.difference(_lastMeterUiUpdate) >= const Duration(milliseconds: 33)) {
        _outputVolume = _pcmRms(chunk.data);
        _lastMeterUiUpdate = now;
        notifyListeners();
      }
    }));

    // interrupted → stop streamer (mirrors stopAudioStreamer in useLiveAPI)
    _subs.add(_client.interruptedStream.listen((_) {
      _outputDecayTimer?.cancel();
      _outputDecayTimer = null;
      _audioBytesPerTurn = 0;
      _streamer.stop();
      _outputVolume = 0;
      final userText = _pendingTurnUser.trim();
      if (userText.isNotEmpty) {
        _addTranscript(userText, isUser: true);
      }
      final partialModel = _pendingTurnModel.trim();
      if (partialModel.isNotEmpty) {
        _addTranscript(partialModel, isUser: false);
      }
      unawaited(_commitTurnToBackend());
      _pendingTurnModel = '';
      _setState(SessionState.listening);
    }));

    _subs.add(_client.outputTranscriptStream.listen((text) {
      _pendingTurnModel = _mergeTurnText(_pendingTurnModel, text);
    }));

    _subs.add(_client.inputTranscriptStream.listen((text) {
      _pendingTurnUser = _mergeTurnText(_pendingTurnUser, text);
      _checkGoodbyeWakeWord(_pendingTurnUser);
      // Transcript arrival = provider-confirmed speech → activate user wave.
      if (!_userTalking) {
        _userTalking = true;
        _notifyMetersThrottled();
      }
      _talkHoldoffTimer?.cancel();
      _talkHoldoffTimer = Timer(const Duration(milliseconds: 1200), () {
        _userTalking = false;
        _notifyMetersThrottled();
      });
    }));

    _subs.add(_client.turnCompleteStream.listen((_) {
      final userText = _pendingTurnUser.trim();
      if (userText.isNotEmpty) {
        _addTranscript(userText, isUser: true);
      }
      final modelText = _pendingTurnModel.trim();
      if (modelText.isNotEmpty) {
        _addTranscript(modelText, isUser: false);
      }
      unawaited(_commitTurnToBackend());
      _schedulePlaybackEnd();
    }));

    _subs.add(_client.toolCallStream.listen((calls) {
      unawaited(_handleToolCalls(calls));
    }));

    _subs.add(_client.disconnectedStream.listen((_) {
      _clearPendingMicAudio();
      _talkHoldoffTimer?.cancel();
      _talkHoldoffTimer = null;
      _userTalking = false;
      _pendingTurnUser = '';
      _pendingTurnModel = '';
      _setState(SessionState.disconnected);
    }));
  }

  // ── Wire AudioRecorderService → client (mirrors ControlTray onData handler) ─

  void _wireRecorderStreams() {
    _subs.add(_recorder.pcmStream.listen((pcm16) {
      _rawInputVolume = _pcmRms(pcm16);
      if (!_muted) _bufferAudio(pcm16);
      _notifyMetersThrottled();
    }));

    _subs.add(_recorder.volumeStream.listen((vol) {
      _inputVolume = vol;
      // EMA smoothing for visual amplitude only — VAD is driven by transcript events
      final alpha = vol > _smoothedInputVol ? 0.35 : 0.15;
      _smoothedInputVol = _smoothedInputVol * (1 - alpha) + vol * alpha;
      _rawInputVolume = _smoothedInputVol;
      _notifyMetersThrottled();
    }));
  }

  // ── Mic audio buffering + echo suppression ────────────────────────────────────

  void _bufferAudio(Uint8List pcm) {
    if (!_client.isConnected || _state == SessionState.disconnected || _muted) return;
    
    // For autonomous barge-in to work, we MUST send microphone audio even
    // while the model is speaking. The server uses VAD (Voice Activity Detection)
    // to detect when the user interrupts the model.
    // We rely on client-side AEC (configured in web_audio_impl.dart and 
    // audio_recorder_service.dart) to filter out the model's own voice.
    
    _pendingMicAudio.add(pcm);
    _micFlushTimer ??= Timer(_micFlushInterval, _flushBufferedAudio);
  }

  void _flushBufferedAudio() {
    _micFlushTimer = null;
    if (_pendingMicAudio.length == 0) return;
    if (!_client.isConnected || _state == SessionState.disconnected || _muted) {
      _clearPendingMicAudio();
      return;
    }
    final pcm = _pendingMicAudio.takeBytes();
    _sendAudioToClient(pcm);
  }

  void _clearPendingMicAudio() {
    _micFlushTimer?.cancel();
    _micFlushTimer = null;
    if (_pendingMicAudio.length > 0) _pendingMicAudio.clear();
  }

  void _sendAudioToClient(Uint8List pcm) {
    if (!_client.isConnected || _state == SessionState.disconnected || _muted) return;
    _client.sendRealtimeAudio(pcm);
  }

  // ── Wake word detection ──────────────────────────────────────────────────────

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
      listenFor: const Duration(seconds: 8),
      pauseFor: const Duration(seconds: 3),
      partialResults: true,
      onSoundLevelChange: null,
      cancelOnError: false,
      listenMode: stt.ListenMode.dictation,
    );
    _speechToText.statusListener = (status) {
      if (status == 'done' || status == 'notListening') {
        if (_wakeWordListening && _state == SessionState.disconnected) {
          Future.delayed(const Duration(milliseconds: 300), _listenForWakeWord);
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

  bool get wakeWordListening => _wakeWordListening;

  void stopSpeaking() {
    if (_client.isConnected && _state == SessionState.speaking) {
      _client.interrupt();
      // The server will send an 'interrupted' message back, 
      // which we already handle in _wireClientStreams to stop playback.
    }
  }

  // ── Connection lifecycle ─────────────────────────────────────────────────────

  Future<void> connect({bool userInitiated = false}) async {
    if (_connectFuture != null) {
      await _connectFuture;
      return;
    }
    _connectFuture = _connect();
    try {
      await _connectFuture;
    } finally {
      _connectFuture = null;
    }
  }

  Future<void> _connect() async {
    stopWakeWordListening();
    if (_state != SessionState.disconnected) {
      _disconnectTransport();
      _setState(SessionState.disconnected);
    }

    _setState(SessionState.connecting);
    _sessionId = DateTime.now().millisecondsSinceEpoch.toString();

    // Check for environment bypass first
    debugPrint('DEBUG: Attempting connect. Provider: ${Env.liveProvider}, Key length: ${Env.geminiApiKey.length}');
    if (Env.liveProvider == 'gemini' && Env.geminiApiKey.isNotEmpty) {
      debugPrint('DEBUG: Using Gemini API Key Bypass');
      _providerApiKey = Env.geminiApiKey;
      final payload = {
        // PERMANENT MODEL SELECTION - DO NOT CHANGE WITHOUT EXPLICIT USER DIRECTIVE
        'model': 'models/gemini-3.1-flash-live-preview',
        'generation_config': {
          'response_modalities': ['AUDIO'],
          'speech_config': {
            'voice_config': {
              'prebuilt_voice_config': {
                'voice_name': 'Aoide',
              }
            }
          }
        }
      };
      // Switch to stable v1beta URL
      const wsUrl = 'wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent';
      await _client.connect(wsUrl, _providerApiKey!, payload);
      return;
    }

    if (!kIsWeb) {
      final permission = await Permission.microphone.request();
      if (!permission.isGranted) {
        _setState(SessionState.disconnected);
        throw Exception('Microphone permission denied');
      }
    }

    final bootstrap = await _bootstrapForProvider();
    final liveWsUrl = bootstrap['websocket_url'] as String?;
    final apiKey = _credentialFromBootstrap(bootstrap);
    final setup = bootstrap['setup'] as Map<String, dynamic>?;

    _providerApiKey = apiKey;
    _systemPrompt = _extractSystemPrompt(setup);

    try {
      if (Env.liveProvider == 'gemini') {
        if (liveWsUrl == null || liveWsUrl.isEmpty || apiKey == null) {
          throw Exception('Missing Gemini Live bootstrap data');
        }

        final Map<String, dynamic> payload = setup != null
            ? Map<String, dynamic>.from(setup)
            : <String, dynamic>{
                // PERMANENT MODEL SELECTION - DO NOT CHANGE WITHOUT EXPLICIT USER DIRECTIVE
                'model': 'models/gemini-3.1-flash-live-preview',
                'response_modalities': ['AUDIO'],
                'speech_config': {
                  'voice_config': {
                    'prebuilt_voice_config': {
                      'voice_name': 'Aoide', // Standard Gemini Live voice
                    }
                  }
                },
                'generation_config': {
                  'speech_config': {
                    'voice_config': {
                      'prebuilt_voice_config': {
                        'voice_name': 'Aoide',
                      }
                    }
                  }
                }
              };

        // Inject VAD config if not present to ensure best barge-in experience
        payload['speech_config'] ??= <String, dynamic>{};
        final speechConfig = Map<String, dynamic>.from(payload['speech_config'] as Map);
        payload['speech_config'] = speechConfig;

        // Gemini Multimodal Live API uses 'speech_config' with 'voice_config'
        // Some versions use 'automatic_activity_detection'
        speechConfig['automatic_activity_detection'] ??= {
          'enabled': true,
          'detection_sensitivity': 'HIGH',
          'prefix_padding_ms': 300,
        };

        await _client.connect(liveWsUrl, apiKey, payload);
        return;
      }

      if (apiKey == null || apiKey.isEmpty) {
        throw Exception(
          'Missing OpenAI credential. Provide AYMA_OPENAI_API_KEY or return openai_api_key/client_secret from bootstrap.',
        );
      }

      final model =
          (bootstrap['openai_realtime_model'] as String?) ?? Env.openAiRealtimeModel;
      await _client.connect(
        apiKey: apiKey,
        model: model.isEmpty ? 'gpt-realtime-2' : model,
        session: _openAiSessionFromBootstrap(setup),
      );
    } catch (e) {
      debugPrint('Live connection failed: $e');
      _disconnectTransport();
      _setState(SessionState.disconnected);
      rethrow;
    }
  }

  void disconnect({bool notify = true}) {
    _disconnectTransport();
    _clearPendingMicAudio();
    _pendingTurnUser = '';
    _pendingTurnModel = '';
    _setState(SessionState.disconnected, notify: notify);
  }

  void _disconnectTransport() {
    _client.disconnect();
    _recorder.stop();
    _streamer.stop();
    _talkHoldoffTimer?.cancel();
    _talkHoldoffTimer = null;
    _userTalking = false;
    _smoothedInputVol = 0;
    _outputDecayTimer?.cancel();
    _outputDecayTimer = null;
    _audioBytesPerTurn = 0;
  }

  // ── Transcript persistence ────────────────────────────────────────────────────

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
    
    // We don't use _restoredTranscript flag because we want to re-restore 
    // when a DIFFERENT user signs in.
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
    _persistDebounce = Timer(const Duration(milliseconds: 900), () {
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
    if (normalized.isEmpty && (attachments == null || attachments.isEmpty)) return;

    if (_transcript.isNotEmpty) {
      final last = _transcript.last;
      final isDuplicate = last.isUser == isUser &&
          last.text.trim() == normalized &&
          DateTime.now().difference(last.time) < const Duration(seconds: 3);
      if (isDuplicate && !allowRecentDuplicate) return;
    }

    final now = DateTime.now();
    _transcript.add(
      TranscriptLine(normalized, isUser: isUser, time: now, attachments: attachments),
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
    if (_history.length > 60) _history.removeRange(0, _history.length - 60);
  }

  void _trimTranscriptIfNeeded() {
    if (_transcript.length <= _maxTranscriptLines) return;
    _transcript.removeRange(0, _transcript.length - _maxTranscriptLines);
  }

  // ── Backend turn commit ───────────────────────────────────────────────────────

  Future<void> _commitTurnToBackend() async {
    final userText = _pendingTurnUser.trim();
    final modelText = _pendingTurnModel.trim();
    if (userText.isEmpty && modelText.isEmpty) return;

    final messages = <Map<String, String>>[
      if (userText.isNotEmpty) {'role': 'user', 'text': userText},
      if (modelText.isNotEmpty) {'role': 'model', 'text': modelText},
    ];

    try {
      await BackendService.postTurn(sessionId: _sessionId, messages: messages);
      // Clear only after confirmed write, so transient failures can retry.
      if (_pendingTurnUser.trim() == userText) _pendingTurnUser = '';
      if (_pendingTurnModel.trim() == modelText) _pendingTurnModel = '';
    } catch (e) {
      debugPrint('post-turn memory sync failed: $e');
    }
  }

  // ── Tool call handling ────────────────────────────────────────────────────────

  Future<void> _handleToolCalls(List<LiveToolCall> calls) async {
    final responses = <Map<String, dynamic>>[];
    for (final call in calls) {
      String output;
      if (call.name == 'add_followup_question') {
        output = await _execAddFollowup(call.args);
      } else if (call.name == 'get_current_time') {
        output = DateTime.now().toIso8601String();
      } else {
        output = 'Tool ${call.name} is not available.';
      }
      responses.add({
        'id': call.id,
        'name': call.name,
        'response': {'output': output},
      });
    }
    if (_client.isConnected) {
      _client.sendToolResponse(responses);
    }
  }

  Future<String> _execAddFollowup(Map<String, dynamic> args) async {
    final question = (args['question'] as String? ?? '').trim();
    if (question.isEmpty) return 'skipped: empty question';
    try {
      await FirestoreService.addFollowupQuestion(question, sessionId: _sessionId);
      return 'noted';
    } catch (e) {
      return 'error: $e';
    }
  }

  // ── Text chat (HTTP) ─────────────────────────────────────────────────────────

  Future<bool> sendText(
    String text, {
    List<Map<String, String>> attachments = const [],
  }) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty && attachments.isEmpty) return false;

    final attachmentSummary = attachments.isEmpty
        ? ''
        : '\n\nShared attachments:\n${attachments.map((a) => '- ${a['kind'] ?? 'file'}: ${a['filename'] ?? a['url'] ?? 'attachment'}').join('\n')}';
    final historyText =
        trimmed.isEmpty ? attachmentSummary.trim() : '$trimmed$attachmentSummary';

    _addTranscript(
      trimmed.isEmpty
          ? '[Shared ${attachments.length} attachment${attachments.length == 1 ? '' : 's'}]'
          : trimmed,
      isUser: true,
      historyText: historyText,
      attachments: attachments,
      allowRecentDuplicate: true,
    );

    if (_state == SessionState.disconnected) _setState(SessionState.thinking);

    try {
      await _bootstrapTextChatIfNeeded();
      final reply = await _providerTextChat(historyText, attachments: attachments);
      if (reply.isEmpty) {
        _addAssistantFallbackMessage();
        return false;
      }
      _pendingTurnUser = historyText;
      _pendingTurnModel = reply;
      _addTranscript(reply, isUser: false);
      unawaited(_commitTurnToBackend());
      return true;
    } catch (_) {
      _addAssistantFallbackMessage();
      return false;
    } finally {
      if (_state == SessionState.thinking) _setState(SessionState.disconnected);
    }
  }

  Future<bool> sendLivePrompt(String prompt) async {
    final text = prompt.trim();
    if (text.isEmpty) return false;

    if (_state == SessionState.disconnected || !_client.isConnected) {
      await connect(userInitiated: true);
    }

    final deadline = DateTime.now().add(const Duration(seconds: 6));
    while (_state == SessionState.connecting && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }

    if (!_client.isConnected || _state == SessionState.disconnected) return false;

    _addTranscript(text, isUser: true, allowRecentDuplicate: true);
    _client.sendText(text);
    return true;
  }

  Future<void> _bootstrapTextChatIfNeeded() async {
    if ((_providerApiKey ?? '').isNotEmpty) return;
    final bootstrap = await _bootstrapForProvider();
    _providerApiKey = _credentialFromBootstrap(bootstrap);
    final setup = bootstrap['setup'] as Map<String, dynamic>?;
    _systemPrompt = _extractSystemPrompt(setup);
    if ((_providerApiKey ?? '').isEmpty) {
      throw Exception('Missing ${Env.liveProvider} API key from bootstrap/env');
    }
  }

  Future<Map<String, dynamic>> _bootstrapForProvider() async {
    if (Env.liveProvider != 'gemini' && Env.openAiApiKey.isNotEmpty) {
      try {
        return await BackendService.bootstrap().timeout(const Duration(seconds: 4));
      } catch (_) {
        return <String, dynamic>{};
      }
    }
    return BackendService.bootstrap();
  }

  Future<String> _providerTextChat(
    String message, {
    List<Map<String, String>> attachments = const [],
  }) async {
    await _bootstrapTextChatIfNeeded();
    return Env.liveProvider == 'gemini'
        ? _geminiTextChat(message, attachments: attachments)
        : _openAiTextChat(message, attachments: attachments);
  }

  Future<String> _geminiTextChat(
    String message, {
    List<Map<String, String>> attachments = const [],
  }) async {
    final key = _providerApiKey;
    if (key == null || key.isEmpty) return '';

    final userParts = await _buildUserParts(message: message, attachments: attachments);

    final contents = [
      for (final h in _history.sublist(0, math.max(0, _history.length - 1)))
        {
          'role': h['role'],
          'parts': [
            {'text': h['text']}
          ]
        },
      {'role': 'user', 'parts': userParts},
    ];

    final response = await http
        .post(
          Uri.parse(
              // PERMANENT MODEL SELECTION - DO NOT CHANGE WITHOUT EXPLICIT USER DIRECTIVE
              'https://generativelanguage.googleapis.com/v1beta/models/gemini-3.5-flash:generateContent?key=$key'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'contents': contents,
            if ((_systemPrompt ?? '').isNotEmpty)
              'systemInstruction': {
                'parts': [
                  {'text': _systemPrompt}
                ]
              },
          }),
        )
        .timeout(const Duration(seconds: 30));

    if (response.statusCode != 200) return '';
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final candidates = body['candidates'] as List<dynamic>? ?? [];
    if (candidates.isEmpty) return '';
    final parts = (candidates.first['content']?['parts'] as List<dynamic>? ?? []);
    return parts.map((p) => (p['text'] as String? ?? '')).join(' ').trim();
  }

  Future<String> _openAiTextChat(
    String message, {
    List<Map<String, String>> attachments = const [],
  }) async {
    final key = _providerApiKey;
    if (key == null || key.isEmpty) return '';

    final input = <Map<String, dynamic>>[
      for (final h in _history.sublist(0, math.max(0, _history.length - 1)))
        {
          'role': h['role'] == 'model' ? 'assistant' : 'user',
          'content': [
            {'type': 'input_text', 'text': h['text'] ?? ''},
          ],
        },
      {
        'role': 'user',
        'content': await _buildOpenAiUserContent(
          message: message,
          attachments: attachments,
        ),
      },
    ];

    final response = await http
        .post(
          Uri.parse('https://api.openai.com/v1/responses'),
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $key',
          },
          body: jsonEncode({
            'model': Env.openAiTextModel.isEmpty ? 'gpt-5.5' : Env.openAiTextModel,
            if ((_systemPrompt ?? '').isNotEmpty) 'instructions': _systemPrompt,
            'input': input,
          }),
        )
        .timeout(const Duration(seconds: 30));

    if (response.statusCode != 200) {
      debugPrint('OpenAI text chat failed: ${response.statusCode} ${response.body}');
      return '';
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return _extractOpenAiOutputText(body).trim();
  }

  Future<List<Map<String, dynamic>>> _buildUserParts({
    required String message,
    List<Map<String, String>> attachments = const [],
  }) async {
    final parts = <Map<String, dynamic>>[
      {'text': message},
    ];

    var imageCount = 0;
    for (final att in attachments) {
      final kind = (att['kind'] ?? '').toLowerCase();
      final url = att['url'] ?? '';
      if (kind != 'image' || url.isEmpty || imageCount >= 3 || !url.startsWith('http')) {
        continue;
      }
      try {
        final res = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 12));
        if (res.statusCode != 200 || res.bodyBytes.isEmpty) continue;
        if (res.bodyBytes.length > 4 * 1024 * 1024) continue;
        final mimeType = _detectImageMimeType(att, res.headers) ?? 'image/jpeg';
        parts.add({
          'inlineData': {'mimeType': mimeType, 'data': base64Encode(res.bodyBytes)}
        });
        imageCount++;
      } catch (_) {}
    }
    return parts;
  }

  List<Map<String, dynamic>> _openAiToolsFromGeminiSetup(Map<String, dynamic>? setup) {
    final declarations = setup?['tools'] is List
        ? (setup?['tools'] as List)
            .whereType<Map<String, dynamic>>()
            .expand((tool) => (tool['function_declarations'] as List? ?? const []))
            .whereType<Map<String, dynamic>>()
            .toList()
        : const <Map<String, dynamic>>[];

    final source = declarations.isNotEmpty
        ? declarations
        : const [
            {
              'name': 'add_followup_question',
              'description': 'Save a useful follow-up question to ask the user later.',
              'parameters': {
                'type': 'object',
                'properties': {
                  'question': {
                    'type': 'string',
                    'description': 'The concise follow-up question to save.'
                  }
                },
                'required': ['question']
              }
            },
            {
              'name': 'get_current_time',
              'description': 'Get the current local timestamp.',
              'parameters': {'type': 'object', 'properties': {}}
            },
          ];

    return [
      for (final declaration in source)
        {
          'type': 'function',
          'name': declaration['name'] as String? ?? '',
          if ((declaration['description'] as String? ?? '').isNotEmpty)
            'description': declaration['description'],
          'parameters': declaration['parameters'] ??
              {'type': 'object', 'properties': <String, dynamic>{}},
        },
    ].where((tool) => (tool['name'] as String).isNotEmpty).toList();
  }

  Map<String, dynamic> _openAiSessionFromBootstrap(Map<String, dynamic>? setup) {
    return {
      'type': 'realtime',
      if ((_systemPrompt ?? '').isNotEmpty) 'instructions': _systemPrompt,
      'audio': {
        'input': {
          'format': {
            'type': 'audio/pcm',
            'rate': 24000,
          },
          'turn_detection': {
            'type': 'semantic_vad',
            'eagerness': 'medium',
            'interrupt_response': true,
            'create_response': true,
          },
          'transcription': {
            'model': 'gpt-4o-mini-transcribe',
          },
        },
        'output': {
          'format': {
            'type': 'audio/pcm',
            'rate': 24000,
          },
          'voice': Env.openAiVoice.isEmpty ? 'marin' : Env.openAiVoice,
        },
      },
      'tools': _openAiToolsFromGeminiSetup(setup),
    };
  }

  String? _credentialFromBootstrap(Map<String, dynamic> bootstrap) {
    if (Env.liveProvider != 'gemini' && Env.openAiApiKey.isNotEmpty) {
      return Env.openAiApiKey;
    }
    final clientSecret = bootstrap['client_secret'];
    if (clientSecret is Map<String, dynamic>) {
      final secretValue = clientSecret['value'] as String?;
      if ((secretValue ?? '').isNotEmpty) return secretValue;
    }
    return bootstrap['openai_api_key'] as String? ??
        bootstrap['token'] as String? ??
        bootstrap['api_key'] as String?;
  }

  String _extractSystemPrompt(Map<String, dynamic>? setup) {
    final geminiParts = setup?['system_instruction']?['parts'];
    if (geminiParts is List) {
      return geminiParts
          .whereType<Map<String, dynamic>>()
          .map((p) => p['text'] as String? ?? '')
          .join('')
          .trim();
    }
    return (setup?['instructions'] as String? ?? '').trim();
  }

  Future<List<Map<String, dynamic>>> _buildOpenAiUserContent({
    required String message,
    List<Map<String, String>> attachments = const [],
  }) async {
    final content = <Map<String, dynamic>>[
      {'type': 'input_text', 'text': message},
    ];

    var imageCount = 0;
    for (final att in attachments) {
      final kind = (att['kind'] ?? '').toLowerCase();
      final url = att['url'] ?? '';
      if (kind != 'image' || url.isEmpty || imageCount >= 3 || !url.startsWith('http')) {
        continue;
      }
      try {
        final res = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 12));
        if (res.statusCode != 200 || res.bodyBytes.isEmpty) continue;
        if (res.bodyBytes.length > 4 * 1024 * 1024) continue;
        final mimeType = _detectImageMimeType(att, res.headers) ?? 'image/jpeg';
        content.add({
          'type': 'input_image',
          'image_url': 'data:$mimeType;base64,${base64Encode(res.bodyBytes)}',
        });
        imageCount++;
      } catch (_) {}
    }
    return content;
  }

  String _extractOpenAiOutputText(Map<String, dynamic> body) {
    final direct = body['output_text'] as String?;
    if ((direct ?? '').isNotEmpty) return direct!;

    final buffer = StringBuffer();
    final output = body['output'] as List<dynamic>? ?? const [];
    for (final item in output.whereType<Map<String, dynamic>>()) {
      final content = item['content'] as List<dynamic>? ?? const [];
      for (final part in content.whereType<Map<String, dynamic>>()) {
        final text = part['text'] as String? ?? part['transcript'] as String? ?? '';
        if (text.isNotEmpty) {
          if (buffer.isNotEmpty) buffer.write(' ');
          buffer.write(text);
        }
      }
    }
    return buffer.toString();
  }

  String? _detectImageMimeType(
    Map<String, String> attachment,
    Map<String, String> headers,
  ) {
    final headerType = headers['content-type'];
    if (headerType != null && headerType.startsWith('image/')) {
      return headerType.split(';').first.trim();
    }
    final name = (attachment['filename'] ?? '').toLowerCase();
    if (name.endsWith('.png')) return 'image/png';
    if (name.endsWith('.webp')) return 'image/webp';
    if (name.endsWith('.gif')) return 'image/gif';
    if (name.endsWith('.jpg') || name.endsWith('.jpeg')) return 'image/jpeg';
    return null;
  }

  // ── Controls ─────────────────────────────────────────────────────────────────

  void toggleMute() {
    _muted = !_muted;
    notifyListeners();
  }

  void setMuted(bool muted) {
    if (_muted == muted) return;
    _muted = muted;
    if (_muted) {
      _clearPendingMicAudio();
    }
    notifyListeners();
  }

  void toggleSpeaker() {
    _speakerMuted = !_speakerMuted;
    if (_speakerMuted) _streamer.stop();
    notifyListeners();
  }

  // ── Internal helpers ─────────────────────────────────────────────────────────

  void _setState(SessionState next, {bool notify = true}) {
    final changed = _state != next;
    _state = next;
    if (changed && next != SessionState.speaking) _outputVolume = 0;
    if (notify && changed) notifyListeners();
  }

  void _notifyMetersThrottled() {
    final now = DateTime.now();
    if (now.difference(_lastMeterUiUpdate) < const Duration(milliseconds: 260)) return;
    _lastMeterUiUpdate = now;
    notifyListeners();
  }

  String _mergeTurnText(String existing, String incoming) {
    final next = incoming.trim();
    final cur = existing.trim();
    if (next.isEmpty) return cur;
    if (cur.isEmpty) return next;
    if (cur == next || cur.endsWith(next)) return cur;
    if (next.startsWith(cur)) return next;
    return '$cur $next';
  }

  String _stamp(DateTime time, String text) => '[${time.toIso8601String()}] $text';

  double _pcmRms(Uint8List pcm16) {
    if (pcm16.length < 2) return 0;
    final view = ByteData.sublistView(pcm16);
    final count = pcm16.length ~/ 2;
    double sum = 0;
    for (int i = 0; i < count; i++) {
      final s = view.getInt16(i * 2, Endian.little) / 32768.0;
      sum += s * s;
    }
    return math.sqrt(sum / count).clamp(0.0, 1.0);
  }

  void _checkGoodbyeWakeWord(String transcript) {
    final lower = transcript.toLowerCase();
    if (lower.contains('goodbye ayma') ||
        lower.contains('bye ayma') ||
        lower.contains('goodbye, ayma') ||
        lower.contains('bye, ayma') ||
        lower.contains('stop ayma')) {
      // Small delay so the transcript is committed first
      Future.delayed(const Duration(milliseconds: 400), () {
        if (_state != SessionState.disconnected) disconnect();
      });
    }
  }

  void _addAssistantFallbackMessage() {
    _addTranscript(
      'I could not generate a reply right now. Please check your connection and try again.',
      isUser: false,
    );
  }

  @override
  void dispose() {
    stopWakeWordListening();
    _speechToText.stop();
    _micFlushTimer?.cancel();
    _persistDebounce?.cancel();
    _talkHoldoffTimer?.cancel();
    _outputDecayTimer?.cancel();
    for (final sub in _subs) {
      sub.cancel();
    }
    _client.dispose();
    _recorder.dispose();
    _streamer.dispose();
    super.dispose();
  }
}
