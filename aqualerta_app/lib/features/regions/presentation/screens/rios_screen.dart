import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:aqualerta/core/domain/carta.dart';
import 'package:aqualerta/core/domain/severidade.dart';
import 'package:aqualerta/core/state/painel_cubit.dart';
import 'package:aqualerta/core/utils/formato.dart';
import 'package:aqualerta/shared/theme/aqua_colors.dart';
import 'package:aqualerta/shared/widgets/esqueleto.dart';
import 'package:aqualerta/shared/widgets/hachura.dart';
import 'package:aqualerta/shared/widgets/regua.dart';
import 'package:aqualerta/shared/widgets/v3.dart';

class RiosScreen extends StatelessWidget {
  const RiosScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final painel = context.watch<PainelCubit>().state;
    final c = AquaColors.of(context);
    final t = Theme.of(context).textTheme;

    // Com leitura recente primeiro, do maior risco para o menor.
    final estacoes = [...painel.estacoes]..sort((a, b) {
        final sa = a.severidade()?.index ?? -1;
        final sb = b.severidade()?.index ?? -1;
        return sb != sa ? sb.compareTo(sa) : a.titulo.compareTo(b.titulo);
      });

    return Scaffold(
      body: Column(
        children: [
          const CabecalhoTela(
              titulo: 'Rios', subtitulo: 'Nível agora nas estações da ANA'),
          if (painel.erro != null)
            FaixaAviso(
                texto: painel.erro!,
                icone: Icons.wifi_off,
                acao: 'Tentar',
                aoTocar: context.read<PainelCubit>().carregar),
          Expanded(
            child: RefreshIndicator(
              onRefresh: context.read<PainelCubit>().carregar,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                children: [
                  const _Legenda(),
                  if (!painel.carregando && estacoes.isEmpty)
                    const EstadoVazio(
                      icone: Icons.straighten,
                      titulo: 'Leituras indisponíveis',
                      texto:
                          'As leituras das estações ainda não chegaram. Puxe para baixo para tentar de novo.',
                    ),
                  // Primeira carga: esqueleto das estações, que dá lugar às
                  // leituras com um fade curto.
                  AnimatedSwitcher(
                    duration: MediaQuery.disableAnimationsOf(context)
                        ? Duration.zero
                        : const Duration(milliseconds: 250),
                    switchInCurve: Curves.easeOut,
                    layoutBuilder: (atual, anteriores) => Stack(
                        alignment: Alignment.topCenter,
                        children: [...anteriores, if (atual != null) atual]),
                    child: painel.carregando && !painel.temDados
                        ? const EsqueletoEstacoes(key: ValueKey('carregando'))
                        : Column(
                            key: const ValueKey('estacoes'),
                            children: [
                              for (final (i, e) in estacoes.indexed)
                                _LinhaEstacao(
                                    estacao: e,
                                    ultima: i == estacoes.length - 1),
                            ],
                          ),
                  ),
                  const SizedBox(height: 28),
                  const TituloSecao('Regiões que você segue'),
                  Text('Você recebe avisos das regiões marcadas.',
                      style: t.bodySmall),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final r in painel.regioes)
                        FilterChip(
                          label: Text(r.nome),
                          labelStyle: t.labelLarge!
                              .copyWith(color: c.tinta, fontSize: 15),
                          avatar: AmostraHachura(
                              severidade: painel.severidadeDaRegiao(r.id),
                              tamanho: 16),
                          selected: painel.seguidas.contains(r.id),
                          showCheckmark: false,
                          selectedColor: c.canal.withValues(alpha: 0.16),
                          side: BorderSide(
                              color: painel.seguidas.contains(r.id)
                                  ? c.canal
                                  : c.linha,
                              width: 1.5),
                          onSelected: (v) => context
                              .read<PainelCubit>()
                              .seguir(r.id, seguir: v),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Legenda extends StatelessWidget {
  const _Legenda();

  @override
  Widget build(BuildContext context) {
    final c = AquaColors.of(context);
    final t = Theme.of(context).textTheme;
    Widget item(Color cor, String texto, {bool tracejado = true}) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
                width: 3,
                height: 16,
                color: tracejado ? cor.withValues(alpha: 0.9) : cor),
            const SizedBox(width: 6),
            Flexible(child: Text(texto, style: t.bodySmall)),
          ],
        );
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Wrap(
        spacing: 16,
        runSpacing: 6,
        children: [
          item(c.corDe(Severidade.medio), 'Cota de alerta'),
          item(c.corDe(Severidade.alto), 'Cota de inundação'),
          item(c.corDe(Severidade.critico), 'Inundação severa'),
          item(c.tinta, 'Nível agora', tracejado: false),
        ],
      ),
    );
  }
}

class _LinhaEstacao extends StatelessWidget {
  const _LinhaEstacao({required this.estacao, required this.ultima});
  final Estacao estacao;
  final bool ultima;

  @override
  Widget build(BuildContext context) {
    final c = AquaColors.of(context);
    final t = Theme.of(context).textTheme;
    final recente = estacao.leituraRecente();
    final s = estacao.severidade();
    final cotas = estacao.cotas;

    String? situacao;
    if (recente && cotas != null) {
      final n = estacao.nivel!;
      final severa = cotas.severa;
      situacao = severa != null && n >= severa
          ? 'Acima da inundação severa'
          : n >= cotas.inundacao
              ? 'Acima da inundação'
              : n >= cotas.alerta
                  ? 'Acima do alerta'
                  : '${formatarDiferenca(cotas.alerta - n)} abaixo do alerta';
    }

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 16),
      decoration: BoxDecoration(
          border: ultima ? null : Border(bottom: BorderSide(color: c.linha))),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: double.infinity,
            child: Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.start,
              spacing: 12,
              runSpacing: 4,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(estacao.titulo, style: t.titleMedium),
                    Text(estacao.nome,
                        style: t.bodyMedium!.copyWith(color: c.tinta2)),
                  ],
                ),
                if (recente)
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text('${formatarMetros(estacao.nivel!, casas: 2)} m',
                          style: t.titleLarge),
                      if (situacao != null)
                        Text(situacao,
                            style: t.labelSmall!.copyWith(
                                color: s == null ? c.tinta2 : c.textoDe(s))),
                    ],
                  )
                else
                  Text('Sem leitura recente', style: t.labelSmall),
              ],
            ),
          ),
          if (cotas != null) ...[
            const SizedBox(height: 10),
            Regua(
                cotas: cotas,
                nivel: recente ? estacao.nivel : null,
                rio: estacao.titulo,
                direcao: Axis.horizontal),
            const SizedBox(height: 8),
            Text(
              [
                'Alerta ${formatarMetros(cotas.alerta, casas: 2)} m, inundação ${formatarMetros(cotas.inundacao, casas: 2)} m'
                    '${cotas.severa == null ? '' : ', severa ${formatarMetros(cotas.severa!, casas: 2)} m'}.',
                if (recente && estacao.variacao24h != null)
                  '${formatarTendencia(estacao.variacao24h)}.',
                if (recente) 'Leitura ${formatarHaQuanto(estacao.lidoEm!)}.',
              ].join(' '),
              style: t.bodySmall,
            ),
          ],
        ],
      ),
    );
  }
}
