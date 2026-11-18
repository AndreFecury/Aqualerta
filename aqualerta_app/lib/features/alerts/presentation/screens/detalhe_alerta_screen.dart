import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:aqualerta/core/config/mapas.dart';
import 'package:aqualerta/shared/widgets/logo_maptiler.dart';
import 'package:aqualerta/core/domain/carta.dart';
import 'package:aqualerta/core/state/painel_cubit.dart';
import 'package:aqualerta/core/utils/formato.dart';
import 'package:aqualerta/features/map/presentation/cubit/camadas_cubit.dart';
import 'package:aqualerta/shared/theme/aqua_colors.dart';
import 'package:aqualerta/shared/widgets/regua.dart';
import 'package:aqualerta/shared/widgets/selo_severidade.dart';
import 'package:aqualerta/shared/widgets/v3.dart';

/// Ações gerais de preparação para cheias, em linguagem simples.
const _acoes = [
  'Guarde documentos e remédios em saco plástico, num lugar alto.',
  'Se a água entrar em casa, desligue a energia no disjuntor.',
  'Combine com a família um lugar seguro para onde ir.',
];

class DetalheAlertaScreen extends StatefulWidget {
  const DetalheAlertaScreen({required this.alertaId, super.key});
  final String alertaId;

  @override
  State<DetalheAlertaScreen> createState() => _DetalheAlertaScreenState();
}

class _DetalheAlertaScreenState extends State<DetalheAlertaScreen> {
  final _feitas = <int>{};

  @override
  Widget build(BuildContext context) {
    final painel = context.watch<PainelCubit>().state;
    final alerta = painel.alerta(widget.alertaId);
    final c = AquaColors.of(context);
    final t = Theme.of(context).textTheme;

    if (alerta == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Alerta')),
        body: painel.carregando
            ? const Center(child: CircularProgressIndicator())
            : EstadoVazio(
                icone: Icons.search_off,
                titulo: 'Alerta não encontrado',
                texto: 'Ele pode ter sido encerrado há mais de 90 dias.',
                acao: FilledButton(
                    onPressed: () => context.go('/alerts'),
                    child: const Text('Ver alertas')),
              ),
      );
    }

    final estacao = alerta.estacao;
    final recente = estacao?.leituraRecente() ?? false;
    final regiao = painel.regiao(alerta.regiaoId);
    final evento =
        painel.eventos.where((e) => e.id == alerta.eventoId).firstOrNull;
    final contornos = (evento?.contornos.isNotEmpty ?? false)
        ? evento!.contornos
        : (regiao?.contornos ?? const <List<LatLng>>[]);

