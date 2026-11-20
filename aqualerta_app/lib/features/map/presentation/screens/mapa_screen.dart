import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';
import 'package:aqualerta/core/config/mapas.dart';
import 'package:aqualerta/shared/widgets/logo_maptiler.dart';
import 'package:aqualerta/core/domain/carta.dart';
import 'package:aqualerta/core/domain/satelite.dart';
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

/// Parte da altura que o cartão ocupa fechado; o mapa deixa essa faixa livre.
const _alturaMinima = 0.2;

/// Água detectada por satélite: azul forte translúcido, distinto das cores de
/// risco e visível tanto sobre a foto de satélite quanto sobre o mapa de ruas.
const _aguaSateliteFundo = Color(0x732F80ED);
const _aguaSateliteBorda = Color(0xFF1A56DB);

class MapaScreen extends StatefulWidget {
  const MapaScreen({super.key});

  @override
  State<MapaScreen> createState() => _MapaScreenState();
}

class _MapaScreenState extends State<MapaScreen>
    with SingleTickerProviderStateMixin {
  final _mapa = MapController();
  final _busca = TextEditingController();
  String? _regiaoSelecionadaId;
  LatLng? _minhaPosicao;
  double _alturaMapa = 800;

  // Aviso de mapa que não carrega: vários erros de tile em pouco tempo.
  final _errosDeTile = <DateTime>[];
  String? _ultimoErroDeTile;
  bool _mapaComProblema = false;
  Timer? _reavaliar;

  bool _centrouNaAbertura = false;
  bool _mexeuNoMapa = false;

  // Troca automática para os mapas gratuitos quando o MapTiler falha.
  bool _avisoReserva = false;
  Timer? _fimAvisoReserva;
  Timer? _fimReserva;

  void _erroDeTile(Object erro, {required bool doMapTiler}) {
    final texto = erro.toString().replaceAll(RegExp(r'\s+'), ' ');
    _ultimoErroDeTile =
        texto.length > 90 ? '${texto.substring(0, 90)}...' : texto;
    if (doMapTiler) {
      // Falha do MapTiler não conta para o aviso: o app troca de mapa.
      if (FundoMapa.registrarFalhaDoMapTiler()) {
        Future.microtask(_mostrarTroca);
      }
      return;
    }
    final agora = DateTime.now();
    _errosDeTile
      ..add(agora)
      ..removeWhere((t) => agora.difference(t) > const Duration(seconds: 10));
    if (!_mapaComProblema && _errosDeTile.length >= 5) {
      Future.microtask(() {
        if (!mounted) return;
        setState(() => _mapaComProblema = true);
        _reavaliar?.cancel();
        _reavaliar = Timer.periodic(const Duration(seconds: 6), (_) {
          final limite = DateTime.now().subtract(const Duration(seconds: 8));
          if (_errosDeTile.every((t) => t.isBefore(limite)) && mounted) {
            _reavaliar?.cancel();
            setState(() => _mapaComProblema = false);
          }
        });
      });
    }
  }

  void _mostrarTroca() {
    if (!mounted) return;
    setState(() => _avisoReserva = true);
    _fimAvisoReserva?.cancel();
    _fimAvisoReserva = Timer(const Duration(seconds: 8), () {
      if (mounted) setState(() => _avisoReserva = false);
    });
    // Passado o tempo da reserva, redesenha para tentar o MapTiler de novo.
    _fimReserva?.cancel();
    _fimReserva = Timer(FundoMapa.tempoNaReserva, () {
      if (mounted) setState(() {});
    });
  }

  late final AnimationController _voo = AnimationController(vsync: this);

  /// Leva a câmera até [destino] com uma transição suave. Em distâncias
  /// Sem afastar no meio do caminho: cada nível de zoom que a câmera cruza
  /// pede mapa novo, e isso deixava tudo lento.
  void _voar(LatLng destino, double zoomFinal) {
    final cam = _mapa.camera;
    final origem = cam.center;
    final z0 = cam.zoom;
    final z1 = zoomFinal.clamp(cam.minZoom ?? 3, cam.maxZoom ?? 19).toDouble();
    final km = distanciaKm(origem, destino);
    if (km < 0.02 && (z1 - z0).abs() < 0.05) return;

    // 300 ms num pulo curto, até 600 ms atravessando o estado: mais que
    // isso parece lento (e o dedo pode interromper a qualquer momento).
    final duracao = Duration(
        milliseconds:
            (300 + km * 1.5 + (z1 - z0).abs() * 50).clamp(300, 600).round());
    _voo.stop();
    _voo.duration = duracao;
    final curva = CurvedAnimation(parent: _voo, curve: Curves.easeInOutCubic);
    void passo() {
      final t = curva.value;
      final zoom = z0 + (z1 - z0) * t;
      _mapa.move(
        LatLng(origem.latitude + (destino.latitude - origem.latitude) * t,
            origem.longitude + (destino.longitude - origem.longitude) * t),
        zoom.clamp(cam.minZoom ?? 3, cam.maxZoom ?? 19).toDouble(),
      );
    }

    curva.addListener(passo);
    _voo.forward(from: 0).whenComplete(() {
      curva.removeListener(passo);
      curva.dispose();
    });
  }

  /// Seleciona a região e enquadra o município inteiro, sem cobrir o contorno
  /// com o cartão de baixo.
  void _selecionar(Regiao r) {
    setState(() => _regiaoSelecionadaId = r.id);
    final pontos = [for (final anel in r.contornos) ...anel];
    if (pontos.length < 3) {
      if (r.centro != null) _voar(r.centro!, 10);
      return;
    }
    final enquadrado = CameraFit.bounds(
      bounds: LatLngBounds.fromPoints(pontos),
      padding: EdgeInsets.fromLTRB(
          28, 84, 28, _alturaMapa * (0.34 - _alturaMinima) + 28),
      maxZoom: 11,
    ).fit(_mapa.camera);
    _voar(enquadrado.center, enquadrado.zoom);
  }

  @override
  void dispose() {
    _reavaliar?.cancel();
    _fimAvisoReserva?.cancel();
    _fimReserva?.cancel();
    _voo.dispose();
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
    final achada = p.regioes
        .where((r) =>
            norm(r.nome).contains(q) || norm(r.municipio ?? '').contains(q))
        .firstOrNull;
    if (achada == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text('Nenhuma região monitorada com o nome "$texto".')),
      );
      return;
    }
    _selecionar(achada);
  }

  Future<void> _centralizarEmMim() async {
    final aviso = ScaffoldMessenger.of(context);
    try {
      var permissao = await Geolocator.checkPermission();
      if (permissao == LocationPermission.denied)
        permissao = await Geolocator.requestPermission();
      if (permissao == LocationPermission.denied ||
          permissao == LocationPermission.deniedForever) {
        aviso.showSnackBar(const SnackBar(
            content: Text(
                'Sem permissão de localização. Você pode liberar nas configurações do celular.')));
        return;
      }
      final pos = await Geolocator.getCurrentPosition();
      final aqui = LatLng(pos.latitude, pos.longitude);
      setState(() => _minhaPosicao = aqui);
      _voar(aqui, 14.5);
    } catch (_) {
      aviso.showSnackBar(const SnackBar(
          content: Text('Não foi possível obter sua localização agora.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = AquaColors.of(context);
    final painel = context.watch<PainelCubit>().state;
    final exibicao = context.watch<CamadasCubit>().state;
    final brilho = Theme.of(context).brightness;
    final fundo = FundoMapa.para(exibicao.tipo, brilho);

    final regiao = (_regiaoSelecionadaId != null
            ? painel.regiao(_regiaoSelecionadaId!)
            : null) ??
        painel.regiaoPrincipal;
    final estacao = painel.estacaoDaRegiao(regiao);

    // Água por satélite: busca a região mostrada quando a camada está ligada.
    // O SateliteCubit guarda em memória e não repete em 30 min.
    final satelite = context.watch<SateliteCubit>();
    final mostraSatelite = exibicao.mostra(Camada.aguaSatelite);
    final dadoSatelite = regiao == null ? null : satelite.de(regiao.id);
    if (mostraSatelite && regiao != null) {
      final vencido = dadoSatelite?.situacao == SituacaoSatelite.pronto &&
          DateTime.now().difference(dadoSatelite!.buscadoEm!) >
              SateliteCubit.validadeCache;
      if (dadoSatelite == null || vencido) {
        final id = regiao.id;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) satelite.carregar(id);
        });
      }
    }
    final areasSatelite = mostraSatelite
        ? dadoSatelite?.observacao?.areas ?? const <AreaAgua>[]
        : const <AreaAgua>[];

    // Os dados chegam depois do primeiro desenho do mapa (que abre em
    // Manaus). Uma vez só, leva a câmera até a região principal, se a
    // pessoa ainda não mexeu no mapa.
    if (!_centrouNaAbertura && painel.temDados && regiao?.centro != null) {
      _centrouNaAbertura = true;
      final alvo = regiao!.centro!;
      if (!_mexeuNoMapa && distanciaKm(alvo, _manaus) > 1) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && !_mexeuNoMapa) _mapa.move(alvo, 11);
        });
      }
    }

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
            child: LayoutBuilder(
                builder: (context, caixa) => Stack(
                      children: [
                        Padding(
                          padding: EdgeInsets.only(
                              bottom: caixa.maxHeight * _alturaMinima),
                          child: FlutterMap(
                            mapController: _mapa,
                            options: MapOptions(
                              onPositionChanged: (_, gesto) {
                                if (!gesto) return;
                                _mexeuNoMapa = true;
                                // O dedo manda: para o voo da câmera em
                                // vez de puxar o mapa de volta.
                                if (_voo.isAnimating) _voo.stop();
                              },
                              initialCenter: regiao?.centro ?? _manaus,
                              initialZoom: 11,
                              minZoom: 4,
                              maxZoom: fundo.zoomMaximo.toDouble(),
                              backgroundColor: c.fundo,
                              interactionOptions: const InteractionOptions(
                                  flags: InteractiveFlag.all &
                                      ~InteractiveFlag.rotate),
                              onTap: (_, ponto) {
                                final achada =
                                    regiaoNoPonto(ponto, painel.regioes);
                                if (achada != null)
                                  setState(
                                      () => _regiaoSelecionadaId = achada.id);
                              },
                            ),
                            children: [
                              if (!FundoMapa.desligado)
                                TileLayer(
                                  key: ValueKey(fundo.url),
                                  urlTemplate: fundo.url,
                                  subdomains: fundo.subdominios,
                                  retinaMode: fundo.retina &&
                                      RetinaMode.isHighDensity(context),
                                  maxNativeZoom: fundo.zoomMaximo,
                                  userAgentPackageName: 'br.com.aqualerta',
                                  evictErrorTileStrategy: EvictErrorTileStrategy
                                      .notVisibleRespectMargin,
                                  tileUpdateTransformer:
                                      TileUpdateTransformers.throttle(
                                          const Duration(milliseconds: 250)),
                                  errorTileCallback: (_, erro, __) =>
                                      _erroDeTile(erro,
                                          doMapTiler: fundo.ehMapTiler),
                                  tileDisplay: const TileDisplay.fadeIn(
                                      duration: Duration(milliseconds: 180)),
                                ),
                              if (!FundoMapa.desligado &&
                                  fundo.sobreposicao != null)
                                TileLayer(
                                  urlTemplate: fundo.sobreposicao!.url,
                                  subdomains: fundo.sobreposicao!.subdominios,
                                  retinaMode: fundo.sobreposicao!.retina &&
                                      RetinaMode.isHighDensity(context),
                                  userAgentPackageName: 'br.com.aqualerta',
                                  evictErrorTileStrategy: EvictErrorTileStrategy
                                      .notVisibleRespectMargin,
                                  tileUpdateTransformer:
                                      TileUpdateTransformers.throttle(
                                          const Duration(milliseconds: 250)),
                                ),
                              if (areasSatelite.isNotEmpty)
                                PolygonLayer(
                                  key: const ValueKey('camada-satelite'),
                                  polygons: [
                                    for (final a in areasSatelite)
                                      Polygon(
                                        points: a.contorno,
                                        holePointsList: a.buracos,
                                        color: _aguaSateliteFundo,
                                        borderColor: _aguaSateliteBorda,
                                        borderStrokeWidth: 1.2,
                                      ),
                                  ],
                                ),
                              if (exibicao.mostra(Camada.areasAlagadas))
                                PolygonLayer(polygons: [
                                  for (final e in painel.eventos)
                                    for (final anel in e.contornos)
                                      if (anel.length >= 3)
                                        Polygon(
                                          points: anel,
                                          color: c
                                              .corDe(e.severidade)
                                              .withValues(alpha: 0.28),
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
                                          color: c
                                              .corDe(painel
                                                  .severidadeDaRegiao(r.id))
                                              .withValues(alpha: 0.06),
                                          borderColor: c.corDe(
                                              painel.severidadeDaRegiao(r.id)),
                                          borderStrokeWidth:
                                              r.id == regiao?.id ? 3 : 1.8,
                                          pattern:
                                              painel.severidadeDaRegiao(r.id) ==
                                                      Severidade.baixo
                                                  ? StrokePattern.dashed(
                                                      segments: const [8, 4])
                                                  : const StrokePattern.solid(),
                                        ),
                                ]),
                              MarkerLayer(markers: [
                                if (exibicao.mostra(Camada.regioes))
                                  for (final r in painel.regioes)
                                    if (r.centro != null)
                                      Marker(
                                        point: r.centro!,
                                        width: 124,
                                        height: 48, // área de toque mínima
                                        child: _MarcaRegiao(
                                          regiao: r,
                                          severidade:
                                              painel.severidadeDaRegiao(r.id),
                                          estacao:
                                              exibicao.mostra(Camada.estacoes)
                                                  ? painel.estacaoDaRegiao(r)
                                                  : null,
                                          selecionada: r.id == regiao?.id,
                                          // Igual à busca: seleciona e enquadra.
                                          aoTocar: () => _selecionar(r),
                                        ),
                                      ),
                                // Estações que não têm região perto: marcador próprio, com gota.
                                if (exibicao.mostra(Camada.estacoes))
                                  for (final e in painel.estacoes)
                                    if (e.posicao != null &&
                                        !(exibicao.mostra(Camada.regioes) &&
                                            painel.regioes.any((r) =>
                                                painel.estacaoDaRegiao(r)?.id ==
                                                    e.id &&
                                                r.centro != null)))
                                      Marker(
                                          point: e.posicao!,
                                          width: 124,
                                          height: 36,
                                          child: _MarcaEstacao(estacao: e)),
                                if (exibicao.mostra(Camada.minhaLocalizacao) &&
                                    _minhaPosicao != null)
                                  Marker(
                                    point: _minhaPosicao!,
                                    width: 40,
                                    height: 40,
                                    child: Semantics(
                                      label: 'Você está aqui',
                                      child: Container(
                                        decoration: BoxDecoration(
                                            shape: BoxShape.circle,
                                            color: c.canal
                                                .withValues(alpha: 0.18)),
                                        alignment: Alignment.center,
                                        child: Container(
                                          width: 16,
                                          height: 16,
                                          decoration: BoxDecoration(
                                            shape: BoxShape.circle,
                                            color: c.canal,
                                            border: Border.all(
                                                color: Colors.white, width: 3),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                              ]),
                              if (!FundoMapa.desligado && fundo.ehMapTiler)
                                const Align(
                                  alignment: Alignment.bottomLeft,
                                  child: Padding(
                                    padding:
                                        EdgeInsets.only(left: 52, bottom: 10),
                                    child: LogoMapTiler(),
                                  ),
                                ),
                              RichAttributionWidget(
                                alignment: AttributionAlignment.bottomLeft,
                                showFlutterMapAttribution: false,
                                attributions: [
                                  TextSourceAttribution(fundo.atribuicao)
                                ],
                              ),
                            ],
                          ),
                        ),
                        // Busca
                        Positioned(
                          top: MediaQuery.paddingOf(context).top +
                              (painel.erro != null ? 0 : 12),
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
                        if (_avisoReserva && !_mapaComProblema)
                          Positioned(
                            top: MediaQuery.paddingOf(context).top +
                                (painel.erro != null ? 0 : 12) +
                                64,
                            left: 12,
                            right: 72,
                            child: Material(
                              color: c.papel,
                              elevation: 2,
                              borderRadius: BorderRadius.circular(10),
                              child: Padding(
                                padding: const EdgeInsets.all(10),
                                child: Row(
                                  children: [
                                    Icon(Icons.swap_horiz,
                                        size: 20, color: c.tinta2),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                          'O MapTiler não respondeu nesta rede. Mostrando o mapa alternativo.',
                                          style: Theme.of(context)
                                              .textTheme
                                              .bodyMedium),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        if (_mapaComProblema)
                          Positioned(
                            top: MediaQuery.paddingOf(context).top +
                                (painel.erro != null ? 0 : 12) +
                                64,
                            left: 12,
                            right: 72,
                            child: Material(
                              color: c.papel,
                              elevation: 2,
                              borderRadius: BorderRadius.circular(10),
                              child: Padding(
                                padding: const EdgeInsets.all(10),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Icon(Icons.cloud_off,
                                        size: 20, color: c.tinta2),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                              'O mapa de fundo não está carregando. Confira a internet.',
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .bodyMedium),
                                          if (_ultimoErroDeTile != null)
                                            Text(_ultimoErroDeTile!,
                                                style: Theme.of(context)
                                                    .textTheme
                                                    .bodySmall),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        if (mostraSatelite)
                          Positioned(
                            left: 12,
                            top: MediaQuery.paddingOf(context).top + 76,
                            child: _LegendaSatelite(
                                dado: dadoSatelite, temRegiao: regiao != null),
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
                                rotulo:
                                    'Exibição do mapa: tipo de mapa e camadas',
                                aoTocar: () => mostrarPainelExibicao(context),
                              ),
                            ],
                          ),
                        ),
                        // Cartão que sobe e desce
                        _FolhaRegiao(
                            painel: painel, regiao: regiao, estacao: estacao),
                      ],
                    )),
          ),
        ],
      ),
    );
  }
}

class _BotaoMapa extends StatelessWidget {
  const _BotaoMapa(
      {required this.icone, required this.rotulo, required this.aoTocar});
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
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: c.linha)),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: aoTocar,
          child: SizedBox(
              width: 48,
              height: 48,
              child: Icon(icone, color: c.canal, semanticLabel: rotulo)),
        ),
      ),
    );
  }
}

