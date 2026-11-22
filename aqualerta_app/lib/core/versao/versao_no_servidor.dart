import 'package:flutter/foundation.dart' show debugPrint;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Diz ao servidor qual build este aparelho usa (RPC `registrar_versao_app`,
/// migração 20261123_versao_app.sql). Com isso o banco sabe sozinho quando
/// ninguém mais usa versão antiga e pode desligar o que só elas usavam.
class VersaoNoServidor {
  VersaoNoServidor({
    String? Function()? usuario,
    Future<int> Function()? build,
    Future<void> Function(int build)? enviar,
  })  : _usuario = usuario ?? _usuarioAtual,
        _build = build ?? _buildDoApp,
        _enviar = enviar ?? _enviarAoBanco;

  final String? Function() _usuario;
  final Future<int> Function() _build;
  final Future<void> Function(int) _enviar;
  String? _registradoPara;

  static String? _usuarioAtual() =>
      Supabase.instance.client.auth.currentUser?.id;
  static Future<int> _buildDoApp() async =>
      int.tryParse((await PackageInfo.fromPlatform()).buildNumber) ?? 0;
  static Future<void> _enviarAoBanco(int b) => Supabase.instance.client
      .rpc('registrar_versao_app', params: {'p_build': b});

  /// Uma vez por conta a cada abertura do app. Sem login, nada; sem rede,
  /// tenta de novo na próxima entrada.
  Future<void> registrar() async {
    final uid = _usuario();
    if (uid == null || uid == _registradoPara) return;
    _registradoPara = uid;
    try {
      final b = await _build();
      if (b <= 0) return;
      await _enviar(b);
    } catch (e) {
      _registradoPara = null;
      debugPrint('AquaAlerta: não foi possível registrar a versão ($e)');
    }
  }
}
