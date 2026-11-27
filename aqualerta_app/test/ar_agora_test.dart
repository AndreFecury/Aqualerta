import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aqualerta/core/domain/ar.dart';
import 'package:aqualerta/features/map/presentation/screens/mapa_screen.dart';

import 'telas_v3_test.dart' show montar, ArFixo;

/// Indicador "agora" (média de 3 h do sensor) ao lado do IQAr de 24 h.
/// Valores do teste SQL ar_agora_test.sql (126,7 µg/m³ = N5 contra 24 h = N2).

Map<String, dynamic> _linha({int iqar = 54}) => {
      'region_id': 'r-compensa',
      'hora': '2026-11-21T21:00:00+00:00',
      'iqar': iqar,
      'nivel': 'N2',
      'poluente': 'pm2_5',
      'pm2_5_24': 27.3,
      'iqar_previsto_48h': 55,
      'hora_pior_prevista': '2026-11-22T22:00:00+00:00',
      'tendencia': 'estavel',
      'focos_24h': 0,
      'fumaca_provavel': false,
      'atualizado_em': DateTime.now().toUtc().toIso8601String(),
    };

Map<String, dynamic> _contextoSaudavel() => {
      'region_id': 'r-compensa',
      'tem_sensor': true,
      'sensor_nome': 'Manaus',
      'sensor_provedor': 'AirGradient',
      'sensor_distancia_km': 2,
      'sensor_situacao': 'saudável',
      'comparacao_ok': false,
      'epoca_fumaca': true,
      'focos_300km_72h': 0,
      'cautela_boa': false,
      'aviso_sensor_ligado': false,
    };

Map<String, dynamic> _agora({double pm = 126.7, String nivel = 'N5'}) => {
      'region_id': 'r-compensa',
      'pm25_3h': pm,
      'iqar_3h': 202,
      'nivel_3h': nivel,
      'pm25_24h_sensor': 24.6,
      'nivel_24h_sensor': 'N2',
      'piorou': true,
      'ate': '2026-11-23T00:00:00+00:00',
    };

ResumoAr _resumo({AgoraAr? agora}) => ResumoAr.doJson(_linha())
    .comContexto(ContextoAr.doJson(_contextoSaudavel()))
    .comAgora(agora);

Finder _rolavel() => find
    .descendant(
        of: find.byType(DraggableScrollableSheet),
        matching: find.byType(Scrollable))
    .first;

void main() {
  group('AgoraAr (domínio)', () {
    test('lê a linha da RPC e não usa nome de índice estrangeiro', () {
      final a = AgoraAr.doJson(_agora())!;
      expect(a.pm25, 126.7);
      expect(a.nivel, NivelAr.n5);
      expect(a.iqar, 202);
      expect(a.textoMedia, contains('126,7 µg/m³'));
      expect(a.textoMedia, contains('Não é o índice oficial'));
      expect(a.textoMedia, isNot(contains('AQI')));
      expect(AgoraAr.textoPiorou, isNot(contains('AQI')));
    });

    test('linha sem valor ou sem faixa não vira indicador', () {
      expect(AgoraAr.doJson({..._agora(), 'pm25_3h': null}), isNull);
      expect(AgoraAr.doJson({..._agora(), 'nivel_3h': null}), isNull);
    });

    test('"piorou" só com 2 ou mais níveis acima do índice de 24 h', () {
      AgoraAr em(NivelAr n) => AgoraAr(regiaoId: 'r', pm25: 1, nivel: n);
      expect(em(NivelAr.n4).piorou(NivelAr.n2), isTrue);
      expect(em(NivelAr.n3).piorou(NivelAr.n1), isTrue);
      expect(em(NivelAr.n3).piorou(NivelAr.n2), isFalse, reason: '1 nível');
      expect(em(NivelAr.n2).piorou(NivelAr.n2), isFalse);
      expect(em(NivelAr.n1).piorou(NivelAr.n4), isFalse,
          reason: 'melhorou não avisa');
    });

    test('comAgora e comContexto preservam um ao outro', () {
      final a = AgoraAr.doJson(_agora());
      final r = ResumoAr.doJson(_linha())
          .comAgora(a)
          .comContexto(ContextoAr.doJson(_contextoSaudavel()));
      expect(r.agora, same(a));
      expect(r.contexto, isNotNull);
      expect(r.comAgora(null).contexto, isNotNull);
    });
  });

  group('Cartão: 24 h e agora lado a lado', () {
    testWidgets(
        'ar piorou: mostra as duas, rotuladas, e o aviso em linguagem simples',
        (t) async {
      await montar(t, const MapaScreen(),
          ar: ArFixo([_resumo(agora: AgoraAr.doJson(_agora()))]));
      await t.pump(const Duration(milliseconds: 100));
      await t.scrollUntilVisible(find.byKey(const Key('ar-agora')), 200,
          scrollable: _rolavel());
      expect(find.text('Ar moderada · índice 54'), findsOneWidget,
          reason: 'a categoria oficial (24 h) continua');
      expect(find.byKey(const Key('ar-rotulo-24h')), findsOneWidget);
      expect(find.textContaining('média de 24 h'), findsWidgets);
      expect(
          find.textContaining('Agora (sensor, média das últimas 3 h): '
              'MP2,5 de 126,7 µg/m³, na faixa péssima do IQAr'),
          findsOneWidget);
      expect(find.textContaining('Até as 20:00'), findsOneWidget,
          reason: '00:00 UTC = 20:00 em Manaus');
      expect(find.byKey(const Key('ar-piorou')), findsOneWidget);
      expect(
          find.textContaining('Nas últimas horas o ar piorou'), findsOneWidget);
      expect(find.textContaining('AQI'), findsNothing);
    });

    testWidgets('1 nível acima: mostra o agora, sem o aviso', (t) async {
      await montar(t, const MapaScreen(),
          ar: ArFixo(
              [_resumo(agora: AgoraAr.doJson(_agora(pm: 60, nivel: 'N3')))]));
      await t.pump(const Duration(milliseconds: 100));
      await t.scrollUntilVisible(find.byKey(const Key('ar-agora')), 200,
          scrollable: _rolavel());
      expect(find.textContaining('na faixa ruim do IQAr'), findsOneWidget);
      expect(find.byKey(const Key('ar-piorou')), findsNothing);
    });

    testWidgets('sem o agora (sensor sem 3 h válidas): nada inventado',
        (t) async {
      await montar(t, const MapaScreen(), ar: ArFixo([_resumo()]));
      await t.pump(const Duration(milliseconds: 100));
      await t.scrollUntilVisible(find.text('Ar moderada · índice 54'), 200,
          scrollable: _rolavel());
      expect(find.byKey(const Key('ar-agora')), findsNothing);
      expect(find.byKey(const Key('ar-piorou')), findsNothing);
    });
  });
}
