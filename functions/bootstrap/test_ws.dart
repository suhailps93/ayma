import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  final payload = jsonDecode(File('setup.json').readAsStringSync());
  final token = payload['token'];
  final setupPayload = payload['setup'];
  final wsUrl = "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1alpha.GenerativeService.BidiGenerateContentConstrained";
  
  Map<String, dynamic> normalizeSetup(dynamic setup) {
    dynamic normalize(dynamic value) {
      if (value is Map) {
        return value.map((k, v) {
          final newKey = k is String ? k.replaceAllMapped(RegExp(r'_([a-z])'), (m) => m[1]!.toUpperCase()) : k;
          return MapEntry(newKey.toString(), normalize(v));
        });
      }
      if (value is List) return value.map(normalize).toList();
      return value;
    }
    return normalize(setup);
  }

  final wsUri = Uri.parse(wsUrl).replace(queryParameters: {'access_token': token});
  
  try {
    final ws = await WebSocket.connect(wsUri.toString());
    ws.pingInterval = Duration(milliseconds: 1); // FORCE A PING QUICKLY
    ws.listen(
      (message) {
        print('Received: $message');
      },
      onDone: () {
        print('WebSocket closed: ${ws.closeCode} - ${ws.closeReason}');
        exit(0);
      },
    );
    
    final normalized = normalizeSetup(setupPayload);
    final setupMessage = jsonEncode({'setup': normalized});
    ws.add(setupMessage);
    
    await Future.delayed(Duration(seconds: 3));
    ws.close();
  } catch (e) {
    print('Exception: $e');
  }
}
