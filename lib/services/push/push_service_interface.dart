// Interfaccia Push Service per astrazione FCM/UnifiedPush
abstract class PushServiceInterface {
  Future<void> initialize();
  Future<void> initializeUnifiedPush();
  Future<String?> getPushToken();
  Future<void> subscribeToTopic(String topic);
  Future<void> unsubscribeFromTopic(String topic);
  Future<void> deleteToken();
  
  // Esposto all'UI: true se UP ha fallito e non c'è fallback
  bool get upFailed;
  set upFailed(bool value);
}