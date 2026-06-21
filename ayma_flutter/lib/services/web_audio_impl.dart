// Web Audio API mic capture and PCM playback for Flutter Web voice sessions.
// ignore_for_file: avoid_web_libraries_in_flutter, undefined_class, undefined_function, deprecated_member_use
import 'dart:html' as html;
import 'dart:js_util' as js_util;
import 'dart:typed_data';

class WebMicCapture {
  dynamic _ctx;
  html.MediaStream? _stream;
  dynamic _processor;
  dynamic _source;
  bool _active = false;

  Future<void> start(void Function(Uint8List pcm16) onData) async {
    final devices = html.window.navigator.mediaDevices;
    if (devices == null) return;

    _stream = await devices.getUserMedia({
      'audio': {
        'sampleRate': 16000,
        'channelCount': 1,
        'echoCancellation': true,
        'noiseSuppression': true,
        'autoGainControl': true,
      },
    });

    // Create context at 16 kHz; some browsers may resample but that's fine.
    final audioContextCtor = js_util.getProperty(html.window, 'AudioContext') ??
        js_util.getProperty(html.window, 'webkitAudioContext');
    if (audioContextCtor == null) return;
    _ctx = js_util.callConstructor(audioContextCtor, [js_util.jsify({'sampleRate': 16000})]);
    await js_util.promiseToFuture(js_util.callMethod(_ctx, 'resume', const []));

    _source = js_util.callMethod(_ctx, 'createMediaStreamSource', [_stream]);
    _processor = js_util.callMethod(_ctx, 'createScriptProcessor', [4096, 1, 1]);

    final onAudioProcess = js_util.getProperty(_processor, 'onaudioprocess');
    if (onAudioProcess != null) {
      js_util.setProperty(_processor, 'onaudioprocess', js_util.allowInterop((event) {
        if (!_active) return;
        final inputBuffer = js_util.getProperty(event, 'inputBuffer');
        final input = js_util.callMethod(inputBuffer, 'getChannelData', [0]) as Float32List;
        final bytes = Uint8List(input.length * 2);
        final view = ByteData.sublistView(bytes);
        for (int i = 0; i < input.length; i++) {
          final s = (input[i].clamp(-1.0, 1.0) * 32767).round();
          view.setInt16(i * 2, s, Endian.little);
        }
        onData(bytes);
      }));
    } else {
      js_util.callMethod(
        js_util.getProperty(_processor, 'addEventListener'),
        'call',
        [
          _processor,
          'audioprocess',
          js_util.allowInterop((event) {
            if (!_active) return;
            final inputBuffer = js_util.getProperty(event, 'inputBuffer');
            final input =
                js_util.callMethod(inputBuffer, 'getChannelData', [0]) as Float32List;
            final bytes = Uint8List(input.length * 2);
            final view = ByteData.sublistView(bytes);
            for (int i = 0; i < input.length; i++) {
              final s = (input[i].clamp(-1.0, 1.0) * 32767).round();
              view.setInt16(i * 2, s, Endian.little);
            }
            onData(bytes);
          }),
        ],
      );
    }
    js_util.callMethod(_source, 'connect', [_processor]);
    
    // Create a silent sink (GainNode with gain 0) to ensure the ScriptProcessorNode
    // continues to fire 'audioprocess' events in all browsers without playing
    // the microphone input back through the speakers.
    final gainNode = js_util.callMethod(_ctx, 'createGain', const []);
    final gainParam = js_util.getProperty(gainNode, 'gain');
    js_util.setProperty(gainParam, 'value', 0.0);
    
    js_util.callMethod(_processor, 'connect', [gainNode]);
    js_util.callMethod(gainNode, 'connect', [js_util.getProperty(_ctx, 'destination')]);
    
    _active = true;
  }

  void stop() {
    _active = false;
    if (_processor != null) {
      js_util.callMethod(_processor, 'disconnect', const []);
    }
    if (_source != null) {
      js_util.callMethod(_source, 'disconnect', const []);
    }
    _stream?.getTracks().forEach((t) => t.stop());
    if (_ctx != null) {
      js_util.callMethod(_ctx, 'close', const []);
    }
    _ctx       = null;
    _stream    = null;
    _processor = null;
    _source    = null;
  }
}

class WebPcmPlayer {
  dynamic _ctx;
  double _nextTime = 0;

  void play(Uint8List pcm16) {
    // Create context lazily — must happen after a user gesture (autoplay policy)
    if (_ctx == null) {
      final audioContextCtor = js_util.getProperty(html.window, 'AudioContext') ??
          js_util.getProperty(html.window, 'webkitAudioContext');
      if (audioContextCtor == null) return;
      _ctx = js_util.callConstructor(
        audioContextCtor,
        [js_util.jsify({'sampleRate': 24000})],
      );
    }
    final ctx = _ctx!;
    js_util.callMethod(ctx, 'resume', const []); // resume in case it was suspended

    final sampleCount  = pcm16.length ~/ 2;
    final audioBuffer = js_util.callMethod(ctx, 'createBuffer', [1, sampleCount, 24000]);
    final channelData = js_util.callMethod(audioBuffer, 'getChannelData', [0]) as Float32List;
    final view         = ByteData.sublistView(pcm16);

    for (int i = 0; i < sampleCount; i++) {
      channelData[i] = view.getInt16(i * 2, Endian.little) / 32768.0;
    }

    final sourceNode = js_util.callMethod(ctx, 'createBufferSource', const []);
    js_util.setProperty(sourceNode, 'buffer', audioBuffer);
    js_util.callMethod(sourceNode, 'connect', [js_util.getProperty(ctx, 'destination')]);

    final now = (js_util.getProperty(ctx, 'currentTime') as num?)?.toDouble() ?? 0.0;
    if (_nextTime < now) _nextTime = now;
    js_util.callMethod(sourceNode, 'start', [_nextTime]);
    final duration = (js_util.getProperty(audioBuffer, 'duration') as num?)?.toDouble() ?? 0.0;
    _nextTime += duration;
  }

  void stop() {
    if (_ctx != null) {
      js_util.callMethod(_ctx, 'close', const []);
    }
    _ctx      = null;
    _nextTime = 0;
  }
}
