import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:aqualerta/shared/theme/aqua_theme.dart';
import 'package:aqualerta/features/settings/presentation/cubit/aparencia_cubit.dart';
import 'package:aqualerta/features/settings/presentation/cubit/notificacoes_cubit.dart';
import 'package:aqualerta/features/map/data/satelite_repository.dart';
import 'package:aqualerta/features/map/presentation/cubit/camadas_cubit.dart';
import 'router.dart';

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
    return MultiBlocProvider(
      providers: [
        BlocProvider(create: (_) => AparenciaCubit(widget.preferencias)),
        BlocProvider(
            create: (_) => NotificacoesCubit(widget.preferencias,
                cliente: Supabase.instance.client)),
        BlocProvider(create: (_) => CamadasCubit(widget.preferencias)),
        BlocProvider(create: (_) => SateliteCubit(SateliteRepository())),
      ],
      child: BlocBuilder<AparenciaCubit, Aparencia>(
        builder: (context, aparencia) => MaterialApp.router(
          title: 'AquaAlerta',
          debugShowCheckedModeBanner: false,
          theme: AquaTheme.claro,
          darkTheme: AquaTheme.escuro,
          themeMode: aparencia.tema,
          routerConfig: _router,
          // O tamanho do texto segue o celular (ou a escolha feita no Perfil),
          // dentro de limites que não quebram o layout.
          builder: (context, child) {
            final mq = MediaQuery.of(context);
            return MediaQuery(
              data:
                  mq.copyWith(textScaler: aparencia.escalaFinal(mq.textScaler)),
              child: child!,
            );
          },
        ),
      ),
    );
  }
}
