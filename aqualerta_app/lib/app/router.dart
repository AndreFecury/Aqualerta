import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:aqualerta/app/voltar.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:aqualerta/core/atualizacao/aviso_atualizacao.dart';
import 'package:aqualerta/core/config/chave_mapa.dart';
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
            pageBuilder: (_, s) => _paginaDeAba(s, const MapaScreen())),
        GoRoute(
          path: '/alerts',
          pageBuilder: (_, s) => _paginaDeAba(s, const AlertasScreen()),
          routes: [
            GoRoute(
                path: ':id',
                builder: (_, s) =>
                    DetalheAlertaScreen(alertaId: s.pathParameters['id']!)),
          ],
        ),
        GoRoute(
            path: '/rios',
            pageBuilder: (_, s) => _paginaDeAba(s, const RiosScreen())),
        GoRoute(
            path: '/perfil',
            pageBuilder: (_, s) => _paginaDeAba(s, const PerfilScreen())),
        // Endereços antigos continuam funcionando.
        GoRoute(path: '/regions', redirect: (_, __) => '/rios'),
        GoRoute(path: '/settings', redirect: (_, __) => '/perfil'),
      ],
    ),
  ],
);

/// Troca de aba: a tela nova entra deslizando um pouco (6% da largura) do
/// lado da aba tocada, com fade, em 240 ms; a antiga some em 120 ms. Curto
/// de propósito: as abas são o que mais se usa no app. Sem movimento quando
/// o celular pede para reduzir animações.
CustomTransitionPage<void> _paginaDeAba(GoRouterState s, Widget tela) =>
    CustomTransitionPage<void>(
      key: s.pageKey,
      child: tela,
      transitionDuration: const Duration(milliseconds: 240),
      reverseTransitionDuration: const Duration(milliseconds: 120),
      transitionsBuilder: (context, animacao, _, filho) {
        if (MediaQuery.disableAnimationsOf(context)) return filho;
        final curva = CurvedAnimation(
            parent: animacao,
            curve: const Cubic(0.16, 1, 0.3, 1),
            reverseCurve: Curves.easeIn);
        return FadeTransition(
          opacity: curva,
          child: SlideTransition(
            position:
                Tween(begin: Offset(0.06 * Abas.direcao, 0), end: Offset.zero)
                    .animate(curva),
            child: filho,
          ),
        );
      },
    );

/// Rotas das abas, na ordem do menu de baixo.
const rotasDasAbas = ['/map', '/alerts', '/rios', '/perfil'];

int indiceDaAba(String caminho) => rotasDasAbas
    .indexWhere(caminho.startsWith)
    .clamp(0, rotasDasAbas.length - 1);

class Abas {
  Abas._();

  /// 1 = a aba nova está à direita da anterior; -1 = à esquerda.
  static double direcao = 1;

  static void irPara(BuildContext context, int destino) {
    final atual = indiceDaAba(GoRouterState.of(context).uri.path);
    if (destino == atual) return;
    direcao = destino > atual ? 1 : -1;
    context.go(rotasDasAbas[destino]);
  }
}

class _Abas extends StatelessWidget {
  const _Abas({required this.child});
  final Widget child;

  static DateTime? _ultimoVoltar;

  /// Ordem do voltar: a tela desfaz o que puder; fora do Mapa, volta ao
  /// Mapa; no Mapa, pede um segundo toque para sair (em até 2 s).
  static void _voltar(BuildContext context, int indice) {
    if (Voltar.tratar()) return;
    if (indice != 0) {
      Abas.irPara(context, 0);
      return;
    }
    final agora = DateTime.now();
    if (_ultimoVoltar != null &&
        agora.difference(_ultimoVoltar!) < const Duration(seconds: 2)) {
      SystemNavigator.pop();
      return;
    }
    _ultimoVoltar = agora;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(
        content: Text('Toque em voltar de novo para sair'),
        duration: Duration(seconds: 2),
      ));
  }

  @override
  Widget build(BuildContext context) {
    final local = GoRouterState.of(context).uri.path;
    final indice = indiceDaAba(local);
    final ativos =
        context.select<PainelCubit, int>((c) => c.state.ativos.length);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (saiu, _) {
        if (!saiu) _voltar(context, indice);
      },
      child: Scaffold(
        body: child,
        bottomNavigationBar: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const AvisoAtualizacao(),
            NavigationBar(
              selectedIndex: indice,
              onDestinationSelected: (i) => Abas.irPara(context, i),
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
  void initState() {
    super.initState();
    // Já logado: busca a chave do mapa (não vem dentro da APK).
    ChaveMapa.carregar();
  }

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
