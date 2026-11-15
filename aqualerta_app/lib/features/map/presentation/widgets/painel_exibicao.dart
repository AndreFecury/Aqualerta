import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:aqualerta/core/domain/severidade.dart';
import 'package:aqualerta/features/map/presentation/cubit/camadas_cubit.dart';
import 'package:aqualerta/shared/theme/aqua_colors.dart';
import 'package:aqualerta/shared/widgets/hachura.dart';

/// Abre o painel "Exibição do mapa": tipo de mapa e camadas.
Future<void> mostrarPainelExibicao(BuildContext context) {
  final cubit = context.read<CamadasCubit>();
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => BlocProvider.value(value: cubit, child: const _PainelExibicao()),
  );
}

class _PainelExibicao extends StatelessWidget {
  const _PainelExibicao();

  @override
  Widget build(BuildContext context) {
    final c = AquaColors.of(context);
    final t = Theme.of(context).textTheme;
    final estado = context.watch<CamadasCubit>().state;
    final cubit = context.read<CamadasCubit>();

    Widget icone(Camada camada) => switch (camada) {
          Camada.areasAlagadas => const AmostraHachura(severidade: Severidade.alto, tamanho: 24),
          Camada.regioes => const AmostraHachura(severidade: Severidade.baixo, tamanho: 24),
          Camada.estacoes => Icon(Icons.straighten, color: c.tinta),
          Camada.minhaLocalizacao => Icon(Icons.my_location, color: c.canal),
        };

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.9),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Semantics(header: true, child: Text('Exibição do mapa', style: t.titleLarge)),
              const SizedBox(height: 16),
              Text('Tipo de mapa', style: t.titleSmall),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final tipo in TipoMapa.values)
                    _OpcaoTipo(tipo: tipo, selecionado: estado.tipo == tipo, aoTocar: () => cubit.escolherTipo(tipo)),
                ],
              ),
              const SizedBox(height: 8),
              Text('Automático usa a carta clara de dia e a escura à noite. Satélite gasta mais internet.',
                  style: t.bodySmall),
              const SizedBox(height: 20),
              Text('Camadas', style: t.titleSmall),
              for (final camada in Camada.values)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  secondary: SizedBox(width: 28, child: Center(child: icone(camada))),
                  title: Text(camada.titulo, style: t.titleSmall),
                  subtitle: Text(camada.descricao, style: t.bodySmall),
                  value: estado.mostra(camada),
                  onChanged: (_) => cubit.alternar(camada),
                ),
              ListTile(
                enabled: false,
                contentPadding: EdgeInsets.zero,
                leading: SizedBox(width: 28, child: Icon(Icons.satellite_alt_outlined, color: c.tinta2)),
                title: Text('Inundação por satélite', style: t.titleSmall!.copyWith(color: c.tinta2)),
                subtitle: Text('Imagens Sentinel-1 do Copernicus', style: t.bodySmall),
                trailing: Text('Em breve', style: t.labelSmall),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _OpcaoTipo extends StatelessWidget {
  const _OpcaoTipo({required this.tipo, required this.selecionado, required this.aoTocar});
  final TipoMapa tipo;
  final bool selecionado;
  final VoidCallback aoTocar;

  @override
  Widget build(BuildContext context) {
    final c = AquaColors.of(context);
    final t = Theme.of(context).textTheme;
    final (Color terra, Color agua) = switch (tipo) {
      TipoMapa.automatico => (c.fundo, c.aguaFunda),
      TipoMapa.carta => (AquaColors.claro.fundo, AquaColors.claro.aguaFunda),
      TipoMapa.ruas => (const Color(0xFFF4F4F2), const Color(0xFFAAD3DF)),
      TipoMapa.satelite => (const Color(0xFF3E5A33), const Color(0xFF2A2A20)),
    };
    return Semantics(
      selected: selecionado,
      button: true,
      label: 'Mapa ${tipo.rotulo}',
      excludeSemantics: true,
      child: InkWell(
        onTap: aoTocar,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          width: 76,
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: selecionado ? c.canal : Colors.transparent, width: 2.5),
          ),
          child: Column(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: SizedBox(
                  height: 48,
                  child: Stack(
                    children: [
                      Positioned.fill(child: ColoredBox(color: terra)),
                      if (tipo == TipoMapa.automatico)
                        Positioned.fill(
                            child: ClipPath(clipper: _Diagonal(), child: ColoredBox(color: AquaColors.escuro.fundo))),
                      Positioned(left: 0, right: 0, bottom: 8, height: 12, child: ColoredBox(color: agua)),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Text(tipo.rotulo,
                  style: t.labelMedium!.copyWith(fontWeight: selecionado ? FontWeight.w800 : FontWeight.w500),
                  textAlign: TextAlign.center),
            ],
          ),
        ),
      ),
    );
  }
}

class _Diagonal extends CustomClipper<Path> {
  @override
  Path getClip(Size s) => Path()
    ..moveTo(s.width, 0)
    ..lineTo(s.width, s.height)
    ..lineTo(0, s.height)
    ..close();

  @override
  bool shouldReclip(covariant CustomClipper<Path> oldClipper) => false;
}
