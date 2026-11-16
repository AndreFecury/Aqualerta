import 'package:flutter/material.dart';
import 'package:aqualerta/shared/theme/aqua_colors.dart';

/// Gota do AquaAlerta (da proposta do San), desenhada em código para ficar
/// nítida em qualquer tamanho e seguir o tema.
class LogoAqualerta extends StatelessWidget {
  const LogoAqualerta({this.tamanho = 32, super.key});
  final double tamanho;

  @override
  Widget build(BuildContext context) {
    final c = AquaColors.of(context);
    return ExcludeSemantics(
      child: CustomPaint(
          size: Size.square(tamanho), painter: _Gota(c.canal, c.aguaFunda)),
    );
  }
}

class _Gota extends CustomPainter {
  _Gota(this.corGota, this.corOnda);
  final Color corGota;
  final Color corOnda;

  @override
  void paint(Canvas canvas, Size s) {
    final w = s.width, h = s.height;
    final gota = Path()
      ..moveTo(w * 0.5, h * 0.06)
      ..cubicTo(w * 0.5, h * 0.06, w * 0.18, h * 0.42, w * 0.18, h * 0.62)
      ..arcToPoint(Offset(w * 0.82, h * 0.62),
          radius: Radius.circular(w * 0.32), clockwise: false)
      ..cubicTo(w * 0.82, h * 0.42, w * 0.5, h * 0.06, w * 0.5, h * 0.06)
      ..close();
    canvas.drawPath(gota, Paint()..color = corGota);
    canvas.save();
    canvas.clipPath(gota);
    final onda = Path()
      ..moveTo(0, h * 0.68)
      ..quadraticBezierTo(w * 0.3, h * 0.6, w * 0.5, h * 0.68)
      ..quadraticBezierTo(w * 0.72, h * 0.76, w, h * 0.66)
      ..lineTo(w, h)
      ..lineTo(0, h)
      ..close();
    canvas.drawPath(onda, Paint()..color = corOnda);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_Gota old) =>
      old.corGota != corGota || old.corOnda != corOnda;
}
