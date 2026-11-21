import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aqualerta/shared/theme/aqua_theme.dart';
import 'package:aqualerta/shared/widgets/esqueleto.dart';
import 'package:aqualerta/shared/widgets/tremor.dart';

Widget _app(Widget filho, {bool semMovimento = false}) => MaterialApp(
      theme: AquaTheme.claro,
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: semMovimento),
        child: Scaffold(body: filho),
      ),
    );

class _Senha extends StatefulWidget {
  const _Senha();
  @override
  State<_Senha> createState() => _SenhaEstado();
}

class _SenhaEstado extends State<_Senha> {
  int erros = 0;
  @override
  Widget build(BuildContext context) => Column(children: [
        Tremor(
            gatilho: erros,
            child: const SizedBox(key: Key('campo'), width: 100, height: 40)),
        TextButton(
            onPressed: () => setState(() => erros++),
            child: const Text('errar')),
      ]);
}

double _x(WidgetTester t) => t.getTopLeft(find.byKey(const Key('campo'))).dx;

void main() {
  group('Tremor da senha errada', () {
    testWidgets('balança e volta ao lugar em 360 ms', (t) async {
      await t.pumpWidget(_app(const _Senha()));
      final x0 = _x(t);
      await t.tap(find.text('errar'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 30));
      expect((_x(t) - x0).abs(), greaterThan(1));
      expect((_x(t) - x0).abs(), lessThanOrEqualTo(Tremor.amplitude));
      await t.pump(Tremor.duracao);
      expect(_x(t), x0);
    });

    testWidgets('sem animação quando o sistema pede', (t) async {
      await t.pumpWidget(_app(const _Senha(), semMovimento: true));
      final x0 = _x(t);
      await t.tap(find.text('errar'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 30));
      expect(_x(t), x0);
    });
  });

  group('Esqueleto de carregamento', () {
    testWidgets('respira e se anuncia como "Carregando"', (t) async {
      await t.pumpWidget(_app(const EsqueletoAlertas()));
      final fade = find.descendant(
          of: find.byType(Esqueleto), matching: find.byType(FadeTransition));
      final o1 = t.widget<FadeTransition>(fade.first).opacity.value;
      await t.pump(Esqueleto.meioCiclo ~/ 2);
      final o2 = t.widget<FadeTransition>(fade.first).opacity.value;
      expect(o1, isNot(o2));
      expect(find.bySemanticsLabel('Carregando'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('parado quando o sistema pede menos movimento', (t) async {
      await t.pumpWidget(_app(const EsqueletoEstacoes(), semMovimento: true));
      await t.pumpAndSettle(); // não fica animando para sempre
      final fade = find.descendant(
          of: find.byType(Esqueleto), matching: find.byType(FadeTransition));
      expect(t.widget<FadeTransition>(fade.first).opacity.value, 1);
    });
  });

  test('telas empilhadas usam o voltar preditivo do Android', () {
    expect(
        AquaTheme.claro.pageTransitionsTheme.builders[TargetPlatform.android],
        isA<PredictiveBackPageTransitionsBuilder>());
    expect(
        AquaTheme.escuro.pageTransitionsTheme.builders[TargetPlatform.android],
        isA<PredictiveBackPageTransitionsBuilder>());
  });
}
