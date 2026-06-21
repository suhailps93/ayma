// No-op audio stubs for iOS/Android — real implementation is in web_audio_impl.dart on web.
import 'dart:typed_data';

class WebMicCapture {
  Future<void> start(void Function(Uint8List pcm16) onData) async {}
  void stop() {}
}

class WebPcmPlayer {
  void play(Uint8List pcm16) {}
  void stop() {}
}
