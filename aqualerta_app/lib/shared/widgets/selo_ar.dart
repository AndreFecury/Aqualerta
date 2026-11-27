import 'package:flutter/material.dart';
import 'package:aqualerta/core/domain/ar.dart';
import 'package:aqualerta/shared/theme/aqua_colors.dart';

/// Selo da qualidade do ar: quadrado na cor do nível (paleta própria do ar,
/// diferente da de cheia) e o nome do nível. O texto fica na cor da tinta,
/// para o contraste não depender da cor do nível.
class SeloAr extends StatelessWidget {
  const SeloAr(
      {required this.nivel,
      this.indice,
      this.grande = false,
      this.estimativa = false,
      this.sensor = false,
      super.key});
  final NivelAr nivel;
  final int? indice;
  final bool grande;

  /// Valor só do modelo: o leitor de tela anuncia "Estimativa do modelo: …".
  final bool estimativa;

  /// Valor medido por um sensor (média de 3 h): o leitor de tela anuncia
  /// "Medição do sensor: …".
  final bool sensor;

  @override
  Widget build(BuildContext context) {
    final c = AquaColors.of(context);
    final t = Theme.of(context).textTheme;
    final texto = 'Ar ${nivel.nome.toLowerCase()}'
        '${indice == null ? '' : ' · índice $indice'}';
    final lado = grande ? 22.0 : 18.0;
    return Semantics(
      label:
          '${estimativa ? 'Estimativa do modelo: qualidade' : sensor ? 'Medição do sensor: qualidade' : 'Qualidade'} '
          'do ar ${nivel.nome.toLowerCase()}'
          '${indice == null ? '' : ', índice $indice'}',
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: lado,
            height: lado,
            decoration: BoxDecoration(
              color: nivel.cor(Theme.of(context).brightness),
              borderRadius: BorderRadius.circular(lado / 2),
              border: Border.all(color: c.tinta.withValues(alpha: 0.35)),
            ),
          ),
          SizedBox(width: grande ? 10 : 8),
          Flexible(
            child: Text(texto,
                style: (grande ? t.titleMedium : t.labelSmall)!
                    .copyWith(color: c.tinta, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }
}
