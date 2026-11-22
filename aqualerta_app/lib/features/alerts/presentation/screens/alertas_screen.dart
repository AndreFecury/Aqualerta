import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:aqualerta/app/router.dart' show Abas;
import 'package:aqualerta/core/domain/carta.dart';
import 'package:aqualerta/core/state/painel_cubit.dart';
import 'package:aqualerta/core/utils/formato.dart';
import 'package:aqualerta/features/settings/presentation/cubit/notificacoes_cubit.dart';
import 'package:aqualerta/shared/theme/aqua_colors.dart';
import 'package:aqualerta/core/domain/ar.dart';
import 'package:aqualerta/features/map/presentation/widgets/bloco_ar.dart'
    show horaManaus;
import 'package:aqualerta/shared/widgets/esqueleto.dart';
import 'package:aqualerta/shared/widgets/selo_ar.dart';
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
                  Tab(
                      text:
                          'Ativos (${painel.ativos.length + painel.avisosArAtivos.length})'),
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
                    avisosAr: painel.avisosArAtivos,
                    carregando: painel.carregando && !painel.temDados,
                    destacarNovos: true,
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
                              onPressed: () => Abas.irPara(context, 3),
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
                    avisosAr: [
                      for (final a in painel.avisosAr)
                        if (!a.ativo) a
                    ],
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
      this.avisosAr = const [],
      this.destacarNovos = false,
      this.topo});
  final List<AlertaV3> alertas;
  final List<AvisoAr> avisosAr;
  final bool carregando;
  final Widget vazio;
  final bool destacarNovos;
  final Widget? topo;

  /// Alertas ativos já mostrados nesta sessão. Os que existiam ao abrir não
  /// são "novos"; os que chegam depois ganham um destaque passageiro.
  static Set<String>? _vistos;

  @override
  Widget build(BuildContext context) {
    // Primeira carga: esqueleto no formato das linhas; depois troca com fade
    // curto para a lista (sem spinner no meio da tela).
    return AnimatedSwitcher(
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 250),
      switchInCurve: Curves.easeOut,
      layoutBuilder: (atual, anteriores) => Stack(
          alignment: Alignment.topCenter,
          children: [...anteriores, if (atual != null) atual]),
      child: carregando
          ? const Align(
              key: ValueKey('carregando'),
              alignment: Alignment.topCenter,
              child: EsqueletoAlertas())
          : KeyedSubtree(
              key: const ValueKey('lista'), child: _conteudo(context)),
    );
  }

  Widget _conteudo(BuildContext context) {
    final novos = <String>{};
    if (destacarNovos) {
      if (_vistos == null) {
        _vistos = {for (final a in alertas) a.id};
      } else {
        for (final a in alertas) {
          if (_vistos!.add(a.id)) novos.add(a.id);
        }
      }
    }
    return RefreshIndicator(
      onRefresh: context.read<PainelCubit>().carregar,
      child: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          if (topo != null) topo!,
          if (avisosAr.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Semantics(
                header: true,
                child: Text('Qualidade do ar (sensor)',
                    style: Theme.of(context).textTheme.titleSmall),
              ),
            ),
            for (final a in avisosAr)
              _LinhaAvisoAr(key: ValueKey('ar-${a.id}'), aviso: a),
          ],
          if (alertas.isEmpty && avisosAr.isEmpty) vazio,
          for (final a in alertas)
            _LinhaAlerta(
                key: ValueKey(a.id), alerta: a, novo: novos.contains(a.id)),
        ],
      ),
    );
  }
}

class _LinhaAlerta extends StatelessWidget {
  const _LinhaAlerta({super.key, required this.alerta, this.novo = false});
  final AlertaV3 alerta;
  final bool novo;

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
        // Alerta que acabou de chegar: fundo na cor do nível que some em
        // 1,5 s. Sem piscar nem tremer (alarme falso cansa).
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: novo ? 1 : 0, end: 0),
          duration: MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : const Duration(milliseconds: 1500),
          curve: Curves.easeIn,
          builder: (context, v, filho) => Container(
            color: (alerta.ehAr
                    ? NivelAr.doAviso(alerta.severidade)
                        .cor(Theme.of(context).brightness)
                    : c.corDe(alerta.severidade))
                .withValues(alpha: 0.22 * v),
            child: filho,
          ),
          child: Container(
            padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
            decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: c.linha))),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      alerta.ehAr
                          ? SeloAr(nivel: NivelAr.doAviso(alerta.severidade))
                          : SeloSeveridade(
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
      ),
    );
  }
}

/// Linha de um aviso de ar pelo sensor na lista de alertas.
class _LinhaAvisoAr extends StatelessWidget {
  const _LinhaAvisoAr({super.key, required this.aviso});
  final AvisoAr aviso;

  @override
  Widget build(BuildContext context) {
    final c = AquaColors.of(context);
    final t = Theme.of(context).textTheme;
    final regiao =
        context.watch<PainelCubit>().state.regiao(aviso.regiaoId)?.nome ??
            'Região';
    final quando = aviso.ativo
        ? 'desde ${horaManaus(aviso.inicio)}'
        : 'encerrado ${aviso.fim != null ? 'às ${horaManaus(aviso.fim!)}' : ''}';
    return ListTile(
      onTap: () => context.push('/alerts/${aviso.id}'),
      leading: SeloAr(nivel: aviso.nivel),
      title: Text('${aviso.titulo} em $regiao', style: t.titleSmall),
      subtitle: Text(
          'Sensor perto · $quando'
          '${aviso.nowcastAtual != null ? ' · ${aviso.nowcastAtual!.toStringAsFixed(0)} µg/m³ agora' : ''}',
          style: t.bodySmall!.copyWith(color: c.tinta2)),
      trailing: const Icon(Icons.chevron_right),
    );
  }
}