    return Scaffold(
      appBar: AppBar(
        title: Text(estacao != null ? 'Alerta do ${estacao.titulo}' : 'Alerta'),
        actions: [
          IconButton(
            tooltip: 'Compartilhar alerta',
            icon: const Icon(Icons.share_outlined),
            onPressed: () => _compartilhar(alerta),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 32),
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (estacao?.cotas != null) ...[
                SizedBox(
                    width: 72,
                    height: 340,
                    child: Regua(
                        cotas: estacao!.cotas!,
                        nivel: recente ? estacao.nivel : null,
                        rio: estacao.titulo)),
                const SizedBox(width: 16),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SeloSeveridade(severidade: alerta.severidade),
                    const SizedBox(height: 8),
                    Semantics(
                        header: true,
                        child: Text(
                            alerta.ativo
                                ? alerta.severidade.acao
                                : 'Alerta encerrado',
                            style: t.headlineSmall)),
                    const SizedBox(height: 8),
                    Text(alerta.titulo, style: t.titleMedium),
                    const SizedBox(height: 4),
                    Text(alerta.texto, style: t.bodyLarge),
                    if (recente && estacao!.cotas != null) ...[
                      const SizedBox(height: 16),
                      Text(formatarMetros(estacao.nivel!, casas: 2),
                          style: t.displaySmall),
                      Text(
                        [
                          'metros na régua',
                          if (estacao.variacao24h != null)
                            formatarTendencia(estacao.variacao24h)!
                                .toLowerCase()
                        ].join(', '),
                        style: t.bodySmall,
                      ),
                      const SizedBox(height: 8),
                      Text(
                          _relacao(estacao.nivel! - estacao.cotas!.alerta,
                              'do alerta'),
                          style: t.bodyLarge),
                      Text(
                          _relacao(estacao.nivel! - estacao.cotas!.inundacao,
                              'da inundação'),
                          style: t.bodyLarge),
                      if (estacao.cotas!.severa != null)
                        Text(
                            _relacao(estacao.nivel! - estacao.cotas!.severa!,
                                'da inundação severa'),
                            style: t.bodyLarge),
                    ],
                    const SizedBox(height: 12),
                    Text(
                      [
                        alerta.regiaoNome,
                        'Emitido ${formatarDataHora(alerta.emitidoEm)}',
                        if (recente)
                          'Estação ${estacao!.codigoAna} da ANA, leitura de ${formatarDataHora(estacao.lidoEm!)}',
                        if (estacao?.cotas != null)
                          'Cotas oficiais do Serviço Geológico do Brasil (SGB)'
                        else if (estacao != null)
                          'Estação ${estacao.codigoAna} da ANA sem leitura recente',
                      ].join('\n'),
                      style: t.bodySmall,
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (alerta.severidade != alerta.severidadeOriginal && recente) ...[
            const SizedBox(height: 12),
            Text(
              'O nível mostrado segue a régua da estação, que está mais atual que o alerta '
              '(emitido como ${alerta.severidadeOriginal.rotulo}).',
              style: t.bodySmall,
            ),
          ],
          if (alerta.ativo) ...[
            const SizedBox(height: 28),
            const TituloSecao('O que fazer agora'),
            for (var i = 0; i < _acoes.length; i++)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: _feitas.contains(i),
                onChanged: (v) => setState(
                    () => v == true ? _feitas.add(i) : _feitas.remove(i)),
                title:
                    Text(_acoes[i], style: t.bodyLarge!.copyWith(fontSize: 16)),
                shape: Border(bottom: BorderSide(color: c.linha)),
              ),
          ],
          if (contornos.isNotEmpty) ...[
            const SizedBox(height: 28),
            const TituloSecao('Área afetada'),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: SizedBox(
                  height: 200,
                  child: _MiniCarta(
                      contornos: contornos, cor: c.corDe(alerta.severidade))),
            ),
            const SizedBox(height: 6),
            Text(
              evento?.areaReal == true
                  ? 'Área registrada no evento de inundação.'
                  : 'Contorno da região monitorada; a área exata ainda não foi medida.',
              style: t.bodySmall,
            ),
          ],
          const SizedBox(height: 28),
          FilledButton.icon(
            onPressed: () => launchUrl(Uri(scheme: 'tel', path: '199')),
            icon: const Icon(Icons.phone),
            label: const Text('Ligar para a Defesa Civil, 199'),
          ),
          const SizedBox(height: 10),
          OutlinedButton(
              onPressed: () => _compartilhar(alerta),
              child: const Text('Enviar para a família')),
        ],
      ),
    );
  }

  String _relacao(double dif, String referencia) => dif >= 0
      ? '${formatarDiferenca(dif)} acima $referencia'
      : '${formatarDiferenca(dif)} abaixo $referencia';

  void _compartilhar(AlertaV3 a) {
    final texto = StringBuffer()
      ..writeln(
          'AquaAlerta: ${a.severidade.acao} (risco ${a.severidade.rotulo.toLowerCase()})')
      ..writeln('${a.titulo} - ${a.regiaoNome}')
      ..writeln(a.texto)
      ..write('Em caso de emergência, ligue 199 (Defesa Civil).');
    SharePlus.instance.share(ShareParams(text: texto.toString()));
  }
}

class _MiniCarta extends StatelessWidget {
  const _MiniCarta({required this.contornos, required this.cor});
  final List<List<LatLng>> contornos;
  final Color cor;

  @override
  Widget build(BuildContext context) {
    final pontos = [for (final a in contornos) ...a];
    final fundo = FundoMapa.para(TipoMapa.carta, Theme.of(context).brightness);
    return Semantics(
      label: 'Mapa da área afetada',
      child: FlutterMap(
        options: MapOptions(
          initialCameraFit: CameraFit.bounds(
              bounds: LatLngBounds.fromPoints(pontos),
              padding: const EdgeInsets.all(20)),
          interactionOptions:
              const InteractionOptions(flags: InteractiveFlag.none),
          backgroundColor: AquaColors.of(context).fundo,
        ),
        children: [
          if (!FundoMapa.desligado)
            TileLayer(
                key: ValueKey(fundo.url),
                urlTemplate: fundo.url,
                subdomains: fundo.subdominios,
                userAgentPackageName: 'br.com.aqualerta',
                // Sem internet o mini-mapa só fica sem fundo; se for o
                // MapTiler que falha, o app passa para o mapa gratuito.
                errorTileCallback: (_, __, ___) {
                  if (fundo.ehMapTiler) FundoMapa.registrarFalhaDoMapTiler();
                }),
          PolygonLayer(polygons: [
            for (final a in contornos)
              if (a.length >= 3)
                Polygon(
                    points: a,
                    color: cor.withValues(alpha: 0.3),
                    borderColor: cor,
                    borderStrokeWidth: 2.5),
          ]),
          if (!FundoMapa.desligado && fundo.ehMapTiler)
            const Align(
              alignment: Alignment.bottomLeft,
              child: Padding(
                padding: EdgeInsets.only(left: 8, bottom: 8),
                child: LogoMapTiler(),
              ),
            ),
          RichAttributionWidget(
              showFlutterMapAttribution: false,
              attributions: [TextSourceAttribution(fundo.atribuicao)]),
        ],
      ),
    );
  }
}
