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

  test('published file remains readable after staging cleanup', () async {
    final directory = await Directory.systemTemp.createTemp(
      'publisher-cleanup-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final staged = File('${directory.path}/暂存文件.tmp');
    final target = File('${directory.path}/保存的会话.sprk');
    final contents = List<int>.generate(1024, (index) => index % 256);
    await staged.writeAsBytes(contents);

    await SafeFilePublisher.publishNoReplace(staged, target);
    await staged.delete();

    expect(await target.readAsBytes(), contents);
  });

  test(
    'missing staged file reports failure without creating a target',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'publisher-missing-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final staged = File('${directory.path}/missing.tmp');
      final target = File('${directory.path}/result.sprk');

      await expectLater(
        SafeFilePublisher.publishNoReplace(staged, target),
        throwsA(isA<FileSystemException>()),
      );
      expect(await target.exists(), isFalse);
    },
  );

  test(
    'real conflict preserves both existing target and new staged data',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'publisher-conflict-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final staged = File('${directory.path}/staged.tmp');
      final target = File('${directory.path}/result.sprk');
      await staged.writeAsString('new contents');
      await target.writeAsString('original contents');

      await expectLater(
        SafeFilePublisher.publishNoReplace(staged, target),
        throwsA(
          isA<FileSystemException>().having(
            (error) => error.message,
            'message',
            contains('目标文件已存在'),
          ),
        ),
      );
      expect(await target.readAsString(), 'original contents');
      expect(await staged.readAsString(), 'new contents');
    },
  );
}
