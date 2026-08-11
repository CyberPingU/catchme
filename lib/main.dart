// dart:io non più necessario — SSL override rimosso
import 'package:flutter/material.dart';
import 'package:flutter_background/flutter_background.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'screens/main_navigation_screen.dart';
import 'screens/lock_screen.dart';
import 'services/auth_service.dart';
import 'screens/chat_screen.dart';
import 'models/nearby_user.dart';
import 'services/proximity_service.dart';
import 'services/storage_service.dart';
import 'services/notification_service.dart';
import 'services/push_service.dart';

// Costante compile-time: flutter build apk --dart-define=PUSH_PROVIDER=unifiedpush
// Nella build F-Droid (unifiedpush) Firebase non viene inizializzato.
const _pushProvider = String.fromEnvironment('PUSH_PROVIDER', defaultValue: 'fcm');
const _useFcm = _pushProvider != 'unifiedpush';

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

void openChatScreen(String senderHash, {String? defaultNickname}) async {
  final storageService = StorageService();
  final bluetoothService = ProximityService();
  
  // Recupera il contatto corrispondente se esiste
  final contact = await storageService.getContactById(senderHash);
  final nickname = contact?.nickname ?? (defaultNickname ?? 'Utente');
  final publicKey = contact?.publicKey ?? '';

  final chatUser = NearbyUser(
    endpointId: senderHash,
    nickname: nickname,
    status: 'Online',
    isConnected: bluetoothService.connectedEndpoints.contains(senderHash),
    publicKey: publicKey,
    isVerified: true,
  );

  navigatorKey.currentState?.push(
    MaterialPageRoute(
      builder: (_) => ChatScreen(
        user: chatUser,
        bluetoothService: bluetoothService,
      ),
    ),
  );
}

// SSL: verifica certificati abilitata (nessun override - comportamento di default)

// Handler top-level FCM background — usato solo nella build con FCM
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  // Eseguito in un Dart isolate separato. FCM mostra la notifica automaticamente.
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (_useFcm) {
    // Build Play Store: inizializza Firebase
    FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
    try {
      await Firebase.initializeApp();
    } catch (e) {
      print('Errore inizializzazione Firebase: $e');
    }
  }
  
  // Inizializza il servizio in background (senza abilitarlo subito)
  try {
    final androidConfig = FlutterBackgroundAndroidConfig(
      notificationTitle: 'CatchMe Attivo',
      notificationText: 'Invio della posizione in background',
      notificationImportance: AndroidNotificationImportance.normal,
      notificationIcon: AndroidResource(name: 'ic_launcher', defType: 'mipmap'),
    );
    
    await FlutterBackground.initialize(androidConfig: androidConfig);
    // NON chiamare enableBackgroundExecution qui - verrà fatto dopo i permessi
  } catch (e) {
    print('Errore inizializzazione FlutterBackground: $e');
  }
  
  runApp(const CatchMeApp());
}

class CatchMeApp extends StatelessWidget {
  const CatchMeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: navigatorKey,
      title: 'CatchMe',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.blue,
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.blue,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      themeMode: ThemeMode.system,
      home: const AppInitializer(),
      routes: {
        '/main': (context) => const MainNavigationScreen(),
      },
    );
  }
}

class AppInitializer extends StatefulWidget {
  const AppInitializer({super.key});

  @override
  State<AppInitializer> createState() => _AppInitializerState();
}

class _AppInitializerState extends State<AppInitializer> {
  final _authService = AuthService();
  final _notificationService = NotificationService();
  final _pushService = PushService();
  bool _isLoading = true;
  bool _isLockEnabled = false;

  @override
  void initState() {
    super.initState();
    _checkLockStatus();
    _setupFCM();
    _setupLocalNotifications();
    _pushService.initialize();
  }

  Future<void> _setupLocalNotifications() async {
    // Inizializza le notifiche locali con il callback di click
    await _notificationService.initialize(
      onNotificationClick: (payload) {
        if (payload != null && payload.isNotEmpty) {
          if (payload.contains('|')) {
            final parts = payload.split('|');
            openChatScreen(parts[0], defaultNickname: parts[1]);
          } else {
            openChatScreen(payload);
          }
        }
      },
    );
  }

