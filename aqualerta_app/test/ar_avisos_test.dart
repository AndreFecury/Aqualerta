import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:aqualerta/core/config/mapas.dart';
import 'package:aqualerta/core/domain/ar.dart';
import 'package:aqualerta/core/domain/severidade.dart';
import 'package:aqualerta/core/state/painel_cubit.dart';
import 'package:aqualerta/features/alerts/presentation/screens/alertas_screen.dart';
import 'package:aqualerta/features/alerts/presentation/screens/detalhe_alerta_screen.dart';
import 'package:aqualerta/features/map/presentation/screens/mapa_screen.dart';

import 'apoio/dados_exemplo.dart';
import 'telas_v3_test.dart' show montar;

/// Linha como a tabela ar_avisos devolve (valores inventados).
Map<String, dynamic> _linha({bool ativo = true, String sev = 'HIGH'}) => {
      'id': 'aviso-ar-1',
      'region_id': 'r-compensa',
      'severity': sev,
      'fonte': 'sensor',
      'limite_ugm3': 75,
      'nowcast_atual': 98.4,
      'nowcast_max': 143.0,
      'inicio': '2026-10-08T14:00:00+00:00',
      'fim': ativo ? null : '2026-10-09T02:00:00+00:00',
      'situacao': ativo ? 'ativo' : 'encerrado',
      'motivo_fim':
          ativo ? null : 'o índice ficou abaixo de 75 µg/m³ por 3 h seguidas',
    };

CartaFalsa _dados(List<AvisoAr> avisos) =>
    CartaFalsa()..avisosArFalsos = avisos;

void main() {
  setUp(() => FundoMapa.desligado = true);

  test('lê a linha da tabela', () {
    final a = AvisoAr.doJson(_linha());
    expect(a.ativo, isTrue);
    expect(a.severidade, Severidade.alto);
    expect(a.nivel, NivelAr.n4);
    expect(a.titulo, 'Ar muito ruim');
    expect(AvisoAr.doJson(_linha(sev: 'CRITICAL')).titulo, 'Ar péssimo');
    expect(AvisoAr.doJson(_linha(ativo: false)).ativo, isFalse);
  });

  test('painel carrega os avisos de ar à parte dos alertas de cheia', () async {
    SharedPreferences.setMockInitialValues({});
    final painel =
        PainelCubit(_dados([AvisoAr.doJson(_linha())]), ouvirTempoReal: false);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(painel.state.avisosArAtivos, hasLength(1));
    expect(painel.state.avisoAr('aviso-ar-1'), isNotNull);
    expect(painel.state.ativos.where((a) => a.id == 'aviso-ar-1'), isEmpty,
        reason: 'não entra na lista de alertas de cheia');
    final semAr = PainelCubit(CartaFalsa(), ouvirTempoReal: false);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(painel.state.severidadeDaRegiao('r-compensa'),
        semAr.state.severidadeDaRegiao('r-compensa'),
        reason: 'ar não muda o risco de cheia');
    await semAr.close();
    await painel.close();
  });

  testWidgets('aba Alertas: seção própria e conta no total de ativos',
      (t) async {
    await montar(t, const AlertasScreen(),
        dados: _dados([AvisoAr.doJson(_linha())]));
    await t.pump(const Duration(milliseconds: 100));
    expect(find.text('Qualidade do ar (sensor)'), findsOneWidget);
    expect(find.text('Ar muito ruim em Compensa'), findsOneWidget);
    expect(find.textContaining('Sensor perto · desde'), findsOneWidget);
    expect(find.textContaining('98 µg/m³ agora'), findsOneWidget);
  });

  testWidgets('aviso encerrado vai para a aba Encerrados', (t) async {
    await montar(t, const AlertasScreen(),
        dados: _dados([AvisoAr.doJson(_linha(ativo: false))]));
    await t.pump(const Duration(milliseconds: 100));
    expect(find.text('Qualidade do ar (sensor)'), findsNothing);
    await t.tap(find.text('Encerrados'));
    await t.pumpAndSettle();
    expect(find.text('Ar muito ruim em Compensa'), findsOneWidget);
  });

  testWidgets('detalhe: sensor, índice em tempo quase real, não oficial',
      (t) async {
    await montar(t, const DetalheAlertaScreen(alertaId: 'aviso-ar-1'),
        dados: _dados([AvisoAr.doJson(_linha())]));
    await t.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const Key('aviso-ar-titulo')), findsOneWidget);
    expect(find.text('Ar muito ruim em Compensa'), findsOneWidget);
    expect(find.textContaining('Ativo desde 08/10 às 10:00'), findsOneWidget);
    expect(find.textContaining('agora 98 µg/m³'), findsOneWidget);
    expect(find.textContaining('o maior desde o início: 143 µg/m³'),
        findsOneWidget);
    expect(find.textContaining('não o índice oficial do MMA'), findsOneWidget);
    expect(find.textContaining('baixo custo'), findsOneWidget);
    expect(find.text('Alerta não encontrado'), findsNothing);
  });

  testWidgets('cartão da região mostra o botão do aviso ativo', (t) async {
    await montar(t, const MapaScreen(),
        dados: _dados([AvisoAr.doJson(_linha())]), ar: null);
    await t.pump(const Duration(milliseconds: 100));
    final botao = find.byKey(const Key('ver-aviso-ar'));
    await t.scrollUntilVisible(botao, 200,
        scrollable: find
            .descendant(
                of: find.byType(DraggableScrollableSheet),
                matching: find.byType(Scrollable))
            .first);
    expect(find.text('Ver aviso: ar muito ruim (sensor)'), findsOneWidget);
  });
}
