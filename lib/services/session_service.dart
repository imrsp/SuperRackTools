import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import '../models/rack.dart';

class SessionException implements Exception {
  const SessionException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Safe `.sprk` reader/writer. A copied database is edited, checked, then
/// atomically renamed over the selected destination so the source is preserved.
class SessionService {
  const SessionService({Directory Function()? temporaryDirectoryProvider})
    : _temporaryDirectoryProvider = temporaryDirectoryProvider;

  final Directory Function()? _temporaryDirectoryProvider;

  Directory get _temporaryDirectory =>
      _temporaryDirectoryProvider?.call() ?? Directory.systemTemp;

  Future<String> copyToTemporary(
    String source, {
    String prefix = 'superrack-db-',
  }) async {
    _rejectAuxiliary(source, const ['-wal', '-shm', '-journal']);
    final root = _temporaryDirectory;
    await root.create(recursive: true);
    final temp = await root.createTemp(prefix);
    final copy = p.join(temp.path, p.basename(source));
    try {
      await File(source).copy(copy);
      _rejectAuxiliary(source, const ['-wal', '-shm', '-journal']);
      return copy;
    } catch (_) {
      await temp.delete(recursive: true);
      rethrow;
    }
  }

  Future<Database> openDatabaseCopy(
    String source, {
    bool readOnly = true,
  }) async {
    final copy = await copyToTemporary(source);
    try {
      final db = sqlite3.open(
        copy,
        mode: readOnly ? OpenMode.readOnly : OpenMode.readWrite,
      );
      _databaseCopies[db] = copy;
      return db;
    } catch (_) {
      await deleteTemporaryCopy(copy);
      rethrow;
    }
  }

  Future<void> closeDatabaseCopy(Database db) async {
    db.close();
    final copy = _databaseCopies.remove(db);
    if (copy != null) await deleteTemporaryCopy(copy);
  }

  static final Map<Database, String> _databaseCopies = {};

  Future<void> deleteTemporaryCopy(String copyPath) async {
    final copy = File(copyPath);
    if (await copy.exists()) await copy.delete();
    for (final suffix in ['-wal', '-shm', '-journal']) {
      final auxiliary = File('$copyPath$suffix');
      if (await auxiliary.exists()) await auxiliary.delete();
    }
    final parent = copy.parent;
    if (await parent.exists() && await parent.list().isEmpty) {
      await parent.delete();
    }
  }

  Future<List<Rack>> readRacks(String path) async {
    _rejectAuxiliary(path, const ['-wal', '-shm', '-journal']);
    final root = _temporaryDirectory;
    await root.create(recursive: true);
    final temp = await root.createTemp('superrack-read-');
    final copy = p.join(temp.path, 'read.sprk');
    try {
      await File(path).copy(copy);
      _rejectAuxiliary(path, const ['-wal', '-shm', '-journal']);
      final db = sqlite3.open(copy, mode: OpenMode.readOnly);
      try {
        _validateSchema(db);
        final rows = db.select('''
          SELECT o.id AS id, o.obj_index + 1 AS number, sc.name AS name
          FROM object o JOIN cluster_type ct ON ct.id=o.obj_type
          JOIN snapshot_chainer sc ON sc.chainer_id=o.id
          JOIN snapshot s ON s.id=sc.snapshot_id
          WHERE ct.name='Input' AND s.number=-1 ORDER BY o.obj_index
        ''');
        if (rows.isEmpty) {
          throw const SessionException('文件中没有 Active Snapshot Rack。');
        }
        return rows.map((row) => Rack.fromRow(row)).toList(growable: false);
      } finally {
        db.close();
      }
    } on SqliteException catch (e) {
      throw SessionException('无法读取 SuperRack 会话：${e.message}');
    } finally {
      await temp.delete(recursive: true);
    }
  }

