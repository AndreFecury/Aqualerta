import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:aqualerta/core/domain/severidade.dart';

class PreferenciasNotificacao extends Equatable {
  const PreferenciasNotificacao({
    this.ativas = true,
    this.som = true,
    this.severidadeMinima = Severidade.medio,
    this.ar = true,
  });

  final bool ativas;

  /// Avisos de qualidade do ar (fumaça/poluição). Os de cheia e chuva não
  /// dependem disto.
  final bool ar;

  /// Som nos níveis Alto e Crítico.
  final bool som;
  final Severidade severidadeMinima;

  bool deveAvisar(Severidade s) => ativas && s >= severidadeMinima;

  PreferenciasNotificacao copyWith(
          {bool? ativas, bool? som, Severidade? severidadeMinima, bool? ar}) =>
      PreferenciasNotificacao(
        ativas: ativas ?? this.ativas,
        som: som ?? this.som,
        severidadeMinima: severidadeMinima ?? this.severidadeMinima,
        ar: ar ?? this.ar,
      );

  Map<String, Object> paraBanco() => {
        'push': ativas,
        'sound': som,
        'min_severity': severidadeMinima.codigo,
        'ar': ar,
      };

  @override
  List<Object?> get props => [ativas, som, severidadeMinima, ar];
}

/// Preferências de aviso. Ficam salvas no aparelho e, quando há usuário
/// logado, também em `user_profiles.notification_preferences`.
class NotificacoesCubit extends Cubit<PreferenciasNotificacao> {
  NotificacoesCubit(this._prefs, {SupabaseClient? cliente})
      : _cliente = cliente,
        super(_ler(_prefs));

  final SharedPreferences _prefs;
  final SupabaseClient? _cliente;

  static const _kAtivas = 'avisos.ativos';
  static const _kSom = 'avisos.som';
  static const _kMinima = 'avisos.minima';
  static const _kAr = 'avisos.ar';

  static PreferenciasNotificacao _ler(SharedPreferences p) =>
      PreferenciasNotificacao(
        ativas: p.getBool(_kAtivas) ?? true,
        som: p.getBool(_kSom) ?? true,
        severidadeMinima: Severidade.doCodigo(
            p.getString(_kMinima) ?? Severidade.medio.codigo),
        ar: p.getBool(_kAr) ?? true,
      );

  Future<void> definirAtivas(bool v) => _salvar(state.copyWith(ativas: v));
  Future<void> definirSom(bool v) => _salvar(state.copyWith(som: v));
  Future<void> definirAr(bool v) => _salvar(state.copyWith(ar: v));
  Future<void> definirMinima(Severidade s) =>
      _salvar(state.copyWith(severidadeMinima: s));

  Future<void> _salvar(PreferenciasNotificacao novo) async {
    emit(novo);
    await _prefs.setBool(_kAtivas, novo.ativas);
    await _prefs.setBool(_kSom, novo.som);
    await _prefs.setString(_kMinima, novo.severidadeMinima.codigo);
    await _prefs.setBool(_kAr, novo.ar);
    final c = _cliente;
    final uid = c?.auth.currentUser?.id;
    if (c == null || uid == null) return;
    try {
      await c
          .from('user_profiles')
          .update({'notification_preferences': novo.paraBanco()}).eq('id', uid);
    } catch (_) {
      // Sem internet: fica salvo no aparelho e vai na próxima alteração.
    }
  }
}
