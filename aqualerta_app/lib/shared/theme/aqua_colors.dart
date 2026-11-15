import 'package:flutter/material.dart';
import 'package:aqualerta/core/domain/severidade.dart';

/// Cores da v3 ("a régua sobre a carta").
///
/// Use sempre pelo tema: `AquaColors.of(context).canal`. Assim a mesma tela
/// funciona no modo claro e no modo escuro ("noite no rio").
@immutable
class AquaColors extends ThemeExtension<AquaColors> {
  const AquaColors({
    required this.fundo,
    required this.papel,
    required this.tinta,
    required this.tinta2,
    required this.canal,
    required this.sobreCanal,
    required this.aguaRasa,
    required this.aguaFunda,
    required this.contorno,
    required this.barro,
    required this.aguaBarrenta,
    required this.rua,
    required this.linha,
    required this.sombra,
    required this.risco,
    required this.textoRisco,
  });

  /// Fundo das telas e terra firme no mapa.
  final Color fundo;

  /// Folhas, barras e réguas.
  final Color papel;

  /// Texto principal (cor de chá escuro do Rio Negro no modo claro).
  final Color tinta;

  /// Texto secundário: legendas, fonte e hora dos dados.
  final Color tinta2;

  /// Botões e links.
  final Color canal;

  /// Texto e ícones sobre [canal].
  final Color sobreCanal;

  final Color aguaRasa;
  final Color aguaFunda;

  /// Margens tracejadas dos rios no mapa.
  final Color contorno;

  /// Marcas menores da régua e o Solimões (decoração apenas, nunca texto).
  final Color barro;
  final Color aguaBarrenta;
  final Color rua;

  /// Divisórias e bordas finas.
  final Color linha;
  final Color sombra;

  /// Cor de cada nível de risco (marcas, hachuras, contornos).
  final Map<Severidade, Color> risco;

  /// Cor de texto de cada nível, com contraste suficiente sobre [fundo] e [papel].
  final Map<Severidade, Color> textoRisco;

  Color corDe(Severidade s) => risco[s]!;
  Color textoDe(Severidade s) => textoRisco[s]!;

  static AquaColors of(BuildContext context) =>
      Theme.of(context).extension<AquaColors>()!;

  static const claro = AquaColors(
    fundo: Color(0xFFEDF0EA),
    papel: Color(0xFFFBFCF8),
    tinta: Color(0xFF231A14),
    tinta2: Color(0xFF5A4E44),
    canal: Color(0xFF0E5C6B),
    sobreCanal: Color(0xFFFFFFFF),
    aguaRasa: Color(0xFFCFE3EA),
    aguaFunda: Color(0xFF9CC6D6),
    contorno: Color(0xFF6E9BAB),
    barro: Color(0xFFB98A4E),
    aguaBarrenta: Color(0xFFE6D3AE),
    rua: Color(0xFFDCE1D6),
    linha: Color(0x29231A14),
    sombra: Color(0x1F231A14),
    risco: {
      Severidade.baixo: Color(0xFF2E7D4F),
      Severidade.medio: Color(0xFFE3A600),
      Severidade.alto: Color(0xFFE0661B),
      Severidade.critico: Color(0xFFC1121F),
    },
    textoRisco: {
      Severidade.baixo: Color(0xFF1F5E3A),
      Severidade.medio: Color(0xFF6B4E00),
      Severidade.alto: Color(0xFF8A3300),
      Severidade.critico: Color(0xFFA30F1A),
    },
  );

  static const escuro = AquaColors(
    fundo: Color(0xFF1B1510),
    papel: Color(0xFF261E17),
    tinta: Color(0xFFF1ECE4),
    tinta2: Color(0xFFBCB0A2),
    canal: Color(0xFF7FCFDE),
    sobreCanal: Color(0xFF10262B),
    aguaRasa: Color(0xFF1F3A44),
    aguaFunda: Color(0xFF2A5563),
    contorno: Color(0xFF4E8798),
    barro: Color(0xFFA07C4C),
    aguaBarrenta: Color(0xFF4A3A22),
    rua: Color(0xFF2C231B),
    linha: Color(0x29F1ECE4),
    sombra: Color(0x80000000),
    risco: {
      Severidade.baixo: Color(0xFF3FAF6E),
      Severidade.medio: Color(0xFFF2B705),
      Severidade.alto: Color(0xFFF07A2E),
      Severidade.critico: Color(0xFFE0233F),
    },
    textoRisco: {
      Severidade.baixo: Color(0xFF8AE6A8),
      Severidade.medio: Color(0xFFFFD75E),
      Severidade.alto: Color(0xFFFFB27A),
      Severidade.critico: Color(0xFFFF8A99),
    },
  );

  @override
  AquaColors copyWith({
    Color? fundo,
    Color? papel,
    Color? tinta,
    Color? tinta2,
    Color? canal,
    Color? sobreCanal,
    Color? aguaRasa,
    Color? aguaFunda,
    Color? contorno,
    Color? barro,
    Color? aguaBarrenta,
    Color? rua,
    Color? linha,
    Color? sombra,
    Map<Severidade, Color>? risco,
    Map<Severidade, Color>? textoRisco,
  }) {
    return AquaColors(
      fundo: fundo ?? this.fundo,
      papel: papel ?? this.papel,
      tinta: tinta ?? this.tinta,
      tinta2: tinta2 ?? this.tinta2,
      canal: canal ?? this.canal,
      sobreCanal: sobreCanal ?? this.sobreCanal,
      aguaRasa: aguaRasa ?? this.aguaRasa,
      aguaFunda: aguaFunda ?? this.aguaFunda,
      contorno: contorno ?? this.contorno,
      barro: barro ?? this.barro,
      aguaBarrenta: aguaBarrenta ?? this.aguaBarrenta,
      rua: rua ?? this.rua,
      linha: linha ?? this.linha,
      sombra: sombra ?? this.sombra,
      risco: risco ?? this.risco,
      textoRisco: textoRisco ?? this.textoRisco,
    );
  }

  @override
  AquaColors lerp(ThemeExtension<AquaColors>? other, double t) {
    if (other is! AquaColors) return this;
    Color l(Color a, Color b) => Color.lerp(a, b, t)!;
    Map<Severidade, Color> lm(Map<Severidade, Color> a, Map<Severidade, Color> b) =>
        {for (final s in Severidade.values) s: l(a[s]!, b[s]!)};
    return AquaColors(
      fundo: l(fundo, other.fundo),
      papel: l(papel, other.papel),
      tinta: l(tinta, other.tinta),
      tinta2: l(tinta2, other.tinta2),
      canal: l(canal, other.canal),
      sobreCanal: l(sobreCanal, other.sobreCanal),
      aguaRasa: l(aguaRasa, other.aguaRasa),
      aguaFunda: l(aguaFunda, other.aguaFunda),
      contorno: l(contorno, other.contorno),
      barro: l(barro, other.barro),
      aguaBarrenta: l(aguaBarrenta, other.aguaBarrenta),
      rua: l(rua, other.rua),
      linha: l(linha, other.linha),
      sombra: l(sombra, other.sombra),
      risco: lm(risco, other.risco),
      textoRisco: lm(textoRisco, other.textoRisco),
    );
  }
}
