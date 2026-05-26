import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'audio_recorder_service.dart';
import 'audio_streamer_service.dart';
import 'backend_service.dart';
import 'firestore_service.dart';
import 'gemini_live_client.dart';

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

// Orchestrates GeminiLiveClient + AudioRecorderService + AudioStreamerService,
// mirroring how useLiveAPI hook + ControlTray wire together in the React reference.
class AymaAudioService extends ChangeNotifier {
  static const _transcriptStorageKey = 'ayma.chat.transcript';

  final _client = GeminiLiveClient();
  final _recorder = AudioRecorderService();
  final _streamer = AudioStreamerService();

  final List<StreamSubscription<dynamic>> _subs = [];

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

  bool _restoredTranscript = false;
  String _pendingTurnUser = '';
  String _pendingTurnModel = '';
  Timer? _persistDebounce;
  static const int _maxTranscriptLines = 180;

  String? _geminiApiKey;
  String? _systemPrompt;
  String _sessionId = DateTime.now().millisecondsSinceEpoch.toString();

  Future<void>? _connectFuture;

  DateTime _lastMeterUiUpdate = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastUserVoiceAt = DateTime.fromMillisecondsSinceEpoch(0);

  final BytesBuilder _pendingMicAudio = BytesBuilder(copy: false);
  Timer? _micFlushTimer;
  static const _micFlushInterval = Duration(milliseconds: 120);

  AymaAudioService() {
    unawaited(_restoreTranscript());
    _wireClientStreams();
    _wireRecorderStreams();
  }

  Future<void> init() async {
    await _restoreTranscript();
  }

  // ── Wire GeminiLiveClient events → session state (mirrors use-live-api.ts) ──

