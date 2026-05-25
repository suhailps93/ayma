import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_sound/flutter_sound.dart';
import 'package:logger/logger.dart' show Level;
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

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

class AymaAudioService extends ChangeNotifier {
  static const _transcriptStorageKey = 'ayma.chat.transcript';

  WebSocketChannel? _channel;
  StreamSubscription? _wsSub;

  final _recorder = FlutterSoundRecorder(logLevel: Level.nothing);
  final _player = FlutterSoundPlayer(logLevel: Level.nothing);
  bool _playerStreaming = false;
  int _playerSampleRate = 24000;
  int _playerChannels = 1;

  final _webMic = WebMicCapture();
  final _webPlayer = WebPcmPlayer();

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

  // Shared context for both Live and Text APIs.
  final List<Map<String, String>> _history = [];

  bool _audioInitialized = false;
  Future<void>? _audioInitFuture;
  Future<void>? _connectFuture;

  final BytesBuilder _pendingMicAudio = BytesBuilder(copy: false);
  Timer? _micFlushTimer;
  static const _micFlushInterval = Duration(milliseconds: 120);

  DateTime _lastMeterUiUpdate = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastUserVoiceAt = DateTime.fromMillisecondsSinceEpoch(0);

  String? _geminiApiKey;
  String? _systemPrompt;
  String _sessionId = DateTime.now().millisecondsSinceEpoch.toString();

  bool _restoredTranscript = false;
  bool _liveHistorySeeded = false;
  String _pendingTurnUser = '';
  String _pendingTurnModel = '';
  String _pendingDisplayModel = '';

