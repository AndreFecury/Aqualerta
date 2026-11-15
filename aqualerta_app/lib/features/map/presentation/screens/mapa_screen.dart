import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';
import 'package:aqualerta/core/config/mapas.dart';
import 'package:aqualerta/core/domain/carta.dart';
import 'package:aqualerta/core/domain/severidade.dart';
import 'package:aqualerta/core/state/painel_cubit.dart';
import 'package:aqualerta/core/utils/formato.dart';
import 'package:aqualerta/features/map/presentation/cubit/camadas_cubit.dart';
import 'package:aqualerta/features/map/presentation/widgets/painel_exibicao.dart';
import 'package:aqualerta/shared/theme/aqua_colors.dart';
import 'package:aqualerta/shared/widgets/hachura.dart';
import 'package:aqualerta/shared/widgets/regua.dart';
import 'package:aqualerta/shared/widgets/selo_severidade.dart';
import 'package:aqualerta/shared/widgets/v3.dart';

/// Manaus: ponto inicial do mapa.
const _manaus = LatLng(-3.119, -60.021);

class MapaScreen extends StatefulWidget {
  const MapaScreen({super.key});

  @override
  State<MapaScreen> createState() => _MapaScreenState();
}

class _MapaScreenState extends State<MapaScreen> {
  final _mapa = MapController();
  final _busca = TextEditingController();
  String? _regiaoSelecionadaId;
  LatLng? _minhaPosicao;

  @override
  void dispose() {
    _busca.dispose();
    _mapa.dispose();
    super.dispose();
  }

