#!/usr/bin/env bash
flutter build apk --flavor playstore --dart-define=PUSH_PROVIDER=fcm --release
flutter build apk --flavor fdroid --dart-define=PUSH_PROVIDER=unifiedpush --release

