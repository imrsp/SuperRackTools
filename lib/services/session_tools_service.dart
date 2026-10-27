import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:xml/xml.dart';

import '../models/session_tools.dart';
import '../models/rack.dart';
import 'session_service.dart';
import 'safe_file_publisher.dart';

class SessionToolsService {
  const SessionToolsService({Directory Function()? temporaryDirectoryProvider})
    : _temporaryDirectoryProvider = temporaryDirectoryProvider;

  final Directory Function()? _temporaryDirectoryProvider;

  Directory get _temporaryDirectory =>
      _temporaryDirectoryProvider?.call() ?? Directory.systemTemp;

  Future<List<SessionSnapshot>> readSnapshots(String path) async {
    final db = await _openReadCopy(path, 'snapshots');
    try {
      return db
          .select('''
            SELECT s.id, s.number, COALESCE(s.name, '') AS name,
              (SELECT count(*) FROM snapshot_chainer sc
               JOIN object o ON o.id=sc.chainer_id
               JOIN cluster_type ct ON ct.id=o.obj_type
               WHERE sc.snapshot_id=s.id AND ct.name='Input') AS rack_count
            FROM snapshot s ORDER BY s.number
          ''')
          .map(
            (r) => SessionSnapshot(
              id: r['id']! as int,
              number: r['number']! as int,
              name: r['name']! as String,
              rackCount: r['rack_count']! as int,
            ),
          )
          .toList(growable: false);
    } finally {
      db.close();
      await _closeReadCopy(db);
    }
  }

  Future<List<Rack>> readSnapshotRacks(String path, int snapshotId) async {
    final db = await _openReadCopy(path, 'snapshot-racks');
    try {
      return db
          .select(
            '''SELECT o.id AS id,o.obj_index+1 AS number,sc.name AS name
            FROM object o JOIN cluster_type ct ON ct.id=o.obj_type
            JOIN snapshot_chainer sc ON sc.chainer_id=o.id
            WHERE ct.name='Input' AND sc.snapshot_id=? ORDER BY o.obj_index''',
            [snapshotId],
          )
          .map((row) => Rack.fromRow(row))
          .toList(growable: false);
    } finally {
      db.close();
      await _closeReadCopy(db);
    }
  }

  Future<List<UserPreset>> readUserPresets(String path) async {
    final db = await _openReadCopy(path, 'presets');
    try {
      _requireTable(db, 'user_presets');
      return db
          .select('SELECT id,name FROM user_presets ORDER BY id')
          .map(
            (r) => UserPreset(id: r['id']! as int, name: r['name']! as String),
          )
          .toList(growable: false);
    } finally {
      db.close();
      await _closeReadCopy(db);
    }
  }

  Future<String> readPresetXml(String path, int presetId) async {
    final db = await _openReadCopy(path, 'preset-xml');
    try {
      final rows = db.select('SELECT preset FROM user_presets WHERE id=?', [
        presetId,
      ]);
      if (rows.isEmpty) throw const SessionException('预设已不存在。');
      return rows.single['preset']! as String;
    } finally {
      db.close();
      await _closeReadCopy(db);
    }
  }

  Future<List<MatrixRack>> readMatrix(String path, int snapshotId) async {
    final db = await _openReadCopy(path, 'matrix');
    try {
      _requireTable(db, 'plug');
      final racks = db.select(
        '''SELECT o.id, o.obj_index+1 AS number, sc.name,
          o.recall_safe,
          COALESCE((SELECT p.param_value FROM snapshot_chainer_params p
            WHERE p.chainer_id=o.id AND p.snapshot_id=? AND p.param_id=105),
            (SELECT d.param_value FROM chainer_params_default_values d
            WHERE d.obj_type=o.obj_type AND d.param_id=105), 1.0) AS rack_on
          FROM object o JOIN cluster_type ct ON ct.id=o.obj_type
          JOIN snapshot_chainer sc ON sc.chainer_id=o.id AND sc.snapshot_id=?
          WHERE ct.name='Input' ORDER BY o.obj_index''',
        [snapshotId, snapshotId],
      );
      final plugins = db.select(
        '''SELECT pl.id,pl.chainer_id,pl.slot,pl.plugin_name,pl.recall_safe,
          COALESCE(MAX(sp.bypass),0) AS bypass
          FROM plug pl LEFT JOIN snapshot_plugin sp
            ON sp.plug_id=pl.id AND sp.snapshot_id=?
          GROUP BY pl.id ORDER BY pl.chainer_id,pl.slot''',
        [snapshotId],
      );
      final byRack = <int, List<MatrixPlugin>>{};
      for (final row in plugins) {
        byRack
            .putIfAbsent(row['chainer_id']! as int, () => [])
            .add(
              MatrixPlugin(
                id: row['id']! as int,
                slot: row['slot']! as int,
                name: row['plugin_name']! as String,
                bypass: (row['bypass']! as num) != 0,
                recallSafe: (row['recall_safe']! as num) != 0,
              ),
            );
      }
      return racks
          .map(
            (row) => MatrixRack(
              id: row['id']! as int,
              number: row['number']! as int,
              name: row['name']! as String,
              isOn: (row['rack_on']! as num) != 0,
              recallSafe: (row['recall_safe']! as num) != 0,
              plugins: byRack[row['id']! as int] ?? const [],
            ),
          )
          .toList(growable: false);
    } finally {
      db.close();
      await _closeReadCopy(db);
    }
  }

