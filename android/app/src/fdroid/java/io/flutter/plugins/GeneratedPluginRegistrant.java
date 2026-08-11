package io.flutter.plugins;

import androidx.annotation.Keep;
import androidx.annotation.NonNull;
import io.flutter.Log;

import io.flutter.embedding.engine.FlutterEngine;

/**
 * Registrante plugin per il flavor FDROID.
 * Registra SOLO i plugin FOSS: Firebase Core e Firebase Messaging sono ESCLUSI
 * per garantire la conformità F-Droid (nessun bytecode Google Firebase nell'APK).
 * Questo file sostituisce la generazione automatica di Flutter.
 */
@Keep
public final class GeneratedPluginRegistrant {
  private static final String TAG = "GeneratedPluginRegistrant";
  public static void registerWith(@NonNull FlutterEngine flutterEngine) {
    // firebase_core  → ESCLUSO (non FOSS, non presente nel flavor fdroid)
    // firebase_messaging → ESCLUSO (non FOSS, non presente nel flavor fdroid)
    try {
      flutterEngine.getPlugins().add(new id.flutter.flutter_background_service.FlutterBackgroundServicePlugin());
    } catch (Exception e) {
      Log.e(TAG, "Error registering plugin flutter_background_service_android, id.flutter.flutter_background_service.FlutterBackgroundServicePlugin", e);
    }
    try {
      flutterEngine.getPlugins().add(new com.dexterous.flutterlocalnotifications.FlutterLocalNotificationsPlugin());
    } catch (Exception e) {
      Log.e(TAG, "Error registering plugin flutter_local_notifications, com.dexterous.flutterlocalnotifications.FlutterLocalNotificationsPlugin", e);
    }
    try {
      flutterEngine.getPlugins().add(new io.flutter.plugins.flutter_plugin_android_lifecycle.FlutterAndroidLifecyclePlugin());
    } catch (Exception e) {
      Log.e(TAG, "Error registering plugin flutter_plugin_android_lifecycle, io.flutter.plugins.flutter_plugin_android_lifecycle.FlutterAndroidLifecyclePlugin", e);
    }
    try {
      flutterEngine.getPlugins().add(new com.it_nomads.fluttersecurestorage.FlutterSecureStoragePlugin());
    } catch (Exception e) {
      Log.e(TAG, "Error registering plugin flutter_secure_storage, com.it_nomads.fluttersecurestorage.FlutterSecureStoragePlugin", e);
    }
    try {
      flutterEngine.getPlugins().add(new com.baseflow.geolocator.GeolocatorPlugin());
    } catch (Exception e) {
      Log.e(TAG, "Error registering plugin geolocator_android, com.baseflow.geolocator.GeolocatorPlugin", e);
    }
    try {
      flutterEngine.getPlugins().add(new io.flutter.plugins.imagepicker.ImagePickerPlugin());
    } catch (Exception e) {
      Log.e(TAG, "Error registering plugin image_picker_android, io.flutter.plugins.imagepicker.ImagePickerPlugin", e);
    }
    try {
      flutterEngine.getPlugins().add(new com.github.dart_lang.jni.JniPlugin());
    } catch (Exception e) {
      Log.e(TAG, "Error registering plugin jni, com.github.dart_lang.jni.JniPlugin", e);
    }
    try {
      flutterEngine.getPlugins().add(new com.github.dart_lang.jni_flutter.JniFlutterPlugin());
    } catch (Exception e) {
      Log.e(TAG, "Error registering plugin jni_flutter, com.github.dart_lang.jni_flutter.JniFlutterPlugin", e);
    }
    try {
      flutterEngine.getPlugins().add(new io.flutter.plugins.localauth.LocalAuthPlugin());
    } catch (Exception e) {
      Log.e(TAG, "Error registering plugin local_auth_android, io.flutter.plugins.localauth.LocalAuthPlugin", e);
    }
    try {
      flutterEngine.getPlugins().add(new com.baseflow.permissionhandler.PermissionHandlerPlugin());
    } catch (Exception e) {
      Log.e(TAG, "Error registering plugin permission_handler_android, com.baseflow.permissionhandler.PermissionHandlerPlugin", e);
    }
    try {
      flutterEngine.getPlugins().add(new io.flutter.plugins.sharedpreferences.SharedPreferencesPlugin());
    } catch (Exception e) {
      Log.e(TAG, "Error registering plugin shared_preferences_android, io.flutter.plugins.sharedpreferences.SharedPreferencesPlugin", e);
    }
    try {
      flutterEngine.getPlugins().add(new org.unifiedpush.flutter.connector.Plugin());
    } catch (Exception e) {
      Log.e(TAG, "Error registering plugin unifiedpush_android, org.unifiedpush.flutter.connector.Plugin", e);
    }
    try {
      flutterEngine.getPlugins().add(new io.flutter.plugins.urllauncher.UrlLauncherPlugin());
    } catch (Exception e) {
      Log.e(TAG, "Error registering plugin url_launcher_android, io.flutter.plugins.urllauncher.UrlLauncherPlugin", e);
    }
    try {
      flutterEngine.getPlugins().add(new com.example.webcrypto.WebcryptoPlugin());
    } catch (Exception e) {
      Log.e(TAG, "Error registering plugin webcrypto, com.example.webcrypto.WebcryptoPlugin", e);
    }
  }
}
