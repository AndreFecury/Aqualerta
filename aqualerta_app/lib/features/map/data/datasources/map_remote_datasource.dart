import 'package:aqualerta/features/map/domain/entities/flood_event.dart';
import 'package:aqualerta/core/network/supabase_service.dart';

class MapRemoteDatasource {
  final _client = SupabaseService.client;

  Future<List<FloodEvent>> getRecentFloodEvents({
    double? minLat,
    double? maxLat,
    double? minLng,
    double? maxLng,
    int hours = 72,
  }) async {
    var query = _client
        .from('flood_events')
        .select('''
          id, region_id, flooded_area_km2, severity, confidence,
          detected_at, satellite_type, geojson_path,
          center_lat, center_lng,
          monitored_regions!inner(name, state_code)
        ''')
        .gte(
          'detected_at',
          DateTime.now().subtract(Duration(hours: hours)).toIso8601String(),
        )
        .order('detected_at', ascending: false)
        .limit(100);

    final data = await query;

    return (data as List).map((row) {
      final region = row['monitored_regions'] as Map<String, dynamic>;
      return FloodEvent(
        id: row['id'] as String,
        regionId: row['region_id'] as String,
        regionName: '${region['name']} - ${region['state_code']}',
        detectedAt: DateTime.parse(row['detected_at'] as String),
        floodedAreaKm2: (row['flooded_area_km2'] as num).toDouble(),
        severity: row['severity'] as String,
        confidence: (row['confidence'] as num? ?? 0.8).toDouble(),
        centerLat: (row['center_lat'] as num?)?.toDouble(),
        centerLng: (row['center_lng'] as num?)?.toDouble(),
        geojsonPath: row['geojson_path'] as String?,
        satelliteType: row['satellite_type'] as String? ?? 'SENTINEL_1_SAR',
      );
    }).toList();
  }

  Stream<List<FloodEvent>> watchFloodEvents() {
    return _client
        .from('flood_events')
        .stream(primaryKey: ['id'])
        .order('detected_at', ascending: false)
        .limit(50)
        .map((rows) => rows.map((row) {
              return FloodEvent(
                id: row['id'] as String,
                regionId: row['region_id'] as String,
                regionName: row['region_name'] as String? ?? 'Região',
                detectedAt: DateTime.parse(row['detected_at'] as String),
                floodedAreaKm2: (row['flooded_area_km2'] as num).toDouble(),
                severity: row['severity'] as String,
                confidence: (row['confidence'] as num? ?? 0.8).toDouble(),
                centerLat: (row['center_lat'] as num?)?.toDouble(),
                centerLng: (row['center_lng'] as num?)?.toDouble(),
              );
            }).toList());
  }
}