  Future<void> updateSnapshotNames({
    required String source,
    required String destination,
    required int snapshotId,
    required Map<int, String> names,
  }) async {
    if (names.isEmpty) throw const SessionException('没有选择要修改的通道。');
    await _editCopy(source, destination, (db) {
      db.execute('BEGIN IMMEDIATE');
      try {
        for (final entry in names.entries) {
          final name = entry.value.trim();
          if (name.isEmpty) throw const SessionException('通道名不能为空。');
          db.execute(
            'UPDATE snapshot_chainer SET name=? WHERE chainer_id=? AND snapshot_id=?',
            [name, entry.key, snapshotId],
          );
          if (db.updatedRows != 1) {
            throw const SessionException('指定 Snapshot 中找不到选中的 Rack。');
          }
        }
        db.execute('COMMIT');
      } catch (_) {
        db.execute('ROLLBACK');
        rethrow;
      }
    });
  }

  Future<void> updateMatrix({
    required String source,
    required String destination,
    required int snapshotId,
    Map<int, bool> rackOn = const {},
    Map<int, bool> rackRecallSafe = const {},
    Map<int, bool> pluginBypass = const {},
    Map<int, bool> pluginRecallSafe = const {},
  }) async {
    await _editCopy(source, destination, (db) {
      db.execute('BEGIN IMMEDIATE');
      try {
        for (final entry in rackOn.entries) {
          final rackId = entry.key;
          if (entry.value) {
            db.execute(
              'DELETE FROM snapshot_chainer_params WHERE chainer_id=? AND snapshot_id=? AND param_id=105',
              [rackId, snapshotId],
            );
          } else {
            db.execute(
              '''INSERT INTO snapshot_chainer_params(chainer_id,snapshot_id,param_id,param_value)
                 VALUES(?,?,105,0) ON CONFLICT(chainer_id,snapshot_id,param_id)
                 DO UPDATE SET param_value=excluded.param_value''',
              [rackId, snapshotId],
            );
          }
        }
        for (final entry in rackRecallSafe.entries) {
          db.execute('UPDATE object SET recall_safe=? WHERE id=?', [
            entry.value ? 1 : 0,
            entry.key,
          ]);
          if (db.updatedRows != 1) throw const SessionException('Rack 已不存在。');
        }
        for (final entry in pluginBypass.entries) {
          db.execute(
            'UPDATE snapshot_plugin SET bypass=? WHERE plug_id=? AND snapshot_id=?',
            [entry.value ? 1 : 0, entry.key, snapshotId],
          );
        }
        for (final entry in pluginRecallSafe.entries) {
          db.execute('UPDATE plug SET recall_safe=? WHERE id=?', [
            entry.value ? 1 : 0,
            entry.key,
          ]);
          if (db.updatedRows != 1) {
            throw const SessionException('插件槽位已不存在。');
          }
        }
        db.execute('COMMIT');
      } catch (_) {
        db.execute('ROLLBACK');
        rethrow;
      }
    });
  }

  Future<void> saveCombinedEdits({
    required String source,
    required String destination,
    required Map<int, Map<int, String>> namesBySnapshot,
    List<MatrixEditDraft> matrixDrafts = const [],
    PresetEditDraft? presets,
  }) async {
    await _editCopy(source, destination, (db) {
      db.execute('BEGIN IMMEDIATE');
      try {
        for (final snapshotEntry in namesBySnapshot.entries) {
          for (final entry in snapshotEntry.value.entries) {
            final name = entry.value.trim();
            if (name.isEmpty) throw const SessionException('通道名不能为空。');
            db.execute(
              'UPDATE snapshot_chainer SET name=? WHERE chainer_id=? AND snapshot_id=?',
              [name, entry.key, snapshotEntry.key],
            );
            if (db.updatedRows != 1) {
              throw const SessionException('指定 Snapshot 中找不到选中的 Rack。');
            }
          }
        }
        for (final matrix in matrixDrafts) {
          if (matrix.hasChanges) _applyMatrixDraft(db, matrix);
        }
        if (presets?.hasChanges ?? false) _applyPresetDraft(db, presets!);
        db.execute('COMMIT');
      } catch (_) {
        db.execute('ROLLBACK');
        rethrow;
      }
    });
  }

