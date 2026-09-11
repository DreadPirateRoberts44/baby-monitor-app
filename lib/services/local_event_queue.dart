import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

import '../models/care_event.dart';

/// Local-first queue for feed/change events logged from the app.
///
/// Every tap on "Log feed"/"Log change" writes here immediately -- this
/// works with no network at all, matching PI_CONTRACT.md's "log a
/// feed/change event while away from the house entirely" case. A
/// separate sync pass (see SyncCoordinator) later pushes unsynced rows
/// to the Pi's POST /care_events and marks them synced.
///
/// This is deliberately a dumb append-only local mirror, not a general
/// offline cache of the Pi's data -- cry_history/device_events stay
/// read-only and fetched live (see PI_CONTRACT.md: the app never
/// originates that data), so there's nothing to queue for those.
class LocalEventQueue {
  static Database? _db;

  Future<Database> get _database async {
    _db ??= await _open();
    return _db!;
  }

  Future<Database> _open() async {
    final path = join(await getDatabasesPath(), 'local_care_events.db');
    return openDatabase(
      path,
      version: 1,
      onCreate: (db, version) {
        return db.execute('''
          CREATE TABLE pending_care_events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            event_type TEXT NOT NULL,
            timestamp TEXT NOT NULL,
            device_id TEXT,
            note TEXT,
            synced INTEGER NOT NULL DEFAULT 0
          )
        ''');
      },
    );
  }

  /// Records a new event immediately, unsynced. Returns the local row id.
  Future<int> enqueue({
    required String eventType,
    required DateTime timestamp,
    String? deviceId,
    String? note,
  }) async {
    final db = await _database;
    return db.insert('pending_care_events', {
      'event_type': eventType,
      'timestamp': timestamp.toUtc().toIso8601String(),
      'device_id': deviceId,
      'note': note,
      'synced': 0,
    });
  }

  /// All locally-queued events, most recent first -- used to merge with
  /// the Pi's own history in the UI (see CareEventsScreen).
  Future<List<CareEvent>> getAll() async {
    final db = await _database;
    final rows = await db.query(
      'pending_care_events',
      orderBy: 'timestamp DESC',
    );
    return rows.map(CareEvent.fromLocalRow).toList();
  }

  Future<List<CareEvent>> getUnsynced() async {
    final db = await _database;
    final rows = await db.query(
      'pending_care_events',
      where: 'synced = 0',
      orderBy: 'timestamp ASC',
    );
    return rows.map(CareEvent.fromLocalRow).toList();
  }

  Future<void> markSynced(int localId) async {
    final db = await _database;
    await db.update(
      'pending_care_events',
      {'synced': 1},
      where: 'id = ?',
      whereArgs: [localId],
    );
  }

  /// Local-only delete (e.g. a not-yet-synced event the caregiver wants
  /// to undo before it ever reaches the Pi). Does not touch the Pi --
  /// use SyncApiClient.deleteCareEvent for an already-synced event.
  Future<void> deleteLocal(int localId) async {
    final db = await _database;
    await db.delete(
      'pending_care_events',
      where: 'id = ?',
      whereArgs: [localId],
    );
  }

  /// Clears all locally-synced rows -- called after a successful sync
  /// pass so the local table doesn't grow unbounded once the Pi is the
  /// durable copy. Unsynced rows are left alone.
  Future<void> pruneSynced() async {
    final db = await _database;
    await db.delete('pending_care_events', where: 'synced = 1');
  }
}
