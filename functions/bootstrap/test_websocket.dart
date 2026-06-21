import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  print('Requesting bootstrap...');
  
  final httpClient = HttpClient();
  final req = await httpClient.postUrl(Uri.parse('https://ayma-bootstrap-235381544962.us-central1.run.app/bootstrap'));
  req.headers.set('Content-Type', 'application/json');
  req.add(utf8.encode(jsonEncode({"uid": "test_uid"})));
  
  final res = await req.close();
  final responseBody = await res.transform(utf8.decoder).join();
  
  if (res.statusCode != 200) {
    print('Failed to bootstrap: ${res.statusCode} - $responseBody');
    exit(1);
  }
  
  final data = jsonDecode(responseBody);
  final wsUrl = data['websocket_url'];
  final token = data['token'];
  final setupPayload = data['setup'];
  
  print('Got websocket_url: $wsUrl');
  print('Got token: $token');
  
  final wsUri = Uri.parse(wsUrl).replace(queryParameters: {'access_token': token});
  print('Connecting to $wsUri...');
  
  try {
    final ws = await WebSocket.connect(wsUri.toString());
    print('WebSocket connected!');
    
    ws.listen(
      (message) {
        print('Received: $message');
      },
      onDone: () {
        print('WebSocket closed: ${ws.closeCode} - ${ws.closeReason}');
        exit(0);
      },
      onError: (err) {
        print('WebSocket error: $err');
      }
    );
    
    final setupMessage = jsonEncode({'setup': setupPayload});
    print('Sending setup: $setupMessage');
    ws.add(setupMessage);
    
    // Wait for 10 seconds to see if it closes
    await Future.delayed(Duration(seconds: 10));
    print('Kept alive for 10 seconds. Success!');
    ws.close();
  } catch (e) {
    print('Exception: $e');
  }
}
