import 'package:baby_monitor_app/models/detection_settings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DetectionSettings', () {
    test('round-trips through fromJson/toJson', () {
      final settings = DetectionSettings.fromJson({
        'stage1_confidence_threshold': 0.85,
        'session_start_min_windows': 2,
        'session_end_missed_windows': 150,
      });

      expect(settings.stage1ConfidenceThreshold, 0.85);
      expect(settings.sessionStartMinWindows, 2);
      expect(settings.sessionEndMissedWindows, 150);
      expect(settings.toJson(), {
        'stage1_confidence_threshold': 0.85,
        'session_start_min_windows': 2,
        'session_end_missed_windows': 150,
      });
    });

    test('accepts an integer threshold from JSON (e.g. exactly 1)', () {
      final settings = DetectionSettings.fromJson({
        'stage1_confidence_threshold': 1,
        'session_start_min_windows': 3,
        'session_end_missed_windows': 100,
      });
      expect(settings.stage1ConfidenceThreshold, 1.0);
    });
  });
}
