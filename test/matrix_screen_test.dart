import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:super_rack_tools/models/session_tools.dart';
import 'package:super_rack_tools/screens/matrix_screen.dart';
import 'package:super_rack_tools/services/session_tools_service.dart';

class _MatrixFixtureService extends SessionToolsService {
  static const snapshot = SessionSnapshot(
    id: 7,
    number: 1,
    name: 'Snapshot One',
    rackCount: 1,
  );
  static const rack = MatrixRack(
    id: 10,
    number: 1,
    name: 'Lead',
    isOn: true,
    recallSafe: false,
    plugins: [
      MatrixPlugin(
        id: 100,
        slot: 0,
        name: 'EQ',
        bypass: true,
        recallSafe: false,
      ),
    ],
  );

  @override
  Future<List<SessionSnapshot>> readSnapshots(String path) async => [snapshot];

  @override
  Future<List<MatrixRack>> readMatrix(String path, int snapshotId) async => [
    rack,
  ];
}

const _secondSnapshot = SessionSnapshot(
  id: 8,
  number: 1,
  name: 'Snapshot Two',
  rackCount: 1,
);

void main() {
  testWidgets(
    'headers select directly and shared selection control applies edits',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final drafts = <List<MatrixEditDraft>>[];
      final commands = <EditorCommand>[];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MatrixScreen(
              sessionPath: 'fixture.sprk',
              snapshots: const [_MatrixFixtureService.snapshot],
              selectedSnapshotId: 7,
              allSnapshots: false,
              onDraftChanged: drafts.add,
              onCommand: commands.add,
              service: _MatrixFixtureService(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('状态矩阵'), findsNothing);
      expect(find.text('Active · 64 个通道'), findsNothing);
      final start = tester.getCenter(find.text('Rack'));
      final end = tester.getCenter(find.text('On'));
      final headerDrag = await tester.startGesture(
        start,
        kind: PointerDeviceKind.mouse,
        buttons: kPrimaryMouseButton,
      );
      await headerDrag.moveTo(end);
      await headerDrag.up();
      await tester.pumpAndSettle();
      expect(find.byType(PopupMenuItem<String>), findsNothing);
      expect(find.text('4 已选'), findsOneWidget);
      await tester.tap(find.text('Rack'));
      await tester.pumpAndSettle();
      expect(find.text('0 已选'), findsOneWidget);
      await tester.tap(find.byTooltip('选择操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('全选'));
      await tester.pumpAndSettle();
      expect(find.text('4 已选'), findsOneWidget);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      expect(drafts.last.single.rackOn[10], isFalse);
      expect(drafts.last.single.pluginBypass[100], isFalse);
      expect(commands, hasLength(1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('touching a matrix cell updates every snapshot in all mode', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final drafts = <List<MatrixEditDraft>>[];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MatrixScreen(
            sessionPath: 'fixture.sprk',
            snapshots: const [_MatrixFixtureService.snapshot, _secondSnapshot],
            selectedSnapshotId: 7,
            allSnapshots: true,
            onDraftChanged: drafts.add,
            onCommand: (_) {},
            service: _MatrixFixtureService(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.power_settings_new_rounded).last);
    await tester.pumpAndSettle();

    expect(drafts.last.map((draft) => draft.snapshotId).toSet(), {7, 8});
    expect(drafts.last.every((draft) => draft.rackOn[10] == false), isTrue);
    expect(tester.takeException(), isNull);
  });
}