  Future<void> editPresets({
    required String source,
    required String destination,
    required List<UserPreset> orderedPresets,
    Map<int, String> renames = const {},
    Set<int> duplicateIds = const {},
    Set<int> deleteIds = const {},
  }) async {
    await _editCopy(source, destination, (db) {
      _requireTable(db, 'user_presets');
      db.execute('BEGIN IMMEDIATE');
      try {
        for (final id in deleteIds) {
          db.execute('DELETE FROM user_presets WHERE id=?', [id]);
        }
        for (final entry in renames.entries) {
          final name = entry.value.trim();
          _ensurePresetNameAvailable(db, name, exceptId: entry.key);
          final row = db.select('SELECT preset FROM user_presets WHERE id=?', [
            entry.key,
          ]);
          if (row.isEmpty) throw const SessionException('预设已不存在。');
          final updated = _renamePresetXml(
            row.first['preset']! as String,
            name,
          );
          db.execute('UPDATE user_presets SET name=?,preset=? WHERE id=?', [
            name,
            updated,
            entry.key,
          ]);
        }
        for (final id in duplicateIds) {
          if (deleteIds.contains(id)) continue;
          final row = db.select(
            'SELECT name,preset FROM user_presets WHERE id=?',
            [id],
          );
          if (row.isEmpty) continue;
          final originalName = row.first['name']! as String;
          var copyName = '$originalName Copy';
          var number = 2;
          while (_presetNameExists(db, copyName)) {
            copyName = '$originalName Copy $number';
            number++;
          }
          _insertPreset(db, copyName, row.first['preset']! as String);
        }
        final current = db.select('SELECT id FROM user_presets ORDER BY id');
        final remaining = current.map((r) => r['id']! as int).toList();
        final order = <int>[
          for (final preset in orderedPresets)
            if (remaining.contains(preset.id) && !deleteIds.contains(preset.id))
              preset.id,
          for (final id in remaining)
            if (!orderedPresets.any((preset) => preset.id == id)) id,
        ];
        if (order.isNotEmpty) _reorderPresetIds(db, order);
        db.execute('COMMIT');
      } catch (_) {
        db.execute('ROLLBACK');
        rethrow;
      }
    });
  }

  Future<int> importXps({
    required String sessionPath,
    required String xpsPath,
    required String destination,
    required Set<int> selectedIndexes,
  }) async {
    final document = XmlDocument.parse(await File(xpsPath).readAsString());
    final root = document.rootElement;
    if (root.name.local != 'PresetXMLTree') {
      throw const SessionException('这不是有效的 XPS 预设文件。');
    }
    final presets = root.findElements('Preset').toList();
    final indexes = selectedIndexes.toList()..sort();
    for (final index in indexes) {
      if (index < 0 || index >= presets.length) {
        throw const SessionException('预设选择已失效，请重新选择。');
      }
    }
    var imported = 0;
    await _editCopy(sessionPath, destination, (db) {
      _requireTable(db, 'user_presets');
      db.execute('BEGIN IMMEDIATE');
      try {
        for (final index in indexes) {
          final element = presets[index].copy();
          final originalName = element.getAttribute('Name')?.trim() ?? '';
          var name = originalName.isEmpty ? 'Imported Preset' : originalName;
          var suffix = 2;
          while (_presetNameExists(db, name)) {
            name = '$originalName ($suffix)';
            suffix++;
          }
          if (name != originalName) {
            element.setAttribute('Name', name);
            for (final data in element.findAllElements('PresetData')) {
              if (data.getAttribute('SetupName') != null) {
                data.setAttribute('SetupName', name);
              }
            }
          }
          final wrapper = XmlElement.tag(
            'PresetChunkXMLTree',
            attributes: [XmlAttribute(const XmlName.parts('version'), '3')],
            children: [element],
            isSelfClosing: false,
          );
          db.execute('INSERT INTO user_presets(name,preset) VALUES(?,?)', [
            name,
            XmlDocument([wrapper]).toXmlString(pretty: true),
          ]);
          imported++;
        }
        db.execute('COMMIT');
      } catch (_) {
        db.execute('ROLLBACK');
        rethrow;
      }
    });
    return imported;
  }

