// Mic capture to PCM16 for live voice sessions (flutter_sound on mobile, WebMicCapture on web).
// ignore_for_file: deprecated_member_use
import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_sound/flutter_sound.dart';
import 'package:logger/logger.dart' show Level;

import '../config/audio_config.dart';
import 'web_audio_stub.dart' if (dart.library.html) 'web_audio_impl.dart';

/// A buffer that collects raw incoming byte chunks of variable sizes
/// and groups them into fixed-size frames (matching AudioConfig.frameSize).
/// To prevent memory reference chains (where slice views keep large parent arrays
/// alive), it duplicates sub-arrays using [Uint8List.fromList] so old buffers 
/// can be garbage-collected immediately.
class PcmFrameBuffer {
  /// The target frame size in bytes.
  final int frameSize;
  
  /// The internal builder used to accumulate partial data chunks.
  final BytesBuilder _buffer = BytesBuilder(copy: false);

  PcmFrameBuffer({this.frameSize = AudioConfig.frameSize});

  /// Adds a new audio byte chunk, returning a list of any completed, 
  /// aligned frames of size [frameSize].
  List<Uint8List> add(Uint8List chunk) {
    _buffer.add(chunk);
    final List<Uint8List> frames = [];
    while (_buffer.length >= frameSize) {
      final fullBytes = _buffer.takeBytes();
      
      // CRITICAL: Explicitly copy the slice into a new array. This isolates
      // the frame buffer and releases the large parent fullBytes array to the GC.
      final frame = Uint8List.fromList(Uint8List.sublistView(fullBytes, 0, frameSize));
      frames.add(frame);
      
      if (fullBytes.length > frameSize) {
        // CRITICAL: Explicitly copy the remainder into a new array. This prevents
        // the internal BytesBuilder list from holding onto the large fullBytes array.
        final remainder = Uint8List.fromList(Uint8List.sublistView(fullBytes, frameSize));
        _buffer.add(remainder);
      }
    }
    return frames;
  }

  /// Clears the accumulated buffer content.
  void clear() {
    _buffer.clear();
  }
}

/// A service handles microphone hardware recording on both Mobile and Web platforms,
/// using flutter_sound (mobile) or custom ScriptProcessor nodes (web).
/// It outputs raw audio frames of a fixed size over [pcmStream] and volume amplitude on [volumeStream].
class AudioRecorderService {
  /// The mobile native audio recorder controller from flutter_sound.
  final _recorder = FlutterSoundRecorder(logLevel: Level.nothing);
  
  /// The web-specific microphone capture module.
  final _webMic = WebMicCapture();
  
  /// Aligns native chunks into target frame sizes.
  final _frameBuffer = PcmFrameBuffer(frameSize: AudioConfig.frameSize);

  bool _initialized = false;
  bool _recording = false;
  StreamSubscription<Uint8List>? _nativeRecorderSub;

  final _pcmCtrl = StreamController<Uint8List>.broadcast();
  final _volumeCtrl = StreamController<double>.broadcast();

  /// Stream of fixed-size PCM16 mono audio frames.
  Stream<Uint8List> get pcmStream => _pcmCtrl.stream;
  
  /// Stream of normalized input volumes (0.0 to 1.0).
  Stream<double> get volumeStream => _volumeCtrl.stream;
  
  /// Whether the recorder is currently capturing audio.
  bool get isRecording => _recording;

  /// Ensures that the native recording hardware/layer is initialized.
  Future<void> _ensureInit() async {
    if (kIsWeb || _initialized) return;
    await _recorder.openRecorder();
    await _recorder.setSubscriptionDuration(
      const Duration(milliseconds: AudioConfig.subscriptionDurationMs),
    );
    _initialized = true;
  }

