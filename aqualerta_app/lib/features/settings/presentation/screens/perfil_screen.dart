import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:aqualerta/core/atualizacao/atualizacao.dart';
import 'package:aqualerta/core/auth/conta.dart';
import 'package:aqualerta/core/auth/login_google.dart';
import 'package:aqualerta/core/domain/severidade.dart';
import 'package:aqualerta/core/notificacoes/avisos_service.dart';
import 'package:aqualerta/core/state/painel_cubit.dart';
import 'package:aqualerta/features/map/data/ar_repository.dart';
import 'package:aqualerta/features/map/presentation/cubit/camadas_cubit.dart';
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
    final mapa = context.watch<CamadasCubit>().state;
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
                // Aviso de ar só existe onde há sensor perto e depois de validado
                // (decisões de 22/11/2026). Sem região com aviso ligado, a chave
                // não aparece; o texto diz onde há sensor.
                Builder(builder: (context) {
                  final cubitAr = context.watch<ArCubit>();
                  if (cubitAr.vencido &&
                      cubitAr.state.situacao != SituacaoAr.erro) {
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (context.mounted) context.read<ArCubit>().carregar();
                    });
                  }
                  final ar = cubitAr.state;
                  final contextos = [
                    for (final r in ar.regioes.values)
                      if (r.contexto != null) r.contexto!
                  ];
                  String nome(String id) => painel.regiao(id)?.nome ?? 'região';
                  final comSensor = [
                    for (final x in contextos)
                      if (x.temSensor) nome(x.regiaoId)
                  ]..sort();
                  final ligadas = [
                    for (final x in contextos)
                      if (x.avisoSensorLigado) nome(x.regiaoId)
                  ]..sort();
                  final textoSensores = comSensor.isEmpty
                      ? 'Nenhuma região tem sensor de qualidade do ar perto; '
                          'o app mostra só a estimativa do modelo.'
                      : 'Sensor de qualidade do ar perto: ${comSensor.join(', ')}. '
                          'Nas outras regiões, só a estimativa do modelo, sem aviso.';
                  if (ligadas.isEmpty) {
                    return Padding(
                      key: const Key('avisos-ar-texto'),
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Qualidade do ar', style: t.titleSmall),
                          const SizedBox(height: 2),
                          Text(
                              'Avisos de qualidade do ar ainda desligados: só '
                              'vão existir onde há sensor perto e depois de '
                              'validados. $textoSensores',
                              style: t.bodySmall),
                        ],
                      ),
                    );
                  }
                  return SwitchListTile(
                    key: const Key('avisos-ar'),
                    contentPadding: EdgeInsets.zero,
                    title: Text('Qualidade do ar', style: t.titleSmall),
                    subtitle: Text(
                        'Avisar quando o sensor perto indicar ar muito ruim '
                        '(${ligadas.join(', ')}). $textoSensores '
                        'Não muda os avisos de cheia.',
                        style: t.bodySmall),
                    value: avisos.ar,
                    onChanged: avisos.ativas
                        ? context.read<NotificacoesCubit>().definirAr
                        : null,
                  );
                }),
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
                const TituloSecao('Mapa'),
                Text('Abrir o mapa em', style: t.titleSmall),
                const SizedBox(height: 8),
                SegmentedButton<InicioMapa>(
                  key: const Key('inicio-mapa'),
                  showSelectedIcon: false,
                  segments: [
                    for (final i in InicioMapa.values)
                      ButtonSegment(value: i, label: Text(i.rotulo)),
                  ],
                  selected: {mapa.inicio},
                  onSelectionChanged: (s) =>
                      context.read<CamadasCubit>().escolherInicio(s.first),
                ),
                const SizedBox(height: 8),
                Text(
                  switch (mapa.inicio) {
                    InicioMapa.manaus => 'O mapa sempre abre em Manaus.',
                    InicioMapa.seguida =>
                      'Abre na primeira região que você segue (ou em Manaus).',
                    InicioMapa.maiorRisco =>
                      'Abre onde o risco estiver mais alto agora.',
                  },
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
                    nome: 'CEMADEN, chuva nos pluviômetros a cada 10 min',
                    estado: estadoChuva(painel.chuvaColetadaEm),
                    cor: estadoChuva(painel.chuvaColetadaEm) == 'Ativa'
                        ? c.textoDe(Severidade.baixo)
                        : c.tinta2),
                _LinhaFonte(
                    nome: 'IBGE, limites dos municípios',
                    estado: 'Ativa',
                    cor: c.textoDe(Severidade.baixo)),
                _LinhaFonte(
                    nome: 'Copernicus, água por satélite (Sentinel-1)',
                    estado: 'Ativa',
                    cor: c.textoDe(Severidade.baixo)),
                Builder(builder: (context) {
                  final ar = context.watch<ArCubit>();
                  if (ar.vencido && ar.state.situacao != SituacaoAr.erro) {
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (context.mounted) context.read<ArCubit>().carregar();
                    });
                  }
                  final coleta = ar.state.coletaEm;
                  final estado = estadoAr(coleta);
                  return _LinhaFonte(
                      nome: 'Open-Meteo/CAMS e INPE, qualidade do ar (modelo)',
                      estado: estado,
                      cor: estado == 'Ativa'
                          ? c.textoDe(Severidade.baixo)
                          : c.tinta2);
                }),
                const SizedBox(height: 28),
                OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: c.textoDe(Severidade.critico),
                    side: BorderSide(color: c.linha, width: 1.5),
                  ),
                  onPressed: () async {
                    await AvisosService.instancia.esquecerAparelho();
                    await LoginGoogle.sair();
                    await Supabase.instance.client.auth.signOut();
                  },
                  child: const Text('Sair da conta'),
                ),
                const SizedBox(height: 8),
                TextButton(
                  key: const Key('excluir-conta'),
                  style: TextButton.styleFrom(
                      foregroundColor: c.textoDe(Severidade.critico)),
                  onPressed: () => _excluirConta(context),
                  child: const Text('Excluir conta'),
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
                Center(
                  child: TextButton(
                    key: const Key('procurar-atualizacao'),
                    onPressed: () => _procurarAtualizacao(context),
                    child: const Text('Procurar atualização'),
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

Future<void> _procurarAtualizacao(BuildContext context) async {
  final aviso = ScaffoldMessenger.of(context);
  final tem = await context.read<AtualizacaoCubit>().verificar(manual: true);
  if (!tem) {
    aviso.showSnackBar(const SnackBar(
        content: Text('Você já tem a versão mais nova do AquaAlerta.')));
  }
}

/// Pede confirmação clara antes de apagar: a exclusão não tem volta.
Future<void> _excluirConta(BuildContext context) async {
  final c = AquaColors.of(context);
  final confirmou = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Excluir sua conta?'),
      content: const Text(
          'Sua conta, as regiões que você segue e as preferências de aviso '
          'serão apagadas agora, e você deixará de receber alertas neste '
          'celular. Isso não pode ser desfeito.'),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar')),
        FilledButton(
          key: const Key('confirmar-exclusao'),
          style: FilledButton.styleFrom(
              backgroundColor: c.textoDe(Severidade.critico)),
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Excluir conta'),
        ),
      ],
    ),
  );
  if (confirmou != true || !context.mounted) return;
  final aviso = ScaffoldMessenger.of(context);
  try {
    await Conta.excluir();
    aviso.showSnackBar(const SnackBar(
        content: Text('Conta excluída. Seus dados foram apagados.')));
  } catch (_) {
    aviso.showSnackBar(const SnackBar(
        content: Text(
            'Não foi possível excluir a conta agora. Confira a internet e tente de novo.')));
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

/// Estado da coleta de chuva para a lista de fontes: "Ativa" com coleta nos
/// últimos 30 min, "Atrasada" se parou, "Aguardando" se ainda não começou.
/// Coleta do ar é de hora em hora: até 3 h sem dado novo ainda é "Ativa".
String estadoAr(DateTime? ultima, {DateTime? agora}) {
  if (ultima == null) return 'Aguardando';
  final h = (agora ?? DateTime.now()).difference(ultima);
  return h <= const Duration(hours: 3) ? 'Ativa' : 'Atrasada';
}

String estadoChuva(DateTime? ultima, {DateTime? agora}) {
  if (ultima == null) return 'Aguardando';
  final idade = (agora ?? DateTime.now()).difference(ultima);
  return idade <= const Duration(minutes: 30) ? 'Ativa' : 'Atrasada';
}
