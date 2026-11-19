import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:aqualerta/core/domain/satelite.dart';

/// De onde vem a última observação de satélite de uma região.
abstract class FonteSatelite {
  /// `null` quando a região ainda não tem observação. Lança em erro de rede.
  Future<ObservacaoSatelite?> ultima(String regionId);
}

/// Lê a RPC `satelite_geojson` (supabase/migrations/20261118_satelite.sql),
/// preenchida pela Edge Function `satelite-ingest` com dados reais do
/// Copernicus EMS — GFM. Nada é inventado aqui: sem linha no banco, `null`.
class SateliteRepository implements FonteSatelite {
  SateliteRepository([SupabaseClient? cliente]) : _cliente = cliente;

  final SupabaseClient? _cliente;

  // Só pega o cliente na hora da consulta: a camada nasce desligada.
  SupabaseClient get _c => _cliente ?? Supabase.instance.client;

  @override
  Future<ObservacaoSatelite?> ultima(String regionId) async {
    final json =
        await _c.rpc('satelite_geojson', params: {'p_region': regionId});
    return ObservacaoSatelite.doGeoJson(json);
  }
}
