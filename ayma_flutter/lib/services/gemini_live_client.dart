// Gemini Live WebSocket client: setup, bidirectional audio, tool calls, turn events.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../config/audio_config.dart';

enum LiveClientStatus { disconnected, connecting, connected }

class LiveAudioChunk {
  final Uint8List data;
  final String mimeType;
  const LiveAudioChunk(this.data, this.mimeType);
}

class LiveToolCall {
  final String id;
  final String name;
  final Map<String, dynamic> args;
  const LiveToolCall({required this.id, required this.name, required this.args});
}

class GeminiLiveClient {
  WebSocketChannel? _channel;
  StreamSubscription? _wsSub;
  LiveClientStatus _status = LiveClientStatus.disconnected;

  final _audioCtrl = StreamController<LiveAudioChunk>.broadcast();
  final _setupCompleteCtrl = StreamController<void>.broadcast();
  final _interruptedCtrl = StreamController<void>.broadcast();
  final _turnCompleteCtrl = StreamController<void>.broadcast();
  final _inputTranscriptCtrl = StreamController<String>.broadcast();
  final _outputTranscriptCtrl = StreamController<String>.broadcast();
  final _toolCallCtrl = StreamController<List<LiveToolCall>>.broadcast();
  final _disconnectedCtrl = StreamController<void>.broadcast();

  Stream<LiveAudioChunk> get audioStream => _audioCtrl.stream;
  Stream<void> get setupCompleteStream => _setupCompleteCtrl.stream;
  Stream<void> get interruptedStream => _interruptedCtrl.stream;
  Stream<void> get turnCompleteStream => _turnCompleteCtrl.stream;
  Stream<String> get inputTranscriptStream => _inputTranscriptCtrl.stream;
  Stream<String> get outputTranscriptStream => _outputTranscriptCtrl.stream;
  Stream<List<LiveToolCall>> get toolCallStream => _toolCallCtrl.stream;
  Stream<void> get disconnectedStream => _disconnectedCtrl.stream;

  LiveClientStatus get status => _status;
  bool get isConnected => _status == LiveClientStatus.connected;

  Map<String, dynamic> _normalizeSetup(Map<String, dynamic> setup) {
    dynamic normalize(dynamic value) {
      if (value is Map) {
        final out = <String, dynamic>{};
        value.forEach((k, v) {
          final key = k.toString().replaceAllMapped(
            RegExp(r'_([a-z])'),
            (m) => m[1]!.toUpperCase(),
          );
          out[key] = normalize(v);
        });
        return out;
      }
      if (value is List) return value.map(normalize).toList();
      return value;
    }
    return normalize(setup) as Map<String, dynamic>;
  }

