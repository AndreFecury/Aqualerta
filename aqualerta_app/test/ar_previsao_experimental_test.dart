import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aqualerta/core/domain/ar.dart';
import 'package:aqualerta/features/map/presentation/screens/mapa_screen.dart';
import 'package:aqualerta/features/map/presentation/widgets/bloco_ar.dart'
    show textoPrevisaoExperimental;

import 'telas_v3_test.dart' show montar, ArFixo;

/// A previsão numérica de 48 h fica escondida até ser validada contra valores
/// observados (pico observado ~IQAr 177 contra ~70 previstos).

Map<String, dynamic> _linha({int? previsto = 70}) => {
      'region_id': 'r-compensa',
      'hora': '2026-11-22T23:00:00+00:00',
      'iqar': 54,
      'nivel': 'N2',
      'poluente': 'pm2_5',
      'pm2_5_24': 27.3,
      'iqar_previsto_48h': previsto,
      'hora_pior_prevista':
          previsto == null ? null : '2026-11-24T20:00:00+00:00',
      'tendencia': 'sobe',
      'focos_24h': 0,
      'fumaca_provavel': false,
      'atualizado_em': DateTime.now().toUtc().toIso8601String(),
    };

ResumoAr _resumo({int? previsto = 70}) =>
    ResumoAr.doJson(_linha(previsto: previsto)).comContexto(ContextoAr.doJson({
      'region_id': 'r-compensa',
      'tem_sensor': true,
      'sensor_nome': 'Manaus',
      'sensor_provedor': 'AirGradient',
      'sensor_distancia_km': 2,
      'sensor_situacao': 'saudável',
      'comparacao_ok': false,
    }));

Finder _rolavel() => find
    .descendant(
        of: find.byType(DraggableScrollableSheet),
        matching: find.byType(Scrollable))
    .first;

void main() {
  testWidgets('com previsão: só o aviso de "experimental", sem número nem hora',
      (t) async {
    await montar(t, const MapaScreen(), ar: ArFixo([_resumo()]));
    await t.pump(const Duration(milliseconds: 100));
    await t.scrollUntilVisible(
        find.byKey(const Key('ar-previsao-experimental')), 200,
        scrollable: _rolavel());
    expect(find.text(textoPrevisaoExperimental), findsOneWidget);
    expect(textoPrevisaoExperimental, contains('experimental'));
    expect(find.textContaining('pior previsto'), findsNothing);
    expect(find.textContaining('(70)'), findsNothing);
    expect(find.textContaining('ter 20h'), findsNothing);
    // O que é observado continua: a tendência em relação a ontem.
    expect(find.text('Piorando em relação a ontem'), findsOneWidget);
  });

  testWidgets('o dado da previsão continua no domínio (só a tela o esconde)',
      (t) async {
    final r = _resumo();
    expect(r.previsto48h, 70);
    expect(r.horaPiorPrevista, isNotNull);
  });

  testWidgets('sem previsão: nada sobre previsão', (t) async {
    await montar(t, const MapaScreen(), ar: ArFixo([_resumo(previsto: null)]));
    await t.pump(const Duration(milliseconds: 100));
    await t.scrollUntilVisible(find.text('Piorando em relação a ontem'), 200,
        scrollable: _rolavel());
    expect(find.byKey(const Key('ar-previsao-experimental')), findsNothing);
  });
}
