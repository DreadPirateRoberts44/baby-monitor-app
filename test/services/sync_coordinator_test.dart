import 'dart:convert';

import 'package:baby_monitor_app/models/care_event.dart';
import 'package:baby_monitor_app/services/local_event_queue.dart';
import 'package:baby_monitor_app/services/pi_connection_settings.dart';
import 'package:baby_monitor_app/services/sync_api_client.dart';
import 'package:baby_monitor_app/services/sync_coordinator.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Stands in for the real sqflite-backed queue -- avoids needing a real
/// platform channel/sqflite_common_ffi in a plain flutter_test run.
/// SyncCoordinator only ever calls getUnsynced/markSynced/pruneSynced,
/// so that's all this needs to fake.
class _FakeLocalEventQueue implements LocalEventQueue {
  final List<CareEvent> unsynced;
  final List<int> syncedIds = [];
  bool pruned = false;

  _FakeLocalEventQueue(this.unsynced);

  @override
  Future<List<CareEvent>> getUnsynced() async => unsynced;

  @override
  Future<void> markSynced(int localId) async {
    syncedIds.add(localId);
  }

  @override
  Future<void> pruneSynced() async {
    pruned = true;
  }

  @override
  Future<List<CareEvent>> getAll() async => unsynced;

  @override
  Future<int> enqueue({
    required String eventType,
    required DateTime timestamp,
    String? deviceId,
    String? note,
  }) async =>
      throw UnimplementedError();

  @override
  Future<void> deleteLocal(int localId) async =>
      throw UnimplementedError();
}

CareEvent _unsyncedEvent(int localId, {String eventType = 'feed'}) =>
    CareEvent(
      localId: localId,
      eventType: eventType,
      timestamp: DateTime.utc(2026, 1, 1, 8, localId),
      source: 'app',
      synced: false,
    );

Future<PiConnectionSettings> _settings() async {
  SharedPreferences.setMockInitialValues({});
  return PiConnectionSettings.load();
}

void main() {
  group('SyncCoordinator.sync', () {
    test('pushes every unsynced event and prunes on full success', () async {
      final queue = _FakeLocalEventQueue([
        _unsyncedEvent(1),
        _unsyncedEvent(2),
      ]);
      final client = SyncApiClient(
        await _settings(),
        httpClient: MockClient((request) async {
          return http.Response(jsonEncode({'status': 'created'}), 200);
        }),
      );
      final coordinator = SyncCoordinator(queue: queue, client: client);

      final count = await coordinator.sync();

      expect(count, 2);
      expect(queue.syncedIds, [1, 2]);
      expect(queue.pruned, isTrue);
    });

    test('treats a dedup "skipped_duplicate" response as success', () async {
      final queue = _FakeLocalEventQueue([_unsyncedEvent(1)]);
      final client = SyncApiClient(
        await _settings(),
        httpClient: MockClient((request) async {
          return http.Response(
              jsonEncode({'status': 'skipped_duplicate'}), 200);
        }),
      );
      final coordinator = SyncCoordinator(queue: queue, client: client);

      final count = await coordinator.sync();

      expect(count, 1);
      expect(queue.syncedIds, [1]);
    });

    test('stops at the first network failure without marking it synced',
        () async {
      var callCount = 0;
      final queue = _FakeLocalEventQueue([
        _unsyncedEvent(1),
        _unsyncedEvent(2),
      ]);
      final client = SyncApiClient(
        await _settings(),
        httpClient: MockClient((request) async {
          callCount++;
          throw Exception('socket closed');
        }),
      );
      final coordinator = SyncCoordinator(queue: queue, client: client);

      final count = await coordinator.sync();

      expect(count, 0);
      expect(queue.syncedIds, isEmpty);
      expect(queue.pruned, isFalse);
      // Stops after the first failure rather than trying the rest out of
      // order (see SyncCoordinator's own doc comment).
      expect(callCount, 1);
    });

    test('propagates a real API error (non-2xx) instead of swallowing it',
        () async {
      final queue = _FakeLocalEventQueue([_unsyncedEvent(1)]);
      final client = SyncApiClient(
        await _settings(),
        httpClient: MockClient((request) async {
          return http.Response('Internal Server Error', 500);
        }),
      );
      final coordinator = SyncCoordinator(queue: queue, client: client);

      // A genuine API-level failure (bad request, server error) is a real
      // bug signal, not "just not on the Pi's WiFi" -- SyncCoordinator
      // deliberately rethrows SyncApiException rather than swallowing it
      // the way a bare network exception is swallowed above.
      await expectLater(coordinator.sync(), throwsA(isA<SyncApiException>()));
      expect(queue.syncedIds, isEmpty);
    });

    test('does not prune when nothing was synced', () async {
      final queue = _FakeLocalEventQueue([]);
      final client = SyncApiClient(
        await _settings(),
        httpClient: MockClient((request) async {
          return http.Response(jsonEncode({'status': 'created'}), 200);
        }),
      );
      final coordinator = SyncCoordinator(queue: queue, client: client);

      final count = await coordinator.sync();

      expect(count, 0);
      expect(queue.pruned, isFalse);
    });

    test('a second concurrent call while syncing is a no-op', () async {
      final queue = _FakeLocalEventQueue([_unsyncedEvent(1)]);
      final client = SyncApiClient(
        await _settings(),
        httpClient: MockClient((request) async {
          await Future.delayed(const Duration(milliseconds: 20));
          return http.Response(jsonEncode({'status': 'created'}), 200);
        }),
      );
      final coordinator = SyncCoordinator(queue: queue, client: client);

      final first = coordinator.sync();
      final second = coordinator.sync();

      final results = await Future.wait([first, second]);
      expect(results, containsAll([0, 1]));
    });
  });
}
