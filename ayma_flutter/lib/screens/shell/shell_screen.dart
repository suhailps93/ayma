import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../providers/providers.dart';
import '../../theme.dart';

class ShellScreen extends ConsumerWidget {
  final Widget child;
  const ShellScreen({super.key, required this.child});

  static const _tabs = [
    (path: '/chat', kind: 'talk', label: 'Talk'),
    (path: '/matches', kind: 'matches', label: 'Matches'),
    (path: '/explore', kind: 'explore', label: 'Explore'),
    (path: '/notifications', kind: 'notifications', label: 'Signals'),
    (path: '/profile', kind: 'profile', label: 'You'),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final location = GoRouterState.of(context).matchedLocation;
    final unread = ref.watch(
        notificationsProvider.select((ns) => ns.where((n) => !n.read).length));
    final bottomInset = MediaQuery.paddingOf(context).bottom;

    int selectedIndex = _tabs.indexWhere((t) => location.startsWith(t.path));
    if (selectedIndex == -1) selectedIndex = 0;

    return Scaffold(
      backgroundColor: AymaColors.bg,
      body: Padding(
        padding: EdgeInsets.only(bottom: 56 + bottomInset),
        child: child,
      ),
      extendBody: true,
      bottomNavigationBar: _AymaTabBar(
        tabs: _tabs,
        selectedIndex: selectedIndex,
        unreadCount: unread,
        onTap: (i) => context.go(_tabs[i].path),
      ),
    );
  }
}

class _AymaTabBar extends StatelessWidget {
  final List<({String path, String kind, String label})> tabs;
  final int selectedIndex;
  final int unreadCount;
  final ValueChanged<int> onTap;

  const _AymaTabBar({
    required this.tabs,
    required this.selectedIndex,
    required this.unreadCount,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        border: Border(
          top: BorderSide(color: Color(0x0AFFFFFF), width: 0.5),
        ),
      ),
      child: ClipRect(
        child: Container(
          color: AymaColors.bg.withValues(alpha: 0.92),
          child: SafeArea(
            top: false,
            child: SizedBox(
              height: 56,
              child: Row(
                children: List.generate(tabs.length, (i) {
                  final tab = tabs[i];
                  final active = i == selectedIndex;
                  final isSignals = tab.kind == 'notifications';

                  return Expanded(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => onTap(i),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Stack(
                            clipBehavior: Clip.none,
                            children: [
                              _TabIcon(kind: tab.kind, active: active),
                              if (isSignals && unreadCount > 0)
                                Positioned(
                                  top: -4,
                                  right: -6,
                                  child: Container(
                                    width: 14,
                                    height: 14,
                                    decoration: const BoxDecoration(
                                      color: AymaColors.accent,
                                      shape: BoxShape.circle,
                                    ),
                                    child: Center(
                                      child: Text(
                                        unreadCount > 9 ? '9+' : '$unreadCount',
                                        style: const TextStyle(
                                          color: Colors.black,
                                          fontSize: 8,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            tab.label.toUpperCase(),
                            style: AymaFonts.mono(
                              size: 8,
                              color: active ? AymaColors.fg : AymaColors.fgMute,
                              letterSpacing: 0.15,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                }),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TabIcon extends StatelessWidget {
  final String kind;
  final bool active;
  const _TabIcon({required this.kind, required this.active});

  @override
  Widget build(BuildContext context) {
    final c = active ? AymaColors.fg : AymaColors.fgMute;
    final accentC = active ? AymaColors.accent : Colors.transparent;

    return SizedBox(
      width: 22,
      height: 22,
      child: CustomPaint(
        painter: _TabIconPainter(kind: kind, color: c, accentColor: accentC),
      ),
    );
  }
}

class _TabIconPainter extends CustomPainter {
  final String kind;
  final Color color;
  final Color accentColor;

  _TabIconPainter(
      {required this.kind, required this.color, required this.accentColor});

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = Paint()
      ..color = color
      ..strokeWidth = 1.4
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    // Scale from 20×20 viewBox to actual size
    final sx = size.width / 20;
    final sy = size.height / 20;
    canvas.scale(sx, sy);

    switch (kind) {
      case 'talk':
        // Inner dot (accent filled)
        final dotPaint = Paint()
          ..color = accentColor != Colors.transparent ? accentColor : color
          ..style = PaintingStyle.fill;
        canvas.drawCircle(const Offset(10, 10), 2.2, dotPaint);
        canvas.drawCircle(const Offset(10, 10), 5, stroke);
        final outerStroke = Paint()
          ..color = color.withValues(alpha: 0.5)
          ..strokeWidth = 1.4
          ..style = PaintingStyle.stroke;
        canvas.drawCircle(const Offset(10, 10), 8, outerStroke);

      case 'matches':
        canvas.drawRRect(
          RRect.fromRectAndRadius(
              const Rect.fromLTWH(3, 3, 6, 8), const Radius.circular(1)),
          stroke,
        );
        canvas.drawRRect(
          RRect.fromRectAndRadius(
              const Rect.fromLTWH(11, 6, 6, 8), const Radius.circular(1)),
          stroke,
        );
        final dotPaint = Paint()
          ..color = color
          ..style = PaintingStyle.fill;
        canvas.drawCircle(const Offset(6, 13.5), 0.8, dotPaint);
        canvas.drawCircle(const Offset(14, 16.5), 0.8, dotPaint);

      case 'explore':
        canvas.drawCircle(const Offset(9, 9), 5.5, stroke);
        canvas.drawLine(const Offset(13, 13), const Offset(17, 17), stroke);

      case 'notifications':
        canvas.drawPath(
          Path()
            ..moveTo(3, 10)
            ..quadraticBezierTo(10, 3, 17, 10),
          stroke,
        );
        final inner = Paint()
          ..color = color.withValues(alpha: 0.6)
          ..strokeWidth = 1.4
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round;
        canvas.drawPath(
          Path()
            ..moveTo(6, 11.5)
            ..quadraticBezierTo(10, 8, 14, 11.5),
          inner,
        );
        final dotPaint = Paint()
          ..color = color
          ..style = PaintingStyle.fill;
        canvas.drawCircle(const Offset(10, 13.5), 0.9, dotPaint);

      case 'profile':
        canvas.drawCircle(const Offset(10, 7), 3, stroke);
        canvas.drawPath(
          Path()
            ..moveTo(3.5, 17)
            ..quadraticBezierTo(10, 10.5, 16.5, 17),
          stroke,
        );
    }
  }

  @override
  bool shouldRepaint(_TabIconPainter o) =>
      o.kind != kind || o.color != color || o.accentColor != accentColor;
}
