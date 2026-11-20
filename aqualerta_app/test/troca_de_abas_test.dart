import 'package:animations/animations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aqualerta/app/router.dart' show TrocaDeAbas;

/// Aba de teste com um contador: serve para ver se o estado sobrevive.
class _Aba extends StatefulWidget {
  const _Aba(this.nome);
  final String nome;
  @override
  State<_Aba> createState() => _AbaEstado();
}

class _AbaEstado extends State<_Aba> {
  int toques = 0;
  @override
  Widget build(BuildContext context) => Center(
        child: TextButton(
          onPressed: () => setState(() => toques++),
          child: Text('${widget.nome} $toques'),
        ),
      );
}

Future<void> _montar(WidgetTester t, int indice, {bool semMovimento = false}) =>
    t.pumpWidget(MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: semMovimento),
        child: TrocaDeAbas(
          indice: indice,
          filhos: const [_Aba('mapa'), _Aba('alertas')],
        ),
      ),
    ));

void main() {
  testWidgets('fade through: a antiga sai, a nova entra, em 350 ms', (t) async {
    await _montar(t, 0);
    expect(find.text('mapa 0'), findsOneWidget);
    await _montar(t, 1);
    await t.pump(const Duration(milliseconds: 50));
    // No começo da troca as duas ainda estão desenhadas (a antiga sumindo).
    expect(find.text('mapa 0'), findsOneWidget);
    expect(find.text('alertas 0'), findsOneWidget);
    await t.pump(const Duration(milliseconds: 320));
    await t.pump();
    expect(find.text('alertas 0'), findsOneWidget);
    expect(find.text('mapa 0'), findsNothing,
        reason: 'a antiga fica fora da tela');
  });

  testWidgets('cada aba guarda o próprio estado ao trocar', (t) async {
    await _montar(t, 0);
    await t.tap(find.text('mapa 0'));
    await t.pump();
    await _montar(t, 1);
    await t.pumpAndSettle();
    await _montar(t, 0);
    await t.pumpAndSettle();
    expect(find.text('mapa 1'), findsOneWidget);
  });

  testWidgets('a aba de trás não recebe toques durante a troca', (t) async {
    await _montar(t, 0);
    await _montar(t, 1);
    await t.pump(const Duration(milliseconds: 50));
    await t.tap(find.text('mapa 0'), warnIfMissed: false);
    await t.pumpAndSettle();
    await _montar(t, 0);
    await t.pumpAndSettle();
    expect(find.text('mapa 0'), findsOneWidget);
  });

  testWidgets('com "reduzir animações", troca na hora', (t) async {
    await _montar(t, 0, semMovimento: true);
    await _montar(t, 1, semMovimento: true);
    await t.pump();
    expect(find.text('alertas 0'), findsOneWidget);
    expect(find.text('mapa 0'), findsNothing);
  });
}
