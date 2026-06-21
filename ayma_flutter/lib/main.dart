// App entry point: Firebase init, Riverpod root, go_router, and overlay mini-app.
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'firebase_options.dart';
import 'providers/providers.dart';
import 'router.dart';
import 'theme.dart';

@pragma('vm:entry-point')
void overlayMain() {
  runApp(const _OverlayApp());
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  } catch (e) {
    runApp(_StartupErrorApp(message: e.toString()));
    return;
  }

  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: Color(0xFF080808),
    systemNavigationBarIconBrightness: Brightness.light,
  ));

  runApp(const ProviderScope(child: AymaApp()));
}

class _StartupErrorApp extends StatelessWidget {
  const _StartupErrorApp({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: const Color(0xFF080808),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              'App startup failed:\n$message',
              style: const TextStyle(color: Colors.white70, height: 1.5),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ),
    );
  }
}

class AymaApp extends ConsumerWidget {
  const AymaApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Eagerly activate FCM token registration whenever user auth changes.
    ref.watch(fcmRegistrationProvider);
    final router = ref.watch(routerProvider);
    final themeMode = ref.watch(themeModeProvider);
    return MaterialApp.router(
      title: 'Ayma',
      theme: AymaTheme.light,
      darkTheme: AymaTheme.dark,
      themeMode: themeMode,
      routerConfig: router,
      debugShowCheckedModeBanner: false,
    );
  }
}

// Overlay entry point — runs in a separate Dart isolate when the
// system floating sphere is active (flutter_overlay_window).
class _OverlayApp extends StatelessWidget {
  const _OverlayApp();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: GestureDetector(
        onTap: FlutterOverlayWindow.closeOverlay,
        child: Container(
          width: 80,
          height: 80,
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(
              center: Alignment(-0.30, -0.38),
              radius: 0.82,
              colors: [
                Color(0xFFFFF6EF),
                Color(0xFFEA9858),
                Color(0xFFB86228),
                Color(0xFF5A2408),
              ],
              stops: [0.0, 0.32, 0.68, 1.0],
            ),
            boxShadow: [
              BoxShadow(
                color: Color(0x88CF7628),
                blurRadius: 20,
                spreadRadius: 4,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
