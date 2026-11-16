import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aqualerta/core/domain/severidade.dart';
import 'package:aqualerta/core/utils/formato.dart';
import 'package:aqualerta/shared/theme/aqua_theme.dart';
import 'package:aqualerta/shared/widgets/regua.dart';
import 'package:aqualerta/shared/widgets/selo_severidade.dart';

const _manaus = CotasEstacao(alerta: 27, inundacao: 27.5, severa: 29);

Widget _app(Widget filho, {ThemeData? tema, double escala = 1}) => MaterialApp(
      theme: tema ?? AquaTheme.claro,
      home: MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(escala)),
        child: Scaffold(body: Center(child: filho)),
      ),
    );

void main() {
  test('formata metros e diferenças em português', () {
    expect(formatarMetros(27.3), '27,3');
    expect(formatarMetros(27), '27');
    expect(formatarDiferenca(0.3), '30 cm');
    expect(formatarDiferenca(1.7), '1,7 m');
    expect(formatarMetros(8.43, casas: 2), '8,43');
    expect(formatarTendencia(0.12), 'Subiu 12 cm em 24 h');
    expect(formatarTendencia(-1.2), 'Desceu 1,2 m em 24 h');
    expect(formatarTendencia(0.004), 'Estável em 24 h');
    expect(formatarTendencia(null), isNull);
  });

  testWidgets('régua na seca mostra o rio muito abaixo do alerta sem quebrar',
      (t) async {
    await t.pumpWidget(
        _app(const Regua(cotas: _manaus, nivel: 16.14, rio: 'Rio Negro')));
    expect(find.bySemanticsLabel(RegExp(r'16,14 metros.*inundação severa 29')),
        findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('régua descreve o nível para leitores de tela', (t) async {
    await t.pumpWidget(
        _app(const Regua(cotas: _manaus, nivel: 27.3, rio: 'Rio Negro')));
    expect(
      find.bySemanticsLabel(RegExp(r'Régua do Rio Negro: 27,30 metros')),
      findsOneWidget,
    );
  });

  testWidgets('régua sem leitura avisa que não há dado', (t) async {
    await t.pumpWidget(_app(const Regua(
        cotas: _manaus,
        nivel: null,
        rio: 'Rio Tapajós',
        direcao: Axis.horizontal)));
    expect(find.bySemanticsLabel('Régua do Rio Tapajós: sem leitura recente'),
        findsOneWidget);
  });

  testWidgets('selo mostra nome e ação, nos dois temas e com letra grande',
      (t) async {
    for (final tema in [AquaTheme.claro, AquaTheme.escuro]) {
      await t.pumpWidget(_app(
        const SeloSeveridade(
            severidade: Severidade.alto, mostrarAcao: true, grande: true),
        tema: tema,
        escala: 1.6,
      ));
      expect(find.text('Prepare-se'), findsOneWidget);
      expect(t.takeException(), isNull);
    }
  });
}
