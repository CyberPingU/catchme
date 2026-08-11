import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AuthService {
  static const String _lockEnabledKey = 'lock_enabled';
  static const String _savedPinKey = 'saved_pin';
  
  final LocalAuthentication _localAuth = LocalAuthentication();

  // Verifica se il dispositivo supporta la biometria
  Future<bool> isBiometricAvailable() async {
    try {
      return await _localAuth.canCheckBiometrics;
    } catch (e) {
      return false;
    }
  }

  // Ottiene i tipi di biometria disponibili
  Future<List<BiometricType>> getAvailableBiometrics() async {
    try {
      return await _localAuth.getAvailableBiometrics();
    } catch (e) {
      return [];
    }
  }

  // Esegue l'autenticazione biometrica
  Future<bool> authenticateWithBiometrics() async {
    try {
      return await _localAuth.authenticate(
        localizedReason: 'Sblocca CatchMe con la tua impronta o il viso',
        options: const AuthenticationOptions(
          stickyAuth: true,
          biometricOnly: true,
        ),
      );
    } catch (e) {
      return false;
    }
  }

  // Verifica se il blocco è attivo
  Future<bool> isLockEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_lockEnabledKey) ?? false;
  }

  // Attiva/disattiva il blocco
  Future<void> setLockEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_lockEnabledKey, enabled);
  }

  // Salva il PIN
  Future<void> savePin(String pin) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_savedPinKey, pin);
  }

  // Ottiene il PIN salvato
  Future<String?> getSavedPin() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_savedPinKey);
  }

  // Verifica se il PIN è corretto
  Future<bool> verifyPin(String pin) async {
    final savedPin = await getSavedPin();
    return savedPin != null && savedPin == pin;
  }

  // Verifica se esiste un PIN salvato
  Future<bool> hasSavedPin() async {
    final savedPin = await getSavedPin();
    return savedPin != null && savedPin.isNotEmpty;
  }

  // Rimuove il PIN salvato
  Future<void> removePin() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_savedPinKey);
  }
}