  Future<List<XpsPresetInfo>> readXpsPresetNames(String path) async {
    final document = XmlDocument.parse(await File(path).readAsString());
    if (document.rootElement.name.local != 'PresetXMLTree') {
      throw const SessionException('这不是有效的 XPS 预设文件。');
    }
    return document.rootElement
        .findElements('Preset')
        .toList()
        .indexed
        .map(
          (entry) => XpsPresetInfo(
            index: entry.$1,
            name: entry.$2.getAttribute('Name') ?? 'Preset ${entry.$1 + 1}',
          ),
        )
        .toList(growable: false);
  }

  Future<List<XpsPresetData>> readXpsPresetData(
    String path,
    Set<int> selectedIndexes,
  ) async {
    final document = XmlDocument.parse(await File(path).readAsString());
    if (document.rootElement.name.local != 'PresetXMLTree') {
      throw const SessionException('这不是有效的 XPS 预设文件。');
    }
    final presets = document.rootElement.findElements('Preset').toList();
    final indexes = selectedIndexes.toList()..sort();
    for (final index in indexes) {
      if (index < 0 || index >= presets.length) {
        throw const SessionException('预设选择已失效，请重新选择。');
      }
    }
    return [
      for (final index in indexes)
        XpsPresetData(
          index: index,
          name: presets[index].getAttribute('Name') ?? 'Preset ${index + 1}',
          xml: XmlDocument([presets[index].copy()]).toXmlString(pretty: true),
        ),
    ];
  }

  Future<void> exportXps({
    required String sessionPath,
    required String destination,
    required Set<int> selectedIds,
    PresetEditDraft? draft,
  }) async {
    if (selectedIds.isEmpty) throw const SessionException('没有选择预设。');
    final db = await _openReadCopy(sessionPath, 'export-presets');
    try {
      _requireTable(db, 'user_presets');
      final presets = <XmlElement>[];
      final rawById = <int, String>{
        for (final entry in db.select('SELECT id,preset FROM user_presets'))
          entry['id']! as int: entry['preset']! as String,
        if (draft != null) ...draft.importedXmlById,
      };
      final orderedIds = draft == null
          ? rawById.keys.where(selectedIds.contains)
          : draft.orderedPresets
                .map((preset) => preset.id)
                .where(selectedIds.contains);
      for (final id in orderedIds) {
        if (draft?.deleteIds.contains(id) ?? false) continue;
        final raw = rawById[id];
        if (raw == null) continue;
        final name = draft?.renames[id];
        final element = _presetElement(
          name == null ? raw : _renamePresetXml(raw, name),
        );
        presets.add(element.copy());
      }
      if (presets.length != selectedIds.length) {
        throw const SessionException('部分选中的预设已不存在。');
      }
      final root = XmlElement.tag(
        'PresetXMLTree',
        attributes: [XmlAttribute(const XmlName.parts('version'), '3')],
        children: presets,
        isSelfClosing: false,
      );
      final xml = XmlDocument([
        XmlDeclaration()..version = '1.0',
        root,
      ]).toXmlString(pretty: true);
      await File(destination).writeAsString('$xml\n');
    } finally {
      db.close();
      await _closeReadCopy(db);
    }
  }

