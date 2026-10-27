import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:super_rack_tools/widgets/editor_selection.dart';

void main() {
  testWidgets('selection badge has one predictable tap and shared styling', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SelectableIndexBadge(
            index: '04',
            selected: true,
            onTap: () => taps++,
          ),
        ),
      ),
    );
    await tester.tap(find.text('04'));
    expect(taps, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('selection toolbar keeps stable controls and reports the count', (
    tester,
  ) async {
    var selectedAll = false;
    var cleared = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EditorSelectionToolbar(
            count: 3,
            onSelectAll: () => selectedAll = true,
            onClear: () => cleared = true,
            onInvert: () {},
            onCopy: () {},
          ),
        ),
      ),
    );
    expect(find.text('3 已选'), findsOneWidget);
    await tester.tap(find.byTooltip('选择操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('全选'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('选择操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('全不选'));
    expect(selectedAll, isTrue);
    expect(cleared, isTrue);
    expect(tester.takeException(), isNull);
  });
}
