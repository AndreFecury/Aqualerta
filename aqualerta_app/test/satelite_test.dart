import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aqualerta/core/config/mapas.dart';
import 'package:aqualerta/core/domain/satelite.dart';
import 'package:aqualerta/features/map/data/satelite_repository.dart';
import 'package:aqualerta/features/map/presentation/cubit/camadas_cubit.dart';
import 'package:aqualerta/features/map/presentation/screens/mapa_screen.dart';

import 'telas_v3_test.dart' show montar, SateliteVazio;

/// Formato devolvido pela RPC satelite_geojson (números como no PostgREST).
Map<String, Object?> _rpc({
  Object? geometria,
  String observadoEm = '2026-11-03T09:38:21+00:00',
}) =>
    {
      'type': 'FeatureCollection',
      'observacao': {
        'region_id': 'r1',
        'fonte': 'copernicus-gfm',
        'produto': 'ensemble_water_extent',
        'observado_em': observadoEm,
        'area_agua_km2': 574.018,
        'area_inundada_km2': 1.642,
        'cobertura_pct': 100,
        'idade_horas': 360.5,
        'excluida_pct': 74.3,
        'atribuicao':
            'Copernicus Emergency Management Service — Global Flood Monitoring',
      },
      'features': [
        if (geometria != null)
          {
            'type': 'Feature',
            'geometry': geometria,
            'properties': {'observado_em': observadoEm}
          }
      ],
    };

const _quadrado = [
  [-60.0, -3.0],
  [-60.0, -3.1],
  [-59.9, -3.1],
  [-59.9, -3.0],
  [-60.0, -3.0]
];
const _ilha = [
  [-59.97, -3.03],
  [-59.93, -3.03],
  [-59.93, -3.07],
  [-59.97, -3.07],
  [-59.97, -3.03]
];

class _FonteFalsa implements FonteSatelite {
  _FonteFalsa(this.resposta);
  Object? Function() resposta;
  int chamadas = 0;
  @override
  Future<ObservacaoSatelite?> ultima(String regionId) async {
    chamadas++;
    final r = resposta();
    if (r is Exception) throw r;
    return ObservacaoSatelite.doGeoJson(r);
  }
}

