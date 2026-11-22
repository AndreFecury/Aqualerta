import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:aqualerta/core/domain/carta.dart';
import 'package:aqualerta/core/domain/severidade.dart';
import 'package:aqualerta/features/settings/presentation/cubit/notificacoes_cubit.dart';

/// Notificações do AquaAlerta.
///
/// Hoje: avisos locais disparados quando chega um alerta novo pelo Supabase
/// Realtime (com o app aberto ou em segundo plano recente).
/// Push com o app fechado: Firebase Cloud Messaging. O token do aparelho vai
/// para `user_profiles.fcm_token` (RPC `registrar_token_push`) e a Edge
/// Function `push-alertas` envia quando um alerta é criado ou muda de nível.
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
      final android = _local.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      await android?.createNotificationChannel(_canal);
      await android?.requestNotificationsPermission();
    } catch (e) {
      debugPrint('AquaAlerta: notificações locais indisponíveis ($e)');
    }
    await _iniciarPush();
  }

  String? _token;

  Future<void> _iniciarPush() async {
    try {
      // Lê android/app/google-services.json (projeto Firebase aqualerta-f1b77).
      await Firebase.initializeApp();
      final fcm = FirebaseMessaging.instance;
      await fcm.requestPermission();
      _token = await fcm.getToken();
      await _salvarToken();
      fcm.onTokenRefresh.listen((t) {
        _token = t;
        _salvarToken();
      });
      // Quem entrar na conta depois de abrir o app também passa a receber.
      Supabase.instance.client.auth.onAuthStateChange.listen((d) {
        if (d.event == AuthChangeEvent.signedIn) _salvarToken();
      });
      // Com o app aberto o Android não mostra o push sozinho. O id do aviso
      // é o do alerta, então o aviso local do Realtime e o push viram um só.
      FirebaseMessaging.onMessage.listen((m) {
        debugPrint('AquaAlerta: push recebido com o app aberto '
            '(alerta ${m.data['alert_id']})');
        final n = m.notification;
        if (n == null) return;
        final alertaId = m.data['alert_id'] as String?;
        final sev = Severidade.doCodigo(m.data['severity'] as String?);
        _mostrar(alertaId?.hashCode ?? m.hashCode, n.title ?? 'AquaAlerta',
            n.body ?? '', alertaId,
            som: sev >= Severidade.alto);
      });
      FirebaseMessaging.onMessageOpenedApp.listen(_abrir);
      // App estava fechado e foi aberto tocando no aviso.
      final inicial = await fcm.getInitialMessage();
      if (inicial != null) {
        // Espera a primeira tela existir antes de navegar.
        WidgetsBinding.instance.addPostFrameCallback((_) => _abrir(inicial));
        WidgetsBinding.instance.scheduleFrame();
      }
      pushAtivo = true;
    } catch (e) {
      // Firebase não configurado neste build: segue só com avisos locais.
      debugPrint('AquaAlerta: push desligado ($e)');
    }
  }

  void _abrir(RemoteMessage m) {
    final id = m.data['alert_id'] as String?;
    if (id != null && id.isNotEmpty) aoAbrirAlerta?.call(id);
  }

  Future<void> _salvarToken() async {
    final token = _token;
    final c = Supabase.instance.client;
    if (token == null || c.auth.currentUser == null) return;
    try {
      // Também tira este token de outra conta que já usou o aparelho.
      await c.rpc('registrar_token_push', params: {'p_token': token});
    } catch (e) {
      debugPrint('AquaAlerta: não foi possível salvar o token ($e)');
    }
  }

  /// Chamar antes de sair da conta: o aparelho para de receber os avisos dela.
  Future<void> esquecerAparelho() async {
    final c = Supabase.instance.client;
    if (c.auth.currentUser == null) return;
    try {
      await c.rpc('remover_token_push', params: {'p_token': _token});
    } catch (_) {
      // Sem internet: o servidor apaga o token quando o FCM recusar.
    }
  }

  /// Avisa sobre um alerta novo, respeitando as preferências.
  Future<void> avisar(AlertaV3 a, PreferenciasNotificacao prefs) async {
    if (!prefs.deveAvisar(a.severidade)) return;
    if (a.ehAr && !prefs.ar) return;
    await _mostrar(
      a.id.hashCode,
      a.ehAr
          ? (a.severidade == Severidade.critico
              ? 'Ar péssimo: evite sair de casa'
              : 'Ar muito ruim: proteja-se')
          : '${a.severidade.acao}: risco ${a.severidade.rotulo.toLowerCase()}',
      '${a.titulo} - ${a.regiaoNome}',
      a.id,
      som: prefs.som && a.severidade >= Severidade.alto,
    );
  }

  Future<void> _mostrar(int id, String titulo, String texto, String? alertaId,
      {required bool som}) async {
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
