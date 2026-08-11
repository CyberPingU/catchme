import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import '../models/nearby_user.dart';
import '../models/contact.dart';
import '../services/proximity_service.dart';
import '../services/storage_service.dart';
import '../models/chat_message.dart';
import '../screens/chat_screen.dart';
import 'dart:async';

class UserProfileCard extends StatefulWidget {
  final NearbyUser user;
  final String? initialAvatarPath;
  final ProximityService bluetoothService;
  final VoidCallback? onActionDone;

  const UserProfileCard({
    Key? key,
    required this.user,
    this.initialAvatarPath,
    required this.bluetoothService,
    this.onActionDone,
  }) : super(key: key);

  @override
  State<UserProfileCard> createState() => _UserProfileCardState();
}

class _UserProfileCardState extends State<UserProfileCard> {
  final _storageService = StorageService();
  String? _avatarPath;
  bool _hasRequestedPhoto = false;
  StreamSubscription? _messageSubscription;
  bool _isConnecting = false;
  Contact? _contact;

  @override
  void initState() {
    super.initState();
    _avatarPath = widget.initialAvatarPath;
    _checkExistingPhoto();
    _listenForPhotoResponse();
    _checkContact();
  }

  Future<void> _checkContact() async {
    final contact = await _storageService.getContactById(widget.user.endpointId);
    if (mounted) {
      setState(() {
        _contact = contact;
      });
    }
  }

  @override
  void dispose() {
    _messageSubscription?.cancel();
    super.dispose();
  }

  Future<void> _checkExistingPhoto() async {
    if (_avatarPath == null) {
      final photoFile = await _storageService.getContactPhoto(widget.user.endpointId);
      if (photoFile != null && await photoFile.exists()) {
        setState(() {
          _avatarPath = photoFile.path;
        });
      }
    }
  }

