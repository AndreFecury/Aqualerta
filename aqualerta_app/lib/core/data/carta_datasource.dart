import 'package:flutter/foundation.dart' show debugPrint;
import 'package:latlong2/latlong.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:aqualerta/core/domain/ar.dart';
import 'package:aqualerta/core/domain/carta.dart';
import 'package:aqualerta/core/domain/severidade.dart';

/// Lê do Supabase tudo o que as telas da v3 mostram.
///
/// Usa as views de `supabase/migrations/20261115_v3_views.sql`. Se elas ainda
/// não existirem no banco, cai para as tabelas e views antigas, sem contornos
/// e sem estações, em vez de quebrar a tela.
class CartaDatasource {
  CartaDatasource([SupabaseClient? cliente])
      : _c = cliente ?? Supabase.instance.client;

  final SupabaseClient _c;

  /// `false` quando o banco ainda não tem as views da v3.
  bool viewsV3Disponiveis = true;

  double? _d(Object? v) => (v as num?)?.toDouble();

  Future<List<Regiao>> regioes() async {
    try {
      final linhas = await _c
          .from('v_regioes_mapa')
          .select(
              'id, name, state_code, municipality, area_km2, geojson, center_lat, center_lng')
          .order('name');
      return [
        for (final r in linhas)
          Regiao(
            id: r['id'] as String,
            nome: r['name'] as String,
            uf: r['state_code'] as String? ?? '',
            municipio: r['municipality'] as String?,
            areaKm2: _d(r['area_km2']),
            centro: (r['center_lat'] != null && r['center_lng'] != null)
                ? LatLng(_d(r['center_lat'])!, _d(r['center_lng'])!)
                : null,
            contornos: contornosDoGeoJson(r['geojson']),
          ),
      ];
    } on PostgrestException {
      viewsV3Disponiveis = false;
      final linhas = await _c
          .from('monitored_regions')
          .select('id, name, state_code, municipality, area_km2')
          .eq('is_public', true)
          .order('name');
      return [
        for (final r in linhas)
          Regiao(
            id: r['id'] as String,
            nome: r['name'] as String,
            uf: r['state_code'] as String? ?? '',
            municipio: r['municipality'] as String?,
            areaKm2: _d(r['area_km2']),
          ),
      ];
    }
  }

  Future<List<Evento>> eventos() async {
    try {
      final linhas = await _c
          .from('v_eventos_mapa')
          .select(
              'id, region_id, region_name, state_code, detected_at, severity, flooded_area_km2, area_real, geojson')
          .order('detected_at', ascending: false)
          .limit(200);
      return [
        for (final r in linhas)
          Evento(
            id: r['id'] as String,
            regiaoId: r['region_id'] as String,
            regiaoNome: '${r['region_name']}, ${r['state_code']}',
            detectadoEm: DateTime.parse(r['detected_at'] as String),
            severidade: Severidade.doCodigo(r['severity'] as String?),
            areaKm2: _d(r['flooded_area_km2']),
            areaReal: r['area_real'] as bool? ?? false,
            contornos: contornosDoGeoJson(r['geojson']),
          ),
      ];
    } on PostgrestException {
      viewsV3Disponiveis = false;
      // Corrige a consulta antiga, que pedia colunas inexistentes em flood_events.
      final linhas = await _c.from('v_recent_flood_events').select(
          'id, region_id, region_name, state_code, detected_at, severity, flooded_area_km2');
      return [
        for (final r in linhas)
          Evento(
            id: r['id'] as String,
            regiaoId: r['region_id'] as String,
            regiaoNome: '${r['region_name']}, ${r['state_code']}',
            detectadoEm: DateTime.parse(r['detected_at'] as String),
            severidade: Severidade.doCodigo(r['severity'] as String?),
            areaKm2: _d(r['flooded_area_km2']),
          ),
      ];
    }
  }

  Future<List<Estacao>> estacoes() async {
    try {
      final linhas = await _c.from('v_estacoes_nivel').select().order('name');
      return [
        for (final r in linhas)
          Estacao(
            id: r['id'] as String,
            codigoAna: r['ana_code'] as String,
            nome: r['name'] as String,
            rio: r['river'] as String?,
            posicao: (r['lat'] != null && r['lng'] != null)
                ? LatLng(_d(r['lat'])!, _d(r['lng'])!)
                : null,
            cotas: _cotas(r),
            nivel: _d(r['water_level_m']),
            lidoEm: r['recorded_at'] != null
                ? DateTime.parse(r['recorded_at'] as String)
                : null,
            nivel24h: _d(r['level_24h_m']),
          ),
      ];
    } on PostgrestException {
      viewsV3Disponiveis = false;
      return const [];
    }
  }

  CotasEstacao? _cotas(Map<String, dynamic> r) {
    final a = _d(r['alert_level_m']);
    final i = _d(r['flood_level_m']);
    final s = _d(r['emergency_level_m']);
    if (a == null || i == null || a > i) return null;
    return CotasEstacao(
        alerta: a, inundacao: i, severa: (s != null && s >= i) ? s : null);
  }

