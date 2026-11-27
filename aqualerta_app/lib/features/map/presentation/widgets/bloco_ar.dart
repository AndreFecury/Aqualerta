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
    final ctx = r?.contexto;
    final comparacao = ctx?.fraseComparacao;
    final divergencia = ctx?.fraseDivergencia;
    final fonteSensor = ctx == null || !ctx.temSensor
        ? null
        : '${ctx.sensorProvedor ?? 'sensor'}'
            '${ctx.sensorDistanciaKm != null ? ', a ${ctx.sensorDistanciaKm} km' : ''}';
    // Fase 4: as duas leituras lado a lado, sem dizer quem acertou.
    final sensorPerto = <Widget>[
      if (comparacao != null) ...[
        const SizedBox(height: 8),
        Semantics(
          label: '$comparacao. ${divergencia ?? ''}',
          excludeSemantics: true,
          child: Row(
            key: const Key('ar-comparacao'),
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Icon(Icons.sensors, size: 18, color: c.tinta2),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('$comparacao.',
                        style: t.bodyMedium
                            ?.copyWith(fontWeight: FontWeight.w600)),
                    if (divergencia != null)
                      Text(divergencia, style: t.bodyMedium),
                    Text(
                        'Médias das últimas 24 h. O sensor é um aparelho de '
                        'baixo custo ($fonteSensor, via OpenAQ), não um monitor '
                        'oficial; o modelo é o CAMS.',
                        style: t.bodySmall),
                  ],
                ),
              ),
            ],
          ),
        ),
      ] else if (fonteSensor != null) ...[
        const SizedBox(height: 6),
        Text(
            ctx!.sensorSituacao == 'parado'
                ? 'Há um sensor perto ($fonteSensor), sem leituras recentes.'
                : 'Há um sensor perto ($fonteSensor), ainda sem dias '
                    'suficientes para comparar com o modelo.',
            style: t.bodySmall),
      ],
    ];
    final cautela = ctx != null && ctx.cautelaBoa;
    // "Agora": média de 3 h do sensor, ao lado do índice oficial de 24 h.
    final agora = r?.agora;
    final referencia24h = r?.nivel ?? ctx?.sensorNivel;
    final piorou =
        agora != null && referencia24h != null && agora.piorou(referencia24h);
    final blocoAgora = <Widget>[
      if (agora != null) ...[
        const SizedBox(height: 8),
        Semantics(
          container: true,
          child: Column(
            key: const Key('ar-agora'),
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                  '${agora.textoMedia}'
                  '${agora.ate != null ? ' Até as ${horaManaus(agora.ate!)}.' : ''}',
                  style: t.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
              if (piorou) ...[
                const SizedBox(height: 6),
                Container(
                  key: const Key('ar-piorou'),
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    border: Border.all(color: c.barro),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.trending_up, size: 18, color: c.barro),
                      const SizedBox(width: 6),
                      Expanded(
                          child: Text(AgoraAr.textoPiorou,
                              style: t.bodyMedium
                                  ?.copyWith(fontWeight: FontWeight.w700))),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    ];
    final aviso = context
        .watch<PainelCubit>()
        .state
        .avisosArAtivos
        .where((a) => a.regiaoId == regiaoId)
        .firstOrNull;

    // O aviso vem do sensor: aparece mesmo sem estimativa do modelo.
    final botaoAviso = <Widget>[
      if (aviso != null)
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: () => context.push('/alerts/${aviso.id}'),
            key: const Key('ver-aviso-ar'),
            child: Text('Ver aviso: ${aviso.titulo.toLowerCase()} (sensor)'),
          ),
        ),
    ];

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
        ...blocoAgora,
        ...sensorPerto,
        ...botaoAviso,
      ];
    } else {
      final nivel = r.nivel!;
      final prev = r.previsto48h;
      corpo = [
        if (r.semMedicaoAgora) ...[
          // Sem medição: nada de manchete tranquilizadora vinda do modelo.
          Semantics(
            header: true,
            child: Text('Sem medição agora',
                key: const Key('ar-sem-medicao'),
                style: t.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
          ),
          const SizedBox(height: 4),
          Column(
            key: const Key('ar-estimativa-modelo'),
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (nivel.index >= NivelAr.n3.index) ...[
                // O modelo pode SUBIR o nível, nunca baixar: ruim ou pior fica
                // em destaque, marcado como estimativa.
                Text('Estimativa do modelo (CAMS, não é medição):',
                    style: t.bodyMedium),
                const SizedBox(height: 4),
                SeloAr(
                    nivel: nivel,
                    indice: r.iqar,
                    grande: true,
                    estimativa: true),
              ] else
                Text(
                    'Estimativa do modelo (CAMS, não é medição): '
                    'ar ${nivel.nome.toLowerCase()}, índice ${r.iqar}.',
                    style: t.bodyMedium),
            ],
          ),
        ] else ...[
          SeloAr(nivel: nivel, indice: r.iqar, grande: true),
          const SizedBox(height: 2),
          Text('Índice oficial (IQAr, média de 24 h), estimado pelo modelo.',
              key: const Key('ar-rotulo-24h'), style: t.bodySmall),
        ],
        ...blocoAgora,
        if (cautela && nivel == NivelAr.n1) ...[
          const SizedBox(height: 6),
          Text(ctx.textoCautela!,
              key: const Key('ar-cautela-boa'),
              style: t.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
        ],
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
        if (r.focos24h > 0) ...[
          const SizedBox(height: 6),
          Text(
              '${r.focos24h} focos de queimada a até 100 km nas últimas 24 h (INPE).',
              style: t.bodyMedium),
        ],
        if (r.focos24h > 0 || (ctx?.epocaFumaca ?? false)) ...[
          const SizedBox(height: 2),
          Text(
              'A fumaça também pode vir de queimadas distantes, a centenas '
              'de quilômetros.',
              style: t.bodySmall),
        ],
        if (nivel.saude != null) ...[
          const SizedBox(height: 6),
          Text(nivel.saude!, style: t.bodyMedium),
        ],
        ...sensorPerto,
        ...botaoAviso,
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