  Future<void> createSession({
    required String templatePath,
    required String destination,
    required SessionBlueprint blueprint,
  }) async {
    if (blueprint.rackNames.isEmpty || blueprint.rackNames.length > 64) {
      throw const SessionException('通道数需要在 1 到 64 之间。');
    }
    if (await File(destination).exists()) {
      throw const SessionException('目标文件已存在，请选择新文件名。');
    }
    _rejectAuxiliary(templatePath);
    final stage = await _stageFile('new-session');
    try {
      await File(templatePath).copy(stage.path);
      final db = sqlite3.open(stage.path);
      try {
        _validateSchema(db);
        final appVersion = db
            .select(
              "SELECT value FROM file_properties WHERE name='Application Version'",
            )
            .first['value'];
        if (appVersion != '14.23.62.569 Build R 295380') {
          throw SessionException('模板版本不符合预期：$appVersion');
        }
        db.execute('PRAGMA foreign_keys=ON');
        db.execute('BEGIN IMMEDIATE');
        try {
          db.execute(
            'ALTER TABLE snapshot_plugin ADD COLUMN fw_scale_precentage INTEGER DEFAULT 100',
          );
          db.execute(
            'ALTER TABLE recall_safe_settings ADD COLUMN is_permanent_check_state INTEGER NOT NULL DEFAULT 0',
          );
          db.execute(
            'UPDATE info SET schema_version_major=4,schema_version_minor=3,schema_version_revision=0,schema_version_patch=5 WHERE id=0',
          );
          db.execute(
            "UPDATE file_properties SET value='14.30.283.991 Build R 312874' WHERE name='Application Version'",
          );
          db.execute('UPDATE mixer_settings SET mixer_channel_count=64');
          for (var i = 0; i < blueprint.rackNames.length; i++) {
            final name = blueprint.rackNames[i].trim().isEmpty
                ? 'Rack ${i + 1}'
                : blueprint.rackNames[i].trim();
            db.execute(
              "UPDATE snapshot_chainer SET name=? WHERE snapshot_id=-1 AND chainer_id=(SELECT id FROM object WHERE obj_type=(SELECT id FROM cluster_type WHERE name='Input') AND obj_index=?)",
              [name, i],
            );
          }
          var nextSnapshotId =
              (db.select('SELECT max(id) AS id FROM snapshot').first['id']!
                  as int) +
              1;
          var nextNumber = 0;
          final requested = blueprint.snapshotNames
              .map((e) => e.trim())
              .where((e) => e.isNotEmpty && e.toLowerCase() != 'active')
              .toSet();
          for (final snapshotName in requested) {
            final currentRows = db.select(
              "SELECT id FROM snapshot WHERE name=? COLLATE NOCASE",
              [snapshotName],
            );
            if (currentRows.isNotEmpty) continue;
            final snapshotId = nextSnapshotId++;
            while (db.select('SELECT 1 FROM snapshot WHERE number=?', [
              nextNumber,
            ]).isNotEmpty) {
              nextNumber++;
            }
            db.execute(
              'INSERT INTO snapshot(id,ext_id,number,name,note,info,tempo,sync_tempo) VALUES(?,NULL,?,?,\'\',\'\',120,0)',
              [snapshotId, nextNumber, snapshotName],
            );
            _copySnapshotRows(db, fromSnapshot: -1, toSnapshot: snapshotId);
            _verifySnapshotRows(db, fromSnapshot: -1, toSnapshot: snapshotId);
            final names = _namesForSnapshot(blueprint, snapshotName);
            if (names != null) _writeRackNames(db, snapshotId, names);
            nextNumber++;
          }
          final activeNames = _namesForSnapshot(blueprint, 'Active');
          if (activeNames != null) _writeRackNames(db, -1, activeNames);
          db.execute('COMMIT');
        } catch (_) {
          db.execute('ROLLBACK');
          rethrow;
        }
        _verifyDb(db);
        final version = db
            .select(
              'SELECT schema_version_major,schema_version_minor,schema_version_revision,schema_version_patch FROM info WHERE id=0',
            )
            .first
            .values
            .join('.');
        if (version != '4.3.0.5') throw const SessionException('新工程结构版本复核失败。');
        final count = db
            .select('SELECT mixer_channel_count FROM mixer_settings')
            .first['mixer_channel_count'];
        if (count != 64) throw const SessionException('64 Rack 设置复核失败。');
      } finally {
        db.close();
      }
      await _publishStage(stage, destination);
    } finally {
      await _deleteStage(stage);
    }
  }

  Future<void> _editCopy(
    String source,
    String destination,
    void Function(Database db) edit,
  ) async {
    if (p.equals(
      p.normalize(p.absolute(source)),
      p.normalize(p.absolute(destination)),
    )) {
      throw const SessionException('请另存为不同文件名。');
    }
    if (await File(destination).exists()) {
      throw const SessionException('目标文件已存在，请选择新文件名。');
    }
    _rejectAuxiliary(source);
    final stage = await _stageFile('edit-session');
    try {
      await File(source).copy(stage.path);
      final db = sqlite3.open(stage.path);
      try {
        db.execute('PRAGMA foreign_keys=ON');
        db.execute('PRAGMA journal_mode=DELETE');
        edit(db);
        _verifyDb(db);
      } finally {
        db.close();
      }
      await _publishStage(stage, destination);
    } on SqliteException catch (e) {
      throw SessionException('SQLite 操作失败：${e.message}');
    } finally {
      await _deleteStage(stage);
    }
  }

  Future<Database> _openReadCopy(String source, String prefix) async {
    _rejectAuxiliary(source);
    final stage = await _stageFile(prefix);
    try {
      await File(source).copy(stage.path);
      _rejectAuxiliary(source);
      final db = sqlite3.open(stage.path, mode: OpenMode.readOnly);
      _readCopies[db] = stage;
      return db;
    } catch (_) {
      await _deleteStage(stage);
      rethrow;
    }
  }

  static final Map<Database, File> _readCopies = {};

