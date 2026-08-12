import 'package:flutter/foundation.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:unifiedpush/unifiedpush.dart';
import 'notification_service.dart';
import 'storage_service.dart';

const _pushProvider = String.fromEnvironment('PUSH_PROVIDER', defaultValue: 'unifiedpush');
const _useFcm = false;

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
    // Usa sempre UnifiedPush (FOSS)
    await initializeUnifiedPush();
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

    // Registrazione esplicita con il distributore già noto (es. ntfy).
    // Senza questa chiamata ntfy non riceve mai l'Intent e onNewEndpoint
    // non viene mai invocato → race condition / timeout.
    if (!_useFcm) {
      final distributor = await UnifiedPush.getDistributor();
      debugPrint('[PushService] initializeUnifiedPush(): distributore corrente="$distributor"');

      if (distributor != null && distributor.isNotEmpty) {
        // Distributore già selezionato: registra direttamente senza dialog
        debugPrint('[PushService] initializeUnifiedPush(): chiamo UnifiedPush.register() con distributore=$distributor');
        await UnifiedPush.register();
      } else {
        // Nessun distributore salvato: cerca quelli disponibili
        final distributors = await UnifiedPush.getDistributors();
        debugPrint('[PushService] initializeUnifiedPush(): distributori disponibili=$distributors');

        if (distributors.length == 1) {
          // Un solo distributore installato: selezionalo e registra automaticamente
          debugPrint('[PushService] initializeUnifiedPush(): seleziono automaticamente ${distributors.first}');
          await UnifiedPush.saveDistributor(distributors.first);
          await UnifiedPush.register();
        } else if (distributors.isNotEmpty) {
          // Più distributori: seleziona il primo (ntfy ha priorità se presente)
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

  // Quando viene generato un nuovo endpoint UnifiedPush
  Future<void> _onUnifiedPushEndpoint(PushEndpoint endpoint, String instance) async {
    final endpointUrl = endpoint.url;
    debugPrint('[PushService] onNewEndpoint: endpoint=$endpointUrl instance=$instance');
    _lastUpEndpoint = endpointUrl;
    _upEndpointController.add(endpointUrl);

    // Persisti sempre in SharedPreferences come cache resiliente:
    // garantisce che l'endpoint sopravviva anche se il profilo non è ancora
    // stato creato al momento del callback (race condition al primo avvio).
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_upEndpointPrefKey, endpointUrl);
      debugPrint('[PushService] onNewEndpoint: endpoint persistito in SharedPreferences');
    } catch (e) {
      debugPrint('[PushService] onNewEndpoint: errore salvataggio SharedPreferences: $e');
    }

    // Aggiorna anche il profilo se disponibile
    final profile = await _storageService.loadProfile();
    if (profile != null) {
      final updatedProfile = profile.copyWith(
        pushProvider: 'unifiedpush',
        pushToken: endpointUrl,
      );
      await _storageService.saveProfile(updatedProfile);
      debugPrint('[PushService] onNewEndpoint: profilo aggiornato con endpoint UP: $endpointUrl');
    } else {
      // Profilo non ancora creato: l'endpoint è già in SharedPreferences e in
      // _lastUpEndpoint. Quando il profilo verrà creato/salvato, il chiamante
      // dovrà includere pushToken = PushService().lastUpEndpoint.
      debugPrint('[PushService] onNewEndpoint: profilo non trovato — endpoint in cache SharedPreferences/$_upEndpointPrefKey');
    }
  }

  void _onUnifiedPushFailed(FailedReason reason, String instance) async {
    debugPrint('[PushService] Registrazione UnifiedPush fallita: ${reason.toString()}');
    // Nessun fallback FCM disponibile (FOSS)
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