  void _buscar(Painel p, String texto) {
    String norm(String s) => s
        .toLowerCase()
        .replaceAll(RegExp('[áàâã]'), 'a')
        .replaceAll(RegExp('[éê]'), 'e')
        .replaceAll('í', 'i')
        .replaceAll(RegExp('[óôõ]'), 'o')
        .replaceAll('ú', 'u')
        .replaceAll('ç', 'c');
    final q = norm(texto.trim());
    if (q.isEmpty) return;
    final achada = p.regioes.where((r) => norm(r.nome).contains(q) || norm(r.municipio ?? '').contains(q)).firstOrNull;
    if (achada == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Nenhuma região monitorada com o nome "$texto".')),
      );
      return;
    }
    setState(() => _regiaoSelecionadaId = achada.id);
    if (achada.centro != null) _mapa.move(achada.centro!, 11);
  }

  Future<void> _centralizarEmMim() async {
    final aviso = ScaffoldMessenger.of(context);
    try {
      var permissao = await Geolocator.checkPermission();
      if (permissao == LocationPermission.denied) permissao = await Geolocator.requestPermission();
      if (permissao == LocationPermission.denied || permissao == LocationPermission.deniedForever) {
        aviso.showSnackBar(const SnackBar(
            content: Text('Sem permissão de localização. Você pode liberar nas configurações do celular.')));
        return;
      }
      final pos = await Geolocator.getCurrentPosition();
      final aqui = LatLng(pos.latitude, pos.longitude);
      setState(() => _minhaPosicao = aqui);
      _mapa.move(aqui, 13);
    } catch (_) {
      aviso.showSnackBar(const SnackBar(content: Text('Não foi possível obter sua localização agora.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = AquaColors.of(context);
    final painel = context.watch<PainelCubit>().state;
    final exibicao = context.watch<CamadasCubit>().state;
    final brilho = Theme.of(context).brightness;
    final fundo = FundoMapa.para(exibicao.tipo, brilho);

    final regiao =
        (_regiaoSelecionadaId != null ? painel.regiao(_regiaoSelecionadaId!) : null) ?? painel.regiaoPrincipal;
    final estacao = painel.estacaoDaRegiao(regiao);

    return Scaffold(
      body: Column(
        children: [
          if (painel.erro != null)
            Padding(
              padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top),
              child: FaixaAviso(
                  texto: painel.erro!,
                  icone: Icons.wifi_off,
                  acao: 'Tentar',
                  aoTocar: context.read<PainelCubit>().carregar),
            ),
          Expanded(
            child: Stack(
              children: [
                FlutterMap(
                  mapController: _mapa,
                  options: MapOptions(
                    initialCenter: regiao?.centro ?? _manaus,
                    initialZoom: 11,
                    minZoom: 4,
                    maxZoom: fundo.zoomMaximo.toDouble(),
                    backgroundColor: c.fundo,
                    interactionOptions: const InteractionOptions(flags: InteractiveFlag.all & ~InteractiveFlag.rotate),
                  ),
                  children: [
                    if (!FundoMapa.desligado)
                      TileLayer(
                        urlTemplate: fundo.url,
                        subdomains: fundo.subdominios,
                        retinaMode: fundo.retina && RetinaMode.isHighDensity(context),
                        maxNativeZoom: fundo.zoomMaximo,
                        userAgentPackageName: 'br.com.aqualerta',
                      ),
                    if (exibicao.mostra(Camada.areasAlagadas))
                      PolygonLayer(polygons: [
                        for (final e in painel.eventos)
                          for (final anel in e.contornos)
                            if (anel.length >= 3)
                              Polygon(
                                points: anel,
                                color: c.corDe(e.severidade).withValues(alpha: 0.28),
                                borderColor: c.corDe(e.severidade),
                                borderStrokeWidth: 2.5,
                              ),
                      ]),
                    if (exibicao.mostra(Camada.regioes))
                      PolygonLayer(polygons: [
                        for (final r in painel.regioes)
                          for (final anel in r.contornos)
                            if (anel.length >= 3)
                              Polygon(
                                points: anel,
                                color: c.corDe(painel.severidadeDaRegiao(r.id)).withValues(alpha: 0.06),
                                borderColor: c.corDe(painel.severidadeDaRegiao(r.id)),
                                borderStrokeWidth: r.id == regiao?.id ? 3 : 1.8,
                                pattern: painel.severidadeDaRegiao(r.id) == Severidade.baixo
                                    ? StrokePattern.dashed(segments: const [8, 4])
                                    : const StrokePattern.solid(),
                              ),
                      ]),
                    MarkerLayer(markers: [
                      if (exibicao.mostra(Camada.regioes))
                        for (final r in painel.regioes)
                          if (r.centro != null)
                            Marker(
                              point: r.centro!,
                              width: 48,
                              height: 48,
                              child: _MarcaRegiao(
                                regiao: r,
                                severidade: painel.severidadeDaRegiao(r.id),
                                selecionada: r.id == regiao?.id,
                                aoTocar: () => setState(() => _regiaoSelecionadaId = r.id),
                              ),
                            ),
                      if (exibicao.mostra(Camada.estacoes))
                        for (final e in painel.estacoes)
                          if (e.posicao != null)
                            Marker(point: e.posicao!, width: 120, height: 36, child: _MarcaEstacao(estacao: e)),
                      if (exibicao.mostra(Camada.minhaLocalizacao) && _minhaPosicao != null)
                        Marker(
                          point: _minhaPosicao!,
                          width: 40,
                          height: 40,
                          child: Semantics(
                            label: 'Você está aqui',
                            child: Container(
                              decoration: BoxDecoration(shape: BoxShape.circle, color: c.canal.withValues(alpha: 0.18)),
                              alignment: Alignment.center,
                              child: Container(
                                width: 16,
                                height: 16,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: c.canal,
                                  border: Border.all(color: Colors.white, width: 3),
                                ),
                              ),
                            ),
                          ),
                        ),
                    ]),
                    RichAttributionWidget(
                      alignment: AttributionAlignment.bottomLeft,
                      showFlutterMapAttribution: false,
                      attributions: [TextSourceAttribution(fundo.atribuicao)],
                    ),
                  ],
                ),
                // Busca
                Positioned(
                  top: MediaQuery.paddingOf(context).top + (painel.erro != null ? 0 : 12),
                  left: 12,
                  right: 12,
                  child: TextField(
                    controller: _busca,
                    textInputAction: TextInputAction.search,
                    onSubmitted: (t) => _buscar(painel, t),
                    decoration: InputDecoration(
                      hintText: 'Buscar bairro ou região',
                      prefixIcon: Icon(Icons.search, color: c.tinta2),
                    ),
                  ),
                ),
                // Botões do mapa
                Positioned(
                  right: 12,
                  top: MediaQuery.paddingOf(context).top + 76,
                  child: Column(
                    children: [
                      _BotaoMapa(
                          icone: Icons.my_location,
                          rotulo: 'Centralizar na minha localização',
                          aoTocar: _centralizarEmMim),
                      const SizedBox(height: 8),
                      _BotaoMapa(
                        icone: Icons.layers_outlined,
                        rotulo: 'Exibição do mapa: tipo de mapa e camadas',
                        aoTocar: () => mostrarPainelExibicao(context),
                      ),
                    ],
                  ),
                ),
                // Régua do rio da região
                if (estacao?.cotas != null)
                  Positioned(
                    left: 12,
                    top: MediaQuery.paddingOf(context).top + 76,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          height: (MediaQuery.sizeOf(context).height * 0.34).clamp(180.0, 320.0),
                          width: 64,
                          child: Regua(
                              cotas: estacao!.cotas!,
                              nivel: estacao.leituraRecente() ? estacao.nivel : null,
                              rio: estacao.titulo),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          _FolhaRegiao(painel: painel, regiao: regiao, estacao: estacao),
        ],
      ),
    );
  }
}

class _BotaoMapa extends StatelessWidget {
  const _BotaoMapa({required this.icone, required this.rotulo, required this.aoTocar});
  final IconData icone;
  final String rotulo;
  final VoidCallback aoTocar;

  @override
  Widget build(BuildContext context) {
    final c = AquaColors.of(context);
    return Tooltip(
      message: rotulo,
      child: Material(
        color: c.papel,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: c.linha)),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: aoTocar,
          child: SizedBox(width: 48, height: 48, child: Icon(icone, color: c.canal, semanticLabel: rotulo)),
        ),
      ),
    );
  }
}

class _MarcaRegiao extends StatelessWidget {
  const _MarcaRegiao(
      {required this.regiao, required this.severidade, required this.selecionada, required this.aoTocar});
  final Regiao regiao;
  final Severidade severidade;
  final bool selecionada;
  final VoidCallback aoTocar;

  @override
  Widget build(BuildContext context) {
    final c = AquaColors.of(context);
    return Semantics(
      button: true,
      label: '${regiao.nome}: risco ${severidade.rotulo.toLowerCase()}',
      child: GestureDetector(
        onTap: aoTocar,
        child: Center(
          child: Container(
            padding: const EdgeInsets.all(5),
            decoration: BoxDecoration(
              color: c.papel,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: selecionada ? c.tinta : c.linha, width: selecionada ? 2 : 1),
            ),
            child: AmostraHachura(severidade: severidade, tamanho: 20),
          ),
        ),
      ),
    );
  }
}

class _MarcaEstacao extends StatelessWidget {
  const _MarcaEstacao({required this.estacao});
  final Estacao estacao;

  @override
  Widget build(BuildContext context) {
    final c = AquaColors.of(context);
    final t = Theme.of(context).textTheme;
    final recente = estacao.leituraRecente();
    final s = estacao.severidade();
    return Semantics(
      label: recente
          ? 'Estação ${estacao.titulo}: ${formatarMetros(estacao.nivel!)} metros'
          : 'Estação ${estacao.titulo}: sem leitura recente',
      child: Center(
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            decoration: BoxDecoration(
              color: c.papel,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: s == null ? c.linha : c.corDe(s), width: 1.5),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.straighten, size: 14, color: c.tinta2),
                const SizedBox(width: 4),
                Text(recente ? '${formatarMetros(estacao.nivel!)} m' : 'sem leitura',
                    style: t.labelSmall!.copyWith(color: c.tinta), textScaler: TextScaler.noScaling),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _FolhaRegiao extends StatelessWidget {
  const _FolhaRegiao({required this.painel, required this.regiao, required this.estacao});
  final Painel painel;
  final Regiao? regiao;
  final Estacao? estacao;

  @override
  Widget build(BuildContext context) {
    final c = AquaColors.of(context);
    final t = Theme.of(context).textTheme;

    if (regiao == null) {
      return Container(
        color: c.papel,
        padding: const EdgeInsets.all(20),
        child: painel.carregando
            ? const LinearProgressIndicator()
            : Text('Nenhuma região monitorada encontrada.', style: t.bodyLarge),
      );
    }

    final severidade = painel.severidadeDaRegiao(regiao!.id);
    final alerta = painel.ativos.where((a) => a.regiaoId == regiao!.id).firstOrNull;
    final recente = estacao?.leituraRecente() ?? false;

    String frase;
    if (recente && estacao!.cotas != null) {
      final dif = estacao!.nivel! - estacao!.cotas!.alerta;
      frase = dif >= 0
          ? 'O ${estacao!.titulo} está ${formatarDiferenca(dif)} acima da cota de alerta.'
          : 'O ${estacao!.titulo} está ${formatarDiferenca(dif)} abaixo da cota de alerta.';
    } else if (alerta != null) {
      frase = alerta.titulo;
    } else {
      frase = 'Sem alertas ativos nesta região.';
    }
    final fonte = recente
        ? 'Leitura da ANA, ${formatarDataHora(estacao!.lidoEm!)}'
        : (estacao != null ? 'Sem leitura recente da estação ${estacao!.nome}' : 'Sem estação da ANA próxima');

    return Container(
      decoration: BoxDecoration(
        color: c.papel,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
        boxShadow: [BoxShadow(color: c.sombra, blurRadius: 24, offset: const Offset(0, -6))],
      ),
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(child: SeloSeveridade(severidade: severidade, mostrarAcao: true, grande: true)),
              Text(
                  painel.principalEhSeguida || regiao!.id != painel.regiaoPrincipal?.id
                      ? regiao!.nome
                      : 'Maior risco agora',
                  style: t.bodySmall),
            ],
          ),
          const SizedBox(height: 6),
          Text('${regiao!.nome}: $frase', style: t.bodyLarge!.copyWith(fontSize: 16)),
          const SizedBox(height: 6),
          Text(fonte, style: t.bodySmall),
          if (alerta != null) ...[
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child:
                  FilledButton(onPressed: () => context.push('/alerts/${alerta.id}'), child: const Text('O que fazer')),
            ),
          ] else if (!painel.seguidas.contains(regiao!.id)) ...[
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: () => context.read<PainelCubit>().seguir(regiao!.id, seguir: true),
                child: const Text('Seguir região'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