  Future<void> connect(String wsUrl, String apiKey, Map<String, dynamic> setupPayload) async {
    debugPrint('DEBUG: GeminiLiveClient connecting to $wsUrl');
    if (apiKey.trim().isEmpty) {
      throw ArgumentError('Gemini API key/token is empty');
    }
    if (_status != LiveClientStatus.disconnected) {
      _closeTransport();
    }
    _status = LiveClientStatus.connecting;

    final isToken = !apiKey.startsWith('AIza');
    final authParam = isToken ? 'access_token' : 'key';

    debugPrint('DEBUG: Using ${isToken ? 'OAuth Token' : 'API Key'} for authentication (length: ${apiKey.length})');

    final wsUri = Uri.parse(wsUrl).replace(queryParameters: {authParam: apiKey});
    debugPrint('DEBUG: GeminiLiveClient WS URI: ${wsUri.replace(queryParameters: {authParam: '${apiKey.substring(0, apiKey.length > 6 ? 6 : apiKey.length)}...'})}');
    _channel = kIsWeb
        ? WebSocketChannel.connect(wsUri)
        : IOWebSocketChannel.connect(wsUri, pingInterval: const Duration(seconds: AudioConfig.websocketPingIntervalSeconds));

    await _channel!.ready;

    final setupMessage = jsonEncode({'setup': _normalizeSetup(setupPayload)});
    debugPrint('DEBUG: GeminiLiveClient setup: $setupMessage');
    _channel!.sink.add(setupMessage);

    _wsSub = _channel!.stream.listen(
      (data) {
        try {
          final String text;
          if (data is String) {
            text = data;
          } else if (data is List<int>) {
            text = utf8.decode(data);
          } else {
            text = '';
          }
          if (text.isNotEmpty) {
            final msg = jsonDecode(text) as Map<String, dynamic>;
            if (msg.containsKey('setupComplete')) {
              debugPrint('DEBUG: Received from Gemini: SetupComplete');
            } else if (msg.containsKey('serverContent')) {
              final sc = msg['serverContent'] as Map<String, dynamic>?;
              final mt = sc?['modelTurn'] as Map<String, dynamic>?;
              final ot = sc?['outputTranscription'] as Map<String, dynamic>?;
              final it = sc?['inputTranscription'] as Map<String, dynamic>?;
              final done = sc?['turnComplete'] == true;
              final interrupted = sc?['interrupted'] == true;
              
              if (mt != null) {
                final parts = mt['parts'] as List?;
                var bytesCount = 0;
                if (parts != null) {
                  for (final p in parts) {
                    final inlineData = p['inlineData'] as Map?;
                    final dataStr = inlineData?['data'] as String?;
                    if (dataStr != null) {
                      bytesCount += base64Decode(dataStr).length;
                    }
                  }
                }
                debugPrint('DEBUG: Received from Gemini: AudioChunk ($bytesCount bytes)');
              }
              if (ot != null) {
                debugPrint('DEBUG: Received from Gemini: OutputTranscription "${ot['text']}"');
              }
              if (it != null) {
                debugPrint('DEBUG: Received from Gemini: InputTranscription "${it['text']}"');
              }
              if (done) {
                debugPrint('DEBUG: Received from Gemini: TurnComplete');
              }
              if (interrupted) {
                debugPrint('DEBUG: Received from Gemini: Interrupted');
              }
            } else if (msg.containsKey('toolCall')) {
              debugPrint('DEBUG: Received from Gemini: ToolCall');
            } else {
              debugPrint('DEBUG: Received from Gemini: ${msg.keys.toList()}');
            }
          } else {
            debugPrint('DEBUG: Received from Gemini: Raw binary message');
          }
        } catch (_) {
          debugPrint('DEBUG: Received from Gemini: Raw data payload');
        }
        _onRawMessage(data);
      },
      onError: (e) {
        debugPrint('DEBUG: Gemini WebSocket error: $e');
        _onDisconnect();
      },
      onDone: () {
        debugPrint(
          'DEBUG: Gemini WebSocket closed (code: ${_channel!.closeCode}, reason: ${_channel!.closeReason}, status was: $_status)',
        );
        _onDisconnect();
      },
    );
    _status = LiveClientStatus.connected;
    debugPrint('DEBUG: GeminiLiveClient status: connected');
  }

  void disconnect() {
    _closeTransport();
    _status = LiveClientStatus.disconnected;
  }

  void _closeTransport() {
    _wsSub?.cancel();
    _wsSub = null;
    _channel?.sink.close();
    _channel = null;
  }

  void _onDisconnect() {
    _closeTransport();
    _status = LiveClientStatus.disconnected;
    if (!_disconnectedCtrl.isClosed) _disconnectedCtrl.add(null);
  }

