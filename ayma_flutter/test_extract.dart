import 'dart:convert';

void main() {
  final setupJson = '''
  {
    "system_instruction": {
      "parts": [
        {"text": "Hello world"}
      ]
    }
  }
  ''';
  final setup = jsonDecode(setupJson) as Map<String, dynamic>;
  final geminiParts = setup['system_instruction']['parts'];
  if (geminiParts is List) {
    final extracted = geminiParts
        .whereType<Map<String, dynamic>>()
        .map((p) => p['text'] as String? ?? '')
        .join('')
        .trim();
    // ignore: avoid_print
    print('Extracted: $extracted');
  }
}
