import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:aqualerta/core/auth/login_google.dart';
import 'package:aqualerta/core/notificacoes/avisos_service.dart';

/// Exclusão da própria conta (LGPD e Play Store). O servidor apaga o usuário
/// e, junto, perfil, token de notificação e regiões seguidas
/// (`excluir_minha_conta()`, migração 20261120_excluir_conta.sql).
class Conta {
  Conta._();

  /// Testes trocam isto para não falar com o Supabase.
  static Future<void> Function()? excluirParaTeste;

  static Future<void> excluir() async {
    final teste = excluirParaTeste;
    if (teste != null) return teste();
    final c = Supabase.instance.client;
    await AvisosService.instancia.esquecerAparelho();
    await c.rpc('excluir_minha_conta'); // se falhar, nada foi apagado
    await LoginGoogle.sair();
    try {
      await c.auth.signOut();
    } catch (_) {
      // A sessão já não vale no servidor: limpa só no aparelho.
      await c.auth.signOut(scope: SignOutScope.local);
    }
  }
}
