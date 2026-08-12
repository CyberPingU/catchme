import 'dart:io';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  final FlutterLocalNotificationsPlugin _notifications = FlutterLocalNotificationsPlugin();

  /// ID del canale usato dal Foreground Service (deve corrispondere a
  /// AndroidConfiguration.notificationChannelId in main.dart).
  static const String foregroundChannelId = 'catchme_foreground_service';

  Future<void> initialize({Function(String?)? onNotificationClick}) async {
    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosSettings = DarwinInitializationSettings();
    const settings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
    );

    await _notifications.initialize(
      settings,
      onDidReceiveNotificationResponse: (NotificationResponse response) {
        if (onNotificationClick != null) {
          onNotificationClick(response.payload);
        }
      },
    );

    // Crea il canale del Foreground Service subito dopo l'inizializzazione,
    // prima che flutter_background_service tenti di postare la notifica.
    // Su Android 14/15 il canale DEVE esistere prima di startForeground().
    if (Platform.isAndroid) {
      await _createForegroundServiceChannel();
    }
  }

  /// Crea (o aggiorna) il Notification Channel per il Foreground Service.
  /// Idempotente: Android ignora la chiamata se il canale esiste già.
  Future<void> _createForegroundServiceChannel() async {
    final androidPlugin = _notifications
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    if (androidPlugin == null) return;

    const channel = AndroidNotificationChannel(
      foregroundChannelId,           // ID — deve corrispondere ad AndroidConfiguration
      'CatchMe — Servizio Attivo',   // nome visibile nelle impostazioni Android
      description: 'Mantiene attivo il tracciamento GPS in background',
      importance: Importance.low,    // low = nessun suono, barra di stato silenziosa
      playSound: false,
      enableVibration: false,
      showBadge: false,
    );

    await androidPlugin.createNotificationChannel(channel);
  }

  Future<void> showForegroundNotification() async {
    // Usa lo stesso channelId del Foreground Service per evitare
    // CannotPostForegroundServiceNotificationException su Android 14/15.
    final androidDetails = AndroidNotificationDetails(
      foregroundChannelId,           // ← stesso ID di AndroidConfiguration
      'CatchMe — Servizio Attivo',
      channelDescription: 'Mantiene attivo il tracciamento GPS in background',
      importance: Importance.low,
      priority: Priority.low,
      ongoing: true,
      autoCancel: false,
      icon: '@mipmap/ic_launcher',   // icona esplicita — mai null
      playSound: false,
      enableVibration: false,
    );

    final details = NotificationDetails(android: androidDetails);

    await _notifications.show(
      888,   // stesso ID di foregroundServiceNotificationId
      'CatchMe in esecuzione',
      'Tracciamento GPS attivo',
      details,
    );
  }

  Future<void> showNewUserNotification(String nickname) async {
    const androidDetails = AndroidNotificationDetails(
      'catchme_users',
      'Nuovi Utenti',
      channelDescription: 'Notifiche per nuovi utenti vicini',
      importance: Importance.high,
      priority: Priority.high,
    );

    const details = NotificationDetails(android: androidDetails);

    await _notifications.show(
      DateTime.now().millisecondsSinceEpoch % 100000,
      'Nuovo utente vicino',
      '$nickname è nelle vicinanze',
      details,
    );
  }

  Future<void> showProximityAlertNotification(String nickname) async {
    const androidDetails = AndroidNotificationDetails(
      'catchme_proximity',
      'Avvisi Prossimità',
      channelDescription: 'Notifiche quando i contatti preferiti sono vicini',
      importance: Importance.high,
      priority: Priority.high,
    );

    const details = NotificationDetails(android: androidDetails);

    await _notifications.show(
      DateTime.now().millisecondsSinceEpoch % 100000,
      'Contatto nelle vicinanze',
      '$nickname è ora vicino a te!',
      details,
    );
  }

  Future<void> showProximityExitNotification(String nickname) async {
    const androidDetails = AndroidNotificationDetails(
      'catchme_proximity',
      'Avvisi Prossimità',
      channelDescription: 'Notifiche quando i contatti preferiti si allontanano',
      importance: Importance.high,
      priority: Priority.high,
    );

    const details = NotificationDetails(android: androidDetails);

    await _notifications.show(
      (DateTime.now().millisecondsSinceEpoch % 100000) + 1,
      'Contatto allontanato',
      '$nickname non si trova più nei paraggi',
      details,
    );
  }

  Future<void> showConnectionRequestNotification(String nickname) async {
    const androidDetails = AndroidNotificationDetails(
      'catchme_requests',
      'Richieste Connessione',
      channelDescription: 'Notifiche per richieste di connessione',
      importance: Importance.high,
      priority: Priority.high,
    );

    const details = NotificationDetails(android: androidDetails);

    await _notifications.show(
      DateTime.now().millisecondsSinceEpoch % 100000,
      'Richiesta di connessione',
      '$nickname vuole connettersi',
      details,
    );
  }

  Future<void> showNewMessageNotification(String senderHash, String senderNickname, String message) async {
    const androidDetails = AndroidNotificationDetails(
      'catchme_messages',
      'Messaggi',
      channelDescription: 'Notifiche per nuovi messaggi',
      importance: Importance.high,
      priority: Priority.high,
    );

    const details = NotificationDetails(android: androidDetails);

    await _notifications.show(
      DateTime.now().millisecondsSinceEpoch % 100000,
      'Nuovo messaggio da $senderNickname',
      message,
      details,
      payload: senderHash,
    );
  }

  /// Metodo generico per mostrare una notifica locale (usato da push service)
  Future<void> showNotification(String title, String body, {String? payload}) async {
    const androidDetails = AndroidNotificationDetails(
      'catchme_push',
      'Push Notifications',
      channelDescription: 'Notifiche push ricevute',
      importance: Importance.high,
      priority: Priority.high,
    );
    const details = NotificationDetails(android: androidDetails);
    await _notifications.show(
      DateTime.now().millisecondsSinceEpoch % 100000,
      title,
      body,
      details,
      payload: payload,
    );
  }

  Future<void> cancelForegroundNotification() async {
    await _notifications.cancel(1);
  }
}