  void _onRawMessage(dynamic raw) {
    final String text;
    if (raw is String) {
      text = raw;
    } else if (raw is List<int>) {
      text = utf8.decode(raw);
    } else if (raw is Uint8List) {
      text = utf8.decode(raw);
    } else {
      return;
    }

    final Map<String, dynamic> msg;
    try {
      msg = jsonDecode(text) as Map<String, dynamic>;
    } catch (_) {
      return;
    }

    if (msg.containsKey('setupComplete')) {
      if (!_setupCompleteCtrl.isClosed) _setupCompleteCtrl.add(null);
      return;
    }

    if (msg.containsKey('goAway')) {
      _onDisconnect();
      return;
    }

    final serverContent = msg['serverContent'] as Map<String, dynamic>?;
    if (serverContent != null) {
      final interrupted = (serverContent['interrupted'] as bool?) ?? false;
      if (interrupted) {
        if (!_interruptedCtrl.isClosed) _interruptedCtrl.add(null);
        return;
      }

      final modelTurn = serverContent['modelTurn'] as Map<String, dynamic>?;
      if (modelTurn != null) {
        final parts = (modelTurn['parts'] as List<dynamic>? ?? [])
            .whereType<Map<String, dynamic>>();
        for (final part in parts) {
          final inlineData = part['inlineData'] as Map<String, dynamic>?;
          if (inlineData != null) {
            final mimeType = inlineData['mimeType'] as String? ?? '';
            final data = inlineData['data'] as String?;
            if (data != null && mimeType.contains('audio') && !_audioCtrl.isClosed) {
              _audioCtrl.add(LiveAudioChunk(base64Decode(data), mimeType));
            }
          }
        }
      }

      final outTx = serverContent['outputTranscription'] as Map<String, dynamic>?;
      final outText = (outTx?['text'] as String? ?? '').trim();
      if (outText.isNotEmpty && !_outputTranscriptCtrl.isClosed) {
        _outputTranscriptCtrl.add(outText);
      }

      final inTx = serverContent['inputTranscription'] as Map<String, dynamic>?;
      final inText = (inTx?['text'] as String? ?? '').trim();
      if (inText.isNotEmpty && !_inputTranscriptCtrl.isClosed) {
        _inputTranscriptCtrl.add(inText);
      }

      final turnComplete = (serverContent['turnComplete'] as bool?) ?? false;
      if (turnComplete && !_turnCompleteCtrl.isClosed) {
        _turnCompleteCtrl.add(null);
      }
      return;
    }

    final toolCall = msg['toolCall'] as Map<String, dynamic>?;
    if (toolCall != null) {
      final calls = (toolCall['functionCalls'] as List<dynamic>? ?? [])
          .whereType<Map<String, dynamic>>()
          .map((c) => LiveToolCall(
                id: c['id'] as String? ?? '',
                name: c['name'] as String? ?? '',
                args: c['args'] as Map<String, dynamic>? ?? {},
              ))
          .toList();
      if (calls.isNotEmpty && !_toolCallCtrl.isClosed) {
        _toolCallCtrl.add(calls);
      }
    }
  }

  void sendRealtimeAudio(Uint8List pcm16) {
    if (_channel == null || _status != LiveClientStatus.connected) return;
    _channel!.sink.add(jsonEncode({
      'realtimeInput': {
        'audio': {
          'mimeType': 'audio/pcm;rate=16000',
          'data': base64Encode(pcm16),
        }
      }
    }));
  }

  void interrupt() {
    if (_channel == null || _status != LiveClientStatus.connected) return;
    // Sending any clientContent message interrupts the model output.
    // We send an empty turn to signal interruption without adding new content.
    _channel!.sink.add(jsonEncode({
      'clientContent': {
        'turns': [
          {
            'role': 'user',
            'parts': [],
          }
        ],
        'turnComplete': true,
      }
    }));
  }

  void sendText(String text) {
    if (_channel == null || _status != LiveClientStatus.connected) return;
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
  }

  void sendToolResponse(List<Map<String, dynamic>> responses) {
    if (_channel == null || _status != LiveClientStatus.connected) return;
    _channel!.sink.add(jsonEncode({
      'toolResponse': {'functionResponses': responses}
    }));
  }

  void dispose() {
    _closeTransport();
    _audioCtrl.close();
    _setupCompleteCtrl.close();
    _interruptedCtrl.close();
    _turnCompleteCtrl.close();
    _inputTranscriptCtrl.close();
    _outputTranscriptCtrl.close();
    _toolCallCtrl.close();
    _disconnectedCtrl.close();
  }
}
