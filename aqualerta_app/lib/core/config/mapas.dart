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

  static const _chave = String.fromEnvironment('MAPTILER_KEY');

  /// Desliga o mapa de fundo (usado nos testes, que não têm internet).
  static bool desligado = false;
  static bool get temMapTiler => _chave.isNotEmpty;

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
    if (temMapTiler) {
      return switch (efetivo) {
        TipoMapa.satelite => const FundoMapa(
            url:
                'https://api.maptiler.com/tiles/satellite-v2/{z}/{x}/{y}.jpg?key=$_chave',
            atribuicao: _creditoMapTiler,
            zoomMaximo: 20),
        TipoMapa.hibrido => const FundoMapa(
            url:
                'https://api.maptiler.com/maps/hybrid/256/{z}/{x}/{y}.jpg?key=$_chave',
            atribuicao: _creditoMapTiler,
            zoomMaximo: 20),
        TipoMapa.terreno => const FundoMapa(
            url:
                'https://api.maptiler.com/maps/outdoor-v2/256/{z}/{x}/{y}.webp?key=$_chave',
            atribuicao: _creditoMapTiler),
        TipoMapa.ruas => const FundoMapa(
            url:
                'https://api.maptiler.com/maps/streets-v2/256/{z}/{x}/{y}.webp?key=$_chave',
            atribuicao: _creditoMapTiler),
        _ => FundoMapa(
            url:
                'https://api.maptiler.com/maps/${escuro ? 'dataviz-dark' : 'dataviz'}/256/{z}/{x}/{y}.webp?key=$_chave',
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
