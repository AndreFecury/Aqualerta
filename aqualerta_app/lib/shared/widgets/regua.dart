import 'package:flutter/material.dart';
import 'package:aqualerta/core/domain/severidade.dart';
import 'package:aqualerta/core/utils/formato.dart';
import 'package:aqualerta/shared/theme/aqua_colors.dart';
import 'hachura.dart';

/// A régua do rio: o elemento central da v3.
///
/// Mostra o nível atual subindo sobre a escala da estação, com as cotas de
/// alerta (laranja, tracejada) e de inundação (vermelha, tracejada).
/// Sem leitura ([nivel] nulo), a régua aparece vazia e hachurada.
class Regua extends StatelessWidget {
  const Regua({
    required this.cotas,
    required this.nivel,
    this.rio,
    this.direcao = Axis.vertical,
    this.mostrarNumeros = true,
    super.key,
  });

  final CotasEstacao cotas;
  final double? nivel;

  /// Nome do rio, usado na descrição para leitores de tela.
  final String? rio;
  final Axis direcao;

  /// Números da escala (só na régua vertical).
  final bool mostrarNumeros;

  String _descricao() {
    final nome = rio == null ? 'Régua do rio' : 'Régua do $rio';
    if (nivel == null) return '$nome: sem leitura recente';
    return '$nome: ${formatarMetros(nivel!)} metros. '
        'Cota de alerta ${formatarMetros(cotas.alerta)}, '
        'cota de inundação ${formatarMetros(cotas.inundacao)}.';
  }

  @override
  Widget build(BuildContext context) {
    final cores = AquaColors.of(context);
    final estilo = Theme.of(context).textTheme.labelSmall!.copyWith(color: cores.tinta);
    return Semantics(
      label: _descricao(),
      image: true,
      child: CustomPaint(
        painter: _ReguaPainter(
          cotas: cotas,
          nivel: nivel,
          cores: cores,
          vertical: direcao == Axis.vertical,
          mostrarNumeros: mostrarNumeros && direcao == Axis.vertical,
          estiloNumero: estilo,
          escalaTexto: MediaQuery.textScalerOf(context),
        ),
        child: direcao == Axis.vertical
            ? const SizedBox(width: 64, height: 360)
            : const SizedBox(width: double.infinity, height: 30),
      ),
    );
  }
}

class _ReguaPainter extends CustomPainter {
  _ReguaPainter({
    required this.cotas,
    required this.nivel,
    required this.cores,
    required this.vertical,
    required this.mostrarNumeros,
    required this.estiloNumero,
    required this.escalaTexto,
  });

  final CotasEstacao cotas;
  final double? nivel;
  final AquaColors cores;
  final bool vertical;
  final bool mostrarNumeros;
  final TextStyle estiloNumero;
  final TextScaler escalaTexto;

  // Faixa da escala: um pouco abaixo da cota normal até um pouco acima da emergência.
  double get _min => vertical
      ? (cotas.normal - 1).floorToDouble()
      : cotas.normal - (cotas.emergencia - cotas.normal) * 0.12;
  double get _max => vertical
      ? (cotas.emergencia + 0.5).ceilToDouble()
      : cotas.emergencia + (cotas.emergencia - cotas.normal) * 0.06;

  @override
  void paint(Canvas canvas, Size size) {
    const margem = 12.0;
    final corpo = Offset.zero & size;
    final rr = RRect.fromRectAndRadius(corpo.deflate(0.5), const Radius.circular(4));

    // Posição de um valor em metros ao longo da régua.
    double pos(double v) {
      final t = ((v - _min) / (_max - _min)).clamp(0.0, 1.0);
      return vertical
          ? size.height - margem - t * (size.height - 2 * margem)
          : t * size.width;
    }

    canvas.drawRRect(rr, Paint()..color = cores.papel);

    if (nivel == null) {
      _hachuraVazia(canvas, rr);
    } else {
      final p = pos(nivel!);
      final agua = vertical
          ? Rect.fromLTRB(0, p, size.width, size.height)
          : Rect.fromLTRB(0, 0, p, size.height);
      canvas.save();
      canvas.clipRRect(rr);
      canvas.drawRect(agua, Paint()..color = cores.aguaFunda.withValues(alpha: 0.75));
      canvas.restore();
    }

    // Marcas: a cada 0,5 m na vertical; 40 divisões na horizontal.
    final maior = Paint()
      ..color = cores.tinta
      ..strokeWidth = 1.6;
    final menor = Paint()
      ..color = cores.barro
      ..strokeWidth = 1.2;
    if (vertical) {
      for (var v = _min; v <= _max + 1e-6; v += 0.5) {
        final y = pos(v);
        final inteiro = (v - v.roundToDouble()).abs() < 1e-6;
        final comprimento = size.width * (inteiro ? 0.42 : 0.22);
        canvas.drawLine(Offset(size.width - comprimento, y), Offset(size.width, y), inteiro ? maior : menor);
        if (inteiro && mostrarNumeros) {
          final tp = TextPainter(
            text: TextSpan(text: v.round().toString(), style: estiloNumero),
            textDirection: TextDirection.ltr,
            textScaler: escalaTexto.clamp(maxScaleFactor: 1.3),
          )..layout();
          tp.paint(canvas, Offset(6, y - tp.height / 2));
        }
      }
    } else {
      for (var i = 0; i <= 40; i++) {
        final x = 1 + (size.width - 2) * i / 40;
        final grande = i % 4 == 0;
        final comprimento = grande ? 10.0 : 5.0;
        canvas.drawLine(Offset(x, size.height - 1 - comprimento), Offset(x, size.height - 1), grande ? maior : menor);
      }
    }

    canvas.drawRRect(
      rr,
      Paint()
        ..style = PaintingStyle.stroke
        ..color = cores.tinta.withValues(alpha: 0.22),
    );

    // Cotas tracejadas.
    for (final (valor, cor) in [
      (cotas.alerta, cores.corDe(Severidade.alto)),
      (cotas.inundacao, cores.corDe(Severidade.critico)),
    ]) {
      final p = pos(valor);
      final linha = Path();
      if (vertical) {
        linha
          ..moveTo(0, p)
          ..lineTo(size.width + 14, p);
      } else {
        linha
          ..moveTo(p, -3)
          ..lineTo(p, size.height + 3);
      }
      desenharTracejado(
        canvas,
        linha,
        Paint()
          ..color = cor
          ..strokeWidth = 2.5
          ..style = PaintingStyle.stroke,
      );
    }

    // Nível agora.
    if (nivel != null) {
      final p = pos(nivel!);
      final agora = Paint()
        ..color = cores.tinta
        ..strokeWidth = 3;
      if (vertical) {
        canvas.drawLine(Offset(-4, p), Offset(size.width + 4, p), agora);
      } else {
        canvas.drawLine(Offset(p, -4), Offset(p, size.height + 4), agora);
      }
    }
  }

  void _hachuraVazia(Canvas canvas, RRect rr) {
    canvas.save();
    canvas.clipRRect(rr);
    final listra = Paint()
      ..color = cores.tinta2.withValues(alpha: 0.45)
      ..strokeWidth = 1.5;
    final r = rr.outerRect;
    final d = r.width + r.height;
    for (var i = -d; i < d; i += 6) {
      canvas.drawLine(Offset(r.left + i, r.bottom), Offset(r.left + i + r.height, r.top), listra);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_ReguaPainter antigo) =>
      antigo.nivel != nivel ||
      antigo.cores != cores ||
      antigo.vertical != vertical ||
      antigo.escalaTexto != escalaTexto;
}
