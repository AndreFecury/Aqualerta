import 'package:flutter/material.dart';
import 'package:aqualerta/features/map/presentation/cubit/camadas_cubit.dart';

/// Endereços dos mapas de fundo.
///
/// Sem chave, o app usa serviços gratuitos que não exigem cadastro:
/// CARTO (carta, ruas e nomes), OpenTopoMap (terreno) e
/// EOX Sentinel-2 cloudless (satélite, CC BY-NC-SA 4.0).
/// Com a chave do MapTiler (`--dart-define=MAPTILER_KEY=...`), os mesmos
/// tipos passam a vir dele, com mais detalhe e sem limite de uso informal.
///
/// Não use tile.openstreetmap.org: a política dos servidores do OSM não
/// permite que aplicativos dependam deles.
class FundoMapa {
  const FundoMapa({
    required this.url,
    required this.atribuicao,
    this.subdominios = const [],
    this.retina = false,
    this.zoomMaximo = 19,
    this.sobreposicao,
  });

  final String url;
  final String atribuicao;
  final List<String> subdominios;
  final bool retina;
  final int zoomMaximo;

  /// Camada desenhada por cima (os nomes de lugares, no mapa híbrido).
  final FundoMapa? sobreposicao;

  static const _chaveDoBuild = String.fromEnvironment('MAPTILER_KEY');

  /// Só para testes: finge que o app foi compilado com uma chave.
  @visibleForTesting
  static String? chaveDeTeste;
  static String get _chave => chaveDeTeste ?? _chaveDoBuild;

  /// Desliga o mapa de fundo (usado nos testes, que não têm internet).
  static bool desligado = false;
  static bool get temMapTiler => _chave.isNotEmpty;

  // ---- Reserva: quando o MapTiler falha (rede que bloqueia
  // api.maptiler.com, cota estourada, chave revogada), o app usa os mapas
  // gratuitos por [tempoNaReserva] e depois tenta o MapTiler de novo.
  static DateTime? _reservaDesde;
  static Duration tempoNaReserva = const Duration(minutes: 15);

  static bool get usandoReserva =>
      _reservaDesde != null &&
      DateTime.now().difference(_reservaDesde!) < tempoNaReserva;

  /// O MapTiler está sendo usado agora (tem chave e não está na reserva).
  static bool get usaMapTiler => temMapTiler && !usandoReserva;

  static void trocarParaReserva() {
    _reservaDesde = DateTime.now();
    _falhasMapTiler.clear();
  }

  static final _falhasMapTiler = <DateTime>[];

  /// Conta um tile do MapTiler que falhou. Com 4 falhas em 10 s o app passa
  /// para os mapas gratuitos; devolve true quando essa troca acontece agora.
  static bool registrarFalhaDoMapTiler() {
    if (!usaMapTiler) return false;
    final agora = DateTime.now();
    _falhasMapTiler
      ..add(agora)
      ..removeWhere((t) => agora.difference(t) > const Duration(seconds: 10));
    if (_falhasMapTiler.length < 4) return false;
    trocarParaReserva();
    return true;
  }

  @visibleForTesting
  static void voltarAoMapTiler() {
    _reservaDesde = null;
    _falhasMapTiler.clear();
  }

  /// Este fundo vem do MapTiler (e precisa mostrar o logo dele).
  bool get ehMapTiler => url.contains('api.maptiler.com');

  static const _creditoCarto = '© CARTO © colaboradores do OpenStreetMap';
  static const _creditoMapTiler = '© MapTiler © colaboradores do OpenStreetMap';
  static const _creditoEox =
      'Sentinel-2 cloudless por EOX IT Services GmbH (dados Copernicus 2023)';

  /// Nomes de lugares em letras claras, para pôr sobre o satélite.
  static const _nomesSobreSatelite = FundoMapa(
    url:
        'https://{s}.basemaps.cartocdn.com/dark_only_labels/{z}/{x}/{y}{r}.png',
    subdominios: ['a', 'b', 'c', 'd'],
    retina: true,
    atribuicao: _creditoCarto,
  );

  static FundoMapa para(TipoMapa tipo, Brightness brilho) {
    final escuro = brilho == Brightness.dark;
    final efetivo = tipo == TipoMapa.automatico ? TipoMapa.carta : tipo;
    if (usaMapTiler) {
      final chave = _chave;
      return switch (efetivo) {
        TipoMapa.satelite => FundoMapa(
            url:
                'https://api.maptiler.com/tiles/satellite-v2/{z}/{x}/{y}.jpg?key=$chave',
            atribuicao: _creditoMapTiler,
            zoomMaximo: 20),
        TipoMapa.hibrido => FundoMapa(
            url:
                'https://api.maptiler.com/maps/hybrid/256/{z}/{x}/{y}.jpg?key=$chave',
            atribuicao: _creditoMapTiler,
            zoomMaximo: 20),
        TipoMapa.terreno => FundoMapa(
            url:
                'https://api.maptiler.com/maps/outdoor-v2/256/{z}/{x}/{y}.png?key=$chave',
            atribuicao: _creditoMapTiler),
        TipoMapa.ruas => FundoMapa(
            url:
                'https://api.maptiler.com/maps/streets-v2/256/{z}/{x}/{y}.png?key=$chave',
            atribuicao: _creditoMapTiler),
        _ => FundoMapa(
            url:
                'https://api.maptiler.com/maps/${escuro ? 'dataviz-dark' : 'dataviz'}/256/{z}/{x}/{y}.png?key=$chave',
            atribuicao: _creditoMapTiler),
      };
    }
    return switch (efetivo) {
      TipoMapa.satelite => const FundoMapa(
          url:
              'https://tiles.maps.eox.at/wmts/1.0.0/s2cloudless-2023_3857/default/g/{z}/{y}/{x}.jpg',
          atribuicao: _creditoEox,
          zoomMaximo: 15),
      TipoMapa.hibrido => const FundoMapa(
          url:
              'https://tiles.maps.eox.at/wmts/1.0.0/s2cloudless-2023_3857/default/g/{z}/{y}/{x}.jpg',
          atribuicao: '$_creditoEox. Nomes: $_creditoCarto',
          zoomMaximo: 15,
          sobreposicao: _nomesSobreSatelite),
      TipoMapa.terreno => const FundoMapa(
          url: 'https://{s}.tile.opentopomap.org/{z}/{x}/{y}.png',
          subdominios: ['a', 'b', 'c'],
          atribuicao:
              '© colaboradores do OpenStreetMap, SRTM | estilo © OpenTopoMap (CC-BY-SA)',
          zoomMaximo: 17),
      TipoMapa.ruas => const FundoMapa(
          url:
              'https://{s}.basemaps.cartocdn.com/rastertiles/voyager/{z}/{x}/{y}{r}.png',
          subdominios: ['a', 'b', 'c', 'd'],
          retina: true,
          atribuicao: _creditoCarto),
      _ => FundoMapa(
          url:
              'https://{s}.basemaps.cartocdn.com/${escuro ? 'dark_all' : 'light_all'}/{z}/{x}/{y}{r}.png',
          subdominios: const ['a', 'b', 'c', 'd'],
          retina: true,
          atribuicao: _creditoCarto),
    };
  }
}
