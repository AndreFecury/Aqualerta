import 'dart:ui' show Brightness;

import 'package:flutter/painting.dart';
import 'package:aqualerta/core/domain/severidade.dart';

/// Níveis do IQAr (MMA, Orientação Técnica de 10/01/2025, Res. Conama
/// 506/2024). A paleta é própria do ar (ardósia → violeta) para nunca ser
/// confundida com o risco de cheia (verde, amarelo, laranja, vermelho).
enum NivelAr {
  n1('Boa', 0, 40, Color(0xFF5B7A8C), Color(0xFF9DB8C8)),
  n2('Moderada', 41, 80, Color(0xFF6F62A3), Color(0xFFB3A9DE)),
  n3('Ruim', 81, 120, Color(0xFF5E3F96), Color(0xFFC3A6F0)),
  n4('Muito ruim', 121, 200, Color(0xFF47257A), Color(0xFFD5B8FF)),
  n5('Péssima', 201, 400, Color(0xFF2E1A47), Color(0xFFE9D9FF));

  const NivelAr(this.nome, this.de, this.ate, this.corClara, this.corEscura);
  final String nome;
  final int de;
  final int ate;
  final Color corClara;
  final Color corEscura;

  Color cor(Brightness b) => b == Brightness.dark ? corEscura : corClara;

  /// Nível de um aviso de ar (o banco só avisa a partir de N4).
  static NivelAr doAviso(Severidade s) => s == Severidade.critico ? n5 : n4;

  static NivelAr doIndice(int iqar) => iqar <= 40
      ? n1
      : iqar <= 80
          ? n2
          : iqar <= 120
              ? n3
              : iqar <= 200
                  ? n4
                  : n5;

  /// Efeitos à saúde do Quadro 2 do MMA (fonte original: Cetesb, 2019).
  /// Nada para N1: o índice baixo de um modelo não garante ar limpo na rua.
  String? get saude => switch (this) {
        n1 => null,
        n2 => 'Crianças, idosos e pessoas com doenças respiratórias ou '
            'cardíacas podem ter tosse seca e cansaço.',
        n3 => 'Qualquer pessoa pode ter tosse seca, cansaço e ardor nos '
            'olhos, nariz e garganta; grupos sensíveis, efeitos mais sérios.',
        n4 => 'Qualquer pessoa pode ter os sintomas piores e ainda falta de '
            'ar; grupos sensíveis, efeitos ainda mais graves. Evite esforço '
            'ao ar livre.',
        n5 => 'Risco sério de doenças respiratórias e cardiovasculares para '
            'toda a população. Fique em locais fechados se puder.',
      };
}

enum TendenciaAr { sobe, estavel, desce }

/// Resumo da qualidade do ar de uma região (RPC `ar_resumo`). É ESTIMATIVA
/// DE MODELO (CAMS, ~45 km), não medição local, e nunca muda o risco de
/// cheia da região.
class ResumoAr {
  const ResumoAr({
    required this.regiaoId,
    this.hora,
    this.iqar,
    this.poluente,
    this.pm25Media24h,
    this.previsto48h,
    this.horaPiorPrevista,
    this.tendencia,
    this.focos24h = 0,
    this.fumacaProvavel = false,
    this.atualizadoEm,
    this.local,
  });

  final String regiaoId;

  /// Medição de sensores reais perto da região (OpenAQ), quando houver.
  final MedicaoLocalAr? local;

  ResumoAr comLocal(MedicaoLocalAr? m) => ResumoAr(
        regiaoId: regiaoId,
        hora: hora,
        iqar: iqar,
        poluente: poluente,
        pm25Media24h: pm25Media24h,
        previsto48h: previsto48h,
        horaPiorPrevista: horaPiorPrevista,
        tendencia: tendencia,
        focos24h: focos24h,
        fumacaProvavel: fumacaProvavel,
        atualizadoEm: atualizadoEm,
        local: m,
      );

  /// Hora (UTC) a que o índice se refere.
  final DateTime? hora;

