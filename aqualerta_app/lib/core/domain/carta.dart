import 'dart:math' as math;
import 'package:equatable/equatable.dart';
import 'package:latlong2/latlong.dart';
import 'severidade.dart';

/// Região monitorada (bairro, cidade ou trecho de rio).
class Regiao extends Equatable {
  const Regiao({
    required this.id,
    required this.nome,
    required this.uf,
    this.municipio,
    this.areaKm2,
    this.centro,
    this.contornos = const [],
  });

  final String id;
  final String nome;
  final String uf;
  final String? municipio;
  final double? areaKm2;
  final LatLng? centro;

  /// Anéis externos dos polígonos (vazio se o banco ainda não tem a view v3).
  final List<List<LatLng>> contornos;

  String get nomeCompleto => '$nome, $uf';

  @override
  List<Object?> get props => [id];
}

/// Evento de inundação registrado.
class Evento extends Equatable {
  const Evento({
    required this.id,
    required this.regiaoId,
    required this.regiaoNome,
    required this.detectadoEm,
    required this.severidade,
    this.areaKm2,
    this.contornos = const [],
    this.areaReal = false,
  });

  final String id;
  final String regiaoId;
  final String regiaoNome;
  final DateTime detectadoEm;
  final Severidade severidade;
  final double? areaKm2;
  final List<List<LatLng>> contornos;

  /// `true` quando o contorno é a área afetada medida; `false` quando é
  /// apenas o contorno da região (estimativa).
  final bool areaReal;

  @override
  List<Object?> get props => [id];
}

/// Estação hidrológica da ANA com a leitura mais recente.
class Estacao extends Equatable {
  const Estacao({
    required this.id,
    required this.codigoAna,
    required this.nome,
    this.rio,
    this.posicao,
    this.cotas,
    this.nivel,
    this.lidoEm,
  });

  final String id;
  final String codigoAna;
  final String nome;
  final String? rio;
  final LatLng? posicao;
  final CotasEstacao? cotas;
  final double? nivel;
  final DateTime? lidoEm;

  /// Leituras com mais de 2 dias não contam como "agora".
  static const validadeLeitura = Duration(hours: 48);

  bool leituraRecente([DateTime? agora]) =>
      nivel != null && lidoEm != null && (agora ?? DateTime.now()).difference(lidoEm!) <= validadeLeitura;

  /// Severidade pelas cotas (regra única do app). Nulo sem leitura recente.
  Severidade? severidade([DateTime? agora]) =>
      (cotas != null && leituraRecente(agora)) ? severidadePorCota(nivel!, cotas!) : null;

  String get titulo => rio ?? nome;

  @override
  List<Object?> get props => [id, nivel, lidoEm];
}

/// Alerta já com a severidade que o app mostra.
class AlertaV3 extends Equatable {
  const AlertaV3({
    required this.id,
    required this.regiaoId,
    required this.regiaoNome,
    required this.titulo,
    required this.texto,
    required this.severidadeOriginal,
    required this.ativo,
    required this.emitidoEm,
    this.encerradoEm,
    this.eventoId,
    this.estacao,
  });

  final String id;
  final String regiaoId;
  final String regiaoNome;
  final String titulo;
  final String texto;
  final Severidade severidadeOriginal;
  final bool ativo;
  final DateTime emitidoEm;
  final DateTime? encerradoEm;
  final String? eventoId;

  /// Estação mais próxima da região, quando conhecida.
  final Estacao? estacao;

  /// Pelas cotas da estação quando há leitura recente; senão, a do alerta.
  Severidade get severidade => estacao?.severidade() ?? severidadeOriginal;

  AlertaV3 comEstacao(Estacao? e) => AlertaV3(
        id: id,
        regiaoId: regiaoId,
        regiaoNome: regiaoNome,
        titulo: titulo,
        texto: texto,
        severidadeOriginal: severidadeOriginal,
        ativo: ativo,
        emitidoEm: emitidoEm,
        encerradoEm: encerradoEm,
        eventoId: eventoId,
        estacao: e,
      );

  @override
  List<Object?> get props => [id, ativo, estacao];
}

/// Lê os anéis externos de um GeoJSON Polygon ou MultiPolygon.
List<List<LatLng>> contornosDoGeoJson(Object? geojson) {
  if (geojson is! Map) return const [];
  final tipo = geojson['type'];
  final coords = geojson['coordinates'];
  List<LatLng> anel(Object? a) => [
        for (final p in (a as List? ?? const []))
          if (p is List && p.length >= 2) LatLng((p[1] as num).toDouble(), (p[0] as num).toDouble()),
      ];
  if (tipo == 'Polygon' && coords is List && coords.isNotEmpty) return [anel(coords.first)];
  if (tipo == 'MultiPolygon' && coords is List) {
    return [
      for (final poligono in coords)
        if (poligono is List && poligono.isNotEmpty) anel(poligono.first)
    ];
  }
  return const [];
}

/// Distância aproximada em km (fórmula de haversine).
double distanciaKm(LatLng a, LatLng b) {
  const r = 6371.0;
  double rad(double g) => g * math.pi / 180;
  final dLat = rad(b.latitude - a.latitude);
  final dLng = rad(b.longitude - a.longitude);
  final h = math.pow(math.sin(dLat / 2), 2) +
      math.cos(rad(a.latitude)) * math.cos(rad(b.latitude)) * math.pow(math.sin(dLng / 2), 2);
  return 2 * r * math.asin(math.sqrt(h));
}

/// Estação com coordenadas mais próxima de [ponto], até [raioKm].
Estacao? estacaoMaisProxima(LatLng? ponto, List<Estacao> estacoes, {double raioKm = 150}) {
  if (ponto == null) return null;
  Estacao? melhor;
  var menor = double.infinity;
  for (final e in estacoes) {
    if (e.posicao == null) continue;
    final d = distanciaKm(ponto, e.posicao!);
    if (d < menor) {
      menor = d;
      melhor = e;
    }
  }
  return menor <= raioKm ? melhor : null;
}
