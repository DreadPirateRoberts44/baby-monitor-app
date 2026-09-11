/// [localId] and [synced] only make sense for events that originated on
/// this device (see services/local_event_queue.dart) -- an event read
/// back from the Pi's /care_events has neither, since by definition the
/// Pi already has it. See docs/PI_CONTRACT.md's "App sync" section for
/// why the app queues locally rather than requiring the home WiFi to log
/// a feed/change event.
class CareEvent {
  final String? id;
  final int? localId;
  final String eventType; // "feed" | "change"
  final DateTime timestamp;
  final String source; // "button" | "app"
  final String? deviceId;
  final String? note;
  final bool synced;

  const CareEvent({
    this.id,
    this.localId,
    required this.eventType,
    required this.timestamp,
    required this.source,
    this.deviceId,
    this.note,
    this.synced = true,
  });

  factory CareEvent.fromJson(Map<String, dynamic> json) => CareEvent(
        id: json['id'] as String?,
        eventType: json['event_type'] as String,
        timestamp: DateTime.parse(json['timestamp'] as String),
        source: json['source'] as String? ?? 'app',
        deviceId: json['device_id'] as String?,
        note: json['note'] as String?,
      );

  factory CareEvent.fromLocalRow(Map<String, dynamic> row) => CareEvent(
        localId: row['id'] as int,
        eventType: row['event_type'] as String,
        timestamp: DateTime.parse(row['timestamp'] as String),
        source: 'app',
        deviceId: row['device_id'] as String?,
        note: row['note'] as String?,
        synced: (row['synced'] as int) == 1,
      );

  Map<String, dynamic> toPostJson() => {
        'event_type': eventType,
        'timestamp': timestamp.toUtc().toIso8601String(),
        if (deviceId != null) 'device_id': deviceId,
        if (note != null) 'note': note,
      };
}

class CrySession {
  final String id;
  final DateTime startedAt;
  final DateTime endedAt;
  final double durationSeconds;
  final String topReason;
  final Map<String, double> reasonProbs;

  const CrySession({
    required this.id,
    required this.startedAt,
    required this.endedAt,
    required this.durationSeconds,
    required this.topReason,
    required this.reasonProbs,
  });

  factory CrySession.fromJson(Map<String, dynamic> json) => CrySession(
        id: json['id'] as String,
        startedAt: DateTime.parse(json['started_at'] as String),
        endedAt: DateTime.parse(json['ended_at'] as String),
        durationSeconds: (json['duration_seconds'] as num).toDouble(),
        topReason: json['top_reason'] as String,
        reasonProbs: (json['reason_probs'] as Map).map(
          (k, v) => MapEntry(k as String, (v as num).toDouble()),
        ),
      );
}

class DeviceEvent {
  final String id;
  final String eventType; // "startup" | "shutdown"
  final DateTime timestamp;
  final String? reason;

  const DeviceEvent({
    required this.id,
    required this.eventType,
    required this.timestamp,
    this.reason,
  });

  factory DeviceEvent.fromJson(Map<String, dynamic> json) => DeviceEvent(
        id: json['id'] as String,
        eventType: json['event_type'] as String,
        timestamp: DateTime.parse(json['timestamp'] as String),
        reason: json['reason'] as String?,
      );
}
