import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:aqualerta/core/atualizacao/atualizacao.dart';
import 'package:aqualerta/shared/theme/aqua_colors.dart';

/// Faixa acima das abas: "Nova versão… Atualizar", progresso do download e
/// o que fazer em seguida. Some sozinha quando não há nada novo.
class AvisoAtualizacao extends StatelessWidget {
  const AvisoAtualizacao({super.key});

  @override
  Widget build(BuildContext context) {
    final e = context.watch<AtualizacaoCubit>().state;
    final semMovimento = MediaQuery.disableAnimationsOf(context);
    return AnimatedSize(
      duration:
          semMovimento ? Duration.zero : const Duration(milliseconds: 200),
      curve: Curves.easeOut,
      alignment: Alignment.bottomCenter,
      child:
          e.mostrarAviso ? _Faixa(e) : const SizedBox(width: double.infinity),
    );
  }
}

class _Faixa extends StatelessWidget {
  const _Faixa(this.e);
  final EstadoAtualizacao e;

  @override
  Widget build(BuildContext context) {
    final c = AquaColors.of(context);
    final t = Theme.of(context).textTheme;
    final cubit = context.read<AtualizacaoCubit>();
    final v = e.nova!;

    final Widget conteudo = switch (e.fase) {
      FaseAtualizacao.baixando => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
                'Baixando a versão ${v.versao}… '
                '${e.progresso == null ? '' : '${e.progresso}%'}',
                style: t.bodyMedium),
            const SizedBox(height: 8),
            LinearProgressIndicator(
                value: e.progresso == null ? null : e.progresso! / 100),
          ],
        ),
      FaseAtualizacao.instalando => Text(
          'Confirme a instalação na tela do Android. '
          'Seus dados e regiões continuam iguais.',
          style: t.bodyMedium),
      FaseAtualizacao.erro => Row(
          children: [
            Expanded(child: Text(e.erro ?? 'Falhou.', style: t.bodyMedium)),
            TextButton(
                onPressed: cubit.atualizar,
                child: const Text('Tentar de novo')),
          ],
        ),
      _ => Row(
          children: [
            Icon(Icons.system_update, color: c.canal),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Nova versão ${v.versao} do AquaAlerta',
                      style: t.titleSmall),
                  if (v.notas != null || v.tamanhoTexto != null)
                    Text(
                        [v.notas, v.tamanhoTexto]
                            .whereType<String>()
                            .join(' · '),
                        style: t.bodySmall,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
            TextButton(
                onPressed: cubit.dispensar, child: const Text('Agora não')),
            FilledButton(
                key: const Key('atualizar-app'),
                onPressed: cubit.atualizar,
                child: const Text('Atualizar')),
          ],
        ),
    };

    return Semantics(
      liveRegion: true,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
        decoration: BoxDecoration(
          color: c.papel,
          border: Border(top: BorderSide(color: c.linha)),
        ),
        child: conteudo,
      ),
    );
  }
}