  /// `null` = sem estimativa recente para a região.
  final int? iqar;
  final String? poluente;
  final double? pm25Media24h;
  final int? previsto48h;
  final DateTime? horaPiorPrevista;
  final TendenciaAr? tendencia;
  final int focos24h;
  final bool fumacaProvavel;
  final DateTime? atualizadoEm;

  NivelAr? get nivel => iqar == null ? null : NivelAr.doIndice(iqar!);

  /// A coleta é de hora em hora; mais de 3 h sem dado novo é atraso.
  bool desatualizado({DateTime? agora}) =>
      atualizadoEm != null &&
      (agora ?? DateTime.now()).difference(atualizadoEm!) >
          const Duration(hours: 3);

  static String nomePoluente(String? p) => switch (p) {
        'pm2_5' => 'partículas finas (MP2,5)',
        'pm10' => 'partículas (MP10)',
        'o3' => 'ozônio',
        'no2' => 'dióxido de nitrogênio',
        'co' => 'monóxido de carbono',
        _ => 'poluente',
      };

  static double? _d(Object? v) => (v as num?)?.toDouble();
  static DateTime? _t(Object? v) =>
      v == null ? null : DateTime.parse(v as String);

  factory ResumoAr.doJson(Map<String, dynamic> j) => ResumoAr(
        regiaoId: j['region_id'] as String,
        hora: _t(j['hora']),
        iqar: (j['iqar'] as num?)?.toInt(),
        poluente: j['poluente'] as String?,
        pm25Media24h: _d(j['pm2_5_24']),
        previsto48h: (j['iqar_previsto_48h'] as num?)?.toInt(),
        horaPiorPrevista: _t(j['hora_pior_prevista']),
        tendencia: switch (j['tendencia']) {
          'sobe' => TendenciaAr.sobe,
          'desce' => TendenciaAr.desce,
          'estavel' => TendenciaAr.estavel,
          _ => null,
        },
        focos24h: (j['focos_24h'] as num?)?.toInt() ?? 0,
        fumacaProvavel: j['fumaca_provavel'] as bool? ?? false,
        atualizadoEm: _t(j['atualizado_em']),
      );
}

/// MP2,5 medido por sensores perto da região (RPC `ar_local`, dados da
/// OpenAQ). Média de 24 h, só com sensores que cobrem ao menos 18 horas.
class MedicaoLocalAr {
  const MedicaoLocalAr({
    required this.regiaoId,
    required this.pm25Media24h,
    required this.iqar,
    required this.sensores,
    this.distanciaKm,
    this.fontes,
    this.atualizadoEm,
  });

  final String regiaoId;
  final double pm25Media24h;
  final int iqar;
  final int sensores;
  final int? distanciaKm;
  final String? fontes;
  final DateTime? atualizadoEm;

  NivelAr get nivel => NivelAr.doIndice(iqar);

  static MedicaoLocalAr? doJson(Map<String, dynamic> j) {
    final pm = (j['pm25_24h'] as num?)?.toDouble();
    final iqar = (j['iqar'] as num?)?.toInt();
    if (pm == null || iqar == null) return null;
    return MedicaoLocalAr(
      regiaoId: j['region_id'] as String,
      pm25Media24h: pm,
      iqar: iqar,
      sensores: (j['sensores'] as num?)?.toInt() ?? 1,
      distanciaKm: (j['distancia_km'] as num?)?.round(),
      fontes: j['fontes'] as String?,
      atualizadoEm: j['atualizado_em'] == null
          ? null
          : DateTime.parse(j['atualizado_em'] as String),
    );
  }

  /// "MP2,5 de 21,3 µg/m³ na média de 24 h (moderada, índice 41), 1 sensor
  /// a até 4 km."
  String get frase {
    final pm = pm25Media24h.toStringAsFixed(1).replaceAll('.', ',');
    final onde = sensores == 1 ? '1 sensor' : '$sensores sensores';
    final dist = distanciaKm == null ? '' : ' a até $distanciaKm km';
    return 'MP2,5 de $pm µg/m³ na média de 24 h '
        '(${nivel.nome.toLowerCase()}, índice $iqar), $onde$dist.';
  }
}
