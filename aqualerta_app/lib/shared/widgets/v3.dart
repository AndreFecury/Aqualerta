import 'package:flutter/material.dart';
import 'package:aqualerta/shared/theme/aqua_colors.dart';

/// Faixa de aviso no topo do conteúdo (sem conexão, banco desatualizado...).
class FaixaAviso extends StatelessWidget {
  const FaixaAviso(
      {required this.texto,
      this.icone = Icons.info_outline,
      this.acao,
      this.aoTocar,
      super.key});

  final String texto;
  final IconData icone;
  final String? acao;
  final VoidCallback? aoTocar;

  @override
  Widget build(BuildContext context) {
    final c = AquaColors.of(context);
    final t = Theme.of(context).textTheme;
    return Semantics(
      liveRegion: true,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
        decoration: BoxDecoration(
          color: c.papel,
          border: Border(bottom: BorderSide(color: c.linha)),
        ),
        child: Row(
          children: [
            Icon(icone, size: 20, color: c.tinta2),
            const SizedBox(width: 10),
            Expanded(child: Text(texto, style: t.bodyMedium)),
            if (acao != null)
              TextButton(onPressed: aoTocar, child: Text(acao!)),
          ],
        ),
      ),
    );
  }
}

/// Estado vazio: explica e diz o que acontece em seguida.
class EstadoVazio extends StatelessWidget {
  const EstadoVazio(
      {required this.titulo,
      required this.texto,
      this.icone = Icons.check_circle_outline,
      this.acao,
      super.key});

  final String titulo;
  final String texto;
  final IconData icone;
  final Widget? acao;

  @override
  Widget build(BuildContext context) {
    final c = AquaColors.of(context);
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icone, size: 40, color: c.tinta2),
          const SizedBox(height: 12),
          Text(titulo, style: t.titleMedium, textAlign: TextAlign.center),
          const SizedBox(height: 6),
          Text(texto,
              style: t.bodyLarge!.copyWith(color: c.tinta2),
              textAlign: TextAlign.center),
          if (acao != null) ...[const SizedBox(height: 16), acao!],
        ],
      ),
    );
  }
}

/// Cabeçalho das telas principais (título + subtítulo), sem barra de app.
class CabecalhoTela extends StatelessWidget {
  const CabecalhoTela(
      {required this.titulo, this.subtitulo, this.acoes = const [], super.key});

  final String titulo;
  final String? subtitulo;
  final List<Widget> acoes;

  @override
  Widget build(BuildContext context) {
    final c = AquaColors.of(context);
    final t = Theme.of(context).textTheme;
    return Container(
      width: double.infinity,
      padding: EdgeInsets.fromLTRB(
          16, MediaQuery.paddingOf(context).top + 16, 8, 14),
      decoration: BoxDecoration(
          color: c.papel, border: Border(bottom: BorderSide(color: c.linha))),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Semantics(
                    header: true, child: Text(titulo, style: t.headlineSmall)),
                if (subtitulo != null) ...[
                  const SizedBox(height: 2),
                  Text(subtitulo!,
                      style: t.bodyLarge!.copyWith(color: c.tinta2)),
                ],
              ],
            ),
          ),
          ...acoes,
        ],
      ),
    );
  }
}

/// Título de seção dentro das telas.
class TituloSecao extends StatelessWidget {
  const TituloSecao(this.texto, {super.key});
  final String texto;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Semantics(
            header: true,
            child: Text(texto, style: Theme.of(context).textTheme.titleLarge)),
      );
}
