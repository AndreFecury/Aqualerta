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

/// Há quanto tempo, em linguagem simples: "agora", "há 12 min", "há 5 h",
/// "ontem", "há 3 dias".
String formatarHaQuanto(DateTime quando, {DateTime? agora}) {
  final dif = (agora ?? DateTime.now()).difference(quando);
  if (dif.inMinutes < 1) return 'agora';
  if (dif.inMinutes < 60) return 'há ${dif.inMinutes} min';
  if (dif.inHours < 24) return 'há ${dif.inHours} h';
  if (dif.inDays == 1) return 'ontem';
  return 'há ${dif.inDays} dias';
}

/// Hora no formato do Brasil: "hoje, 15:28", "ontem, 09:05" ou "12/11, 18:40".
String formatarDataHora(DateTime quando, {DateTime? agora}) {
  final local = quando.toLocal();
  final hoje = agora ?? DateTime.now();
  String dois(int n) => n.toString().padLeft(2, '0');
  final hora = '${dois(local.hour)}:${dois(local.minute)}';
  final diaHoje = DateTime(hoje.year, hoje.month, hoje.day);
  final dia = DateTime(local.year, local.month, local.day);
  final dias = diaHoje.difference(dia).inDays;
  if (dias == 0) return 'hoje, $hora';
  if (dias == 1) return 'ontem, $hora';
  return '${dois(local.day)}/${dois(local.month)}, $hora';
}
