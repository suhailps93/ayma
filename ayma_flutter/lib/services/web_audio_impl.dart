// ignore_for_file: avoid_web_libraries_in_flutter, undefined_class, undefined_function, deprecated_member_use
import 'dart:html' as html;
import 'dart:typed_data';

/// Real Web Audio API implementation for Flutter Web.
/// Mic → ScriptProcessorNode → PCM16 → callback
/// PCM16 playback via scheduled AudioBufferSourceNodes.

class WebMicCapture {
  html.AudioContext? _ctx;
  html.MediaStream? _stream;
  html.ScriptProcessorNode? _processor;
  html.MediaStreamAudioSourceNode? _source;
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
    _ctx = html.AudioContext({'sampleRate': 16000});
    await _ctx!.resume();

    _source    = _ctx!.createMediaStreamSource(_stream!);
    _processor = _ctx!.createScriptProcessor(4096, 1, 1);

    _processor!.onAudioProcess.listen((html.AudioProcessingEvent event) {
      if (!_active) return;
      // getChannelData returns a Float32List view
      final input  = event.inputBuffer.getChannelData(0);
      final bytes  = Uint8List(input.length * 2);
      final view   = ByteData.sublistView(bytes);
      for (int i = 0; i < input.length; i++) {
        final s = (input[i].clamp(-1.0, 1.0) * 32767).round();
        view.setInt16(i * 2, s, Endian.little);
      }
      onData(bytes);
    });

    _source!.connectNode(_processor!);
    // Must connect to destination for ScriptProcessorNode to fire (browser quirk)
    _processor!.connectNode(_ctx!.destination!);
    _active = true;
  }

  void stop() {
    _active = false;
    _processor?.disconnect();
    _source?.disconnect();
    _stream?.getTracks().forEach((t) => t.stop());
    _ctx?.close();
    _ctx       = null;
    _stream    = null;
    _processor = null;
    _source    = null;
  }
}

class WebPcmPlayer {
  html.AudioContext? _ctx;
  double _nextTime = 0;

  void play(Uint8List pcm16) {
    // Create context lazily — must happen after a user gesture (autoplay policy)
    _ctx ??= html.AudioContext({'sampleRate': 24000});
    final ctx = _ctx!;
    ctx.resume(); // resume in case it was suspended

    final sampleCount  = pcm16.length ~/ 2;
    final audioBuffer  = ctx.createBuffer(1, sampleCount, 24000);
    final channelData  = audioBuffer.getChannelData(0); // Float32List
    final view         = ByteData.sublistView(pcm16);

    for (int i = 0; i < sampleCount; i++) {
      channelData[i] = view.getInt16(i * 2, Endian.little) / 32768.0;
    }

    final sourceNode = ctx.createBufferSource();
    sourceNode.buffer = audioBuffer;
    sourceNode.connectNode(ctx.destination!);

    final now = ctx.currentTime ?? 0.0;
    if (_nextTime < now) _nextTime = now;
    sourceNode.start(_nextTime);
    _nextTime += audioBuffer.duration ?? 0.0;
  }

  void stop() {
    _ctx?.close();
    _ctx      = null;
    _nextTime = 0;
  }
}
