import 'package:flutter/material.dart';

import '../../services/api_service.dart';
import '../../theme.dart';

class DirectMessageScreen extends StatefulWidget {
  final String targetUserId;
  final String targetName;
  const DirectMessageScreen({
    super.key,
    required this.targetUserId,
    required this.targetName,
  });

  @override
  State<DirectMessageScreen> createState() => _DirectMessageScreenState();
}

class _DirectMessageScreenState extends State<DirectMessageScreen> {
  final _ctrl = TextEditingController();
  bool _sending = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _ctrl.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      await ApiService.sendDirectMessage(
        targetUserId: widget.targetUserId,
        text: text,
      );
      _ctrl.clear();
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.ac.bg,
      appBar: AppBar(
        backgroundColor: context.ac.bg,
        foregroundColor: context.ac.fg,
        elevation: 0,
        title: Text(widget.targetName),
      ),
      body: Column(
        children: [
          Expanded(
            child: StreamBuilder<List<Map<String, dynamic>>>(
              stream: ApiService.conversationStream(widget.targetUserId),
              builder: (context, snap) {
                final items = snap.data ?? const <Map<String, dynamic>>[];
                if (items.isEmpty) {
                  return Center(
                    child: Text(
                      'No messages yet. Start the conversation.',
                      style: TextStyle(color: context.ac.fgMute),
                    ),
                  );
                }
                return ListView.builder(
                  padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
                  itemCount: items.length,
                  itemBuilder: (_, i) {
                    final m = items[i];
                    final text = (m['text'] as String?) ?? '';
                    final from = (m['from_user_id'] as String?) ?? '';
                    final mine = from == ApiService.uidForClient();
                    return Align(
                      alignment:
                          mine ? Alignment.centerRight : Alignment.centerLeft,
                      child: Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 9),
                        constraints: const BoxConstraints(maxWidth: 280),
                        decoration: BoxDecoration(
                          color: mine ? context.ac.bgCard : context.ac.bgElev,
                          borderRadius: BorderRadius.circular(12),
                          border:
                              Border.all(color: context.ac.lineSoft, width: 0.5),
                        ),
                        child: Text(
                          text,
                          style: TextStyle(color: context.ac.fg, height: 1.4),
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _ctrl,
                      minLines: 1,
                      maxLines: 4,
                      decoration: InputDecoration(
                        hintText: 'Type a message...',
                        filled: true,
                        fillColor: context.ac.bgElev,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide:
                              BorderSide(color: context.ac.lineSoft),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide:
                              BorderSide(color: context.ac.lineSoft),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    onPressed: _sending ? null : _send,
                    icon: Icon(Icons.send_rounded, color: context.ac.accent),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
