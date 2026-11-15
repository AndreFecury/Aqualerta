import 'package:flutter/material.dart';
import 'package:aqualerta/features/map/presentation/cubit/camadas_cubit.dart';

/// Endereços dos mapas de fundo.
///
/// Sem chave, o app usa serviços gratuitos que não exigem cadastro:
/// CARTO (carta e ruas, uso não comercial com atribuição) e
/// EOX Sentinel-2 cloudless (satélite, CC BY-NC-SA 4.0).
/// Para publicar o app, crie uma conta gratuita no MapTiler e rode com
/// `--dart-define=MAPTILER_KEY=sua_chave`; os mesmos tipos passam a vir dele.
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
  });

  final String url;
  final String atribuicao;
  final List<String> subdominios;
  final bool retina;
  final int zoomMaximo;

  static const _chave = String.fromEnvironment('MAPTILER_KEY');

  /// Desliga o mapa de fundo (usado nos testes, que não têm internet).
  static bool desligado = false;
  static bool get temMapTiler => _chave.isNotEmpty;

  static FundoMapa para(TipoMapa tipo, Brightness brilho) {
    final escuro = brilho == Brightness.dark;
    final efetivo = tipo == TipoMapa.automatico ? TipoMapa.carta : tipo;
    if (temMapTiler) {
      const credito = '© MapTiler © colaboradores do OpenStreetMap';
      return switch (efetivo) {
        TipoMapa.satelite => const FundoMapa(
            url: 'https://api.maptiler.com/tiles/satellite-v2/{z}/{x}/{y}.jpg?key=$_chave',
            atribuicao: credito,
            zoomMaximo: 20),
        TipoMapa.ruas => const FundoMapa(
            url: 'https://api.maptiler.com/maps/streets-v2/{z}/{x}/{y}.png?key=$_chave', atribuicao: credito),
        _ => FundoMapa(
            url: 'https://api.maptiler.com/maps/${escuro ? 'dataviz-dark' : 'dataviz'}/{z}/{x}/{y}.png?key=$_chave',
            atribuicao: credito),
      };
    }
    const creditoCarto = '© CARTO © colaboradores do OpenStreetMap';
    return switch (efetivo) {
      TipoMapa.satelite => const FundoMapa(
          url: 'https://tiles.maps.eox.at/wmts/1.0.0/s2cloudless-2023_3857/default/g/{z}/{y}/{x}.jpg',
          atribuicao: 'Sentinel-2 cloudless por EOX IT Services GmbH (dados Copernicus 2023)',
          zoomMaximo: 15),
      TipoMapa.ruas => const FundoMapa(
          url: 'https://{s}.basemaps.cartocdn.com/rastertiles/voyager/{z}/{x}/{y}{r}.png',
          subdominios: ['a', 'b', 'c', 'd'],
          retina: true,
          atribuicao: creditoCarto),
      _ => FundoMapa(
          url: 'https://{s}.basemaps.cartocdn.com/${escuro ? 'dark_all' : 'light_all'}/{z}/{x}/{y}{r}.png',
          subdominios: const ['a', 'b', 'c', 'd'],
          retina: true,
          atribuicao: creditoCarto),
    };
  }
}
