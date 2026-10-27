import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:super_rack_tools/main.dart';
import 'package:super_rack_tools/screens/database_screen.dart';

class _SavePicker extends FilePicker {
  _SavePicker(this.destination);
  final String destination;

  @override
  Future<String?> saveFile({
    String? dialogTitle,
    String? fileName,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Uint8List? bytes,
    bool lockParentWindow = false,
  }) async => destination;
}

Future<void> _waitFor(WidgetTester tester, bool Function() ready) async {
  await tester.runAsync(() async {
    for (var attempt = 0; attempt < 200 && !ready(); attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await tester.pump();
    }
  });
  expect(ready(), isTrue);
}

void main() {
  testWidgets(
    'home saves name and matrix edits together through the real service',
    (tester) async {
      final directory = Directory.systemTemp.createTempSync('home-save-test-');
      final source = File(
        'assets/Empty Session.sprk',
      ).copySync('${directory.path}/source.sprk');
      final destination = '${directory.path}/saved.sprk';
      FilePicker.platform = _SavePicker(destination);
      const channel = MethodChannel('tech.rslive.superracktools/files');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (_) async => [source.path],
      );
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(() async {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        );
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        directory.deleteSync(recursive: true);
      });

      await tester.pumpWidget(const SuperRackToolsApp());
      await _waitFor(
        tester,
        () => find.byType(TextField).evaluate().isNotEmpty,
      );
      await tester.enterText(
        find.byType(TextField).first,
        'Acceptance Rack 01',
      );
      await tester.tap(find.byTooltip('SQLite 数据库浏览器（高级）'));
      await tester.pump();
      await _waitFor(tester, () => find.text('丢弃未保存修改？').evaluate().isNotEmpty);
      await tester.tap(find.text('继续编辑'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(DatabaseScreen), findsNothing);
      expect(find.text('Acceptance Rack 01'), findsOneWidget);

      await tester.tap(find.text('状态编辑'));
      await tester.pump();
      await _waitFor(
        tester,
        () =>
            find.byIcon(Icons.power_settings_new_rounded).evaluate().length > 1,
      );
      await tester.tap(find.byIcon(Icons.power_settings_new_rounded).at(1));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存全部修改'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('选择保存位置'));
      await _waitFor(tester, () => find.text('全部修改已保存').evaluate().isNotEmpty);
      final db = sqlite3.open(destination, mode: OpenMode.readOnly);
      try {
        expect(db.select('PRAGMA integrity_check').single.values.single, 'ok');
        expect(db.select('PRAGMA foreign_key_check'), isEmpty);
        expect(
          db.select(
            "SELECT * FROM snapshot_chainer WHERE name='Acceptance Rack 01'",
          ),
          isNotEmpty,
        );
        expect(
          db.select('''SELECT cp.* FROM snapshot_chainer_params cp
            JOIN snapshot_chainer sc ON sc.chainer_id=cp.chainer_id
              AND sc.snapshot_id=cp.snapshot_id
            WHERE sc.name='Acceptance Rack 01' AND cp.param_id=105
              AND cp.param_value=0'''),
          isNotEmpty,
        );
      } finally {
        db.close();
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