/// Marcador da região: amostra de hachura do risco e, se houver estação
/// perto, o nível do rio na mesma etiqueta (um símbolo só, sem sobreposição).
class _MarcaRegiao extends StatefulWidget {
  const _MarcaRegiao({
    required this.regiao,
    required this.severidade,
    required this.estacao,
    required this.selecionada,
    required this.aoTocar,
  });
  final Regiao regiao;
  final Severidade severidade;
  final Estacao? estacao;
  final bool selecionada;
  final VoidCallback aoTocar;

  @override
  State<_MarcaRegiao> createState() => _MarcaRegiaoState();
}

class _MarcaRegiaoState extends State<_MarcaRegiao> {
  bool _pressionado = false;

  void _pressao(bool v) {
    if (_pressionado != v) setState(() => _pressionado = v);
  }

  @override
  Widget build(BuildContext context) {
    final regiao = widget.regiao;
    final severidade = widget.severidade;
    final estacao = widget.estacao;
    final selecionada = widget.selecionada;
    final semMovimento = MediaQuery.disableAnimationsOf(context);
    final c = AquaColors.of(context);
    final t = Theme.of(context).textTheme;
    final nivel = (estacao?.leituraRecente() ?? false)
        ? '${formatarMetros(estacao!.nivel!)} m'
        : null;
    return Semantics(
      button: true,
      label:
          '${regiao.nome}: risco ${severidade.rotulo.toLowerCase()}${nivel != null ? ', rio a $nivel' : ''}',
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque, // os 48 de altura inteiros tocam
        onTap: widget.aoTocar,
        onTapDown: (_) => _pressao(true),
        onTapUp: (_) => _pressao(false),
        onTapCancel: () => _pressao(false),
        child: Center(
          child: AnimatedScale(
            // Afunda um pouco ao pressionar (100 ms): resposta imediata.
            scale: _pressionado ? 0.94 : 1,
            duration: semMovimento
                ? Duration.zero
                : const Duration(milliseconds: 100),
            curve: Curves.easeOut,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: AnimatedContainer(
                duration: semMovimento
                    ? Duration.zero
                    : const Duration(milliseconds: 150),
                curve: Curves.easeOut,
                padding: const EdgeInsets.fromLTRB(5, 5, 8, 5),
                decoration: BoxDecoration(
                  color: c.papel,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                      color: selecionada ? c.tinta : c.linha,
                      width: selecionada ? 2.5 : 1),
                  boxShadow: [BoxShadow(color: c.sombra, blurRadius: 6)],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ClipRRect(
                        borderRadius: BorderRadius.circular(14),
                        child: AmostraHachura(
                            severidade: severidade, tamanho: 24)),
                    const SizedBox(width: 6),
                    Text(nivel ?? regiao.nome,
                        style: t.labelMedium!.copyWith(
                            color: c.tinta, fontWeight: FontWeight.w700),
                        textScaler: TextScaler.noScaling),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Estação sem região por perto: gota d'água e o nível.
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
      excludeSemantics: true,
      child: Center(
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
            decoration: BoxDecoration(
              color: c.papel,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                  color: s == null ? c.linha : c.corDe(s), width: 1.5),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.water_drop, size: 15, color: c.canal),
                const SizedBox(width: 4),
                Text(
                    recente
                        ? '${formatarMetros(estacao.nivel!)} m'
                        : 'sem leitura',
                    style: t.labelMedium!
                        .copyWith(color: c.tinta, fontWeight: FontWeight.w700),
                    textScaler: TextScaler.noScaling),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Cartão de baixo: fechado mostra o risco; puxado para cima mostra a régua,
/// as cotas e as ações.
class _FolhaRegiao extends StatelessWidget {
  const _FolhaRegiao(
      {required this.painel, required this.regiao, required this.estacao});
  final Painel painel;
  final Regiao? regiao;
  final Estacao? estacao;

  @override
  Widget build(BuildContext context) {
    final c = AquaColors.of(context);
    final t = Theme.of(context).textTheme;

    return DraggableScrollableSheet(
      initialChildSize: 0.34,
      minChildSize: _alturaMinima,
      maxChildSize: 0.86,
      snap: true,
      snapSizes: const [0.34],
      builder: (context, controle) => Container(
        decoration: BoxDecoration(
          color: c.papel,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
          border: Border(top: BorderSide(color: c.linha)),
          boxShadow: [
            BoxShadow(
                color: c.sombra, blurRadius: 24, offset: const Offset(0, -6))
          ],
        ),
        child: ListView(
          controller: controle,
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
          children: [
            Semantics(
              label: 'Arraste para cima para ver mais detalhes',
              child: Center(
                child: Container(
                  width: 40,
                  height: 5,
                  margin: const EdgeInsets.only(bottom: 12, top: 2),
                  decoration: BoxDecoration(
                      color: c.linha, borderRadius: BorderRadius.circular(3)),
                ),
              ),
            ),
            if (regiao == null)
              painel.carregando
                  ? const LinearProgressIndicator()
                  : Text('Nenhuma região monitorada encontrada.',
                      style: t.bodyLarge)
            else
              // Trocar de região: o conteúdo novo entra suave (200 ms) e o
              // antigo sai rápido (100 ms), sem pular de uma vez.
              AnimatedSwitcher(
                duration: MediaQuery.disableAnimationsOf(context)
                    ? Duration.zero
                    : const Duration(milliseconds: 200),
                reverseDuration: const Duration(milliseconds: 100),
                switchInCurve: const Cubic(0.16, 1, 0.3, 1),
                switchOutCurve: Curves.easeIn,
                layoutBuilder: (atual, anteriores) => Stack(
                  alignment: Alignment.topCenter,
                  children: [...anteriores, if (atual != null) atual],
                ),
                transitionBuilder: (filho, anim) => FadeTransition(
                  opacity: anim,
                  child: SlideTransition(
                    position:
                        Tween(begin: const Offset(0, 0.02), end: Offset.zero)
                            .animate(anim),
                    child: filho,
                  ),
                ),
                child: Column(
                  key: ValueKey(regiao!.id),
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: _conteudo(context, c, t),
                ),
              ),
          ],
        ),
      ),
    );
  }

  List<Widget> _conteudo(BuildContext context, AquaColors c, TextTheme t) {
    final severidade = painel.severidadeDaRegiao(regiao!.id);
    final daRegiao = painel.ativos.where((a) => a.regiaoId == regiao!.id);
    final chuva = daRegiao.where((a) => a.ehChuva).firstOrNull;
    // Aviso de chuva tem prioridade: é o que muda nos próximos minutos.
    final alerta = chuva ?? daRegiao.firstOrNull;
    final recente = estacao?.leituraRecente() ?? false;

    String frase;
    if (chuva != null) {
      frase = switch (chuva.severidade) {
        Severidade.critico =>
          'chuva extrema nos pluviômetros, risco de grandes alagamentos.',
        Severidade.alto =>
          'chuva muito forte nos pluviômetros, alagamentos prováveis.',
        _ => 'chuva forte nos pluviômetros, risco de alagamento.',
      };
    } else if (recente && estacao!.cotas != null) {
      final dif = estacao!.nivel! - estacao!.cotas!.alerta;
      frase = dif >= 0
          ? 'O ${estacao!.titulo} está ${formatarDiferenca(dif)} acima da cota de alerta.'
          : 'O ${estacao!.titulo} está ${formatarDiferenca(dif)} abaixo da cota de alerta.';
    } else if (alerta != null) {
      frase = alerta.titulo;
    } else {
      frase = 'Sem alertas ativos nesta região.';
    }
    final tendencia = recente ? formatarTendencia(estacao!.variacao24h) : null;
    final fonte = recente
        ? [
            'Leitura da ANA, ${formatarDataHora(estacao!.lidoEm!)}',
            if (tendencia != null) tendencia
          ].join('. ')
        : (estacao != null
            ? 'Sem leitura recente da estação ${estacao!.nome}'
            : 'Sem estação da ANA próxima');
    final cotas = estacao?.cotas;

    Widget linhaCota(String rotulo, double valor, Severidade nivelCota) =>
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(
            children: [
              ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: AmostraHachura(severidade: nivelCota, tamanho: 16)),
              const SizedBox(width: 8),
              Expanded(child: Text(rotulo, style: t.bodyMedium)),
              Text('${formatarMetros(valor)} m', style: t.titleSmall),
            ],
          ),
        );

    return [
      Row(
        children: [
          Expanded(
              child: SeloSeveridade(
                  severidade: severidade, mostrarAcao: true, grande: true)),
          Flexible(
            child: Text(
                painel.principalEhSeguida ||
                        regiao!.id != painel.regiaoPrincipal?.id
                    ? regiao!.nome
                    : 'Maior risco agora',
                style: t.bodySmall,
                textAlign: TextAlign.end),
          ),
        ],
      ),
      const SizedBox(height: 8),
      Text('${regiao!.nome}: $frase',
          style: t.bodyLarge!.copyWith(fontSize: 16)),
      const SizedBox(height: 6),
      Text(fonte, style: t.bodySmall),
      if (cotas != null) ...[
        const SizedBox(height: 20),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              height: 230,
              width: 72,
              child: Regua(
                  cotas: cotas,
                  nivel: recente ? estacao!.nivel : null,
                  rio: estacao!.titulo),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(estacao!.titulo, style: t.titleSmall),
                  const SizedBox(height: 2),
                  Text('Estação ${estacao!.nome} · ANA ${estacao!.codigoAna}',
                      style: t.bodySmall),
                  const SizedBox(height: 14),
                  Text('Cotas oficiais', style: t.labelLarge),
                  linhaCota('Alerta', cotas.alerta, Severidade.medio),
                  linhaCota('Inundação', cotas.inundacao, Severidade.alto),
                  if (cotas.severa != null)
                    linhaCota(
                        'Inundação severa', cotas.severa!, Severidade.critico),
                  if (regiao!.areaKm2 != null) ...[
                    const SizedBox(height: 12),
                    Text('Município com ${regiao!.areaKm2!.round()} km²',
                        style: t.bodySmall),
                  ],
                ],
              ),
            ),
          ],
        ),
      ],
      const SizedBox(height: 16),
      if (alerta != null)
        SizedBox(
          width: double.infinity,
          child: FilledButton(
              onPressed: () => context.push('/alerts/${alerta.id}'),
              child: const Text('O que fazer')),
        )
      else if (!painel.seguidas.contains(regiao!.id))
        SizedBox(
          width: double.infinity,
          child: OutlinedButton(
            onPressed: () =>
                context.read<PainelCubit>().seguir(regiao!.id, seguir: true),
            child: const Text('Seguir região'),
          ),
        ),
      const SizedBox(height: 20),
      _BlocoSatelite(regiaoId: regiao!.id),
    ];
  }
}

