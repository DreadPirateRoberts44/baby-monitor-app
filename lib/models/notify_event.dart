/// Mirrors the three message shapes published on `babymonitor/notify`.
/// See docs/PI_CONTRACT.md for the wire format and why reason_updated
/// is a silent refresh, not an alert.
library;

enum NotifyEventKind { cryStarted, reasonUpdated, cryEnded }

class CryContext {
  final double? secondsSinceFeed;
  final double? secondsSinceChange;

  const CryContext({this.secondsSinceFeed, this.secondsSinceChange});

  factory CryContext.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const CryContext();
    return CryContext(
      secondsSinceFeed: (json['seconds_since_feed'] as num?)?.toDouble(),
      secondsSinceChange: (json['seconds_since_change'] as num?)?.toDouble(),
    );
  }
}

class NotifyEvent {
  final NotifyEventKind kind;
  final DateTime timestamp;
  final double? stage1Confidence;
  final Map<String, double>? stage2Probs;
  final Map<String, double>? aggregatedStage2Probs;
  final double? durationSeconds;

  /// Approximate seconds of ACTUAL confident crying within the session, as
  /// opposed to [durationSeconds] which also counts any quiet gap the
  /// Pi-side merge window absorbed (see docs/PI_CONTRACT.md). Present on
  /// reasonUpdated/cryEnded only -- null on cryStarted, where it would
  /// trivially equal the elapsed time so far and add nothing.
  final double? confirmedCrySeconds;

  /// confirmedCrySeconds / durationSeconds as a 0.0-1.0 ratio -- 1.0 means
  /// wall-to-wall confirmed crying with no absorbed gaps. Same
  /// null-on-cryStarted rule as confirmedCrySeconds.
  final double? cryDensity;

  final CryContext context;

  const NotifyEvent({
    required this.kind,
    required this.timestamp,
    this.stage1Confidence,
    this.stage2Probs,
    this.aggregatedStage2Probs,
    this.durationSeconds,
    this.confirmedCrySeconds,
    this.cryDensity,
    required this.context,
  });

  /// Returns null on an unrecognized "event" value rather than throwing —
  /// a forward-incompatible Pi-side change shouldn't crash the app, just
  /// silently drop the message.
  static NotifyEvent? tryParse(Map<String, dynamic> json) {
    final kind = switch (json['event']) {
      'cry_started' => NotifyEventKind.cryStarted,
      'reason_updated' => NotifyEventKind.reasonUpdated,
      'cry_ended' => NotifyEventKind.cryEnded,
      _ => null,
    };
    if (kind == null) return null;

    final timestampStr = json['timestamp'] as String?;
    if (timestampStr == null) return null;
    final timestamp = DateTime.tryParse(timestampStr);
    if (timestamp == null) return null;

    return NotifyEvent(
      kind: kind,
      timestamp: timestamp,
      stage1Confidence: (json['stage1_confidence'] as num?)?.toDouble(),
      stage2Probs: _probsMap(json['stage2_probs']),
      aggregatedStage2Probs: _probsMap(json['aggregated_stage2_probs']),
      durationSeconds: (json['duration_seconds'] as num?)?.toDouble(),
      confirmedCrySeconds: (json['confirmed_cry_seconds'] as num?)?.toDouble(),
      cryDensity: (json['cry_density'] as num?)?.toDouble(),
      context: CryContext.fromJson(json['context'] as Map<String, dynamic>?),
    );
  }

  /// True if this message is older than [maxAge] — the retained-message
  /// staleness check docs/PI_CONTRACT.md calls out: a freshly-connecting
  /// app can receive a replay of the last message from hours/days ago and
  /// must not treat it as a live alert.
  bool isStale({Duration maxAge = const Duration(minutes: 2)}) {
    return DateTime.now().toUtc().difference(timestamp.toUtc()) > maxAge;
  }

  static Map<String, double>? _probsMap(Object? raw) {
    if (raw is! Map) return null;
    return raw.map((k, v) => MapEntry(k as String, (v as num).toDouble()));
  }
}
