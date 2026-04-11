import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter_sound/flutter_sound.dart';
import 'package:logger/logger.dart' show Level;
import 'package:permission_handler/permission_handler.dart';
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'auth_storage.dart';
import 'backend_service.dart';
import '../env.dart';
import 'audio_dump_stub.dart'
    if (dart.library.io) 'audio_dump_io.dart';
import 'web_audio_stub.dart'
    if (dart.library.html) 'web_audio_impl.dart';

// ignore_for_file: deprecated_member_use

enum SessionState { disconnected, connecting, ready, listening, thinking, speaking }

class TranscriptLine {
  final String text;
  final bool isUser;
  final DateTime time;
  TranscriptLine(this.text, {required this.isUser}) : time = DateTime.now();
}

class AymaAudioService extends ChangeNotifier {
  WebSocketChannel? _channel;

  // Mobile audio (flutter_sound) — skipped on web
  final _recorder = FlutterSoundRecorder(logLevel: Level.nothing);
  final _player   = FlutterSoundPlayer(logLevel: Level.nothing);
  bool  _playerStarted  = false;
  final BytesBuilder _turnOutputAudio = BytesBuilder(copy: false);
  int _playerSampleRate = 24000;
  int _playerChannels = 1;

  // Web audio (dart:html Web Audio API) — skipped on mobile
  final _webMic    = WebMicCapture();
  final _webPlayer = WebPcmPlayer();

  StreamSubscription? _wsSub;

  SessionState _state = SessionState.disconnected;
  SessionState get state => _state;

  double _inputVolume  = 0;
  double _outputVolume = 0;
  double get inputVolume  => _inputVolume;
  double get outputVolume => _outputVolume;

  bool _muted        = false;
  bool _speakerMuted = false;
  bool get muted        => _muted;
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

  bool   _firstContentSent = false;
  bool _audioInitialized = false;
  Future<void>? _audioInitFuture;
  Future<void>? _connectFuture;
  String? _lastWsUrl;
  Timer? _reconnectTimer;
  bool _manualDisconnect = false;
  int _reconnectAttempts = 0;
  final BytesBuilder _pendingMicAudio = BytesBuilder(copy: false);
  final BytesBuilder _debugOutputAudio = BytesBuilder(copy: false);
  Timer? _micFlushTimer;
  static const _micFlushInterval = Duration(milliseconds: 120);
  static const _debugDumpTargetBytes = 24 * 2 * 2000;
  bool _debugAudioDumpWritten = false;

  // ── Init ────────────────────────────────────────────────────────────────────

