import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:aqualerta/shared/theme/app_theme.dart';
import 'package:aqualerta/shared/theme/aqua_colors.dart';
import 'package:aqualerta/shared/theme/aqua_theme.dart';
import 'package:aqualerta/features/settings/presentation/cubit/aparencia_cubit.dart';
import 'router.dart';

/// Liga os temas da v3 (claro e "noite no rio").
///
/// Fica desligado enquanto as telas antigas, que usam cores fixas do tema
/// escuro anterior, não forem migradas. Nesse período o app usa o tema antigo
/// com as cores da v3 disponíveis para os componentes novos.
const bool temaV3Ativo = false;

class AqualertaApp extends StatefulWidget {
  const AqualertaApp({required this.preferencias, super.key});

  final SharedPreferences preferencias;

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
    return BlocProvider(
      create: (_) => AparenciaCubit(widget.preferencias),
      child: BlocBuilder<AparenciaCubit, Aparencia>(
        builder: (context, aparencia) => MaterialApp.router(
          title: 'AquaAlerta',
          debugShowCheckedModeBanner: false,
          theme: temaV3Ativo
              ? AquaTheme.claro
              : AppTheme.dark.copyWith(extensions: const [AquaColors.escuro]),
          darkTheme: temaV3Ativo
              ? AquaTheme.escuro
              : AppTheme.dark.copyWith(extensions: const [AquaColors.escuro]),
          themeMode: temaV3Ativo ? aparencia.tema : ThemeMode.dark,
          routerConfig: _router,
          // O tamanho do texto segue o celular (ou a escolha feita no Perfil),
          // dentro de limites que não quebram o layout.
          builder: (context, child) {
            final mq = MediaQuery.of(context);
            return MediaQuery(
              data: mq.copyWith(textScaler: aparencia.escalaFinal(mq.textScaler)),
              child: child!,
            );
          },
        ),
      ),
    );
  }
}