// ---------------------------------------------------------------------------
// Água detectada por satélite (informação complementar ao alerta)
// ---------------------------------------------------------------------------

const _textoLimitacoes =
    'O radar só enxerga água aberta: rios, lagos e áreas alagadas sem mata. '
    'Várzea e igapó alagados debaixo da floresta não aparecem, então isto não '
    'é o tamanho total da cheia. Vento forte na hora da passagem também pode '
    'esconder água. O nível de alerta continua vindo só das cotas oficiais '
    'da ANA/SGB.';

/// "03/11/2026, 05:38": hora de Manaus (UTC−4, sem horário de verão).
String formatarHoraManaus(DateTime quando) {
  final m = quando.toUtc().subtract(const Duration(hours: 4));
  String dois(int n) => n.toString().padLeft(2, '0');
  return '${dois(m.day)}/${dois(m.month)}/${m.year}, '
      '${dois(m.hour)}:${dois(m.minute)}';
}

/// Área no padrão brasileiro: 1036.3 → "1.036"; 57.4 → "57,4"; 0.13 → "0,13".
String formatarKm2(double v) {
  if (v >= 100) {
    final s = v.round().toString();
    final b = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) b.write('.');
      b.write(s[i]);
    }
    return b.toString();
  }
  return v.toStringAsFixed(v >= 10 ? 1 : 2).replaceAll('.', ',');
}