  /// Alertas ativos e os encerrados nos últimos 90 dias.
  Future<List<AlertaV3>> alertas() async {
    final desde =
        DateTime.now().subtract(const Duration(days: 90)).toIso8601String();
    final linhas = await _c
        .from('alerts')
        .select(
            'id, region_id, title, body, severity, status, issued_at, resolved_at, flood_event_id, metadata, '
            'monitored_regions!inner(name, state_code)')
        .or('status.eq.ACTIVE,issued_at.gte.$desde')
        .order('issued_at', ascending: false)
        .limit(200);
    return [
      for (final r in linhas)
        AlertaV3(
          id: r['id'] as String,
          regiaoId: r['region_id'] as String,
          regiaoNome:
              '${r['monitored_regions']['name']}, ${r['monitored_regions']['state_code']}',
          titulo: r['title'] as String,
          texto: r['body'] as String,
          severidadeOriginal: Severidade.doCodigo(r['severity'] as String?),
          ativo: r['status'] == 'ACTIVE',
          emitidoEm: DateTime.parse(r['issued_at'] as String),
          encerradoEm: r['resolved_at'] != null
              ? DateTime.parse(r['resolved_at'] as String)
              : null,
          eventoId: r['flood_event_id'] as String?,
          origem: (r['metadata'] as Map?)?['origem'] as String?,
        ),
    ];
  }

  /// Última coleta bem-sucedida dos pluviômetros do CEMADEN (tabela
  /// chuva_estado). `null` se a coleta ainda não existe no banco ou falhou.
  /// Avisos de ar pelo sensor: ativos e os encerrados nos últimos 90 dias.
  /// Sem a tabela (banco antigo) ou sem rede, lista vazia.
  Future<List<AvisoAr>> avisosAr() async {
    try {
      final desde = DateTime.now()
          .subtract(const Duration(days: 90))
          .toUtc()
          .toIso8601String();
      final linhas = await _c
          .from('ar_avisos')
          .select()
          .or('situacao.eq.ativo,inicio.gte.$desde')
          .order('inicio', ascending: false)
          .limit(100);
      return [for (final l in linhas) AvisoAr.doJson(l)];
    } catch (_) {
      return const [];
    }
  }

  Future<DateTime?> chuvaUltimaColeta() async {
    try {
      final r = await _c
          .from('chuva_estado')
          .select('ultima_coleta_ok')
          .maybeSingle();
      final v = r?['ultima_coleta_ok'] as String?;
      return v == null ? null : DateTime.parse(v);
    } catch (_) {
      return null;
    }
  }

  /// Regiões que o usuário segue (ids).
  Future<Set<String>> regioesSeguidas() async {
    final uid = _c.auth.currentUser?.id;
    if (uid == null) return {};
    final linhas = await _c
        .from('user_monitored_regions')
        .select('region_id')
        .eq('user_id', uid);
    return {for (final r in linhas) r['region_id'] as String};
  }

  Future<void> seguir(String regiaoId, {required bool seguir}) async {
    final uid = _c.auth.currentUser?.id;
    if (uid == null) return;
    if (seguir) {
      await _c
          .from('user_monitored_regions')
          .upsert({'user_id': uid, 'region_id': regiaoId});
    } else {
      await _c
          .from('user_monitored_regions')
          .delete()
          .eq('user_id', uid)
          .eq('region_id', regiaoId);
    }
  }

  /// Avisa quando alertas, eventos ou leituras mudam no banco.
  ///
  /// Ouve o sinal "mudou" do canal público `dados`, que o banco manda no
  /// máximo 1 vez por minuto (migração 20261121b_sinal_dados.sql), em vez de
  /// uma mensagem por linha alterada.
  /// [aoFalhar] é chamado quando a inscrição falha (ex.: token de login
  /// vencido ao abrir o app); [aoConectar], quando entra no canal.
  RealtimeChannel ouvirMudancas(void Function() aoMudar,
          {void Function()? aoFalhar, void Function()? aoConectar}) =>
      _c
          .channel('dados')
          .onBroadcast(
              event: 'mudou',
              callback: (_) {
                // Aparece no logcat (tag flutter): serve para conferir no aparelho.
                debugPrint('AquaAlerta: sinal "mudou" recebido');
                aoMudar();
              })
          .subscribe((estado, [erro]) {
        debugPrint(
            'AquaAlerta: canal dados $estado${erro == null ? '' : ' ($erro)'}');
        if (estado == RealtimeSubscribeStatus.subscribed) {
          aoConectar?.call();
        } else if (estado == RealtimeSubscribeStatus.channelError ||
            estado == RealtimeSubscribeStatus.timedOut) {
          aoFalhar?.call();
        }
      });

  /// Renova a sessão se o token de login já venceu (o app pode abrir depois
  /// de horas parado, antes da renovação automática).
  Future<void> renovarSessaoSeVencida() async {
    final s = _c.auth.currentSession;
    if (s != null && s.isExpired) await _c.auth.refreshSession();
  }

  /// Fecha o canal (app em segundo plano libera a conexão).
  Future<void> pararDeOuvir(RealtimeChannel canal) => _c.removeChannel(canal);
}
