import 'package:latlong2/latlong.dart';

/// Uma mancha de água detectada pelo radar: contorno externo e buracos
/// (ilhas secas dentro dela).
class AreaAgua {
  const AreaAgua(this.contorno, [this.buracos = const []]);
  final List<LatLng> contorno;
  final List<List<LatLng>> buracos;
}

/// Última passagem do satélite sobre uma região (Copernicus EMS — GFM,
/// Sentinel-1). Informação complementar: nunca muda o nível do alerta, que
/// vem só das cotas oficiais.
class ObservacaoSatelite {
  const ObservacaoSatelite({
    required this.regionId,
    required this.observadoEm,
    required this.areaAguaKm2,
    this.areaInundadaKm2,
    this.coberturaPct,
    this.excluidaPct,
    this.atribuicao,
    this.areas = const [],
  });

  final String regionId;

  /// Hora da passagem do satélite (não a hora em que o dado chegou aqui).
  final DateTime observadoEm;

  /// Água aberta no quadrado de 50 km em volta da estação (contagem de
  /// pixels de 40 m, mais precisa que o desenho simplificado).
  final double areaAguaKm2;

  /// Água fora do leito de referência do GFM (inundação), se houver.
  final double? areaInundadaKm2;

  /// Quanto do quadrado a passagem cobriu.
  final double? coberturaPct;

  /// Parte coberta que o radar não consegue avaliar (floresta densa, cidade,
  /// sombra de relevo).
  final double? excluidaPct;

  final String? atribuicao;
  final List<AreaAgua> areas;

  /// Passou disto, o cartão marca "desatualizado".
  static const validade = Duration(days: 14);

  Duration idade([DateTime? agora]) =>
      (agora ?? DateTime.now()).difference(observadoEm);

  bool desatualizada([DateTime? agora]) => idade(agora) > validade;

  /// Lê o retorno da RPC `satelite_geojson`: FeatureCollection com o membro
  /// extra `observacao` (os números). `null` quando a região ainda não tem
  /// observação. Aceita Polygon e MultiPolygon, com buracos.
  static ObservacaoSatelite? doGeoJson(Object? json) {
    if (json is! Map) return null;
    final o = json['observacao'];
    if (o is! Map) return null;
    final quando = DateTime.tryParse('${o['observado_em']}');
    final agua = _num(o['area_agua_km2']);
    if (quando == null || agua == null) return null;
    final areas = <AreaAgua>[];
    for (final f in (json['features'] as List? ?? const [])) {
      if (f is Map) areas.addAll(areasDaGeometria(f['geometry']));
    }
    return ObservacaoSatelite(
      regionId: '${o['region_id']}',
      observadoEm: quando,
      areaAguaKm2: agua,
      areaInundadaKm2: _num(o['area_inundada_km2']),
      coberturaPct: _num(o['cobertura_pct']),
      excluidaPct: _num(o['excluida_pct']),
      atribuicao: o['atribuicao'] as String?,
      areas: areas,
    );
  }
}

double? _num(Object? v) =>
    v is num ? v.toDouble() : (v is String ? double.tryParse(v) : null);

List<LatLng> _anel(Object? a) => [
      for (final p in (a as List? ?? const []))
        if (p is List && p.length >= 2)
          LatLng((p[1] as num).toDouble(), (p[0] as num).toDouble()),
    ];

AreaAgua? _poligono(Object? p) {
  if (p is! List || p.isEmpty) return null;
  final externo = _anel(p.first);
  if (externo.length < 3) return null;
  return AreaAgua(externo, [
    for (final b in p.skip(1))
      if (_anel(b).length >= 3) _anel(b),
  ]);
}

/// Polygon ou MultiPolygon do GeoJSON → manchas com buracos.
List<AreaAgua> areasDaGeometria(Object? g) {
  if (g is! Map) return const [];
  final coords = g['coordinates'];
  if (coords is! List) return const [];
  return switch (g['type']) {
    'Polygon' => [if (_poligono(coords) case final p?) p],
    'MultiPolygon' => [
        for (final p in coords)
          if (_poligono(p) case final a?) a
      ],
    _ => const [],
  };
}
