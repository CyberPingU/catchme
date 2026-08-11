// Firebase stub implementation for F-Droid build
// This file provides empty implementations of Firebase APIs
// Used when building with --flavor fdroid

class Firebase {
  static Future<void> initializeApp() async {
    // No-op for F-Droid build
  }
}

class FirebaseMessaging {
  static FirebaseMessaging get instance => FirebaseMessaging._();
  
  FirebaseMessaging._();
  
  static get onBackgroundMessage => null;
  
  Future<String?> getToken() async => null;
  
  Future<void> subscribeToTopic(String topic) async {}
  
  Future<void> unsubscribeFromTopic(String topic) async {}
  
  Future<void> deleteToken() async {}
  
  Future<Map<String, dynamic>> requestPermission({
    bool alert = false,
    bool badge = false,
    bool sound = false,
    bool carPlay = false,
    bool criticalAlert = false,
    bool provisional = false,
    bool announcement = false,
  }) async {
    return {
      'authorizationStatus': 'authorized',
      'alert': alert,
      'badge': badge,
      'sound': sound,
      'carPlay': carPlay,
      'criticalAlert': criticalAlert,
      'provisional': provisional,
      'announcement': announcement,
    };
  }
  
  Future<void> setForegroundNotificationPresentationOptions({
    bool alert = false,
    bool badge = false,
    bool sound = false,
  }) async {}
  
  static get onMessageOpenedApp => Stream.empty();
  
  Future<RemoteMessage?> getInitialMessage() async => null;
  
  static get onMessage => Stream.empty();
}

class RemoteMessage {
  final Map<String, dynamic> data;
  final Map<String, dynamic>? notification;
  
  RemoteMessage({required this.data, this.notification});
}