import 'dart:typed_data';

// Stub for non-web platforms — flutter_sound is used instead.
class WebMicCapture {
  Future<void> start(void Function(Uint8List pcm16) onData) async {}
  void stop() {}
}

class WebPcmPlayer {
  void play(Uint8List pcm16) {}
  void stop() {}
}
