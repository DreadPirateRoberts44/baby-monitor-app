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
 "aggregated_stage2_probs": {"...": "..."}, "confirmed_cry_seconds": 38.0,
 "cry_density": 0.903, "context": {"...": "..."}}

{"event": "cry_ended", "timestamp": "...", "duration_seconds": 96.3,
 "aggregated_stage2_probs": {"...": "..."}, "confirmed_cry_seconds": 52.0,
 "cry_density": 0.54, "context": {"...": "..."}}
```

Map these to three distinct UI behaviors, matching the Pi-side
alert/live-update split:
- **`cry_started`** — an **alert**: interrupt/notify, play a sound. Fires
  only after several consecutive confident-cry windows on the Pi side
  (`settings.SESSION_START_MIN_WINDOWS`), filtering out a single
  misclassified window before the app ever sees it — so there's a few
  seconds of latency between the baby actually starting to cry and this
  message, by design.
- **`reason_updated`** — a **live update only**: silently refresh the
  currently-displayed session's reason estimate. Do NOT alert/buzz —
  the caregiver has already been notified the baby is crying; this
  just means the reason guess changed as more audio accumulated.
- **`cry_ended`** — an **alert**: tells the app the episode is over,
  carries the final aggregated reason. Can fire up to
  `settings.SESSION_MERGE_WINDOW_SECONDS` (default 10 min on the Pi)
  after the caregiver actually heard/handled the cry, because a
  session on the Pi side stays open across quiet gaps that short (baby
  picked up and carried out of mic range, still crying, shouldn't count
  as a second session) — treat this as lower-urgency than `cry_started`
  in whatever UI/sound choice distinguishes them (e.g. no buzz, just
  update the active-session card to a "did it stop?" state and clear it
  after a short delay), but DO still handle it: it's the only reliable
  signal that a session is over, and without it an active-session UI
  would otherwise stay showing "crying now" indefinitely if nothing else
  times it out.

`"confirmed_cry_seconds"`/`"cry_density"` (on `reason_updated`/`cry_ended`
only — never `cry_started`, where it would trivially read `1.0`/full
duration and add nothing) distinguish "session ran long because the baby
cried the whole time" from "session ran long because of an absorbed quiet
gap, only part of it was confirmed crying." `cry_density` is
`confirmed_cry_seconds / duration_seconds`, 0.0–1.0, 1.0 = wall-to-wall
confirmed crying. Worth surfacing somewhere in session detail UI (e.g.
"38s confirmed crying, 90% of session") now that `duration_seconds` alone
can be misleading about how much of that time was actually crying.

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

GET    /cry_history?since=<ISO8601>     read-only cry-session history ->
                                         {"sessions": [{"id", "started_at",
                                          "ended_at", "duration_seconds",
                                          "top_reason", "reason_probs",
                                          "confirmed_cry_seconds",
                                          "cry_density"}, ...]}
                                         (confirmed_cry_seconds/cry_density:
                                         same meaning as the MQTT payloads
                                         above)
GET    /device_events?since=<ISO8601>   read-only startup/shutdown log
                                         (explains gaps in cry_history —
                                         monitor was off, not "no crying")

GET    /detection_settings              {"stage1_confidence_threshold": 0.85,
                                          "session_start_min_windows": 2,
                                          "session_end_missed_windows": 150}
POST   /detection_settings              body: any subset of the three keys,
                                         e.g. {"stage1_confidence_threshold":
                                         0.8} -> 200 with all three current
                                         values, or 400 {"error": "..."} if
                                         invalid.
                                         {"reset": true} restores Pi defaults
                                         (returns all three, same as above).
                                         stage1_confidence_threshold is the
                                         same stage-1 gate as cry_started's
                                         confidence (see MQTT section);
                                         session_start_min_windows is
                                         settings.SESSION_START_MIN_WINDOWS,
                                         also referenced above.

GET    /prediction_state                {"paused": true|false}
POST   /prediction_state                {"paused": true|false} ->
                                         {"paused": ..., "changed_at": "..."}
                                         pause/resume inference on the Pi —
                                         the escape hatch for a misbehaving
                                         model. Capture keeps running;
                                         only predict/notify/history are
                                         skipped. A CONFIRMED in-progress
                                         session is force-ended (fires
                                         cry_ended normally) when pause
                                         takes effect; an unconfirmed
                                         candidate (hadn't reached
                                         SESSION_START_MIN_WINDOWS yet) is
                                         just discarded -- it was never
                                         alerted, so there's nothing to end.

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
