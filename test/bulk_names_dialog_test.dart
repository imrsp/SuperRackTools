import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:super_rack_tools/screens/home_screen.dart';

void main() {
  testWidgets(
    'bulk name editor shows line numbers and Alt-drag edits a column',
    (tester) async {
      tester.view.physicalSize = const Size(900, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BulkNamesDialog(
              initialNames: const ['abc', 'abc'],
              rowCount: 2,
            ),
          ),
        ),
      );
      expect(find.text('1'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);

      final field = find.byType(TextField);
      final rect = tester.getRect(field);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      final gesture = await tester.startGesture(
        Offset(rect.left + 27, rect.top + 10),
        kind: PointerDeviceKind.mouse,
        buttons: kPrimaryMouseButton,
      );
      await gesture.moveTo(Offset(rect.left + 36, rect.top + 34));
      await gesture.up();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyX, character: 'x');
      await tester.pumpAndSettle();

      expect(tester.widget<TextField>(field).controller!.text.split('\n'), [
        'axc',
        'axc',
      ]);
      expect(tester.takeException(), isNull);
    },
  );
}