  void _listenForPhotoResponse() {
    _messageSubscription = widget.bluetoothService.messages.listen((message) {
      if (message.isSent) return;
      if (message.endpointId == widget.user.endpointId || 
          message.endpointId == widget.user.publicKey) {
        if (message.type == MessageType.photoResponse && message.photoData != null) {
          _saveAndShowReceivedPhoto(message.photoData!);
        } else if (message.type == MessageType.photoRejected) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Richiesta foto rifiutata dall\'utente')),
            );
          }
        }
      }
    });
  }

  Future<void> _saveAndShowReceivedPhoto(String base64Photo) async {
    try {
      final photoBytes = base64Decode(base64Photo);
      final filePath = await _storageService.saveContactPhoto(
        widget.user.endpointId,
        photoBytes,
      );

      final contact = await _storageService.getContactById(widget.user.endpointId);
      if (contact != null) {
        await _storageService.updateContactAvatar(widget.user.endpointId, filePath);
      }

      if (mounted) {
        setState(() {
          _avatarPath = filePath;
          _hasRequestedPhoto = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Foto ricevuta e mostrata')),
        );
      }
    } catch (e) {
      debugPrint('[UserProfileCard] Errore salvataggio foto: $e');
    }
  }

  void _showFullscreenPhoto() {
    if (_avatarPath == null) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            backgroundColor: Colors.black,
            iconTheme: const IconThemeData(color: Colors.white),
            title: Text(widget.user.nickname, style: const TextStyle(color: Colors.white)),
          ),
          body: Center(
            child: InteractiveViewer(
              minScale: 0.5,
              maxScale: 4.0,
              child: Image.file(
                File(_avatarPath!),
                fit: BoxFit.contain,
                width: double.infinity,
                height: double.infinity,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _requestPhoto() async {
    if (_hasRequestedPhoto) return;

    if (!widget.user.isConnected) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Impossibile richiedere: utente non connesso')),
      );
      return;
    }

    await widget.bluetoothService.sendPhotoRequest(widget.user.endpointId);
    if (!mounted) return;
    setState(() => _hasRequestedPhoto = true);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Richiesta foto inviata')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final user = widget.user;

    // Costruisci la stringa dei dettagli di profilo
    final List<String> details = [];
    if (user.age != null) details.add('${user.age} anni');
    if (user.gender != null && user.gender!.isNotEmpty) details.add(user.gender!);
    final detailsText = details.join(' • ');

    return SafeArea(
      child: Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: theme.scaffoldBackgroundColor,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // Linea trascinamento bottom sheet
            Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.only(bottom: 20),
              decoration: BoxDecoration(
                color: Colors.grey.shade400,
                borderRadius: BorderRadius.circular(2),
              ),
            ),

            // Foto profilo grande
            GestureDetector(
              onTap: _avatarPath != null ? _showFullscreenPhoto : null,
              child: Stack(
                alignment: Alignment.bottomRight,
                children: [
                  CircleAvatar(
                    radius: 70,
                    backgroundColor: theme.colorScheme.primaryContainer,
                    backgroundImage: _avatarPath != null ? FileImage(File(_avatarPath!)) : null,
                    child: _avatarPath == null
                        ? Text(
                            user.nickname[0].toUpperCase(),
                            style: TextStyle(
                              fontSize: 50,
                              fontWeight: FontWeight.bold,
                              color: theme.colorScheme.onPrimaryContainer,
                            ),
                          )
                        : null,
                  ),
                  if (_avatarPath != null)
                    CircleAvatar(
                      radius: 20,
                      backgroundColor: theme.colorScheme.primary,
                      child: const Icon(Icons.fullscreen, color: Colors.white, size: 20),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // Nickname
            Text(
              user.nickname,
              style: theme.textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),

            // Età • Sesso
            if (detailsText.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                detailsText,
                style: theme.textTheme.titleMedium?.copyWith(
                  color: Colors.grey.shade600,
                ),
              ),
            ],

            const SizedBox(height: 8),
            // Distanza/Status
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: user.isConnected ? Colors.green.shade50 : Colors.grey.shade100,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Text(
                user.isConnected ? 'Nelle vicinanze (${user.status})' : 'Sconnesso / Offline',
                style: TextStyle(
                  color: user.isConnected ? Colors.green.shade700 : Colors.grey.shade600,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(height: 20),

            // Biografia (Bio)
            if (user.bio != null && user.bio!.isNotEmpty) ...[
              const Divider(),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Biografia',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.primary,
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  user.bio!,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ),
              const SizedBox(height: 8),
            ],
            const Divider(),
            if (_contact != null) ...[
              SwitchListTile(
                secondary: Icon(
                  _contact!.proximityAlertEnabled ? Icons.notifications_active : Icons.notifications_off,
                  color: _contact!.proximityAlertEnabled ? theme.colorScheme.primary : Colors.grey,
                ),
                title: const Text('Notifica Prossimità'),
                subtitle: const Text('Avvisami se questo contatto è vicino'),
                value: _contact!.proximityAlertEnabled,
                onChanged: (val) async {
                  final updatedContact = _contact!.copyWith(proximityAlertEnabled: val);
                  await _storageService.saveContact(updatedContact);
                  setState(() {
                    _contact = updatedContact;
                  });
                  widget.onActionDone?.call();
                },
              ),
              const Divider(),
            ],
            const SizedBox(height: 16),

            // Azione Richiesta Foto (se connesso e non ha ancora foto)
            if (user.isConnected && _avatarPath == null) ...[
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  icon: const Icon(Icons.camera_alt),
                  label: Text(_hasRequestedPhoto ? 'Richiesta inviata...' : 'Richiedi Foto Profilo'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: theme.colorScheme.secondaryContainer,
                    foregroundColor: theme.colorScheme.onSecondaryContainer,
                  ),
                  onPressed: _hasRequestedPhoto ? null : _requestPhoto,
                ),
              ),
              const SizedBox(height: 12),
            ],

            // Azioni Principali
            Row(
              children: [
                // Blocca
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.block, color: Colors.red),
                    label: const Text('Blocca', style: TextStyle(color: Colors.red)),
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Colors.red),
                    ),
                    onPressed: () async {
                      final navigator = Navigator.of(context);
                      final scaffoldMessenger = ScaffoldMessenger.of(context);
                      await _storageService.addBlockedUser(user.endpointId);
                      if (!mounted) return;
                      navigator.pop();
                      scaffoldMessenger.showSnackBar(
                        const SnackBar(content: Text('Utente bloccato')),
                      );
                      widget.onActionDone?.call();
                    },
                  ),
                ),
                const SizedBox(width: 12),

                // Azione Primaria (Connetti / Salva / Chat)
                Expanded(
                  flex: 2,
                  child: _buildPrimaryActionButton(context, theme),
                ),
              ],
            ),
          ],
        ),
      ),
    ));
  }

  Widget _buildPrimaryActionButton(BuildContext context, ThemeData theme) {
    final user = widget.user;

    // Se non connesso e non pendente -> Richiedi Connessione
    if (!user.isConnected && !user.isPending) {
      return ElevatedButton.icon(
        icon: const Icon(Icons.connect_without_contact),
        label: const Text('Connetti'),
        onPressed: _isConnecting ? null : () async {
          setState(() => _isConnecting = true);
          widget.bluetoothService.requestConnection(user.endpointId);
          Navigator.pop(context);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Richiesta di connessione inviata')),
          );
          widget.onActionDone?.call();
        },
      );
    }

    // Se in attesa (pendente)
    if (user.isPending) {
      return const ElevatedButton(
        onPressed: null,
        child: Text('In attesa...'),
      );
    }

    // Se connesso ma non ancora contatti/rubrica
    if (user.isConnected && !user.isVerified) {
      return ElevatedButton.icon(
        icon: const Icon(Icons.save),
        label: const Text('Salva Contatto'),
        onPressed: () async {
          final navigator = Navigator.of(context);
          final scaffoldMessenger = ScaffoldMessenger.of(context);
          await widget.bluetoothService.saveContact(user.endpointId);
          if (!mounted) return;
          navigator.pop();
          scaffoldMessenger.showSnackBar(
            const SnackBar(content: Text('Salvato in Rubrica')),
          );
          widget.onActionDone?.call();
        },
      );
    }

    // Se connesso e verificato (amici) -> Apri Chat
    return ElevatedButton.icon(
      icon: const Icon(Icons.chat),
      label: const Text('Invia Messaggio'),
      onPressed: () {
        Navigator.pop(context);
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => ChatScreen(
              user: user,
              bluetoothService: widget.bluetoothService,
            ),
          ),
        );
        widget.onActionDone?.call();
      },
    );
  }
}