  Future<void> _closeReadCopy(Database db) async {
    final file = _readCopies.remove(db);
    if (file != null) await _deleteStage(file);
  }

  Future<void> _deleteStage(File file) async {
    if (await file.exists()) await file.delete();
    for (final suffix in ['-wal', '-shm', '-journal']) {
      final auxiliary = File('${file.path}$suffix');
      if (await auxiliary.exists()) await auxiliary.delete();
    }
    final parent = file.parent;
    if (await parent.exists() && await parent.list().isEmpty) {
      await parent.delete();
    }
  }

  Future<File> _stageFile(String prefix) async {
    final tempDir = _temporaryDirectory;
    await tempDir.create(recursive: true);
    final dir = await tempDir.createTemp('superrack-$prefix-');
    return File(p.join(dir.path, 'session.sprk'));
  }

  Future<void> _publishStage(File stage, String destination) async {
    final target = File(destination);
    await target.parent.create(recursive: true);
    final db = sqlite3.open(stage.path, mode: OpenMode.readOnly);
    try {
      _verifyDb(db);
    } finally {
      db.close();
    }
    final sibling = File(
      p.join(
        target.parent.path,
        '.${p.basename(target.path)}.${DateTime.now().microsecondsSinceEpoch}.tmp',
      ),
    );
    try {
      if (await target.exists()) {
        throw const SessionException('目标文件已存在，请选择新文件名。');
      }
      await stage.copy(sibling.path);
      await SafeFilePublisher.publishNoReplace(sibling, target);
    } finally {
      if (await sibling.exists()) await sibling.delete();
    }
  }

  void _applyMatrixDraft(Database db, MatrixEditDraft draft) {
    for (final entry in draft.rackOn.entries) {
      if (entry.value) {
        db.execute(
          'DELETE FROM snapshot_chainer_params WHERE chainer_id=? AND snapshot_id=? AND param_id=105',
          [entry.key, draft.snapshotId],
        );
      } else {
        db.execute(
          '''INSERT INTO snapshot_chainer_params(chainer_id,snapshot_id,param_id,param_value)
             VALUES(?,?,105,0) ON CONFLICT(chainer_id,snapshot_id,param_id)
             DO UPDATE SET param_value=excluded.param_value''',
          [entry.key, draft.snapshotId],
        );
      }
    }
    for (final entry in draft.rackRecallSafe.entries) {
      db.execute('UPDATE object SET recall_safe=? WHERE id=?', [
        entry.value ? 1 : 0,
        entry.key,
      ]);
      if (db.updatedRows != 1) throw const SessionException('Rack 已不存在。');
    }
    for (final entry in draft.pluginBypass.entries) {
      db.execute(
        'UPDATE snapshot_plugin SET bypass=? WHERE plug_id=? AND snapshot_id=?',
        [entry.value ? 1 : 0, entry.key, draft.snapshotId],
      );
    }
    for (final entry in draft.pluginRecallSafe.entries) {
      db.execute('UPDATE plug SET recall_safe=? WHERE id=?', [
        entry.value ? 1 : 0,
        entry.key,
      ]);
      if (db.updatedRows != 1) {
        throw const SessionException('插件槽位已不存在。');
      }
    }
  }

