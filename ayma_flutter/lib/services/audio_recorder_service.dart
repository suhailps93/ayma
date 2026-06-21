// Mic capture to PCM16 for live voice sessions (flutter_sound on mobile, WebMicCapture on web).
// ignore_for_file: deprecated_member_use
import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_sound/flutter_sound.dart';
import 'package:logger/logger.dart' show Level;

import 'web_audio_stub.dart' if (dart.library.html) 'web_audio_impl.dart';

class PcmFrameBuffer {
  final int frameSize;
  final BytesBuilder _buffer = BytesBuilder(copy: false);

  PcmFrameBuffer({this.frameSize = 1280});

  List<Uint8List> add(Uint8List chunk) {
    _buffer.add(chunk);
    final List<Uint8List> frames = [];
    while (_buffer.length >= frameSize) {
      final fullBytes = _buffer.takeBytes();
      // Copy the frame bytes to allow the fullBytes buffer to be garbage-collected
      final frame = Uint8List.fromList(Uint8List.sublistView(fullBytes, 0, frameSize));
      frames.add(frame);
      if (fullBytes.length > frameSize) {
        // Copy the remainder to avoid holding a reference to the large fullBytes array inside the builder
        final remainder = Uint8List.fromList(Uint8List.sublistView(fullBytes, frameSize));
        _buffer.add(remainder);
      }
    }
    return frames;
  }

  void clear() {
    _buffer.clear();
  }
}

class AudioRecorderService {
  final _recorder = FlutterSoundRecorder(logLevel: Level.nothing);
  final _webMic = WebMicCapture();
  final _frameBuffer = PcmFrameBuffer(frameSize: 1280); // 40ms frames for 16kHz PCM16 Mono

  bool _initialized = false;
  bool _recording = false;
  StreamSubscription<Uint8List>? _nativeRecorderSub;

  final _pcmCtrl = StreamController<Uint8List>.broadcast();
  final _volumeCtrl = StreamController<double>.broadcast();

  Stream<Uint8List> get pcmStream => _pcmCtrl.stream;
  Stream<double> get volumeStream => _volumeCtrl.stream;
  bool get isRecording => _recording;

  Future<void> _ensureInit() async {
    if (kIsWeb || _initialized) return;
    await _recorder.openRecorder();
    await _recorder.setSubscriptionDuration(const Duration(milliseconds: 80));
    _initialized = true;
  }

  Future<void> start() async {
    if (_recording) return;
    _recording = true;
    _frameBuffer.clear();

    if (kIsWeb) {
      await _webMic.start((pcm16) {
        final frames = _frameBuffer.add(pcm16);
        for (final frame in frames) {
          if (!_pcmCtrl.isClosed) _pcmCtrl.add(frame);
          final rms = _pcmRms(frame);
          if (!_volumeCtrl.isClosed) _volumeCtrl.add(rms);
        }
      });
      return;
    }

    await _ensureInit();
    final ctrl = StreamController<Uint8List>();
    _nativeRecorderSub = ctrl.stream.listen((data) {
      final frames = _frameBuffer.add(data);
      for (final frame in frames) {
        if (!_pcmCtrl.isClosed) _pcmCtrl.add(frame);
      }
    });

    await _recorder.startRecorder(
      toStream: ctrl.sink,
      codec: Codec.pcm16,
      numChannels: 1,
      sampleRate: 16000,
      audioSource: AudioSource.voice_communication,
    );

    _recorder.onProgress?.listen((e) {
      final vol = ((e.decibels ?? -60) + 60) / 60;
      if (!_volumeCtrl.isClosed) _volumeCtrl.add(vol.clamp(0.0, 1.0));
    });
  }

  void stop() {
    if (!_recording) return;
    _recording = false;
    _nativeRecorderSub?.cancel();
    _nativeRecorderSub = null;
    _frameBuffer.clear();
    if (kIsWeb) {
      _webMic.stop();
    } else if (_recorder.isRecording) {
      _recorder.stopRecorder();
    }
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

  void dispose() {
    stop();
    _pcmCtrl.close();
    _volumeCtrl.close();
    if (!kIsWeb && _initialized) {
      _recorder.closeRecorder();
    }
  }
}

class ClientVoiceActivityDetector {
  final double rmsThreshold;
  final double zcrMin;
  final double zcrMax;
  final Duration hangoverDuration;
  final Duration preBufferDuration;

  bool _isSpeechActive = false;
  DateTime? _lastSpeechTime;

  // A circular pre-buffer to store the last 300ms of audio
  final List<Uint8List> _preBuffer = [];
  final int _maxPreBufferPackets; // e.g. 7-8 packets of 40ms

  ClientVoiceActivityDetector({
    this.rmsThreshold = 0.015,
    this.zcrMin = 0.03,
    this.zcrMax = 0.35,
    this.hangoverDuration = const Duration(milliseconds: 800),
    this.preBufferDuration = const Duration(milliseconds: 300),
    int packetDurationMs = 40,
  }) : _maxPreBufferPackets = preBufferDuration.inMilliseconds ~/ packetDurationMs;

  bool get isSpeechActive => _isSpeechActive;

  /// Process an audio frame, returning whether speech is active.
  bool processFrame(Uint8List pcm16) {
    if (pcm16.length < 2) return _isSpeechActive;

    final rms = _calculateRms(pcm16);
    final zcr = _calculateZcr(pcm16);

    final bool energyThresholdMet = rms >= rmsThreshold;
    final bool zcrValid = zcr >= zcrMin && zcr <= zcrMax;
    final bool currentFrameSpeech = energyThresholdMet && zcrValid;

    final now = DateTime.now();
    if (currentFrameSpeech) {
      _isSpeechActive = true;
      _lastSpeechTime = now;
    } else {
      if (_isSpeechActive) {
        if (_lastSpeechTime != null && now.difference(_lastSpeechTime!) > hangoverDuration) {
          _isSpeechActive = false;
        }
      }
    }

    // Manage pre-buffer when silent
    if (!_isSpeechActive) {
      _preBuffer.add(pcm16);
      if (_preBuffer.length > _maxPreBufferPackets) {
        _preBuffer.removeAt(0);
      }
    }

    return _isSpeechActive;
  }

  /// Get and clear the pre-buffer when speech starts
  List<Uint8List> getAndClearPreBuffer() {
    final copy = List<Uint8List>.from(_preBuffer);
    _preBuffer.clear();
    return copy;
  }

  void reset() {
    _isSpeechActive = false;
    _lastSpeechTime = null;
    _preBuffer.clear();
  }

  double _calculateRms(Uint8List pcm16) {
    final view = ByteData.sublistView(pcm16);
    final count = pcm16.length ~/ 2;
    double sum = 0.0;
    for (int i = 0; i < count; i++) {
      final s = view.getInt16(i * 2, Endian.little) / 32768.0;
      sum += s * s;
    }
    return math.sqrt(sum / count);
  }

  double _calculateZcr(Uint8List pcm16) {
    final view = ByteData.sublistView(pcm16);
    final count = pcm16.length ~/ 2;
    if (count < 2) return 0.0;
    int crossings = 0;
    int prevSign = view.getInt16(0, Endian.little) >= 0 ? 1 : -1;
    for (int i = 1; i < count; i++) {
      final val = view.getInt16(i * 2, Endian.little);
      final sign = val >= 0 ? 1 : -1;
      if (sign != prevSign) {
        crossings++;
        prevSign = sign;
      }
    }
    return crossings / count;
  }
}
