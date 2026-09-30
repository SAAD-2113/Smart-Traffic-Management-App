import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../models/json.dart';

class QueuedPacket {
  QueuedPacket({required this.id, required this.sessionId, required this.seq, required this.recordedAt, required this.payload});
  final int id;
  final String sessionId;
  final int seq;
  final DateTime recordedAt;
  final Json payload;
}

/// Every GPS packet is written here first and removed only after the server answered for it,
/// so nothing is lost while the phone is offline (see "Offline data policy" in the docs).
abstract class TelemetryQueue {
  Future<void> add(String sessionId, int seq, DateTime recordedAt, Json payload);
  Future<List<QueuedPacket>> oldest(String sessionId, int limit);
  Future<void> remove(Iterable<int> ids);
  Future<int> count();
  Future<int> dropOlderThan(DateTime cutoff);
  Future<int> dropOtherSessions(String keepSessionId);
  Future<int> trimTo(int maxPackets);
}

class SqliteTelemetryQueue implements TelemetryQueue {
  SqliteTelemetryQueue._(this._db);
  final Database _db;

  static Future<SqliteTelemetryQueue> open() async {
    final db = await openDatabase(
      p.join(await getDatabasesPath(), 'telemetry_queue.db'),
      version: 1,
      onCreate: (db, _) async {
        await db.execute('''CREATE TABLE packets (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          session_id TEXT NOT NULL,
          seq INTEGER NOT NULL,
          recorded_at INTEGER NOT NULL,
          payload TEXT NOT NULL)''');
        await db.execute('CREATE INDEX ix_packets_session ON packets(session_id, id)');
      },
    );
    return SqliteTelemetryQueue._(db);
  }

  @override
  Future<void> add(String sessionId, int seq, DateTime recordedAt, Json payload) => _db.insert('packets', {
        'session_id': sessionId,
        'seq': seq,
        'recorded_at': recordedAt.millisecondsSinceEpoch,
        'payload': jsonEncode(payload),
      });

  @override
  Future<List<QueuedPacket>> oldest(String sessionId, int limit) async {
    final rows = await _db.query('packets', where: 'session_id = ?', whereArgs: [sessionId], orderBy: 'id', limit: limit);
    return rows
        .map((r) => QueuedPacket(
              id: r['id'] as int,
              sessionId: r['session_id'] as String,
              seq: r['seq'] as int,
              recordedAt: DateTime.fromMillisecondsSinceEpoch(r['recorded_at'] as int, isUtc: true),
              payload: jsonDecode(r['payload'] as String) as Json,
            ))
        .toList();
  }

  @override
  Future<void> remove(Iterable<int> ids) async {
    final list = ids.toList();
    if (list.isEmpty) return;
    await _db.delete('packets', where: 'id IN (${List.filled(list.length, '?').join(',')})', whereArgs: list);
  }

  @override
  Future<int> count() async => Sqflite.firstIntValue(await _db.rawQuery('SELECT COUNT(*) FROM packets')) ?? 0;

  @override
  Future<int> dropOlderThan(DateTime cutoff) =>
      _db.delete('packets', where: 'recorded_at < ?', whereArgs: [cutoff.millisecondsSinceEpoch]);

  @override
  Future<int> dropOtherSessions(String keepSessionId) =>
      _db.delete('packets', where: 'session_id != ?', whereArgs: [keepSessionId]);

  @override
  Future<int> trimTo(int maxPackets) async {
    final total = await count();
    if (total <= maxPackets) return 0;
    return _db.rawDelete(
        'DELETE FROM packets WHERE id IN (SELECT id FROM packets ORDER BY id LIMIT ?)', [total - maxPackets]);
  }
}

/// Used in tests and on platforms without SQLite.
class MemoryTelemetryQueue implements TelemetryQueue {
  final _items = <QueuedPacket>[];
  var _nextId = 1;

  @override
  Future<void> add(String sessionId, int seq, DateTime recordedAt, Json payload) async => _items.add(
      QueuedPacket(id: _nextId++, sessionId: sessionId, seq: seq, recordedAt: recordedAt, payload: payload));

  @override
  Future<List<QueuedPacket>> oldest(String sessionId, int limit) async =>
      _items.where((q) => q.sessionId == sessionId).take(limit).toList();

  @override
  Future<void> remove(Iterable<int> ids) async {
    final set = ids.toSet();
    _items.removeWhere((q) => set.contains(q.id));
  }

  @override
  Future<int> count() async => _items.length;

  @override
  Future<int> dropOlderThan(DateTime cutoff) async {
    final before = _items.length;
    _items.removeWhere((q) => q.recordedAt.isBefore(cutoff));
    return before - _items.length;
  }

  @override
  Future<int> dropOtherSessions(String keepSessionId) async {
    final before = _items.length;
    _items.removeWhere((q) => q.sessionId != keepSessionId);
    return before - _items.length;
  }

  @override
  Future<int> trimTo(int maxPackets) async {
    final extra = _items.length - maxPackets;
    if (extra <= 0) return 0;
    _items.removeRange(0, extra);
    return extra;
  }
}
