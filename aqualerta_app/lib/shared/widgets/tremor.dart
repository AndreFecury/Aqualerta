import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Balança o filho de lado quando [gatilho] muda, como o campo de senha
/// errada do iOS e de muitos apps: 3 idas e voltas em 360 ms, diminuindo, e
/// uma vibração curta. Sem animação quando "remover animações" está ligado
/// (a vibração continua, porque não é movimento na tela).
class Tremor extends StatefulWidget {
  const Tremor({required this.gatilho, required this.child, super.key});
  final int gatilho;
  final Widget child;

  static const duracao = Duration(milliseconds: 360);

  /// Deslocamento máximo para cada lado.
  static const amplitude = 10.0;

  @override
  State<Tremor> createState() => _TremorState();
}

class _TremorState extends State<Tremor> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: Tremor.duracao);

  @override
  void didUpdateWidget(Tremor antigo) {
    super.didUpdateWidget(antigo);
    if (widget.gatilho != antigo.gatilho) {
      HapticFeedback.mediumImpact();
      if (!MediaQuery.disableAnimationsOf(context)) _c.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _c,
        builder: (_, filho) {
          final v = _c.value;
          final dx = v == 0 || v == 1
              ? 0.0
              : math.sin(v * math.pi * 6) * Tremor.amplitude * (1 - v);
          return Transform.translate(offset: Offset(dx, 0), child: filho);
        },
        child: widget.child,
      );
}