  void _applyPresetDraft(Database db, PresetEditDraft draft) {
    _requireTable(db, 'user_presets');
    for (final id in draft.deleteIds.where((id) => id > 0)) {
      db.execute('DELETE FROM user_presets WHERE id=?', [id]);
    }
    for (final entry in draft.renames.entries.where((entry) => entry.key > 0)) {
      if (draft.deleteIds.contains(entry.key)) continue;
      final name = entry.value.trim();
      _ensurePresetNameAvailable(db, name, exceptId: entry.key);
      final row = db.select('SELECT preset FROM user_presets WHERE id=?', [
        entry.key,
      ]);
      if (row.isEmpty) throw const SessionException('预设已不存在。');
      db.execute('UPDATE user_presets SET name=?,preset=? WHERE id=?', [
        name,
        _renamePresetXml(row.first['preset']! as String, name),
        entry.key,
      ]);
    }

    for (final id in draft.duplicateIds.where((id) => id > 0)) {
      if (draft.deleteIds.contains(id)) continue;
      final row = db.select('SELECT name,preset FROM user_presets WHERE id=?', [
        id,
      ]);
      if (row.isEmpty) continue;
      final originalName = row.first['name']! as String;
      final name = _uniquePresetName(db, '$originalName Copy');
      _insertPreset(
        db,
        name,
        _renamePresetXml(row.first['preset']! as String, name),
      );
    }

    final importedIds = <int, int>{};
    final importedDuplicateIds = <int, int>{};
    for (final entry in draft.importedXmlById.entries) {
      final draftId = entry.key;
      if (draft.deleteIds.contains(draftId)) continue;
      final baseName =
          (draft.renames[draftId] ??
                  _presetElement(entry.value).getAttribute('Name') ??
                  'Imported Preset')
              .trim();
      final name = _uniquePresetName(
        db,
        baseName.isEmpty ? 'Imported Preset' : baseName,
      );
      _insertPreset(db, name, _renamePresetXml(entry.value, name));
      importedIds[draftId] = db.lastInsertRowId;
      if (draft.duplicateIds.contains(draftId)) {
        final duplicateName = _uniquePresetName(db, '$name Copy');
        _insertPreset(
          db,
          duplicateName,
          _renamePresetXml(entry.value, duplicateName),
        );
        importedDuplicateIds[draftId] = db.lastInsertRowId;
      }
    }

    final currentIds = db
        .select('SELECT id FROM user_presets ORDER BY id')
        .map((row) => row['id']! as int)
        .toList();
    final order = <int>[];
    for (final preset in draft.orderedPresets) {
      if (draft.deleteIds.contains(preset.id)) continue;
      final resolved = preset.id > 0 ? preset.id : importedIds[preset.id];
      if (resolved != null && currentIds.contains(resolved)) {
        order.add(resolved);
      }
      final duplicate = importedDuplicateIds[preset.id];
      if (duplicate != null && currentIds.contains(duplicate)) {
        order.add(duplicate);
      }
    }
    for (final id in currentIds) {
      if (!order.contains(id)) order.add(id);
    }
    if (order.isNotEmpty) _reorderPresetIds(db, order);
  }

  String _uniquePresetName(Database db, String desired) {
    var name = desired;
    var suffix = 2;
    while (_presetNameExists(db, name)) {
      name = '$desired ($suffix)';
      suffix++;
    }
    return name;
  }

  void _insertPreset(Database db, String name, String presetXml) {
    db.execute('INSERT INTO user_presets(name,preset) VALUES(?,?)', [
      name,
      _presetChunkXml(_renamePresetXml(presetXml, name)),
    ]);
  }

  void _verifyDb(Database db) {
    final integrity = db.select('PRAGMA integrity_check').first.values.first;
    if (integrity != 'ok') throw SessionException('SQLite 完整性检查失败：$integrity');
    final foreignKeys = db.select('PRAGMA foreign_key_check');
    if (foreignKeys.isNotEmpty) throw const SessionException('外键检查失败。');
  }

  void _requireTable(Database db, String name) {
    if (db.select("SELECT 1 FROM sqlite_schema WHERE type='table' AND name=?", [
      name,
    ]).isEmpty) {
      throw SessionException('会话中缺少 $name 表。');
    }
  }

  void _validateSchema(Database db) {
    for (final name in [
      'info',
      'file_properties',
      'snapshot',
      'object',
      'cluster_type',
      'snapshot_chainer',
    ]) {
      _requireTable(db, name);
    }
  }

  void _rejectAuxiliary(String path) {
    for (final suffix in ['-wal', '-shm', '-journal']) {
      if (File('$path$suffix').existsSync()) {
        throw SessionException(
          '检测到数据库辅助文件 ${p.basename(path)}$suffix，请完全退出 SuperRack 后重试。',
        );
      }
    }
  }

  String _quote(String value) => '"${value.replaceAll('"', '""')}"';

  void _copySnapshotRows(
    Database db, {
    required int fromSnapshot,
    required int toSnapshot,
  }) {
    final tables = db.select(
      "SELECT name FROM sqlite_schema WHERE type='table' AND name NOT LIKE 'sqlite_%'",
    );
    for (final tableRow in tables) {
      final table = tableRow['name']! as String;
      final columns = db.select('PRAGMA table_info(${_quote(table)})');
      if (!columns.any((c) => c['name'] == 'snapshot_id')) continue;
      final rows = db.select(
        'SELECT * FROM ${_quote(table)} WHERE snapshot_id=?',
        [fromSnapshot],
      );
      for (final row in rows) {
        final writable = columns
            .where((c) => !(c['name'] == 'id' && c['pk'] == 1))
            .toList();
        final names = writable.map((c) => c['name']! as String).toList();
        final values = names
            .map((name) => name == 'snapshot_id' ? toSnapshot : row[name])
            .toList();
        final placeholders = List.filled(names.length, '?').join(',');
        db.execute(
          'INSERT INTO ${_quote(table)} (${names.map(_quote).join(',')}) VALUES($placeholders)',
          values,
        );
      }
    }
  }

