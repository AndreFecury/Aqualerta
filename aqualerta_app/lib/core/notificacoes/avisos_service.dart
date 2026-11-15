import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:aqualerta/core/domain/carta.dart';
import 'package:aqualerta/core/domain/severidade.dart';
import 'package:aqualerta/features/settings/presentation/cubit/notificacoes_cubit.dart';

/// Notificações do AquaAlerta.
///
/// Hoje: avisos locais disparados quando chega um alerta novo pelo Supabase
/// Realtime (com o app aberto ou em segundo plano recente).
/// Push com o app fechado: liga sozinho quando o projeto Firebase estiver
/// configurado (`flutterfire configure`); o token é salvo em
/// `user_profiles.fcm_token` para o servidor enviar.
class AvisosService {
  AvisosService._();
  static final instancia = AvisosService._();

  final _local = FlutterLocalNotificationsPlugin();
  bool _iniciado = false;
  bool pushAtivo = false;

  /// Chamado quando a pessoa toca numa notificação (recebe o id do alerta).
  void Function(String alertaId)? aoAbrirAlerta;

  static const _canal = AndroidNotificationChannel(
    'aqualerta_alerts',
    'Alertas de cheia',
    description: 'Avisos de risco nas regiões que você segue',
    importance: Importance.high,
  );

  Future<void> iniciar() async {
    if (_iniciado || kIsWeb) return;
    _iniciado = true;
    try {
      await _local.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('@drawable/ic_notification'),
          iOS: DarwinInitializationSettings(),
        ),
        onDidReceiveNotificationResponse: (r) {
          final id = r.payload;
          if (id != null && id.isNotEmpty) aoAbrirAlerta?.call(id);
        },
      );
      final android = _local.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      await android?.createNotificationChannel(_canal);
      await android?.requestNotificationsPermission();
    } catch (e) {
      debugPrint('AquaAlerta: notificações locais indisponíveis ($e)');
    }
    await _iniciarPush();
  }

  Future<void> _iniciarPush() async {
    try {
      await Firebase.initializeApp();
      final fcm = FirebaseMessaging.instance;
      await fcm.requestPermission();
      final token = await fcm.getToken();
      await _salvarToken(token);
      fcm.onTokenRefresh.listen(_salvarToken);
      FirebaseMessaging.onMessage.listen((m) {
        final n = m.notification;
        if (n == null) return;
        _mostrar(m.hashCode, n.title ?? 'AquaAlerta', n.body ?? '', m.data['alert_id'] as String?, som: true);
      });
      FirebaseMessaging.onMessageOpenedApp.listen((m) {
        final id = m.data['alert_id'] as String?;
        if (id != null) aoAbrirAlerta?.call(id);
      });
      pushAtivo = true;
    } catch (e) {
      // Firebase ainda não configurado neste projeto: segue só com avisos locais.
      debugPrint('AquaAlerta: push desligado até configurar o Firebase ($e)');
    }
  }

  Future<void> _salvarToken(String? token) async {
    final c = Supabase.instance.client;
    final uid = c.auth.currentUser?.id;
    if (token == null || uid == null) return;
    try {
      await c.from('user_profiles').update({'fcm_token': token}).eq('id', uid);
    } catch (_) {}
  }

  /// Avisa sobre um alerta novo, respeitando as preferências.
  Future<void> avisar(AlertaV3 a, PreferenciasNotificacao prefs) async {
    if (!prefs.deveAvisar(a.severidade)) return;
    await _mostrar(
      a.id.hashCode,
      '${a.severidade.acao}: risco ${a.severidade.rotulo.toLowerCase()}',
      '${a.titulo} - ${a.regiaoNome}',
      a.id,
      som: prefs.som && a.severidade >= Severidade.alto,
    );
  }

  Future<void> _mostrar(int id, String titulo, String texto, String? alertaId, {required bool som}) async {
    if (kIsWeb) return;
    try {
      await _local.show(
        id: id,
        title: titulo,
        body: texto,
        payload: alertaId,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            _canal.id,
            _canal.name,
            channelDescription: _canal.description,
            importance: Importance.high,
            priority: Priority.high,
            playSound: som,
            category: AndroidNotificationCategory.alarm,
            styleInformation: BigTextStyleInformation(texto),
          ),
          iOS: DarwinNotificationDetails(presentSound: som),
        ),
      );
    } catch (e) {
      debugPrint('AquaAlerta: não foi possível mostrar o aviso ($e)');
    }
  }
}
