import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:aqualerta/shared/theme/app_theme.dart';
import 'router.dart';

class AqualertaApp extends StatefulWidget {
  const AqualertaApp({super.key});

  @override
  State<AqualertaApp> createState() => _AqualertaAppState();
}

class _AqualertaAppState extends State<AqualertaApp> {
  late final GoRouter _router;

  @override
  void initState() {
    super.initState();
    _router = router;

    Supabase.instance.client.auth.onAuthStateChange.listen((data) {
      final event = data.event;
      if (event == AuthChangeEvent.signedOut) {
        _router.go('/login');
      } else if (event == AuthChangeEvent.signedIn) {
        _router.go('/map');
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'Aqualerta',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark,
      darkTheme: AppTheme.dark,
      themeMode: ThemeMode.dark,
      routerConfig: _router,
      builder: (context, child) {
        // Corrigido: usar textScaler em vez de textScaleFactor (deprecado)
        return MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: const TextScaler.linear(1.0),
          ),
          child: child!,
        );
      },
    );
  }
}
