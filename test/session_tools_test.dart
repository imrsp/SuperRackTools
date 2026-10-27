import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:super_rack_tools/models/session_tools.dart';
import 'package:super_rack_tools/services/session_blueprint_parser.dart';
import 'package:super_rack_tools/services/session_tools_service.dart';

Directory _testTemporaryDirectory() =>
    Directory(p.join(Directory.current.path, 'work', 'tmp'));

const _fixturePresetXml = '''
<PresetChunkXMLTree version="3">
  <Preset Name="Fixture Preset">
    <PresetData SetupName="Fixture Preset"><Value name="gain">0</Value></PresetData>
  </Preset>
</PresetChunkXMLTree>
''';

const _fixtureXps = '''
<?xml version="1.0" encoding="UTF-8"?>
<PresetXMLTree version="3">
  <Preset Name="Fixture Import">
    <PresetData SetupName="Fixture Import"><Value name="gain"><![CDATA[1]]></Value></PresetData>
  </Preset>
</PresetXMLTree>
''';

Future<File> _createSessionFixture(Directory directory) async {
  final file = File(p.join(directory.path, 'fixture.sprk'));
  await File(
    p.join(Directory.current.path, 'assets', 'Empty Session.sprk'),
  ).copy(file.path);
  final db = sqlite3.open(file.path);
  try {
    db.execute('INSERT INTO user_presets(name,preset) VALUES(?,?)', [
      'Fixture Preset',
      _fixturePresetXml,
    ]);
    db.execute('INSERT INTO plugin_preset(hash,preset) VALUES(?,?)', [
      'superracktools-test-fixture-preset',
      _fixturePresetXml,
    ]);
    final pluginPresetId = db.lastInsertRowId;
    db.execute('''
      INSERT INTO plug(chainer_id,slot,plugin_name,plugin_4cc,disabled,side_chain)
      VALUES(1,0,'Fixture EQ','FTEQ',0,0)
    ''');
    final pluginId = db.lastInsertRowId;
    db.execute('''
      INSERT INTO snapshot_plugin(plug_id,preset_id,snapshot_id,setup_type_id,bypass,mute)
      VALUES(?,?, -1,0,0,0)
    ''', [pluginId, pluginPresetId]);
  } finally {
    db.close();
  }
  return file;
}