class _BlocoSatelite extends StatelessWidget {
  const _BlocoSatelite({required this.regiaoId});
  final String regiaoId;

  @override
  Widget build(BuildContext context) {
    final c = AquaColors.of(context);
    final t = Theme.of(context).textTheme;
    final ligada =
        context.watch<CamadasCubit>().state.mostra(Camada.aguaSatelite);

    if (!ligada) {
      return Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: () =>
              context.read<CamadasCubit>().alternar(Camada.aguaSatelite),
          icon: const Icon(Icons.satellite_alt_outlined),
          label: const Text('Mostrar água detectada por satélite'),
        ),
      );
    }

    final dado = context.watch<SateliteCubit>().de(regiaoId);
    final obs = dado?.observacao;
    final titulo = Row(
      children: [
        Icon(Icons.satellite_alt_outlined, size: 20, color: c.tinta2),
        const SizedBox(width: 8),
        Expanded(
            child: Semantics(
                header: true, child: Text('Satélite', style: t.titleSmall))),
        if (obs != null && obs.desatualizada())
          Semantics(
            label: 'Observação desatualizada, com mais de 14 dias',
            excludeSemantics: true,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                border: Border.all(color: c.barro),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text('desatualizado',
                  style: t.labelSmall!.copyWith(color: c.barro)),
            ),
          ),
      ],
    );

    final List<Widget> corpo;
    switch (dado?.situacao) {
      case null:
      case SituacaoSatelite.carregando:
        corpo = [
          Text('Carregando a última passagem do satélite…', style: t.bodySmall)
        ];
      case SituacaoSatelite.erro:
        corpo = [
          Text('Não foi possível carregar a observação de satélite.',
              style: t.bodyMedium),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () => context
                  .read<SateliteCubit>()
                  .carregar(regiaoId, forcar: true),
              child: const Text('Tentar de novo'),
            ),
          ),
        ];
      case SituacaoSatelite.pronto when obs == null:
        corpo = [
          Text('Sem observação de satélite disponível para esta região ainda.',
              style: t.bodyMedium),
        ];
      case SituacaoSatelite.pronto:
        final o = obs!;
        final inundada = o.areaInundadaKm2;
        corpo = [
          Row(
            children: [
              const _AmostraSatelite(),
              const SizedBox(width: 8),
              Expanded(
                child: Text('Água aberta detectada por radar (Sentinel-1)',
                    style: t.bodyMedium),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
              'Passagem de ${formatarHoraManaus(o.observadoEm)} '
              '(hora de Manaus) · ${formatarHaQuanto(o.observadoEm)}',
              style: t.bodySmall),
          const SizedBox(height: 6),
          Text(
              '${formatarKm2(o.areaAguaKm2)} km² de água num quadrado de '
              '50 × 50 km em volta da estação.',
              style: t.bodyMedium),
          if (inundada != null && inundada >= 0.01)
            Text(
                '${formatarKm2(inundada)} km² fora do leito habitual '
                '(inundação, segundo o GFM).',
                style: t.bodySmall),
          if (o.excluidaPct != null && o.excluidaPct! >= 1)
            Text(
                'O radar não consegue avaliar ${o.excluidaPct!.round()}% '
                'dessa área (floresta densa, cidade, relevo).',
                style: t.bodySmall),
          const SizedBox(height: 6),
          Text(
              'Fonte: ${o.atribuicao ?? 'Copernicus Emergency Management Service — Global Flood Monitoring'}.',
              style: t.bodySmall),
        ];
    }

    return Semantics(
      container: true,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          border: Border.all(color: c.linha),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            titulo,
            const SizedBox(height: 8),
            ...corpo,
            const SizedBox(height: 10),
            Text('Limitações', style: t.labelLarge),
            const SizedBox(height: 2),
            Text(_textoLimitacoes, style: t.bodySmall),
          ],
        ),
      ),
    );
  }
}

