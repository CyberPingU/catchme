import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/nearby_user.dart';
import '../models/user_profile.dart';
import '../models/contact.dart';
import '../services/proximity_service.dart';
import '../services/storage_service.dart';
import '../services/notification_service.dart';
import '../widgets/user_profile_card.dart';

class RadarScreen extends StatefulWidget {
  final UserProfile? profile;

  const RadarScreen({super.key, this.profile});

  @override
  State<RadarScreen> createState() => _RadarScreenState();
}

class _RadarScreenState extends State<RadarScreen> with WidgetsBindingObserver {
  final _bluetoothService = ProximityService();
  final _storageService = StorageService();
  final _notificationService = NotificationService();

  UserProfile? _profile;
  List<NearbyUser> _nearbyUsers = [];
  bool _isInitialized = false;
  final Map<String, Contact?> _contactsCache = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _profile = widget.profile;
    _initialize();
  }
  
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    
    switch (state) {
      case AppLifecycleState.resumed:
        // App in primo piano
        _bluetoothService.onAppResumed();
        break;
      case AppLifecycleState.paused:
        // App in background
        _bluetoothService.onAppPaused();
        break;
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
      case AppLifecycleState.hidden:
        // Stati transitori, non fare nulla
        break;
    }
  }

  @override
  void didUpdateWidget(RadarScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.profile != oldWidget.profile && widget.profile != null) {
      _profile = widget.profile;
      if (!_isInitialized) {
        // Il profilo è arrivato in ritardo (race condition con _loadProfile).
        // _initialize() aveva abortito perché _profile era null: rilancia ora.
        debugPrint('[DEBUG-CATCHME] didUpdateWidget: profilo arrivato dopo init, rilancio _initialize()');
        _initialize();
      } else {
        // Già inizializzato: basta aggiornare il profilo e riavviare advertising
        _restartAdvertising();
      }
    }
  }

  Future<void> _restartAdvertising() async {
    if (_profile == null || !_isInitialized) return;
    
    await _bluetoothService.stopAdvertising();
    await _bluetoothService.startAdvertising(_profile!);
    
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Profilo aggiornato'),
          duration: Duration(seconds: 1),
        ),
      );
    }
  }

  Future<void> _initialize() async {
    debugPrint('[DEBUG-CATCHME] _initialize(): avvio. profile=${_profile?.nickname}');
    await _notificationService.initialize();
    await _bluetoothService.initialize();

    if (_profile == null) {
      debugPrint('[DEBUG-CATCHME] _initialize(): profilo null, esco.');
      if (mounted) setState(() {});
      return;
    }

    debugPrint('[DEBUG-CATCHME] _initialize(): richiedo permessi...');
    final hasPermissions = await _bluetoothService.requestPermissions();
    debugPrint('[DEBUG-CATCHME] _initialize(): hasPermissions=$hasPermissions');
    if (!hasPermissions) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Permessi GPS/notifiche necessari')),
        );
      }
      return;
    }

    // Abilita il background execution SOLO se abilitato nelle impostazioni e dopo i permessi
    final prefs = await SharedPreferences.getInstance();
    final isBgSyncEnabled = prefs.getBool('background_sync_enabled') ?? true;
    
    if (isBgSyncEnabled) {
      try {
        FlutterBackgroundService().invoke('startService');
      } catch (e) {
        debugPrint('Errore attivazione background: $e');
      }
    } else {
      try {
        FlutterBackgroundService().invoke('stopService');
      } catch (_) {}
    }

    debugPrint('[DEBUG-CATCHME] _initialize(): startAdvertising...');
    await _bluetoothService.startAdvertising(_profile!);
    await _bluetoothService.startDiscovery();

    _isInitialized = true;
    debugPrint('[DEBUG-CATCHME] _initialize(): COMPLETATO. Connessione server avviata.');

    _bluetoothService.discoveredUsers.listen((users) async {
      setState(() => _nearbyUsers = users);
      // Carica le foto dei contatti verificati
      await _loadContactPhotos();
    });

    _bluetoothService.connectionRequests.listen((request) async {
      // Analizza l'endpointName per estrarre il nickname
      String nickname = request.endpointName;
      
      if (request.endpointName.contains('|')) {
        final parts = request.endpointName.split('|');
        if (parts.length == 2) {
          nickname = parts[0];
        }
      }
      
      // Mostra il popup per tutti gli utenti sconosciuti
      _showConnectionRequestDialog(request.endpointId, nickname);
      _notificationService.showConnectionRequestNotification(nickname);
    });
  }

  Future<void> _refreshRadar() async {
    // Stop current discovery
    await _bluetoothService.stopDiscovery();
    
    // Clear the list
    setState(() => _nearbyUsers = []);
    
    // Restart discovery
    await _bluetoothService.startDiscovery();
    
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Ricerca aggiornata'),
          duration: Duration(seconds: 1),
        ),
      );
    }
  }

  Future<void> _loadContactPhotos() async {
    for (final user in _nearbyUsers) {
      if (user.isVerified && user.publicKey != null) {
        final contact = await _storageService.getContactByPublicKey(user.publicKey!);
        if (contact != null) {
          _contactsCache[user.endpointId] = contact;
        }
      }
    }
    if (mounted) {
      setState(() {});
    }
  }

  void _showConnectionRequestDialog(String endpointId, String nickname) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Richiesta Connessione'),
        content: Text('$nickname vuole connettersi'),
        actions: [
          TextButton(
            onPressed: () {
              _bluetoothService.rejectConnection(endpointId);
              Navigator.pop(context);
            },
            child: const Text('Rifiuta'),
          ),
          TextButton(
            onPressed: () async {
              await _bluetoothService.acceptConnection(endpointId);
              // Salva il contatto dopo l'accettazione
              await _bluetoothService.saveContact(endpointId);
              if (context.mounted) {
                Navigator.pop(context);
              }
            },
            child: const Text('Accetta'),
          ),
        ],
      ),
    );
  }

  void _showUserOptions(NearbyUser user) {
    final contact = _contactsCache[user.endpointId];
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => UserProfileCard(
        user: user,
        initialAvatarPath: contact?.avatarPath,
        bluetoothService: _bluetoothService,
        onActionDone: () {
          _loadContactPhotos();
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Radar'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _refreshRadar,
            tooltip: 'Aggiorna ricerca',
          ),
        ],
      ),
      body: _profile == null
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.person_outline, size: 64, color: Colors.grey),
                  const SizedBox(height: 16),
                  const Text(
                    'Profilo non configurato',
                    style: TextStyle(fontSize: 18, color: Colors.grey),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Vai alla scheda Profilo per configurarlo',
                    style: TextStyle(color: Colors.grey),
                  ),
                ],
              ),
            )
          : RefreshIndicator(
              onRefresh: _refreshRadar,
              child: Builder(
                builder: (context) {
                  // Filtra solo gli utenti sconosciuti (strangers)
                  final strangerUsers = _nearbyUsers
                      .where((u) => !u.isVerified && !u.isTrusted)
                      .toList();
                  
                  if (strangerUsers.isEmpty) {
                    return SingleChildScrollView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      child: SizedBox(
                        height: MediaQuery.of(context).size.height - 200,
                        child: const Center(
                          child: Text('Nessun utente nelle vicinanze'),
                        ),
                      ),
                    );
                  }
                  
                  return ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: strangerUsers.length,
                    itemBuilder: (context, index) {
                      final user = strangerUsers[index];
                      final contact = _contactsCache[user.endpointId];
                      final hasPhoto = contact?.avatarPath != null && File(contact!.avatarPath!).existsSync(); 
                      return Card(
                        margin: const EdgeInsets.only(bottom: 12),
                        child: ListTile(
                          leading: Stack(
                            children: [
                              CircleAvatar(
                                radius: 24,
                                backgroundImage: hasPhoto
                                    ? FileImage(File(contact!.avatarPath!))
                                    : null,
                                child: hasPhoto
                                    ? null
                                    : Text(user.nickname[0].toUpperCase()),
                              ),
                              if (user.isVerified)
                                Positioned(
                                  right: 0,
                                  bottom: 0,
                                  child: Container(
                                    padding: const EdgeInsets.all(2),
                                    decoration: const BoxDecoration(
                                      color: Colors.white,
                                      shape: BoxShape.circle,
                                    ),
                                    child: const Icon(
                                      Icons.verified,
                                      color: Colors.blue,
                                      size: 16,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          title: Row(
                            children: [
                              Text(user.nickname),
                              if (user.isTrusted && !user.isVerified)
                                const Padding(
                                  padding: EdgeInsets.only(left: 4),
                                  child: Icon(
                                    Icons.security,
                                    color: Colors.orange,
                                    size: 16,
                                  ),
                                ),
                            ],
                          ),
                          subtitle: Text(
                            user.isVerified
                                ? 'Contatto verificato'
                                : user.isTrusted
                                    ? 'Identità verificata'
                                    : user.status,
                          ),
                          trailing: user.isPending
                              ? const CircularProgressIndicator()
                              : user.isConnected
                                  ? const Icon(Icons.check_circle, color: Colors.green)
                                  : null,
                          onTap: () => _showUserOptions(user),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // Non chiamare dispose() sul servizio Singleton
    super.dispose();
  }
}
