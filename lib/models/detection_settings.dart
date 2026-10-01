/// Pi-side cry-detection tuning knobs, editable from Settings. See
/// docs/PI_CONTRACT.md's HTTP sync API section for the wire format.
class DetectionSettings {
  final double stage1ConfidenceThreshold;
  final int sessionStartMinWindows;
  final int sessionEndMissedWindows;

  const DetectionSettings({
    required this.stage1ConfidenceThreshold,
    required this.sessionStartMinWindows,
    required this.sessionEndMissedWindows,
  });

  factory DetectionSettings.fromJson(Map<String, dynamic> json) =>
      DetectionSettings(
        stage1ConfidenceThreshold:
            (json['stage1_confidence_threshold'] as num).toDouble(),
        sessionStartMinWindows: json['session_start_min_windows'] as int,
        sessionEndMissedWindows: json['session_end_missed_windows'] as int,
      );

  Map<String, dynamic> toJson() => {
        'stage1_confidence_threshold': stage1ConfidenceThreshold,
        'session_start_min_windows': sessionStartMinWindows,
        'session_end_missed_windows': sessionEndMissedWindows,
      };
}
