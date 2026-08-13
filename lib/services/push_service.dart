import 'package:flutter/foundation.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:unifiedpush/unifiedpush.dart';
import 'notification_service.dart';
import 'storage_service.dart';
import 'push/push_service_fcm.dart';

const _pushProvider = String.fromEnvironment('PUSH_PROVIDER', defaultValue: 'unifiedpush');

class PushService {
  static final PushService _instance = PushService._internal();
  factory PushService() => _instance;
  PushService._internal();

  final _notificationService = NotificationService();
  final _storageService = StorageService();

  bool _isUnifiedPushInitialized = false;

  // Esposto all'UI: true se UP ha fallito e non c'è fallback
  bool upFailed = false;

  // Stream che emette l'endpoint UnifiedPush ogni volta che viene (ri)generato
  final _upEndpointController = StreamController<String>.broadcast();
  Stream<String> get onUnifiedPushEndpoint => _upEndpointController.stream;

  // Ultimo endpoint UP noto (null finché onNewEndpoint non è stato chiamato)
  String? _lastUpEndpoint;
  String? get lastUpEndpoint => _lastUpEndpoint;

  /// Chiave SharedPreferences per la cache persistente dell'endpoint UP.
  static const String _upEndpointPrefKey = 'up_endpoint_cache';

  /// Restituisce l'endpoint UP da tutte le sorgenti disponibili:
  /// 1. cache in-memory (più veloce)
  /// 2. SharedPreferences (persistente tra riavvii)
  /// 3. profilo salvato
  Future<String?> getUpEndpoint() async {
    if (_lastUpEndpoint != null) return _lastUpEndpoint;
    final prefs = await SharedPreferences.getInstance();
    final cached = prefs.getString(_upEndpointPrefKey);
    if (cached != null && cached.isNotEmpty) {
      _lastUpEndpoint = cached; // popola la cache in-memory
      return cached;
    }
    final profile = await _storageService.loadProfile();
    return profile?.pushToken;
  }

  Future<void> initialize() async {
    final profile = await _storageService.loadProfile();
    
    // Determina il provider: dal profilo salvato, altrimenti dal flag di compilazione env
    final effectiveProvider = profile?.pushProvider ?? _pushProvider;

    if (effectiveProvider == 'fcm') {
      await PushServiceFCM().initialize();
    } else {
      await initializeUnifiedPush();
    }
  }

  /// Esegue lo switch runtime a FCM aggiornando il profilo e pulendo la cache UP
  Future<void> switchToFcm() async {
    // 1. Unregister da UnifiedPush e pulisci la cache locale UP
    try {
      await UnifiedPush.unregister();
      _lastUpEndpoint = null;
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_upEndpointPrefKey);
    } catch (e) {
      debugPrint('[PushService] Errore unregister UnifiedPush: $e');
    }

    // 2. Inizializza FCM
    final fcmService = PushServiceFCM();
    await fcmService.initialize();
    final fcmToken = await fcmService.getPushToken();

    // 3. Salva la preferenza FCM nel profilo
    final profile = await _storageService.loadProfile();
    if (profile != null && fcmToken != null) {
      final updatedProfile = profile.copyWith(
        pushProvider: 'fcm',
        pushToken: fcmToken,
      );
      await _storageService.saveProfile(updatedProfile);
      debugPrint('[PushService] Switch a FCM completato con token: $fcmToken');
    }
  }

  /// Esegue lo switch runtime a UnifiedPush aggiornando il profilo
  Future<void> switchToUnifiedPush(String distributor) async {
    await initializeUnifiedPush();
    await UnifiedPush.saveDistributor(distributor);
    await UnifiedPush.register();

    // Il callback _onUnifiedPushEndpoint provvederà ad aggiornare 
    // il profilo con pushProvider: 'unifiedpush' e il nuovo endpoint.
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

    // Registra con UP solo se il profilo salvato/effettivo non è impostato su FCM
    final profile = await _storageService.loadProfile();
    final effectiveProvider = profile?.pushProvider ?? _pushProvider;

    if (effectiveProvider != 'fcm') {
      final distributor = await UnifiedPush.getDistributor();
      debugPrint('[PushService] initializeUnifiedPush(): distributore corrente="$distributor"');

      if (distributor != null && distributor.isNotEmpty) {
        debugPrint('[PushService] initializeUnifiedPush(): chiamo UnifiedPush.register() con distributore=$distributor');
        await UnifiedPush.register();
      } else {
        final distributors = await UnifiedPush.getDistributors();
        debugPrint('[PushService] initializeUnifiedPush(): distributori disponibili=$distributors');

        if (distributors.length == 1) {
          debugPrint('[PushService] initializeUnifiedPush(): seleziono automaticamente ${distributors.first}');
          await UnifiedPush.saveDistributor(distributors.first);
          await UnifiedPush.register();
        } else if (distributors.isNotEmpty) {
          final preferred = distributors.firstWhere(
            (d) => d.contains('ntfy'),
            orElse: () => distributors.first,
          );
          debugPrint('[PushService] initializeUnifiedPush(): seleziono $preferred tra $distributors');
          await UnifiedPush.saveDistributor(preferred);
          await UnifiedPush.register();
        } else {
          debugPrint('[PushService] initializeUnifiedPush(): nessun distributore UP installato.');
        }
      }
    }
  }
 /// Restituisce il token push attivo (FCM o UP)
  Future<String?> getPushToken() async {
    final profile = await _storageService.loadProfile();
    final effectiveProvider = profile?.pushProvider ?? _pushProvider;

    if (effectiveProvider == 'fcm') {
      return await PushServiceFCM().getPushToken();
    } else {
      return await getUpEndpoint();
    }
  }
  // Quando viene generato un nuovo endpoint UnifiedPush
  Future<void> _onUnifiedPushEndpoint(PushEndpoint endpoint, String instance) async {
    final endpointUrl = endpoint.url;
    debugPrint('[PushService] onNewEndpoint: endpoint=$endpointUrl instance=$instance');
    _lastUpEndpoint = endpointUrl;
    _upEndpointController.add(endpointUrl);

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_upEndpointPrefKey, endpointUrl);
      debugPrint('[PushService] onNewEndpoint: endpoint persistito in SharedPreferences');
    } catch (e) {
      debugPrint('[PushService] onNewEndpoint: errore salvataggio SharedPreferences: $e');
    }

    final profile = await _storageService.loadProfile();
    if (profile != null) {
      final updatedProfile = profile.copyWith(
        pushProvider: 'unifiedpush',
        pushToken: endpointUrl,
      );
      await _storageService.saveProfile(updatedProfile);
      debugPrint('[PushService] onNewEndpoint: profilo aggiornato con endpoint UP: $endpointUrl');
    } else {
      debugPrint('[PushService] onNewEndpoint: profilo non trovato — endpoint in cache SharedPreferences/$_upEndpointPrefKey');
    }
  }

  void _onUnifiedPushFailed(FailedReason reason, String instance) async {
    debugPrint('[PushService] Registrazione UnifiedPush fallita: ${reason.toString()}');
    upFailed = true;
    await _notificationService.showNewMessageNotification(
      'system_no_push',
      'CatchMe — Notifiche non disponibili',
      'Installa ntfy (o un altro distributore UnifiedPush) per ricevere notifiche quando l\'app è chiusa.',
    );
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
