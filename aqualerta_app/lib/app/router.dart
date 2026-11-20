import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:aqualerta/core/atualizacao/aviso_atualizacao.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:aqualerta/core/data/carta_datasource.dart';
import 'package:aqualerta/core/notificacoes/avisos_service.dart';
import 'package:aqualerta/features/settings/presentation/cubit/notificacoes_cubit.dart';
import 'package:aqualerta/core/state/painel_cubit.dart';
import 'package:aqualerta/features/alerts/presentation/screens/alertas_screen.dart';
import 'package:aqualerta/features/alerts/presentation/screens/detalhe_alerta_screen.dart';
import 'package:aqualerta/features/map/presentation/screens/mapa_screen.dart';
import 'package:aqualerta/features/regions/presentation/screens/rios_screen.dart';
import 'package:aqualerta/features/settings/presentation/screens/perfil_screen.dart';
import 'screens/login_screen.dart';

final _raiz = GlobalKey<NavigatorState>();
final _abas = GlobalKey<NavigatorState>();

final router = GoRouter(
  navigatorKey: _raiz,
  initialLocation: '/map',
  redirect: (context, state) {
    final logado = Supabase.instance.client.auth.currentUser != null;
    final noLogin = state.matchedLocation == '/login';
    if (!logado && !noLogin) return '/login';
    if (logado && noLogin) return '/map';
    return null;
  },
  routes: [
    GoRoute(path: '/login', builder: (_, __) => const LoginScreen()),
    ShellRoute(
      navigatorKey: _abas,
      builder: (context, state, child) => BlocProvider(
        // Criado depois do login: as consultas precisam do usuário autenticado.
        create: (_) => PainelCubit(CartaDatasource()),
        child: _OuvinteAvisos(child: _Abas(child: child)),
      ),
      routes: [
        GoRoute(
            path: '/map',
            pageBuilder: (_, __) =>
                const NoTransitionPage(child: MapaScreen())),
        GoRoute(
          path: '/alerts',
          pageBuilder: (_, __) =>
              const NoTransitionPage(child: AlertasScreen()),
          routes: [
            GoRoute(
                path: ':id',
                builder: (_, s) =>
                    DetalheAlertaScreen(alertaId: s.pathParameters['id']!)),
          ],
        ),
        GoRoute(
            path: '/rios',
            pageBuilder: (_, __) =>
                const NoTransitionPage(child: RiosScreen())),
        GoRoute(
            path: '/perfil',
            pageBuilder: (_, __) =>
                const NoTransitionPage(child: PerfilScreen())),
        // Endereços antigos continuam funcionando.
        GoRoute(path: '/regions', redirect: (_, __) => '/rios'),
        GoRoute(path: '/settings', redirect: (_, __) => '/perfil'),
      ],
    ),
  ],
);

class _Abas extends StatelessWidget {
  const _Abas({required this.child});
  final Widget child;

  static const _rotas = ['/map', '/alerts', '/rios', '/perfil'];

  @override
  Widget build(BuildContext context) {
    final local = GoRouterState.of(context).uri.path;
    final indice =
        _rotas.indexWhere(local.startsWith).clamp(0, _rotas.length - 1);
    final ativos =
        context.select<PainelCubit, int>((c) => c.state.ativos.length);

    return Scaffold(
      body: child,
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const AvisoAtualizacao(),
          NavigationBar(
            selectedIndex: indice,
            onDestinationSelected: (i) => context.go(_rotas[i]),
            destinations: [
              const NavigationDestination(
                  icon: Icon(Icons.map_outlined),
                  selectedIcon: Icon(Icons.map),
                  label: 'Mapa'),
              NavigationDestination(
                icon: Badge(
                    isLabelVisible: ativos > 0,
                    label: _NumeroQuePulsa(ativos),
                    child: const Icon(Icons.notifications_outlined)),
                selectedIcon: Badge(
                    isLabelVisible: ativos > 0,
                    label: _NumeroQuePulsa(ativos),
                    child: const Icon(Icons.notifications)),
                label: 'Alertas',
                tooltip: ativos > 0 ? 'Alertas: $ativos ativos' : 'Alertas',
              ),
              const NavigationDestination(
                  icon: Icon(Icons.straighten), label: 'Rios'),
              const NavigationDestination(
                  icon: Icon(Icons.person_outline),
                  selectedIcon: Icon(Icons.person),
                  label: 'Perfil'),
            ],
          ),
        ],
      ),
    );
  }
}

/// Número de alertas ativos: quando muda, cresce para 1,2x e volta em
/// 150 ms, para chamar o olho sem alarde.
class _NumeroQuePulsa extends StatelessWidget {
  const _NumeroQuePulsa(this.n);
  final int n;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      key: ValueKey(n),
      tween: Tween(begin: 1.2, end: 1),
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 150),
      curve: Curves.easeOut,
      builder: (_, escala, filho) =>
          Transform.scale(scale: escala, child: filho),
      child: Text('$n'),
    );
  }
}

/// Mostra uma notificação quando chega um alerta novo numa região seguida.
/// Os alertas que já existiam ao abrir o app não geram aviso.
class _OuvinteAvisos extends StatefulWidget {
  const _OuvinteAvisos({required this.child});
  final Widget child;

  @override
  State<_OuvinteAvisos> createState() => _OuvinteAvisosState();
}

class _OuvinteAvisosState extends State<_OuvinteAvisos> {
  Set<String>? _vistos;

  @override
  Widget build(BuildContext context) {
    return BlocListener<PainelCubit, Painel>(
      listenWhen: (antes, depois) =>
          depois.temDados && antes.alertas != depois.alertas,
      listener: (context, painel) {
        final ativos = painel.ativos;
        if (_vistos == null) {
          _vistos = {for (final a in ativos) a.id};
          return;
        }
        final prefs = context.read<NotificacoesCubit>().state;
        for (final a in ativos) {
          if (_vistos!.add(a.id) && painel.seguidas.contains(a.regiaoId)) {
            AvisosService.instancia.avisar(a, prefs);
          }
        }
      },
      child: widget.child,
    );
  }
}