  /// Starts the audio capture pipeline, redirecting native/web samples to the frame buffer.
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
      numChannels: AudioConfig.channelCount,
      sampleRate: AudioConfig.inputSampleRate,
      audioSource: AudioSource.voice_communication,
    );

    _recorder.onProgress?.listen((e) {
      final vol = ((e.decibels ?? AudioConfig.minDecibels) - AudioConfig.minDecibels) / AudioConfig.decibelRange;
      if (!_volumeCtrl.isClosed) _volumeCtrl.add(vol.clamp(0.0, 1.0));
    });
  }

  /// Stops recording and cancels active subscriptions.
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

  /// Calculates the Root-Mean-Square (RMS) amplitude of a PCM16 frame.
  double _pcmRms(Uint8List pcm16) {
    if (pcm16.length < 2) return 0;
    final view = ByteData.sublistView(pcm16);
    final count = pcm16.length ~/ 2;
    double sum = 0;
    for (int i = 0; i < count; i++) {
      final s = view.getInt16(i * 2, Endian.little) / AudioConfig.maxPcmValue;
      sum += s * s;
    }
    return math.sqrt(sum / count).clamp(0.0, 1.0);
  }

  /// Releases audio recorder resources.
  void dispose() {
    stop();
    _pcmCtrl.close();
    _volumeCtrl.close();
    if (!kIsWeb && _initialized) {
      _recorder.closeRecorder();
    }
  }
}

/// A lightweight, client-side Voice Activity Detector (VAD).
/// It analyzes short 40ms audio frames using:
/// 1. RMS Energy (detects vocal power relative to a threshold).
/// 2. Zero-Crossing Rate (ZCR) (identifies vocal cord vibrations and filters out sibilance/static).
/// Holds a circular pre-buffer to recover leading consonants, and applies hangover time to
/// prevent premature speech muting during standard mid-sentence pauses.
class ClientVoiceActivityDetector {
  /// The energy threshold (RMS) above which a frame might be considered voice.
  final double rmsThreshold;
  
  /// The minimum zero-crossing rate expected for voiced human speech.
  final double zcrMin;
  
  /// The maximum zero-crossing rate permitted for voiced human speech.
  final double zcrMax;
  
  /// How long speech state remains active after energy drops below threshold (ms).
  final Duration hangoverDuration;
  
  /// The duration of leading voice samples preserved before the onset of speech.
  final Duration preBufferDuration;

  bool _isSpeechActive = false;
  DateTime? _lastSpeechTime;

  /// Holds silent/pre-speech frames to avoid clipping the start of words.
  final List<Uint8List> _preBuffer = [];
  
  /// The maximum number of frames stored in the pre-buffer.
  final int _maxPreBufferPackets;

  ClientVoiceActivityDetector({
    this.rmsThreshold = AudioConfig.defaultRmsThreshold,
    this.zcrMin = AudioConfig.zcrMin,
    this.zcrMax = AudioConfig.zcrMax,
    this.hangoverDuration = const Duration(milliseconds: AudioConfig.hangoverDurationMs),
    this.preBufferDuration = const Duration(milliseconds: AudioConfig.preBufferDurationMs),
    int packetDurationMs = AudioConfig.packetDurationMs,
  }) : _maxPreBufferPackets = preBufferDuration.inMilliseconds ~/ packetDurationMs;

  /// Returns whether voice activity is currently active.
  bool get isSpeechActive => _isSpeechActive;

  /// Analyzes a PCM16 audio frame and determines if it represents active human speech.
  /// Manages hangover timing and pre-buffering.
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

    // Keep pre-buffer populated during silence so consonants are not clipped
    if (!_isSpeechActive) {
      _preBuffer.add(pcm16);
      if (_preBuffer.length > _maxPreBufferPackets) {
        _preBuffer.removeAt(0);
      }
    }

    return _isSpeechActive;
  }

  /// Retrieves and clears the leading silence frames collected prior to speech onset.
  List<Uint8List> getAndClearPreBuffer() {
    final copy = List<Uint8List>.from(_preBuffer);
    _preBuffer.clear();
    return copy;
  }

  /// Resets the VAD tracking states.
  void reset() {
    _isSpeechActive = false;
    _lastSpeechTime = null;
    _preBuffer.clear();
  }

  /// Helper to calculate root-mean-square amplitude of sample list.
  double _calculateRms(Uint8List pcm16) {
    final view = ByteData.sublistView(pcm16);
    final count = pcm16.length ~/ 2;
    double sum = 0.0;
    for (int i = 0; i < count; i++) {
      final s = view.getInt16(i * 2, Endian.little) / AudioConfig.maxPcmValue;
      sum += s * s;
    }
    return math.sqrt(sum / count);
  }

  /// Helper to calculate zero-crossing rate.
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
