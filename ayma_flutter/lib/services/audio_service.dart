import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter_sound/flutter_sound.dart';
import 'package:logger/logger.dart' show Level;
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/io.dart';

import 'package:http/http.dart' as http;

import 'backend_service.dart';
import 'firestore_service.dart';
import 'web_audio_stub.dart' if (dart.library.html) 'web_audio_impl.dart';

// ignore_for_file: deprecated_member_use

enum SessionState {
  disconnected,
  connecting,
  ready,
  listening,
  thinking,
  speaking
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

class AymaAudioService extends ChangeNotifier {
  static const _transcriptStorageKey = 'ayma.chat.transcript';

  WebSocketChannel? _channel;

  // Mobile audio (flutter_sound) — skipped on web
  final _recorder = FlutterSoundRecorder(logLevel: Level.nothing);
  final _player = FlutterSoundPlayer(logLevel: Level.nothing);
  bool _playerStreaming = false;
  int _playerSampleRate = 24000;
  int _playerChannels = 1;

  // Web audio (dart:html Web Audio API) — skipped on mobile
  final _webMic = WebMicCapture();
  final _webPlayer = WebPcmPlayer();

  StreamSubscription? _wsSub;

  SessionState _state = SessionState.disconnected;
  SessionState get state => _state;

  double _inputVolume = 0;
  double _outputVolume = 0;
  double get inputVolume => _inputVolume;
  double get outputVolume => _outputVolume;

  bool _userTalking = false;
  bool get userTalking => _userTalking;
  Timer? _userTalkingDebounce;

  bool _muted = false;
  bool _speakerMuted = false;
  bool get muted => _muted;
  bool get speakerMuted => _speakerMuted;

  final List<TranscriptLine> _transcript = [];
  List<TranscriptLine> get transcript => List.unmodifiable(_transcript);

  // Text-chat history for offline fallback (role: "user"|"model")
  final List<Map<String, String>> _textHistory = [];

  // Agent output: buffer and commit on turnComplete (or interrupt).
  // User input: gemini-3.1 delivers full-utterance transcription non-incrementally,
  // so we can show it immediately when received without waiting for turnComplete.
  String _pendingAgentText = '';
  String _pendingUserText = '';

  bool _audioInitialized = false;
  Future<void>? _audioInitFuture;
  Future<void>? _connectFuture;
  Timer? _reconnectTimer;
  bool _manualDisconnect = false;
  int _reconnectAttempts = 0;
  final BytesBuilder _pendingMicAudio = BytesBuilder(copy: false);
  final BytesBuilder _debugOutputAudio = BytesBuilder(copy: false);
  Timer? _micFlushTimer;
  static const _micFlushInterval = Duration(milliseconds: 120);

  bool _restoredTranscript = false;
  String _sessionId = DateTime.now().millisecondsSinceEpoch.toString();
  String? _geminiApiKey; // cached from bootstrap for text-chat fallback

  AymaAudioService() {
    unawaited(_restoreTranscript());
  }

  // ── Init ────────────────────────────────────────────────────────────────────

  Future<void> init() async {
    await _restoreTranscript();
    await _ensureAudioInitialized();
  }

  Future<void> _restoreTranscript() async {
    if (_restoredTranscript) return;
    _restoredTranscript = true;

    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_transcriptStorageKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw) as List<dynamic>;
      _transcript
        ..clear()
        ..addAll(decoded
            .whereType<Map<String, dynamic>>()
            .map(TranscriptLine.fromMap)
            .where((line) => line.text.isNotEmpty));

      // Rebuild context history for text-chat fallback
      _textHistory.clear();
      for (final line in _transcript) {
        _textHistory.add({
          'role': line.isUser ? 'user' : 'model',
          'text': line.text,
        });
      }
      if (_textHistory.length > 50) {
        _textHistory.removeRange(0, _textHistory.length - 50);
      }