void main() {
  late Directory testDirectory;
  late SessionToolsService service;
  const parser = SessionBlueprintParser();

  setUp(() async {
    final root = Directory(p.join(Directory.current.path, 'work', 'tmp'));
    await root.create(recursive: true);
    testDirectory = await root.createTemp('session-tools-test-');
    service = SessionToolsService(
      temporaryDirectoryProvider: _testTemporaryDirectory,
    );
  });

  tearDown(() async {
    if (await testDirectory.exists()) {
      await testDirectory.delete(recursive: true);
    }
  });

  test(
    'creates a 4.3 session and copies rack state into named snapshots',
    () async {
      final template = File(p.join(testDirectory.path, 'Empty Session.sprk'));
      await File(
        p.join(Directory.current.path, 'assets', 'Empty Session.sprk'),
      ).copy(template.path);
      final destination = p.join(testDirectory.path, 'created.sprk');
      final rackNames = List.generate(64, (i) => 'Rack Name ${i + 1}');
      final blueprint = parser.plainText(
        rackNames.join('\n'),
        'Soundcheck\nShow',
      );

      await service.createSession(
        templatePath: template.path,
        destination: destination,
        blueprint: blueprint,
      );

      final db = sqlite3.open(destination, mode: OpenMode.readOnly);
      try {
        expect(
          db
              .select(
                'SELECT schema_version_major,schema_version_minor,schema_version_revision,schema_version_patch FROM info WHERE id=0',
              )
              .single
              .values
              .join('.'),
          '4.3.0.5',
        );
        expect(
          db
              .select('SELECT mixer_channel_count FROM mixer_settings')
              .single['mixer_channel_count'],
          64,
        );
        expect(
          db
              .select(
                "SELECT value FROM file_properties WHERE name='Application Version'",
              )
              .single['value'],
          '14.30.283.991 Build R 312874',
        );
        expect(
          db
              .select('SELECT name FROM snapshot ORDER BY number')
              .map((r) => r['name'])
              .toList(),
          ['Backup', 'Active', 'Soundcheck', 'Show'],
        );
        expect(
          db
              .select(
                "SELECT ext_id FROM snapshot WHERE name IN ('Soundcheck','Show')",
              )
              .map((row) => row['ext_id'])
              .toList(),
          [null, null],
        );
        for (final table in [
          'snapshot_chainer',
          'snapshot_chainer_params',
          'snapshot_scope_settings',
          'snapshot_hot_plugins',
          'snapshot_iom',
          'snapshot_mute_group',
        ]) {
          expect(
            db
                .select(
                  'SELECT count(*) AS n FROM "$table" WHERE snapshot_id IN (0,1)',
                )
                .single['n'],
            db
                .select(
                      'SELECT count(*) AS n FROM "$table" WHERE snapshot_id=-1',
                    )
                    .single['n']! *
                2,
            reason: '$table must be copied to each new Snapshot',
          );
        }
        expect(
          db.select('''SELECT count(*) AS n FROM snapshot_chainer sc
          JOIN snapshot s ON s.id=sc.snapshot_id
          WHERE s.name='Soundcheck' AND sc.name='Rack Name 1' ''').single['n'],
          1,
        );
        expect(db.select('PRAGMA foreign_key_check'), isEmpty);
      } finally {
        db.close();
      }
    },
  );

  test('imports selected XPS entries and exports valid XPS XML', () async {
    final template = File(p.join(testDirectory.path, 'Empty Session.sprk'));
    await File(
      p.join(Directory.current.path, 'assets', 'Empty Session.sprk'),
    ).copy(template.path);
    final source = p.join(testDirectory.path, 'source.sprk');
    final imported = p.join(testDirectory.path, 'imported.sprk');
    final xpsIn = File(p.join(testDirectory.path, 'fixture.xps'));
    await xpsIn.writeAsString(_fixtureXps);
    final xpsOut = p.join(testDirectory.path, 'selected.xps');
    await File(template.path).copy(source);
    final options = await service.readXpsPresetNames(xpsIn.path);
    expect(options, isNotEmpty);
    await service.importXps(
      sessionPath: source,
      xpsPath: xpsIn.path,
      destination: imported,
      selectedIndexes: {0},
    );
    expect((await service.readUserPresets(imported)).length, 1);
    final preset = (await service.readUserPresets(imported)).single;
    await service.exportXps(
      sessionPath: imported,
      destination: xpsOut,
      selectedIds: {preset.id},
    );
    expect(
      (await service.readXpsPresetNames(xpsOut)).single.name,
      options.first.name,
    );
    expect(await File(xpsOut).readAsString(), contains('<![CDATA['));
  });

  test('snapshot name edits write only the selected snapshot', () async {
    final cleanSource = await _createSessionFixture(testDirectory);
    final original = await service.readSnapshots(cleanSource.path);
    final active = original.firstWhere((s) => s.number == -1);
    final rack = (await service.readSnapshotRacks(
      cleanSource.path,
      active.id,
    )).first;
    final destination = p.join(testDirectory.path, 'renamed.sprk');
    await service.updateSnapshotNames(
      source: cleanSource.path,
      destination: destination,
      snapshotId: active.id,
      names: {rack.id: 'Temporary Test Name'},
    );
    final updated = await service.readSnapshotRacks(destination, active.id);
    expect(updated.first.name, 'Temporary Test Name');
    expect(
      (await service.readSnapshotRacks(cleanSource.path, active.id)).first.name,
      rack.name,
    );
  });

  test('batch rack, bypass, and Recall Safe states round trip', () async {
    final cleanSource = await _createSessionFixture(testDirectory);
    final snapshots = await service.readSnapshots(cleanSource.path);
    final active = snapshots.firstWhere((s) => s.number == -1);
    final matrix = await service.readMatrix(cleanSource.path, active.id);
    final rack = matrix.firstWhere((r) => r.plugins.isNotEmpty);
    final plugin = rack.plugins.first;
    final destination = p.join(testDirectory.path, 'matrix-edited.sprk');

    await service.updateMatrix(
      source: cleanSource.path,
      destination: destination,
      snapshotId: active.id,
      rackOn: {rack.id: !rack.isOn},
      rackRecallSafe: {rack.id: !rack.recallSafe},
      pluginBypass: {plugin.id: !plugin.bypass},
      pluginRecallSafe: {plugin.id: !plugin.recallSafe},
    );

    final updated = await service.readMatrix(destination, active.id);
    final updatedRack = updated.firstWhere((r) => r.id == rack.id);
    final updatedPlugin = updatedRack.plugins.firstWhere(
      (p) => p.id == plugin.id,
    );
    expect(updatedRack.isOn, !rack.isOn);
    expect(updatedRack.recallSafe, !rack.recallSafe);
    expect(updatedPlugin.bypass, !plugin.bypass);
    expect(updatedPlugin.recallSafe, !plugin.recallSafe);
  });

  test(
    'combined save applies matrix drafts across multiple snapshots',
    () async {
      final original = await _createSessionFixture(testDirectory);
      final source = p.join(testDirectory.path, 'multi-snapshot-source.sprk');
      final destination = p.join(
        testDirectory.path,
        'multi-snapshot-result.sprk',
      );
      await original.copy(source);
      final snapshots = (await service.readSnapshots(
        source,
      )).where((s) => s.rackCount > 0).take(2).toList();
      final drafts = <MatrixEditDraft>[];
      final before = <int, bool>{};
      for (final snapshot in snapshots) {
        final rack = (await service.readMatrix(source, snapshot.id)).first;
        before[snapshot.id] = rack.isOn;
        drafts.add(
          MatrixEditDraft(
            snapshotId: snapshot.id,
            rackOn: {rack.id: !rack.isOn},
            rackRecallSafe: const {},
            pluginBypass: const {},
            pluginRecallSafe: const {},
          ),
        );
      }
      await service.saveCombinedEdits(
        source: source,
        destination: destination,
        namesBySnapshot: const {},
        matrixDrafts: drafts,
      );
      for (var i = 0; i < snapshots.length; i++) {
        final rack = (await service.readMatrix(
          destination,
          snapshots[i].id,
        )).first;
        expect(rack.isOn, !before[snapshots[i].id]!);
      }
    },
  );

  test('saves all three editor drafts into one session copy', () async {
    final cleanSource = await _createSessionFixture(testDirectory);
    final snapshots = await service.readSnapshots(cleanSource.path);
    final active = snapshots.firstWhere((s) => s.number == -1);
    final racks = await service.readMatrix(cleanSource.path, active.id);
    final rack = racks.firstWhere((r) => r.plugins.isNotEmpty);
    final plugin = rack.plugins.first;
    final originalPresets = await service.readUserPresets(cleanSource.path);
    final xpsFile = File(p.join(testDirectory.path, 'combined-fixture.xps'));
    await xpsFile.writeAsString(_fixtureXps);
    final importedXml = (await service.readXpsPresetData(xpsFile.path, {
      0,
    })).single.xml;
    final importedDraft = UserPreset(id: -1, name: 'Imported from XPS');
    final renamedId = originalPresets.first.id;
    final duplicateId = originalPresets.last.id;
    final draft = PresetEditDraft(
      orderedPresets: [...originalPresets, importedDraft],
      renames: {renamedId: 'Combined Rename', -1: 'Imported from XPS'},
      duplicateIds: {duplicateId},
      deleteIds: const {},
      importedXmlById: {-1: importedXml},
      reordered: true,
    );
    final destination = p.join(testDirectory.path, 'combined.sprk');
    final xpsDraftPath = p.join(testDirectory.path, 'combined-selected.xps');

    await service.exportXps(
      sessionPath: cleanSource.path,
      destination: xpsDraftPath,
      selectedIds: {renamedId, -1},
      draft: draft,
    );
    expect(
      (await service.readXpsPresetNames(
        xpsDraftPath,
      )).map((preset) => preset.name).toList(),
      ['Combined Rename', 'Imported from XPS'],
    );

    await service.saveCombinedEdits(
      source: cleanSource.path,
      destination: destination,
      namesBySnapshot: {
        active.id: {rack.id: 'Combined Rack Name'},
      },
      matrixDrafts: [
        MatrixEditDraft(
          snapshotId: active.id,
          rackOn: {rack.id: !rack.isOn},
          rackRecallSafe: const {},
          pluginBypass: {plugin.id: !plugin.bypass},
          pluginRecallSafe: const {},
        ),
      ],
      presets: draft,
    );

    expect(
      (await service.readSnapshotRacks(
        destination,
        active.id,
      )).firstWhere((r) => r.id == rack.id).name,
      'Combined Rack Name',
    );
    final updatedMatrix = await service.readMatrix(destination, active.id);
    final updatedRack = updatedMatrix.firstWhere((r) => r.id == rack.id);
    expect(updatedRack.isOn, !rack.isOn);
    expect(
      updatedRack.plugins.firstWhere((p) => p.id == plugin.id).bypass,
      !plugin.bypass,
    );
    final updatedPresets = await service.readUserPresets(destination);
    expect(updatedPresets.length, originalPresets.length + 2);
    expect(updatedPresets.first.name, 'Combined Rename');
    expect(updatedPresets.any((p) => p.name == 'Imported from XPS'), isTrue);
  });

  test(
    'reads an existing preset XML payload for preview duplication',
    () async {
      final source = await _createSessionFixture(testDirectory);
      final presets = await service.readUserPresets(source.path);
      expect(presets, isNotEmpty);
      final xml = await service.readPresetXml(source.path, presets.first.id);
      expect(xml, contains('<Preset'));
    },
  );
}
