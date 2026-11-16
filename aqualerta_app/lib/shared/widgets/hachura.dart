import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:aqualerta/core/domain/severidade.dart';
import 'package:aqualerta/shared/theme/aqua_colors.dart';

/// Desenha a hachura de cada nível de risco, como numa carta náutica.
///
/// O padrão muda com o nível, não só a cor, para quem não distingue cores:
/// Baixo = contorno tracejado · Médio = pontos · Alto = listras · Crítico = xadrez.
class HachuraPainter extends CustomPainter {
  HachuraPainter({
    required this.severidade,
    required this.cores,
    this.raio = 2,
    this.forma,
    this.espessuraBorda = 2,
  });

  final Severidade severidade;
  final AquaColors cores;
  final double raio;

  /// Forma opcional (por exemplo, o polígono de uma região). Sem ela,
  /// a hachura ocupa o retângulo inteiro.
  final Path? forma;
  final double espessuraBorda;

  @override
  void paint(Canvas canvas, Size size) {
    final cor = cores.corDe(severidade);
    final contorno = forma ??
        (Path()
          ..addRRect(RRect.fromRectAndRadius(
            (Offset.zero & size).deflate(espessuraBorda / 2),
            Radius.circular(raio),
          )));

    final borda = Paint()
      ..color = cor
      ..style = PaintingStyle.stroke
      ..strokeWidth = espessuraBorda;

    if (severidade == Severidade.baixo) {
      desenharTracejado(canvas, contorno, borda, traco: 4, espaco: 2);
      return;
    }

    canvas.save();
    canvas.clipPath(contorno);
    canvas.drawPath(contorno, Paint()..color = cor.withValues(alpha: 0.13));
    final traco = Paint()
      ..color = cor
      ..strokeWidth = severidade == Severidade.critico ? 2.2 : 2.6;
    final limites = contorno.getBounds();

    switch (severidade) {
      case Severidade.medio:
        final ponto = Paint()..color = cores.textoDe(Severidade.medio);
        for (var y = limites.top + 4; y < limites.bottom; y += 8) {
          for (var x = limites.left + 4; x < limites.right; x += 8) {
            canvas.drawCircle(Offset(x, y), 1.7, ponto);
          }
        }
      case Severidade.alto:
      case Severidade.critico:
        const passo = 9.0;
        final d = limites.width + limites.height;
        for (var i = -d; i < d; i += passo) {
          canvas.drawLine(
            Offset(limites.left + i, limites.bottom),
            Offset(limites.left + i + limites.height, limites.top),
            traco,
          );
          if (severidade == Severidade.critico) {
            canvas.drawLine(
              Offset(limites.left + i, limites.top),
              Offset(limites.left + i + limites.height, limites.bottom),
              traco,
            );
          }
        }
      case Severidade.baixo:
        break;
    }
    canvas.restore();
    canvas.drawPath(contorno, borda);
  }

  @override
  bool shouldRepaint(HachuraPainter antigo) =>
      antigo.severidade != severidade ||
      antigo.cores != cores ||
      antigo.forma != forma;
}

/// Pequena amostra da hachura, usada como legenda ao lado do nome do nível.
class AmostraHachura extends StatelessWidget {
  const AmostraHachura(
      {required this.severidade, this.tamanho = 18, super.key});

  final Severidade severidade;
  final double tamanho;

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: CustomPaint(
        size: Size.square(tamanho),
        painter: HachuraPainter(
            severidade: severidade, cores: AquaColors.of(context)),
      ),
    );
  }
}

/// Desenha [caminho] tracejado.
void desenharTracejado(Canvas canvas, Path caminho, Paint tinta,
    {double traco = 5, double espaco = 3}) {
  for (final ui.PathMetric metrica in caminho.computeMetrics()) {
    var distancia = 0.0;
    while (distancia < metrica.length) {
      final fim = (distancia + traco).clamp(0.0, metrica.length);
      canvas.drawPath(metrica.extractPath(distancia, fim), tinta);
      distancia += traco + espaco;
    }
  }
}
