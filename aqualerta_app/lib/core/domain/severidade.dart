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

/// Cotas oficiais de uma estação, em metros, publicadas pelo SGB
/// (Serviço Geológico do Brasil) nos Sistemas de Alerta Hidrológico.
///
/// - [alerta]: possibilidade elevada de inundação;
/// - [inundacao]: o rio começa a atingir as primeiras casas;
/// - [severa]: inundação severa. Nem toda estação tem essa cota.
class CotasEstacao {
  const CotasEstacao({
    required this.alerta,
    required this.inundacao,
    this.severa,
  }) : assert(alerta <= inundacao && (severa == null || inundacao <= severa));

  final double alerta;
  final double inundacao;
  final double? severa;

  /// A cota mais alta que a estação tem.
  double get topo => severa ?? inundacao;
}

/// Regra única de severidade do app: o nível do rio comparado às cotas da
/// estação. O banco gera os alertas com a mesma regra, então o alerta e a
/// régua nunca se contradizem.
///
/// - abaixo da cota de alerta: [Severidade.baixo]
/// - da cota de alerta até antes da inundação: [Severidade.medio]
/// - da cota de inundação até antes da severa: [Severidade.alto]
/// - a partir da cota de inundação severa: [Severidade.critico]
Severidade severidadePorCota(double nivel, CotasEstacao cotas) {
  final severa = cotas.severa;
  if (severa != null && nivel >= severa) return Severidade.critico;
  if (nivel >= cotas.inundacao) return Severidade.alto;
  if (nivel >= cotas.alerta) return Severidade.medio;
  return Severidade.baixo;
}
