# CatchMe

<p align="center">
  <img src="assets/icon/icon.png" alt="CatchMe Logo" width="100"/>
</p>

<p align="center">
  <strong>Proximity-based encrypted messaging app</strong><br/>
  Discover and chat with people nearby — without ever sharing your identity or exact location with a central server.
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-AGPL%20v3-blue.svg" alt="License: AGPL v3"/></a>
  <img src="https://img.shields.io/badge/Platform-Android-green.svg" alt="Platform: Android"/>
  <img src="https://img.shields.io/badge/Flutter-3.x-02569B?logo=flutter" alt="Flutter"/>
  <img src="https://img.shields.io/badge/UnifiedPush-compatible-purple" alt="UnifiedPush"/>
</p>

---

## How it works

CatchMe connects to a lightweight relay server that knows only your **approximate GPS position** and a **public key hash** (no email, no phone number, no account). Users within the chosen proximity radius appear on the radar. All messages are **end-to-end encrypted** (ECDH X25519 + AES-GCM): the server only routes encrypted blobs it cannot read.

- 📡 **Proximity discovery** via GPS + server relay
- 🔐 **End-to-end encryption** — server sees only ciphertext
- 👤 **No account required** — identity is a cryptographic key pair generated on device
- 📍 **Optional location sharing** with trusted contacts (permanent or one-shot)
- 🔔 **Push notifications** via FCM (Google) or UnifiedPush (FOSS)
- 🏷️ **Adjustable radar range** — 500m to 1000km, user-controlled
- 📋 **Contact list** with groups, last-seen distance, profile photos on request
- 🔒 **Biometric app lock** (optional)

---

## Build Flavors

| Flavor | Push notifications | Suitable for |
|---|---|---|
| `foss` | UnifiedPush only | **F-Droid**, privacy-focused users |
| `full` | FCM + UnifiedPush | GitHub Releases, Obtainium, GMS devices |

### Build FOSS flavor (UnifiedPush only)
```bash
flutter pub get
flutter build apk --release --flavor foss -t lib/main_foss.dart
```

### Build full flavor (FCM + UnifiedPush)
> Requires `android/app/google-services.json` from your own Firebase project.
```bash
flutter pub get
flutter build apk --release --flavor full -t lib/main.dart
```

---

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

> ⚠️ **Never commit this file.** It is already in `.gitignore`.

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

```ini
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

---

## Client Configuration

Point the app at your server by editing `lib/services/proximity_service.dart`:

```dart
static const String _serverUrl = 'wss://your-server.example.com:3000';
```

> For production, put the WebSocket server behind a reverse proxy (nginx/Caddy) with a valid TLS certificate.

---

## Project Structure

```
├── lib/
│   ├── main.dart                       # Entry point (full flavor)
│   ├── main_foss.dart                  # Entry point (FOSS flavor)
│   ├── models/
│   │   ├── user_profile.dart           # Local user profile model
│   │   ├── nearby_user.dart            # Nearby user model
│   │   ├── chat_message.dart           # Chat message model
│   │   └── contact.dart               # Saved contact model
│   ├── services/
│   │   ├── proximity_service.dart      # WebSocket client, E2E crypto, radar
│   │   ├── crypto_service.dart         # ECDH X25519 + AES-GCM encryption
│   │   ├── storage_service.dart        # Local storage (SharedPreferences + files)
│   │   ├── notification_service.dart   # Local + push notifications
│   │   └── unifiedpush_service.dart    # UnifiedPush integration
│   └── screens/
│       ├── main_screen.dart            # Main tab navigator
│       ├── radar_screen.dart           # Nearby users radar
│       ├── chat_screen.dart            # Chat UI
│       ├── contacts_screen.dart        # Saved contacts list
│       └── profile_screen.dart         # User profile settings
└── server/
    ├── server.js                       # Node.js WebSocket relay server
    └── package.json
```

---

## Privacy & Permissions

| Permission | Reason |
|---|---|
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

---

## License

CatchMe is free software: you can redistribute it and/or modify it under the terms of the **GNU Affero General Public License** as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

See [LICENSE](LICENSE) for the full text.
