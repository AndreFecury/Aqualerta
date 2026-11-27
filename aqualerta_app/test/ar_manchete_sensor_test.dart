import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aqualerta/core/config/mapas.dart';
import 'package:aqualerta/core/domain/ar.dart';
import 'package:aqualerta/features/map/presentation/screens/mapa_screen.dart';
import 'package:aqualerta/features/map/presentation/widgets/bloco_ar.dart'
    show textoPoucasLeiturasAlto;
import 'package:aqualerta/shared/widgets/selo_ar.dart';

import 'telas_v3_test.dart' show montar, ArFixo;

/// Fase 2: com o sensor em dia, a manchete e o nível vêm do SENSOR (média de
/// 3 h, com a média de 24 h do próprio sensor como contexto). O modelo CAMS
/// é só uma linha secundária rotulada e nunca uma manchete tranquilizadora.
/// O selo do mapa segue a mesma regra.

Map<String, dynamic> _linha({int? iqar = 54, String nivel = 'N2'}) => {
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

Map<String, dynamic> _contexto(
        {bool temSensor = true, String situacao = 'saudável'}) =>
    {
      'region_id': 'r-compensa',
      'tem_sensor': temSensor,
      'sensor_nome': temSensor ? 'Manaus' : null,
      'sensor_provedor': temSensor ? 'AirGradient' : null,
      'sensor_distancia_km': temSensor ? 2 : null,
      'sensor_situacao': temSensor ? situacao : null,
      'comparacao_ok': false,
      'epoca_fumaca': false,
      'focos_300km_72h': 0,
      'cautela_boa': false,
      'aviso_sensor_ligado': false,
    };

/// Linha de ar_agora() com o sensor em dia. [dia] null = poucas leituras.
Map<String, dynamic> _agora({
  required double pm,
  required String nivel,
  double? dia,
  String? nivelDia,
}) =>
    {
      'region_id': 'r-compensa',
      'pm25_3h': pm,
      'iqar_3h': 100,
      'nivel_3h': nivel,
      'pm25_24h_sensor': dia,
      'nivel_24h_sensor': nivelDia,
      'piorou': false,
      'ate': '2026-11-27T00:00:00+00:00',
      'ultima_leitura': '2026-11-27T00:00:00+00:00',
      'sensor_parado': false,
      'sem_dados_h': null,
    };

Map<String, dynamic> _linhaParado({int horas = 13}) => {
      'region_id': 'r-compensa',
      'pm25_3h': null,
      'nivel_3h': null,
      'sensor_parado': true,
      'sem_dados_h': horas,
    };

/// Monta o resumo como o repositório monta: modelo + contexto + ar_agora.
ResumoAr _r({
  int? iqar = 54,
  String nivelModelo = 'N2',
  Map<String, dynamic>? contexto,
  Map<String, dynamic>? agora,
}) {
  var r = ResumoAr.doJson(_linha(iqar: iqar, nivel: nivelModelo))
      .comContexto(ContextoAr.doJson(contexto ?? _contexto()));
  if (agora != null) {
    if (agora['sensor_parado'] == true) {
      r = r.comSemDados(SemDadosSensor.doJson(agora));
    } else {
      r = r.comAgora(AgoraAr.doJson(agora));
    }
  }
  return r;
}

Finder _rolavel() => find
    .descendant(
        of: find.byType(DraggableScrollableSheet),
        matching: find.byType(Scrollable))
    .first;

Future<void> _abrir(WidgetTester t, ResumoAr r) async {
  await montar(t, const MapaScreen(), ar: ArFixo([r]));
  await t.pump(const Duration(milliseconds: 100));
  await t.scrollUntilVisible(find.text('Limitações'), 200,
      scrollable: _rolavel());
}

Finder _anuncia(String rotulo) => find
    .byWidgetPredicate((w) => w is Semantics && w.properties.label == rotulo);

void main() {
  group('A. Manchete do sensor quando ele está em dia', () {
    testWidgets(
        'sensor em dia com valor ALTO: manchete "muito ruim" do sensor, aviso de '
        'piora e o modelo (moderada) só como estimativa rotulada', (t) async {
      await _abrir(
          t,
          _r(
            agora: _agora(pm: 101.0, nivel: 'N4', dia: 40.0, nivelDia: 'N2'),
          ));
      expect(find.byKey(const Key('ar-manchete-sensor')), findsOneWidget);
      expect(find.text('Ar muito ruim'), findsOneWidget);
      expect(_anuncia('Medição do sensor: qualidade do ar muito ruim'),
          findsOneWidget);
      expect(
          find.textContaining(
              'MP2,5 de 101,0 µg/m³, na faixa muito ruim do IQAr'),
          findsOneWidget);
      expect(find.text('Média de 24 h do sensor: 40,0 µg/m³ (faixa moderada).'),
          findsOneWidget);
      expect(find.byKey(const Key('ar-piorou')), findsOneWidget);
      // O modelo diz "moderada", mas é só uma linha rotulada, nunca a manchete.
      expect(find.text('Ar moderada · índice 54'), findsNothing);
      expect(find.text('Ar moderada'), findsNothing);
      expect(
          find.text('Estimativa do modelo (CAMS, não é medição): '
              'ar moderada, índice 54.'),
          findsOneWidget);
      expect(
          find.textContaining('O modelo está bem abaixo do que o sensor mede'),
          findsOneWidget);
      expect(find.text('Sem medição agora'), findsNothing);
      expect(find.textContaining('falta de ar'), findsOneWidget,
          reason: 'o texto de saúde segue o nível do sensor');
    });

    testWidgets(
        'sensor em dia com valor BAIXO: "Boa" vem da medição, e o modelo '
        'continua rotulado como estimativa', (t) async {
      await _abrir(
          t,
          _r(
            iqar: 100,
            nivelModelo: 'N3',
            agora: _agora(pm: 8.0, nivel: 'N1', dia: 9.0, nivelDia: 'N1'),
          ));
      expect(find.text('Ar boa'), findsOneWidget);
      expect(
          _anuncia('Medição do sensor: qualidade do ar boa'), findsOneWidget);
      expect(find.text('Sem medição agora'), findsNothing);
      expect(find.byKey(const Key('ar-piorou')), findsNothing);
      expect(
          find.text('Estimativa do modelo (CAMS, não é medição): '
              'ar ruim, índice 100.'),
          findsOneWidget);
      expect(find.textContaining('O sensor é um aparelho de baixo custo'),
          findsOneWidget);
    });

    testWidgets('sensor parado: "Sem medição agora", sem categoria do modelo',
        (t) async {
      await _abrir(t, _r(agora: _linhaParado()));
      expect(find.text('Sem medição agora'), findsOneWidget);
      expect(find.byKey(const Key('ar-manchete-sensor')), findsNothing);
      expect(find.byType(SeloAr), findsNothing);
      expect(find.text('Ar moderada · índice 54'), findsNothing);
      expect(_anuncia('Qualidade do ar moderada, índice 54'), findsNothing);
      expect(find.textContaining('sem dados há 13 horas'), findsOneWidget);
      expect(find.byKey(const Key('ar-modelo-subestima')), findsOneWidget);
    });

    testWidgets(
        'região sem sensor: "Sem medição agora", sem categoria do modelo',
        (t) async {
      await _abrir(t, _r(contexto: _contexto(temSensor: false)));
      expect(find.text('Sem medição agora'), findsOneWidget);
      expect(find.byType(SeloAr), findsNothing);
      expect(find.text('Ar moderada · índice 54'), findsNothing);
      expect(find.byKey(const Key('ar-sensor-sem-dados')), findsNothing);
      expect(find.byKey(const Key('ar-modelo-subestima')), findsOneWidget);
    });

    testWidgets(
        'sensor em dia mesmo sem estimativa do modelo: a manchete aparece',
        (t) async {
      await _abrir(
          t,
          _r(
            iqar: null,
            agora: _agora(pm: 60.0, nivel: 'N3', dia: 55.0, nivelDia: 'N3'),
          ));
      expect(find.text('Ar ruim'), findsOneWidget);
      expect(
          find.text(
              'Sem estimativa de qualidade do ar para esta região agora.'),
          findsNothing);
      expect(find.byKey(const Key('ar-estimativa-modelo')), findsNothing);
    });

    test(
        'regra de domínio: Boa e Moderada só saem de uma medição com cobertura',
        () {
      for (final n in ['N1', 'N2']) {
        for (final c in [
          _r(nivelModelo: n, iqar: n == 'N1' ? 30 : 54),
          _r(nivelModelo: n, iqar: n == 'N1' ? 30 : 54, agora: _linhaParado()),
          _r(
              nivelModelo: n,
              iqar: n == 'N1' ? 30 : 54,
              contexto: _contexto(temSensor: false)),
        ]) {
          expect(c.categoriaVisivel, isNull,
              reason: 'modelo $n sem medição não vira categoria');
        }
      }
      // Modelo "ruim" ou pior pode SUBIR o nível, sempre como estimativa.
      final alto = _r(nivelModelo: 'N4', iqar: 150, agora: _linhaParado());
      expect(alto.categoriaVisivel?.nivel, NivelAr.n4);
      expect(alto.categoriaVisivel?.origem, OrigemAr.modelo);
      // Medição com cobertura vale, até para dizer "Boa".
      final boa =
          _r(agora: _agora(pm: 8.0, nivel: 'N1', dia: 9.0, nivelDia: 'N1'));
      expect(boa.categoriaVisivel?.nivel, NivelAr.n1);
      expect(boa.categoriaVisivel?.origem, OrigemAr.sensor);
    });
  });

  group('C. Poucas leituras (ex-"cobertura baixa")', () {
    testWidgets(
        'valor parcial ALTO: aparece (pode subir), marcado "poucas leituras" e '
        'sem a comparação com 24 h', (t) async {
      await _abrir(t, _r(agora: _agora(pm: 101.0, nivel: 'N4')));
      expect(find.text('Ar muito ruim'), findsOneWidget);
      expect(find.text(textoPoucasLeiturasAlto), findsOneWidget);
      expect(find.byKey(const Key('ar-poucas-leituras')), findsOneWidget);
      expect(find.byKey(const Key('ar-sensor-24h')), findsNothing);
      expect(find.byKey(const Key('ar-piorou')), findsNothing);
      expect(find.text('Sem medição agora'), findsNothing);
    });

    testWidgets(
        'valor parcial BAIXO: nunca tranquiliza; vira "Sem medição agora" com o '
        'motivo', (t) async {
      await _abrir(t, _r(agora: _agora(pm: 40.0, nivel: 'N2')));
      expect(find.text('Sem medição agora'), findsOneWidget);
      expect(find.byType(SeloAr), findsNothing);
      expect(_anuncia('Medição do sensor: qualidade do ar moderada'),
          findsNothing);
      final motivo = find.byKey(const Key('ar-poucas-leituras'));
      expect(motivo, findsOneWidget);
      expect(
          find.descendant(
              of: find.byType(Column),
              matching: find.textContaining('não bastam para dizer que o ar '
                  'está bom')),
          findsWidgets);
      expect(find.textContaining('40,0 µg/m³, faixa moderada'), findsOneWidget);
      expect(find.byKey(const Key('ar-agora')), findsNothing,
          reason: 'o valor parcial baixo não aparece como leitura normal');
    });

    test('domínio: poucas leituras só mostra categoria de "ruim" para cima',
        () {
      ResumoAr parcial(String nivel) =>
          _r(agora: _agora(pm: 10.0, nivel: nivel));
      expect(parcial('N1').manchete, MancheteAr.poucasLeituras);
      for (final n in ['N1', 'N2']) {
        expect(parcial(n).categoriaVisivel, isNull);
      }
      for (final n in ['N3', 'N4', 'N5']) {
        expect(parcial(n).categoriaVisivel?.origem, OrigemAr.sensorParcial);
      }
    });
  });

  group('B. Selo do mapa segue a mesma regra', () {
    setUp(() => FundoMapa.desligado = true);
    const ligada = {
      'mapa.camadas': ['regioes', 'qualidadeAr'],
    };

    test('texto do selo por situação', () {
      // Sensor parado + modelo "moderada" (as 19:42 de Manaus): sem categoria.
      expect(textoSeloAr(_r(agora: _linhaParado())), 'Ar sem medição');
      expect(textoSeloAr(_r(contexto: _contexto(temSensor: false))),
          'Ar sem medição');
      // Sensor em dia: a categoria do sensor.
      expect(
          textoSeloAr(_r(
              agora:
                  _agora(pm: 101.0, nivel: 'N4', dia: 40.0, nivelDia: 'N2'))),
          'Ar Muito ruim · sensor');
      expect(
          textoSeloAr(_r(
              agora: _agora(pm: 8.0, nivel: 'N1', dia: 9.0, nivelDia: 'N1'))),
          'Ar Boa · sensor');
      // Poucas leituras: só de "ruim" para cima.
      expect(textoSeloAr(_r(agora: _agora(pm: 101.0, nivel: 'N4'))),
          'Ar Muito ruim · sensor, poucas leituras');
      expect(textoSeloAr(_r(agora: _agora(pm: 40.0, nivel: 'N2'))),
          'Ar sem medição');
      // Sem medição, modelo "muito ruim": pode subir, como estimativa.
      expect(
          textoSeloAr(_r(iqar: 150, nivelModelo: 'N4', agora: _linhaParado())),
          'Ar 150 · Muito ruim (estimativa)');
      // Nada de nada, e estados do carregamento.
      expect(textoSeloAr(_r(iqar: null)), 'Ar sem estimativa');
      expect(textoSeloAr(null, carregando: true), 'Ar …');
      expect(textoSeloAr(null), isNull);
    });

    testWidgets(
        'sensor parado + modelo "moderada": o selo diz "sem medição", '
        'sem cor de nível', (t) async {
      await montar(t, const MapaScreen(),
          ar: ArFixo([_r(agora: _linhaParado())]), preferencias: ligada);
      await t.pump(const Duration(milliseconds: 100));
      await t.pump(const Duration(milliseconds: 100));
      final selo = find.byKey(const ValueKey('selo-ar-r-compensa'));
      expect(find.descendant(of: selo, matching: find.text('Ar sem medição')),
          findsOneWidget);
      expect(
          find.descendant(of: selo, matching: find.textContaining('Moderada')),
          findsNothing,
          reason:
              'a legenda lista as faixas, mas o selo não mostra a do modelo');
      // Sem o quadradinho da cor do nível: ícone neutro no lugar.
      expect(find.descendant(of: selo, matching: find.byIcon(Icons.air)),
          findsOneWidget);
    });

    testWidgets('sensor em dia: o selo usa a categoria e a cor do SENSOR',
        (t) async {
      await montar(t, const MapaScreen(),
          ar: ArFixo([
            _r(agora: _agora(pm: 101.0, nivel: 'N4', dia: 40.0, nivelDia: 'N2'))
          ]),
          preferencias: ligada);
      await t.pump(const Duration(milliseconds: 100));
      await t.pump(const Duration(milliseconds: 100));
      final selo = find.byKey(const ValueKey('selo-ar-r-compensa'));
      expect(
          find.descendant(
              of: selo, matching: find.text('Ar Muito ruim · sensor')),
          findsOneWidget);
      final cores = find
          .descendant(of: selo, matching: find.byType(Container))
          .evaluate()
          .map((e) => (e.widget as Container).decoration)
          .whereType<BoxDecoration>()
          .map((d) => d.color)
          .toList();
      expect(cores, contains(NivelAr.n4.corClara));
      expect(cores, isNot(contains(NivelAr.n2.corClara)),
          reason: 'a cor do modelo "moderada" não aparece');
    });

    testWidgets('legenda deixa claro que mistura sensor e estimativa',
        (t) async {
      await montar(t, const MapaScreen(),
          ar: ArFixo([_r(agora: _linhaParado())]), preferencias: ligada);
      await t.pump(const Duration(milliseconds: 100));
      await t.pump(const Duration(milliseconds: 100));
      expect(find.textContaining('Ar (sensor ou modelo)'), findsOneWidget);
      expect(find.textContaining('Ar (modelo)'), findsNothing);
    });
  });
}
