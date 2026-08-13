# CatchMe
## Proximity-based Encrypted Messaging App

Discover and chat with people nearby — without ever sharing your identity or exact location with a central server.

---

**License:** AGPL v3 | **Platform:** Android | **Framework:** Flutter 3.x | **Push:** UnifiedPush Compatible

---

## How it works

CatchMe connects to a lightweight relay server that knows only your **approximate GPS position** and a **public key hash** (no email, no phone number, no account). Users within the chosen proximity radius appear on the radar. All messages are **end-to-end encrypted** (ECDH X25519 + AES-GCM): the server only routes encrypted blobs it cannot read.

- **📡 Proximity discovery** via GPS + server relay
- **🔐 End-to-end encryption** — server sees only ciphertext
- **👤 No account required** — identity is a cryptographic key pair generated on device
- **📍 Optional location sharing** with trusted contacts (permanent or one-shot)
- **🔔 Push notifications** via FCM (Google) or UnifiedPush (FOSS)
- **🏷 Adjusting radar range** — 500m to 1000km, user-controlled
- **📋 Contact list** with groups, last-seen distance, profile photos on request
- **🔒 Biometric app lock** (optional)

## Build Flavors

| **Flavor** | **Branch** | **Push Notifications** | **Suitable for** |
|------------|------------|------------------------|------------------|
| `fdroid` | `main` | UnifiedPush only | **F-Droid**, pure FOSS, privacy-focused |
| `playstore` | `full` | FCM (Google) + UnifiedPush | Google Play Store, GMS devices, Obtainium |

### Build FOSS Flavor (UnifiedPush only)
*Run on `main` branch:*
```bash
flutter pub get
flutter build apk --release --flavor fdroid --dart-define=PUSH_PROVIDER=unifiedpush
```

### Build Full Flavor (FCM + UnifiedPush)
*Run on `full` branch (requires `android/app/google-services.json` from your Firebase project):*
```bash
flutter pub get
flutter build apk --release --flavor playstore --dart-define=PUSH_PROVIDER=fcm
```

## Self-hosting the Server

The relay server is a Node.js WebSocket server. It requires **no database** — state is persisted to a local JSON file.

### Requirements
- Node.js 18+
- (Optional) Firebase project for FCM push notifications

### Setup
```bash
cd server
npm install
```

Create your Firebase service account key (for FCM push) and place it in `server/`:
```
server/your-firebase-adminsdk-key.json
```

**Note:** *Never commit this file. It is already in `.gitignore`.*

### Run
```bash
# Default proximity radius: 500m
node server.js

# Custom radius
node server.js --distance 2km
node server.js --distance 500m
```

The server persists state to `server/server_db.json` automatically (survives restarts).

### Run with systemd (recommended for VPS)
```systemd
[Unit]
Description=CatchMe Proximity Server
After=network.target

[Service]
WorkingDirectory=/opt/catchme/server
ExecStart=/usr/bin/node server.js --distance 5km
Restart=always
RestartSec=5
User=catchme

[Install]
WantedBy=multi-user.target
```

## Client Configuration

Point the app at your server by editing `lib/services/proximity_service.dart`:
```java
static const String _serverUrl = 'wss://your-server.example.com:3000';
```

*For production, put the WebSocket server behind a reverse proxy (nginx/Caddy) with a valid TLS certificate.*

## Project Structure

```
lib/
├── main.dart                       # App entry point & dependency injection
├── models/
│   ├── user_profile.dart           # Local user profile model
│   ├── nearby_user.dart            # Nearby user model
│   ├── chat_message.dart           # Chat message model
│   └── contact.dart                # Saved contact model
├── services/
│   ├── proximity_service.dart      # WebSocket client, E2E crypto, radar
│   ├── crypto_service.dart         # ECDH X25519 + AES-GCM encryption
│   ├── storage_service.dart        # Local storage & sanitized photo I/O
│   ├── notification_service.dart   # Local notifications
│   └── push/                       # Modular push notification providers
│       ├── push_service.dart       # Abstract push interface
│       ├── push_service_fcm.dart   # Firebase Cloud Messaging provider
│       └── push_service_unifiedpush.dart # UnifiedPush provider
└── screens/
    ├── main_screen.dart            # Main tab navigator
    ├── radar_screen.dart           # Nearby users radar
    ├── chat_screen.dart            # Chat UI & photo viewer
    ├── contacts_screen.dart        # Saved contacts list
    └── profile_screen.dart         # User profile settings
server/
├── server.js                       # Node.js WebSocket relay server
└── package.json
```

## Privacy & Permissions

| **Permission** | **Reason** |
|----------------|------------|
| `ACCESS_FINE_LOCATION` | GPS for proximity detection |
| `INTERNET` | WebSocket connection to relay server |
| `POST_NOTIFICATIONS` | Push notification delivery |
| `FOREGROUND_SERVICE` | Background location updates |
| `USE_BIOMETRIC` | Optional biometric app lock |

The relay server stores:
- Your **public key hash** (not the key itself, which stays on device)
- Your **approximate GPS coordinates** (never sent to other users directly)
- Your **FCM/UnifiedPush token** (for offline notifications)

No account, no email, no phone number is ever required or stored.

## License

CatchMe is free software: you can redistribute it and/or modify it under the terms of the **GNU Affero General Public License** as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.
