import 'package:animations/animations.dart';
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
    // Endereços antigos continuam funcionando.
    GoRoute(path: '/regions', redirect: (_, __) => '/rios'),
    GoRoute(path: '/settings', redirect: (_, __) => '/perfil'),
    // Cada aba tem a própria pilha e fica viva ao trocar (como nos apps
    // grandes): voltar ao Mapa não recarrega nem perde a posição.
    StatefulShellRoute(
      builder: (context, state, shell) => BlocProvider(
        // Criado depois do login: as consultas precisam do usuário autenticado.
        create: (_) => PainelCubit(CartaDatasource()),
        child: _OuvinteAvisos(child: _Abas(shell: shell)),
      ),
      navigatorContainerBuilder: (context, shell, filhos) =>
          TrocaDeAbas(indice: shell.currentIndex, filhos: filhos),
      branches: [
        StatefulShellBranch(routes: [
          GoRoute(path: '/map', builder: (_, __) => const MapaScreen()),
        ]),
        StatefulShellBranch(routes: [
          GoRoute(
            path: '/alerts',
            builder: (_, __) => const AlertasScreen(),
            routes: [
              GoRoute(
                  path: ':id',
                  builder: (_, s) =>
                      DetalheAlertaScreen(alertaId: s.pathParameters['id']!)),
            ],
          ),
        ]),
        StatefulShellBranch(routes: [
          GoRoute(path: '/rios', builder: (_, __) => const RiosScreen()),
        ]),
        StatefulShellBranch(routes: [
          GoRoute(path: '/perfil', builder: (_, __) => const PerfilScreen()),
        ]),
      ],
    ),
  ],
);

/// Troca de aba no padrão "fade through" do Material Design, o mesmo dos
/// apps do Google para o menu de baixo: a tela atual some (primeiros 30%),
/// depois a nova aparece crescendo de 92% para 100%. As duas nunca se
/// misturam, e não sugere arrastar de lado (as abas não são uma sequência).
/// 350 ms: tela inteira mudando pede um pouco mais que um botão. Sem
/// movimento quando o celular pede para reduzir animações.
class TrocaDeAbas extends StatefulWidget {
  const TrocaDeAbas({required this.indice, required this.filhos});
  final int indice;
  final List<Widget> filhos;

  static const duracao = Duration(milliseconds: 350);

  @override
  State<TrocaDeAbas> createState() => TrocaDeAbasEstado();
}

class TrocaDeAbasEstado extends State<TrocaDeAbas>
    with SingleTickerProviderStateMixin {
  late final _troca =
      AnimationController(vsync: this, duration: TrocaDeAbas.duracao, value: 1)
        ..addStatusListener((s) {
          if (s == AnimationStatus.completed && mounted) {
            setState(() => _anterior = null);
          }
        });
  int? _anterior;

  @override
  void didUpdateWidget(TrocaDeAbas antigo) {
    super.didUpdateWidget(antigo);
    if (antigo.indice == widget.indice) return;
    if (MediaQuery.disableAnimationsOf(context)) {
      _anterior = null;
      _troca.value = 1;
    } else {
      _anterior = antigo.indice;
      _troca.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _troca.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final fundo = Theme.of(context).scaffoldBackgroundColor;
    return Stack(
      fit: StackFit.expand,
      children: [
        for (var i = 0; i < widget.filhos.length; i++) _camada(i, fundo),
      ],
    );
  }

  Widget _camada(int i, Color fundo) {
    final atual = i == widget.indice;
    final saindo = i == _anterior;
    // Mesma estrutura para todas as abas, sempre: só as animações mudam.
    // Assim nenhuma aba é recriada (e perde o estado) ao trocar.
    return Offstage(
      key: ValueKey(i),
      offstage: !atual && !saindo,
      child: TickerMode(
        enabled: atual || saindo,
        child: IgnorePointer(
          ignoring: !atual,
          child: FadeThroughTransition(
            animation: atual ? _troca : kAlwaysCompleteAnimation,
            secondaryAnimation: saindo ? _troca : kAlwaysDismissedAnimation,
            fillColor: fundo,
            child: widget.filhos[i],
          ),
        ),
      ),
    );
  }
}

/// Rotas das abas, na ordem do menu de baixo.
const rotasDasAbas = ['/map', '/alerts', '/rios', '/perfil'];

int indiceDaAba(String caminho) => rotasDasAbas
    .indexWhere(caminho.startsWith)
    .clamp(0, rotasDasAbas.length - 1);

class Abas {
  Abas._();

  static StatefulNavigationShell? _shell;

  /// Vai para a aba [destino]. Tocar na aba em que já está volta ao início
  /// dela (ex.: do detalhe de um alerta para a lista), como nos apps grandes.
  static void irPara(BuildContext context, int destino) {
    final shell = _shell;
    if (shell == null) {
      context.go(rotasDasAbas[destino]);
      return;
    }
    shell.goBranch(destino, initialLocation: destino == shell.currentIndex);
  }
}

class _Abas extends StatelessWidget {
  const _Abas({required this.shell});
  final StatefulNavigationShell shell;

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
    Abas._shell = shell;
    final indice = shell.currentIndex;
    final ativos =
        context.select<PainelCubit, int>((c) => c.state.ativos.length);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (saiu, _) {
        if (!saiu) _voltar(context, indice);
      },
      child: Scaffold(
        body: shell,
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
