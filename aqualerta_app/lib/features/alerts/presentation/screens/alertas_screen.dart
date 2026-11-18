import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:aqualerta/core/domain/carta.dart';
import 'package:aqualerta/core/state/painel_cubit.dart';
import 'package:aqualerta/core/utils/formato.dart';
import 'package:aqualerta/features/settings/presentation/cubit/notificacoes_cubit.dart';
import 'package:aqualerta/shared/theme/aqua_colors.dart';
import 'package:aqualerta/shared/widgets/selo_severidade.dart';
import 'package:aqualerta/shared/widgets/v3.dart';

class AlertasScreen extends StatelessWidget {
  const AlertasScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final painel = context.watch<PainelCubit>().state;
    final minimo = context.watch<NotificacoesCubit>().state.severidadeMinima;
    final c = AquaColors.of(context);
    final t = Theme.of(context).textTheme;

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        body: Column(
          children: [
            const CabecalhoTela(
                titulo: 'Alertas',
                subtitulo: 'Regiões monitoradas pelo AquaAlerta'),
            Material(
              color: c.papel,
              child: TabBar(
                labelColor: c.tinta,
                unselectedLabelColor: c.tinta2,
                labelStyle: t.titleSmall,
                unselectedLabelStyle:
                    t.titleSmall!.copyWith(fontWeight: FontWeight.w500),
                indicatorColor: c.canal,
                indicatorWeight: 3,
                tabs: [
                  Tab(text: 'Ativos (${painel.ativos.length})'),
                  const Tab(text: 'Encerrados'),
                ],
              ),
            ),
            if (painel.erro != null)
              FaixaAviso(
                  texto: painel.erro!,
                  icone: Icons.wifi_off,
                  acao: 'Tentar',
                  aoTocar: context.read<PainelCubit>().carregar),
            Expanded(
              child: TabBarView(
                children: [
                  _Lista(
                    alertas: painel.ativos,
                    carregando: painel.carregando && !painel.temDados,
                    topo: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                                'Você recebe avisos a partir de ${minimo.rotulo}.',
                                style: t.bodyMedium),
                          ),
                          TextButton(
                              onPressed: () => context.go('/perfil'),
                              child: const Text('Alterar')),
                        ],
                      ),
                    ),
                    vazio: const EstadoVazio(
                      titulo: 'Nenhum alerta ativo',
                      texto:
                          'Tudo certo nas regiões monitoradas. Você será avisado se algo mudar.',
                    ),
                  ),
                  _Lista(
                    alertas: painel.encerrados,
                    carregando: painel.carregando && !painel.temDados,
                    vazio: const EstadoVazio(
                      icone: Icons.history,
                      titulo: 'Nenhum alerta encerrado',
                      texto:
                          'Quando um alerta terminar, ele fica guardado aqui por 90 dias.',
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Lista extends StatelessWidget {
  const _Lista(
      {required this.alertas,
      required this.carregando,
      required this.vazio,
      this.topo});
  final List<AlertaV3> alertas;
  final bool carregando;
  final Widget vazio;
  final Widget? topo;

  @override
  Widget build(BuildContext context) {
    if (carregando) return const Center(child: CircularProgressIndicator());
    return RefreshIndicator(
      onRefresh: context.read<PainelCubit>().carregar,
      child: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          if (topo != null) topo!,
          if (alertas.isEmpty) vazio,
          for (final a in alertas) _LinhaAlerta(alerta: a),
        ],
      ),
    );
  }
}

class _LinhaAlerta extends StatelessWidget {
  const _LinhaAlerta({required this.alerta});
  final AlertaV3 alerta;

  @override
  Widget build(BuildContext context) {
    final c = AquaColors.of(context);
    final t = Theme.of(context).textTheme;
    final quando = alerta.ativo
        ? 'Emitido ${formatarHaQuanto(alerta.emitidoEm)}'
        : 'Encerrado ${formatarHaQuanto(alerta.encerradoEm ?? alerta.emitidoEm)}';
    return Semantics(
      button: true,
      hint: 'Abre os detalhes do alerta',
      child: InkWell(
        onTap: () => context.push('/alerts/${alerta.id}'),
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
          decoration:
              BoxDecoration(border: Border(bottom: BorderSide(color: c.linha))),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SeloSeveridade(
                        severidade: alerta.severidade,
                        mostrarAcao: alerta.ativo),
                    const SizedBox(height: 6),
                    Text(alerta.titulo, style: t.titleMedium),
                    const SizedBox(height: 2),
                    Text(alerta.regiaoNome, style: t.bodyMedium),
                    const SizedBox(height: 2),
                    Text(quando, style: t.bodySmall),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: c.tinta2),
            ],
          ),
        ),
      ),
    );
  }
}
