// OpenAI Realtime WebSocket client (alternative to Gemini Live when AYMA_LIVE_PROVIDER=openai).
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../config/audio_config.dart';
import 'gemini_live_client.dart';

class OpenAiRealtimeClient {
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

  final Map<String, _PendingToolCall> _pendingToolCalls = {};
  Timer? _responseFallbackTimer;
  bool _sawAudioInResponse = false;
  bool _sawInputTranscriptDelta = false;
  bool _sawOutputTranscriptDelta = false;

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

  Future<void> connect({
    required String apiKey,
    required String model,
    required Map<String, dynamic> session,
  }) async {
    if (_status != LiveClientStatus.disconnected) {
      _closeTransport();
    }
    _status = LiveClientStatus.connecting;

    final wsUri = Uri(
      scheme: 'wss',
      host: 'api.openai.com',
      path: '/v1/realtime',
      queryParameters: {'model': model},
    );
    if (kIsWeb) {
      _channel = WebSocketChannel.connect(
        wsUri,
        protocols: ['realtime', 'openai-insecure-api-key.$apiKey'],
      );
    } else {
      _channel = IOWebSocketChannel.connect(
        wsUri,
        protocols: ['realtime'],
        headers: {
          'Authorization': 'Bearer $apiKey',
        },
        pingInterval: const Duration(seconds: AudioConfig.websocketPingIntervalSeconds),
        connectTimeout: const Duration(seconds: AudioConfig.connectionTimeoutSeconds),
      );
    }

    await _channel!.ready.timeout(const Duration(seconds: AudioConfig.connectionTimeoutSeconds));
    _wsSub = _channel!.stream.listen(
      _onRawMessage,
      onError: (_) => _onDisconnect(),
      onDone: _onDisconnect,
    );

    _send({
      'type': 'session.update',
      'session': session,
    });
    _status = LiveClientStatus.connected;
  }

  void disconnect() {
    _closeTransport();
    _status = LiveClientStatus.disconnected;
  }

  void _closeTransport() {
    _responseFallbackTimer?.cancel();
    _responseFallbackTimer = null;
    _wsSub?.cancel();
    _wsSub = null;
    _channel?.sink.close();
    _channel = null;
    _pendingToolCalls.clear();
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
    } else {
      return;
    }

    final Map<String, dynamic> msg;
    try {
      msg = jsonDecode(text) as Map<String, dynamic>;
    } catch (_) {
      return;
    }

