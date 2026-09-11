import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

/// Debug-only in-process HTTP server that mimics pi/sync_api.py's
/// responses. Lets the real SyncApiClient/history_screen code exercise
/// its actual HTTP+JSON path against realistic-looking data, instead of
/// special-casing the UI to accept fake data directly -- cry sessions
/// and device events are Pi-owned/read-only by design (see
/// PI_CONTRACT.md), so this is the only way to see them populated in
/// History without a real Pi, without breaking that boundary.
///
/// Serves canned, generated-on-start responses shaped exactly like
/// pi/sync_api.py's real JSON (see that file's _session_to_json /
/// _device_event_to_json / _event_to_json). Read-only endpoints only --
/// POST /care_events, /prediction_state, /reset all return simple
/// stubbed-OK responses rather than actually persisting anything,
/// since the point is to view history, not to test the Pi's own write
/// logic (that's pi/sync_api.py's own responsibility to test).
class FakePiServer {
  HttpServer? _server;
  final List<Map<String, dynamic>> _sessions;
  final List<Map<String, dynamic>> _deviceEvents;
  final List<Map<String, dynamic>> _careEvents;

  FakePiServer._(this._sessions, this._deviceEvents, this._careEvents);

  factory FakePiServer.generate({int days = 30, int seed = 7}) {
    assert(kDebugMode, 'FakePiServer must only be used in debug builds');
    final random = Random(seed);
    final now = DateTime.now().toUtc();
    final start = now.subtract(Duration(days: days));

    const reasons = ['hungry', 'fussy', 'tired'];
    final sessions = <Map<String, dynamic>>[];
    final deviceEvents = <Map<String, dynamic>>[];
    final careEvents = <Map<String, dynamic>>[];

    // Monitor startup at the beginning of the seeded window, then an
    // occasional shutdown+restart pair -- mirrors device_events.py's
    // real behavior (a crash-and-restart looks the same as a deliberate
    // power cycle, see pi/README.md's "Device events" section).
    var deviceUp = start;
    deviceEvents.add({
      'id': 'seed-dev-${deviceEvents.length}',
      'event_type': 'startup',
      'timestamp': deviceUp.toIso8601String(),
      'reason': null,
    });
    while (deviceUp.isBefore(now)) {
      deviceUp = deviceUp.add(Duration(
        hours: 36 + random.nextInt(96),
      ));
      if (deviceUp.isAfter(now)) break;
      final downFor = Duration(minutes: 5 + random.nextInt(120));
      deviceEvents.add({
        'id': 'seed-dev-${deviceEvents.length}',
        'event_type': 'shutdown',
        'timestamp': deviceUp.toIso8601String(),
        'reason': random.nextBool() ? 'sigterm' : 'keyboard_interrupt',
      });
      deviceUp = deviceUp.add(downFor);
      deviceEvents.add({
        'id': 'seed-dev-${deviceEvents.length}',
        'event_type': 'startup',
        'timestamp': deviceUp.toIso8601String(),
        'reason': null,
      });
    }

    // A handful of cry sessions per day, each with a plausible reason
    // breakdown (one dominant reason, matching how cry_history.py
    // stores the aggregated probs at session end).
    var day = start;
    while (day.isBefore(now)) {
      final sessionsToday = random.nextInt(4); // 0-3/day
      for (var i = 0; i < sessionsToday; i++) {
        final startedAt = day.add(Duration(
          hours: random.nextInt(24),
          minutes: random.nextInt(60),
        ));
        if (startedAt.isAfter(now)) continue;
        final durationSeconds = 30.0 + random.nextInt(600);
        final endedAt =
            startedAt.add(Duration(seconds: durationSeconds.round()));

        final topReason = reasons[random.nextInt(reasons.length)];
        final probs = <String, double>{};
        var remaining = 1.0;
        for (final r in reasons) {
          if (r == topReason) continue;
          final p = (random.nextDouble() * remaining * 0.4);
          probs[r] = p;
          remaining -= p;
        }
        probs[topReason] = remaining;

        sessions.add({
          'id': 'seed-session-${sessions.length}',
          'started_at': startedAt.toIso8601String(),
          'ended_at': endedAt.toIso8601String(),
          'duration_seconds': durationSeconds,
          'top_reason': topReason,
          'reason_probs': probs,
        });
      }
      day = day.add(const Duration(days: 1));
    }

    // Feed/change history "as if" logged via the wireless buttons over
    // the same window -- source: "button", matching the real primary
    // input path (see pi/README.md's "Care events" section: the app
    // logging feed/change is the exception, not the norm).
    var feedTime = start;
    while (feedTime.isBefore(now)) {
      feedTime = feedTime.add(Duration(
        hours: 2,
        minutes: 30 + random.nextInt(90),
      ));
      if (feedTime.isAfter(now)) break;
      careEvents.add({
        'id': 'seed-care-${careEvents.length}',
        'event_type': 'feed',
        'timestamp': feedTime.toIso8601String(),
        'source': 'button',
        'device_id': null,
        'note': null,
      });
    }
    var changeTime = start.add(const Duration(hours: 1));
    while (changeTime.isBefore(now)) {
      changeTime = changeTime.add(Duration(
        hours: 3,
        minutes: random.nextInt(90),
      ));
      if (changeTime.isAfter(now)) break;
      careEvents.add({
        'id': 'seed-care-${careEvents.length}',
        'event_type': 'change',
        'timestamp': changeTime.toIso8601String(),
        'source': 'button',
        'device_id': null,
        'note': null,
      });
    }

    return FakePiServer._(sessions, deviceEvents, careEvents);
  }

  bool get isRunning => _server != null;
  int? get port => _server?.port;

  Future<int> start() async {
    assert(kDebugMode, 'FakePiServer must only be used in debug builds');
    if (_server != null) return _server!.port;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    server.listen(_handle);
    return server.port;
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  void _handle(HttpRequest request) async {
    final path = request.uri.path;
    final since = request.uri.queryParameters['since'] != null
        ? DateTime.tryParse(request.uri.queryParameters['since']!)
        : null;

    Map<String, dynamic> body = {};
    switch ('${request.method} $path') {
      case 'GET /cry_history':
        body = {
          'sessions': _filterSince(_sessions, 'started_at', since),
        };
        break;
      case 'GET /device_events':
        body = {
          'events': _filterSince(_deviceEvents, 'timestamp', since),
        };
        break;
      case 'GET /care_events':
        body = {
          'events': _filterSince(_careEvents, 'timestamp', since),
        };
        break;
      case 'GET /prediction_state':
        body = {'paused': false};
        break;
      default:
        if (request.method == 'POST' &&
            (path == '/care_events' ||
                path == '/prediction_state' ||
                path == '/reset')) {
          // Not actually persisted -- see class doc. Good enough to let
          // the UI's success/failure paths run without erroring.
          request.response
            ..statusCode = 200
            ..headers.contentType = ContentType.json
            ..write(jsonEncode({'status': 'ok'}));
          await request.response.close();
          return;
        }
        request.response.statusCode = 404;
        await request.response.close();
        return;
    }

    request.response
      ..statusCode = 200
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(body));
    await request.response.close();
  }

  List<Map<String, dynamic>> _filterSince(
    List<Map<String, dynamic>> items,
    String field,
    DateTime? since,
  ) {
    if (since == null) return items;
    return items
        .where((item) => DateTime.parse(item[field] as String).isAfter(since))
        .toList();
  }
}
