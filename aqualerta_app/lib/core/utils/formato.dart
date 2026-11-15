/// Formata metros no padrão brasileiro: 27.3 → "27,3"; 27.0 → "27".
String formatarMetros(double valor, {int casas = 1}) {
  final arredondado = double.parse(valor.toStringAsFixed(casas));
  if (arredondado == arredondado.roundToDouble()) {
    return arredondado.toStringAsFixed(0);
  }
  return arredondado.toStringAsFixed(casas).replaceAll('.', ',');
}

/// Diferença em linguagem simples: 0.3 → "30 cm"; 1.7 → "1,7 m".
String formatarDiferenca(double metros) {
  final m = metros.abs();
  if (m < 1) return '${(m * 100).round()} cm';
  return '${formatarMetros(m)} m';
}
