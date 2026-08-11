import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'dart:io';
import 'package:image/image.dart' as img;
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../models/nearby_user.dart';
import '../models/chat_message.dart';
import '../models/contact.dart';
import '../models/user_profile.dart';
import 'crypto_service.dart';
import 'storage_service.dart';
import 'notification_service.dart';
import 'package:permission_handler/permission_handler.dart';
import 'push_service.dart';


class ProximityService {
  static final ProximityService _instance = ProximityService._internal();
  factory ProximityService() => _instance;
  ProximityService._internal();

  final _cryptoService = CryptoService();
  final _storageService = StorageService();
  final _notificationService = NotificationService();

  WebSocketChannel? _channel;
  bool _isConnected = false;
  bool get isConnected => _isConnected;
  
  final _discoveredUsersController = StreamController<List<NearbyUser>>.broadcast();
  Stream<List<NearbyUser>> get discoveredUsers => _discoveredUsersController.stream;

  final _connectionRequestController = StreamController<ConnectionRequest>.broadcast();
  Stream<ConnectionRequest> get connectionRequests => _connectionRequestController.stream;

  final _messageController = StreamController<ChatMessage>.broadcast();
  Stream<ChatMessage> get messages => _messageController.stream;

  final Map<String, NearbyUser> _nearbyUsers = {};
  final Set<String> _connectedEndpoints = {};
  final Set<String> _notifiedProximityHashes = {};
  UserProfile? _currentProfile;
  String? _activeChatPublicKey;
  
  static const String _serverUrl = 'wss://catchme.dreadful.work';
  Timer? _gpsTimer;
  Timer? _reconnectTimer;
  bool _isInBackground = false;

  Future<void> initialize() async {
    await _cryptoService.initialize();
  }

  Set<String> get connectedEndpoints => _connectedEndpoints;

  Future<bool> requestPermissions() async {
    final notificationStatus = await Permission.notification.request();
    
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    
    if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
      debugPrint('[DEBUG-CATCHME] Permessi posizione negati: $permission');
      return false;
    }
    
    final notificationsGranted = notificationStatus.isGranted;
    debugPrint('[DEBUG-CATCHME] Risultati permessi: posizione=$permission, notifiche=$notificationsGranted');
    
