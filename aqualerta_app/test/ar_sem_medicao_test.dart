import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aqualerta/core/domain/ar.dart';
import 'package:aqualerta/features/map/presentation/screens/mapa_screen.dart';
import 'package:aqualerta/shared/widgets/selo_ar.dart';

import 'telas_v3_test.dart' show montar, ArFixo;

/// Sensor calado ("parado") ou ausente: o cartão NÃO pode abrir com uma
/// categoria tranquilizadora (Boa/Moderada) vinda só do modelo.
///
/// Reproduz as 19:42 de Manaus (hora local): o sensor perto estava sem
/// leituras há horas, o modelo CAMS dizia "moderada" (IQAr 80) e os sensores
/// vizinhos mediam MP2,5 de 93 a 111 µg/m³.

Map<String, dynamic> _linha({int iqar = 80, String nivel = 'N2'}) => {
      'region_id': 'r-compensa',
      'hora': '2026-11-22T23:00:00+00:00',
      'iqar': iqar,
      'nivel': nivel,
      'poluente': 'pm2_5',
      'pm2_5_24': 35.0,
      'iqar_previsto_48h': 70,
      'hora_pior_prevista': '2026-11-24T20:00:00+00:00',
      'tendencia': 'estavel',
      'focos_24h': 0,
      'fumaca_provavel': false,
      'atualizado_em': DateTime.now().toUtc().toIso8601String(),
    };

Map<String, dynamic> _contexto({
  bool temSensor = true,
  String? situacao = 'parado',
  bool cautela = false,
}) =>
    {
      'region_id': 'r-compensa',
      'tem_sensor': temSensor,
      'sensor_nome': temSensor ? 'Manaus' : null,
      'sensor_provedor': temSensor ? 'AirGradient' : null,
      'sensor_distancia_km': temSensor ? 2 : null,
      'sensor_situacao': temSensor ? situacao : null,
      'comparacao_ok': false,
      'epoca_fumaca': true,
      'focos_300km_72h': 0,
      'cautela_boa': cautela,
      'aviso_sensor_ligado': false,
    };

ResumoAr _resumo({
  int iqar = 80,
  String nivel = 'N2',
  Map<String, dynamic>? contexto,
}) {
  final r = ResumoAr.doJson(_linha(iqar: iqar, nivel: nivel));
  return contexto == null ? r : r.comContexto(ContextoAr.doJson(contexto));
}

Finder _rolavel() => find
    .descendant(
        of: find.byType(DraggableScrollableSheet),
        matching: find.byType(Scrollable))
    .first;

/// Rótulos de leitor de tela que anunciam uma categoria do modelo como se
/// fosse a medição ("Qualidade do ar moderada, índice 80").
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
  group('Sem medição agora (19:42 de Manaus)', () {
    testWidgets(
        'sensor parado + modelo "moderada": sem manchete tranquilizadora',
        (t) async {
      await _abrir(t, _resumo(contexto: _contexto()));
      // A manchete é "Sem medição agora"…
      expect(find.text('Sem medição agora'), findsOneWidget);
      // …e a categoria do modelo NÃO aparece como manchete nem como selo.
      expect(find.text('Ar moderada · índice 80'), findsNothing);
      expect(find.byType(SeloAr), findsNothing);
      expect(_anunciaCategoria(), findsNothing,
          reason: 'o leitor de tela também não pode anunciar "moderada"');
      // A estimativa fica como linha secundária, rotulada.
      final linha = find.byKey(const Key('ar-estimativa-modelo'));
      expect(linha, findsOneWidget);
      expect(
          find.descendant(
              of: linha, matching: find.textContaining('Estimativa do modelo')),
          findsOneWidget);
      expect(
          find.descendant(
              of: linha, matching: find.textContaining('não é medição')),
          findsOneWidget);
      expect(
          find.descendant(of: linha, matching: find.textContaining('moderada')),
          findsOneWidget);
      // O sensor calado é dito com todas as letras.
      expect(find.textContaining('sem leituras recentes'), findsOneWidget);
    });

    testWidgets('modelo "boa" com sensor parado: também sem manchete tranquila',
        (t) async {
      await _abrir(t, _resumo(iqar: 30, nivel: 'N1', contexto: _contexto()));
      expect(find.text('Sem medição agora'), findsOneWidget);
      expect(find.text('Ar boa · índice 30'), findsNothing);
      expect(find.byType(SeloAr), findsNothing);
      expect(_anunciaCategoria(), findsNothing);
      expect(find.byKey(const Key('ar-estimativa-modelo')), findsOneWidget);
    });

    testWidgets('sem sensor perto: mesma regra', (t) async {
      await _abrir(t, _resumo(contexto: _contexto(temSensor: false)));
      expect(find.text('Sem medição agora'), findsOneWidget);
      expect(find.text('Ar moderada · índice 80'), findsNothing);
      expect(find.byType(SeloAr), findsNothing);
      expect(_anunciaCategoria(), findsNothing);
    });

    testWidgets('contexto não carregou: não dá para afirmar medição',
        (t) async {
      await _abrir(t, _resumo());
      expect(find.text('Sem medição agora'), findsOneWidget);
      expect(find.text('Ar moderada · índice 80'), findsNothing);
      expect(find.byType(SeloAr), findsNothing);
    });

    testWidgets(
        'modelo "ruim" ou pior continua em destaque, rotulado como estimativa',
        (t) async {
      await _abrir(t, _resumo(iqar: 100, nivel: 'N3', contexto: _contexto()));
      expect(find.text('Sem medição agora'), findsOneWidget);
      // O modelo pode SUBIR o nível: o selo grande fica, marcado como estimativa.
      expect(find.byType(SeloAr), findsOneWidget);
      expect(find.text('Ar ruim · índice 100'), findsOneWidget);
      expect(
          find.byWidgetPredicate((w) =>
              w is Semantics &&
              w.properties.label ==
                  'Estimativa do modelo: qualidade do ar ruim, índice 100'),
          findsOneWidget);
      expect(find.byKey(const Key('ar-estimativa-modelo')), findsOneWidget);
      expect(find.textContaining('Qualquer pessoa pode ter tosse seca'),
          findsOneWidget,
          reason: 'o texto de saúde do nível ruim não some');
    });

    testWidgets('com cautela e modelo "boa", a frase de cautela continua',
        (t) async {
      await _abrir(t,
          _resumo(iqar: 30, nivel: 'N1', contexto: _contexto(cautela: true)));
      expect(find.byKey(const Key('ar-cautela-boa')), findsOneWidget);
    });
  });

  group('Sensor saudável: nada muda', () {
    testWidgets('manchete com a categoria, como antes', (t) async {
      await montar(t, const MapaScreen(),
          ar: ArFixo([_resumo(contexto: _contexto(situacao: 'saudável'))]));
      await t.pump(const Duration(milliseconds: 100));
      await t.scrollUntilVisible(find.text('Ar moderada · índice 80'), 200,
          scrollable: _rolavel());
      expect(find.text('Sem medição agora'), findsNothing);
      expect(find.byKey(const Key('ar-sem-medicao')), findsNothing);
    });

    testWidgets('cobertura baixa (sensor ainda manda dados): igual a antes',
        (t) async {
      await montar(t, const MapaScreen(),
          ar: ArFixo(
              [_resumo(contexto: _contexto(situacao: 'cobertura baixa'))]));
      await t.pump(const Duration(milliseconds: 100));
      await t.scrollUntilVisible(find.text('Ar moderada · índice 80'), 200,
          scrollable: _rolavel());
      expect(find.text('Sem medição agora'), findsNothing);
    });
  });
}
