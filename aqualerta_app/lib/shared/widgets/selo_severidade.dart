import 'package:flutter/material.dart';
import 'package:aqualerta/core/domain/severidade.dart';
import 'package:aqualerta/shared/theme/aqua_colors.dart';
import 'hachura.dart';

/// Nível de risco com amostra de hachura + nome, nunca só cor.
///
/// Substitui o antigo `SeverityBadge` (pílula colorida) nas telas da v3.
class SeloSeveridade extends StatelessWidget {
  const SeloSeveridade({
    required this.severidade,
    this.mostrarAcao = false,
    this.grande = false,
    super.key,
  });

  final Severidade severidade;

  /// Mostra a ação ("Prepare-se") em vez de só o nome do nível.
  final bool mostrarAcao;
  final bool grande;

  @override
  Widget build(BuildContext context) {
    final cores = AquaColors.of(context);
    final textos = Theme.of(context).textTheme;
    final texto = mostrarAcao ? severidade.acao : 'Risco ${severidade.rotulo.toLowerCase()}';
    final estilo = (grande ? textos.titleMedium : textos.labelSmall)!
        .copyWith(color: cores.textoDe(severidade), fontWeight: FontWeight.w700);

    return Semantics(
      label: 'Risco ${severidade.rotulo.toLowerCase()}: ${severidade.acao}',
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AmostraHachura(severidade: severidade, tamanho: grande ? 22 : 18),
          SizedBox(width: grande ? 10 : 8),
          Flexible(child: Text(texto, style: estilo)),
        ],
      ),
    );
  }
}