void main() {
  group('leitura do GeoJSON', () {
    test('Polygon com buraco', () {
      final o = ObservacaoSatelite.doGeoJson(_rpc(geometria: {
        'type': 'Polygon',
        'coordinates': [_quadrado, _ilha]
      }))!;
      expect(o.areas, hasLength(1));
      expect(o.areas.single.contorno, hasLength(5));
      expect(o.areas.single.buracos, hasLength(1));
      // GeoJSON é [lng, lat]
      expect(o.areas.single.contorno.first.latitude, -3.0);
      expect(o.areas.single.contorno.first.longitude, -60.0);
      expect(o.observadoEm, DateTime.utc(2026, 11, 3, 9, 38, 21));
      expect(o.areaAguaKm2, closeTo(574.018, 1e-9));
      expect(o.areaInundadaKm2, closeTo(1.642, 1e-9));
      expect(o.excluidaPct, closeTo(74.3, 1e-9));
    });

    test('MultiPolygon: um polígono com buraco e outro sem', () {
      final o = ObservacaoSatelite.doGeoJson(_rpc(geometria: {
        'type': 'MultiPolygon',
        'coordinates': [
          [_quadrado, _ilha],
          [_ilha],
        ]
      }))!;
      expect(o.areas.map((a) => a.buracos.length), [1, 0]);
    });

    test('sem geometria (água zero ou já podada): números sem desenho', () {
      final o = ObservacaoSatelite.doGeoJson(_rpc())!;
      expect(o.areas, isEmpty);
      expect(o.areaAguaKm2, greaterThan(0));
    });

    test('região sem observação, lixo e anéis curtos', () {
      expect(
          ObservacaoSatelite.doGeoJson(
              {'type': 'FeatureCollection', 'observacao': null, 'features': []}),
          isNull);
      expect(ObservacaoSatelite.doGeoJson(null), isNull);
      expect(ObservacaoSatelite.doGeoJson('x'), isNull);
      expect(
          areasDaGeometria({
            'type': 'Polygon',
            'coordinates': [
              [
                [0, 0],
                [1, 1]
              ]
            ]
          }),
          isEmpty);
      expect(areasDaGeometria({'type': 'Point', 'coordinates': [0, 0]}),
          isEmpty);
    });

    test('números como texto (numeric do Postgres) também servem', () {
      final j = _rpc();
      (j['observacao'] as Map)['area_agua_km2'] = '12.5';
      expect(ObservacaoSatelite.doGeoJson(j)!.areaAguaKm2, 12.5);
    });
  });

  group('idade', () {
    final obs = ObservacaoSatelite(
        regionId: 'r1',
        observadoEm: DateTime.utc(2026, 11, 3, 9),
        areaAguaKm2: 1);
    test('até 14 dias está em dia; depois, desatualizada', () {
      expect(obs.desatualizada(DateTime.utc(2026, 11, 17, 8)), isFalse);
      expect(obs.desatualizada(DateTime.utc(2026, 11, 17, 10)), isTrue);
      expect(obs.idade(DateTime.utc(2026, 11, 5, 9)).inDays, 2);
    });

    test('hora de Manaus e área no padrão brasileiro', () {
      expect(formatarHoraManaus(DateTime.utc(2026, 11, 3, 9, 38)),
          '03/11/2026, 05:38');
      expect(formatarHoraManaus(DateTime.utc(2026, 11, 4, 2, 5)),
          '03/11/2026, 22:05');
      expect(formatarKm2(1036.32), '1.036');
      expect(formatarKm2(574.018), '574');
      expect(formatarKm2(57.44), '57,4');
      expect(formatarKm2(0.128), '0,13');
    });
  });

  group('SateliteCubit', () {
    test('não busca de novo a mesma região em 30 min', () async {
      var agora = DateTime(2026, 11, 18, 10);
      final fonte = _FonteFalsa(() => _rpc());
      final cubit = SateliteCubit(fonte, relogio: () => agora);
      await cubit.carregar('r1');
      await cubit.carregar('r1');
      agora = agora.add(const Duration(minutes: 29));
      await cubit.carregar('r1');
      expect(fonte.chamadas, 1);
      expect(cubit.de('r1')!.situacao, SituacaoSatelite.pronto);
      agora = agora.add(const Duration(minutes: 2));
      await cubit.carregar('r1');
      expect(fonte.chamadas, 2);
      await cubit.carregar('r2'); // outra região tem cache próprio
      expect(fonte.chamadas, 3);
      await cubit.close();
    });

    test('duas chamadas ao mesmo tempo viram uma busca', () async {
      final fonte = _FonteFalsa(() => _rpc());
      final cubit = SateliteCubit(fonte);
      await Future.wait([cubit.carregar('r1'), cubit.carregar('r1')]);
      expect(fonte.chamadas, 1);
      await cubit.close();
    });

    test('erro fica parado até "Tentar de novo"', () async {
      Object? resposta = Exception('sem rede');
      final fonte = _FonteFalsa(() => resposta);
      final cubit = SateliteCubit(fonte);
      await cubit.carregar('r1');
      expect(cubit.de('r1')!.situacao, SituacaoSatelite.erro);
      await cubit.carregar('r1'); // não repete sozinho
      expect(fonte.chamadas, 1);
      resposta = _rpc();
      await cubit.carregar('r1', forcar: true);
      expect(fonte.chamadas, 2);
      expect(cubit.de('r1')!.observacao, isNotNull);
      await cubit.close();
    });

    test('região sem observação é "pronto" com observação nula', () async {
      final cubit = SateliteCubit(SateliteVazio());
      await cubit.carregar('r1');
      expect(cubit.de('r1')!.situacao, SituacaoSatelite.pronto);
      expect(cubit.de('r1')!.observacao, isNull);
      await cubit.close();
    });
  });

  group('tela do mapa', () {
    setUp(() => FundoMapa.desligado = true);

    Finder rolavelDoCartao() => find
        .descendant(
            of: find.byType(DraggableScrollableSheet),
            matching: find.byType(Scrollable))
        .first;

    testWidgets('camada desligada por padrão: nada é buscado', (t) async {
      final fonte = SateliteVazio();
      await montar(t, const MapaScreen(), satelite: fonte);
      await t.pump(const Duration(milliseconds: 100));
      expect(find.byKey(const ValueKey('camada-satelite')), findsNothing);
      expect(fonte.chamadas, 0);
    });

    testWidgets('camada ligada desenha os polígonos e mostra a legenda',
        (t) async {
      final fonte = _FonteFalsa(() => _rpc(
          observadoEm: DateTime.now()
              .toUtc()
              .subtract(const Duration(days: 2))
              .toIso8601String(),
          geometria: {
            'type': 'MultiPolygon',
            'coordinates': [
              [_quadrado, _ilha],
              [_ilha],
            ]
          }));
      await montar(t, const MapaScreen(), satelite: fonte, preferencias: {
        'mapa.camadas': ['regioes', 'aguaSatelite'],
      });
      await t.pump(const Duration(milliseconds: 100));
      await t.pump(const Duration(milliseconds: 100));
      final camada = t.widget<PolygonLayer>(
          find.byKey(const ValueKey('camada-satelite')));
      expect(camada.polygons, hasLength(2));
      expect(camada.polygons.first.holePointsList, hasLength(1));
      expect(find.text('Água por satélite · há 2 dias'), findsOneWidget);
      expect(fonte.chamadas, 1);

      // O cartão traz o rótulo honesto, a fonte e as limitações.
      await t.scrollUntilVisible(find.text('Limitações'), 200,
          scrollable: rolavelDoCartao());
      expect(find.text('Água aberta detectada por radar (Sentinel-1)'),
          findsOneWidget);
      expect(find.textContaining('574 km² de água'), findsOneWidget);
      expect(find.textContaining('Várzea e igapó'), findsOneWidget);
      expect(find.text('desatualizado'), findsNothing);
    });

    testWidgets('cartão mostra o estado vazio quando não há observação',
        (t) async {
      await montar(t, const MapaScreen(), satelite: SateliteVazio(),
          preferencias: {
            'mapa.camadas': ['regioes', 'aguaSatelite'],
          });
      await t.pump(const Duration(milliseconds: 100));
      await t.scrollUntilVisible(
          find.text(
              'Sem observação de satélite disponível para esta região ainda.'),
          200,
          scrollable: rolavelDoCartao());
      expect(find.byKey(const ValueKey('camada-satelite')), findsNothing);
      expect(find.text('Água por satélite · sem dado nesta região'),
          findsOneWidget);
    });

    testWidgets('observação velha ganha o selo "desatualizado"', (t) async {
      final fonte = _FonteFalsa(() => _rpc(
          observadoEm: DateTime.now()
              .toUtc()
              .subtract(const Duration(days: 20))
              .toIso8601String()));
      await montar(t, const MapaScreen(), satelite: fonte, preferencias: {
        'mapa.camadas': ['regioes', 'aguaSatelite'],
      });
      await t.pump(const Duration(milliseconds: 100));
      await t.scrollUntilVisible(find.text('desatualizado'), 200,
          scrollable: rolavelDoCartao());
      expect(find.text('desatualizado'), findsOneWidget);
    });

    testWidgets('botão do cartão liga a camada e busca a região', (t) async {
      final fonte = SateliteVazio();
      await montar(t, const MapaScreen(), satelite: fonte);
      final botao = find.text('Mostrar água detectada por satélite');
      await t.scrollUntilVisible(botao, 200, scrollable: rolavelDoCartao());
      // Deixa o cartão terminar de se acomodar antes de tocar.
      for (var i = 0; i < 5; i++) {
        await t.pump(const Duration(milliseconds: 200));
      }
      await t.ensureVisible(botao);
      await t.pump(const Duration(milliseconds: 200));
      await t.tap(botao);
      await t.pump(const Duration(milliseconds: 100));
      await t.pump(const Duration(milliseconds: 100));
      expect(fonte.chamadas, 1);
      expect(find.textContaining('Água por satélite'), findsOneWidget);
    });
  });
}
