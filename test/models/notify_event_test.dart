import 'dart:convert';

import 'package:baby_monitor_app/models/notify_event.dart';
import 'package:flutter_test/flutter_test.dart';

/// tryParse's only real caller (notify_listener.dart) always feeds it
/// genuine jsonDecode output, which is always Map<String, dynamic> --
/// round-tripping fixtures through jsonEncode/jsonDecode here (rather
/// than passing Dart map literals straight through) keeps these tests
/// honest about that, since a bare {} literal infers as
/// Map<dynamic, dynamic> and doesn't reflect what the wire actually
/// produces.
Map<String, dynamic> _wire(Map<String, dynamic> json) =>
    jsonDecode(jsonEncode(json)) as Map<String, dynamic>;

void main() {
  group('NotifyEvent.tryParse', () {
    test('parses a cry_started message', () {
      final event = NotifyEvent.tryParse(_wire({
        'event': 'cry_started',
        'timestamp': '2026-01-01T12:00:00Z',
        'stage1_confidence': 0.9,
        'stage2_probs': {'hungry': 0.5, 'fussy': 0.5},
        'context': {'seconds_since_feed': 100.0, 'seconds_since_change': null},
      }));

      expect(event, isNotNull);
      expect(event!.kind, NotifyEventKind.cryStarted);
      expect(event.timestamp, DateTime.parse('2026-01-01T12:00:00Z'));
      expect(event.stage1Confidence, 0.9);
      expect(event.stage2Probs, {'hungry': 0.5, 'fussy': 0.5});
      expect(event.context.secondsSinceFeed, 100.0);
      expect(event.context.secondsSinceChange, isNull);
      // Per PI_CONTRACT.md, cry_started never carries these -- confirm
      // tryParse doesn't invent them when the JSON simply omits them.
      expect(event.confirmedCrySeconds, isNull);
      expect(event.cryDensity, isNull);
    });

    test('parses a reason_updated message', () {
      final event = NotifyEvent.tryParse(_wire({
        'event': 'reason_updated',
        'timestamp': '2026-01-01T12:00:30Z',
        'aggregated_stage2_probs': {'hungry': 0.7, 'fussy': 0.3},
        'duration_seconds': 30.0,
        'confirmed_cry_seconds': 25.0,
        'cry_density': 0.83,
        'context': {},
      }));

      expect(event, isNotNull);
      expect(event!.kind, NotifyEventKind.reasonUpdated);
      expect(event.aggregatedStage2Probs, {'hungry': 0.7, 'fussy': 0.3});
      expect(event.durationSeconds, 30.0);
      expect(event.confirmedCrySeconds, 25.0);
      expect(event.cryDensity, 0.83);
    });

    test('parses a cry_ended message', () {
      final event = NotifyEvent.tryParse(_wire({
        'event': 'cry_ended',
        'timestamp': '2026-01-01T12:05:00Z',
        'aggregated_stage2_probs': {'tired': 1.0},
        'duration_seconds': 300.0,
        'confirmed_cry_seconds': 280.0,
        'cry_density': 0.93,
        'context': {'seconds_since_feed': 5400.0},
      }));

      expect(event, isNotNull);
      expect(event!.kind, NotifyEventKind.cryEnded);
      expect(event.context.secondsSinceFeed, 5400.0);
    });

    test('returns null for an unrecognized event type', () {
      final event = NotifyEvent.tryParse(_wire({
        'event': 'something_from_a_future_pi_version',
        'timestamp': '2026-01-01T12:00:00Z',
      }));
      expect(event, isNull);
    });

    test('returns null when the event field is missing', () {
      final event = NotifyEvent.tryParse(_wire({
        'timestamp': '2026-01-01T12:00:00Z',
      }));
      expect(event, isNull);
    });

    test('returns null when the timestamp is missing', () {
      final event = NotifyEvent.tryParse(_wire({'event': 'cry_started'}));
      expect(event, isNull);
    });

    test('returns null when the timestamp is unparseable', () {
      final event = NotifyEvent.tryParse(_wire({
        'event': 'cry_started',
        'timestamp': 'not-a-real-timestamp',
      }));
      expect(event, isNull);
    });

    test('treats a missing context object as an empty CryContext', () {
      final event = NotifyEvent.tryParse(_wire({
        'event': 'cry_started',
        'timestamp': '2026-01-01T12:00:00Z',
      }));
      expect(event, isNotNull);
      expect(event!.context.secondsSinceFeed, isNull);
      expect(event.context.secondsSinceChange, isNull);
    });
  });

  group('NotifyEvent.isStale', () {
    NotifyEvent eventAt(DateTime timestamp) => NotifyEvent(
          kind: NotifyEventKind.cryStarted,
          timestamp: timestamp,
          context: const CryContext(),
        );

    test('a message from just now is not stale', () {
      final event = eventAt(DateTime.now().toUtc());
      expect(event.isStale(), isFalse);
    });

    test('a retained message from hours ago is stale', () {
      final event =
          eventAt(DateTime.now().toUtc().subtract(const Duration(hours: 3)));
      expect(event.isStale(), isTrue);
    });

    test('respects a custom maxAge', () {
      final event =
          eventAt(DateTime.now().toUtc().subtract(const Duration(seconds: 90)));
      expect(event.isStale(maxAge: const Duration(minutes: 2)), isFalse);
      expect(event.isStale(maxAge: const Duration(seconds: 60)), isTrue);
    });
  });
}
