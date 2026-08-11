import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import '../models/user_profile.dart';
import '../services/storage_service.dart';
import '../services/auth_service.dart';
import '../services/proximity_service.dart';
import '../services/crypto_service.dart';
import '../services/push_service.dart';
import '../services/notification_service.dart';
import 'package:url_launcher/url_launcher.dart';

// Costante compile-time (stessa logica di push_service.dart)
const _useFcmBuild = String.fromEnvironment('PUSH_PROVIDER', defaultValue: 'fcm') != 'unifiedpush';

class ProfileScreen extends StatefulWidget {
   final UserProfile? profile;
   final Function(UserProfile)? onProfileSaved;

   const ProfileScreen({super.key, this.profile, this.onProfileSaved});

   @override
   State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nicknameController = TextEditingController();
  final _ageController = TextEditingController();
  final _bioController = TextEditingController();
  final _storageService = StorageService();
  final _authService = AuthService();
  final _bluetoothService = ProximityService();
  final _cryptoService = CryptoService();
  final _pushService = PushService();
  final _notificationService = NotificationService();

  UserStatus _selectedStatus = UserStatus.available;
  String? _selectedGender;
  String? _avatarPath;
  DateTime? _birthDate;
  bool _isLockEnabled = false;
  bool _hasSavedPin = false;
  bool _isLoading = false;
  bool _isBackgroundSyncEnabled = true;
  bool _isSendingLocation = false;
  String _selectedPushProvider = _useFcmBuild ? 'fcm' : 'unifiedpush';
  String? _selectedDistributor;
  List<String> _distributors = [];

  int _selectedRadarRange = 500;

  String _formatBirthDate(DateTime date) {
    final today = DateTime.now();
    int calculatedAge = today.year - date.year;
    if (today.month < date.month || (today.month == date.month && today.day < date.day)) {
      calculatedAge--;
    }
    return '${date.day}/${date.month}/${date.year} ($calculatedAge anni)';
  }

