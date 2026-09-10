import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

/// Per-install connection config and identity. Manual host entry for now —
/// see docs/PI_CONTRACT.md's "Discovery" section for why (no mDNS yet).
class PiConnectionSettings {
  static const _hostKey = 'pi_host';
  static const _mqttPortKey = 'mqtt_port';
  static const _syncPortKey = 'sync_port';
  static const _deviceIdKey = 'device_id';

  static const defaultMqttPort = 1883;
  static const defaultSyncPort = 8081;

  final SharedPreferences _prefs;

  PiConnectionSettings._(this._prefs);

  static Future<PiConnectionSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    final settings = PiConnectionSettings._(prefs);
    // A stable per-install id is required the first time — this is the
    // "device_id" sent with every logged event (see PI_CONTRACT.md's
    // "Multiple caregivers" section). Purely informational, not auth.
    if (!prefs.containsKey(_deviceIdKey)) {
      await prefs.setString(_deviceIdKey, const Uuid().v4());
    }
    return settings;
  }

  String get deviceId => _prefs.getString(_deviceIdKey)!;

  String? get host => _prefs.getString(_hostKey);
  Future<void> setHost(String value) => _prefs.setString(_hostKey, value);

  int get mqttPort => _prefs.getInt(_mqttPortKey) ?? defaultMqttPort;
  Future<void> setMqttPort(int value) => _prefs.setInt(_mqttPortKey, value);

  int get syncPort => _prefs.getInt(_syncPortKey) ?? defaultSyncPort;
  Future<void> setSyncPort(int value) => _prefs.setInt(_syncPortKey, value);

  bool get isConfigured => host != null && host!.isNotEmpty;
}
