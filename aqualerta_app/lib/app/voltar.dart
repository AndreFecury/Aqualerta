/// Botão voltar do Android dentro das abas: em vez de fechar o app de cara,
/// primeiro desfaz o que estiver aberto na tela (busca, cartão expandido,
/// região escolhida). As telas registram aqui o que sabem desfazer; o
/// último registrado é perguntado primeiro.
class Voltar {
  Voltar._();

  static final _tratadores = <bool Function()>[];

  static void registrar(bool Function() tratador) => _tratadores.add(tratador);

  static void remover(bool Function() tratador) => _tratadores.remove(tratador);

  /// Devolve `true` se alguma tela desfez algo (e o voltar para aqui).
  static bool tratar() {
    for (final t in _tratadores.reversed.toList()) {
      if (t()) return true;
    }
    return false;
  }
}
