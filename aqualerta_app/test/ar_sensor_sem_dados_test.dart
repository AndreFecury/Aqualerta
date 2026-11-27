import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aqualerta/core/domain/ar.dart';
import 'package:aqualerta/features/map/presentation/screens/mapa_screen.dart';
import 'package:aqualerta/shared/widgets/selo_ar.dart';

import 'telas_v3_test.dart' show montar, ArFixo;

/// Achado de produção em 26/11/2026: o único sensor de Manaus parou de mandar
/// leituras às 10:00 UTC (180 a 188 µg/m³ às 5-6h locais) e o cartão ficou só
/// com o modelo, que subestima a fumaça lá. O cartão tem de dizer que não há
/// medição, há quantas horas, e que o valor do modelo é só uma estimativa.

Map<String, dynamic> _linha({int? iqar = 80, String nivel = 'N2'}) => {
      'region_id': 'r-compensa',
      'hora': '2026-11-26T23:00:00+00:00',
      'iqar': iqar,
      'nivel': iqar == null ? null : nivel,
      'poluente': 'pm2_5',
      'pm2_5_24': 35.0,
      'iqar_previsto_48h': null,
      'hora_pior_prevista': null,
      'tendencia': 'estavel',
      'focos_24h': 0,
      'fumaca_provavel': false,
      'atualizado_em': DateTime.now().toUtc().toIso8601String(),
    };

Map<String, dynamic> _contexto({String situacao = 'parado'}) => {
      'region_id': 'r-compensa',
      'tem_sensor': true,
      'sensor_nome': 'Manaus',
      'sensor_provedor': 'AirGradient',
      'sensor_distancia_km': 2,
      'sensor_situacao': situacao,
      'comparacao_ok': false,
      'epoca_fumaca': true,
      'focos_300km_72h': 0,
      'cautela_boa': false,
      'aviso_sensor_ligado': false,
    };

/// Linha de ar_agora() para um sensor parado há [horas] (null = nunca mandou).
Map<String, dynamic> _linhaAgoraParado({int? horas = 13}) => {
      'region_id': 'r-compensa',
      'pm25_3h': null,
      'iqar_3h': null,
      'nivel_3h': null,
      'pm25_24h_sensor': null,
      'nivel_24h_sensor': null,
      'piorou': false,
      'ate': null,
      'ultima_leitura': horas == null ? null : '2026-11-26T10:00:00+00:00',
      'sensor_parado': true,
      'sem_dados_h': horas,
    };

ResumoAr _resumo({
  int? iqar = 80,
  String nivel = 'N2',
  int? horas = 13,
  bool comContexto = true,
}) {
  var r = ResumoAr.doJson(_linha(iqar: iqar, nivel: nivel));
  if (comContexto) r = r.comContexto(ContextoAr.doJson(_contexto()));
  return r.comSemDados(SemDadosSensor.doJson(_linhaAgoraParado(horas: horas)));
}

Finder _rolavel() => find
    .descendant(
        of: find.byType(DraggableScrollableSheet),
        matching: find.byType(Scrollable))
    .first;

Finder _anunciaCategoria() => find.byWidgetPredicate((w) =>
    w is Semantics &&
    (w.properties.label ?? '').startsWith('Qualidade do ar '));

Future<void> _abrir(WidgetTester t, ResumoAr r) async {
  await montar(t, const MapaScreen(), ar: ArFixo([r]));
  await t.pump(const Duration(milliseconds: 100));
  await t.scrollUntilVisible(find.text('Limitações'), 200,
      scrollable: _rolavel());
}

