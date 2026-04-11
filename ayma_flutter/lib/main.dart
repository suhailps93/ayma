import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'providers/providers.dart';
import 'router.dart';
import 'services/auth_storage.dart';
import 'theme.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AuthStorage.load();

  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: Color(0xFF080808),
    systemNavigationBarIconBrightness: Brightness.light,
  ));

  runApp(const ProviderScope(child: AymaApp()));
}

class AymaApp extends ConsumerStatefulWidget {
  const AymaApp({super.key});

  @override
  ConsumerState<AymaApp> createState() => _AymaAppState();
}

class _AymaAppState extends ConsumerState<AymaApp> {
  late final AppLinks _appLinks;

  @override
  void initState() {
    super.initState();
    _appLinks = AppLinks();
    _appLinks.uriLinkStream.listen(_handleDeepLink);
  }

  Future<void> _handleDeepLink(Uri uri) async {
    if (uri.scheme == 'ayma' && uri.host == 'auth') {
      final authService = ref.read(authControllerProvider);
      await authService.handleConfirmationLink(uri);
    }
  }

  @override
  Widget build(BuildContext context) {
    final router = ref.watch(routerProvider);
    return MaterialApp.router(
      title: 'Ayma',
      theme: AymaTheme.dark,
      routerConfig: router,
      debugShowCheckedModeBanner: false,
    );
  }
}