class _AmostraSatelite extends StatelessWidget {
  const _AmostraSatelite();

  @override
  Widget build(BuildContext context) => Container(
        width: 16,
        height: 16,
        decoration: BoxDecoration(
          color: _aguaSateliteFundo,
          border: Border.all(color: _aguaSateliteBorda, width: 1.2),
          borderRadius: BorderRadius.circular(3),
        ),
      );
}

/// Legenda pequena no canto do mapa quando a camada de satélite está ligada.
class _LegendaSatelite extends StatelessWidget {
  const _LegendaSatelite({required this.dado, required this.temRegiao});
  final DadoSatelite? dado;
  final bool temRegiao;

  @override
  Widget build(BuildContext context) {
    final c = AquaColors.of(context);
    final t = Theme.of(context).textTheme;
    final obs = dado?.observacao;
    final detalhe = switch (dado?.situacao) {
      SituacaoSatelite.pronto when obs != null =>
        formatarHaQuanto(obs.observadoEm),
      SituacaoSatelite.pronto => 'sem dado nesta região',
      SituacaoSatelite.erro => 'não carregou',
      _ => temRegiao ? 'carregando…' : 'escolha uma região',
    };
    return Semantics(
      label:
          'Legenda: área azul é água aberta detectada por satélite, $detalhe',
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        constraints: const BoxConstraints(maxWidth: 220),
        decoration: BoxDecoration(
          color: c.papel.withValues(alpha: 0.94),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: c.linha),
          boxShadow: [BoxShadow(color: c.sombra, blurRadius: 8)],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const _AmostraSatelite(),
            const SizedBox(width: 8),
            Flexible(
              child: Text('Água por satélite · $detalhe',
                  style: t.labelSmall, overflow: TextOverflow.ellipsis),
            ),
          ],
        ),
      ),
    );
  }
}
