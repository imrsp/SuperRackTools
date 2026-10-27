import '../models/session_tools.dart';
import 'session_service.dart';

class SessionBlueprintParser {
  const SessionBlueprintParser();

  SessionBlueprint plainText(String channels, String snapshots) {
    final rackNames = _lines(channels);
    _validateRackCount(rackNames.length);
    if (rackNames.any((name) => name.isEmpty)) {
      throw const SessionException('通道名称不能为空。');
    }
    final snapshotNames = _lines(
      snapshots,
    ).where((e) => e.isNotEmpty && e.toLowerCase() != 'active').toList();
    _validateSnapshots(snapshotNames);
    final namesBySnapshot = <String, List<String>>{
      'Active': rackNames,
      for (final name in snapshotNames) name: rackNames,
    };
    return SessionBlueprint(
      rackNames: rackNames,
      snapshotNames: snapshotNames,
      namesBySnapshot: namesBySnapshot,
    );
  }

  List<String> singleColumnCsv(String content) {
    final rows = _parseCsv(content.replaceFirst('\uFEFF', ''));
    if (rows.isEmpty) throw const SessionException('CSV 文件中没有名称。');
    if (rows.any((row) => row.length != 1)) {
      throw const SessionException('请导入只有一列的 CSV，每行填写一个名称。');
    }
    return rows.map((row) => row.single.trim()).toList();
  }

  List<String> _lines(String input) {
    final lines = input
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .split('\n');
    while (lines.isNotEmpty && lines.last.trim().isEmpty) {
      lines.removeLast();
    }
    return lines.map((line) => line.trim()).toList();
  }

  void _validateRackCount(int count) {
    if (count == 0 || count > 64) {
      throw const SessionException('请输入 1 到 64 个通道名称。');
    }
  }

  void _validateSnapshots(List<String> names) {
    final values = names.map((e) => e.trim()).toList();
    if (values.any((e) => e.isEmpty)) {
      throw const SessionException('Snapshot 名称不能为空。');
    }
    if (values.map((e) => e.toLowerCase()).toSet().length != values.length) {
      throw const SessionException('Snapshot 名称不能重复。');
    }
  }

  List<List<String>> _parseCsv(String input) {
    final rows = <List<String>>[];
    var row = <String>[];
    final cell = StringBuffer();
    var quoted = false;
    for (var i = 0; i < input.length; i++) {
      final char = input[i];
      if (quoted) {
        if (char == '"' && i + 1 < input.length && input[i + 1] == '"') {
          cell.write('"');
          i++;
        } else if (char == '"') {
          quoted = false;
        } else {
          cell.write(char);
        }
      } else if (char == '"' && cell.isEmpty) {
        quoted = true;
      } else if (char == ',') {
        row.add(cell.toString());
        cell.clear();
      } else if (char == '\n' || char == '\r') {
        row.add(cell.toString());
        cell.clear();
        if (row.any((value) => value.trim().isNotEmpty)) rows.add(row);
        row = <String>[];
        if (char == '\r' && i + 1 < input.length && input[i + 1] == '\n') i++;
      } else {
        cell.write(char);
      }
    }
    if (quoted) throw const SessionException('CSV 中有未闭合的引号。');
    if (cell.isNotEmpty || row.isNotEmpty) {
      row.add(cell.toString());
      if (row.any((value) => value.trim().isNotEmpty)) rows.add(row);
    }
    return rows;
  }
}