  void _verifySnapshotRows(
    Database db, {
    required int fromSnapshot,
    required int toSnapshot,
  }) {
    final tables = db.select(
      "SELECT name FROM sqlite_schema WHERE type='table' AND name NOT LIKE 'sqlite_%'",
    );
    for (final tableRow in tables) {
      final table = tableRow['name']! as String;
      final columns = db.select('PRAGMA table_info(${_quote(table)})');
      if (!columns.any((column) => column['name'] == 'snapshot_id')) continue;
      final sourceCount = db.select(
        'SELECT count(*) AS count FROM ${_quote(table)} WHERE snapshot_id=?',
        [fromSnapshot],
      ).single['count'];
      final copiedCount = db.select(
        'SELECT count(*) AS count FROM ${_quote(table)} WHERE snapshot_id=?',
        [toSnapshot],
      ).single['count'];
      if (sourceCount != copiedCount) {
        throw SessionException('Snapshot 数据复制校验失败：$table。');
      }
    }
  }

  void _writeRackNames(Database db, int snapshotId, List<String> names) {
    final ids = db.select(
      "SELECT id FROM object WHERE obj_type=(SELECT id FROM cluster_type WHERE name='Input') ORDER BY obj_index",
    );
    for (var i = 0; i < ids.length && i < names.length; i++) {
      final name = names[i].trim();
      if (name.isEmpty) continue;
      db.execute(
        'UPDATE snapshot_chainer SET name=? WHERE chainer_id=? AND snapshot_id=?',
        [name, ids[i]['id'], snapshotId],
      );
    }
  }

  List<String>? _namesForSnapshot(SessionBlueprint blueprint, String name) {
    for (final entry in blueprint.namesBySnapshot.entries) {
      if (entry.key.toLowerCase() == name.toLowerCase()) return entry.value;
    }
    return null;
  }

  String _renamePresetXml(String rawXml, String newName) {
    final root = XmlDocument.parse(rawXml).rootElement.copy();
    final preset = root.name.local == 'Preset'
        ? root
        : root.findElements('Preset').firstOrNull;
    if (preset == null) {
      throw const SessionException('预设 XML 中没有 Preset。');
    }
    preset.setAttribute('Name', newName);
    for (final data in preset.findAllElements('PresetData')) {
      if (data.getAttribute('SetupName') != null) {
        data.setAttribute('SetupName', newName);
      }
    }
    return XmlDocument([root]).toXmlString(pretty: true);
  }

  String _presetChunkXml(String rawXml) {
    final document = XmlDocument.parse(rawXml);
    if (document.rootElement.name.local == 'PresetChunkXMLTree') {
      return document.toXmlString(pretty: true);
    }
    final preset = _presetElement(rawXml).copy();
    final wrapper = XmlElement.tag(
      'PresetChunkXMLTree',
      attributes: [XmlAttribute(const XmlName.parts('version'), '3')],
      children: [preset],
      isSelfClosing: false,
    );
    return XmlDocument([wrapper]).toXmlString(pretty: true);
  }

  XmlElement _presetElement(String rawXml) {
    final root = XmlDocument.parse(rawXml).rootElement;
    if (root.name.local == 'Preset') return root;
    final preset = root.findElements('Preset').firstOrNull;
    if (preset == null) throw const SessionException('预设 XML 中没有 Preset。');
    return preset;
  }

  bool _presetNameExists(Database db, String name) => db.select(
    'SELECT 1 FROM user_presets WHERE name=? COLLATE NOCASE',
    [name],
  ).isNotEmpty;

  void _ensurePresetNameAvailable(
    Database db,
    String name, {
    required int exceptId,
  }) {
    if (name.isEmpty) throw const SessionException('预设名称不能为空。');
    if (db.select(
      'SELECT 1 FROM user_presets WHERE name=? COLLATE NOCASE AND id<>?',
      [name, exceptId],
    ).isNotEmpty) {
      throw SessionException('已存在同名预设：$name');
    }
  }

  void _reorderPresetIds(Database db, List<int> orderedIds) {
    final maxId =
        (db
                .select('SELECT COALESCE(max(id),0) AS id FROM user_presets')
                .first['id']!
            as int);
    final offset = maxId + orderedIds.length + 1;
    for (final id in orderedIds) {
      db.execute('UPDATE user_presets SET id=? WHERE id=?', [id + offset, id]);
    }
    for (var i = 0; i < orderedIds.length; i++) {
      db.execute('UPDATE user_presets SET id=? WHERE id=?', [
        i + 1,
        orderedIds[i] + offset,
      ]);
    }
  }
}
