import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

Future<String?> dumpAudioDebugCapture({
  required Uint8List bytes,
  required String mimeType,
  required int sampleRate,
  required int channels,
}) async {
  final tempDir = await getTemporaryDirectory();
  final now = DateTime.now().millisecondsSinceEpoch;
  final basePath = '${tempDir.path}/ayma_gemini_output_$now';
  final pcmFile = File('$basePath.pcm');
  final metaFile = File('$basePath.txt');

  await pcmFile.writeAsBytes(bytes, flush: true);
  await metaFile.writeAsString(
    [
      'mime=$mimeType',
      'sample_rate=$sampleRate',
      'channels=$channels',
      'bytes=${bytes.length}',
      'format=signed 16-bit little-endian PCM',
    ].join('\n'),
    flush: true,
  );

  return pcmFile.path;
}