  Future<void> writeRenamed({
    required String source,
    required String destination,
    required List<String> rawNames,
    required bool allSnapshots,
  }) async {
    final src = File(source).absolute.path;
    final dst = File(destination).absolute.path;
    final normalizedSource = p.normalize(src);
    final normalizedDestination = p.normalize(dst);
    final samePath = Platform.isWindows
        ? normalizedSource.toLowerCase() == normalizedDestination.toLowerCase()
        : normalizedSource == normalizedDestination;
    if (samePath) {
      throw const SessionException('请另存为不同文件名，原件不会被覆盖。');
    }
    _rejectAuxiliary(src, const ['-wal', '-journal']);
    _rejectAuxiliary(dst, const ['-wal', '-shm', '-journal']);
    if (await File(dst).exists()) {
      throw const SessionException('目标文件已存在，请选择新的文件名以免覆盖已有会话。');
    }
    final racks = await readRacks(src);
    if (rawNames.length != racks.length) {
      throw SessionException(
        '需要 ${racks.length} 个通道名，当前为 ${rawNames.length} 个。',
      );
    }
    final names = rawNames.map((e) => e.trim()).toList();
    final emptyIndex = names.indexWhere((e) => e.isEmpty);
    if (emptyIndex >= 0) {
      throw SessionException('第 ${emptyIndex + 1} 个通道名为空。');
    }

    final directory = Directory(p.dirname(dst));
    await directory.create(recursive: true);
    final temp = File(
      p.join(
        directory.path,
        '.SuperRackWrite-${DateTime.now().microsecondsSinceEpoch}.sprk',
      ),
    );
    try {
      await File(src).copy(temp.path);
      _rejectAuxiliary(src, const ['-wal', '-journal']);
      final db = sqlite3.open(temp.path);
      try {
        db.execute('PRAGMA journal_mode=DELETE');
        db.execute('PRAGMA foreign_keys=ON');
        db.execute('BEGIN IMMEDIATE');
        try {
          for (var i = 0; i < racks.length; i++) {
            if (allSnapshots) {
              db.execute(
                'UPDATE snapshot_chainer SET name=? WHERE chainer_id=?',
                [names[i], racks[i].id],
              );
            } else {
              db.execute(
                '''UPDATE snapshot_chainer SET name=? WHERE chainer_id=?
                AND snapshot_id=(SELECT id FROM snapshot WHERE number=-1)''',
                [names[i], racks[i].id],
              );
            }
            if (db.updatedRows == 0) {
              throw const SessionException('写入后复核失败。');
            }
          }
          db.execute('COMMIT');
        } catch (_) {
          db.execute('ROLLBACK');
          rethrow;
        }
        final integrity = db
            .select('PRAGMA integrity_check')
            .first
            .values
            .first;
        if (integrity != 'ok') {
          throw SessionException('SQLite 完整性检查失败：$integrity');
        }
        final check = db.select(
          '''SELECT sc.name AS name FROM object o
          JOIN cluster_type ct ON ct.id=o.obj_type JOIN snapshot_chainer sc ON sc.chainer_id=o.id
          JOIN snapshot s ON s.id=sc.snapshot_id WHERE ct.name='Input' AND s.number=-1 ORDER BY o.obj_index''',
        );
        if (check.map((r) => r['name']).join('\u0000') !=
            names.join('\u0000')) {
          throw const SessionException('保存后名称复核失败。');
        }
      } finally {
        db.close();
      }
      // Refuse to overwrite existing destinations; rename stays atomic within the same directory.
      await temp.rename(dst);
    } on SqliteException catch (e) {
      throw SessionException('SQLite 操作失败：${e.message}');
    } finally {
      if (await temp.exists()) await temp.delete();
    }
  }

  void _validateSchema(Database db) {
    final tables = db
        .select("SELECT name FROM sqlite_schema WHERE type='table'")
        .map((row) => row['name'] as String)
        .toSet();
    if (!tables.containsAll({
      'object',
      'cluster_type',
      'snapshot',
      'snapshot_chainer',
    })) {
      throw const SessionException('文件不是受支持的 SuperRack 会话格式。');
    }
  }

  void _rejectAuxiliary(String path, List<String> suffixes) {
    for (final suffix in suffixes) {
      if (File('$path$suffix').existsSync()) {
        throw SessionException(
          '检测到活动数据库辅助文件 ${p.basename(path)}$suffix，请完全退出 SuperRack 后重试。',
        );
      }
    }
  }
}
