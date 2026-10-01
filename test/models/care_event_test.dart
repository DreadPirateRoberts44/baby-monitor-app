import 'package:baby_monitor_app/models/care_event.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('CareEvent.fromJson (Pi-sourced)', () {
    test('parses a full response', () {
      final event = CareEvent.fromJson({
        'id': 'evt-1',
        'event_type': 'feed',
        'timestamp': '2026-01-01T08:00:00Z',
        'source': 'button',
        'device_id': 'pi-01',
        'note': 'bottle',
      });

      expect(event.id, 'evt-1');
      expect(event.localId, isNull);
      expect(event.eventType, 'feed');
      expect(event.source, 'button');
      expect(event.deviceId, 'pi-01');
      expect(event.note, 'bottle');
      // A row read back from the Pi is already confirmed there.
      expect(event.synced, isTrue);
    });

    test('defaults source to "app" when omitted', () {
      final event = CareEvent.fromJson({
        'event_type': 'change',
        'timestamp': '2026-01-01T08:00:00Z',
      });
      expect(event.source, 'app');
    });
  });

  group('CareEvent.fromLocalRow (locally-queued)', () {
    test('parses an unsynced row', () {
      final event = CareEvent.fromLocalRow({
        'id': 5,
        'event_type': 'feed',
        'timestamp': '2026-01-01T08:00:00Z',
        'device_id': null,
        'note': null,
        'synced': 0,
      });

      expect(event.localId, 5);
      expect(event.id, isNull);
      expect(event.synced, isFalse);
      expect(event.source, 'app');
    });

    test('parses a synced row', () {
      final event = CareEvent.fromLocalRow({
        'id': 6,
        'event_type': 'change',
        'timestamp': '2026-01-01T08:00:00Z',
        'device_id': null,
        'note': null,
        'synced': 1,
      });
      expect(event.synced, isTrue);
    });
  });

  group('CareEvent.toPostJson', () {
    test('omits null optional fields', () {
      final event = CareEvent(
        eventType: 'feed',
        timestamp: DateTime.utc(2026, 1, 1, 8),
        source: 'app',
      );
      final json = event.toPostJson();

      expect(json['event_type'], 'feed');
      expect(json['timestamp'], '2026-01-01T08:00:00.000Z');
      expect(json.containsKey('device_id'), isFalse);
      expect(json.containsKey('note'), isFalse);
    });

    test('includes device_id and note when present', () {
      final event = CareEvent(
        eventType: 'change',
        timestamp: DateTime.utc(2026, 1, 1, 8),
        source: 'app',
        deviceId: 'device-abc',
        note: 'diaper change',
      );
      final json = event.toPostJson();

      expect(json['device_id'], 'device-abc');
      expect(json['note'], 'diaper change');
    });

    test('converts a local timestamp to UTC before encoding', () {
      final local = DateTime(2026, 6, 1, 10, 30);
      final event =
          CareEvent(eventType: 'feed', timestamp: local, source: 'app');
      final json = event.toPostJson();

      expect(json['timestamp'], local.toUtc().toIso8601String());
    });
  });

  group('CrySession.fromJson', () {
    test('parses a full response', () {
      final session = CrySession.fromJson({
        'id': 's-1',
        'started_at': '2026-01-01T08:00:00Z',
        'ended_at': '2026-01-01T08:05:00Z',
        'duration_seconds': 300.0,
        'top_reason': 'hungry',
        'reason_probs': {'hungry': 0.7, 'fussy': 0.3},
        'confirmed_cry_seconds': 270.0,
        'cry_density': 0.9,
      });

      expect(session.durationSeconds, 300.0);
      expect(session.confirmedCrySeconds, 270.0);
      expect(session.cryDensity, 0.9);
    });

    test('defaults confirmedCrySeconds to durationSeconds when omitted '
        '(old Pi build backward-compat)', () {
      final session = CrySession.fromJson({
        'id': 's-2',
        'started_at': '2026-01-01T08:00:00Z',
        'ended_at': '2026-01-01T08:05:00Z',
        'duration_seconds': 300.0,
        'top_reason': 'hungry',
        'reason_probs': {'hungry': 1.0},
      });

      expect(session.confirmedCrySeconds, 300.0);
      expect(session.cryDensity, 1.0);
    });

    test('defaults cryDensity to 0.0 for a zero-duration legacy session', () {
      final session = CrySession.fromJson({
        'id': 's-3',
        'started_at': '2026-01-01T08:00:00Z',
        'ended_at': '2026-01-01T08:00:00Z',
        'duration_seconds': 0.0,
        'top_reason': 'hungry',
        'reason_probs': {'hungry': 1.0},
      });

      expect(session.cryDensity, 0.0);
    });
  });

  group('DeviceEvent.fromJson', () {
    test('parses startup and shutdown events', () {
      final startup = DeviceEvent.fromJson({
        'id': 'd-1',
        'event_type': 'startup',
        'timestamp': '2026-01-01T00:00:00Z',
        'reason': null,
      });
      final shutdown = DeviceEvent.fromJson({
        'id': 'd-2',
        'event_type': 'shutdown',
        'timestamp': '2026-01-02T00:00:00Z',
        'reason': 'sigterm',
      });

      expect(startup.eventType, 'startup');
      expect(startup.reason, isNull);
      expect(shutdown.eventType, 'shutdown');
      expect(shutdown.reason, 'sigterm');
    });
  });
}
