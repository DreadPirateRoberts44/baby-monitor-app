import 'package:audioplayers/audioplayers.dart';

/// Plays the short, distinctive chime that alerts the caregiver a crying
/// session has started. Kept as its own player instance (rather than
/// reusing one for UI sounds elsewhere) since it's set to play at max
/// volume regardless of any in-app mute state -- this alert should be
/// heard.
class AlertSoundPlayer {
  static const _chimeAsset = 'sounds/cry_alert_chime.wav';

  final AudioPlayer _player = AudioPlayer();

  Future<void> playCryStartedChime() async {
    try {
      await _player.stop();
      await _player.setVolume(1.0);
      await _player.play(AssetSource(_chimeAsset));
    } catch (_) {
      // Best-effort -- a device with no audio output (or a codec issue)
      // shouldn't crash the alert path. The visual alert still shows.
    }
  }

  void dispose() {
    _player.dispose();
  }
}
