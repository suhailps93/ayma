// ignore_for_file: deprecated_member_use
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_sound/flutter_sound.dart';
import 'package:logger/logger.dart' show Level;

import 'web_audio_stub.dart' if (dart.library.html) 'web_audio_impl.dart';

class AudioStreamerService {
  final _player = FlutterSoundPlayer(logLevel: Level.nothing);
  final _webPlayer = WebPcmPlayer();

  bool _initialized = false;
  Future<void>? _initFuture;
  bool _streaming = false;
  Future<void>? _startingFuture;
  int _sampleRate = 24000;
  int _channels = 1;

  Future<void> _ensureInit() async {
    if (kIsWeb || _initialized) return;
    _initFuture ??= _player.openPlayer().then((_) => _initialized = true);
    await _initFuture;
  }

  Future<void> addPcm16(Uint8List data, {String mimeType = 'audio/pcm;rate=24000'}) async {
    if (kIsWeb) {
      _webPlayer.play(data);
      return;
    }

    await _ensureInit();
    final cfg = _parsePcmConfig(mimeType);
    if (!_streaming || _sampleRate != cfg.sampleRate || _channels != cfg.channels) {
      _stopStreamPlayer();
      _sampleRate = cfg.sampleRate;
      _channels = cfg.channels;
      // Only start once; subsequent concurrent callers await the same future.
      _startingFuture ??= _startStreamPlayer().whenComplete(() => _startingFuture = null);
    }
    // If player is starting, wait for it so no chunks are dropped.
    if (_startingFuture != null) await _startingFuture;
    _player.uint8ListSink?.add(data);
  }

  Future<void> _startStreamPlayer() async {
    if (_streaming) return;
    _streaming = true;
    try {
      await _player.startPlayerFromStream(
        codec: Codec.pcm16,
        interleaved: false,
        sampleRate: _sampleRate,
        numChannels: _channels,
        bufferSize: 32768,
      );
    } catch (_) {
      _streaming = false;
    }
  }

  void _stopStreamPlayer() {
    if (!_streaming && _player.isStopped) return;
    try {
      _player.stopPlayer();
    } catch (_) {}
    _streaming = false;
    _startingFuture = null;
  }

  void stop() {
    if (kIsWeb) {
      _webPlayer.stop();
    } else {
      _stopStreamPlayer();
    }
  }

  ({int sampleRate, int channels}) _parsePcmConfig(String mimeType) {
    final rateMatch = RegExp(r'rate=(\d+)', caseSensitive: false).firstMatch(mimeType);
    final channelsMatch =
        RegExp(r'channels=(\d+)', caseSensitive: false).firstMatch(mimeType);
    return (
      sampleRate: int.tryParse(rateMatch?.group(1) ?? '') ?? 24000,
      channels: int.tryParse(channelsMatch?.group(1) ?? '') ?? 1,
    );
  }

  void dispose() {
    stop();
    if (!kIsWeb && _initialized) {
      _player.closePlayer();
    }
  }
}
