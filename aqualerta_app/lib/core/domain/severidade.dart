/// Níveis de risco do AquaAlerta.
///
/// Os códigos (`LOW`, `MEDIUM`, `HIGH`, `CRITICAL`) são os mesmos gravados
/// no banco (colunas `severity` e `min_severity`).
enum Severidade {
  baixo('LOW', 'Baixo', 'Situação normal'),
  medio('MEDIUM', 'Médio', 'Fique atento'),
  alto('HIGH', 'Alto', 'Prepare-se'),
  critico('CRITICAL', 'Crítico', 'Saia de áreas de risco');

  const Severidade(this.codigo, this.rotulo, this.acao);

  /// Código usado no banco de dados.
  final String codigo;

  /// Nome curto para a interface ("Alto").
  final String rotulo;

  /// O que a pessoa deve fazer, em linguagem simples ("Prepare-se").
  final String acao;

  /// Converte o código do banco. Valores desconhecidos viram [medio],
  /// para nunca esconder um alerta por causa de um dado inesperado.
  static Severidade doCodigo(String? codigo) {
    final c = codigo?.trim().toUpperCase();
    for (final s in Severidade.values) {
      if (s.codigo == c) return s;
    }
    return Severidade.medio;
  }

  bool operator >=(Severidade outra) => index >= outra.index;
}

/// Cotas de uma estação hidrológica da ANA (tabela `hydro_stations`), em metros.
class CotasEstacao {
  const CotasEstacao({
    required this.normal,
    required this.alerta,
    required this.inundacao,
    required this.emergencia,
  }) : assert(normal <= alerta && alerta <= inundacao && inundacao <= emergencia);

  final double normal;
  final double alerta;
  final double inundacao;
  final double emergencia;
}

/// Regra única de severidade do app: calculada pelo nível do rio comparado
/// às cotas da estação. Assim o alerta e a régua nunca se contradizem.
///
/// - abaixo da cota normal: [Severidade.baixo]
/// - da cota normal até antes da cota de alerta: [Severidade.medio]
/// - da cota de alerta até antes da cota de inundação: [Severidade.alto]
/// - a partir da cota de inundação: [Severidade.critico]
Severidade severidadePorCota(double nivel, CotasEstacao cotas) {
  if (nivel >= cotas.inundacao) return Severidade.critico;
  if (nivel >= cotas.alerta) return Severidade.alto;
  if (nivel >= cotas.normal) return Severidade.medio;
  return Severidade.baixo;
}
