import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  final FlutterLocalNotificationsPlugin _notifications = FlutterLocalNotificationsPlugin();

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
  }

  Future<void> showForegroundNotification() async {
    const androidDetails = AndroidNotificationDetails(
      'catchme_foreground',
      'Servizio Attivo',
      channelDescription: 'Scansione Bluetooth attiva',
      importance: Importance.low,
      priority: Priority.low,
      ongoing: true,
      autoCancel: false,
    );

    const details = NotificationDetails(android: androidDetails);

    await _notifications.show(
      1,
      'CatchMe',
      'Scansione utenti vicini attiva',
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

  Future<void> cancelForegroundNotification() async {
    await _notifications.cancel(1);
  }
}
