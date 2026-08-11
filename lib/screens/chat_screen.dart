import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import '../models/nearby_user.dart';
import '../models/chat_message.dart';
import '../services/proximity_service.dart';
import '../services/storage_service.dart';
import '../services/crypto_service.dart';
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';

class ChatScreen extends StatefulWidget {
  final NearbyUser user;
  final ProximityService bluetoothService;

  const ChatScreen({
    super.key,
    required this.user,
    required this.bluetoothService,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _messageController = TextEditingController();
  final _storageService = StorageService();
  final _cryptoService = CryptoService();
  final List<ChatMessage> _messages = [];
  final List<String> _pendingMessages = []; // Messaggi in attesa di connessione
  bool _hasRequestedPhoto = false;
  bool _isLocationShared = false;
  StreamSubscription<ChatMessage>? _messageSubscription;
  StreamSubscription<List<NearbyUser>>? _discoveredUsersSubscription;
  
  // Stato dinamico dell'utente corrente
  NearbyUser? _currentNearbyUser;
  bool _isReconnecting = false;
  
  // Ottieni l'ID permanente dell'utente
  String get _permanentId {
    if (widget.user.publicKey != null && widget.user.publicKey!.isNotEmpty) {
      try {
        return _cryptoService.getPublicKeyHash(widget.user.publicKey!);
      } catch (e) {
        // Fallback in caso di errore
      }
    }
    // Fallback all'endpointId se non c'è chiave pubblica o se è vuota
    return widget.user.endpointId;
  }
  
  // Ottieni l'endpointId aggiornato in tempo reale
  String? get _currentEndpointId {
    if (_currentNearbyUser != null && _currentNearbyUser!.isConnected) {
      return _currentNearbyUser!.endpointId;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    // Carica la cronologia dei messaggi passati
    _loadChatHistory();
    
    // Imposta questa chat come attiva tramite chiave pubblica
    widget.bluetoothService.setActiveChatPublicKey(widget.user.publicKey);
    
    // Inizializza lo stato corrente
    _currentNearbyUser = widget.user;
    
    // Listener per gli utenti scoperti - traccia lo stato in tempo reale
    _discoveredUsersSubscription = widget.bluetoothService.discoveredUsers.listen((users) {
      NearbyUser? foundUser;
      
      // Cerca per endpointId (che sotto WebSockets coincide con il publicKeyHash ed è stabile)
      for (final user in users) {
        if (user.endpointId == widget.user.endpointId) {
          foundUser = user;
          break;
        }
      }
      
      // Fallback per chiave pubblica (se l'endpointId differisce per Bluetooth locale)
      if (foundUser == null && widget.user.publicKey != null && widget.user.publicKey!.isNotEmpty) {
        try {
          final targetHash = _cryptoService.getPublicKeyHash(widget.user.publicKey!);
          for (final user in users) {
            if (user.publicKey != null && user.publicKey!.isNotEmpty) {
              final userHash = _cryptoService.getPublicKeyHash(user.publicKey!);
              if (userHash == targetHash) {
                foundUser = user;
                break;
              }
            }
          }
        } catch (_) {}
      }
      
      setState(() {
        if (foundUser != null) {
          _currentNearbyUser = foundUser;
          _isReconnecting = !foundUser.isConnected;
          
          if (widget.bluetoothService.isConnected && _pendingMessages.isNotEmpty) {
            _sendPendingMessages();
          }
        } else {
          // Utente non più nelle vicinanze
          _currentNearbyUser = widget.user.copyWith(isConnected: false);
          _isReconnecting = false;
        }
      });
    });
    
    _messageSubscription = widget.bluetoothService.messages.listen((message) {
      if (message.endpointId == _currentEndpointId ||
          message.endpointId == widget.user.endpointId) {
        setState(() {
          final index = _messages.indexWhere((m) => m.id == message.id);
          if (index != -1) {
            _messages[index] = _messages[index].copyWith(
              status: message.status,
              localFilePath: message.localFilePath ?? _messages[index].localFilePath,
            );
          } else {
            _messages.add(message);
          }
        });
        _handleIncomingMessage(message);
      }
    });

    // Spostato qui per garantire che il listener del flusso sia già attivo
    _loadChatHistory();
  }

  Future<void> _loadChatHistory() async {
    // Carica lo stato della condivisione posizione
    final contact = await _storageService.getContactById(_permanentId);
    setState(() {
      _isLocationShared = contact?.isLocationShared ?? false;
    });

    // Usa l'ID permanente per caricare la cronologia
    final history = await _storageService.getChatHistory(_permanentId);
    setState(() {
      for (final msg in history) {
        if (!_messages.any((m) => m.id == msg.id)) {
          _messages.add(msg);
        }
      }
      // Ordina cronologicamente per sicurezza
      _messages.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    });
  }

  void _sendMessage() {
    final text = _messageController.text.trim();
    if (text.isEmpty) return;
    if (text.length > 500) return;

    if (widget.bluetoothService.isConnected) {
      widget.bluetoothService.sendMessage(_permanentId, text);
      _messageController.clear();
    } else {
      _pendingMessages.add(text);
      
      final tempMessage = ChatMessage(
        id: 'temp_${DateTime.now().millisecondsSinceEpoch}',
        endpointId: _permanentId,
        message: text,
        timestamp: DateTime.now(),
        isSent: true,
        status: MessageStatus.sending,
      );
      setState(() => _messages.add(tempMessage));
      _messageController.clear();
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Messaggio accodato (in attesa di connessione)')),
        );
      }
    }
  }

  Future<void> _selectAndSendMedia() async {
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: const Text('Galleria Immagini'),
              onTap: () async {
                final navigator = Navigator.of(context);
                navigator.pop();
                final picker = ImagePicker();
                final picked = await picker.pickImage(source: ImageSource.gallery);
                if (picked != null) {
                  await _sendAttachment(File(picked.path), MessageType.image);
                }
              },
            ),
            ListTile(
              leading: const Icon(Icons.photo_camera),
              title: const Text('Scatta Foto'),
              onTap: () async {
                final navigator = Navigator.of(context);
                navigator.pop();
                final picker = ImagePicker();
                final picked = await picker.pickImage(source: ImageSource.camera);
                if (picked != null) {
                  await _sendAttachment(File(picked.path), MessageType.image);
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _sendAttachment(File file, MessageType type, {String? customFileName}) async {
    // Verifica dimensioni (es. limite 2MB)
    final size = await file.length();
    if (size > 2 * 1024 * 1024) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('File troppo grande. Il limite massimo è di 2 MB.')),
        );
      }
      return;
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Cifratura ed invio allegato...')),
      );
    }

