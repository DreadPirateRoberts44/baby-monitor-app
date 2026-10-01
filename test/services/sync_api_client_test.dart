import 'dart:convert';

import 'package:baby_monitor_app/models/care_event.dart';
import 'package:baby_monitor_app/services/pi_connection_settings.dart';
import 'package:baby_monitor_app/services/sync_api_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<PiConnectionSettings> _settingsWithHost(String host) async {
  SharedPreferences.setMockInitialValues({'pi_host': host});
  return PiConnectionSettings.load();
}

void main() {
  group('SyncApiClient', () {
    test('getCareEvents omits since= when not given', () async {
      Uri? requestedUri;
      final client = SyncApiClient(
        await _settingsWithHost('192.168.1.42'),
        httpClient: MockClient((request) async {
          requestedUri = request.url;
          return http.Response(jsonEncode({'events': []}), 200);
        }),
      );

      await client.getCareEvents();

      expect(requestedUri!.queryParameters.containsKey('since'), isFalse);
    });

    test('getCareEvents encodes since= as UTC ISO8601', () async {
      Uri? requestedUri;
      final client = SyncApiClient(
        await _settingsWithHost('192.168.1.42'),
        httpClient: MockClient((request) async {
          requestedUri = request.url;
          return http.Response(jsonEncode({'events': []}), 200);
        }),
      );

      final since = DateTime(2026, 1, 1, 8, 30);
      await client.getCareEvents(since: since);

      expect(requestedUri!.queryParameters['since'],
          since.toUtc().toIso8601String());
    });

    test('getCryHistory parses returned sessions', () async {
      final client = SyncApiClient(
        await _settingsWithHost('192.168.1.42'),
        httpClient: MockClient((request) async {
          expect(request.url.path, '/cry_history');
          return http.Response(
            jsonEncode({
              'sessions': [
                {
                  'id': 's-1',
                  'started_at': '2026-01-01T08:00:00Z',
                  'ended_at': '2026-01-01T08:05:00Z',
                  'duration_seconds': 300.0,
                  'top_reason': 'hungry',
                  'reason_probs': {'hungry': 1.0},
                }
              ],
            }),
            200,
          );
        }),
      );

      final sessions = await client.getCryHistory();

      expect(sessions, hasLength(1));
      expect(sessions.first.topReason, 'hungry');
    });

    test('postCareEvent returns true for "created"', () async {
      final client = SyncApiClient(
        await _settingsWithHost('192.168.1.42'),
        httpClient: MockClient((request) async {
          expect(request.method, 'POST');
          expect(request.url.path, '/care_events');
          return http.Response(jsonEncode({'status': 'created'}), 200);
        }),
      );

      final created = await client.postCareEvent(_sampleEvent());
      expect(created, isTrue);
    });

    test('postCareEvent returns false for "skipped_duplicate"', () async {
      final client = SyncApiClient(
        await _settingsWithHost('192.168.1.42'),
        httpClient: MockClient((request) async {
          return http.Response(
              jsonEncode({'status': 'skipped_duplicate'}), 200);
        }),
      );

      final created = await client.postCareEvent(_sampleEvent());
      expect(created, isFalse);
    });

    test('deleteCareEvent hits DELETE /care_events/<id>', () async {
      String? method;
      String? path;
      final client = SyncApiClient(
        await _settingsWithHost('192.168.1.42'),
        httpClient: MockClient((request) async {
          method = request.method;
          path = request.url.path;
          return http.Response('', 200);
        }),
      );

      await client.deleteCareEvent('evt-123');

      expect(method, 'DELETE');
      expect(path, '/care_events/evt-123');
    });

    test('throws SyncApiException on a non-2xx response', () async {
      final client = SyncApiClient(
        await _settingsWithHost('192.168.1.42'),
        httpClient: MockClient((request) async {
          return http.Response('not found', 404);
        }),
      );

      await expectLater(
        client.getCareEvents(),
        throwsA(isA<SyncApiException>()
            .having((e) => e.statusCode, 'statusCode', 404)),
      );
    });

    test('getPredictionPaused/setPredictionPaused round-trip the flag',
        () async {
      var lastPostedBody = '';
      final client = SyncApiClient(
        await _settingsWithHost('192.168.1.42'),
        httpClient: MockClient((request) async {
          if (request.method == 'POST') {
            lastPostedBody = request.body;
            return http.Response(jsonEncode({'status': 'ok'}), 200);
          }
          return http.Response(jsonEncode({'paused': true}), 200);
        }),
      );

      final paused = await client.getPredictionPaused();
      expect(paused, isTrue);

      await client.setPredictionPaused(true);
      expect(jsonDecode(lastPostedBody), {'paused': true});
    });

    test('getDetectionSettings parses the three fields', () async {
      final client = SyncApiClient(
        await _settingsWithHost('192.168.1.42'),
        httpClient: MockClient((request) async {
          expect(request.url.path, '/detection_settings');
          return http.Response(
            jsonEncode({
              'stage1_confidence_threshold': 0.85,
              'session_start_min_windows': 2,
              'session_end_missed_windows': 150,
            }),
            200,
          );
        }),
      );

      final settings = await client.getDetectionSettings();
      expect(settings.stage1ConfidenceThreshold, 0.85);
      expect(settings.sessionStartMinWindows, 2);
      expect(settings.sessionEndMissedWindows, 150);
    });

    test('updateDetectionSettings posts only the given fields', () async {
      Map<String, dynamic>? postedBody;
      final client = SyncApiClient(
        await _settingsWithHost('192.168.1.42'),
        httpClient: MockClient((request) async {
          postedBody = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(
            jsonEncode({
              'stage1_confidence_threshold': 0.8,
              'session_start_min_windows': 2,
              'session_end_missed_windows': 150,
            }),
            200,
          );
        }),
      );

      final updated = await client.updateDetectionSettings(
          stage1ConfidenceThreshold: 0.8);

      expect(postedBody, {'stage1_confidence_threshold': 0.8});
      expect(updated.stage1ConfidenceThreshold, 0.8);
    });

    test('updateDetectionSettings throws DetectionSettingsException on 400',
        () async {
      final client = SyncApiClient(
        await _settingsWithHost('192.168.1.42'),
        httpClient: MockClient((request) async {
          return http.Response(
            jsonEncode({'error': 'threshold must be 0-1'}),
            400,
          );
        }),
      );

      await expectLater(
        client.updateDetectionSettings(stage1ConfidenceThreshold: 5),
        throwsA(isA<DetectionSettingsException>().having(
            (e) => e.message, 'message', 'threshold must be 0-1')),
      );
    });

    test('resetDetectionSettings posts {"reset": true}', () async {
      Map<String, dynamic>? postedBody;
      final client = SyncApiClient(
        await _settingsWithHost('192.168.1.42'),
        httpClient: MockClient((request) async {
          postedBody = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(
            jsonEncode({
              'stage1_confidence_threshold': 0.85,
              'session_start_min_windows': 2,
              'session_end_missed_windows': 150,
            }),
            200,
          );
        }),
      );

      final defaults = await client.resetDetectionSettings();

      expect(postedBody, {'reset': true});
      expect(defaults.sessionStartMinWindows, 2);
    });

    test('resetAllData returns the deleted-counts map', () async {
      final client = SyncApiClient(
        await _settingsWithHost('192.168.1.42'),
        httpClient: MockClient((request) async {
          return http.Response(
            jsonEncode({
              'deleted': {'care_events': 3, 'cry_sessions': 1},
            }),
            200,
          );
        }),
      );

      final deleted = await client.resetAllData();
      expect(deleted, {'care_events': 3, 'cry_sessions': 1});
    });
  });
}

CareEvent _sampleEvent() => CareEvent(
      eventType: 'feed',
      timestamp: DateTime.utc(2026, 1, 1, 8),
      source: 'app',
    );
