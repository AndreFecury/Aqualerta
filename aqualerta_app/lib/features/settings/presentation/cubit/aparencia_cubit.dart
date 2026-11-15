import 'package:equatable/equatable.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Tamanho do texto escolhido no Perfil (A−, A, A+, A++).
enum EscalaTexto {
  pequeno(0.9, 'Pequeno'),
  normal(1.0, 'Normal'),
  grande(1.15, 'Grande'),
  muitoGrande(1.3, 'Muito grande');

  const EscalaTexto(this.fator, this.rotulo);
  final double fator;
  final String rotulo;
}

class Aparencia extends Equatable {
  const Aparencia({
    this.usarTamanhoDoCelular = true,
    this.escala = EscalaTexto.normal,
    this.tema = ThemeMode.system,
  });

  /// Padrão: segue a configuração de acessibilidade do aparelho.
  final bool usarTamanhoDoCelular;

  /// Usada só quando [usarTamanhoDoCelular] está desligado.
  final EscalaTexto escala;
  final ThemeMode tema;

  /// Limites para o layout não quebrar com letra muito grande ou muito pequena.
  static const escalaMinima = 0.85;
  static const escalaMaxima = 1.6;

  /// Escala final do texto a partir da escala do sistema.
  TextScaler escalaFinal(TextScaler doSistema) {
    final base = usarTamanhoDoCelular ? doSistema : TextScaler.linear(escala.fator);
    return base.clamp(minScaleFactor: escalaMinima, maxScaleFactor: escalaMaxima);
  }

  Aparencia copyWith({bool? usarTamanhoDoCelular, EscalaTexto? escala, ThemeMode? tema}) => Aparencia(
        usarTamanhoDoCelular: usarTamanhoDoCelular ?? this.usarTamanhoDoCelular,
        escala: escala ?? this.escala,
        tema: tema ?? this.tema,
      );

  @override
  List<Object?> get props => [usarTamanhoDoCelular, escala, tema];
}

/// Guarda tamanho do texto e tema no aparelho (SharedPreferences).
class AparenciaCubit extends Cubit<Aparencia> {
  AparenciaCubit(this._prefs) : super(_ler(_prefs));

  final SharedPreferences _prefs;

  static const _kDoCelular = 'aparencia.usarTamanhoDoCelular';
  static const _kEscala = 'aparencia.escala';
  static const _kTema = 'aparencia.tema';

  static Aparencia _ler(SharedPreferences p) {
    T porNome<T extends Enum>(List<T> valores, String? nome, T padrao) =>
        valores.where((v) => v.name == nome).firstOrNull ?? padrao;
    return Aparencia(
      usarTamanhoDoCelular: p.getBool(_kDoCelular) ?? true,
      escala: porNome(EscalaTexto.values, p.getString(_kEscala), EscalaTexto.normal),
      tema: porNome(ThemeMode.values, p.getString(_kTema), ThemeMode.system),
    );
  }

  Future<void> usarTamanhoDoCelular(bool usar) async {
    emit(state.copyWith(usarTamanhoDoCelular: usar));
    await _prefs.setBool(_kDoCelular, usar);
  }

  Future<void> definirEscala(EscalaTexto escala) async {
    emit(state.copyWith(escala: escala, usarTamanhoDoCelular: false));
    await _prefs.setString(_kEscala, escala.name);
    await _prefs.setBool(_kDoCelular, false);
  }

  Future<void> definirTema(ThemeMode tema) async {
    emit(state.copyWith(tema: tema));
    await _prefs.setString(_kTema, tema.name);
  }
}
