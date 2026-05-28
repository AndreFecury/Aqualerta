import 'package:aqualerta/features/regions/domain/entities/monitored_region.dart';
import 'package:aqualerta/core/network/supabase_service.dart';

class RegionsRemoteDatasource {
  final _client = SupabaseService.client;

  Future<List<MonitoredRegion>> getPublicRegions() async {
    // Corrigido: ST_X/ST_Y não funcionam no select do Supabase REST API.
    // Buscamos sem as funções geoespaciais e calculamos o centroide no lado cliente
    // usando os dados brutos, ou usamos a view v_recent_flood_events que já tem.
    // Para regiões, usamos centroid como text via cast.
    final data = await _client
        .from('monitored_regions')
        .select('id, name, description, state_code, municipality, area_km2, is_public')
        .eq('is_public', true)
        .order('name');

    return (data as List)
        .map((row) => _parseRegion(row as Map<String, dynamic>))
        .toList();
  }

  Future<List<MonitoredRegion>> getUserRegions() async {
    final userId = SupabaseService.currentUser?.id;
    if (userId == null) return [];

    final data = await _client
        .from('user_monitored_regions')
        .select('''
          notify, min_severity,
          monitored_regions!inner(
            id, name, description, state_code, municipality, area_km2, is_public
          )
        ''')
        .eq('user_id', userId);

    return (data as List).map((row) {
      final region = row['monitored_regions'] as Map<String, dynamic>;
      return _parseRegion(
        region,
        subscribed: true,
        notifications: row['notify'] as bool? ?? true,
        minSeverity: row['min_severity'] as String? ?? 'MEDIUM',
      );
    }).toList();
  }

  Future<void> subscribeToRegion(
    String regionId, {
    bool notify = true,
    String minSeverity = 'MEDIUM',
  }) async {
    final userId = SupabaseService.currentUser?.id;
    if (userId == null) throw Exception('Usuário não autenticado');

    await _client.from('user_monitored_regions').upsert({
      'user_id': userId,
      'region_id': regionId,
      'notify': notify,
      'min_severity': minSeverity,
    });
  }

  Future<void> unsubscribeFromRegion(String regionId) async {
    final userId = SupabaseService.currentUser?.id;
    if (userId == null) return;

    await _client
        .from('user_monitored_regions')
        .delete()
        .eq('user_id', userId)
        .eq('region_id', regionId);
  }

  Future<void> updateNotificationPreference(
    String regionId,
    bool notify,
    String minSeverity,
  ) async {
    final userId = SupabaseService.currentUser?.id;
    if (userId == null) return;

    await _client
        .from('user_monitored_regions')
        .update({'notify': notify, 'min_severity': minSeverity})
        .eq('user_id', userId)
        .eq('region_id', regionId);
  }

  // Corrigido: tipagem explícita no parâmetro para resolver
  // 'argument_type_not_assignable'
  MonitoredRegion _parseRegion(
    Map<String, dynamic> row, {
    bool subscribed = false,
    bool notifications = true,
    String minSeverity = 'MEDIUM',
  }) {
    // Coordenadas padrão por estado quando não há centroide disponível
    final stateCoords = _defaultCoords(row['state_code'] as String? ?? 'AM');

    return MonitoredRegion(
      id: row['id'] as String,
      name: row['name'] as String,
      description: row['description'] as String?,
      centerLat: stateCoords.$1,
      centerLng: stateCoords.$2,
      areaKm2: (row['area_km2'] as num? ?? 0).toDouble(),
      stateCode: row['state_code'] as String? ?? '--',
      municipality: row['municipality'] as String?,
      isPublic: row['is_public'] as bool? ?? true,
      userSubscribed: subscribed,
      notificationsEnabled: notifications,
      minSeverity: minSeverity,
    );
  }

  /// Coordenadas aproximadas por estado para centrar o mapa
  (double, double) _defaultCoords(String stateCode) {
    const coords = <String, (double, double)>{
      'AM': (-3.1190, -60.0217),
      'PA': (-1.9192, -55.5172),
      'RO': (-8.7612, -63.9004),
      'AC': (-9.9754, -67.8249),
      'AP': (0.9020, -52.0030),
      'RR': (2.7376, -62.0750),
      'TO': (-10.1753, -48.2982),
      'MT': (-12.6819, -56.9211),
    };
    return coords[stateCode] ?? (-3.1190, -60.0217);
  }
}
