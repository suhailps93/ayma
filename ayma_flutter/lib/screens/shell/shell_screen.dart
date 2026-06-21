// App shell: bottom nav (chat, matches, explore, profile, notifications, settings) and overlay hook.
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../providers/providers.dart';
import '../../services/audio_service.dart';
import '../../services/overlay_service.dart';
import '../../theme.dart';

class ShellScreen extends ConsumerStatefulWidget {
  final Widget child;
  const ShellScreen({super.key, required this.child});

  @override
  ConsumerState<ShellScreen> createState() => _ShellScreenState();
}

class _ShellScreenState extends ConsumerState<ShellScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController _pulseCtrl;
  late final Animation<double> _pulse;
  bool _pendingOverlayPermissionNeeded = false;

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    )..repeat(reverse: true);
    _pulse = CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut);
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (kIsWeb) return; // overlay window is Android-only
      if (!await OverlayService.isGranted()) {
        if (mounted) _showOverlayPermissionDialog();
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pulseCtrl.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final connected =
        ref.read(audioServiceProvider).state != SessionState.disconnected;
    if ((state == AppLifecycleState.hidden ||
         state == AppLifecycleState.paused) && connected) {
      OverlayService.showOverlay().then((shown) {
        if (!shown && mounted) {
          _pendingOverlayPermissionNeeded = true;
        }
      });
    } else if (state == AppLifecycleState.resumed) {
      OverlayService.hideOverlay();
      if (_pendingOverlayPermissionNeeded && mounted) {
        _pendingOverlayPermissionNeeded = false;
        _showOverlayPermissionDialog();
      }
    }
  }

  void _showOverlayPermissionDialog() {
    // Only show once per session
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A110D),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text(
          'See Ayma while multitasking',
          style: TextStyle(color: Colors.white, fontSize: 16),
        ),
        content: const Text(
          'Grant "Display over other apps" permission so the Ayma sphere stays visible when you switch apps.',
          style: TextStyle(color: Color(0xFF9E8E7E), fontSize: 13, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Later', style: TextStyle(color: Color(0xFF9E8E7E))),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              OverlayService.requestPermission();
            },
            child: const Text(
              'Grant permission',
              style: TextStyle(color: Color(0xFFC48312), fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final location = GoRouterState.of(context).matchedLocation;
    final unread = ref.watch(
        notificationsProvider.select((ns) => ns.where((n) => !n.read).length));
    final connected = ref.watch(audioServiceProvider.select((a) =>
        a.state == SessionState.listening ||
        a.state == SessionState.ready ||
        a.state == SessionState.speaking ||
        a.state == SessionState.thinking));
    final networkAsync = ref.watch(networkConnectedProvider);
    final isOffline = networkAsync.whenOrNull(data: (v) => !v) ?? false;

    final mq = MediaQuery.of(context);
    final bottomInset = mq.padding.bottom;
    final bottomNavH = 56.0 + bottomInset;

    int selectedIndex = _tabs.indexWhere((t) => location.startsWith(t.path));
    if (selectedIndex == -1) selectedIndex = 0;

    return Scaffold(
      backgroundColor: context.ac.bg,
      extendBody: true,
      body: Column(
        children: [
          if (isOffline) const _OfflineBanner(),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: bottomNavH),
              child: widget.child,
            ),
          ),
        ],
      ),
      bottomNavigationBar: AnimatedBuilder(
        animation: _pulse,
        builder: (_, __) => _AymaTabBar(
          tabs: _tabs,
          selectedIndex: selectedIndex,
          unreadCount: unread,
          connected: connected,
          pulseValue: _pulse.value,
          onTap: (i) {
            final onChatTab = location.startsWith('/chat');
            if (i == 2 && connected && onChatTab) {
              ref.read(audioServiceProvider).disconnect();
            } else {
              context.go(_tabs[i].path);
            }
          },
        ),
      ),
    );
  }

  static const _tabs = [
    (path: '/matches', kind: 'matches', label: 'Matches'),
    (path: '/explore', kind: 'explore', label: 'Explore'),
    (path: '/chat', kind: 'agent', label: 'Ayma'),
    (path: '/notifications', kind: 'notifications', label: 'Signals'),
    (path: '/profile', kind: 'profile', label: 'You'),
  ];
}

class _AymaTabBar extends StatelessWidget {
  final List<({String path, String kind, String label})> tabs;
  final int selectedIndex;
  final int unreadCount;
  final bool connected;
  final double pulseValue;
  final ValueChanged<int> onTap;

  const _AymaTabBar({
    required this.tabs,
    required this.selectedIndex,
    required this.unreadCount,
    required this.connected,
    required this.pulseValue,
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
          color: context.ac.bg.withValues(alpha: 0.92),
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
                              _TabIcon(kind: tab.kind, active: active, connected: connected, pulseValue: pulseValue),
                              if (isSignals && unreadCount > 0)
                                Positioned(
                                  top: -4,
                                  right: -6,
                                  child: Container(
                                    width: 14,
                                    height: 14,
                                    decoration: BoxDecoration(
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
                              color: active ? context.ac.fg : context.ac.fgMute,
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
  final bool connected;
  final double pulseValue;
  const _TabIcon({
    required this.kind,
    required this.active,
    required this.connected,
    required this.pulseValue,
  });

  @override
  Widget build(BuildContext context) {
    if (kind == 'agent') {
      final size = active ? 28.0 : 22.0;
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            center: const Alignment(-0.30, -0.38),
            radius: 0.82,
            colors: connected
                ? const [
                    Color(0xFFFFF6EF),
                    Color(0xFFEA9858),
                    Color(0xFFB86228),
                    Color(0xFF5A2408),
                  ]
                : const [
                    Color(0xFF888888),
                    Color(0xFF444444),
                    Color(0xFF252525),
                    Color(0xFF111111),
                  ],
            stops: const [0.0, 0.32, 0.68, 1.0],
          ),
          boxShadow: connected
              ? [
                  BoxShadow(
                    color: const Color(0xFFCF7628).withValues(alpha: pulseValue * 0.55),
                    blurRadius: 16,
                    spreadRadius: 3,
                  ),
                ]
              : null,
        ),
      );
    }

    final c = active ? context.ac.fg : context.ac.fgMute;
    final accentC = active ? context.ac.accent : Colors.transparent;

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

class _OfflineBanner extends StatelessWidget {
  const _OfflineBanner();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
      color: const Color(0xFF3A1F00),
      child: SafeArea(
        bottom: false,
        child: Row(
          children: [
            const Icon(
              Icons.wifi_off_rounded,
              size: 14,
              color: Color(0xFFE8A455),
            ),
            const SizedBox(width: 8),
            const Expanded(
              child: Text(
                'No internet connection — some features may not work',
                style: TextStyle(
                  color: Color(0xFFE8A455),
                  fontSize: 11,
                  height: 1.3,
                  fontFamily: 'Geist',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
