import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/care_event.dart';
import '../models/detection_settings.dart';
import 'pi_connection_settings.dart';

/// Thin client over pi/sync_api.py. LAN-only, no auth — see
/// docs/PI_CONTRACT.md. Every call can fail simply because the phone
/// isn't on the home WiFi right now; callers should treat that as a
/// normal, expected outcome (try again next sync), not an error to
/// surface loudly.
class SyncApiClient {
  final PiConnectionSettings settings;
  final http.Client _http;

  SyncApiClient(this.settings, {http.Client? httpClient})
      : _http = httpClient ?? http.Client();

  Uri _uri(String path, [Map<String, String>? query]) {
    return Uri.http('${settings.host}:${settings.syncPort}', path, query);
  }

  Future<List<CareEvent>> getCareEvents({DateTime? since}) async {
    final resp = await _http.get(_uri('/care_events', _sinceQuery(since)));
    _checkOk(resp);
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    return (body['events'] as List)
        .map((e) => CareEvent.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Returns true if the event was created, false if the Pi-side dedup
  /// skipped it as a likely duplicate — both are success outcomes; see
  /// PI_CONTRACT.md's "Duplicate handling". Only a thrown exception
  /// (network failure, non-2xx) is a real failure.
  Future<bool> postCareEvent(CareEvent event) async {
    final resp = await _http.post(
      _uri('/care_events'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(event.toPostJson()),
    );
    _checkOk(resp);
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    return body['status'] == 'created';
  }

  Future<void> deleteCareEvent(String id) async {
    final resp = await _http.delete(_uri('/care_events/$id'));
    _checkOk(resp);
  }

  Future<List<CrySession>> getCryHistory({DateTime? since}) async {
    final resp = await _http.get(_uri('/cry_history', _sinceQuery(since)));
    _checkOk(resp);
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    return (body['sessions'] as List)
        .map((e) => CrySession.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<List<DeviceEvent>> getDeviceEvents({DateTime? since}) async {
    final resp = await _http.get(_uri('/device_events', _sinceQuery(since)));
    _checkOk(resp);
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    return (body['events'] as List)
        .map((e) => DeviceEvent.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<bool> getPredictionPaused() async {
    final resp = await _http.get(_uri('/prediction_state'));
    _checkOk(resp);
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    return body['paused'] as bool;
  }

  Future<void> setPredictionPaused(bool paused) async {
    final resp = await _http.post(
      _uri('/prediction_state'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'paused': paused}),
    );
    _checkOk(resp);
  }

  Future<DetectionSettings> getDetectionSettings() async {
    final resp = await _http.get(_uri('/detection_settings'));
    _checkOk(resp);
    return DetectionSettings.fromJson(
        jsonDecode(resp.body) as Map<String, dynamic>);
  }

  /// Any subset of the three fields -- omit a parameter to leave that
  /// value unchanged on the Pi rather than resetting it. Throws
  /// DetectionSettingsException (distinct from SyncApiException) on a
  /// 400, since that's a validation message meant to reach the user
  /// ("threshold must be 0-1"), not a connectivity failure.
  Future<DetectionSettings> updateDetectionSettings({
    double? stage1ConfidenceThreshold,
    int? sessionStartMinWindows,
    int? sessionEndMissedWindows,
  }) async {
    final resp = await _http.post(
      _uri('/detection_settings'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        if (stage1ConfidenceThreshold != null)
          'stage1_confidence_threshold': stage1ConfidenceThreshold,
        if (sessionStartMinWindows != null)
          'session_start_min_windows': sessionStartMinWindows,
        if (sessionEndMissedWindows != null)
          'session_end_missed_windows': sessionEndMissedWindows,
      }),
    );
    return _decodeDetectionSettingsResponse(resp);
  }

  Future<DetectionSettings> resetDetectionSettings() async {
    final resp = await _http.post(
      _uri('/detection_settings'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'reset': true}),
    );
    return _decodeDetectionSettingsResponse(resp);
  }

  DetectionSettings _decodeDetectionSettingsResponse(http.Response resp) {
    if (resp.statusCode == 400) {
      final body = jsonDecode(resp.body) as Map<String, dynamic>;
      throw DetectionSettingsException(body['error'] as String? ?? 'Invalid settings');
    }
    _checkOk(resp);
    return DetectionSettings.fromJson(
        jsonDecode(resp.body) as Map<String, dynamic>);
  }

  /// Irreversible on the Pi side. The Pi does zero confirmation of its
  /// own — see PI_CONTRACT.md: "THE APP OWNS ALL CONFIRM/WARNING UX."
  /// Callers must obtain explicit user confirmation before calling this.
  Future<Map<String, int>> resetAllData() async {
    final resp = await _http.post(
      _uri('/reset'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'confirm': 'RESET'}),
    );
    _checkOk(resp);
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    final deleted = body['deleted'] as Map<String, dynamic>;
    return deleted.map((k, v) => MapEntry(k, v as int));
  }

  Map<String, String>? _sinceQuery(DateTime? since) {
    if (since == null) return null;
    return {'since': since.toUtc().toIso8601String()};
  }

  void _checkOk(http.Response resp) {
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw SyncApiException(resp.statusCode, resp.body);
    }
  }
}

class SyncApiException implements Exception {
  final int statusCode;
  final String body;
  SyncApiException(this.statusCode, this.body);

  @override
  String toString() => 'SyncApiException($statusCode): $body';
}

class DetectionSettingsException implements Exception {
  final String message;
  DetectionSettingsException(this.message);

  @override
  String toString() => 'DetectionSettingsException: $message';
}
