import 'dart:convert';

import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:aqualerta/core/domain/carta.dart';

/// Guarda no aparelho os municípios monitorados com os contornos (a parte
/// mais pesada do que o app baixa, ~48 KB, e que quase nunca muda).
///
/// * Até [validade] depois de baixar, usa o que está guardado sem ir ao
///   servidor: o app abre mais rápido e o Supabase serve menos dados.
/// * Sem internet, usa o guardado mesmo vencido (melhor que mapa vazio numa
///   cheia).
class CacheRegioes {
  CacheRegioes({SharedPreferences? prefs, DateTime Function()? agora})
      : _prefs = prefs,
        _agora = agora ?? DateTime.now;

  static const chave = 'regioes_v1';
  static const validade = Duration(hours: 24);

  SharedPreferences? _prefs;
  final DateTime Function() _agora;

  Future<SharedPreferences> get _p async =>
      _prefs ??= await SharedPreferences.getInstance();

  /// Regiões guardadas e ainda válidas; senão busca com [buscar] e guarda.
  /// [forcar] ignora a validade (puxar para atualizar).
  Future<List<Regiao>> obter(Future<List<Regiao>> Function() buscar,
      {bool forcar = false}) async {
    final guardado = await _ler();
    if (!forcar &&
        guardado != null &&
        _agora().difference(guardado.$1) < validade &&
        guardado.$2.isNotEmpty) {
      return guardado.$2;
    }
    try {
      final novas = await buscar();
      // Lista vazia (banco ainda sem regiões) não substitui o que havia.
      if (novas.isNotEmpty) await _gravar(novas);
      return novas.isNotEmpty ? novas : (guardado?.$2 ?? novas);
    } catch (_) {
      if (guardado != null && guardado.$2.isNotEmpty) return guardado.$2;
      rethrow;
    }
  }

  Future<(DateTime, List<Regiao>)?> _ler() async {
    try {
      final texto = (await _p).getString(chave);
      if (texto == null) return null;
      final j = jsonDecode(texto) as Map<String, dynamic>;
      return (
        DateTime.parse(j['em'] as String),
        [
          for (final r in j['regioes'] as List)
            _regiao(r as Map<String, dynamic>)
        ],
      );
    } catch (_) {
      return null; // formato antigo ou corrompido: baixa de novo
    }
  }

  Future<void> _gravar(List<Regiao> regioes) async {
    try {
      await (await _p).setString(
          chave,
          jsonEncode({
            'em': _agora().toIso8601String(),
            'regioes': [for (final r in regioes) _json(r)],
          }));
    } catch (_) {
      // Sem espaço ou sem preferências: segue sem cache.
    }
  }

  // Coordenadas com 5 casas (~1 m): suficiente para o contorno no mapa.
  static double _r(double v) => (v * 1e5).roundToDouble() / 1e5;

  static Map<String, dynamic> _json(Regiao r) => {
        'id': r.id,
        'nome': r.nome,
        'uf': r.uf,
        'municipio': r.municipio,
        'area': r.areaKm2,
        'centro': r.centro == null
            ? null
            : [_r(r.centro!.latitude), _r(r.centro!.longitude)],
        'contornos': [
          for (final anel in r.contornos)
            [
              for (final p in anel) [_r(p.latitude), _r(p.longitude)]
            ]
        ],
      };

  static LatLng _p2(List p) =>
      LatLng((p[0] as num).toDouble(), (p[1] as num).toDouble());

  static Regiao _regiao(Map<String, dynamic> j) => Regiao(
        id: j['id'] as String,
        nome: j['nome'] as String,
        uf: j['uf'] as String,
        municipio: j['municipio'] as String?,
        areaKm2: (j['area'] as num?)?.toDouble(),
        centro: j['centro'] == null ? null : _p2(j['centro'] as List),
        contornos: [
          for (final anel in j['contornos'] as List)
            [for (final p in anel as List) _p2(p as List)]
        ],
      );
}