    try {
      await widget.bluetoothService.sendMediaMessage(
        _permanentId,
        file,
        type,
        customFileName: customFileName,
      );
      // Ricarica la cronologia locale della chat per mostrare il messaggio inserito
      await _loadChatHistory();
    } catch (e) {
      debugPrint('[ChatScreen] Errore invio allegato: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Errore invio: $e')),
        );
      }
    }
  }

  bool _isSendingPending = false;

  // Invia tutti i messaggi in attesa quando la connessione si stabilisce
  Future<void> _sendPendingMessages() async {
    if (_isSendingPending || _pendingMessages.isEmpty) return;
    if (!widget.bluetoothService.isConnected) return;
    _isSendingPending = true;
    
    try {
      // Crea una copia locale per evitare modifiche concorrenti
      final messagesToSend = List<String>.from(_pendingMessages);
      _pendingMessages.clear();
      
      for (final message in messagesToSend) {
        await widget.bluetoothService.sendMessage(_permanentId, message);
      }
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Messaggi in sospeso inviati')),
        );
      }
    } catch (e) {
      debugPrint('Errore invio messaggi pendenti: $e');
    } finally {
      _isSendingPending = false;
    }
  }

  Future<void> _requestPhoto() async {
    if (_hasRequestedPhoto) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Hai già richiesto la foto')),
        );
      }
      return;
    }

    // Ottieni l'endpointId aggiornato
    final endpointId = _currentEndpointId;
    
    if (endpointId == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Impossibile richiedere: utente non connesso')),
        );
      }
      return;
    }

    await widget.bluetoothService.sendPhotoRequest(endpointId);
    setState(() => _hasRequestedPhoto = true);
    
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Richiesta foto inviata')),
      );
    }
  }

  Future<void> _handleIncomingMessage(ChatMessage message) async {
    if (message.isSent) return;
    if (message.type == MessageType.photoRequest) {
      _showPhotoRequestDialog();
    } else if (message.type == MessageType.photoResponse && message.photoData != null) {
      await _saveReceivedPhoto(message.photoData!);
    } else if (message.type == MessageType.photoRejected) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('L\'utente ha rifiutato di condividere la foto')),
        );
      }
    } else if (message.type == MessageType.locationResponse) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Posizione ricevuta: ${message.message}')),
        );
      }
    } else if (message.type == MessageType.locationRejected) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('L\'utente ha rifiutato di condividere la posizione')),
        );
      }
    }
  }

  Future<void> _respondToLocation({required bool permanent, required String messageId}) async {
    await widget.bluetoothService.sendLocationResponse(_permanentId, permanent: permanent);
    if (permanent) {
      setState(() {
        _isLocationShared = true;
      });
    }
    _updateRequestMessage(messageId, 'Hai condiviso la posizione ${permanent ? "permanentemente" : "una volta"}');
  }

  Future<void> _rejectLocation({required String messageId}) async {
    await widget.bluetoothService.rejectLocationRequest(_permanentId);
    _updateRequestMessage(messageId, 'Hai rifiutato la richiesta di posizione');
  }

  void _updateRequestMessage(String messageId, String newText) async {
    final index = _messages.indexWhere((m) => m.id == messageId);
    if (index != -1) {
      final updated = ChatMessage(
        id: messageId,
        endpointId: _messages[index].endpointId,
        message: newText,
        timestamp: _messages[index].timestamp,
        isSent: _messages[index].isSent,
        type: MessageType.text, // Diventa testo semplice
      );
      setState(() {
        _messages[index] = updated;
      });
      await _storageService.saveChatMessage(_permanentId, updated);
    }
  }

  Future<void> _showPhotoRequestDialog() async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Richiesta Foto'),
        content: Text('${widget.user.nickname} chiede di vedere la tua foto. Accetti di mostrargliela?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Rifiuta'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Accetta'),
          ),
        ],
      ),
    );

    if (result == true) {
      await _sendPhoto();
    } else {
      await widget.bluetoothService.sendPhotoRejection(widget.user.endpointId);
    }
  }

  Future<void> _sendPhoto() async {
    final profile = await _storageService.loadProfile();
    if (profile?.avatarPath == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Non hai una foto profilo da condividere')),
        );
      }
      return;
    }

    try {
      final file = File(profile!.avatarPath!);
      if (!await file.exists()) {
        throw Exception('File foto non trovato');
      }

      // Comprimi l'immagine a 120x120 pixel usando la libreria image
      final originalBytes = await file.readAsBytes();
      final originalImage = img.decodeImage(originalBytes);
      
      List<int> compressedBytes;
      if (originalImage != null) {
        final resizedImage = img.copyResize(originalImage, width: 120, height: 120);
        compressedBytes = img.encodeJpg(resizedImage, quality: 85);
      } else {
        throw Exception('Impossibile decodificare l\'immagine');
      }

      // Converti in Base64
      final base64Photo = base64Encode(compressedBytes);

      // Invia la foto
      await widget.bluetoothService.sendPhotoResponse(
        widget.user.endpointId,
        base64Photo,
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Foto inviata con successo')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Errore nell\'invio della foto: $e')),
        );
      }
    }
  }

  Future<void> _saveReceivedPhoto(String base64Photo) async {
    try {
      // Decodifica Base64
      final photoBytes = base64Decode(base64Photo);

      // Salva localmente usando l'ID permanente
      final filePath = await _storageService.saveContactPhoto(
        _permanentId,
        photoBytes,
      );

      // Aggiorna il contatto nel database usando l'ID permanente
      final contact = await _storageService.getContactById(_permanentId);
      if (contact != null) {
        await _storageService.updateContactAvatar(_permanentId, filePath);
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Foto ricevuta e salvata')),
        );

        // Aggiorna l'UI
        setState(() {});
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Errore nel salvataggio della foto: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.user.nickname),
        actions: [
          if (_isLocationShared)
            IconButton(
              icon: const Icon(Icons.location_off, color: Colors.orange),
              tooltip: 'Revoca Condivisione Posizione',
              onPressed: () async {
                await widget.bluetoothService.revokeLocationSharing(_permanentId);
                if (!mounted) return;
                setState(() {
                  _isLocationShared = false;
                });
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Condivisione posizione revocata')),
                );
              },
            ),
          IconButton(
            icon: const Icon(Icons.my_location),
            tooltip: 'Richiedi Posizione',
            onPressed: _currentNearbyUser != null && _currentNearbyUser!.isConnected
                ? () async {
                    await widget.bluetoothService.sendLocationRequest(_permanentId);
                    if (!mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Richiesta posizione inviata')),
                    );
                  }
                : null,
          ),
          IconButton(
            icon: const Icon(Icons.photo_camera),
            tooltip: 'Richiedi Foto',
            onPressed: _requestPhoto,
          ),
          PopupMenuButton<String>(
            onSelected: (value) async {
              if (value == 'block') {
                final navigator = Navigator.of(context);
                await _storageService.addBlockedUser(_permanentId);
                await widget.bluetoothService.revokeLocationSharing(_permanentId);
                if (!mounted) return;
                navigator.pop();
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Contatto bloccato')),
                );
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'block',
                child: Text('Blocca contatto', style: TextStyle(color: Colors.red)),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _messages.isEmpty
                ? const Center(child: Text('Nessun messaggio'))
                : ListView.builder(
                    reverse: true,
                    padding: const EdgeInsets.all(16),
                    itemCount: _messages.length,
                    itemBuilder: (context, index) {
                      final message = _messages[_messages.length - 1 - index];
                      return Align(
                        alignment: message.isSent
                            ? Alignment.centerRight
                            : Alignment.centerLeft,
                        child: Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          padding: const EdgeInsets.only(
                            left: 14,
                            right: 14,
                            top: 8,
                            bottom: 6,
                          ),
                          decoration: BoxDecoration(
                            color: message.isSent
                                ? Theme.of(context).colorScheme.primary
                                : Theme.of(context).colorScheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _buildMessageContent(message),
                              const SizedBox(height: 4),
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                mainAxisAlignment: MainAxisAlignment.end,
                                children: [
                                  Text(
                                    _formatMessageTime(message.timestamp),
                                    style: TextStyle(
                                      fontSize: 10,
                                      color: message.isSent
                                          ? Theme.of(context).colorScheme.onPrimary.withValues(alpha: 0.6)
                                          : Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5),
                                    ),
                                  ),
                                  if (message.isSent) ...[
                                    const SizedBox(width: 4),
                                    _buildMessageStatusIcon(message.status),
                                  ],
                                ],
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
          SafeArea(
            child: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.1),
                    blurRadius: 4,
                    offset: const Offset(0, -2),
                  ),
                ],
              ),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.attach_file),
                    onPressed: _currentNearbyUser != null ? _selectAndSendMedia : null,
                    tooltip: 'Invia allegato',
                  ),
                  Expanded(
                    child: TextField(
                      controller: _messageController,
                      maxLength: 500,
                      buildCounter: (context, {required currentLength, required isFocused, maxLength}) => null,
                      decoration: InputDecoration(
                        hintText: _currentNearbyUser != null
                            ? (_isReconnecting
                                ? 'Riconnessione in corso...'
                                : 'Scrivi un messaggio...')
                            : 'Utente non nelle vicinanze',
                        border: const OutlineInputBorder(),
                        counterText: '', // nasconde il counter di default
                      ),
                      enabled: _currentNearbyUser != null,
                      onSubmitted: (_) => _sendMessage(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (_isReconnecting)
                    const Padding(
                      padding: EdgeInsets.all(12.0),
                      child: SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  else
                    IconButton(
                      icon: const Icon(Icons.send),
                      onPressed: _currentNearbyUser != null ? _sendMessage : null,
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMessageContent(ChatMessage message) {
    if (message.type == MessageType.locationRequest && !message.isSent) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            message.message,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurface,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: () => _respondToLocation(permanent: false, messageId: message.id),
                child: const Text('Solo Ora', style: TextStyle(fontSize: 12)),
              ),
              const SizedBox(width: 8),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: () => _respondToLocation(permanent: true, messageId: message.id),
                child: const Text('Sempre', style: TextStyle(fontSize: 12)),
              ),
              const SizedBox(width: 8),
              TextButton(
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: () => _rejectLocation(messageId: message.id),
                child: const Text('Rifiuta', style: TextStyle(color: Colors.red, fontSize: 12)),
              ),
            ],
          ),
        ],
      );
    } else if (message.type == MessageType.image) {
      final fileExists = message.localFilePath != null && File(message.localFilePath!).existsSync();
      return GestureDetector(
        onTap: fileExists
            ? () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => Scaffold(
                      backgroundColor: Colors.black,
                      appBar: AppBar(
                        backgroundColor: Colors.black,
                        foregroundColor: Colors.white,
                        title: Text(message.message),
                      ),
                      body: Center(
                        child: InteractiveViewer(
                          maxScale: 4.0,
                          child: Image.file(File(message.localFilePath!)),
                        ),
                      ),
                    ),
                  ),
                );
              }
            : null,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 240, maxHeight: 240),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: fileExists
                ? Image.file(
                    File(message.localFilePath!),
                    fit: BoxFit.cover,
                  )
                : Container(
                    padding: const EdgeInsets.all(12),
                    color: Colors.grey.shade800,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: const [
                        Icon(Icons.broken_image, color: Colors.white54),
                        SizedBox(width: 8),
                        Text('Immagine non trovata', style: TextStyle(color: Colors.white54, fontSize: 13)),
                      ],
                    ),
                  ),
          ),
        ),
      );
    } else if (message.type == MessageType.file) {
      final fileExists = message.localFilePath != null && File(message.localFilePath!).existsSync();
      return InkWell(
        onTap: fileExists
            ? () async {
                try {
                  final fileUri = Uri.file(message.localFilePath!);
                  await launchUrl(fileUri, mode: LaunchMode.externalApplication);
                } catch (e) {
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Impossibile aprire il file: $e')),
                    );
                  }
                }
              }
            : null,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.insert_drive_file,
                color: message.isSent
                    ? Theme.of(context).colorScheme.onPrimary
                    : Theme.of(context).colorScheme.onSurface,
                size: 28,
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      message.message,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: message.isSent
                            ? Theme.of(context).colorScheme.onPrimary
                            : Theme.of(context).colorScheme.onSurface,
                        decoration: fileExists ? TextDecoration.underline : null,
                      ),
                    ),
                    Text(
                      fileExists ? 'Tocca per aprire' : 'File non disponibile',
                      style: TextStyle(
                        fontSize: 10,
                        color: message.isSent
                            ? Theme.of(context).colorScheme.onPrimary.withValues(alpha: 0.7)
                            : Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    } else {
      return Text(
        message.message,
        style: TextStyle(
          color: message.isSent
              ? Theme.of(context).colorScheme.onPrimary
              : Theme.of(context).colorScheme.onSurface,
        ),
      );
    }
  }

  String _formatMessageTime(DateTime dt) {
    final hour = dt.hour.toString().padLeft(2, '0');
    final minute = dt.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  Widget _buildMessageStatusIcon(MessageStatus status) {
    Color color = Colors.white38;
    IconData icon = Icons.access_time;

    if (status == MessageStatus.sent) {
      icon = Icons.check;
      color = Colors.white60;
    } else if (status == MessageStatus.delivered) {
      icon = Icons.done_all;
      color = Colors.cyanAccent;
    }

    return Icon(
      icon,
      size: 14,
      color: color,
    );
  }

  @override
  void dispose() {
    _messageSubscription?.cancel();
    _discoveredUsersSubscription?.cancel();
    widget.bluetoothService.setActiveChatPublicKey(null);
    _messageController.dispose();
    super.dispose();
  }
}
