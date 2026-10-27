import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:super_rack_tools/services/safe_file_publisher.dart';

void main() {
  test(
    'publishes atomically and refuses to replace an existing target',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'publisher-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final staged = File('${directory.path}/staged.tmp');
      final target = File('${directory.path}/result.sprk');
      await staged.writeAsString('complete contents');

      await SafeFilePublisher.publishNoReplace(staged, target);

      expect(await target.readAsString(), 'complete contents');
      expect(await staged.exists(), isTrue);
      await target.writeAsString('keep existing');
      await expectLater(
        SafeFilePublisher.publishNoReplace(staged, target),
        throwsA(isA<FileSystemException>()),
      );
      expect(await target.readAsString(), 'keep existing');
    },
  );
}
