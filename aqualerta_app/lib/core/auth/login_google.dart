import 'package:google_sign_in/google_sign_in.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Entrar com a conta Google (Android): o seletor de contas do próprio
/// celular entrega um ID token do Google, que o Supabase troca por uma
/// sessão do AquaAlerta (`signInWithIdToken`). Sem navegador, sem senha.
///
/// Precisa do ID do cliente OAuth do tipo "Aplicativo da Web" do Google
/// Cloud (o mesmo cadastrado no provedor Google do Supabase). Não é segredo:
/// vem no build com `--dart-define=GOOGLE_WEB_CLIENT_ID=...`. Sem ele, o
/// botão do Google não aparece e o login por e-mail segue igual.
class LoginGoogle {
  LoginGoogle._();

  static const webClientId = String.fromEnvironment('GOOGLE_WEB_CLIENT_ID');

  /// Testes trocam isto para não falar com o Google nem com o Supabase.
  static bool Function()? disponivelParaTeste;
  static Future<bool> Function()? entrarParaTeste;

  static bool get disponivel =>
      disponivelParaTeste?.call() ?? webClientId.isNotEmpty;

  static bool _iniciado = false;

  static Future<void> _iniciar() async {
    if (_iniciado) return;
    await GoogleSignIn.instance.initialize(serverClientId: webClientId);
    _iniciado = true;
  }

  /// Abre o seletor de contas do Google e entra no AquaAlerta.
  /// Devolve `false` se a pessoa desistiu (fechou o seletor); lança erro
  /// se algo falhou.
  static Future<bool> entrar() async {
    final teste = entrarParaTeste;
    if (teste != null) return teste();
    await _iniciar();
    final GoogleSignInAccount conta;
    try {
      conta =
          await GoogleSignIn.instance.authenticate(scopeHint: const ['email']);
    } on GoogleSignInException catch (e) {
      if (e.code == GoogleSignInExceptionCode.canceled) return false;
      rethrow;
    }
    final idToken = conta.authentication.idToken;
    if (idToken == null) {
      throw const AuthException('Google não devolveu o ID token');
    }
    await Supabase.instance.client.auth
        .signInWithIdToken(provider: OAuthProvider.google, idToken: idToken);
    return true;
  }

  /// Ao sair do app, esquece também a conta escolhida, para o seletor
  /// aparecer de novo no próximo login (útil em celular compartilhado).
  static Future<void> sair() async {
    if (!_iniciado) return;
    try {
      await GoogleSignIn.instance.signOut();
    } catch (_) {
      // Sair do AquaAlerta não pode falhar por causa do Google.
    }
  }
}
