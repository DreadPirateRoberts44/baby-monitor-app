# The Pi-side contract

This app talks to the baby-monitor Pi over two local-network channels.
Both are defined and documented in the `baby-monitor` repo (Pi-side +
ML, kept separate on purpose — see that repo's `docs/INDEX.md`), not
here. This doc is a snapshot of the parts of that contract the app
needs to implement against, copied over so this repo is self-contained
for app development. **If the Pi-side contract changes, this doc needs
a manual re-sync from `baby-monitor/pi/README.md`** — it is not a live
dependency.

## Trust model

LAN-only, no auth, on both channels. The network boundary (home WiFi)
*is* the security boundary — same as every other component on the Pi
side. Not reachable from outside the home network (no cloud relay, no
Tailscale exposure for this API). The app is expected to:
- Discover/connect to the Pi only when on the same WiFi network.
- Store its own data locally and sync opportunistically, not assume
  it's always reachable.

## Channel 1: MQTT (live cry alerts)

- Broker: Mosquitto running on the Pi, default port `1883`.
- Topic: `babymonitor/notify` (single topic; `"event"` field
  distinguishes message kinds). A separate topic (`babymonitor/button`)
  carries wireless button presses — internal to the Pi side, the app
  does not need it.
- Published with **`retain=True`** — the broker holds the last message
  and delivers it immediately on (re)connect/subscribe. This means a
  freshly-connecting app may receive a message from hours/days ago.
  **Always compare the payload's `"timestamp"` against "now" and
  ignore stale messages** rather than alerting on them.

**Why no push notifications (APNs/FCM):** deliberately skipped. A real
push service needs a device-token registry (cloud state this project
doesn't have) and, for iOS, an Apple Developer account just for push
entitlements. Given the local-only design and no app-store
distribution, that tradeoff wasn't judged worth it. Instead:
**the app is expected to hold the MQTT connection open and play its
own local sound** when a `cry_started` message arrives.

- **Android**: hold the connection via a foreground service (same
  mechanism music/navigation apps use to run with the screen off) —
  see `flutter_foreground_task` in `pubspec.yaml`.
- **iOS** (future, not this milestone): declare a background audio
  session to stay alive; true silent backgrounding isn't possible on
  iOS without push. See this project's own notes on App Review risk
  and provisioning-profile expiry before shipping that.

**Message shapes** (one topic, `"event"` field selects the shape):

```json
{"event": "cry_started", "timestamp": "...", "stage1_confidence": 0.97,
 "stage2_probs": {"hungry": 0.4, "fussy": 0.5, "...": "..."},
 "context": {"seconds_since_feed": 1820.4, "seconds_since_change": null}}

{"event": "reason_updated", "timestamp": "...", "duration_seconds": 42.1,
 "aggregated_stage2_probs": {"...": "..."}, "context": {"...": "..."}}

{"event": "cry_ended", "timestamp": "...", "duration_seconds": 96.3,
 "aggregated_stage2_probs": {"...": "..."}, "context": {"...": "..."}}
```

Map these to three distinct UI behaviors, matching the Pi-side
alert/live-update split:
- **`cry_started`** — an **alert**: interrupt/notify, play a sound.
- **`reason_updated`** — a **live update only**: silently refresh the
  currently-displayed session's reason estimate. Do NOT alert/buzz —
  the caregiver has already been notified the baby is crying; this
  just means the reason guess changed as more audio accumulated.
- **`cry_ended`** — an **alert**: notify that the episode is over,
  carries the final aggregated reason.

`"context"` (time since feed/change) is intentionally not blended into
the model's probabilities — show it as plain context next to the
prediction ("3.2h since feed"), not as if it adjusted the prediction.

## Channel 2: HTTP sync API (`pi/sync_api.py`)

- Port: `settings.SYNC_API_PORT` on the Pi, default `8081`.
- Plain JSON over HTTP, no auth, LAN only.

```
GET    /care_events?since=<ISO8601>     pull feed/change events since a time
POST   /care_events                     push one event:
                                         {"event_type": "feed"|"change",
                                          "device_id": "...", "note": "...",
                                          "timestamp": "..."}
                                         (device_id/note/timestamp optional)
                                         -> 201 {"status": "created", "id": ...}
                                         -> 200 {"status": "skipped_duplicate"}
                                            (not an error — no special-case
                                            handling needed; see dedup below)
DELETE /care_events/<id>                remove one event (error correction)

GET    /cry_history?since=<ISO8601>     read-only cry-session history
GET    /device_events?since=<ISO8601>   read-only startup/shutdown log
                                         (explains gaps in cry_history —
                                         monitor was off, not "no crying")

GET    /prediction_state                {"paused": true|false}
POST   /prediction_state                {"paused": true|false} ->
                                         {"paused": ..., "changed_at": "..."}
                                         pause/resume inference on the Pi —
                                         the escape hatch for a misbehaving
                                         model. Capture keeps running;
                                         only predict/notify/history are
                                         skipped. An in-progress session is
                                         force-ended when pause takes effect.

POST   /reset                           {"confirm": "RESET"} ->
                                         {"status": "reset",
                                          "deleted": {"care_events": N,
                                          "cry_history": N,
                                          "device_events": N}}
                                         Irreversible. The Pi does this
                                         unconditionally on a valid request —
                                         THE APP OWNS ALL CONFIRM/WARNING UX.
                                         Never call this without an explicit,
                                         unambiguous user confirmation step.
```

**Duplicate handling**: `POST /care_events` is deduped server-side
(same type within `DEDUP_WINDOW_MINUTES`, default 5, is treated as a
likely duplicate and skipped). The app doesn't need to dedup client
side before sending — just handle the `skipped_duplicate` response as
a normal, non-error outcome.

**Multiple caregivers**: each app install generates and keeps its own
`device_id` (a plain UUID, purely informational — "who logged this",
not an auth mechanism) and sends it with everything it logs.

**No app-side event logging for feed/change beyond what's above** —
the wireless buttons are the primary input path by design (see the
Pi-side README's "Care events" section); the app's job is to sync and
review/correct, not to be the primary logging surface.

## Discovery

Not yet solved on the Pi side beyond "same WiFi network" — the app
needs a way to find the Pi's IP (broker + sync API assumed to be the
same host). For the first milestone, a manually-entered IP/hostname in
settings is enough; mDNS/broadcast discovery can come later if manual
entry proves annoying in practice.
