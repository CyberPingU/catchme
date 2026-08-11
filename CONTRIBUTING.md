# Contributing to CatchMe

## Secrets required to build (not included in the repo)

### Full flavor (FCM push notifications)

Place your Firebase config file at:
```
android/app/google-services.json
```
Obtainable from the [Firebase Console](https://console.firebase.google.com/).

### Server (FCM push from server)

Place your Firebase Admin SDK service account key at:
```
server/<your-project-id>-firebase-adminsdk-<suffix>.json
```
Then update the filename reference in `server/server.js` line 4.

### Release signing (optional, for release builds)

Create `android/key.properties`:
```properties
storePassword=YOUR_PASSWORD
keyPassword=YOUR_PASSWORD
keyAlias=catchme
storeFile=/absolute/path/to/catchme-release.jks
```

Generate the keystore with:
```bash
keytool -genkey -v -keystore catchme-release.jks \
  -keyalg RSA -keysize 2048 -validity 10000 -alias catchme
```

## Build

```bash
# FOSS flavor (UnifiedPush only, no Firebase)
flutter build apk --release --flavor foss -t lib/main_foss.dart

# Full flavor (FCM + UnifiedPush, requires google-services.json)
flutter build apk --release --flavor full -t lib/main.dart
```
