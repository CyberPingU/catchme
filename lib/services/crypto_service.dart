import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class CryptoService {
  static final CryptoService _instance = CryptoService._internal();
  
  factory CryptoService() {
    return _instance;
  }
  
  CryptoService._internal();
  
  static const String _privateKeyKey = 'private_key';
  static const String _publicKeyKey = 'public_key';
  
  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();
  final Ed25519 _algorithm = Ed25519();
  
  SimpleKeyPair? _keyPair;
  String? _publicKeyBase64;
  SimpleKeyPair? _x25519KeyPair;
  String? _x25519PublicKeyBase64;

  /// Inizializza il servizio crittografico, generando o caricando le chiavi
  Future<void> initialize() async {
    await _loadOrGenerateKeys();
  }

  /// Carica le chiavi esistenti o ne genera di nuove
  Future<void> _loadOrGenerateKeys() async {
    try {
      // Prova a caricare le chiavi esistenti
      final privateKeyStr = await _secureStorage.read(key: _privateKeyKey);
      final publicKeyStr = await _secureStorage.read(key: _publicKeyKey);

      if (privateKeyStr != null && publicKeyStr != null) {
        // Carica le chiavi esistenti
        final privateKeyBytes = base64Decode(privateKeyStr);
        
        _keyPair = await _algorithm.newKeyPairFromSeed(privateKeyBytes);
        _publicKeyBase64 = publicKeyStr;

        // Deriva la chiave X25519 dallo stesso seed
        _x25519KeyPair = await X25519().newKeyPairFromSeed(privateKeyBytes);
        final x25519PublicKey = await _x25519KeyPair!.extractPublicKey();
        _x25519PublicKeyBase64 = base64Encode(x25519PublicKey.bytes);
      } else {
        // Genera nuove chiavi
        await _generateNewKeys();
      }
    } catch (e) {
      // In caso di errore, genera nuove chiavi
      await _generateNewKeys();
    }
  }

  /// Genera una nuova coppia di chiavi
  Future<void> _generateNewKeys() async {
    _keyPair = await _algorithm.newKeyPair();
    
    // Estrai la chiave pubblica
    final publicKey = await _keyPair!.extractPublicKey();
    final publicKeyBytes = publicKey.bytes;
    _publicKeyBase64 = base64Encode(publicKeyBytes);
    
    // Estrai la chiave privata (seed)
    final privateKeyBytes = await _keyPair!.extractPrivateKeyBytes();
    final privateKeyBase64 = base64Encode(privateKeyBytes);
    
    // Salva le chiavi in modo sicuro
    await _secureStorage.write(key: _privateKeyKey, value: privateKeyBase64);
    await _secureStorage.write(key: _publicKeyKey, value: _publicKeyBase64);

    // Genera e memorizza X25519 dallo stesso seed
    _x25519KeyPair = await X25519().newKeyPairFromSeed(privateKeyBytes);
    final x25519PublicKey = await _x25519KeyPair!.extractPublicKey();
    _x25519PublicKeyBase64 = base64Encode(x25519PublicKey.bytes);
  }

  /// Restituisce la chiave pubblica Ed25519 in formato Base64
  String? get publicKey => _publicKeyBase64;

  /// Restituisce la chiave pubblica X25519 in formato Base64
  String? get x25519PublicKey => _x25519PublicKeyBase64;

  /// Cifra un testo in chiaro per un determinato destinatario usando la propria chiave privata X25519 e la chiave pubblica X25519 del destinatario
  Future<String> encryptPayload(String plaintext, String recipientX25519PublicKeyBase64) async {
    if (_x25519KeyPair == null) {
      throw Exception('Chiavi non inizializzate');
    }
    if (recipientX25519PublicKeyBase64.isEmpty) {
      return plaintext; // Ritorna testo in chiaro se non abbiamo la chiave del destinatario
    }
    
    final remotePublicKeyBytes = base64Decode(recipientX25519PublicKeyBase64);
    final remotePublicKey = SimplePublicKey(remotePublicKeyBytes, type: KeyPairType.x25519);
    
    final sharedSecret = await X25519().sharedSecretKey(
      keyPair: _x25519KeyPair!,
      remotePublicKey: remotePublicKey,
    );
    
    final cipher = AesGcm.with256bits();
    final plaintextBytes = utf8.encode(plaintext);
    
    final secretBox = await cipher.encrypt(
      plaintextBytes,
      secretKey: sharedSecret,
    );
    
    final nonceB64 = base64Encode(secretBox.nonce);
    final cipherTextB64 = base64Encode(secretBox.cipherText);
    final macB64 = base64Encode(secretBox.mac.bytes);
    
    return '$nonceB64:$cipherTextB64:$macB64';
  }

  /// Decifra un payload cifrato inviato da un mittente usando la propria chiave privata X25519 e la chiave pubblica X25519 del mittente
  Future<String> decryptPayload(String encryptedPayload, String senderX25519PublicKeyBase64) async {
    if (_x25519KeyPair == null) {
      throw Exception('Chiavi non inizializzate');
    }
    if (senderX25519PublicKeyBase64.isEmpty) {
      return encryptedPayload; // Ritorna payload originale se non abbiamo la chiave del mittente
    }
    
    final parts = encryptedPayload.split(':');
    if (parts.length != 3) {
      return encryptedPayload; // Non cifrato o non valido
    }
    
    try {
      final nonce = base64Decode(parts[0]);
      final cipherText = base64Decode(parts[1]);
      final macBytes = base64Decode(parts[2]);
      
      final remotePublicKeyBytes = base64Decode(senderX25519PublicKeyBase64);
      final remotePublicKey = SimplePublicKey(remotePublicKeyBytes, type: KeyPairType.x25519);
      
      final sharedSecret = await X25519().sharedSecretKey(
        keyPair: _x25519KeyPair!,
        remotePublicKey: remotePublicKey,
      );
      
      final cipher = AesGcm.with256bits();
      final secretBox = SecretBox(
        cipherText,
        nonce: nonce,
        mac: Mac(macBytes),
      );
      
      final decryptedBytes = await cipher.decrypt(
        secretBox,
        secretKey: sharedSecret,
      );
      
      return utf8.decode(decryptedBytes);
    } catch (e) {
      print('[CRYPTO] Errore decifratura: $e');
      return '[Errore di decifratura: Messaggio cifrato non leggibile]';
    }
  }

  /// Firma un messaggio con la chiave privata Ed25519
  Future<String> signMessage(String message) async {
    if (_keyPair == null) {
      throw Exception('Chiavi non inizializzate');
    }

    final messageBytes = utf8.encode(message);
    final signature = await _algorithm.sign(messageBytes, keyPair: _keyPair!);
    
    return base64Encode(signature.bytes);
  }

  /// Verifica la firma di un messaggio usando la chiave pubblica del mittente
  Future<bool> verifySignature({
    required String message,
    required String signatureBase64,
    required String publicKeyBase64,
  }) async {
    try {
      final messageBytes = utf8.encode(message);
      final signatureBytes = base64Decode(signatureBase64);
      final publicKeyBytes = base64Decode(publicKeyBase64);
      
      final publicKey = SimplePublicKey(publicKeyBytes, type: KeyPairType.ed25519);
      final signature = Signature(signatureBytes, publicKey: publicKey);
      
      final isValid = await _algorithm.verify(messageBytes, signature: signature);
      return isValid;
    } catch (e) {
      return false;
    }
  }

  /// Genera un challenge casuale per l'handshake
  String generateChallenge() {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final random = DateTime.now().microsecondsSinceEpoch;
    return '$timestamp-$random';
  }

  /// Crea un hash della chiave pubblica per usarlo come ID univoco
  String getPublicKeyHash(String publicKeyBase64) {
    return publicKeyBase64.substring(0, 16); // Primi 16 caratteri come ID
  }

  /// Resetta le chiavi (per debug o reset dell'app)
  Future<void> resetKeys() async {
    await _secureStorage.delete(key: _privateKeyKey);
    await _secureStorage.delete(key: _publicKeyKey);
    _keyPair = null;
    _publicKeyBase64 = null;
    _x25519KeyPair = null;
    _x25519PublicKeyBase64 = null;
    await _loadOrGenerateKeys();
  }
}
