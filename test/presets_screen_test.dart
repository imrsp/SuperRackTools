import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:super_rack_tools/models/session_tools.dart';
import 'package:super_rack_tools/screens/presets_screen.dart';
import 'package:super_rack_tools/services/session_tools_service.dart';

class _FakeSessionToolsService extends SessionToolsService {
  @override
  Future<List<UserPreset>> readUserPresets(String path) async => const [
    UserPreset(id: 1, name: 'Preset One'),
    UserPreset(id: 2, name: 'Preset Two'),
    UserPreset(id: 3, name: 'Preset Three'),
  ];

  @override
  Future<String> readPresetXml(String path, int presetId) async =>
      '<Preset id="$presetId" />';
}

void main() {
  testWidgets(
    'duplicate appears immediately and each row has one drag handle',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final commands = <EditorCommand>[];

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.macOS),
          home: Scaffold(
            body: SizedBox.expand(
              child: PresetsScreen(
                sessionPath: 'fixture.sprk',
                onDraftChanged: (_) {},
                onCommand: commands.add,
                service: _FakeSessionToolsService(),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Preset One'), findsOneWidget);
      expect(find.text('0 已选'), findsOneWidget);
      expect(find.byTooltip('拖动调整预设顺序'), findsNWidgets(3));
      final copyBefore = tester.widget<IconButton>(
        find
            .byWidgetPredicate(
              (widget) => widget is IconButton && widget.tooltip == '复制',
            )
            .first,
      );
      final copyColor = copyBefore.color;
      expect(find.byType(ReorderableDragStartListener), findsNWidgets(3));
      await tester.tap(find.text('01'));
      await tester.pumpAndSettle();
      expect(find.text('1 已选'), findsOneWidget);
      expect(
        commands,
        isEmpty,
        reason: 'selection must stay out of undo history',
      );

      await tester.tap(find.text('02'));
      await tester.pumpAndSettle();
      expect(find.text('2 已选'), findsOneWidget);
      final copyAfter = tester.widget<IconButton>(
        find
            .byWidgetPredicate(
              (widget) => widget is IconButton && widget.tooltip == '复制',
            )
            .first,
      );
      expect(copyAfter.color, copyColor);
      expect(copyAfter.onPressed, isNotNull);
      final handleRect = tester.getRect(
        find.byType(ReorderableDragStartListener).first,
      );
      final deleteRect = tester.getRect(find.byTooltip('删除').first);
      expect(handleRect.left - deleteRect.right, greaterThanOrEqualTo(24));
      await tester.tap(find.byTooltip('复制').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('创建副本'));
      await tester.pumpAndSettle();

      expect(find.text('Preset One Copy'), findsOneWidget);
      expect(find.textContaining('复制预设失败'), findsNothing);
      expect(tester.takeException(), isNull);

      final firstHandle = find.byType(ReorderableDragStartListener).first;
      await tester.dragFrom(
        tester.getCenter(firstHandle),
        const Offset(0, 130),
      );
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.text('Preset One')).dy,
        greaterThan(tester.getTopLeft(find.text('Preset One Copy')).dy),
      );
      expect(tester.takeException(), isNull);
    },
  );
}
