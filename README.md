# baby-monitor-app

Caregiver companion app for the [baby-monitor](../baby-monitor) Pi —
live cry alerts, feed/change logging, and history review. This repo is
intentionally separate from `baby-monitor` (Pi-side + ML only); see
that repo's `docs/INDEX.md`.

**Status**: Android-first milestone. iOS is deliberately deferred —
see "Platform plan" below.

## What this app does

- Holds a persistent MQTT connection to the Pi's local broker and
  alerts (with a locally-played sound, not a system push notification)
  when a cry starts or ends; silently refreshes the displayed
  cry-reason estimate as it updates mid-session.
- Lets a caregiver log feed/change events from the app (synced to the
  Pi opportunistically, next time both are on the same WiFi) and
  review/correct the history the wireless buttons and other family
  members' app instances have logged.
- Reviews cry-session history and device startup/shutdown history.
- Lets a caregiver pause cry detection (escape hatch for a
  misbehaving model) and, with explicit confirmation, wipe all stored
  history on the Pi.

**The full wire contract this app implements against — MQTT message
shapes, HTTP endpoints, trust model, and the reasoning behind each —
is in [docs/PI_CONTRACT.md](docs/PI_CONTRACT.md).** Read that before
changing anything networking-related; it's a manually-synced snapshot
of decisions made in the `baby-monitor` repo, not something to
re-derive from scratch here.

## Platform plan

**Android first, personally sideloaded (not Play Store) for now.**
Reasoning:
- No developer account, no signing expiry, no recurring cost —  a
  self-managed signing key works indefinitely (see
  `android/key.properties.example`).
- One real family member (dad) is on Android, so this validates both
  the app itself and real family usage, not just "does it build."
- iOS requires either a Mac (which this project doesn't have locally)
  or cloud CI, plus (for anything beyond a 7-day free-tier sideload) a
  $99/year Apple Developer account and periodic re-signing. Deferred
  until the Android app has proven the concept is worth that
  investment.

Play Store distribution for Android, and iOS entirely, are both
explicitly out of scope for this milestone — revisit once the app is
validated.

## Getting started

Requires the Flutter SDK (not installed as part of scaffolding this
repo — install from https://flutter.dev before running anything here).

```
flutter pub get
flutter run            # requires an Android device/emulator
```

First run: copy `android/local.properties.example` to
`android/local.properties` and fill in your SDK paths (Flutter's
tooling will also do this automatically on first `flutter run`/`pub
get` if the file is missing).

To build a release APK for sideloading:
```
flutter build apk --release
```
Without `android/key.properties` set up (see
`android/key.properties.example`), this signs with the debug key,
which is fine for testing on your own devices but should not be
handed out as "the real app" — see that file for generating a real
key.

## Project layout

```
lib/
  main.dart                       Entry point, foreground-service init
  app_state.dart                  Central app state: connection status,
                                   active cry session (built from the
                                   three MQTT message kinds)
  models/
    notify_event.dart             MQTT message parsing (cry_started /
                                   reason_updated / cry_ended)
    care_event.dart                Care events, cry sessions, device
                                   events -- HTTP API response shapes
  services/
    notify_listener.dart          Persistent MQTT client
    sync_api_client.dart          HTTP client for pi/sync_api.py
    pi_connection_settings.dart   Host/port config + per-install device_id
    foreground_service.dart       Android foreground service wrapper
  screens/
    home_screen.dart              Status tab + navigation shell
    care_events_screen.dart       Log/review feed & change events
    history_screen.dart           Cry-session history
    settings_screen.dart          Connection config, pause toggle, reset
docs/
  PI_CONTRACT.md                  The Pi-side contract this app implements
```
