import 'package:flutter/foundation.dart';
import 'dart:convert';
import 'dart:io';
import 'package:unifiedpush/unifiedpush.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'notification_service.dart';
import 'storage_service.dart';

const _pushProvider = String.fromEnvironment('PUSH_PROVIDER', defaultValue: 'fcm');
const _useFcm = _pushProvider != 'unifiedpush';

class PushService {
  static final PushService _instance = PushService._internal();
  factory PushService() => _instance;
  PushService._internal();

  final _notificationService = NotificationService();
  final _storageService = StorageService();

  bool _isUnifiedPushInitialized = false;

  // Esposto all'UI: true se UP ha fallito e non c'è fallback
  bool upFailed = false;

  Future<void> initialize() async {
    if (_useFcm) await _setupFCM();
    final profile = await _storageService.loadProfile();
    // In build F-Droid forziamo sempre UnifiedPush, indipendentemente dalla preferenza salvata
    if (!_useFcm || (profile != null && profile.pushProvider == 'unifiedpush')) {
      await initializeUnifiedPush();
    }
  }

  // Registra i callback di UnifiedPush
  Future<void> initializeUnifiedPush() async {
    if (_isUnifiedPushInitialized) return;
    _isUnifiedPushInitialized = true;

    UnifiedPush.initialize(
      onNewEndpoint: _onUnifiedPushEndpoint,
      onRegistrationFailed: _onUnifiedPushFailed,
      onUnregistered: _onUnifiedPushUnregistered,
      onMessage: _onUnifiedPushMessage,
    );

    // Registrazione automatica per UnifiedPush nella build F-Droid
    if (!_useFcm) {
      await UnifiedPush.register();
    }
  }

  // Quando viene generato un nuovo endpoint UnifiedPush
  Future<void> _onUnifiedPushEndpoint(PushEndpoint endpoint, String instance) async {
    final endpointUrl = endpoint.url;
    debugPrint('[PushService] Nuovo endpoint UnifiedPush ricevuto: $endpointUrl');
    final profile = await _storageService.loadProfile();
    if (profile != null) {
      final updatedProfile = profile.copyWith(
        pushProvider: 'unifiedpush',
        pushToken: endpointUrl,
      );
      await _storageService.saveProfile(updatedProfile);
    }
  }

  void _onUnifiedPushFailed(FailedReason reason, String instance) async {
    debugPrint('[PushService] Registrazione UnifiedPush fallita: ${reason.toString()}');

    if (_useFcm) {
      // Build Play Store: torna su FCM automaticamente
      debugPrint('[PushService] Fallback automatico su FCM');
      final fcmToken = await getFCMToken();
      final profile = await _storageService.loadProfile();
      if (profile != null) {
        await _storageService.saveProfile(profile.copyWith(
          pushProvider: 'fcm',
          pushToken: fcmToken,
        ));
      }
      await _notificationService.showNewMessageNotification(
        'system_fallback',
        'CatchMe',
        'Nessun distributore UnifiedPush trovato. Passato automaticamente a FCM.',
      );
    } else {
      // Build F-Droid: nessun FCM disponibile, avvisa l'utente
      upFailed = true;
      await _notificationService.showNewMessageNotification(
        'system_no_push',
        'CatchMe — Notifiche non disponibili',
        'Installa ntfy (o un altro distributore UnifiedPush) per ricevere notifiche quando l\'app è chiusa.',
      );
    }
  }

  void _onUnifiedPushUnregistered(String instance) {
    debugPrint('[PushService] UnifiedPush de-registrato per $instance');
  }

  // Quando arriva un messaggio tramite UnifiedPush
  void _onUnifiedPushMessage(PushMessage message, String instance) async {
    try {
      final payloadStr = utf8.decode(message.content);
      debugPrint('[PushService] Messaggio UnifiedPush ricevuto: $payloadStr');
      final data = json.decode(payloadStr) as Map<String, dynamic>;
      
      final type = data['type'] as String?;
      if (type == 'message') {
        final senderHash = data['senderHash'] as String? ?? '';
        final senderNickname = data['senderNickname'] as String? ?? 'Sconosciuto';
        final content = data['content'] as String? ?? '';
        
        await _notificationService.showNewMessageNotification(
          senderHash,
          senderNickname,
          content,
        );
      }
    } catch (e) {
      debugPrint('[PushService] Errore parsing messaggio UnifiedPush: $e');
    }
  }

  Future<void> _setupFCM() async {
    if (!_useFcm) return;
    FirebaseMessaging.onMessage.listen((RemoteMessage message) async {
      debugPrint('[PushService] Messaggio FCM in primo piano: ${message.data}');
      final type = message.data['type'];
      if (type == 'message') {
        final senderHash = message.data['senderHash'] ?? '';
        final senderNickname = message.data['senderNickname'] ?? 'Sconosciuto';
        final content = message.data['content'] ?? '';
        await _notificationService.showNewMessageNotification(
          senderHash,
          senderNickname,
          content,
        );
      }
    });
  }

  // Ottiene il token FCM corrente (null nella build F-Droid)
  Future<String?> getFCMToken() async {
    if (!_useFcm) return null;
    try {
      return await FirebaseMessaging.instance.getToken();
    } catch (e) {
      debugPrint('[PushService] Errore recupero token FCM: $e');
      return null;
    }
  }

  // Abilita UnifiedPush (registra un distributore)
  Future<void> registerUnifiedPush(String distributor) async {
    await initializeUnifiedPush();
    await UnifiedPush.saveDistributor(distributor);
    await UnifiedPush.register();
  }

  // Rimuove la registrazione di UnifiedPush
  Future<void> unregisterUnifiedPush() async {
    await initializeUnifiedPush();
    await UnifiedPush.unregister();
  }

  // Restituisce il distributore salvato corrente
  Future<String?> getActiveDistributor() async {
    await initializeUnifiedPush();
    return await UnifiedPush.getDistributor();
  }

  // Restituisce la lista di distributori ntfy/Gotify installati sul device
  Future<List<String>> getUnifiedPushDistributors() async {
    await initializeUnifiedPush();
    return await UnifiedPush.getDistributors();
  }

  // Invia una notifica push di test (POST locale) per verificare la ricezione
  Future<bool> sendTestNotification(String endpointUrl) async {
    try {
      final client = HttpClient();
      final uri = Uri.parse(endpointUrl);
      final request = await client.postUrl(uri);

      final payloadBytes = utf8.encode(json.encode({
        'type': 'message',
        'senderHash': 'test_system',
        'senderNickname': 'CatchMe Test',
        'content': 'La tua configurazione UnifiedPush funziona alla perfezione! :tada:'
      }));

      request.headers.set('content-type', 'application/json; charset=utf-8');
      request.headers.set('content-length', payloadBytes.length.toString());
      request.add(payloadBytes);

      final response = await request.close();
      debugPrint('[PushService] Risposta test push: ${response.statusCode}');
      return response.statusCode >= 200 && response.statusCode < 300;
    } catch (e) {
      debugPrint('[PushService] Errore invio test push: $e');
      return false;
    }
  }
}
