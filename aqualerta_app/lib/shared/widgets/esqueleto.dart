import 'package:flutter/material.dart';
import 'package:aqualerta/shared/theme/aqua_colors.dart';

/// Carregamento no formato do conteúdo que vai chegar (como Gmail, YouTube e
/// Play Store): blocos cinza que respiram devagar, em vez de um spinner no
/// meio da tela. A pessoa já vê onde as coisas vão aparecer e a troca para o
/// conteúdo real é suave. Com "remover animações" ligado, fica parado.
class Esqueleto extends StatefulWidget {
  const Esqueleto({required this.child, super.key});
  final Widget child;

  /// Um ciclo completo (claro → escuro → claro) leva o dobro disto.
  static const meioCiclo = Duration(milliseconds: 900);

  @override
  State<Esqueleto> createState() => _EsqueletoState();
}

class _EsqueletoState extends State<Esqueleto>
    with SingleTickerProviderStateMixin {
  late final _pulso =
      AnimationController(vsync: this, duration: Esqueleto.meioCiclo);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _pulso
        ..stop()
        ..value = 1;
    } else if (!_pulso.isAnimating) {
      _pulso.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _pulso.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(
        label: 'Carregando',
        child: ExcludeSemantics(
          child: FadeTransition(
            opacity: Tween<double>(begin: 0.45, end: 1)
                .chain(CurveTween(curve: Curves.easeInOut))
                .animate(_pulso),
            child: widget.child,
          ),
        ),
      );
}

/// Um bloco do esqueleto (linha de texto, selo, etc.).
class BlocoEsqueleto extends StatelessWidget {
  const BlocoEsqueleto(
      {this.largura = double.infinity,
      this.altura = 14,
      this.fator,
      super.key});
  final double largura;
  final double altura;

  /// Fração da largura disponível (em vez de [largura]).
  final double? fator;

  @override
  Widget build(BuildContext context) {
    final bloco = Container(
      width: fator == null ? largura : null,
      height: altura,
      decoration: BoxDecoration(
        color: AquaColors.of(context).linha,
        borderRadius: BorderRadius.circular(altura / 2.5),
      ),
    );
    return fator == null
        ? bloco
        : FractionallySizedBox(
            widthFactor: fator, alignment: Alignment.centerLeft, child: bloco);
  }
}

/// Esqueleto da lista de alertas: mesmas medidas da linha real.
class EsqueletoAlertas extends StatelessWidget {
  const EsqueletoAlertas({this.linhas = 4, super.key});
  final int linhas;

  @override
  Widget build(BuildContext context) {
    final c = AquaColors.of(context);
    return Esqueleto(
      child: Column(
        children: [
          for (var i = 0; i < linhas; i++)
            Container(
              padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
              decoration: BoxDecoration(
                  border: Border(bottom: BorderSide(color: c.linha))),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const BlocoEsqueleto(largura: 96, altura: 22),
                  const SizedBox(height: 10),
                  BlocoEsqueleto(fator: i.isEven ? 0.78 : 0.64, altura: 16),
                  const SizedBox(height: 8),
                  const BlocoEsqueleto(fator: 0.4),
                  const SizedBox(height: 6),
                  const BlocoEsqueleto(fator: 0.28, altura: 12),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Esqueleto das estações de rio.
class EsqueletoEstacoes extends StatelessWidget {
  const EsqueletoEstacoes({this.linhas = 3, super.key});
  final int linhas;

  @override
  Widget build(BuildContext context) {
    final c = AquaColors.of(context);
    return Esqueleto(
      child: Column(
        children: [
          for (var i = 0; i < linhas; i++)
            Container(
              padding: const EdgeInsets.symmetric(vertical: 16),
              decoration: BoxDecoration(
                  border: Border(bottom: BorderSide(color: c.linha))),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  BlocoEsqueleto(fator: i.isEven ? 0.5 : 0.42, altura: 16),
                  const SizedBox(height: 8),
                  const BlocoEsqueleto(fator: 0.3),
                  const SizedBox(height: 14),
                  const BlocoEsqueleto(altura: 28),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
