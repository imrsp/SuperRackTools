import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:super_rack_tools/services/session_service.dart';

void main() {
  test(
    'closing a database copy removes its temporary file and directory',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'session-service-test-',
      );
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
      });
      final source = File(p.join(root.path, 'source.sprk'));
      final original = sqlite3.open(source.path);
      original.execute('CREATE TABLE sample(id INTEGER PRIMARY KEY)');
      original.close();
      final tempRoot = Directory(p.join(root.path, 'temporary'));
      final service = SessionService(
        temporaryDirectoryProvider: () => tempRoot,
      );

      final copy = await service.openDatabaseCopy(source.path);
      final copyPath =
          copy.select('PRAGMA database_list').single['file']! as String;
      expect(await File(copyPath).exists(), isTrue);

      await service.closeDatabaseCopy(copy);

      expect(await File(copyPath).exists(), isFalse);
      expect(await Directory(p.dirname(copyPath)).exists(), isFalse);
    },
  );
}