  void _wireClientStreams() {
    // setupComplete → start mic (mirrors ControlTray useEffect on `connected`)
    _subs.add(_client.setupCompleteStream.listen((_) {
      _setState(SessionState.ready);
      unawaited(_recorder.start());
      _setState(SessionState.listening);
    }));

    // audio → streamer (mirrors onAudio → audioStreamer.addPCM16 in useLiveAPI)
    _subs.add(_client.audioStream.listen((chunk) {
      if (_speakerMuted) return;
      _setState(SessionState.speaking);
      _outputVolume = _pcmRms(chunk.data);
      unawaited(_streamer.addPcm16(chunk.data, mimeType: chunk.mimeType));
      _notifyMetersThrottled();
    }));

    // interrupted → stop streamer (mirrors stopAudioStreamer in useLiveAPI)
    _subs.add(_client.interruptedStream.listen((_) {
      _streamer.stop();
      _outputVolume = 0;
      final userText = _pendingTurnUser.trim();
      if (userText.isNotEmpty) {
        _addTranscript(userText, isUser: true, allowRecentDuplicate: true);
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
    }));

    _subs.add(_client.turnCompleteStream.listen((_) {
      final userText = _pendingTurnUser.trim();
      if (userText.isNotEmpty) {
        _addTranscript(userText, isUser: true, allowRecentDuplicate: true);
      }
      final modelText = _pendingTurnModel.trim();
      if (modelText.isNotEmpty) {
        _addTranscript(modelText, isUser: false, allowRecentDuplicate: true);
      }
      unawaited(_commitTurnToBackend());
      _setState(SessionState.listening);
    }));

    _subs.add(_client.toolCallStream.listen((calls) {
      unawaited(_handleToolCalls(calls));
    }));

    _subs.add(_client.disconnectedStream.listen((_) {
      _clearPendingMicAudio();
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
      // Web emits raw PCM RMS (threshold 0.03); native emits normalised dB (0.20)
      _userTalking = kIsWeb ? vol > 0.03 : vol > 0.20;
      if (_userTalking) _lastUserVoiceAt = DateTime.now();
      _notifyMetersThrottled();
    }));
  }

  // ── Mic audio buffering + echo suppression ────────────────────────────────────

  void _bufferAudio(Uint8List pcm) {
    if (!_client.isConnected || _state == SessionState.disconnected || _muted) return;
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

    final speaking = _state == SessionState.speaking;
    final recentVoice =
        DateTime.now().difference(_lastUserVoiceAt) < const Duration(milliseconds: 900);
    if (speaking) {
      if (!_userTalking && !recentVoice) return;
      final likelyEcho = _outputVolume > 0.07 && _rawInputVolume < 0.09;
      if (likelyEcho) return;
    }

    _client.sendRealtimeAudio(pcm);
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
    if (_state != SessionState.disconnected) {
      _disconnectTransport();
      _setState(SessionState.disconnected);
    }

    _setState(SessionState.connecting);
    _sessionId = DateTime.now().millisecondsSinceEpoch.toString();

    if (!kIsWeb) {
      final permission = await Permission.microphone.request();
      if (!permission.isGranted) {
        _setState(SessionState.disconnected);
        throw Exception('Microphone permission denied');
      }
    }

    final bootstrap = await BackendService.bootstrap();
    final liveWsUrl = bootstrap['websocket_url'] as String?;
    final apiKey = bootstrap['token'] as String?;
    final setup = bootstrap['setup'] as Map<String, dynamic>?;

    _geminiApiKey = apiKey;
    _systemPrompt = (setup?['system_instruction']?['parts'] as List<dynamic>?)
        ?.map((p) => p['text'] as String? ?? '')
        .join('');

    if (liveWsUrl == null || liveWsUrl.isEmpty || apiKey == null) {
      _setState(SessionState.disconnected);
      throw Exception('Missing Gemini Live bootstrap data');
    }

    final payload = setup ??
        {
          'model': 'models/${bootstrap['model'] ?? 'gemini-3.1-flash-live-preview'}',
          'response_modalities': ['AUDIO'],
        };

    await _client.connect(liveWsUrl, apiKey, payload);
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
  }

  // ── Transcript persistence ────────────────────────────────────────────────────

  Future<void> clearLocalTranscript() async {
    _transcript.clear();
    _history.clear();
    await _persistTranscript();
    notifyListeners();
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
            .where((l) => l.text.isNotEmpty));
      _history.clear();
      for (final line in _transcript) {
        _history.add({
          'role': line.isUser ? 'user' : 'model',
          'text': _stamp(line.time, line.text),
        });
      }
      _trimHistory();
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
    _pendingTurnUser = '';
    _pendingTurnModel = '';

    try {
      await BackendService.postTurn(sessionId: _sessionId, messages: messages);
    } catch (_) {}
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
      final reply = await _geminiTextChat(historyText, attachments: attachments);
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
    if ((_geminiApiKey ?? '').isNotEmpty) return;
    final bootstrap = await BackendService.bootstrap();
    _geminiApiKey = bootstrap['token'] as String?;
    final setup = bootstrap['setup'] as Map<String, dynamic>?;
    _systemPrompt = (setup?['system_instruction']?['parts'] as List<dynamic>?)
        ?.map((p) => p['text'] as String? ?? '')
        .join('');
    if ((_geminiApiKey ?? '').isEmpty) {
      throw Exception('Missing Gemini API key from bootstrap');
    }
  }

  Future<String> _geminiTextChat(
    String message, {
    List<Map<String, String>> attachments = const [],
  }) async {
    await _bootstrapTextChatIfNeeded();
    final key = _geminiApiKey;
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
              'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=$key'),
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

  void _addAssistantFallbackMessage() {
    _addTranscript(
      'I could not generate a reply right now. Please check your connection and try again.',
      isUser: false,
    );
  }

  @override
  void dispose() {
    _micFlushTimer?.cancel();
    _persistDebounce?.cancel();
    for (final sub in _subs) {
      sub.cancel();
    }
    _client.dispose();
    _recorder.dispose();
    _streamer.dispose();
    super.dispose();
  }
}