    final type = msg['type'] as String? ?? '';
    switch (type) {
      case 'session.created':
      case 'session.updated':
        if (!_setupCompleteCtrl.isClosed) _setupCompleteCtrl.add(null);
        break;
      case 'input_audio_buffer.speech_started':
        if (!_interruptedCtrl.isClosed) _interruptedCtrl.add(null);
        break;
      case 'conversation.item.input_audio_transcription.delta':
        _sawInputTranscriptDelta = true;
        _addTranscriptDelta(_inputTranscriptCtrl, msg['delta']);
        break;
      case 'conversation.item.input_audio_transcription.completed':
        if (!_sawInputTranscriptDelta) {
          _addTranscriptFinal(_inputTranscriptCtrl, msg['transcript']);
        }
        _sawInputTranscriptDelta = false;
        break;
      case 'response.output_audio.delta':
      case 'response.audio.delta':
        _sawAudioInResponse = true;
        final delta = msg['delta'] as String?;
        if (delta != null && delta.isNotEmpty && !_audioCtrl.isClosed) {
          _audioCtrl.add(LiveAudioChunk(base64Decode(delta), 'audio/pcm;rate=24000'));
        }
        break;
      case 'response.output_audio_transcript.delta':
      case 'response.audio_transcript.delta':
        _sawOutputTranscriptDelta = true;
        _addTranscriptDelta(_outputTranscriptCtrl, msg['delta']);
        break;
      case 'response.output_audio_transcript.done':
      case 'response.audio_transcript.done':
        if (!_sawOutputTranscriptDelta) {
          _addTranscriptFinal(_outputTranscriptCtrl, msg['transcript']);
        }
        break;
      case 'response.output_text.delta':
      case 'response.text.delta':
        _addTranscriptDelta(_outputTranscriptCtrl, msg['delta']);
        break;
      case 'response.output_item.done':
        _handleOutputItemDone(msg['item'] as Map<String, dynamic>?);
        break;
      case 'response.function_call_arguments.delta':
        _appendToolArgs(msg);
        break;
      case 'response.function_call_arguments.done':
        _completeToolCall(msg);
        break;
      case 'response.done':
        _responseFallbackTimer?.cancel();
        _responseFallbackTimer = null;
        _sawAudioInResponse = false;
        _sawOutputTranscriptDelta = false;
        if (!_turnCompleteCtrl.isClosed) _turnCompleteCtrl.add(null);
        break;
      case 'error':
        debugPrint('OpenAI realtime error: ${jsonEncode(msg['error'] ?? msg)}');
        _onDisconnect();
        break;
    }
  }

  void _addTranscriptDelta(StreamController<String> ctrl, dynamic value) {
    final text = (value as String? ?? '').trim();
    if (text.isNotEmpty && !ctrl.isClosed) ctrl.add(text);
  }

  void _addTranscriptFinal(StreamController<String> ctrl, dynamic value) {
    final text = (value as String? ?? '').trim();
    if (text.isNotEmpty && !ctrl.isClosed) ctrl.add(text);
  }

  void _appendToolArgs(Map<String, dynamic> msg) {
    final callId = msg['call_id'] as String? ?? msg['item_id'] as String? ?? '';
    if (callId.isEmpty) return;
    final pending = _pendingToolCalls.putIfAbsent(callId, () => _PendingToolCall(callId));
    pending.name = msg['name'] as String? ?? pending.name;
    pending.arguments += msg['delta'] as String? ?? '';
  }

  void _completeToolCall(Map<String, dynamic> msg) {
    final callId = msg['call_id'] as String? ?? msg['item_id'] as String? ?? '';
    if (callId.isEmpty) return;
    final pending = _pendingToolCalls.remove(callId) ?? _PendingToolCall(callId);
    pending.name = msg['name'] as String? ?? pending.name;
    pending.arguments = msg['arguments'] as String? ?? pending.arguments;
    _emitToolCall(pending);
  }

  void _handleOutputItemDone(Map<String, dynamic>? item) {
    if (item == null || item['type'] != 'function_call') return;
    final callId = item['call_id'] as String? ?? item['id'] as String? ?? '';
    if (callId.isEmpty) return;
    final pending = _pendingToolCalls.remove(callId) ?? _PendingToolCall(callId);
    pending.name = item['name'] as String? ?? pending.name;
    pending.arguments = item['arguments'] as String? ?? pending.arguments;
    _emitToolCall(pending);
  }

  void _emitToolCall(_PendingToolCall pending) {
    final name = pending.name.trim();
    if (name.isEmpty || _toolCallCtrl.isClosed) return;
    Map<String, dynamic> args = {};
    if (pending.arguments.trim().isNotEmpty) {
      try {
        args = jsonDecode(pending.arguments) as Map<String, dynamic>;
      } catch (_) {
        args = {'raw': pending.arguments};
      }
    }
    _toolCallCtrl.add([LiveToolCall(id: pending.id, name: name, args: args)]);
  }

  void sendRealtimeAudio(Uint8List pcm16) {
    if (_channel == null || _status != LiveClientStatus.connected) return;
    _send({
      'type': 'input_audio_buffer.append',
      'audio': base64Encode(_pcm16Mono16kTo24k(pcm16)),
    });
  }

  void sendText(String text) {
    if (_channel == null || _status != LiveClientStatus.connected) return;
    _send({
      'type': 'conversation.item.create',
      'item': {
        'type': 'message',
        'role': 'user',
        'content': [
          {'type': 'input_text', 'text': text},
        ],
      },
    });
    _createResponse();
  }

  void sendToolResponse(List<Map<String, dynamic>> responses) {
    if (_channel == null || _status != LiveClientStatus.connected) return;
    for (final response in responses) {
      final callId = response['id'] as String? ?? '';
      if (callId.isEmpty) continue;
      _send({
        'type': 'conversation.item.create',
        'item': {
          'type': 'function_call_output',
          'call_id': callId,
          'output': jsonEncode(response['response'] ?? {}),
        },
      });
    }
    _createResponse();
  }

  void _createResponse() {
    _sawAudioInResponse = false;
    _send({
      'type': 'response.create',
      'response': {
        'modalities': ['audio', 'text'],
      },
    });
    _responseFallbackTimer?.cancel();
    _responseFallbackTimer = Timer(const Duration(seconds: AudioConfig.openaiResponseFallbackSeconds), () {
      if (_status == LiveClientStatus.connected && !_sawAudioInResponse) {
        _send({'type': 'response.cancel'});
        if (!_turnCompleteCtrl.isClosed) _turnCompleteCtrl.add(null);
      }
    });
  }

  void _send(Map<String, dynamic> event) {
    _channel?.sink.add(jsonEncode(event));
  }

  Uint8List _pcm16Mono16kTo24k(Uint8List input) {
    if (input.length < 4) return input;
    final inSamples = input.length ~/ 2;
    final outSamples = ((inSamples - 1) * 3 ~/ 2) + 1;
    final out = Uint8List(outSamples * 2);
    final inView = ByteData.sublistView(input);
    final outView = ByteData.sublistView(out);
    for (int i = 0; i < outSamples; i++) {
      final position = i * 2 / 3;
      final left = position.floor().clamp(0, inSamples - 1);
      final right = (left + 1).clamp(0, inSamples - 1);
      final frac = position - left;
      final a = inView.getInt16(left * 2, Endian.little);
      final b = inView.getInt16(right * 2, Endian.little);
      final sample = (a + (b - a) * frac).round().clamp(-32768, 32767);
      outView.setInt16(i * 2, sample, Endian.little);
    }
    return out;
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

class _PendingToolCall {
  final String id;
  String name = '';
  String arguments = '';

  _PendingToolCall(this.id);
}