    return notificationsGranted;
  }

  void connectToServer() {
    if (_channel != null) {
      debugPrint('[DEBUG-CATCHME] connectToServer(): canale già aperto, skip.');
      return;
    }

    const url = _serverUrl;
    debugPrint('[DEBUG-CATCHME] connectToServer(): avvio connessione a $url ...');
    try {
      _reconnectTimer?.cancel();
      _channel = WebSocketChannel.connect(Uri.parse(url));
      _isConnected = true;
      _notifyUsersUpdate();
      debugPrint('[DEBUG-CATCHME] connectToServer(): WebSocket creato, in attesa di dati...');

      _channel!.stream.listen(
        (message) => _handleServerMessage(message),
        onError: (e) {
          debugPrint('[DEBUG-CATCHME] Errore WebSocket: $e');
          _onConnectionLost();
        },
        onDone: () {
          debugPrint('[DEBUG-CATCHME] Connessione WebSocket chiusa dal server');
          _onConnectionLost();
        },
      );

      _registerWithServer();
    } catch (e) {
      debugPrint('[DEBUG-CATCHME] Errore avvio connessione WebSocket: $e');
      _isConnected = false;
      _onConnectionLost();
    }
  }

  void disconnectFromServer() {
    _reconnectTimer?.cancel();
    _channel?.sink.close();
    _channel = null;
    _isConnected = false;
    _nearbyUsers.clear();
    _connectedEndpoints.clear();
    _notifyUsersUpdate();
  }

  void _onConnectionLost() {
    _channel = null;
    _isConnected = false;
    _nearbyUsers.clear();
    _connectedEndpoints.clear();
    _notifyUsersUpdate();
    
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 5), () {
      if (_currentProfile != null && !_isConnected) {
        connectToServer();
      }
    });
  }

  Future<void> _registerWithServer() async {
    debugPrint('[DEBUG-CATCHME] _registerWithServer(): isConnected=$_isConnected, hasChannel=${_channel != null}, hasProfile=${_currentProfile != null}');
    if (!_isConnected || _channel == null || _currentProfile == null) {
      debugPrint('[DEBUG-CATCHME] _registerWithServer(): ABORTITO - condizioni non soddisfatte.');
      return;
    }

    final publicKey = _cryptoService.publicKey;
    final publicKeyHash = publicKey != null ? _cryptoService.getPublicKeyHash(publicKey) : '';
    debugPrint('[DEBUG-CATCHME] _registerWithServer(): publicKeyHash=$publicKeyHash');

    // Recupera la posizione passata o l'ultima nota in modo ISTANTANEO (evita ritardi di lock GPS)
    Position? pos;
    try {
      debugPrint('[DEBUG-CATCHME] _registerWithServer(): recupero last known GPS...');
      pos = await Geolocator.getLastKnownPosition();
      debugPrint('[DEBUG-CATCHME] _registerWithServer(): Last known GPS -> ${pos?.latitude}, ${pos?.longitude}');
    } catch (e) {
      debugPrint('[DEBUG-CATCHME] Errore recupero last known GPS: $e');
    }

    String? fcmToken;
    try {
      debugPrint('[DEBUG-CATCHME] _registerWithServer(): recupero FCM token...');
      fcmToken = await PushService().getFCMToken();
      debugPrint('[DEBUG-CATCHME] FCM Token: $fcmToken');
    } catch (e) {
      debugPrint('[DEBUG-CATCHME] Errore recupero FCM token: $e');
    }

    final sharingWith = await _getSharingWithList();

    final payload = {
      'type': 'register',
      'data': {
        'publicKeyHash': publicKeyHash,
        'nickname': _currentProfile!.nickname,
        'publicKey': publicKey,
        'x25519PublicKey': _cryptoService.x25519PublicKey,
        'lat': pos?.latitude,
        'lon': pos?.longitude,
        'birthDate': _currentProfile!.birthDate?.toIso8601String(),
        'gender': _currentProfile!.gender,
        'bio': _currentProfile!.bio,
        'pushProvider': _currentProfile!.pushProvider,
        'pushToken': _currentProfile!.pushToken ?? fcmToken,
        'status': _currentProfile!.status.name,
        'radarRange': _currentProfile!.radarRange,
        'sharingWith': sharingWith,
      }
    };

    debugPrint('[DEBUG-CATCHME] _registerWithServer(): invio payload registrazione istantanea...');
    _channel?.sink.add(jsonEncode(payload));
    debugPrint('[DEBUG-CATCHME] _registerWithServer(): registrazione inviata. Richiedo GPS aggiornato in background...');
    
    // Richiedi la posizione GPS ad alta precisione in background senza bloccare la consegna messaggi
    _fetchAndSendCurrentLocation();
  }

  Future<void> _fetchAndSendCurrentLocation() async {
    try {
      final pos = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);
      if (_isConnected && _channel != null) {
        final sharingWith = await _getSharingWithList();
        final payload = {
          'type': 'location_update',
          'data': {
            'lat': pos.latitude,
            'lon': pos.longitude,
            'status': _currentProfile?.status.name,
            'radarRange': _currentProfile?.radarRange,
            'sharingWith': sharingWith,
          }
        };
        _channel?.sink.add(jsonEncode(payload));
        debugPrint('[DEBUG-CATCHME] GPS aggiornato in background con successo.');
      }
    } catch (e) {
      debugPrint('[DEBUG-CATCHME] Errore aggiornamento GPS background: $e');
    }
  }

  Future<void> _sendLocationUpdate() async {
    if (!_isConnected || _channel == null) return;

    try {
      final pos = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);
      final sharingWith = await _getSharingWithList();
      final payload = {
        'type': 'location_update',
        'data': {
          'lat': pos.latitude,
          'lon': pos.longitude,
          'status': _currentProfile?.status.name,
          'radarRange': _currentProfile?.radarRange,
          'sharingWith': sharingWith,
        }
      };
      _channel?.sink.add(jsonEncode(payload));
    } catch (e) {
      debugPrint('[DEBUG-CATCHME] Aggiornamento GPS fallito: $e');
    }
  }

  void _handleServerMessage(String message) async {
    try {
      final payload = jsonDecode(message);
      final String type = payload['type'];
      final data = payload['data'];

      if (type == 'nearby_users') {
        _handleNearbyUsersUpdate(data);
      } else if (type == 'message') {
        _handleIncomingMessage(data);
      } else if (type == 'server_ack') {
        _handleServerAck(data);
      } else if (type == 'msg_delivered') {
        _handleMessageDelivered(data);
      }
    } catch (e) {
      debugPrint('[DEBUG-CATCHME] Errore parse messaggio server: $e');
    }
  }

  void _handleServerAck(dynamic data) async {
    try {
      final String messageId = data['messageId'];
      final String recipientHash = data['recipientHash'];
      debugPrint('[ProximityService] server_ack ricevuto per msg $messageId destinato a $recipientHash');
      
      await _storageService.updateChatMessageStatus(recipientHash, messageId, MessageStatus.sent);
      
      final updatedMessage = ChatMessage(
        id: messageId,
        endpointId: recipientHash,
        message: '',
        timestamp: DateTime.now(),
        isSent: true,
        status: MessageStatus.sent,
      );
      _messageController.add(updatedMessage);
    } catch (e) {
      debugPrint('[ProximityService] Errore in _handleServerAck: $e');
    }
  }

  void _handleMessageDelivered(dynamic data) async {
    try {
      final String messageId = data['messageId'];
      final String recipientHash = data['recipientHash'];
      debugPrint('[ProximityService] msg_delivered (spunta blu) ricevuto per msg $messageId consegnato a $recipientHash');
      
      await _storageService.updateChatMessageStatus(recipientHash, messageId, MessageStatus.delivered);
      
      final updatedMessage = ChatMessage(
        id: messageId,
        endpointId: recipientHash,
        message: '',
        timestamp: DateTime.now(),
        isSent: true,
        status: MessageStatus.delivered,
      );
      _messageController.add(updatedMessage);
    } catch (e) {
      debugPrint('[ProximityService] Errore in _handleMessageDelivered: $e');
    }
  }

  void _handleNearbyUsersUpdate(dynamic data) async {
    final Map<String, NearbyUser> updatedNearby = {};
    final contacts = await _storageService.getContacts();
    
    List<dynamic> nearbyList = [];
    List<dynamic> activeUsers = [];
    
    if (data is Map) {
      nearbyList = data['nearby'] ?? [];
      activeUsers = data['activeUsers'] ?? [];
    } else if (data is List) {
      nearbyList = data;
      activeUsers = data.map((item) => item['publicKeyHash']).toList();
    }
    
    for (final item in nearbyList) {
      final String hash = item['publicKeyHash'];
      final isBlocked = await _storageService.isUserBlocked(hash);
      if (isBlocked) continue; // Salta gli utenti bloccati!
      
      final String nickname = item['nickname'];
      final String? publicKey = item['publicKey'];
      final String? x25519PublicKey = item['x25519PublicKey'];
      final double? distance = item['distance'] != null ? (item['distance'] as num).toDouble() : null;
      final String? birthDateStr = item['birthDate'];
      final DateTime? birthDate = birthDateStr != null ? DateTime.parse(birthDateStr) : null;
      final String? gender = item['gender'] as String?;
      final String? bio = item['bio'] as String?;

      bool isVerified = false;
      for (final contact in contacts) {
        if (contact.id == hash) {
          isVerified = true;
          break;
        }
        if (contact.publicKey.isNotEmpty) {
          try {
            final contactHash = _cryptoService.getPublicKeyHash(contact.publicKey);
            if (contactHash == hash) {
              isVerified = true;
              break;
            }
          } catch (_) {}
        }
      }

      updatedNearby[hash] = NearbyUser(
        endpointId: hash,
        nickname: nickname,
        status: distance != null ? '${distance.toStringAsFixed(0)}m' : 'Nelle vicinanze',
        isVerified: isVerified,
        isTrusted: isVerified,
        isConnected: true,
        publicKey: publicKey,
        birthDate: birthDate,
        gender: gender,
        bio: bio,
        x25519PublicKey: x25519PublicKey,
      );

      // Se l'utente è un contatto registrato, aggiorna la sua ultima posizione e ora visti + info profilo
      if (isVerified) {
        try {
          final matchedContact = contacts.firstWhere((c) => c.id == hash);
          final updatedContact = matchedContact.copyWith(
            lastSeen: DateTime.now(),
            lastDistance: distance,
            nickname: nickname,
            bio: bio,
            birthDate: birthDate,
            gender: gender,
            x25519PublicKey: x25519PublicKey ?? '',
          );
          // Salva in modo asincrono (accodato) senza bloccare il ciclo del radar
          _storageService.saveContact(updatedContact);

          // Invia notifica di prossimità se abilitata e l'utente non era già nei paraggi
          final wasNearby = _nearbyUsers.containsKey(hash);
          if (!wasNearby && matchedContact.proximityAlertEnabled) {
            if (_notifiedProximityHashes.add(hash)) {
              _notificationService.showProximityAlertNotification(nickname);
            }
          }
        } catch (_) {}
      }
    }

    // Invia notifica di allontanamento se un contatto tracciato esce dal radar (o scade il timeout)
    for (final oldHash in _nearbyUsers.keys) {
      if (!updatedNearby.containsKey(oldHash)) {
        if (_notifiedProximityHashes.contains(oldHash)) {
          try {
            final contact = contacts.firstWhere((c) => c.id == oldHash);
            if (contact.proximityAlertEnabled) {
              _notificationService.showProximityExitNotification(contact.nickname);
            }
          } catch (_) {}
          _notifiedProximityHashes.remove(oldHash);
        }
      }
    }

    _nearbyUsers.clear();
    _nearbyUsers.addAll(updatedNearby);
    
    _connectedEndpoints.clear();
    _connectedEndpoints.addAll(activeUsers.map((e) => e.toString()));
    
    _notifyUsersUpdate();
  }

  void _handleIncomingMessage(Map<String, dynamic> data) async {
    final String senderHash = data['senderHash'];
    final String messageId = data['messageId'] ?? DateTime.now().millisecondsSinceEpoch.toString();
    
    final isBlocked = await _storageService.isUserBlocked(senderHash);
    if (isBlocked) {
      debugPrint('[DEBUG-CATCHME] Ignorato messaggio da utente bloccato: $senderHash');
      return;
    }
 
    final String encryptedMessage = data['encryptedMessage'];
    final String msgType = data['type'];
    final String? photoData = data['photoData'];

    final senderUser = _nearbyUsers[senderHash];
    final String nickname = data['senderNickname'] ?? (senderUser?.nickname ?? 'Utente');
    final String senderPublicKey = data['senderPublicKey'] ?? (senderUser?.publicKey ?? '');
    final String senderX25519PublicKey = data['senderX25519PublicKey'] ?? (senderUser?.x25519PublicKey ?? '');
    
    // Se non è ancora nei contatti, crealo automaticamente in modo da farlo apparire in Rubrica
    final contacts = await _storageService.getContacts();
    final hasContact = contacts.any((c) => c.id == senderHash);
    if (!hasContact) {
      final newContact = Contact(
        id: senderHash,
        nickname: nickname,
        publicKey: senderPublicKey,
        dateMatched: DateTime.now(),
        birthDate: senderUser?.birthDate,
        gender: senderUser?.gender,
        bio: senderUser?.bio,
        x25519PublicKey: senderX25519PublicKey,
      );
      await _storageService.saveContact(newContact);
      _notifyUsersUpdate();
    } else {
      final matchedContact = contacts.firstWhere((c) => c.id == senderHash);
      final updatedContact = matchedContact.copyWith(
        nickname: nickname,
        birthDate: senderUser?.birthDate ?? matchedContact.birthDate,
        gender: senderUser?.gender ?? matchedContact.gender,
        bio: senderUser?.bio ?? matchedContact.bio,
        x25519PublicKey: senderX25519PublicKey.isNotEmpty ? senderX25519PublicKey : matchedContact.x25519PublicKey,
      );
      await _storageService.saveContact(updatedContact);
    }
    
    // Recupera la chiave X25519 per decifrare
    String decryptKey = senderX25519PublicKey;
    if (decryptKey.isEmpty) {
      final contact = await _storageService.getContactById(senderHash);
      if (contact != null) {
        decryptKey = contact.x25519PublicKey;
      }
    }
    
    String decryptedText = '';
    bool decryptionFailed = false;
    if (msgType == 'text' || msgType == 'image' || msgType == 'file') {
      try {
        if (decryptKey.isEmpty) {
          throw Exception('Chiave pubblica X25519 mancante');
        }
        decryptedText = await _cryptoService.decryptPayload(encryptedMessage, decryptKey);
      } catch (e) {
        debugPrint('[ProximityService] Errore decifratura: $e');
        decryptedText = '[Messaggio cifrato - Impossibile decifrare]';
        decryptionFailed = true;
      }
    }

    // Estrai il timestamp inviato dal server, altrimenti usa l'ora corrente
    final int? serverTimestamp = data['timestamp'] as int?;
    final DateTime messageTime = serverTimestamp != null 
        ? DateTime.fromMillisecondsSinceEpoch(serverTimestamp) 
        : DateTime.now();

    MessageType parsedType = MessageType.text;
    String displayMessage = decryptedText;

    if (msgType == 'photoRequest') {
      parsedType = MessageType.photoRequest;
      displayMessage = 'Richiesta foto profilo';
    } else if (msgType == 'photoResponse') {
      parsedType = MessageType.photoResponse;
      displayMessage = 'Foto profilo ricevuta';
    } else if (msgType == 'photoRejected') {
      parsedType = MessageType.photoRejected;
      displayMessage = 'Richiesta foto rifiutata';
    } else if (msgType == 'locationRequest') {
      parsedType = MessageType.locationRequest;
      displayMessage = 'Richiesta posizione in tempo reale';
    } else if (msgType == 'locationResponse') {
      parsedType = MessageType.locationResponse;
      displayMessage = encryptedMessage == 'shared_permanently'
          ? 'Posizione condivisa permanentemente'
          : 'Posizione condivisa una volta';
          
      // Se abbiamo ricevuto coordinate, calcoliamo la distanza e aggiorniamo il contatto
      final double? lat = data['lat'] != null ? (data['lat'] as num).toDouble() : null;
      final double? lon = data['lon'] != null ? (data['lon'] as num).toDouble() : null;
      if (lat != null && lon != null) {
        Position? myPos;
        try {
          myPos = await Geolocator.getLastKnownPosition();
          myPos ??= await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.medium).timeout(const Duration(seconds: 2));
        } catch (_) {}
        
        double? distance;
        if (myPos != null) {
          distance = Geolocator.distanceBetween(myPos.latitude, myPos.longitude, lat, lon);
        }
        
        final contact = await _storageService.getContactById(senderHash);
        if (contact != null) {
          final updated = contact.copyWith(
            lastSeen: DateTime.now(),
            lastDistance: distance,
          );
          await _storageService.saveContact(updated);
        }

        // Aggiorna lo stato in memoria dell'utente rilevato per mostrare la distanza in tempo reale sul radar e sui contatti
        final nearby = _nearbyUsers[senderHash];
        if (nearby != null && distance != null) {
          _nearbyUsers[senderHash] = nearby.copyWith(
            status: distance >= 1000 
                ? '${(distance / 1000).toStringAsFixed(1)}km' 
                : '${distance.toStringAsFixed(0)}m',
          );
          _notifyUsersUpdate();
        }
      }
    } else if (msgType == 'locationRejected') {
      parsedType = MessageType.locationRejected;
      displayMessage = 'Richiesta posizione rifiutata';
    }

    String? localPath;
    if ((msgType == 'image' || msgType == 'file') && !decryptionFailed) {
      parsedType = msgType == 'image' ? MessageType.image : MessageType.file;
      final String? fileName = data['fileName'];
      displayMessage = fileName ?? (msgType == 'image' ? 'Immagine' : 'File');
      try {
        final bytes = base64Decode(decryptedText);
        localPath = await _storageService.saveChatAttachment(
          fileName ?? (msgType == 'image' ? 'image_${DateTime.now().millisecondsSinceEpoch}.jpg' : 'file_${DateTime.now().millisecondsSinceEpoch}.bin'),
          bytes,
        );
      } catch (e) {
        debugPrint('[ProximityService] Errore salvataggio allegato in ingresso: $e');
      }
    } else if (decryptionFailed) {
      parsedType = MessageType.text;
      displayMessage = '[Impossibile decifrare il contenuto]';
    }

    final chatMessage = ChatMessage(
      id: messageId,
      endpointId: senderHash,
      message: displayMessage,
      timestamp: messageTime,
      isSent: false,
      type: parsedType,
      photoData: photoData,
      localFilePath: localPath,
      status: MessageStatus.delivered,
    );

    _messageController.add(chatMessage);
    await _storageService.saveChatMessage(senderHash, chatMessage);

    // Invia la ricevuta di consegna (spunta blu) al server
    if (_isConnected && _channel != null) {
      final receiptPayload = {
        'type': 'delivery_receipt',
        'data': {
          'messageId': messageId,
          'senderHash': senderHash,
        }
      };
      _channel!.sink.add(jsonEncode(receiptPayload));
    }

    // Evita la doppia notifica: se il messaggio è vecchio (es. recapitato dopo disconnessione / offline)
    // o se l'utente è attivo nella chat corrente, non mostrare la notifica locale.
    final isActiveChat = senderUser?.publicKey != null && senderUser!.publicKey == _activeChatPublicKey;
    final isMessageFresh = DateTime.now().difference(messageTime).inSeconds < 10;

    if (isMessageFresh && (_isInBackground || !isActiveChat)) {
      await _notificationService.showNewMessageNotification(senderHash, nickname, chatMessage.message);
    }
  }

  Future<void> startAdvertising(UserProfile profile) async {
    _currentProfile = profile;
    connectToServer();
  }

  Future<void> updateProfile(UserProfile profile) async {
    _currentProfile = profile;
    if (_isConnected && _channel != null) {
      await _registerWithServer();
    }
  }

  Future<void> stopAdvertising() async {
    _currentProfile = null;
    disconnectFromServer();
  }

  Future<void> startDiscovery() async {
    _gpsTimer?.cancel();
    // Prima lettura GPS immediata, poi ogni 5 minuti
    _sendLocationUpdate();
    _gpsTimer = Timer.periodic(const Duration(minutes: 5), (timer) {
      _sendLocationUpdate();
    });
  }

  Future<void> stopDiscovery() async {
    _gpsTimer?.cancel();
    _gpsTimer = null;
  }

  Future<void> requestConnection(String endpointId) async {
    if (_nearbyUsers.containsKey(endpointId)) {
      _nearbyUsers[endpointId] = _nearbyUsers[endpointId]!.copyWith(isConnected: true);
      _connectedEndpoints.add(endpointId);
      _notifyUsersUpdate();
    }
  }

  Future<void> acceptConnection(String endpointId) async {}
  Future<void> rejectConnection(String endpointId) async {}

  Future<void> sendMessage(String endpointId, String message) async {
    if (!_isConnected || _channel == null || _currentProfile == null) return;

    final publicKey = _cryptoService.publicKey;
    final senderHash = publicKey != null ? _cryptoService.getPublicKeyHash(publicKey) : '';

    String recipientX25519PublicKey = '';
    final contact = await _storageService.getContactById(endpointId);
    if (contact != null) {
      recipientX25519PublicKey = contact.x25519PublicKey;
    } else {
      final nearbyUser = _nearbyUsers[endpointId];
      if (nearbyUser != null) {
        recipientX25519PublicKey = nearbyUser.x25519PublicKey ?? '';
      }
    }

    final encryptedText = await _cryptoService.encryptPayload(message, recipientX25519PublicKey);
    final messageId = DateTime.now().millisecondsSinceEpoch.toString();

    final payload = {
      'type': 'message',
      'data': {
        'messageId': messageId,
        'recipientHash': endpointId,
        'senderHash': senderHash,
        'senderPublicKey': publicKey,
        'senderX25519PublicKey': _cryptoService.x25519PublicKey,
        'encryptedMessage': encryptedText,
        'type': 'text',
      }
    };

    _channel!.sink.add(jsonEncode(payload));

    final chatMessage = ChatMessage(
      id: messageId,
      endpointId: endpointId,
      message: message,
      timestamp: DateTime.now(),
      isSent: true,
      status: MessageStatus.sending,
    );

    _messageController.add(chatMessage);
    await _storageService.saveChatMessage(endpointId, chatMessage);
  }

  Future<void> sendMediaMessage(String endpointId, File file, MessageType type, {String? customFileName}) async {
    if (!_isConnected || _channel == null || _currentProfile == null) return;

    final publicKey = _cryptoService.publicKey;
    final senderHash = publicKey != null ? _cryptoService.getPublicKeyHash(publicKey) : '';

    String recipientX25519PublicKey = '';
    final contact = await _storageService.getContactById(endpointId);
    if (contact != null) {
      recipientX25519PublicKey = contact.x25519PublicKey;
    } else {
      final nearbyUser = _nearbyUsers[endpointId];
      if (nearbyUser != null) {
        recipientX25519PublicKey = nearbyUser.x25519PublicKey ?? '';
      }
    }

    List<int> fileBytes;
    final String fileName = customFileName ?? file.path.split('/').last;

    if (type == MessageType.image) {
      // Comprimi se è un'immagine prima di cifrarla usando la libreria image
      final originalBytes = await file.readAsBytes();
      final originalImage = img.decodeImage(originalBytes);
      
      if (originalImage != null) {
        // Ridimensiona l'immagine se troppo grande
        final resizedImage = img.copyResize(originalImage, width: 1024, height: 1024);
        // Comprimi con qualità 75%
        final compressedBytes = img.encodeJpg(resizedImage, quality: 75);
        fileBytes = compressedBytes;
      } else {
        fileBytes = originalBytes;
      }
    } else {
      fileBytes = await file.readAsBytes();
    }

    final String base64Payload = base64Encode(fileBytes);
    final encryptedText = await _cryptoService.encryptPayload(base64Payload, recipientX25519PublicKey);
    final messageId = DateTime.now().millisecondsSinceEpoch.toString();

    final payload = {
      'type': 'message',
      'data': {
        'messageId': messageId,
        'recipientHash': endpointId,
        'senderHash': senderHash,
        'senderPublicKey': publicKey,
        'senderX25519PublicKey': _cryptoService.x25519PublicKey,
        'encryptedMessage': encryptedText,
        'type': type == MessageType.image ? 'image' : 'file',
        'fileName': fileName,
      }
    };

    _channel!.sink.add(jsonEncode(payload));

    // Copia il file localmente nella cartella allegati
    final localPath = await _storageService.saveChatAttachment(fileName, fileBytes);

    final chatMessage = ChatMessage(
      id: messageId,
      endpointId: endpointId,
      message: fileName,
      timestamp: DateTime.now(),
      isSent: true,
      type: type,
      localFilePath: localPath,
      status: MessageStatus.sending,
    );

    _messageController.add(chatMessage);
    await _storageService.saveChatMessage(endpointId, chatMessage);
  }

  Future<bool> sendLocationUpdateManually() async {
    try {
      // Se non è connesso, stabilisci la connessione
      if (!_isConnected || _channel == null) {
        connectToServer();
        // Diamo un secondo al socket di stabilirsi
        await Future.delayed(const Duration(milliseconds: 1000));
      }
      
      final pos = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);
      final sharingWith = await _getSharingWithList();
      final payload = {
        'type': 'location_update',
        'data': {
          'lat': pos.latitude,
          'lon': pos.longitude,
          'sharingWith': sharingWith,
        }
      };
      
      if (_channel != null) {
        _channel!.sink.add(jsonEncode(payload));
        return true;
      }
      return false;
    } catch (e) {
      debugPrint('[DEBUG-CATCHME] Errore invio manuale posizione: $e');
      return false;
    }
  }

  Future<void> sendPhotoRequest(String endpointId) async {
    if (!_isConnected || _channel == null) return;

    final publicKey = _cryptoService.publicKey;
    final senderHash = publicKey != null ? _cryptoService.getPublicKeyHash(publicKey) : '';
    final messageId = DateTime.now().millisecondsSinceEpoch.toString();

    final payload = {
      'type': 'message',
      'data': {
        'messageId': messageId,
        'recipientHash': endpointId,
        'senderHash': senderHash,
        'encryptedMessage': '',
        'type': 'photoRequest',
      }
    };
    _channel!.sink.add(jsonEncode(payload));

    final chatMessage = ChatMessage(
      id: messageId,
      endpointId: endpointId,
      message: 'Richiesta foto profilo',
      timestamp: DateTime.now(),
      isSent: true,
      type: MessageType.photoRequest,
    );
    _messageController.add(chatMessage);
    await _storageService.saveChatMessage(endpointId, chatMessage);
  }

  Future<void> sendPhotoResponse(String endpointId, String base64Photo) async {
    if (!_isConnected || _channel == null) return;

    final publicKey = _cryptoService.publicKey;
    final senderHash = publicKey != null ? _cryptoService.getPublicKeyHash(publicKey) : '';
    final messageId = DateTime.now().millisecondsSinceEpoch.toString();

    final payload = {
      'type': 'message',
      'data': {
        'messageId': messageId,
        'recipientHash': endpointId,
        'senderHash': senderHash,
        'encryptedMessage': '',
        'type': 'photoResponse',
        'photoData': base64Photo,
      }
    };
    _channel!.sink.add(jsonEncode(payload));

    final chatMessage = ChatMessage(
      id: messageId,
      endpointId: endpointId,
      message: 'Foto profilo inviata',
      timestamp: DateTime.now(),
      isSent: true,
      type: MessageType.photoResponse,
      photoData: base64Photo,
    );
    _messageController.add(chatMessage);
    await _storageService.saveChatMessage(endpointId, chatMessage);
  }

  Future<void> sendPhotoRejection(String endpointId) async {
    if (!_isConnected || _channel == null) return;

    final publicKey = _cryptoService.publicKey;
    final senderHash = publicKey != null ? _cryptoService.getPublicKeyHash(publicKey) : '';
    final messageId = DateTime.now().millisecondsSinceEpoch.toString();

    final payload = {
      'type': 'message',
      'data': {
        'messageId': messageId,
        'recipientHash': endpointId,
        'senderHash': senderHash,
        'encryptedMessage': '',
        'type': 'photoRejected',
      }
    };
    _channel!.sink.add(jsonEncode(payload));

    final chatMessage = ChatMessage(
      id: messageId,
      endpointId: endpointId,
      message: 'Richiesta foto rifiutata',
      timestamp: DateTime.now(),
      isSent: true,
      type: MessageType.photoRejected,
    );
    _messageController.add(chatMessage);
    await _storageService.saveChatMessage(endpointId, chatMessage);
  }

  void onAppPaused() async {
    _isInBackground = true;
    _gpsTimer?.cancel();
    
    // Disconnetti immediatamente il socket WebSocket continuo per risparmiare batteria
    disconnectFromServer();
    
    // Controlla se la sincronizzazione in background è abilitata nelle impostazioni
    final prefs = await SharedPreferences.getInstance();
    final isBgSyncEnabled = prefs.getBool('background_sync_enabled') ?? true;
    
    if (isBgSyncEnabled) {
      debugPrint('[DEBUG-CATCHME] Sincronizzazione in background attiva. Avvio scansione periodica (5 min).');
      // Avvia la scansione periodica a basso consumo (es. ogni 5 minuti)
      _gpsTimer = Timer.periodic(const Duration(minutes: 5), (timer) async {
        await _sendBackgroundLocationUpdate();
      });
    } else {
      debugPrint('[DEBUG-CATCHME] Sincronizzazione in background disattivata. Nessuna scansione periodica avviata.');
    }
  }

  Future<void> _sendBackgroundLocationUpdate() async {
    try {
      // 1. Rileva posizione GPS (precisione media per consumare meno batteria al chiuso/background)
      final pos = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.medium);
      
      // 2. Connettiti temporaneamente al server
      const url = _serverUrl;
      
      debugPrint('[DEBUG-CATCHME] Connessione temporanea background a: $url');
      final tempChannel = WebSocketChannel.connect(Uri.parse(url));
      
      // 3. Invia pacchetto di registrazione per aggiornare la posizione sul server
      final publicKey = _cryptoService.publicKey;
      final publicKeyHash = publicKey != null ? _cryptoService.getPublicKeyHash(publicKey) : '';
      final fcmToken = await PushService().getFCMToken();
      
      final sharingWith = await _getSharingWithList();

      final payload = {
        'type': 'register',
        'data': {
          'publicKeyHash': publicKeyHash,
          'nickname': _currentProfile?.nickname ?? 'Utente',
          'publicKey': publicKey,
          'x25519PublicKey': _cryptoService.x25519PublicKey,
          'lat': pos.latitude,
          'lon': pos.longitude,
          'birthDate': _currentProfile?.birthDate?.toIso8601String(),
          'gender': _currentProfile?.gender,
          'bio': _currentProfile?.bio,
          'fcmToken': fcmToken,
          'sharingWith': sharingWith,
        }
      };
      
      tempChannel.sink.add(jsonEncode(payload));
      
      // Lascia un breve ritardo per garantire che il socket invii il pacchetto prima di chiudersi
      await Future.delayed(const Duration(milliseconds: 1000));
      await tempChannel.sink.close();
      debugPrint('[DEBUG-CATCHME] Aggiornamento GPS background completato con successo.');
    } catch (e) {
      debugPrint('[DEBUG-CATCHME] Errore aggiornamento GPS background: $e');
    }
  }

  void onAppResumed() {
    _isInBackground = false;
    // Cancella il timer del background (flash connect ogni 5 min)
    _gpsTimer?.cancel();
    // Riapre la connessione WebSocket persistente per radar e chat real-time
    if (_currentProfile != null && !_isConnected) {
      connectToServer();
      startDiscovery();
    }
  }

  void setActiveChatPublicKey(String? publicKey) {
    _activeChatPublicKey = publicKey;
  }

  String? get activeChatPublicKey => _activeChatPublicKey;

  String? getEndpointIdForPublicKey(String publicKey) {
    final targetHash = _cryptoService.getPublicKeyHash(publicKey);
    return _nearbyUsers.containsKey(targetHash) ? targetHash : null;
  }

  void _notifyUsersUpdate() {
    _discoveredUsersController.add(_nearbyUsers.values.toList());
  }

  Future<void> saveContact(String endpointId) async {
    final user = _nearbyUsers[endpointId];
    if (user == null || user.publicKey == null) return;

    final contactId = _cryptoService.getPublicKeyHash(user.publicKey!);
    
    // Controlla se la foto profilo è già stata ricevuta in precedenza
    final photoFile = await _storageService.getContactPhoto(contactId);
    final avatarPath = photoFile?.path;

    final contact = Contact(
      id: contactId,
      nickname: user.nickname,
      publicKey: user.publicKey!,
      dateMatched: DateTime.now(),
      avatarPath: avatarPath,
      birthDate: user.birthDate,
      gender: user.gender,
      bio: user.bio,
      x25519PublicKey: user.x25519PublicKey ?? '',
    );

    await _storageService.saveContact(contact);

    // Aggiorna lo stato dell'utente
    _nearbyUsers[endpointId] = user.copyWith(isVerified: true);
    _notifyUsersUpdate();
  }

  Future<List<String>> _getSharingWithList() async {
    try {
      final contacts = await _storageService.getContacts();
      return contacts.where((c) => c.isLocationShared).map((c) => c.id).toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> sendLocationRequest(String endpointId) async {
    if (!_isConnected || _channel == null) return;

    final publicKey = _cryptoService.publicKey;
    final senderHash = publicKey != null ? _cryptoService.getPublicKeyHash(publicKey) : '';
    final messageId = DateTime.now().millisecondsSinceEpoch.toString();

    final payload = {
      'type': 'message',
      'data': {
        'messageId': messageId,
        'recipientHash': endpointId,
        'senderHash': senderHash,
        'encryptedMessage': '',
        'type': 'locationRequest',
      }
    };
    _channel!.sink.add(jsonEncode(payload));

    final chatMessage = ChatMessage(
      id: messageId,
      endpointId: endpointId,
      message: 'Richiesta posizione inviata',
      timestamp: DateTime.now(),
      isSent: true,
      type: MessageType.locationRequest,
    );
    _messageController.add(chatMessage);
    await _storageService.saveChatMessage(endpointId, chatMessage);
  }

  Future<void> sendLocationResponse(String endpointId, {required bool permanent}) async {
    if (!_isConnected || _channel == null) return;

    final publicKey = _cryptoService.publicKey;
    final senderHash = publicKey != null ? _cryptoService.getPublicKeyHash(publicKey) : '';
    final messageId = DateTime.now().millisecondsSinceEpoch.toString();

    Position? pos;
    try {
      pos = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);
    } catch (_) {}

    if (permanent) {
      final contacts = await _storageService.getContacts();
      final index = contacts.indexWhere((c) => c.id == endpointId);
      if (index != -1) {
        final updated = contacts[index].copyWith(isLocationShared: true);
        await _storageService.saveContact(updated);
        // Forza l'aggiornamento della registrazione sul server per includere la condivisione istantanea
        _registerWithServer();
      }
    }

    final payload = {
      'type': 'message',
      'data': {
        'messageId': messageId,
        'recipientHash': endpointId,
        'senderHash': senderHash,
        'encryptedMessage': permanent ? 'shared_permanently' : 'shared_once',
        'type': 'locationResponse',
        'lat': pos?.latitude,
        'lon': pos?.longitude,
      }
    };
    _channel!.sink.add(jsonEncode(payload));

    final chatMessage = ChatMessage(
      id: messageId,
      endpointId: endpointId,
      message: permanent 
          ? 'Posizione condivisa permanentemente' 
          : 'Posizione condivisa una volta',
      timestamp: DateTime.now(),
      isSent: true,
      type: MessageType.locationResponse,
    );
    _messageController.add(chatMessage);
    await _storageService.saveChatMessage(endpointId, chatMessage);
  }

  Future<void> rejectLocationRequest(String endpointId) async {
    if (!_isConnected || _channel == null) return;

    final publicKey = _cryptoService.publicKey;
    final senderHash = publicKey != null ? _cryptoService.getPublicKeyHash(publicKey) : '';
    final messageId = DateTime.now().millisecondsSinceEpoch.toString();

    final payload = {
      'type': 'message',
      'data': {
        'messageId': messageId,
        'recipientHash': endpointId,
        'senderHash': senderHash,
        'encryptedMessage': '',
        'type': 'locationRejected',
      }
    };
    _channel!.sink.add(jsonEncode(payload));

    final chatMessage = ChatMessage(
      id: messageId,
      endpointId: endpointId,
      message: 'Richiesta posizione rifiutata',
      timestamp: DateTime.now(),
      isSent: true,
      type: MessageType.locationRejected,
    );
    _messageController.add(chatMessage);
    await _storageService.saveChatMessage(endpointId, chatMessage);
  }

  Future<void> revokeLocationSharing(String endpointId) async {
    final contacts = await _storageService.getContacts();
    final index = contacts.indexWhere((c) => c.id == endpointId);
    if (index != -1) {
      final updated = contacts[index].copyWith(isLocationShared: false);
      await _storageService.saveContact(updated);
      
      // Se connessi, aggiorniamo il server rimuovendo questo hash dall'elenco sharingWith
      if (_isConnected && _channel != null) {
        _registerWithServer();
      }
    }
  }

  void dispose() {
    _discoveredUsersController.close();
    _connectionRequestController.close();
    _messageController.close();
    _gpsTimer?.cancel();
    _channel?.sink.close();
  }
}

class ConnectionRequest {
  final String endpointId;
  final String endpointName;

  ConnectionRequest({
    required this.endpointId,
    required this.endpointName,
  });
}
