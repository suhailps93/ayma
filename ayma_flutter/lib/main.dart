import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'firebase_options.dart';
import 'router.dart';
import 'theme.dart';

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
    final router = ref.watch(routerProvider);
    return MaterialApp.router(
      title: 'Ayma',
      theme: AymaTheme.dark,
      routerConfig: router,
      debugShowCheckedModeBanner: false,
    );
  }
}
