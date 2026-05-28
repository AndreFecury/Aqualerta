import 'package:aqualerta/features/alerts/domain/entities/alert.dart';
import 'package:aqualerta/core/network/supabase_service.dart';

class AlertsRemoteDatasource {
  final _client = SupabaseService.client;

  Future<List<Alert>> getAlerts({
    String? severityFilter,
    String? statusFilter,
    int limit = 50,
  }) async {
    // Corrigido: .eq() só funciona em PostgrestFilterBuilder, não em
    // PostgrestTransformBuilder. Aplicar filtros ANTES do .select() com order/limit.
    var query = _client.from('alerts').select('''
        id, region_id, title, body, severity, status,
        issued_at, resolved_at, flood_event_id,
        monitored_regions!inner(name, state_code)
      ''');

    // Filtros aplicados no FilterBuilder (antes de order/limit)
    if (statusFilter != null) {
      query = query.eq('status', statusFilter);
    }
    if (severityFilter != null) {
      query = query.eq('severity', severityFilter);
    }

    final data = await query
        .order('issued_at', ascending: false)
        .limit(limit);

    return _parseAlerts(data as List);
  }

  Future<List<Alert>> getActiveAlerts() async {
    final data = await _client
        .from('alerts')
        .select('''
          id, region_id, title, body, severity, status,
          issued_at, resolved_at, flood_event_id,
          monitored_regions!inner(name, state_code)
        ''')
        .eq('status', 'ACTIVE')
        .order('issued_at', ascending: false);

    return _parseAlerts(data as List);
  }

  Future<void> acknowledgeAlert(String alertId) async {
    final userId = SupabaseService.currentUser?.id;
    if (userId == null) return;

    await _client.from('alert_deliveries').upsert({
      'alert_id': alertId,
      'user_id': userId,
      'delivered_via': 'APP',
      'acknowledged_at': DateTime.now().toIso8601String(),
    });
  }

  Stream<List<Alert>> watchActiveAlerts() {
    return _client
        .from('alerts')
        .stream(primaryKey: ['id'])
        .eq('status', 'ACTIVE')
        .order('issued_at', ascending: false)
        .limit(20)
        .map((rows) => rows
            .map((row) => Alert(
                  id: row['id'] as String,
                  regionId: row['region_id'] as String,
                  regionName: row['region_name'] as String? ?? 'Região',
                  title: row['title'] as String,
                  body: row['body'] as String,
                  severity: row['severity'] as String,
                  status: row['status'] as String,
                  issuedAt: DateTime.parse(row['issued_at'] as String),
                ))
            .toList());
  }

  List<Alert> _parseAlerts(List rows) {
    return rows.map((row) {
      final region = row['monitored_regions'] as Map<String, dynamic>;
      return Alert(
        id: row['id'] as String,
        regionId: row['region_id'] as String,
        regionName: '${region['name']} - ${region['state_code']}',
        title: row['title'] as String,
        body: row['body'] as String,
        severity: row['severity'] as String,
        status: row['status'] as String,
        issuedAt: DateTime.parse(row['issued_at'] as String),
        resolvedAt: row['resolved_at'] != null
            ? DateTime.parse(row['resolved_at'] as String)
            : null,
        floodEventId: row['flood_event_id'] as String?,
      );
    }).toList();
  }
}
