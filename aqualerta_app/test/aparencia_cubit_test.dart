import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:aqualerta/features/settings/presentation/cubit/aparencia_cubit.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('por padrão segue o tamanho do celular e o tema do sistema', () async {
    final cubit = AparenciaCubit(await SharedPreferences.getInstance());
    expect(cubit.state.usarTamanhoDoCelular, isTrue);
    expect(cubit.state.tema, ThemeMode.system);
    expect(cubit.state.escalaFinal(const TextScaler.linear(1.3)).scale(10),
        closeTo(13, 0.01));
  });

  test('escala escolhida no app vale mesmo com o celular em outro tamanho',
      () async {
    final cubit = AparenciaCubit(await SharedPreferences.getInstance());
    await cubit.definirEscala(EscalaTexto.grande);
    expect(cubit.state.escalaFinal(const TextScaler.linear(1.0)).scale(10),
        closeTo(11.5, 0.01));
  });

  test('limita escalas extremas para não quebrar o layout', () async {
    final cubit = AparenciaCubit(await SharedPreferences.getInstance());
    expect(cubit.state.escalaFinal(const TextScaler.linear(3)).scale(10),
        closeTo(16, 0.01));
  });

  test('preferências continuam salvas ao reabrir o app', () async {
    final prefs = await SharedPreferences.getInstance();
    final cubit = AparenciaCubit(prefs);
    await cubit.definirEscala(EscalaTexto.muitoGrande);
    await cubit.definirTema(ThemeMode.dark);

    final reaberto = AparenciaCubit(prefs);
    expect(reaberto.state.escala, EscalaTexto.muitoGrande);
    expect(reaberto.state.usarTamanhoDoCelular, isFalse);
    expect(reaberto.state.tema, ThemeMode.dark);
  });
}
