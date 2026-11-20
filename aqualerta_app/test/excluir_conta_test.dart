import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aqualerta/core/auth/conta.dart';
import 'package:aqualerta/core/config/mapas.dart';
import 'package:aqualerta/features/settings/presentation/screens/perfil_screen.dart';

import 'telas_v3_test.dart' show montar;

Future<void> _abrirConfirmacao(WidgetTester t) async {
  await montar(t, const PerfilScreen());
  final botao = find.byKey(const Key('excluir-conta'));
  await t.scrollUntilVisible(botao, 200);
  // Rola até o fim: o botão fica longe da borda de baixo.
  await t.drag(find.byType(ListView).first, const Offset(0, -400));
  await t.pumpAndSettle();
  await t.tap(botao);
  await t.pumpAndSettle();
}

void main() {
  setUp(() => FundoMapa.desligado = true);
  tearDown(() => Conta.excluirParaTeste = null);

  testWidgets('Perfil tem "Excluir conta" e pede confirmação antes', (t) async {
    var chamadas = 0;
    Conta.excluirParaTeste = () async => chamadas++;
    await _abrirConfirmacao(t);
    expect(find.text('Excluir sua conta?'), findsOneWidget);
    expect(find.textContaining('não pode ser desfeito'), findsOneWidget);
    expect(chamadas, 0, reason: 'nada é apagado só por abrir o aviso');
  });

  testWidgets('cancelar não apaga nada', (t) async {
    var chamadas = 0;
    Conta.excluirParaTeste = () async => chamadas++;
    await _abrirConfirmacao(t);
    await t.tap(find.text('Cancelar'));
    await t.pumpAndSettle();
    expect(chamadas, 0);
    expect(find.text('Excluir sua conta?'), findsNothing);
  });

  testWidgets('confirmar exclui e avisa', (t) async {
    var chamadas = 0;
    Conta.excluirParaTeste = () async => chamadas++;
    await _abrirConfirmacao(t);
    await t.tap(find.byKey(const Key('confirmar-exclusao')));
    await t.pumpAndSettle();
    expect(chamadas, 1);
    expect(find.textContaining('Conta excluída'), findsOneWidget);
  });

  testWidgets('falha na exclusão mostra erro', (t) async {
    Conta.excluirParaTeste = () async => throw Exception('rede');
    await _abrirConfirmacao(t);
    await t.tap(find.byKey(const Key('confirmar-exclusao')));
    await t.pumpAndSettle();
    expect(find.textContaining('Não foi possível excluir'), findsOneWidget);
  });
}
