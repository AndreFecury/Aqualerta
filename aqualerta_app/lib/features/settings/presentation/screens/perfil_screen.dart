import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:aqualerta/core/domain/severidade.dart';
import 'package:aqualerta/core/notificacoes/avisos_service.dart';
import 'package:aqualerta/core/state/painel_cubit.dart';
import 'package:aqualerta/features/settings/presentation/cubit/aparencia_cubit.dart';
import 'package:aqualerta/features/settings/presentation/cubit/notificacoes_cubit.dart';
import 'package:aqualerta/shared/theme/aqua_colors.dart';
import 'package:aqualerta/shared/widgets/selo_severidade.dart';
import 'package:aqualerta/shared/widgets/v3.dart';

class PerfilScreen extends StatelessWidget {
  const PerfilScreen({super.key});

  static const _rotulosEscala = {
    EscalaTexto.pequeno: 'A−',
    EscalaTexto.normal: 'A',
    EscalaTexto.grande: 'A+',
    EscalaTexto.muitoGrande: 'A++',
  };

  @override
  Widget build(BuildContext context) {
    final aparencia = context.watch<AparenciaCubit>().state;
    final avisos = context.watch<NotificacoesCubit>().state;
    final painel = context.watch<PainelCubit>().state;
    final c = AquaColors.of(context);
    final t = Theme.of(context).textTheme;
    final email = _emailAtual();

    return Scaffold(
      body: Column(
        children: [
          CabecalhoTela(titulo: 'Perfil', subtitulo: email),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 32),
              children: [
                const TituloSecao('Tamanho do texto'),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text('Usar o tamanho do celular', style: t.titleSmall),
                  subtitle: Text(
                      'Segue a configuração de acessibilidade do aparelho',
                      style: t.bodySmall),
                  value: aparencia.usarTamanhoDoCelular,
                  onChanged:
                      context.read<AparenciaCubit>().usarTamanhoDoCelular,
                ),
                if (!aparencia.usarTamanhoDoCelular) ...[
                  const SizedBox(height: 8),
                  SegmentedButton<EscalaTexto>(
                    showSelectedIcon: false,
                    segments: [
                      for (final e in EscalaTexto.values)
                        ButtonSegment(
                            value: e,
                            label: Text(_rotulosEscala[e]!,
                                semanticsLabel: e.rotulo)),
                    ],
                    selected: {aparencia.escala},
                    onSelectionChanged: (s) =>
                        context.read<AparenciaCubit>().definirEscala(s.first),
                  ),
                ],
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: c.linha),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Prévia', style: t.bodySmall),
                      const SizedBox(height: 4),
                      const SeloSeveridade(
                          severidade: Severidade.alto,
                          mostrarAcao: true,
                          grande: true),
                      const SizedBox(height: 4),
                      Text(
                          'Na Compensa, o Rio Negro está 30 cm acima da cota de alerta.',
                          style: t.bodyLarge),
                    ],
                  ),
                ),
                const SizedBox(height: 28),
                const TituloSecao('Tema'),
                SegmentedButton<ThemeMode>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: ThemeMode.light, label: Text('Claro')),
                    ButtonSegment(value: ThemeMode.dark, label: Text('Escuro')),
                    ButtonSegment(
                        value: ThemeMode.system, label: Text('Automático')),
                  ],
                  selected: {aparencia.tema},
                  onSelectionChanged: (s) =>
                      context.read<AparenciaCubit>().definirTema(s.first),
                ),
                const SizedBox(height: 28),
                const TituloSecao('Avisos'),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text('Notificações', style: t.titleSmall),
                  subtitle: Text('Receber alertas das regiões que você segue',
                      style: t.bodySmall),
                  value: avisos.ativas,
                  onChanged: context.read<NotificacoesCubit>().definirAtivas,
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text('Som de alerta', style: t.titleSmall),
                  subtitle: Text('Tocar som nos níveis Alto e Crítico',
                      style: t.bodySmall),
                  value: avisos.som,
                  onChanged: avisos.ativas
                      ? context.read<NotificacoesCubit>().definirSom
                      : null,
                ),
                const SizedBox(height: 8),
                Text('Avisar a partir de', style: t.titleSmall),
                const SizedBox(height: 8),
                SegmentedButton<Severidade>(
                  showSelectedIcon: false,
                  segments: [
                    for (final s in Severidade.values)
                      ButtonSegment(value: s, label: Text(s.rotulo))
                  ],
                  selected: {avisos.severidadeMinima},
                  onSelectionChanged: avisos.ativas
                      ? (s) => context
                          .read<NotificacoesCubit>()
                          .definirMinima(s.first)
                      : null,
                ),
                const SizedBox(height: 8),
                Text(
                  painel.seguidas.isEmpty
                      ? 'Você ainda não segue nenhuma região. Escolha em Rios.'
                      : painel.seguidas.length == 1
                          ? 'Vale para a região que você segue.'
                          : 'Vale para as ${painel.seguidas.length} regiões que você segue.',
                  style: t.bodySmall,
                ),
                const SizedBox(height: 28),
                const TituloSecao('Fontes de dados'),
                _LinhaFonte(
                    nome: 'ANA, nível dos rios a cada 30 min',
                    estado: 'Ativa',
                    cor: c.textoDe(Severidade.baixo)),
                _LinhaFonte(
                    nome: 'SGB, cotas de alerta e inundação',
                    estado: 'Ativa',
                    cor: c.textoDe(Severidade.baixo)),
                _LinhaFonte(
                    nome: 'IBGE, limites dos municípios',
                    estado: 'Ativa',
                    cor: c.textoDe(Severidade.baixo)),
                _LinhaFonte(
                    nome: 'Copernicus, água por satélite (Sentinel-1)',
                    estado: 'Ativa',
                    cor: c.textoDe(Severidade.baixo)),
                const SizedBox(height: 28),
                OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: c.textoDe(Severidade.critico),
                    side: BorderSide(color: c.linha, width: 1.5),
                  ),
                  onPressed: () async {
                    await AvisosService.instancia.esquecerAparelho();
                    await Supabase.instance.client.auth.signOut();
                  },
                  child: const Text('Sair da conta'),
                ),
                const SizedBox(height: 16),
                FutureBuilder<PackageInfo>(
                  future: PackageInfo.fromPlatform(),
                  builder: (_, v) => Center(
                    child: Text(
                        v.hasData
                            ? 'AquaAlerta ${v.data!.version}'
                            : 'AquaAlerta',
                        style: t.bodySmall),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

String? _emailAtual() {
  try {
    return Supabase.instance.client.auth.currentUser?.email;
  } catch (_) {
    return null; // Supabase ainda não iniciado (ex.: testes)
  }
}

class _LinhaFonte extends StatelessWidget {
  const _LinhaFonte(
      {required this.nome, required this.estado, required this.cor});
  final String nome;
  final String estado;
  final Color cor;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
          border:
              Border(bottom: BorderSide(color: AquaColors.of(context).linha))),
      child: Row(
        children: [
          Expanded(child: Text(nome, style: t.bodyLarge)),
          Text(estado, style: t.labelSmall!.copyWith(color: cor)),
        ],
      ),
    );
  }
}
