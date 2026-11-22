import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:aqualerta/core/domain/ar.dart';
import 'package:aqualerta/core/state/painel_cubit.dart';
import 'package:aqualerta/features/map/data/ar_repository.dart';
import 'package:aqualerta/shared/theme/aqua_colors.dart';
import 'package:aqualerta/shared/widgets/esqueleto.dart';
import 'package:aqualerta/shared/widgets/selo_ar.dart';

const textoLimitacoesAr =
    'Estimativa do modelo CAMS (Copernicus), com quadrados de dezenas de '
    'quilômetros: não é medição na sua rua. Fumaça de queimada pode chegar '
    'antes ou depois do que o modelo mostra. Foco de calor do INPE não é '
    'incêndio confirmado: nuvens escondem fogo e queima de roçado também '
    'conta. A qualidade do ar não muda o risco de cheia.';

/// "16:00" na hora de Manaus (UTC−4).
String horaManaus(DateTime d) {
  final m = d.toUtc().subtract(const Duration(hours: 4));
  return '${m.hour.toString().padLeft(2, '0')}:${m.minute.toString().padLeft(2, '0')}';
}

/// "sáb 18h" na hora de Manaus.
String diaHoraManaus(DateTime d) {
  final m = d.toUtc().subtract(const Duration(hours: 4));
  const dias = ['seg', 'ter', 'qua', 'qui', 'sex', 'sáb', 'dom'];
  return '${dias[m.weekday - 1]} ${m.hour}h';
}

/// Bloco "Qualidade do ar" no cartão da região (abaixo do satélite).
class BlocoAr extends StatelessWidget {
  const BlocoAr({required this.regiaoId, super.key});
  final String regiaoId;

  @override
  Widget build(BuildContext context) {
    final c = AquaColors.of(context);
    final t = Theme.of(context).textTheme;
    final cubit = context.watch<ArCubit>();
    final estado = cubit.state;
    if (estado.situacao != SituacaoAr.erro && cubit.vencido) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) context.read<ArCubit>().carregar();
      });
    }
    final r = estado.de(regiaoId);
    final local = r?.local;
    final medicaoLocal = <Widget>[
      if (local != null) ...[
        const SizedBox(height: 8),
        Semantics(
          label: 'Medição local: ${local.frase}',
          excludeSemantics: true,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Icon(Icons.sensors, size: 18, color: c.tinta2),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text.rich(
                  TextSpan(children: [
                    TextSpan(
                        text: 'Medição local: ',
                        style: t.bodyMedium
                            ?.copyWith(fontWeight: FontWeight.w600)),
                    TextSpan(text: local.frase, style: t.bodyMedium),
                    TextSpan(
                        text: '\nFonte: ${local.fontes ?? 'OpenAQ'}'
                            '${local.atualizadoEm != null ? ' · até ${horaManaus(local.atualizadoEm!)}' : ''}.',
                        style: t.bodySmall),
                  ]),
                ),
              ),
            ],
          ),
        ),
      ],
    ];
    final aviso = context
        .watch<PainelCubit>()
        .state
        .ativos
        .where((a) => a.ehAr && a.regiaoId == regiaoId)
        .firstOrNull;

    final titulo = Row(
      children: [
        Icon(Icons.air, size: 20, color: c.tinta2),
        const SizedBox(width: 8),
        Expanded(
            child: Semantics(
                header: true,
                child: Text('Qualidade do ar', style: t.titleSmall))),
        if (r != null && r.desatualizado())
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              border: Border.all(color: c.barro),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text('desatualizado',
                style: t.labelSmall!.copyWith(color: c.barro)),
          ),
      ],
    );

    final List<Widget> corpo;
    if (estado.situacao == SituacaoAr.carregando && r == null) {
      corpo = const [
        EsqueletoAlertas(linhas: 1),
      ];
    } else if (estado.situacao == SituacaoAr.erro) {
      corpo = [
        Text('Não foi possível carregar a qualidade do ar.',
            style: t.bodyMedium),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: () => context.read<ArCubit>().carregar(forcar: true),
            child: const Text('Tentar de novo'),
          ),
        ),
      ];
    } else if (r == null || r.iqar == null) {
      corpo = [
        Text('Sem estimativa de qualidade do ar para esta região agora.',
            style: t.bodyMedium),
        ...medicaoLocal,
      ];
    } else {
      final nivel = r.nivel!;
      final prev = r.previsto48h;
      corpo = [
        SeloAr(nivel: nivel, indice: r.iqar, grande: true),
        const SizedBox(height: 6),
        Text(
            'Puxado por ${ResumoAr.nomePoluente(r.poluente)}'
            '${r.pm25Media24h != null ? ' · MP2,5 de ${r.pm25Media24h!.toStringAsFixed(1).replaceAll('.', ',')} µg/m³ na média de 24 h' : ''}.',
            style: t.bodyMedium),
        if (r.tendencia != null || prev != null) ...[
          const SizedBox(height: 4),
          Text(
              [
                if (r.tendencia != null)
                  switch (r.tendencia!) {
                    TendenciaAr.sobe => 'Piorando em relação a ontem',
                    TendenciaAr.desce => 'Melhorando em relação a ontem',
                    TendenciaAr.estavel => 'Parecido com ontem',
                  },
                if (prev != null && r.horaPiorPrevista != null)
                  'pior previsto em 48 h: ${NivelAr.doIndice(prev).nome.toLowerCase()} '
                      '($prev) ${diaHoraManaus(r.horaPiorPrevista!)}',
              ].join('; '),
              style: t.bodySmall),
        ],
        if (r.fumacaProvavel) ...[
          const SizedBox(height: 6),
          Text(
              '${r.focos24h} focos de queimada a até 100 km nas últimas 24 h e o '
              'modelo indica mais partículas no ar: a fumaça pode ser a causa.',
              style: t.bodyMedium),
        ] else if (r.focos24h > 0) ...[
          const SizedBox(height: 4),
          Text('${r.focos24h} focos de queimada a até 100 km nas últimas 24 h.',
              style: t.bodySmall),
        ],
        if (nivel.saude != null) ...[
          const SizedBox(height: 6),
          Text(nivel.saude!, style: t.bodyMedium),
        ],
        ...medicaoLocal,
        if (aviso != null)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () => context.push('/alerts/${aviso.id}'),
              child: const Text('Ver aviso de qualidade do ar'),
            ),
          ),
        const SizedBox(height: 6),
        Text(
            'Estimativa de modelo, não medição local. '
            '${r.atualizadoEm != null ? 'Atualizada às ${horaManaus(r.atualizadoEm!)}. ' : ''}'
            'Fontes: Open-Meteo.com (CAMS/Copernicus, CC BY 4.0) e INPE Queimadas.',
            style: t.bodySmall),
      ];
    }

    return Semantics(
      container: true,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          border: Border.all(color: c.linha),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            titulo,
            const SizedBox(height: 8),
            ...corpo,
            const SizedBox(height: 10),
            Text('Limitações', style: t.labelLarge),
            const SizedBox(height: 2),
            Text(textoLimitacoesAr, style: t.bodySmall),
          ],
        ),
      ),
    );
  }
}