  Future<void> init() async {
    await _ensureAudioInitialized();
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

  Future<void> connect(String wsUrl) async {
    _lastWsUrl = wsUrl;
    _manualDisconnect = false;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    if (_connectFuture != null) {
      await _connectFuture;
      return;
    }

    _connectFuture = _connect(wsUrl, preserveTranscript: true);
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

  Future<void> _connect(String wsUrl, {required bool preserveTranscript}) async {
    if (_state != SessionState.disconnected) {
      debugPrint('[ws] connect requested while state=$_state, closing current transport first');
      _closeTransport();
      _setState(SessionState.disconnected);
    }

    _firstContentSent = false;
    _pendingAgentText = '';
    _pendingUserText = '';
    _debugOutputAudio.clear();
    _turnOutputAudio.clear();
    _debugAudioDumpWritten = false;
    _setState(SessionState.connecting);
    if (!preserveTranscript) {
      _transcript.clear();
      _textHistory.clear();
    }

    var token = AuthStorage.accessToken;
    if (token == null || token.isEmpty) {
      final refreshed = await BackendService.refreshAuthToken();
      token = refreshed ? AuthStorage.accessToken : null;
    } else {
      final refreshed = await BackendService.refreshAuthToken();
      if (refreshed) {
        token = AuthStorage.accessToken;
      }
    }
    if (token == null || token.isEmpty) {
      _setState(SessionState.disconnected);
      throw Exception('Missing auth session');
    }

    if (!kIsWeb) {
      final permission = await Permission.microphone.request();
      if (!permission.isGranted) {
        _setState(SessionState.disconnected);
        throw Exception('Microphone permission denied');
      }
      await _ensureAudioInitialized();
    }

    final baseUri = Uri.parse(wsUrl);
    final wsUri = baseUri.replace(
      queryParameters: {
        ...baseUri.queryParameters,
        'token': token,
      },
    );
    _channel = WebSocketChannel.connect(wsUri);
    debugPrint('[ws] opening $wsUri');

    _channel!.sink.add(jsonEncode({
      'setup': {'run_id': const Uuid().v4()},
    }));
    debugPrint('[ws] setup sent');

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
      if (!_player.isStopped) {
        _player.stopPlayer();
      }
      _playerStarted = false;
      _turnOutputAudio.clear();
    }
  }

  void _scheduleReconnect() {
    if (_manualDisconnect || _lastWsUrl == null || _connectFuture != null) return;
    if (_reconnectAttempts >= 5) {
      debugPrint('[ws] reconnect limit reached');
      return;
    }
    _reconnectAttempts += 1;
    final delay = Duration(milliseconds: 800 * _reconnectAttempts);
    debugPrint('[ws] scheduling reconnect attempt=$_reconnectAttempts delay=${delay.inMilliseconds}ms');
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(delay, () {
      final wsUrl = _lastWsUrl;
      if (wsUrl == null || _manualDisconnect) return;
      unawaited(connect(wsUrl));
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
    final Map<String, dynamic> msg;
    try { msg = jsonDecode(raw as String) as Map<String, dynamic>; }
    catch (_) { return; }

    if (msg.containsKey('setupComplete')) {
      debugPrint('[ws] setupComplete');
      _setState(SessionState.ready);
      _startRecorderAndBegin();
      return;
    }

    if (msg.containsKey('status')) return;

    final sc = msg['serverContent'] as Map<String, dynamic>?;
    final interrupted = (sc?['interrupted'] as bool?) ?? (msg['interrupted'] as bool?) ?? false;
    if (interrupted) {
      debugPrint('[ws] interrupted');
      if (kIsWeb) { _webPlayer.stop(); }
      else        { _player.stopPlayer(); _playerStarted = false; _turnOutputAudio.clear(); }
      _flushPendingAgentText();
      _setState(SessionState.listening);
      return;
    }

    final turnComplete =
        (sc?['turnComplete'] as bool?) ??
        (sc?['turn_complete'] as bool?) ??
        (msg['turnComplete'] as bool?) ??
        (msg['turn_complete'] as bool?) ??
        false;

    final outTx =
        (sc?['outputTranscription'] as Map<String, dynamic>?) ??
        (sc?['output_transcription'] as Map<String, dynamic>?) ??
        (msg['output_transcription'] as Map<String, dynamic>?) ??
        (msg['outputTranscription'] as Map<String, dynamic>?);
    final inTx =
        (sc?['inputTranscription'] as Map<String, dynamic>?) ??
        (sc?['input_transcription'] as Map<String, dynamic>?) ??
        (msg['input_transcription'] as Map<String, dynamic>?) ??
        (msg['inputTranscription'] as Map<String, dynamic>?);

    final modelTurn = sc?['modelTurn'] as Map<String, dynamic>?;
    final content = modelTurn ?? (msg['content'] as Map<String, dynamic>?);
    final hasOutputTranscription =
        (outTx?['text'] as String?)?.trim().isNotEmpty ?? false;
    final agentResponding = content != null || hasOutputTranscription;

    if (agentResponding && _pendingUserText.trim().isNotEmpty) {
      _flushPendingUserText();
    }

    if (content != null) {
      _setState(SessionState.speaking);
      final parts = content['parts'] as List<dynamic>? ?? [];
      for (final part in parts) {
        final p = part as Map<String, dynamic>;
        final inline =
            (p['inlineData'] as Map<String, dynamic>?) ??
            (p['inline_data'] as Map<String, dynamic>?);
        if (inline != null) {
          final mime =
              (inline['mimeType'] as String?) ??
              (inline['mime_type'] as String?) ??
              '';
          final data = inline['data'] as String?;
          if (data != null && mime.contains('audio')) {
            final pcmData = base64Decode(data);
            _captureDebugAudioDump(pcmData, mimeType: mime);
            _playPcm(pcmData, mimeType: mime);
          }
        }

        final text = p['text'] as String?;
        final isThought = (p['thought'] as bool?) ?? false;
        if (text != null && text.trim().isNotEmpty && !hasOutputTranscription && !isThought) {
          _setPendingAgentText(text);
        }
      }
    }

    if (outTx != null) {
      final text = outTx['text'] as String? ?? '';
      if (text.trim().isNotEmpty) {
        _setPendingAgentText(text);
      }
    }

    if (inTx != null) {
      final text = inTx['text'] as String? ?? '';
      if (text.trim().isNotEmpty) {
        // gemini-3.1 delivers complete utterance in one shot — add immediately.
        // Deduplification in _addTranscript prevents doubles if a turnComplete
        // also carries the same text.
        _addTranscript(text, isUser: true);
        _pendingUserText = '';
      }
    }

    if (turnComplete) {
      _flushPendingUserText();
      _flushPendingAgentText();
      if (kIsWeb) {
        _setState(SessionState.listening);
      } else {
        unawaited(_playBufferedTurnAudio());
      }
    }
  }

  void _setPendingAgentText(String text) {
    final normalized = text.trim();
    if (normalized.isEmpty) return;
    if (_pendingAgentText.isEmpty) {
      _pendingAgentText = normalized;
      return;
    }
    if (_pendingAgentText == normalized || _pendingAgentText.endsWith(normalized)) {
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
        _inputVolume = 0.5; // web doesn't give dB; use flat value while speaking
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
        _inputVolume = ((e.decibels ?? -60) + 60) / 60;
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
    if (_muted || _state == SessionState.speaking) return;

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
    if (_muted || _state == SessionState.speaking) {
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
    final rateMatch = RegExp(r'rate=(\d+)', caseSensitive: false).firstMatch(mimeType);
    final channelsMatch = RegExp(r'channels=(\d+)', caseSensitive: false).firstMatch(mimeType);
    final sampleRate = int.tryParse(rateMatch?.group(1) ?? '') ?? 24000;
    final channels = int.tryParse(channelsMatch?.group(1) ?? '') ?? 1;
    return (sampleRate: sampleRate, channels: channels);
  }

  void _captureDebugAudioDump(Uint8List data, {required String mimeType}) {
    if (kIsWeb || !Env.debugAudioDumpEnabled || _debugAudioDumpWritten) {
      return;
    }

    final remaining = _debugDumpTargetBytes - _debugOutputAudio.length;
    if (remaining <= 0) {
      _writeDebugAudioDump(mimeType);
      return;
    }

    if (data.length <= remaining) {
      _debugOutputAudio.add(data);
    } else {
      _debugOutputAudio.add(data.sublist(0, remaining));
    }

    if (_debugOutputAudio.length >= _debugDumpTargetBytes) {
      _writeDebugAudioDump(mimeType);
    }
  }

  Future<void> _writeDebugAudioDump(String mimeType) async {
    if (_debugAudioDumpWritten || kIsWeb || !Env.debugAudioDumpEnabled) {
      return;
    }
    _debugAudioDumpWritten = true;

    try {
      final pcmBytes = _debugOutputAudio.takeBytes();
      final pcmConfig = _parsePcmConfig(mimeType);
      final outputPath = await dumpAudioDebugCapture(
        bytes: pcmBytes,
        mimeType: mimeType,
        sampleRate: pcmConfig.sampleRate,
        channels: pcmConfig.channels,
      );
      if (outputPath != null) {
        debugPrint('[audio-debug] dumped Gemini output audio to $outputPath');
        debugPrint('[audio-debug] metadata written to $outputPath.txt');
      }
    } catch (e, st) {
      debugPrint('[audio-debug] failed to dump output audio: $e\n$st');
    }
  }

  void _playPcm(Uint8List data, {required String mimeType}) {
    if (_speakerMuted) return;
    final pcmConfig = _parsePcmConfig(mimeType);
    if (kIsWeb) {
      _outputVolume = _pcmRms(data);
      _webPlayer.play(data);
    } else {
      if (_playerStarted &&
          (_playerSampleRate != pcmConfig.sampleRate ||
              _playerChannels != pcmConfig.channels)) {
        _restartPlayer();
      }
      _playerSampleRate = pcmConfig.sampleRate;
      _playerChannels = pcmConfig.channels;
      _outputVolume = _pcmRms(data);
      _turnOutputAudio.add(data);
    }
  }

  Future<void> _playBufferedTurnAudio() async {
    if (_speakerMuted || _turnOutputAudio.length == 0) {
      _turnOutputAudio.clear();
      _setState(SessionState.listening);
      return;
    }

    final buffered = _turnOutputAudio.takeBytes();
    try {
      if (!_player.isStopped) {
        await _player.stopPlayer();
      }
      _playerStarted = false;

      await _player.startPlayer(
        fromDataBuffer: buffered,
        codec: Codec.pcm16,
        sampleRate: _playerSampleRate,
        numChannels: _playerChannels,
        whenFinished: () {
          _outputVolume = 0;
          _setState(SessionState.listening);
        },
      );
    } catch (e, st) {
      debugPrint('[player] buffered turn playback error: $e\n$st');
      _setState(SessionState.listening);
    }
  }

  // ── Send helpers ─────────────────────────────────────────────────────────────

  void _sendAudio(Uint8List pcm) {
    if (_channel == null || _state == SessionState.disconnected) return;
    if (_muted) return;
    // Don't send mic audio while agent is speaking — avoids echo feedback loop
    // and reduces unnecessary bandwidth while output is playing
    if (_state == SessionState.speaking) return;
    final b64 = base64Encode(pcm);
    final Map<String, dynamic> payload;
    if (!_firstContentSent) {
      _firstContentSent = true;
      payload = {
        'live_request': {
          'blob': {'mimeType': 'audio/pcm;rate=16000', 'data': b64}
        },
      };
    } else {
      payload = {'blob': {'mimeType': 'audio/pcm;rate=16000', 'data': b64}};
    }
    _channel!.sink.add(jsonEncode(payload));
  }

  Future<void> sendText(
    String text, {
    List<Map<String, String>> attachments = const [],
  }) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    final attachmentSummary = attachments.isEmpty
        ? ''
        : '\n\nShared attachments:\n${attachments.map((a) => '- ${a['kind'] ?? 'file'}: ${a['filename'] ?? a['url'] ?? 'attachment'}').join('\n')}';
    final historyText = '$trimmed$attachmentSummary';

    if (attachments.isEmpty &&
        _state != SessionState.disconnected &&
        _channel != null) {
      // Live session active — send over WebSocket
      final Map<String, dynamic> payload;
      final parts = <Map<String, dynamic>>[
        if (trimmed.isNotEmpty) {'text': trimmed},
      ];
      if (!_firstContentSent) {
        _firstContentSent = true;
        payload = {
          'live_request': {
            'content': {'role': 'user', 'parts': parts},
            if (attachments.isNotEmpty) 'attachments': attachments,
          },
        };
      } else {
        payload = {
          'content': {'role': 'user', 'parts': parts},
          if (attachments.isNotEmpty) 'attachments': attachments,
        };
      }
      _channel!.sink.add(jsonEncode(payload));
      _pendingUserText = historyText;
      _flushPendingUserText();
    } else {
      // No live session — use text-only fallback model
      _addTranscript(trimmed, isUser: true);
      _textHistory.add({'role': 'user', 'text': historyText});
      _setState(SessionState.thinking);
      try {
        final response = await BackendService.post(
          '/api/chat/text',
          {
            'message': trimmed,
            'history': _textHistory,
            'attachments': attachments,
          },
        ) as Map<String, dynamic>;
        final reply = (response['reply'] as String? ?? '').trim();
        if (reply.isNotEmpty) {
          _addTranscript(reply, isUser: false);
          _textHistory.add({'role': 'model', 'text': reply});
        }
      } catch (e) {
        debugPrint('[text-chat] error: $e');
      } finally {
        _setState(SessionState.disconnected);
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
      if (kIsWeb) { _webPlayer.stop(); }
      else        { _player.stopPlayer(); _playerStarted = false; _turnOutputAudio.clear(); }
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

  void _addTranscript(String text, {required bool isUser}) {
    final normalized = text.trim();
    if (normalized.isEmpty) return;

    if (_transcript.isNotEmpty) {
      final last = _transcript.last;
      final isDuplicate = last.isUser == isUser &&
          last.text.trim() == normalized &&
          DateTime.now().difference(last.time) < const Duration(seconds: 3);
      if (isDuplicate) {
        return;
      }
    }

    _transcript.add(TranscriptLine(normalized, isUser: isUser));
    notifyListeners();
  }

  void _restartPlayer() {
    try {
      _player.stopPlayer();
    } catch (_) {}
    _playerStarted = false;
    _turnOutputAudio.clear();
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