void main() {
  group('SemDadosSensor (domínio)', () {
    test('lê a linha de ar_agora: parado há 13 horas', () {
      final d = SemDadosSensor.doJson(_linhaAgoraParado())!;
      expect(d.horas, 13);
      expect(d.frase, 'sem dados há 13 horas');
    });

    test('singular, e sensor que nunca mandou não inventa horas', () {
      expect(SemDadosSensor.doJson(_linhaAgoraParado(horas: 1))!.frase,
          'sem dados há 1 hora');
      final nunca = SemDadosSensor.doJson(_linhaAgoraParado(horas: null))!;
      expect(nunca.horas, isNull);
      expect(nunca.frase, isNull);
    });

    test('sensor em dia não gera "sem dados"', () {
      expect(
          SemDadosSensor.doJson(
              {..._linhaAgoraParado(), 'sensor_parado': false}),
          isNull);
      expect(SemDadosSensor.doJson({'region_id': 'r'}), isNull);
    });

    test('linha de ar_agora com sensor parado não vira indicador "agora"', () {
      expect(AgoraAr.doJson(_linhaAgoraParado()), isNull);
    });

    test('comSemDados preserva o resto', () {
      final r = _resumo();
      expect(r.contexto, isNotNull);
      expect(r.semDados, isNotNull);
      expect(r.comContexto(null).semDados, isNotNull);
      expect(r.comAgora(null).semDados, isNotNull);
    });
  });

  group('Cartão com o sensor calado (Manaus, 26/11)', () {
    testWidgets(
        'diz que não há medição, há quantas horas, e que o modelo pode '
        'subestimar a fumaça; nunca "Moderada" como manchete', (t) async {
      await _abrir(t, _resumo());
      expect(find.text('Sem medição agora'), findsOneWidget);
      expect(find.byKey(const Key('ar-sensor-sem-dados')), findsOneWidget);
      expect(
          find.text('O sensor perto (AirGradient, a 2 km) está sem dados '
              'há 13 horas.'),
          findsOneWidget);
      expect(find.byKey(const Key('ar-modelo-subestima')), findsOneWidget);
      expect(find.text(textoModeloSubestima), findsOneWidget);
      expect(textoModeloSubestima, contains('pode subestimar a fumaça'));
      // O modelo aparece só como estimativa rotulada.
      final linha = find.byKey(const Key('ar-estimativa-modelo'));
      expect(
          find.descendant(
              of: linha, matching: find.textContaining('não é medição')),
          findsOneWidget);
      // Nenhuma manchete tranquilizadora, nem para o leitor de tela.
      expect(find.text('Ar moderada · índice 80'), findsNothing);
      expect(find.byType(SeloAr), findsNothing);
      expect(_anunciaCategoria(), findsNothing);
      // A linha do sensor não repete o que o bloco já disse.
      expect(find.textContaining('sem leituras recentes'), findsNothing);
      expect(find.textContaining('há 13 horas'), findsOneWidget);
    });

    testWidgets('modelo "boa": mesma coisa, com o aviso de subestimativa',
        (t) async {
      await _abrir(t, _resumo(iqar: 30, nivel: 'N1'));
      expect(find.text('Sem medição agora'), findsOneWidget);
      expect(find.text('Ar boa · índice 30'), findsNothing);
      expect(find.byType(SeloAr), findsNothing);
      expect(_anunciaCategoria(), findsNothing);
      expect(find.byKey(const Key('ar-modelo-subestima')), findsOneWidget);
    });

    testWidgets('modelo "ruim" ou pior continua em destaque, e o aviso também',
        (t) async {
      await _abrir(t, _resumo(iqar: 100, nivel: 'N3'));
      expect(find.text('Sem medição agora'), findsOneWidget);
      expect(find.byType(SeloAr), findsOneWidget);
      expect(find.text('Ar ruim · índice 100'), findsOneWidget);
      expect(find.byKey(const Key('ar-sensor-sem-dados')), findsOneWidget);
    });

    testWidgets('sensor que nunca mandou: sem número de horas, mas sem medição',
        (t) async {
      await _abrir(t, _resumo(horas: null));
      expect(find.text('Sem medição agora'), findsOneWidget);
      expect(find.byKey(const Key('ar-sensor-sem-dados')), findsNothing);
      expect(find.textContaining('sem leituras recentes'), findsOneWidget);
      expect(find.byKey(const Key('ar-modelo-subestima')), findsOneWidget);
    });

    testWidgets('mesmo sem o contexto, "sem dados" do ar_agora basta',
        (t) async {
      await _abrir(t, _resumo(comContexto: false));
      expect(find.text('Sem medição agora'), findsOneWidget);
      expect(find.text('O sensor perto está sem dados há 13 horas.'),
          findsOneWidget);
      expect(find.text('Ar moderada · índice 80'), findsNothing);
    });

    testWidgets(
        'sem estimativa do modelo: a linha do sensor ainda diz as horas',
        (t) async {
      await _abrir(t, _resumo(iqar: null));
      expect(
          find.text(
              'Sem estimativa de qualidade do ar para esta região agora.'),
          findsOneWidget);
      expect(find.textContaining('sem dados há 13 horas'), findsOneWidget);
      expect(find.byType(SeloAr), findsNothing);
    });
  });

  group('Sem sensor perto e com sensor em dia', () {
    testWidgets('só modelo (sem sensor): também com o aviso de subestimativa',
        (t) async {
      final r = ResumoAr.doJson(_linha()).comContexto(ContextoAr.doJson({
        'region_id': 'r-compensa',
        'tem_sensor': false,
        'comparacao_ok': false,
      }));
      await _abrir(t, r);
      expect(find.text('Sem medição agora'), findsOneWidget);
      expect(find.byKey(const Key('ar-modelo-subestima')), findsOneWidget);
      expect(find.byKey(const Key('ar-sensor-sem-dados')), findsNothing);
      expect(find.text('Ar moderada · índice 80'), findsNothing);
    });

    testWidgets('sensor em dia: manchete do sensor, sem "sem medição"',
        (t) async {
      final r = ResumoAr.doJson(_linha())
          .comContexto(ContextoAr.doJson(_contexto(situacao: 'saudável')))
          .comAgora(AgoraAr.doJson({
            'region_id': 'r-compensa',
            'pm25_3h': 40.0,
            'iqar_3h': 68,
            'nivel_3h': 'N2',
            'pm25_24h_sensor': 38.0,
            'nivel_24h_sensor': 'N2',
          }));
      await _abrir(t, r);
      expect(find.text('Ar moderada'), findsOneWidget);
      expect(find.text('Sem medição agora'), findsNothing);
      expect(find.byKey(const Key('ar-modelo-subestima')), findsNothing,
          reason: 'modelo e sensor concordam: sem o aviso de subestimativa');
      expect(find.byKey(const Key('ar-sensor-sem-dados')), findsNothing);
    });
  });
}