  Future<void> _selectBirthDate(BuildContext context) async {
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: _birthDate ?? DateTime(2000),
      firstDate: DateTime(1900),
      lastDate: DateTime.now(),
    );
    if (picked != null) {
      setState(() {
        _birthDate = picked;
        _ageController.text = _formatBirthDate(picked);
      });
    }
  }

  @override
  void initState() {
    super.initState();
    _loadProfile();
    _loadSecuritySettings();
    _loadAppSettings();
    _loadPushSettings();
  }

  @override
  void didUpdateWidget(ProfileScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.profile != oldWidget.profile && widget.profile != null) {
      _updateFieldsFromProfile(widget.profile!);
    }
  }

  Future<void> _loadProfile() async {
    if (widget.profile != null) {
      _updateFieldsFromProfile(widget.profile!);
    } else {
      setState(() => _isLoading = true);
      final profile = await _storageService.loadProfile();
      if (profile != null && mounted) {
        _updateFieldsFromProfile(profile);
      }
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  void _updateFieldsFromProfile(UserProfile profile) {
    setState(() {
      _nicknameController.text = profile.nickname;
      _selectedStatus = profile.status;
      _birthDate = profile.birthDate;
      _ageController.text = _birthDate != null ? _formatBirthDate(_birthDate!) : '';
      _selectedGender = profile.gender;
      _bioController.text = profile.bio ?? '';
      _avatarPath = profile.avatarPath;
      _selectedPushProvider = _useFcmBuild ? profile.pushProvider : 'unifiedpush';
      _selectedRadarRange = profile.radarRange;
    });
  }

  Future<void> _loadSecuritySettings() async {
    final lockEnabled = await _authService.isLockEnabled();
    final hasSavedPin = await _authService.hasSavedPin();
    setState(() {
      _isLockEnabled = lockEnabled;
      _hasSavedPin = hasSavedPin;
    });
  }

  Future<void> _loadAppSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _isBackgroundSyncEnabled = prefs.getBool('background_sync_enabled') ?? true;
    });
  }

  Future<void> _toggleBackgroundSync(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('background_sync_enabled', value);
    setState(() {
      _isBackgroundSyncEnabled = value;
    });
    
    try {
      if (value) {
        final hasPermissions = await _bluetoothService.requestPermissions();
        if (hasPermissions) {
          FlutterBackgroundService().invoke('startService');
        }
      } else {
        FlutterBackgroundService().invoke('stopService');
      }
    } catch (e) {
      print('Errore impostazione background execution: $e');
    }
  }

  Future<void> _sendLocationManually() async {
    setState(() => _isSendingLocation = true);
    
    final success = await _bluetoothService.sendLocationUpdateManually();
    
    setState(() => _isSendingLocation = false);
    
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            success 
                ? 'Posizione inviata con successo al server!' 
                : 'Errore durante l\'invio della posizione. Verifica la connessione.',
          ),
          backgroundColor: success ? Colors.green : Colors.red,
        ),
      );
    }
  }

  Future<void> _loadPushSettings() async {
    final distributors = await _pushService.getUnifiedPushDistributors();
    final active = await _pushService.getActiveDistributor();
    setState(() {
      _distributors = distributors;
      if (active != null && active.isNotEmpty) {
        _selectedDistributor = active;
      }
    });
  }

  Future<void> _changePushProvider(String provider) async {
    if (provider == 'fcm') {
      await _pushService.unregisterUnifiedPush();
      final fcmToken = await _pushService.getFCMToken();
      setState(() {
        _selectedPushProvider = 'fcm';
      });
      if (widget.profile != null) {
        final updated = widget.profile!.copyWith(
          pushProvider: 'fcm',
          pushToken: fcmToken,
        );
        await _storageService.saveProfile(updated);
        widget.onProfileSaved?.call(updated);
      }
    } else if (provider == 'unifiedpush') {
      if (_distributors.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Nessun distributore UnifiedPush (es. ntfy) rilevato sul dispositivo.')),
        );
        return;
      }
      if (_distributors.length == 1) {
        await _pushService.registerUnifiedPush(_distributors.first);
        setState(() {
          _selectedPushProvider = 'unifiedpush';
          _selectedDistributor = _distributors.first;
        });
      } else {
        _showDistributorDialog();
      }
    }
  }

  void _showDistributorDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Seleziona Distributore UnifiedPush'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: _distributors.map((d) => ListTile(
            title: Text(d),
            onTap: () async {
              Navigator.pop(context);
              await _pushService.registerUnifiedPush(d);
              setState(() {
                _selectedPushProvider = 'unifiedpush';
                _selectedDistributor = d;
              });
            },
          )).toList(),
        ),
      ),
    );
  }

  Future<void> _sendTestPush() async {
    final profile = await _storageService.loadProfile();
    final provider = _useFcmBuild ? (profile?.pushProvider ?? 'fcm') : 'unifiedpush';

    if (provider == 'fcm') {
      // FCM: mostra una notifica locale direttamente (il server FCM non è raggiungibile dal device)
      await _notificationService.showNewMessageNotification(
        'test_system',
        'CatchMe Test',
        '🔔 FCM configurato correttamente! Le notifiche funzionano.',
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Notifica locale FCM mostrata con successo!'),
            backgroundColor: Colors.green,
          ),
        );
      }
      return;
    }

    // UnifiedPush: POST all'endpoint registrato
    final endpoint = profile?.pushToken;
    if (endpoint == null || endpoint.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Endpoint UnifiedPush non ancora registrato. Seleziona un distributore.')),
        );
      }
      return;
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Invio notifica di test in corso...')),
      );
    }

    final success = await _pushService.sendTestNotification(endpoint);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(success
              ? '✅ Notifica inviata! Controlla se la ricevi.'
              : '❌ Errore invio. Verifica connessione e distributore.'),
          backgroundColor: success ? Colors.green : Colors.red,
        ),
      );
    }
  }

  Future<void> _pickImage() async {
    final picker = ImagePicker();
    final image = await picker.pickImage(source: ImageSource.gallery);
    if (image != null) {
      setState(() => _avatarPath = image.path);
    }
  }

  Future<void> _saveProfile() async {
    if (!_formKey.currentState!.validate()) return;

    // Richiedi i permessi esplicitamente sul primo salvataggio/creazione profilo
    if (widget.profile == null) {
      final hasPermissions = await _bluetoothService.requestPermissions();
      if (!hasPermissions) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('I permessi di posizione e notifiche sono necessari per utilizzare CatchMe.')),
          );
        }
        return;
      }
    }

    String? token = widget.profile?.pushToken;
    if (token == null && _selectedPushProvider == 'fcm') {
      token = await _pushService.getFCMToken();
    }

    final profile = UserProfile(
      nickname: _nicknameController.text.trim(),
      status: _selectedStatus,
      birthDate: _birthDate,
      gender: _selectedGender,
      bio: _bioController.text.trim().isEmpty ? null : _bioController.text.trim(),
      avatarPath: _avatarPath,
      publicKey: _cryptoService.publicKey,
      x25519PublicKey: _cryptoService.x25519PublicKey,
      pushProvider: _selectedPushProvider,
      pushToken: token,
      radarRange: _selectedRadarRange,
    );

    await _storageService.saveProfile(profile);
    
    // Notifica il parent del cambiamento
    widget.onProfileSaved?.call(profile);
    
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Profilo salvato')),
      );
      // Se è stato aperto come modal, chiudi e ritorna il profilo
      if (Navigator.canPop(context)) {
        Navigator.pop(context, profile);
      }
    }
  }

  Future<void> _toggleLock(bool value) async {
    if (value && !_hasSavedPin) {
      // Richiedi di impostare un PIN prima di attivare il blocco
      await _showSetPinDialog();
      return;
    }

    await _authService.setLockEnabled(value);
    setState(() => _isLockEnabled = value);
    
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(value ? 'Blocco attivato' : 'Blocco disattivato')),
      );
    }
  }

  Future<void> _showSetPinDialog() async {
    final pinController = TextEditingController();
    final confirmPinController = TextEditingController();

    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Imposta PIN'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: pinController,
              decoration: const InputDecoration(
                labelText: 'PIN (4 cifre)',
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.number,
              maxLength: 4,
              obscureText: true,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: confirmPinController,
              decoration: const InputDecoration(
                labelText: 'Conferma PIN',
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.number,
              maxLength: 4,
              obscureText: true,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Annulla'),
          ),
          TextButton(
            onPressed: () {
              final pin = pinController.text;
              final confirmPin = confirmPinController.text;

              if (pin.length != 4) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Il PIN deve essere di 4 cifre')),
                );
                return;
              }

              if (pin != confirmPin) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('I PIN non coincidono')),
                );
                return;
              }

              Navigator.pop(context, true);
            },
            child: const Text('Salva'),
          ),
        ],
      ),
    );

    if (result == true) {
      await _authService.savePin(pinController.text);
      await _authService.setLockEnabled(true);
      setState(() {
        _hasSavedPin = true;
        _isLockEnabled = true;
      });
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('PIN salvato e blocco attivato')),
        );
      }
    }

    pinController.dispose();
    confirmPinController.dispose();
  }

  Future<void> _changePin() async {
    await _showSetPinDialog();
  }

  Future<void> _showBlockedUsersDialog() async {
    final contacts = await _storageService.getContacts();
    
    if (!mounted) return;
    
    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return FutureBuilder<Set<String>>(
              future: _storageService.getBlockedUsers(),
              builder: (context, snapshot) {
                if (!snapshot.hasData) {
                  return const AlertDialog(
                    title: Text('Utenti Bloccati'),
                    content: SizedBox(
                      height: 100,
                      child: Center(child: CircularProgressIndicator()),
                    ),
                  );
                }
                
                final blockedList = snapshot.data!.toList();
                
                return AlertDialog(
                  title: const Text('Utenti Bloccati'),
                  content: blockedList.isEmpty
                      ? const SizedBox(
                          height: 100,
                          child: Center(child: Text('Nessun utente bloccato')),
                        )
                      : SizedBox(
                          width: double.maxFinite,
                          height: 300,
                          child: ListView.builder(
                            itemCount: blockedList.length,
                            itemBuilder: (context, index) {
                              final id = blockedList[index];
                              String name = id;
                              try {
                                final contact = contacts.firstWhere((c) => c.id == id);
                                name = contact.nickname;
                              } catch (_) {}
                              
                              if (name.length > 20) {
                                name = name.substring(0, 15) + '...';
                              }
                              
                              return ListTile(
                                title: Text(name),
                                trailing: IconButton(
                                  icon: const Icon(Icons.delete, color: Colors.red),
                                  onPressed: () async {
                                    await _storageService.removeBlockedUser(id);
                                    setDialogState(() {});
                                    if (mounted) {
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        const SnackBar(content: Text('Utente sbloccato')),
                                      );
                                    }
                                  },
                                ),
                              );
                            },
                          ),
                        ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Chiudi'),
                    ),
                  ],
                );
              },
            );
          },
        );
      },
    );
  }
  
  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    final isModal = Navigator.canPop(context);
    
    return Scaffold(
      appBar: AppBar(
        title: const Text('Profilo'),
        automaticallyImplyLeading: isModal,
        actions: [
          IconButton(
            icon: const Icon(Icons.check),
            onPressed: _saveProfile,
            tooltip: 'Salva modifiche',
          ),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Center(
              child: GestureDetector(
                onTap: _pickImage,
                child: CircleAvatar(
                  radius: 60,
                  backgroundImage: _avatarPath != null ? FileImage(File(_avatarPath!)) : null,
                  child: _avatarPath == null
                      ? const Icon(Icons.add_a_photo, size: 40)
                      : null,
                ),
              ),
            ),
            const SizedBox(height: 24),
            TextFormField(
              controller: _nicknameController,
              decoration: const InputDecoration(
                labelText: 'Nickname *',
                border: OutlineInputBorder(),
                counterText: '',
              ),
              maxLength: 30,
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[\w\s\-\.]')),
              ],
              validator: (v) {
                if (v == null || v.trim().isEmpty) return 'Il nickname è obbligatorio';
                if (v.trim().length < 2) return 'Minimo 2 caratteri';
                if (v.trim().length > 30) return 'Massimo 30 caratteri';
                if (!RegExp(r'^[\w\s\-\.]+$').hasMatch(v.trim())) {
                  return 'Solo lettere, numeri, spazi, - e .';
                }
                return null;
              },
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<UserStatus>(
              initialValue: _selectedStatus,
              decoration: const InputDecoration(
                labelText: 'Stato *',
                border: OutlineInputBorder(),
              ),
              items: UserStatus.values
                  .map((s) => DropdownMenuItem(
                        value: s,
                        child: Text(s.displayName),
                      ))
                  .toList(),
              onChanged: (v) => setState(() => _selectedStatus = v!),
            ),
            const SizedBox(height: 16),
             TextFormField(
               controller: _ageController,
               readOnly: true,
               decoration: const InputDecoration(
                 labelText: 'Data di Nascita',
                 border: OutlineInputBorder(),
                 prefixIcon: Icon(Icons.cake),
               ),
               onTap: () => _selectBirthDate(context),
             ),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              initialValue: _selectedGender,
              decoration: const InputDecoration(
                labelText: 'Sesso',
                border: OutlineInputBorder(),
              ),
              items: ['Maschio', 'Femmina', 'Altro']
                  .map((g) => DropdownMenuItem(value: g, child: Text(g)))
                  .toList(),
              onChanged: (v) => setState(() => _selectedGender = v),
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<int>(
              value: _selectedRadarRange,
              decoration: const InputDecoration(
                labelText: 'Raggio del Radar',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.radar),
              ),
              items: const [
                DropdownMenuItem(value: 500, child: Text('500 metri')),
                DropdownMenuItem(value: 5000, child: Text('5 km')),
                DropdownMenuItem(value: 20000, child: Text('20 km')),
                DropdownMenuItem(value: 50000, child: Text('50 km')),
                DropdownMenuItem(value: 100000, child: Text('100 km')),
                DropdownMenuItem(value: 500000, child: Text('500 km')),
                DropdownMenuItem(value: 1000000, child: Text('1000 km')),
              ],
              onChanged: (v) => setState(() => _selectedRadarRange = v ?? 500),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _bioController,
              decoration: const InputDecoration(
                labelText: 'Biografia (Bio)',
                border: OutlineInputBorder(),
                hintText: 'Scrivi qualcosa su di te...',
                helperText: 'Massimo 300 caratteri',
              ),
              maxLines: 3,
              maxLength: 300,
              validator: (v) {
                if (v != null && v.length > 300) return 'Massimo 300 caratteri';
                return null;
              },
            ),
             const SizedBox(height: 32),
             // Sezione Impostazioni App
             const Text(
               'Impostazioni App',
               style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
             ),
             const SizedBox(height: 16),
             Card(
               child: Column(
                 children: [
                   SwitchListTile(
                     title: const Text('Localizzazione in background'),
                     subtitle: const Text('Aggiorna la posizione ogni 5 minuti a schermo spento'),
                     value: _isBackgroundSyncEnabled,
                     onChanged: _toggleBackgroundSync,
                     secondary: const Icon(Icons.location_on),
                   ),
                   const Divider(height: 1),
                   ListTile(
                     leading: const Icon(Icons.my_location),
                     title: const Text('Invia posizione ora'),
                     subtitle: const Text('Aggiorna manualmente le tue coordinate sul server'),
                     trailing: _isSendingLocation
                         ? const SizedBox(
                             width: 20,
                             height: 20,
                             child: CircularProgressIndicator(strokeWidth: 2),
                           )
                         : const Icon(Icons.send),
                     onTap: _isSendingLocation ? null : _sendLocationManually,
                   ),
                   const Divider(height: 1),
                   ListTile(
                      leading: const Icon(Icons.notifications),
                      title: const Text('Provider Notifiche Push'),
                      subtitle: Text(_selectedPushProvider == 'fcm'
                          ? 'Google FCM (Firebase)'
                          : 'UnifiedPush (${_selectedDistributor ?? "Seleziona..."})'),
                      trailing: _useFcmBuild
                          ? DropdownButton<String>(
                              value: _selectedPushProvider,
                              underline: const SizedBox(),
                              icon: const Icon(Icons.arrow_drop_down),
                              items: const [
                                DropdownMenuItem(
                                  value: 'fcm',
                                  child: Text('Google FCM'),
                                ),
                                DropdownMenuItem(
                                  value: 'unifiedpush',
                                  child: Text('UnifiedPush'),
                                ),
                              ],
                              onChanged: (v) {
                                if (v != null) {
                                  _changePushProvider(v);
                                }
                              },
                            )
                          : const Text('UnifiedPush', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.blueAccent)),
                      onTap: !_useFcmBuild
                          ? () {
                              if (_distributors.length > 1) {
                                _showDistributorDialog();
                              } else if (_distributors.isEmpty) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('Nessun distributore UnifiedPush (es. ntfy) rilevato sul dispositivo.')),
                                );
                              }
                            }
                          : null,
                    ),           const Divider(height: 1),
                     ListTile(
                       leading: const Icon(Icons.check_circle_outline, color: Colors.green),
                       title: const Text('Testa Notifiche Push'),
                       subtitle: const Text('Invia una notifica di prova al tuo dispositivo'),
                       trailing: const Icon(Icons.play_arrow),
                       onTap: _sendTestPush,
                     ),
                    // Banner informativo UnifiedPush
                    if (_selectedPushProvider == 'unifiedpush') ...[
                      const Divider(height: 1),
                      Container(
                        margin: const EdgeInsets.all(12),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: _useFcmBuild
                              ? Colors.orange.withOpacity(0.1)
                              : Colors.red.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: _useFcmBuild ? Colors.orange : Colors.red,
                            width: 1,
                          ),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(
                              _useFcmBuild ? Icons.info_outline : Icons.warning_amber,
                              color: _useFcmBuild ? Colors.orange : Colors.red,
                              size: 20,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                _useFcmBuild
                                    ? 'UnifiedPush richiede ntfy o un altro distributore installato sul dispositivo. In assenza, verrà usato FCM automaticamente.'
                                    : 'Questa versione (F-Droid) usa solo UnifiedPush. Senza ntfy installato, le notifiche non funzioneranno quando l\'app è chiusa.',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: _useFcmBuild
                                      ? Colors.orange.shade800
                                      : Colors.red.shade800,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                 ],
               ),
             ),
             const SizedBox(height: 32),
             // Sezione Sicurezza
             const Text(
               'Sicurezza',
               style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
             ),
             const SizedBox(height: 16),
             Card(
              child: Column(
                children: [
                  SwitchListTile(
                    title: const Text('Attiva Blocco App'),
                    subtitle: const Text('Richiedi PIN o biometria all\'avvio'),
                    value: _isLockEnabled,
                    onChanged: _toggleLock,
                    secondary: const Icon(Icons.lock),
                  ),
                  if (_hasSavedPin)
                    ListTile(
                      leading: const Icon(Icons.pin),
                      title: const Text('Modifica PIN di sicurezza'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: _changePin,
                    ),
                  ListTile(
                    leading: const Icon(Icons.block, color: Colors.red),
                    title: const Text('Gestisci utenti bloccati'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: _showBlockedUsersDialog,
                  ),
                ],
              ),
            ),
             const SizedBox(height: 32),
             // Sezione Informazioni
             const Text(
               'Informazioni',
               style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
             ),
             const SizedBox(height: 16),
             Card(
               child: ListTile(
                 leading: const Icon(Icons.info),
                 title: const Text('Informazioni su CatchMe'),
                 subtitle: const Text('Autore, versione e contatti'),
                 trailing: const Icon(Icons.chevron_right),
                 onTap: _showAboutDialog,
               ),
             ),
           ],
         ),
       ),
     );
   }

  void _showAboutDialog() {
    showDialog(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: const Color(0xFF0F172A),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 32.0, horizontal: 24.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  color: Colors.blue.withOpacity(0.1),
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.blueAccent, width: 2),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.blueAccent.withOpacity(0.3),
                      blurRadius: 15,
                      spreadRadius: 1,
                    ),
                  ],
                ),
                child: const Icon(
                  Icons.radar,
                  size: 36,
                  color: Colors.blueAccent,
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'CatchMe',
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.5,
                  color: Colors.white,
                  shadows: [
                    Shadow(
                      color: Colors.blueAccent,
                      blurRadius: 8,
                    ),
                  ],
                ),
              ),
              const Text(
                'Proximity Chat App',
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.white60,
                ),
              ),
              const SizedBox(height: 16),
              const Divider(color: Colors.white24),
              const SizedBox(height: 16),
              const Text(
                'Versione: 0.1 alfa',
                style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              const Text(
                'Autore: CyberPingU',
                style: TextStyle(color: Colors.white70, fontSize: 13),
              ),
              const SizedBox(height: 4),
              GestureDetector(
                onTap: () async {
                  final emailUri = Uri(
                    scheme: 'mailto',
                    path: 'cyberpingus@gmail.com',
                    queryParameters: {'subject': 'Feedback CatchMe'},
                  );
                  try {
                    await launchUrl(emailUri, mode: LaunchMode.externalApplication);
                  } catch (e) {
                    print('Errore apertura mail: $e');
                  }
                },
                child: const Text(
                  'Contatto: cyberpingus@gmail.com',
                  style: TextStyle(color: Colors.blueAccent, fontSize: 13, decoration: TextDecoration.underline),
                ),
              ),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF72A4F2),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                ),
                icon: const Icon(Icons.coffee, size: 18),
                label: const Text('Supportami su Ko-fi', style: TextStyle(fontWeight: FontWeight.bold)),
                onPressed: () async {
                  final kofiUri = Uri.parse('https://ko-fi.com/M5F624UNJN');
                  try {
                    await launchUrl(kofiUri, mode: LaunchMode.externalApplication);
                  } catch (e) {
                    print('Errore apertura Ko-fi: $e');
                  }
                },
              ),
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: const [
                  Text(
                    'Fatto con ',
                    style: TextStyle(color: Colors.grey, fontSize: 11),
                  ),
                  Text(
                    'AMMORE',
                    style: TextStyle(
                      color: Colors.redAccent,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Text(
                    ' da CyberPingU',
                    style: TextStyle(color: Colors.grey, fontSize: 11),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blueAccent,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                onPressed: () => Navigator.pop(context),
                child: const Text('Chiudi'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _nicknameController.dispose();
    _ageController.dispose();
    _bioController.dispose();
    super.dispose();
  }
}
