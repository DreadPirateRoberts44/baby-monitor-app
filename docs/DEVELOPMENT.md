# Development & testing guide

How to get this app building and running locally, and how to exercise
it without needing a real Raspberry Pi monitor running somewhere.

## One-time machine setup

You need three things beyond a normal Flutter install, because Android
Studio's own Gradle runs and the Flutter CLI's don't automatically
share configuration:

1. **Flutter SDK** — install from https://flutter.dev. Add
   `<flutter-sdk>/bin` to your PATH.
2. **Android SDK** — installed via Android Studio (More Actions → SDK
   Manager). You also need the **SDK Tools → Android SDK Command-line
   Tools (latest)** package checked, or `flutter doctor` will complain
   `cmdline-tools component is missing`.
3. **A JDK in the 17–21 range.** This tripped us up during initial
   setup: Gradle 8.6 (what this project's `gradle-wrapper.properties`
   pins) does not support Java 22+, and the Android Gradle Plugin
   needs at least Java 17. If your machine's default `java` resolves
   to something outside that range (check with `java -version` — on
   Windows, `C:\Program Files\Common Files\Oracle\Java\javapath\`
   frequently shadows a much newer or older JDK than the SDK actually
   needs), install a JDK 21 LTS build (e.g.
   [Eclipse Temurin 21](https://adoptium.net/)) and point Flutter's
   CLI builds at it explicitly:
   ```
   flutter config --jdk-dir="C:\path\to\jdk-21"
   ```
   **This setting only affects `flutter build`/`flutter run` from a
   terminal.** Android Studio's own embedded Gradle runs (its Run
   button, its "Build" menu) use a *separate* JDK setting: File →
   Settings → Build, Execution, Deployment → Build Tools → Gradle →
   **Gradle JDK** dropdown. Set both, or you'll see a working CLI
   build and a failing Android-Studio-triggered build (or vice versa)
   and waste time thinking the toolchain is broken.

Run `flutter doctor -v` after all of this — it should show a green
checkmark on "Android toolchain" with no license or cmdline-tools
warnings. (In practice we saw `flutter doctor --android-licenses`
report "Android license status unknown" even after clicking through
Android Studio's license prompts — this turned out to be cosmetic on
newer cmdline-tools releases; check `<sdk>/licenses/` has files in it
directly, and don't chase the doctor warning further if it does.)

## Building and running

```
flutter pub get
flutter devices              # confirm a target is visible
flutter run                  # builds, installs, launches, hot-reloads
```

**Device or emulator, phone or tablet — it doesn't matter.** Nothing
in this app is phone-specific (no telephony, no phone-shaped layout
assumptions); a tablet works identically to a phone for testing every
feature described here. `minSdk` is 26 (Android 8.0), so anything from
roughly the last 8 years of Android devices works.

To create an emulator if you don't have a physical device handy:
```
flutter emulators --create --name pixel_test
flutter emulators --launch pixel_test
```
(or use Android Studio's Device Manager, which does the same thing.)
First boot of a fresh emulator can take a couple of minutes — if
`flutter devices` doesn't show it yet, give it more time before
assuming something's wrong; check `adb devices` directly, and confirm
an `emulator.exe`/`qemu-system-x86_64.exe` process is actually running.

To build a release APK for sideloading onto a real device:
```
flutter build apk --release
```
See the root [README.md](../README.md)'s "Getting started" section
and `android/key.properties.example` for release signing.

## Testing without a real Pi

Most of this app is a thin client over a Raspberry Pi's MQTT broker
and HTTP API (see [PI_CONTRACT.md](PI_CONTRACT.md)) — normally nothing
interesting happens until it's pointed at a real, running monitor. To
exercise the UI before that's available, **debug builds only** expose
a "Developer" section at the bottom of the Settings screen:

- **Seed sample data** — inserts ~30 days of fake feed/change events
  (jittered, roughly every 2.5-3.5h for feeds and every 3-4.5h for
  changes) into the app's own local queue (the same queue real "Log
  feed"/"Log change" taps write to — see "Offline queue" below), and
  fakes an in-progress crying session on the Status tab by feeding a
  synthetic `cry_started` message through the same code path a real
  MQTT message takes. This is enough data to exercise the Care log
  tab's list behavior. It does **not** touch cry history or
  device-startup history — those are Pi-owned and read-only by design
  (see PI_CONTRACT.md); use the fake monitor server below to see those
  populated.
- **Clear sample data** — removes what "Seed sample data" added
  (matched by a `"seed data"` note field) and resets the in-memory
  active session. Doesn't touch anything on a real Pi.
- **Start/stop fake monitor server** — runs an in-process HTTP server
  (`lib/services/fake_pi_server.dart`) that serves ~30 days of
  realistic-looking cry sessions, device startup/shutdown events, and
  button-logged feed/change history, shaped exactly like
  `pi/sync_api.py`'s real JSON responses. While running, Settings'
  host/port are temporarily repointed at `localhost:<fake port>` — the
  real `SyncApiClient` code talks to it exactly as it would a real Pi,
  so this exercises the actual HTTP/JSON parsing path, not just a UI
  shortcut. "Stop" restores whatever host/port were configured before.
  This is the only way to see the History tab's cry-session and
  device-event rows populated without a real Pi — those stay
  deliberately unseedable from the app's own local storage (see
  history_screen.dart's comments on why cry data is Pi-only). Doesn't
  start an MQTT broker — Status tab alerts still need a real Pi or a
  manually-published test message (see "Testing against a real Pi"
  below).

This section is compiled out of release builds via `kDebugMode` — it's
not just hidden, the code path doesn't exist in a `flutter build apk
--release` binary.

## Testing against a real Pi

Once you have a Pi running `monitor.py` + `sync_api.py` (see the root
repo's `docs/INSTALL.md`), or want to simulate one from a dev machine:

1. Point the app at it: Settings → enter the Pi's LAN IP address.
   Default ports (1883 MQTT, 8081 sync API) match `pi/settings.py`'s
   defaults — only change these if you changed them on the Pi too.
2. **Status tab** should flip from "Disconnected" to "Connected" once
   the MQTT connection succeeds.
3. To manually trigger a test alert without waiting for a real cry,
   publish directly to the broker from any machine on the same
   network:
   ```
   mosquitto_pub -h <pi-ip> -t babymonitor/notify -r -m \
     '{"event":"cry_started","timestamp":"2026-01-01T00:00:00Z","stage1_confidence":0.9,"stage2_probs":{"hungry":0.6,"fussy":0.4},"context":{"seconds_since_feed":1200,"seconds_since_change":3600}}'
   ```
   Note the `-r` (retain) flag matches how `pi/notify.py` actually
   publishes — see PI_CONTRACT.md's staleness-check note if the
   timestamp is old and the app ignores it as expected.
4. Care events / history / pause / reset all exercise
   `pi/sync_api.py` directly — the easiest way to confirm they're
   wired up is to log a feed event in the app, then check it landed in
   `care_events.sqlite` on the Pi (or just look for it on the **History**
   tab on the next refresh, which pulls it straight back — the **Care
   log** tab intentionally won't show it once synced, see below).

## Offline queue behavior (feed/change logging away from the Pi)

Feed/change events are logged **locally first**, always, whether or
not the Pi is reachable — see `lib/services/local_event_queue.dart`.
Once an event syncs to the Pi, it's deleted from the local queue (see
`pruneSynced()`) — the Pi's copy is the only one that matters after
that, and the app's two screens make different use of this:

- **Care log tab** is a "what's still pending" view, not a history
  browser — it shows only this device's own not-yet-synced events from
  the **last 24 hours** (see `care_events_screen.dart`'s doc comment).
  Once an event syncs, it disappears from Care log — that's by design,
  not a bug; go to History to see it there instead.
- **History tab** shows the merged timeline: the Pi's confirmed cry
  sessions, device events, and care events, plus any of *this device's*
  care events that haven't synced yet. Because syncing deletes the
  local row, there's no special-casing needed to avoid double-counting
  — an event is either in the Pi's response or in the local queue,
  never both at once.

To test the queue itself:

1. Turn off WiFi (or otherwise make the Pi/fake monitor server
   unreachable).
2. Log a feed or change event — it should appear immediately in Care
   log with a cloud-off icon (pending sync), and also on History
   (same icon).
3. Reconnect, then pull-to-refresh either tab (or just reopen the app —
   a fresh MQTT connection also triggers a sync attempt automatically).
4. The event should disappear from Care log and lose its cloud-off icon
   on History, and a snackbar reports how many events were pushed.
5. Wait a day (or backdate a local row) to confirm Care log's 24-hour
   window actually excludes older unsynced events — this matters if
   the app is ever offline for an extended stretch; those events still
   sync normally and still show on History, they just age out of the
   Care log "what's pending" view.

If a sync attempt fails partway through a batch (e.g. WiFi drops mid
sync), already-synced events stay synced and the rest remain queued
for the next attempt — see `SyncCoordinator.sync()`'s comments for why
it processes in order and stops at the first failure rather than
reordering.

## Known rough edges

- **Tablet layouts are untested for polish** — everything works, but
  the phone-oriented single-column layout with a bottom `NavigationBar`
  will look sparse/stretched on a large tablet screen. Not worth fixing
  until it's clear the family's actual devices need it.
- **No mDNS/auto-discovery of the Pi** — you have to type its IP
  address manually in Settings. See PI_CONTRACT.md's "Discovery"
  section for why this was deferred.
