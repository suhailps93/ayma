// Mic capture to PCM16 for live voice sessions (flutter_sound on mobile, WebMicCapture on web).
// ignore_for_file: deprecated_member_use
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_sound/flutter_sound.dart';
import 'package:logger/logger.dart' show Level;

import 'web_audio_stub.dart' if (dart.library.html) 'web_audio_impl.dart';

class AudioRecorderService {
  final _recorder = FlutterSoundRecorder(logLevel: Level.nothing);
  final _webMic = WebMicCapture();

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

    if (kIsWeb) {
      await _webMic.start((pcm16) {
        if (!_pcmCtrl.isClosed) _pcmCtrl.add(pcm16);
        final rms = _pcmRms(pcm16);
        if (!_volumeCtrl.isClosed) _volumeCtrl.add(rms);
      });
      return;
    }

    await _ensureInit();
    final ctrl = StreamController<Uint8List>();
    _nativeRecorderSub = ctrl.stream.listen((data) {
      if (!_pcmCtrl.isClosed) _pcmCtrl.add(data);
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
