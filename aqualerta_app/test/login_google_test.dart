import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aqualerta/app/screens/login_screen.dart';
import 'package:aqualerta/core/auth/login_google.dart';
import 'package:aqualerta/shared/theme/aqua_theme.dart';

Future<void> _montar(WidgetTester t) async {
  await t.pumpWidget(
      MaterialApp(theme: AquaTheme.claro, home: const LoginScreen()));
  await t.pump();
}

void main() {
  tearDown(() {
    LoginGoogle.disponivelParaTeste = null;
    LoginGoogle.entrarParaTeste = null;
  });

  testWidgets('sem o ID do cliente no build, o botão do Google não aparece',
      (t) async {
    LoginGoogle.disponivelParaTeste = () => false;
    await _montar(t);
    expect(find.byKey(const Key('entrar-google')), findsNothing);
    expect(find.text('ou com e-mail'), findsNothing);
    expect(find.text('Entrar'), findsOneWidget);
  });

  testWidgets('com o cliente configurado, o Google vem antes do e-mail',
      (t) async {
    LoginGoogle.disponivelParaTeste = () => true;
    await _montar(t);
    final google = find.byKey(const Key('entrar-google'));
    expect(google, findsOneWidget);
    expect(find.text('Continuar com o Google'), findsOneWidget);
    expect(
        t.getTopLeft(google).dy,
        lessThan(
            t.getTopLeft(find.widgetWithText(TextFormField, 'E-mail')).dy));
    // Área de toque confortável.
    expect(t.getSize(google).height, greaterThanOrEqualTo(48));
  });

  testWidgets('tocar no Google chama o login e desistir não mostra erro',
      (t) async {
    var chamadas = 0;
    LoginGoogle.disponivelParaTeste = () => true;
    LoginGoogle.entrarParaTeste = () async {
      chamadas++;
      return false; // fechou o seletor de contas
    };
    await _montar(t);
    await t.tap(find.byKey(const Key('entrar-google')));
    await t.pumpAndSettle();
    expect(chamadas, 1);
    expect(find.textContaining('Não foi possível'), findsNothing);
  });

  testWidgets('falha no Google mostra mensagem e sugere o e-mail', (t) async {
    LoginGoogle.disponivelParaTeste = () => true;
    LoginGoogle.entrarParaTeste = () async => throw Exception('rede');
    await _montar(t);
    await t.tap(find.byKey(const Key('entrar-google')));
    await t.pumpAndSettle();
    expect(find.textContaining('Não foi possível entrar com o Google'),
        findsOneWidget);
    // Botão volta a ficar disponível para tentar de novo.
    final botao =
        t.widget<OutlinedButton>(find.byKey(const Key('entrar-google')));
    expect(botao.onPressed, isNotNull);
  });
}
