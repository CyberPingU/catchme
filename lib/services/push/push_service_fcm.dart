// ignore_for_file: uri_does_not_exist, undefined_identifier, undefined_class, depend_on_referenced_packages
// Implementazione FCM per Play Store
import 'package:flutter/foundation.dart';
import 'dart:convert';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:unifiedpush/unifiedpush.dart';
import 'push_service_interface.dart';
import '../notification_service.dart';
import '../storage_service.dart';

class PushServiceFCM implements PushServiceInterface {
  static final PushServiceFCM _instance = PushServiceFCM._internal();
  factory PushServiceFCM() => _instance;
  PushServiceFCM._internal();

  final _notificationService = NotificationService();
  final _storageService = StorageService();

  bool _isUnifiedPushInitialized = false;
  bool _upFailed = false;

  @override
  bool get upFailed => _upFailed;

  @override
  set upFailed(bool value) {
    _upFailed = value;
  }

  @override
  Future<void> initialize() async {
    await _setupFCM();
    final profile = await _storageService.loadProfile();
    if (profile != null && profile.pushProvider == 'unifiedpush') {
      await initializeUnifiedPush();
    }
  }

  @override
  Future<void> initializeUnifiedPush() async {
    if (_isUnifiedPushInitialized) return;
    _isUnifiedPushInitialized = true;

    UnifiedPush.initialize(
      onNewEndpoint: _onUnifiedPushEndpoint,
      onRegistrationFailed: _onUnifiedPushFailed,
      onUnregistered: _onUnifiedPushUnregistered,
      onMessage: _onUnifiedPushMessage,
    );

    // Registrazione automatica per UnifiedPush quando selezionato
    final profile = await _storageService.loadProfile();
    if (profile != null && profile.pushProvider == 'unifiedpush') {
      await UnifiedPush.register();
    }
  }

  Future<void> _setupFCM() async {
    final messaging = FirebaseMessaging.instance;

    // Richiedi permessi esplicitamente
    await messaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );

    // Mostra la notifica anche quando l'app è in primo piano
    await FirebaseMessaging.instance.setForegroundNotificationPresentationOptions(
      alert: true,
      badge: true,
      sound: true,
    );

    // Gestisci messaggi quando l'app è in background/terminata
    FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
      final payload = message.data['payload'];
      if (payload != null) {
        _handlePushPayload(payload);
      }
    });

    // Gestisci messaggi quando l'app è in primo piano
    FirebaseMessaging.onMessage.listen((RemoteMessage message) async {
      final payload = message.data['payload'];
      if (payload != null) {
        await _notificationService.showNotification(
          'Nuovo messaggio',
          'Hai ricevuto un nuovo messaggio',
          payload: payload,
        );
      }
    });

    // Gestisci messaggio iniziale (app lanciata da notifica)
    final initialMessage = await FirebaseMessaging.instance.getInitialMessage();
    if (initialMessage != null) {
      final payload = initialMessage.data['payload'];
      if (payload != null) {
        _handlePushPayload(payload);
      }
    }
  }

  @override
  Future<String?> getPushToken() async {
    try {
      return await FirebaseMessaging.instance.getToken();
    } catch (e) {
      debugPrint('Errore ottenimento token FCM: $e');
      return null;
    }
  }

  @override
  Future<void> subscribeToTopic(String topic) async {
    await FirebaseMessaging.instance.subscribeToTopic(topic);
  }

  @override
  Future<void> unsubscribeFromTopic(String topic) async {
    await FirebaseMessaging.instance.unsubscribeFromTopic(topic);
  }

  @override
  Future<void> deleteToken() async {
    await FirebaseMessaging.instance.deleteToken();
  }

  // Callback UnifiedPush — le firme devono essere void Function(...) per UP
  void _onUnifiedPushEndpoint(PushEndpoint endpoint, String instance) {
    debugPrint('[PushServiceFCM] Nuovo endpoint UnifiedPush: ${endpoint.url}');
  }

  void _onUnifiedPushFailed(FailedReason reason, String instance) {
    debugPrint('[PushServiceFCM] Registrazione UnifiedPush fallita: $reason');
    _upFailed = true;
  }

  void _onUnifiedPushUnregistered(String instance) {
    debugPrint('[PushServiceFCM] UnifiedPush deregistrato');
  }

  void _onUnifiedPushMessage(PushMessage message, String instance) {
    debugPrint('[PushServiceFCM] Messaggio UnifiedPush ricevuto');
    try {
      final raw = utf8.decode(message.content);
      final payload = jsonDecode(raw)['payload'];
      if (payload != null) {
        _notificationService.showNotification(
          'Nuovo messaggio',
          'Hai ricevuto un nuovo messaggio',
          payload: payload.toString(),
        );
      }
    } catch (e) {
      debugPrint('Errore parsing messaggio UnifiedPush: $e');
    }
  }

  void _handlePushPayload(String payload) {
    debugPrint('[PushServiceFCM] Payload ricevuto: $payload');
  }
}
