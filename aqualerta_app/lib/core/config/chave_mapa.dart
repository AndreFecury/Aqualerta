import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:aqualerta/core/config/mapas.dart';

/// Chave do MapTiler entregue pelo Supabase só para quem está logado
/// (`chave_mapa()`, migração 20261120b_chave_mapa.sql; o valor fica no
/// Vault). Assim a APK publicada no site não leva a chave.
///
/// Guarda a última chave no aparelho para o mapa já abrir certo da próxima
/// vez, mesmo antes da resposta do servidor. Sem chave nenhuma, o app usa
/// os mapas gratuitos.
class ChaveMapa {
  ChaveMapa._();

  static const _preferencia = 'chave_mapa_v1';

  /// Testes trocam isto para não falar com o Supabase.
  static Future<Object?> Function()? buscarParaTeste;

  /// Formato das chaves do MapTiler (letras e números).
  static bool valida(Object? v) =>
      v is String && RegExp(r'^[A-Za-z0-9]{10,64}$').hasMatch(v);

  static Future<void> carregar({SharedPreferences? prefs}) async {
    final p = prefs ?? await SharedPreferences.getInstance();
    final guardada = p.getString(_preferencia);
    if (valida(guardada) && FundoMapa.chaveRemota.value == null) {
      FundoMapa.chaveRemota.value = guardada;
    }
    try {
      final teste = buscarParaTeste;
      final v = teste != null
          ? await teste()
          : await Supabase.instance.client.rpc('chave_mapa');
      if (valida(v)) {
        FundoMapa.chaveRemota.value = v as String;
        await p.setString(_preferencia, v);
      } else if (v == null) {
        // O servidor não tem chave (ou foi removida): mapas gratuitos.
        FundoMapa.chaveRemota.value = null;
        await p.remove(_preferencia);
      }
    } catch (_) {
      // Sem internet: fica com a guardada (ou com os mapas gratuitos).
    }
  }
}