      notifyListeners();
    } catch (_) {}
  }

  Future<void> _persistTranscript() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _transcriptStorageKey,
        jsonEncode(_transcript.map((line) => line.toMap()).toList()),
      );
    } catch (_) {}
  }

  Future<void> _ensureAudioInitialized() async {
    if (kIsWeb || _audioInitialized) return;
    if (_audioInitFuture != null) {
      await _audioInitFuture;
      return;
    }

    _audioInitFuture = () async {
      await _recorder.openRecorder();
      await _player.openPlayer();
      await _recorder.setSubscriptionDuration(const Duration(milliseconds: 80));
      _audioInitialized = true;
    }();

    try {
      await _audioInitFuture;
    } finally {
      _audioInitFuture = null;
    }
  }

  // ── Connect ─────────────────────────────────────────────────────────────────

  Future<void> connect() async {
    _manualDisconnect = false;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    if (_connectFuture != null) {
      await _connectFuture;
      return;
    }

    _connectFuture = _connect(preserveTranscript: true);
    try {
      await _connectFuture;
      _reconnectAttempts = 0;
    } catch (e, st) {
      debugPrint('[ws] connect failed: $e\n$st');
      _handleConnectionFailure();
    } finally {
      _connectFuture = null;
    }
  }

  Future<void> _connect({required bool preserveTranscript}) async {
    if (_state != SessionState.disconnected) {
      debugPrint(
          '[ws] connect requested while state=$_state, closing current transport first');
      _closeTransport();
      _setState(SessionState.disconnected);
    }

    _pendingAgentText = '';
    _pendingUserText = '';
    _debugOutputAudio.clear();
    _setState(SessionState.connecting);
    if (!preserveTranscript) {
      _transcript.clear();
      _textHistory.clear();
    }

    if (!kIsWeb) {
      final permission = await Permission.microphone.request();
      if (!permission.isGranted) {
        _setState(SessionState.disconnected);
        throw Exception('Microphone permission denied');
      }
      await _ensureAudioInitialized();
    }

    _sessionId = DateTime.now().millisecondsSinceEpoch.toString();
    final bootstrap = await BackendService.bootstrap();
    final liveWsUrl = bootstrap['websocket_url'] as String?;
    final apiKey = bootstrap['token'] as String?;
    _geminiApiKey = apiKey;
    final setup = bootstrap['setup'] as Map<String, dynamic>?;
    if (liveWsUrl == null || liveWsUrl.isEmpty || apiKey == null) {
      _setState(SessionState.disconnected);
      throw Exception('Missing Gemini Live bootstrap data');
    }

    // Embed API key as query param — works identically on web and mobile.
    final wsUri = Uri.parse(liveWsUrl).replace(queryParameters: {
      'key': apiKey,
    });

    if (kIsWeb) {
      _channel = WebSocketChannel.connect(wsUri);
    } else {
      _channel = IOWebSocketChannel.connect(
        wsUri,
        pingInterval: const Duration(seconds: 30),
      );
    }
    debugPrint('[ws] opening Gemini Live $wsUri');

    if (setup != null) {
      _channel!.sink.add(jsonEncode({'setup': setup}));
      debugPrint('[ws] full setup sent');
    } else {
      final modelName = bootstrap['model'] as String? ?? 'gemini-3.1-flash-live-preview';
      _channel!.sink.add(jsonEncode({'setup': {'model': 'models/$modelName'}}));
      debugPrint('[ws] minimal setup sent: models/$modelName');
    }

    _wsSub = _channel!.stream.listen(
      _onMessage,
      onError: (e) {
        debugPrint('[ws] error: $e');
        _handleRemoteDisconnect();
      },
      onDone: () {
        debugPrint('[ws] done');
        _handleRemoteDisconnect();
      },
    );
  }

  void disconnect({bool notify = true}) {
    debugPrint('[ws] disconnect() state=$_state notify=$notify');
    _manualDisconnect = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _closeTransport();
    _pendingAgentText = '';
    _pendingUserText = '';
    _clearPendingMicAudio();
    _state = SessionState.disconnected;
    _outputVolume = 0;
    if (notify) {
      notifyListeners();
    }
  }

  void _closeTransport() {
    _wsSub?.cancel();
    _wsSub = null;
    _channel?.sink.close();
    _channel = null;

    if (kIsWeb) {
      _webMic.stop();
      _webPlayer.stop();
    } else {
      if (_recorder.isRecording) {
        _recorder.stopRecorder();
      }
      _stopStreamPlayer();
    }
  }

  void _scheduleReconnect() {
    if (_manualDisconnect || _connectFuture != null) return;
    if (_reconnectAttempts >= 5) {
      debugPrint('[ws] reconnect limit reached');
      return;
    }
    _reconnectAttempts += 1;
    final delay = Duration(milliseconds: 800 * _reconnectAttempts);
    debugPrint('[ws] scheduling reconnect attempt=$_reconnectAttempts delay=${delay.inMilliseconds}ms');
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(delay, () {
      if (_manualDisconnect) return;
      unawaited(connect());
    });
  }

  void _handleRemoteDisconnect() {
    debugPrint('[ws] remote disconnect state=$_state');
    _closeTransport();
    _pendingAgentText = '';
    _pendingUserText = '';
    _clearPendingMicAudio();
    _setState(SessionState.disconnected);
    _scheduleReconnect();
  }

  void _handleConnectionFailure() {
    debugPrint('[ws] connection failure state=$_state');
    _closeTransport();
    _clearPendingMicAudio();
    _setState(SessionState.disconnected);
    _scheduleReconnect();
  }

  // ── WebSocket messages ───────────────────────────────────────────────────────

  void _onMessage(dynamic raw) {
    // Optimization: Skip decoding for constant resumption updates to reduce GC pressure
    if (raw is List<int>) {
      if (raw.length > 50) {
        // Search for key signatures in raw bytes without full string allocation
        // "sessionResumptionUpdate" contains "sessionR"
        // "status" contains "status"
        bool isNoisy = false;
        final len = math.min(raw.length, 100);
        for (int i = 0; i < len - 8; i++) {
          if (raw[i] == 115 && // s
              raw[i + 1] == 101 && // e
              raw[i + 2] == 115 && // s
              raw[i + 3] == 115 && // s
              raw[i + 4] == 105 && // i
              raw[i + 5] == 111 && // o
              raw[i + 6] == 110) { // n
            isNoisy = true;
            break;
          }
          if (raw[i] == 115 && // s
              raw[i + 1] == 116 && // t
              raw[i + 2] == 97 && // a
              raw[i + 3] == 116 && // t
              raw[i + 4] == 117 && // u
              raw[i + 5] == 115) { // s
            isNoisy = true;
            break;
          }
        }
        if (isNoisy) return;
      }
    }

    final String decoded;
    if (raw is String) {
      decoded = raw;
    } else if (raw is List<int>) {
      decoded = utf8.decode(raw);
    } else if (raw is Uint8List) {
      decoded = utf8.decode(raw);
    } else {
      return;
    }

    if (decoded.contains('sessionResumptionUpdate') ||
        decoded.contains('"status":')) {
      return;
    }

    final Map<String, dynamic> msg;
    try {
      msg = jsonDecode(decoded) as Map<String, dynamic>;
    } catch (e) {
      debugPrint('[ws] json decode failed: $e');
      return;
    }

    if (msg.containsKey('setupComplete')) {
      debugPrint('[ws] setupComplete');
      _setState(SessionState.ready);
      _startRecorderAndBegin();
      return;
    }

    final serverContent = msg['serverContent'] as Map<String, dynamic>?;
    if (serverContent != null) {
      final interrupted = (serverContent['interrupted'] as bool?) ?? false;
      if (interrupted) {
        debugPrint('[ws] interrupted — stopping playback for barge-in');
        if (kIsWeb) {
          _webPlayer.stop();
        } else {
          _stopStreamPlayer();
        }
        _pendingAgentText = ''; // Clear pending text as it was interrupted
        _setState(SessionState.listening);
        return;
      }

      final modelTurn = serverContent['modelTurn'] as Map<String, dynamic>?;
      if (modelTurn != null) {
        _setState(SessionState.speaking);
        final parts = (modelTurn['parts'] as List<dynamic>? ?? [])
            .whereType<Map<String, dynamic>>();
        for (final part in parts) {
          final inlineData = part['inlineData'] as Map<String, dynamic>?;
          if (inlineData != null) {
            final mimeType = inlineData['mimeType'] as String?;
            final data = inlineData['data'] as String?;
            if (data != null && (mimeType?.contains('audio') ?? false)) {
              final pcmData = base64Decode(data);
              _captureDebugAudioDump(pcmData, mimeType: mimeType!);
              _playPcm(pcmData, mimeType: mimeType);
            }
          }

          final text = part['text'] as String?;
          final isThought = (part['thought'] as bool?) ?? false;
          if (text != null && text.trim().isNotEmpty && !isThought) {
            _setPendingAgentText(text);
          }
        }
      }

      final outTx = serverContent['outputTranscription'] as Map<String, dynamic>?;
      if (outTx != null) {
        final text = outTx['text'] as String?;
        if (text != null && text.isNotEmpty) {
          debugPrint('[ws] model transcription: $text');
          _setPendingAgentText(text);
        }
      }

      final inTx = serverContent['inputTranscription'] as Map<String, dynamic>?;
      if (inTx != null) {
        final text = inTx['text'] as String?;
        if (text != null && text.isNotEmpty) {
          _addTranscript(text, isUser: true);
          _pendingUserText = '';
        }
      }

      final turnComplete = (serverContent['turnComplete'] as bool?) ?? false;
      if (turnComplete) {
        unawaited(_commitTurnToBackend());
        _flushPendingUserText();
        _flushPendingAgentText();
        if (!kIsWeb) {
          _outputVolume = 0;
        }
        _setState(SessionState.listening);
      }
      return;
    }

    final toolCall = msg['toolCall'] as Map<String, dynamic>?;
    if (toolCall != null) {
      final functionCalls = (toolCall['functionCalls'] as List<dynamic>? ?? [])
          .whereType<Map<String, dynamic>>()
          .toList();
      if (functionCalls.isNotEmpty) {
        unawaited(_handleToolCall(functionCalls));
      }
      return;
    }

    if (msg.containsKey('goAway')) {
      debugPrint('[ws] goAway received from Gemini Live');
      _handleRemoteDisconnect();
      return;
    }

    if (msg.containsKey('status')) return;
  }

  Future<void> _commitTurnToBackend() async {
    final userText = _pendingUserText.trim();
    final agentText = _pendingAgentText.trim();
    if (userText.isEmpty && agentText.isEmpty) return;

    final messages = <Map<String, String>>[
      if (userText.isNotEmpty) {'role': 'user', 'text': userText},
      if (agentText.isNotEmpty) {'role': 'model', 'text': agentText},
    ];
    try {
      await BackendService.postTurn(
        sessionId: _sessionId,
        messages: messages,
      );
    } catch (e) {
      debugPrint('[ws] failed to post turn: $e');
    }
  }

  Future<void> _handleToolCall(List<Map<String, dynamic>> functionCalls) async {
    final responses = <Map<String, dynamic>>[];
    for (final call in functionCalls) {
      final name = call['name'] as String? ?? '';
      final id = call['id'] as String? ?? '';
      final args = call['args'] as Map<String, dynamic>? ?? {};
      String output;
      if (name == 'add_followup_question') {
        output = await _execAddFollowup(args);
      } else if (name == 'get_current_time') {
        output = DateTime.now().toIso8601String();
      } else {
        output = 'Tool $name is not available.';
      }
      responses.add({'id': id, 'name': name, 'response': {'output': output}});
    }
    if (_channel == null || _state == SessionState.disconnected) return;
    _channel!.sink.add(jsonEncode({'toolResponse': {'functionResponses': responses}}));
  }

  Future<String> _execAddFollowup(Map<String, dynamic> args) async {
    final question = (args['question'] as String? ?? '').trim();
    if (question.isEmpty) return 'skipped: empty question';
    try {
      await FirestoreService.addFollowupQuestion(question, sessionId: _sessionId);
      debugPrint('[followup] queued: $question');
      return 'noted';
    } catch (e) {
      debugPrint('[followup] error: $e');
      return 'error: $e';
    }
  }

  void _setPendingAgentText(String text) {
    final normalized = text.trim();
    if (normalized.isEmpty) return;
    if (_pendingAgentText.isEmpty) {
      _pendingAgentText = normalized;
      return;
    }
    if (_pendingAgentText == normalized ||
        _pendingAgentText.endsWith(normalized)) {
      return;
    }
    if (normalized.startsWith(_pendingAgentText)) {
      _pendingAgentText = normalized;
      return;
    }
    _pendingAgentText = '$_pendingAgentText $normalized'.trim();
  }

  void _flushPendingAgentText() {
    final t = _pendingAgentText.trim();
    if (t.isNotEmpty) {
      _addTranscript(t, isUser: false);
    }
    _pendingAgentText = '';
  }

  void _flushPendingUserText() {
    final t = _pendingUserText.trim();
    if (t.isNotEmpty) {
      _addTranscript(t, isUser: true);
    }
    _pendingUserText = '';
  }

  // ── Recorder ────────────────────────────────────────────────────────────────

  Future<void> _startRecorderAndBegin() async {
    await _startRecorder();
  }

  Future<void> _startRecorder() async {
    debugPrint('[audio] start recorder');
    if (kIsWeb) {
      await _webMic.start((pcm16) {
        _inputVolume =
            0.5; // web doesn't give dB; use flat value while speaking
        _sendAudio(pcm16);
        notifyListeners();
      });
    } else {
      await _recorder.startRecorder(
        toStream: _recorderSink(),
        codec: Codec.pcm16,
        numChannels: 1,
        sampleRate: 16000,
        // VOICE_COMMUNICATION enables hardware AEC on Android
        // (prevents mic picking up speaker output)
        audioSource: AudioSource.voice_communication,
      );
      _recorder.onProgress?.listen((e) {
        final vol = ((e.decibels ?? -60) + 60) / 60;
        _inputVolume = vol;

        // Lightweight VAD: volume threshold + debounce
        if (vol > 0.22) {
          _userTalking = true;
          _userTalkingDebounce?.cancel();
          _userTalkingDebounce = Timer(const Duration(milliseconds: 500), () {
            _userTalking = false;
            notifyListeners();
          });
        }
        notifyListeners();
      });
    }
  }

  StreamSink<Uint8List> _recorderSink() {
    final ctrl = StreamController<Uint8List>();
    ctrl.stream.listen((data) {
      if (!_muted) _bufferAudio(data);
    });
    return ctrl.sink;
  }

  void _bufferAudio(Uint8List pcm) {
    if (_channel == null || _state == SessionState.disconnected) return;
    if (_muted) return;
    // Keep sending mic even while speaking — Gemini Live's server-side VAD
    // detects user speech and sends an `interrupted` event to stop playback.

    _pendingMicAudio.add(pcm);
    _micFlushTimer ??= Timer(_micFlushInterval, _flushBufferedAudio);
  }

  void _flushBufferedAudio() {
    _micFlushTimer = null;

    if (_pendingMicAudio.length == 0) return;
    if (_channel == null || _state == SessionState.disconnected) {
      _clearPendingMicAudio();
      return;
    }
    if (_muted) {
      _clearPendingMicAudio();
      return;
    }

    final pcm = _pendingMicAudio.takeBytes();
    _sendAudio(pcm);
  }

  void _clearPendingMicAudio() {
    _micFlushTimer?.cancel();
    _micFlushTimer = null;
    if (_pendingMicAudio.length > 0) {
      _pendingMicAudio.clear();
    }
  }

  // ── Player ──────────────────────────────────────────────────────────────────

  // Compute RMS amplitude of a PCM16 LE buffer, normalised to 0.0–1.0.
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

  ({int sampleRate, int channels}) _parsePcmConfig(String mimeType) {
    final rateMatch =
        RegExp(r'rate=(\d+)', caseSensitive: false).firstMatch(mimeType);
    final channelsMatch =
        RegExp(r'channels=(\d+)', caseSensitive: false).firstMatch(mimeType);
    final sampleRate = int.tryParse(rateMatch?.group(1) ?? '') ?? 24000;
    final channels = int.tryParse(channelsMatch?.group(1) ?? '') ?? 1;
    return (sampleRate: sampleRate, channels: channels);
  }

  void _captureDebugAudioDump(Uint8List data, {required String mimeType}) {}

  void _playPcm(Uint8List data, {required String mimeType}) {
    if (_speakerMuted) return;
    final pcmConfig = _parsePcmConfig(mimeType);
    if (kIsWeb) {
      _outputVolume = _pcmRms(data);
      _webPlayer.play(data);
    } else {
      _outputVolume = _pcmRms(data);
      if (!_playerStreaming ||
          _playerSampleRate != pcmConfig.sampleRate ||
          _playerChannels != pcmConfig.channels) {
        // Config changed or not yet streaming — (re)start stream player
        _stopStreamPlayer();
        _playerSampleRate = pcmConfig.sampleRate;
        _playerChannels = pcmConfig.channels;
        unawaited(_startStreamPlayer());
      }
      // Feed PCM chunk directly — plays immediately without waiting for turnComplete
      _feedAudioWhenReady(data);
    }
  }

  void _feedAudioWhenReady(Uint8List data) {
    final sink = _player.uint8ListSink;
    if (sink != null) {
      sink.add(data);
    } else {
      // If sink isn't ready, wait a tiny bit and retry once.
      // This can happen during the very first chunk while startPlayerFromStream is async.
      Future.delayed(const Duration(milliseconds: 25), () {
        _player.uint8ListSink?.add(data);
      });
    }
  }

  Future<void> _startStreamPlayer() async {
    if (_playerStreaming) return;
    _playerStreaming = true;
    try {
      await _player.startPlayerFromStream(
        codec: Codec.pcm16,
        interleaved: false,
        sampleRate: _playerSampleRate,
        numChannels: _playerChannels,
        bufferSize: 8192,
      );
    } catch (e) {
      debugPrint('[player] stream start error: $e');
      _playerStreaming = false;
    }
  }

  void _stopStreamPlayer() {
    if (!_playerStreaming && _player.isStopped) return;
    try {
      _player.stopPlayer();
    } catch (_) {}
    _playerStreaming = false;
  }

  // ── Send helpers ─────────────────────────────────────────────────────────────

  void _sendAudio(Uint8List pcm) {
    if (_channel == null || _state == SessionState.disconnected) return;
    if (_muted) return;
    // Always send mic — Gemini Live's server-side VAD handles barge-in
    // and sends `interrupted` when user speech is detected.
    final b64 = base64Encode(pcm);
    final payload = {
      'realtimeInput': {
        'audio': {'mimeType': 'audio/pcm;rate=16000', 'data': b64}
      },
    };
    _channel!.sink.add(jsonEncode(payload));
  }

  Future<void> sendText(
    String text, {
    List<Map<String, String>> attachments = const [],
  }) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty && attachments.isEmpty) return;
    final attachmentSummary = attachments.isEmpty
        ? ''
        : '\n\nShared attachments:\n${attachments.map((a) => '- ${a['kind'] ?? 'file'}: ${a['filename'] ?? a['url'] ?? 'attachment'}').join('\n')}';
    final historyText = trimmed.isEmpty ? attachmentSummary.trim() : '$trimmed$attachmentSummary';

    final liveSessionActive =
        _state != SessionState.disconnected && _channel != null;

    // As per user requirement, text messages always use the text chat REST API
    // but with the full current context history.
    _addTranscript(trimmed.isEmpty ? '[Shared ${attachments.length} attachment${attachments.length == 1 ? '' : 's'}]' : trimmed,
        isUser: true, historyText: historyText, attachments: attachments);

    if (!liveSessionActive) {
      _setState(SessionState.thinking);
    }

    try {
      final requestText = trimmed.isEmpty ? historyText : trimmed;
      final reply = await _geminiTextChat(requestText);
      if (reply.isNotEmpty) {
        _addTranscript(reply, isUser: false);
      }
      unawaited(_commitTurnToBackend());
    } catch (e) {
      debugPrint('[text-chat] error: $e');
    } finally {
      if (!liveSessionActive) {
        _setState(SessionState.disconnected);
      } else {
        // If live was active, just notify to refresh UI but don't force a state change
        // that might restart the recorder if we were in a different state.
        notifyListeners();
      }
    }
  }

  // ── Controls ─────────────────────────────────────────────────────────────────

  void toggleMute() {
    _muted = !_muted;
    notifyListeners();
  }

  void toggleSpeaker() {
    _speakerMuted = !_speakerMuted;
    if (_speakerMuted) {
      if (kIsWeb) {
        _webPlayer.stop();
      } else {
        _stopStreamPlayer();
      }
    }
    notifyListeners();
  }

  // ── Helpers ──────────────────────────────────────────────────────────────────

  void _setState(SessionState s) {
    if (_state != s) {
      debugPrint('[ws] state $_state -> $s');
    }
    _state = s;
    if (s != SessionState.speaking) _outputVolume = 0;
    notifyListeners();
  }

  void _addTranscript(String text,
      {required bool isUser,
      String? historyText,
      List<Map<String, dynamic>>? attachments}) {
    final normalized = text.trim();
    if (normalized.isEmpty && (attachments == null || attachments.isEmpty)) {
      return;
    }

    if (_transcript.isNotEmpty) {
      final last = _transcript.last;
      final isDuplicate = last.isUser == isUser &&
          last.text.trim() == normalized &&
          (last.attachments?.length ?? 0) == (attachments?.length ?? 0) &&
          DateTime.now().difference(last.time) < const Duration(seconds: 3);
      if (isDuplicate) {
        return;
      }
    }

    _transcript.add(TranscriptLine(
      normalized,
      isUser: isUser,
      attachments: attachments,
    ));

    // Keep context history in sync for text API calls
    _textHistory.add({
      'role': isUser ? 'user' : 'model',
      'text': (historyText ?? normalized).trim(),
    });
    if (_textHistory.length > 50) {
      _textHistory.removeAt(0);
    }

    unawaited(_persistTranscript());
    notifyListeners();
  }

  Future<String> _geminiTextChat(String message) async {
    final key = _geminiApiKey;
    if (key == null || key.isEmpty) return '';

    final contents = [
      for (final h in _textHistory.sublist(0, math.max(0, _textHistory.length - 1)))
        {'role': h['role'], 'parts': [{'text': h['text']}]},
      {'role': 'user', 'parts': [{'text': message}]},
    ];

    final res = await http
        .post(
          Uri.parse(
              'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=$key'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'contents': contents}),
        )
        .timeout(const Duration(seconds: 30));

    if (res.statusCode != 200) return '';
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    final candidates = body['candidates'] as List<dynamic>? ?? [];
    if (candidates.isEmpty) return '';
    final parts = (candidates.first['content']?['parts'] as List<dynamic>? ?? []);
    return parts.map((p) => (p['text'] as String? ?? '')).join(' ').trim();
  }

  @override
  void dispose() {
    _reconnectTimer?.cancel();
    disconnect(notify: false);
    if (!kIsWeb) {
      if (_audioInitialized) {
        _recorder.closeRecorder();
        _player.closePlayer();
      }
    }
    super.dispose();
  }
}