  AymaAudioService() {
    unawaited(_restoreTranscript());
  }

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
      _closeTransport();
      _setState(SessionState.disconnected);
    }

    _setState(SessionState.connecting);
    _sessionId = DateTime.now().millisecondsSinceEpoch.toString();
    _liveHistorySeeded = false;

    if (!kIsWeb) {
      final permission = await Permission.microphone.request();
      if (!permission.isGranted) {
        _setState(SessionState.disconnected);
        throw Exception('Microphone permission denied');
      }
      await _ensureAudioInitialized();
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

    final wsUri = Uri.parse(liveWsUrl).replace(queryParameters: {'key': apiKey});

    if (kIsWeb) {
      _channel = WebSocketChannel.connect(wsUri);
    } else {
      _channel = IOWebSocketChannel.connect(
        wsUri,
        pingInterval: const Duration(seconds: 30),
      );
    }

    final normalizedSetup =
        _normalizeLiveSetupPayload(setup ?? _minimalSetup(bootstrap));
    _channel!.sink.add(jsonEncode({'setup': normalizedSetup}));

    _wsSub = _channel!.stream.listen(
      _onMessage,
      onError: (_) => _handleRemoteDisconnect(),
      onDone: _handleRemoteDisconnect,
    );
  }

  Map<String, dynamic> _minimalSetup(Map<String, dynamic> bootstrap) {
    final modelName =
        bootstrap['model'] as String? ?? 'gemini-3.1-flash-live-preview';
    return {
      'model': 'models/$modelName',
      'response_modalities': ['AUDIO'],
    };
  }

  void disconnect({bool notify = true}) {
    _closeTransport();
    _clearPendingMicAudio();
    _pendingDisplayModel = '';
    _pendingTurnUser = '';
    _pendingTurnModel = '';
    _setState(SessionState.disconnected, notify: notify);
  }

  Future<void> clearLocalTranscript() async {
    _transcript.clear();
    _history.clear();
    await _persistTranscript();
    notifyListeners();
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

  void _handleRemoteDisconnect() {
    _closeTransport();
    _clearPendingMicAudio();
    _pendingDisplayModel = '';
    _pendingTurnUser = '';
    _pendingTurnModel = '';
    _setState(SessionState.disconnected);
  }

  void _onMessage(dynamic raw) {
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

    final Map<String, dynamic> msg;
    try {
      msg = jsonDecode(decoded) as Map<String, dynamic>;
    } catch (_) {
      return;
    }

    if (msg.containsKey('setupComplete')) {
      _setState(SessionState.ready);
      unawaited(_startRecorderAndBegin());
      unawaited(_seedHistoryIntoLiveOnce());
      return;
    }

    final serverContent = msg['serverContent'] as Map<String, dynamic>?;
    if (serverContent != null) {
      final interrupted = (serverContent['interrupted'] as bool?) ?? false;
      if (interrupted) {
        if (kIsWeb) {
          _webPlayer.stop();
        } else {
          _stopStreamPlayer();
        }
        _flushPendingModelText();
        _setState(SessionState.listening);
        return;
      }

      final modelTurn = serverContent['modelTurn'] as Map<String, dynamic>?;
      if (modelTurn != null) {
        _setState(SessionState.speaking);
        final parts =
            (modelTurn['parts'] as List<dynamic>? ?? []).whereType<Map<String, dynamic>>();

        for (final part in parts) {
          final inlineData = part['inlineData'] as Map<String, dynamic>?;
          if (inlineData != null) {
            final mimeType = inlineData['mimeType'] as String?;
            final data = inlineData['data'] as String?;
            if (data != null && (mimeType?.contains('audio') ?? false)) {
              _playPcm(base64Decode(data), mimeType: mimeType!);
            }
          }

          final text = (part['text'] as String? ?? '').trim();
          if (text.isNotEmpty) {
            _appendPendingModelText(text);
          }
        }
      }

      final outTx = serverContent['outputTranscription'] as Map<String, dynamic>?;
      final outText = (outTx?['text'] as String? ?? '').trim();
      if (outText.isNotEmpty) {
        _appendPendingModelText(outText);
      }

      final inTx = serverContent['inputTranscription'] as Map<String, dynamic>?;
      final inText = (inTx?['text'] as String? ?? '').trim();
      if (inText.isNotEmpty) {
        _pendingTurnUser = inText;
        _addTranscript(inText, isUser: true);
      }

      final turnComplete = (serverContent['turnComplete'] as bool?) ?? false;
      if (turnComplete) {
        _flushPendingModelText();
        unawaited(_commitTurnToBackend());
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
      _handleRemoteDisconnect();
      return;
    }
  }

  Future<void> _handleToolCall(List<Map<String, dynamic>> functionCalls) async {
    final responses = <Map<String, dynamic>>[];

    for (final call in functionCalls) {
      final id = call['id'] as String? ?? '';
      final name = call['name'] as String? ?? '';
      final args = call['args'] as Map<String, dynamic>? ?? {};

      String output;
      if (name == 'add_followup_question') {
        output = await _execAddFollowup(args);
      } else if (name == 'get_current_time') {
        output = DateTime.now().toIso8601String();
      } else {
        output = 'Tool $name is not available.';
      }

      responses.add({
        'id': id,
        'name': name,
        'response': {'output': output},
      });
    }

    if (_channel == null || _state == SessionState.disconnected) return;
    _channel!.sink.add(jsonEncode({
      'toolResponse': {'functionResponses': responses}
    }));
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

  Future<void> _seedHistoryIntoLiveOnce() async {
    if (_liveHistorySeeded) return;
    if (_channel == null || _history.isEmpty) {
      _liveHistorySeeded = true;
      return;
    }

    final turns = _history.take(12).map((h) {
      return {
        'role': h['role'] == 'user' ? 'user' : 'model',
        'parts': [
          {'text': h['text'] ?? ''}
        ],
      };
    }).toList();

    _channel!.sink.add(jsonEncode({
      'clientContent': {
        'turns': turns,
        'turnComplete': true,
      }
    }));

    _liveHistorySeeded = true;
    _setState(SessionState.listening);
  }

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

  void _appendPendingModelText(String chunk) {
    final normalized = chunk.trim();
    if (normalized.isEmpty) return;
    if (_pendingDisplayModel.isEmpty) {
      _pendingDisplayModel = normalized;
    } else if (_pendingDisplayModel == normalized ||
        _pendingDisplayModel.endsWith(normalized)) {
      return;
    } else if (normalized.startsWith(_pendingDisplayModel)) {
      _pendingDisplayModel = normalized;
    } else {
      _pendingDisplayModel = '$_pendingDisplayModel $normalized';
    }
    _pendingTurnModel = _pendingDisplayModel;
  }

  void _flushPendingModelText() {
    final text = _pendingDisplayModel.trim();
    if (text.isNotEmpty) {
      _addTranscript(text, isUser: false);
    }
    _pendingDisplayModel = '';
  }

  Future<void> _startRecorderAndBegin() async {
    if (kIsWeb) {
      await _webMic.start((pcm16) {
        final rms = _pcmRms(pcm16);
        _rawInputVolume = rms;
        _inputVolume = rms;
        _userTalking = rms > 0.03;
        if (_userTalking) _lastUserVoiceAt = DateTime.now();
        _bufferAudio(pcm16);
        _notifyMetersThrottled();
      });
    } else {
      await _recorder.startRecorder(
        toStream: _recorderSink(),
        codec: Codec.pcm16,
        numChannels: 1,
        sampleRate: 16000,
        audioSource: AudioSource.voice_communication,
      );

      _recorder.onProgress?.listen((e) {
        final vol = ((e.decibels ?? -60) + 60) / 60;
        _inputVolume = vol;
        _userTalking = vol > 0.20;
        if (_userTalking) _lastUserVoiceAt = DateTime.now();
        _notifyMetersThrottled();
      });
    }
  }

  StreamSink<Uint8List> _recorderSink() {
    final ctrl = StreamController<Uint8List>();
    ctrl.stream.listen((data) {
      final rms = _pcmRms(data);
      _rawInputVolume = rms;
      if (!_muted) {
        _bufferAudio(data);
      }
    });
    return ctrl.sink;
  }

  void _bufferAudio(Uint8List pcm) {
    if (_channel == null || _state == SessionState.disconnected || _muted) return;
    _pendingMicAudio.add(pcm);
    _micFlushTimer ??= Timer(_micFlushInterval, _flushBufferedAudio);
  }

  void _flushBufferedAudio() {
    _micFlushTimer = null;
    if (_pendingMicAudio.length == 0) return;
    if (_channel == null || _state == SessionState.disconnected || _muted) {
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

  void _sendAudio(Uint8List pcm) {
    if (_channel == null || _state == SessionState.disconnected || _muted) return;

    // During model output, keep duplex open but suppress clear echo-only windows.
    final speaking = _state == SessionState.speaking;
    final recentVoice =
        DateTime.now().difference(_lastUserVoiceAt) < const Duration(milliseconds: 900);
    if (speaking && _outputVolume > 0.06 && !recentVoice) {
      return;
    }

    _channel!.sink.add(jsonEncode({
      'realtimeInput': {
        'audio': {
          'mimeType': 'audio/pcm;rate=16000',
          'data': base64Encode(pcm),
        }
      }
    }));
  }

  void _playPcm(Uint8List data, {required String mimeType}) {
    if (_speakerMuted) return;

    final cfg = _parsePcmConfig(mimeType);
    _outputVolume = _pcmRms(data);

    if (kIsWeb) {
      _webPlayer.play(data);
      _notifyMetersThrottled();
      return;
    }

    if (!_playerStreaming ||
        _playerSampleRate != cfg.sampleRate ||
        _playerChannels != cfg.channels) {
      _stopStreamPlayer();
      _playerSampleRate = cfg.sampleRate;
      _playerChannels = cfg.channels;
      unawaited(_startStreamPlayer());
    }

    final sink = _player.uint8ListSink;
    if (sink != null) {
      sink.add(data);
    } else {
      Future<void>.delayed(const Duration(milliseconds: 25), () {
        _player.uint8ListSink?.add(data);
      });
    }

    _notifyMetersThrottled();
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
    } catch (_) {
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

    _addTranscript(
      trimmed.isEmpty
          ? '[Shared ${attachments.length} attachment${attachments.length == 1 ? '' : 's'}]'
          : trimmed,
      isUser: true,
      historyText: historyText,
      attachments: attachments,
      allowRecentDuplicate: true,
    );

    if (_state == SessionState.disconnected) {
      _setState(SessionState.thinking);
    }

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
      if (_state == SessionState.thinking) {
        _setState(SessionState.disconnected);
      }
    }
  }

  Future<bool> sendLivePrompt(String prompt) async {
    final text = prompt.trim();
    if (text.isEmpty) return false;

    if (_state == SessionState.disconnected || _channel == null) {
      await connect(userInitiated: true);
    }

    final deadline = DateTime.now().add(const Duration(seconds: 6));
    while (_state == SessionState.connecting && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }

    if (_channel == null || _state == SessionState.disconnected) return false;

    _addTranscript(text, isUser: true, allowRecentDuplicate: true);
    _channel!.sink.add(jsonEncode({
      'clientContent': {
        'turns': [
          {
            'role': 'user',
            'parts': [
              {'text': text}
            ],
          }
        ],
        'turnComplete': true,
      }
    }));

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

    final userParts = await _buildUserParts(
      message: message,
      attachments: attachments,
    );

    final contents = [
      for (final h in _history.sublist(0, math.max(0, _history.length - 1)))
        {
          'role': h['role'],
          'parts': [
            {'text': h['text']}
          ]
        },
      {
        'role': 'user',
        'parts': userParts,
      }
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
          'inlineData': {
            'mimeType': mimeType,
            'data': base64Encode(res.bodyBytes),
          }
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

  void _setState(SessionState next, {bool notify = true}) {
    _state = next;
    if (next != SessionState.speaking) {
      _outputVolume = 0;
    }
    if (notify) {
      notifyListeners();
    }
  }

  void _notifyMetersThrottled() {
    final now = DateTime.now();
    if (now.difference(_lastMeterUiUpdate) < const Duration(milliseconds: 40)) {
      return;
    }
    _lastMeterUiUpdate = now;
    notifyListeners();
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
      final isDuplicate =
          last.isUser == isUser &&
          last.text.trim() == normalized &&
          DateTime.now().difference(last.time) < const Duration(seconds: 3);
      if (isDuplicate && !allowRecentDuplicate) return;
    }

    final now = DateTime.now();
    _transcript.add(
      TranscriptLine(
        normalized,
        isUser: isUser,
        time: now,
        attachments: attachments,
      ),
    );

    _history.add({
      'role': isUser ? 'user' : 'model',
      'text': _stamp(now, (historyText ?? normalized).trim()),
    });
    _trimHistory();

    unawaited(_persistTranscript());
    notifyListeners();
  }

  String _stamp(DateTime time, String text) {
    return '[${time.toIso8601String()}] $text';
  }

  void _trimHistory() {
    if (_history.length > 60) {
      _history.removeRange(0, _history.length - 60);
    }
  }

  ({int sampleRate, int channels}) _parsePcmConfig(String mimeType) {
    final rateMatch = RegExp(r'rate=(\d+)', caseSensitive: false).firstMatch(mimeType);
    final channelsMatch =
        RegExp(r'channels=(\d+)', caseSensitive: false).firstMatch(mimeType);
    final sampleRate = int.tryParse(rateMatch?.group(1) ?? '') ?? 24000;
    final channels = int.tryParse(channelsMatch?.group(1) ?? '') ?? 1;
    return (sampleRate: sampleRate, channels: channels);
  }

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

  static const Map<String, String> _liveSetupKeyAliases = {
    'system_instruction': 'systemInstruction',
    'generation_config': 'generationConfig',
    'speech_config': 'speechConfig',
    'voice_config': 'voiceConfig',
    'prebuilt_voice_config': 'prebuiltVoiceConfig',
    'voice_name': 'voiceName',
    'function_declarations': 'functionDeclarations',
    'response_modalities': 'responseModalities',
  };

  Map<String, dynamic> _normalizeLiveSetupPayload(Map<String, dynamic> setup) {
    dynamic normalize(dynamic value) {
      if (value is Map) {
        final out = <String, dynamic>{};
        value.forEach((key, v) {
          final rawKey = key.toString();
          final mappedKey = _liveSetupKeyAliases[rawKey] ?? rawKey;
          out[mappedKey] = normalize(v);
        });
        return out;
      }
      if (value is List) {
        return value.map(normalize).toList();
      }
      return value;
    }

    return normalize(setup) as Map<String, dynamic>;
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
    disconnect(notify: false);
    if (!kIsWeb && _audioInitialized) {
      _recorder.closeRecorder();
      _player.closePlayer();
    }
    super.dispose();
  }
}
