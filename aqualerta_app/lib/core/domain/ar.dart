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
    this.contexto,
  });

  final String regiaoId;

  /// Sensor perto, comparação e cautela (RPC ar_contexto).
  final ContextoAr? contexto;

  ResumoAr comContexto(ContextoAr? m) => ResumoAr(
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
        contexto: m,
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

/// Contexto do ar de uma região (RPC `ar_contexto`, migração
/// 20261126a_ar_contexto.sql): sensor perto, comparação sensor × modelo,
/// divergência e quando o "Boa" do modelo precisa de cautela.
class ContextoAr {
  const ContextoAr({
    required this.regiaoId,
    this.temSensor = false,
    this.sensorNome,
    this.sensorProvedor,
    this.sensorDistanciaKm,
    this.sensorSituacao,
    this.comparacaoOk = false,
    this.sensorPm25,
    this.sensorNivel,
    this.modeloPm25,
    this.modeloNivel,
    this.sensorPior = false,
    this.modeloPior = false,
    this.epocaFumaca = false,
    this.focos300km72h = 0,
    this.cautelaBoa = false,
    this.avisoSensorLigado = false,
  });

  final String regiaoId;
  final bool temSensor;
  final String? sensorNome;
  final String? sensorProvedor;
  final int? sensorDistanciaKm;

  /// 'saudável', 'cobertura baixa' ou 'parado' (null sem sensor).
  final String? sensorSituacao;

  /// Há dias suficientes e o sensor está saudável: mostrar as duas leituras.
  final bool comparacaoOk;

  /// Médias das últimas 24 h (só com [comparacaoOk]).
  final double? sensorPm25;
  final NivelAr? sensorNivel;
  final double? modeloPm25;
  final NivelAr? modeloNivel;

  /// Sensor 2+ níveis pior que o modelo hoje (frase desde o 1º dia).
  final bool sensorPior;

  /// Modelo pior que o sensor há 5 dias seguidos.
  final bool modeloPior;
  final bool epocaFumaca;
  final int focos300km72h;

  /// Região só com modelo em época de fumaça ou com muitos focos: "Boa"
  /// nunca aparece sozinho.
  final bool cautelaBoa;
  final bool avisoSensorLigado;

  static NivelAr? _nivel(Object? v) => switch (v) {
        'N1' => NivelAr.n1,
        'N2' => NivelAr.n2,
        'N3' => NivelAr.n3,
        'N4' => NivelAr.n4,
        'N5' => NivelAr.n5,
        _ => null,
      };

  factory ContextoAr.doJson(Map<String, dynamic> j) => ContextoAr(
        regiaoId: j['region_id'] as String,
        temSensor: j['tem_sensor'] as bool? ?? false,
        sensorNome: j['sensor_nome'] as String?,
        sensorProvedor: j['sensor_provedor'] as String?,
        sensorDistanciaKm: (j['sensor_distancia_km'] as num?)?.round(),
        sensorSituacao: j['sensor_situacao'] as String?,
        comparacaoOk: j['comparacao_ok'] as bool? ?? false,
        sensorPm25: (j['sensor_pm25_24h'] as num?)?.toDouble(),
        sensorNivel: _nivel(j['sensor_nivel']),
        modeloPm25: (j['modelo_pm25_24h'] as num?)?.toDouble(),
        modeloNivel: _nivel(j['modelo_nivel']),
        sensorPior: j['sensor_pior'] as bool? ?? false,
        modeloPior: j['modelo_pior'] as bool? ?? false,
        epocaFumaca: j['epoca_fumaca'] as bool? ?? false,
        focos300km72h: (j['focos_300km_72h'] as num?)?.toInt() ?? 0,
        cautelaBoa: j['cautela_boa'] as bool? ?? false,
        avisoSensorLigado: j['aviso_sensor_ligado'] as bool? ?? false,
      );

  static String _ug(double v) => v.toStringAsFixed(0);

  /// "Sensor perto: Moderada (31 µg/m³). Modelo: Boa". Sem dizer quem acertou.
  String? get fraseComparacao {
    if (!comparacaoOk || sensorNivel == null || modeloNivel == null)
      return null;
    return 'Sensor perto: ${sensorNivel!.nome} (${_ug(sensorPm25!)} µg/m³). '
        'Modelo: ${modeloNivel!.nome}';
  }

  String? get fraseDivergencia {
    if (sensorPior) {
      return 'Hoje o sensor perto indica ar bem pior que a estimativa do modelo.';
    }
    if (modeloPior) {
      return 'Há alguns dias a estimativa do modelo indica ar pior que o sensor perto.';
    }
    return null;
  }
}

/// Texto obrigatório quando o modelo diz "Boa" numa região só com modelo em
/// época de fumaça ou com muitos focos (decisão de 22/11/2026).
const textoCautelaBoa =
    'O modelo costuma subestimar fumaça forte; se há cheiro de queimado ou '
    'céu encoberto, trate o ar como ruim.';

/// Aviso de qualidade do ar pelo SENSOR (tabela ar_avisos, migração
/// 20261126b). Usa o índice em tempo quase real (NowCast da EPA), não o IQAr
/// oficial do MMA. O modelo nunca abre aviso.
class AvisoAr {
  const AvisoAr({
    required this.id,
    required this.regiaoId,
    required this.severidade,
    required this.inicio,
    required this.ativo,
    this.limite = 75,
    this.nowcastAtual,
    this.nowcastMax,
    this.fim,
    this.motivoFim,
  });

  final String id;
  final String regiaoId;
  final Severidade severidade;
  final double limite;
  final double? nowcastAtual;
  final double? nowcastMax;
  final DateTime inicio;
  final DateTime? fim;
  final bool ativo;
  final String? motivoFim;

  NivelAr get nivel => NivelAr.doAviso(severidade);

  /// "Ar muito ruim" / "Ar péssimo".
  String get titulo =>
      severidade == Severidade.critico ? 'Ar péssimo' : 'Ar muito ruim';

  factory AvisoAr.doJson(Map<String, dynamic> j) => AvisoAr(
        id: j['id'] as String,
        regiaoId: j['region_id'] as String,
        severidade: Severidade.doCodigo(j['severity'] as String?),
        limite: (j['limite_ugm3'] as num?)?.toDouble() ?? 75,
        nowcastAtual: (j['nowcast_atual'] as num?)?.toDouble(),
        nowcastMax: (j['nowcast_max'] as num?)?.toDouble(),
        inicio: DateTime.parse(j['inicio'] as String),
        fim: j['fim'] == null ? null : DateTime.parse(j['fim'] as String),
        ativo: j['situacao'] == 'ativo',
        motivoFim: j['motivo_fim'] as String?,
      );
}