  Future<void> _setupFCM() async {
    final messaging = FirebaseMessaging.instance;

    // Richiedi permessi esplicitamente (obbligatorio su Android 13+ e iOS)
    await messaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );

    // Mostra la notifica anche quando l'app è in primo piano
    await FirebaseMessaging.instance.setForegroundNotificationPresentationOptions(
      alert: true,
      badge: true,
      sound: true,
    );

    // Gestisce il click sul banner push quando l'app è in background (ma non spenta)
    FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
      final senderHash = message.data['senderHash'];
      final senderNickname = message.data['senderNickname'];
      if (senderHash != null && senderHash.toString().isNotEmpty) {
        openChatScreen(
          senderHash.toString(),
          defaultNickname: senderNickname?.toString(),
        );
      }
    });

    // Gestisce il click sul banner push quando l'app era completamente chiusa/terminata
    final initialMessage = await FirebaseMessaging.instance.getInitialMessage();
    if (initialMessage != null) {
      final senderHash = initialMessage.data['senderHash'];
      final senderNickname = initialMessage.data['senderNickname'];
      if (senderHash != null && senderHash.toString().isNotEmpty) {
        // Attendi un istante per permettere l'inizializzazione del Navigator
        Future.delayed(const Duration(milliseconds: 1500), () {
          openChatScreen(
            senderHash.toString(),
            defaultNickname: senderNickname?.toString(),
          );
        });
      }
    }
  }

  Future<void> _checkLockStatus() async {
    final startTime = DateTime.now();
    final lockEnabled = await _authService.isLockEnabled();
    final elapsed = DateTime.now().difference(startTime).inMilliseconds;
    
    // Garantisce che lo splash rimanga visibile per almeno 3.5 secondi per una bella UX
    final delayNeeded = 3500 - elapsed;
    if (delayNeeded > 0) {
      await Future.delayed(Duration(milliseconds: delayNeeded));
    }

    setState(() {
      _isLockEnabled = lockEnabled;
      _isLoading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Scaffold(
        backgroundColor: const Color(0xFF0F172A), // Sfondo scuro moderno ed elegante (Slate 900)
        body: Stack(
          children: [
            Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // Icona CatchMe stilizzata con effetto neon/bagliore
                  Container(
                    width: 96,
                    height: 96,
                    decoration: BoxDecoration(
                      color: Colors.blue.withOpacity(0.1),
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.blueAccent, width: 2),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.blueAccent.withOpacity(0.3),
                          blurRadius: 20,
                          spreadRadius: 2,
                        ),
                      ],
                    ),
                    child: const Icon(
                      Icons.radar,
                      size: 48,
                      color: Colors.blueAccent,
                    ),
                  ),
                  const SizedBox(height: 24),
                  // Titolo CatchMe
                  const Text(
                    'CatchMe',
                    style: TextStyle(
                      fontSize: 36,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 2.0,
                      color: Colors.white,
                      shadows: [
                        Shadow(
                          color: Colors.blueAccent,
                          blurRadius: 10,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  // Sottotitolo elegante
                  Text(
                    'Proximity Chat App',
                    style: TextStyle(
                      fontSize: 14,
                      color: Colors.grey[400],
                      letterSpacing: 1.2,
                    ),
                  ),
                ],
              ),
            ),
            // Firma CyberPingu in basso al centro
            Positioned(
              bottom: 40,
              left: 0,
              right: 0,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(Colors.blueAccent),
                    ),
                  ),
                  const SizedBox(height: 24),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: const [
                      Text(
                        'Fatto con ',
                        style: TextStyle(
                          color: Colors.grey,
                          fontSize: 13,
                        ),
                      ),
                      Text(
                        'AMMORE',
                        style: TextStyle(
                          color: Colors.redAccent,
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        ' da CyberPingu',
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    if (_isLockEnabled) {
      return const LockScreen();
    }

    return const MainNavigationScreen();
  }
}
