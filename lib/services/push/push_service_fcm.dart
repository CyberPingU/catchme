// Implementazione FCM per Play Store / Full
import 'package:flutter/foundation.dart';
import 'dart:convert';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:unifiedpush/unifiedpush.dart';
import 'push_service_interface.dart';
import '../notification_service.dart';
import '../storage_service.dart';

/// Handler di background top-level
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  final notificationService = NotificationService();
  final data = message.data;
  final payload = data['payload'];

  if (payload != null) {
    try {
      final decoded = json.decode(payload) as Map<String, dynamic>;
      final senderHash = decoded['senderHash'] as String? ?? '';
      final senderNickname = decoded['senderNickname'] as String? ?? 'Sconosciuto';
      final content = decoded['content'] as String? ?? '';

      await notificationService.showNewMessageNotification(
        senderHash,
        senderNickname,
        content,
      );
    } catch (_) {
      await notificationService.showNotification(
        'Nuovo messaggio',
        'Hai ricevuto un nuovo messaggio',
        payload: payload.toString(),
      );
    }
  }
}

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
    try {
      if (Firebase.apps.isEmpty) {
        await Firebase.initializeApp();
      }
    } catch (e) {
      debugPrint('[PushServiceFCM] Errore Firebase.initializeApp(): $e');
    }

    FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

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

    final profile = await _storageService.loadProfile();
    if (profile != null && profile.pushProvider == 'unifiedpush') {
      await UnifiedPush.register();
    }
  }

  Future<void> _setupFCM() async {
    final messaging = FirebaseMessaging.instance;

    await messaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );

    await FirebaseMessaging.instance.setForegroundNotificationPresentationOptions(
      alert: true,
      badge: true,
      sound: true,
    );

    try {
      final token = await messaging.getToken();
      debugPrint('[PushServiceFCM] Token FCM ottenuto: $token');
      if (token != null) {
        await _updateFcmTokenInProfile(token);
      }
    } catch (e) {
      debugPrint('[PushServiceFCM] Errore recupero token FCM: $e');
    }

    messaging.onTokenRefresh.listen((newToken) async {
      debugPrint('[PushServiceFCM] Token FCM rinnovato: $newToken');
      await _updateFcmTokenInProfile(newToken);
    });

    FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
      final payload = message.data['payload'];
      if (payload != null) {
        _handlePushPayload(payload);
      }
    });

    FirebaseMessaging.onMessage.listen((RemoteMessage message) async {
      final data = message.data;
      final payload = data['payload'];
      if (payload != null) {
        try {
          final decoded = json.decode(payload) as Map<String, dynamic>;
          final senderHash = decoded['senderHash'] as String? ?? '';
          final senderNickname = decoded['senderNickname'] as String? ?? 'Sconosciuto';
          final content = decoded['content'] as String? ?? '';

          await _notificationService.showNewMessageNotification(
            senderHash,
            senderNickname,
            content,
          );
        } catch (_) {
          await _notificationService.showNotification(
            'Nuovo messaggio',
            'Hai ricevuto un nuovo messaggio',
            payload: payload.toString(),
          );
        }
      }
    });

    final initialMessage = await FirebaseMessaging.instance.getInitialMessage();
    if (initialMessage != null) {
      final payload = initialMessage.data['payload'];
      if (payload != null) {
        _handlePushPayload(payload);
      }
    }
  }

  Future<void> _updateFcmTokenInProfile(String token) async {
    final profile = await _storageService.loadProfile();
    if (profile != null) {
      final updatedProfile = profile.copyWith(
        pushProvider: 'fcm',
        pushToken: token,
      );
      await _storageService.saveProfile(updatedProfile);
      debugPrint('[PushServiceFCM] Profilo salvato con token FCM: $token');
    }
  }

  @override
  Future<String?> getPushToken() async {
    try {
      if (Firebase.apps.isEmpty) {
        await Firebase.initializeApp();
      }
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
