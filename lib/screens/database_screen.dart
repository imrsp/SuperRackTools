import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' hide Row;
import '../services/session_service.dart';
import '../services/safe_file_publisher.dart';

class DatabaseScreen extends StatefulWidget {
  const DatabaseScreen({
    super.key,
    this.initialPath,
    this.onPathChanged,
    this.onUnsavedChangesChanged,
  });

  final String? initialPath;
  final ValueChanged<String>? onPathChanged;
  final ValueChanged<bool>? onUnsavedChangesChanged;

  @override
  State<DatabaseScreen> createState() => _DatabaseScreenState();
}

class _DatabaseScreenState extends State<DatabaseScreen> {
  final _service = const SessionService();
  String? _path;
  List<String> _objects = const [];
  String? _selected;
  List<Map<String, Object?>> _columns = const [];
  List<Map<String, Object?>> _rows = const [];
  List<Map<String, Object?>> _originalRows = const [];
  final Map<String, List<Map<String, Object?>>> _draftRowsByObject = {};
  bool _isView = false;
  String _status = '打开 .sprk 数据库以浏览所有数据表';
  bool _busy = false;
  bool _showAdvancedWarning = true;
  double _sidebarWidth = 240;
  final _findController = TextEditingController();
  final _tableScrollController = ScrollController();
  String _findText = '';
  String _replaceText = '';
  bool _matchCase = false;
  int _activeMatch = 0;
  List<(String, int, String)> _globalMatches = const [];
  bool _searchAllTables = false;

  bool get _currentTableChanged =>
      _rows.length != _originalRows.length ||
      List.generate(_rows.length, (index) => index).any(
        (index) =>
            _rows[index].length != _originalRows[index].length ||
            _rows[index].entries.any(
              (entry) => _originalRows[index][entry.key] != entry.value,
            ),
      );
  bool get _hasUnsavedChanges =>
      _currentTableChanged || _draftRowsByObject.isNotEmpty;

  void _captureCurrentDraft() {
    final selected = _selected;
    if (selected != null) {
      if (_currentTableChanged) {
        _draftRowsByObject[selected] = _rows
            .map((row) => Map<String, Object?>.from(row))
            .toList();
      } else {
        _draftRowsByObject.remove(selected);
      }
    }
    widget.onUnsavedChangesChanged?.call(_hasUnsavedChanges);
  }

  Future<void> _handlePop(bool didPop) async {
    if (didPop || _busy || !mounted) return;
    final needsConfirmation = _hasUnsavedChanges;
    if (needsConfirmation) {
      final discard = await _confirmDiscard();
      if (!mounted || !discard) return;
    }
    Navigator.of(context).pop();
  }

  Future<bool> _confirmDiscard() async {
    final discard = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('放弃数据库修改？'),
        content: const Text('继续操作会丢弃所有尚未保存的表修改。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('继续编辑'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('放弃修改'),
          ),
        ],
      ),
    );
    if (!mounted) return false;
    return discard == true;
  }

  List<(int, String)> get _matches {
    if (_findText.isEmpty) return const [];
    final needle = _matchCase ? _findText : _findText.toLowerCase();
    final matches = <(int, String)>[];
    for (var row = 0; row < _rows.length; row++) {
      for (final column in _columns) {
        final name = column['name'] as String;
        final value = _rows[row][name]?.toString() ?? '';
        final haystack = _matchCase ? value : value.toLowerCase();
        if (haystack.contains(needle)) matches.add((row, name));
      }
    }
    return matches;
  }

  Future<void> _findAcrossDatabase() async {
    final query = _findText;
    final path = _path;
    if (query.isEmpty || path == null) return;
    setState(() => _busy = true);
    try {
      final db = await _service.openDatabaseCopy(path);
      final matches = <(String, int, String)>[];
      try {
        for (final table in _objects) {
          final columns = db.select('PRAGMA table_info(${_quote(table)})');
          final values = db.select('SELECT * FROM ${_quote(table)}');
          for (var row = 0; row < values.length; row++) {
            for (final column in columns) {
              final name = column['name'] as String;
              final value = values[row][name];
              if (value is! String) continue;
              final haystack = _matchCase ? value : value.toLowerCase();
              final needle = _matchCase ? query : query.toLowerCase();
              if (haystack.contains(needle)) matches.add((table, row, name));
            }
          }
        }
      } finally {
        await _service.closeDatabaseCopy(db);
      }
      if (!mounted) return;
      setState(() {
        _globalMatches = matches;
        _searchAllTables = true;
        _activeMatch = 0;
        _busy = false;
      });
      if (matches.isNotEmpty) {
        await _selectObject(matches.first.$1, preserveSearch: true);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _status = '跨表查找失败：$e';
        });
      }
    }
  }

  Future<void> _activateGlobalMatch(int index) async {
    final matches = _globalMatches;
    if (matches.isEmpty) return;
    final match = matches[index.clamp(0, matches.length - 1)];
    if (_selected != match.$1) {
      await _selectObject(match.$1, preserveSearch: true);
    }
    if (!mounted) return;
    setState(() => _activeMatch = index);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_tableScrollController.hasClients) return;
      _tableScrollController.animateTo(
        (match.$2 * 48.0).clamp(
          0.0,
          _tableScrollController.position.maxScrollExtent,
        ),
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  void dispose() {
    widget.onUnsavedChangesChanged?.call(false);
    _findController.dispose();
    _tableScrollController.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    if (widget.initialPath != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _loadPath(widget.initialPath!);
      });
    }
  }

  Future<void> _open() async {
    if (_hasUnsavedChanges && !await _confirmDiscard()) return;
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['sprk', 'db', 'sqlite', 'sqlite3'],
    );
    final path = result?.files.single.path;
    if (path == null || !mounted) return;
    await _loadPath(path);
  }

  Future<void> _loadPath(String path) async {
    if (!mounted) return;
    setState(() {
      _busy = true;
      _status = '正在读取数据库结构…';
    });
    try {
      final db = await _service.openDatabaseCopy(path);
      try {
        final objects = db
            .select(
              "SELECT name FROM sqlite_schema WHERE type IN ('table','view') AND name NOT LIKE 'sqlite_%' ORDER BY type, name",
            )
            .map((r) => r['name'] as String)
            .toList();
        if (!mounted) return;
        setState(() {
          _path = path;
          _objects = objects;
          _selected = null;
          _columns = const [];
          _rows = const [];
          _originalRows = const [];
          _draftRowsByObject.clear();
          _busy = false;
          _status = '${objects.length} 个表或视图';
        });
        widget.onUnsavedChangesChanged?.call(false);
        widget.onPathChanged?.call(path);
      } finally {
        await _service.closeDatabaseCopy(db);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _status = '读取失败：$e';
        });
      }
    }
  }

  Future<void> _selectObject(String name, {bool preserveSearch = false}) async {
    final path = _path;
    if (path == null) return;
    if (name == _selected) return;
    _captureCurrentDraft();
    try {
      final db = await _service.openDatabaseCopy(path);
      try {
        final columns = db
            .select('PRAGMA table_info(${_quote(name)})')
            .map((r) => Map<String, Object?>.from(r))
            .toList();
        final type = db.select("SELECT type FROM sqlite_schema WHERE name=?", [
          name,
        ]).first['type'];
        final sourceRows = db
            .select('SELECT * FROM ${_quote(name)}')
            .map((r) => Map<String, Object?>.from(r))
            .toList();
        final rows =
            _draftRowsByObject[name]
                ?.map((r) => Map<String, Object?>.from(r))
                .toList() ??
            sourceRows;
        if (!mounted) return;
        setState(() {
          _selected = name;
          _columns = columns;
          _rows = rows;
          _originalRows = sourceRows
              .map((r) => Map<String, Object?>.from(r))
              .toList();
          _isView = type == 'view';
          _status = '${rows.length} 行';
          if (!preserveSearch) {
            _findText = '';
            _findController.clear();
            _searchAllTables = false;
            _globalMatches = const [];
            _activeMatch = 0;
          }
        });
      } finally {
        await _service.closeDatabaseCopy(db);
      }
    } catch (e) {
      if (mounted) setState(() => _status = '无法读取对象：$e');
    }
  }

  String _quote(String identifier) => '"${identifier.replaceAll('"', '""')}"';

  void _navigateMatch(int delta) {
    if (_searchAllTables) {
      if (_globalMatches.isEmpty) return;
      final next =
          (_activeMatch + delta + _globalMatches.length) %
          _globalMatches.length;
      _activateGlobalMatch(next);
      return;
    }
    final matches = _matches;
    if (matches.isEmpty) return;
    final next = (_activeMatch + delta + matches.length) % matches.length;
    setState(() => _activeMatch = next);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_tableScrollController.hasClients) return;
      final position = (matches[next].$1 * 48.0).clamp(
        0.0,
        _tableScrollController.position.maxScrollExtent,
      );
      _tableScrollController.animateTo(
        position,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _showReplace() async {
    if (_isView || _columns.isEmpty) return;
    final find = TextEditingController(text: _findText);
    final replacement = TextEditingController(text: _replaceText);
    var columnName = _columns.first['name'] as String;
    var wholeTable = true;
    final apply = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('查找并替换'),
          content: SizedBox(
            width: 440,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: find,
                  autofocus: true,
                  decoration: const InputDecoration(labelText: '查找内容'),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: replacement,
                  decoration: const InputDecoration(labelText: '替换为'),
                ),
                const SizedBox(height: 12),
                CheckboxListTile(
                  value: wholeTable,
                  contentPadding: EdgeInsets.zero,
                  title: const Text('搜索所有列'),
                  onChanged: (v) =>
                      setDialogState(() => wholeTable = v ?? true),
                ),
                if (!wholeTable)
                  DropdownButtonFormField<String>(
                    initialValue: columnName,
                    decoration: const InputDecoration(labelText: '列'),
                    items: [
                      for (final c in _columns)
                        DropdownMenuItem(
                          value: c['name'] as String,
                          child: Text(c['name'] as String),
                        ),
                    ],
                    onChanged: (v) => setDialogState(() {
                      if (v != null) columnName = v;
                    }),
                  ),
                CheckboxListTile(
                  value: _matchCase,
                  contentPadding: EdgeInsets.zero,
                  title: const Text('区分大小写'),
                  onChanged: (v) =>
                      setDialogState(() => _matchCase = v ?? false),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('全部替换'),
            ),
          ],
        ),
      ),
    );
    if (apply != true || !mounted) {
      find.dispose();
      replacement.dispose();
      return;
    }
    final query = find.text;
    final replacementText = replacement.text;
    find.dispose();
    replacement.dispose();
    if (query.isEmpty) return;
    var count = 0;
    setState(() {
      _findText = query;
      _replaceText = replacementText;
      for (final row in _rows) {
        final targets = wholeTable
            ? _columns
            : _columns.where((c) => c['name'] == columnName);
        for (final c in targets) {
          final key = c['name'] as String;
          final value = row[key];
          if (value is! String ||
              _columns
                  .where(
                    (c) => (c['pk'] as int?) != null && (c['pk'] as int) > 0,
                  )
                  .any((c) => c['name'] == key)) {
            continue;
          }
          final updated = _replaceOccurrences(
            value,
            query,
            replacementText,
            _matchCase,
          );
          if (updated != value) {
            count += _occurrenceCount(value, query, _matchCase);
            row[key] = updated;
          }
        }
      }
      _activeMatch = 0;
    });
    _captureCurrentDraft();
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('已替换 $count 处；另存为后写入文件')));
    }
  }

  String _replaceOccurrences(
    String value,
    String query,
    String replacement,
    bool matchCase,
  ) {
    if (matchCase) return value.replaceAll(query, replacement);
    final pattern = RegExp(RegExp.escape(query), caseSensitive: false);
    return value.replaceAll(pattern, replacement);
  }

  int _occurrenceCount(String value, String query, bool matchCase) =>
      (matchCase
              ? RegExp(RegExp.escape(query))
              : RegExp(RegExp.escape(query), caseSensitive: false))
          .allMatches(value)
          .length;

  Future<void> _editCell(int rowIndex, String column, Object? value) async {
    if (_isView) return;
    final controller = TextEditingController(text: value?.toString() ?? '');
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('编辑 $column'),
        content: TextField(
          controller: controller,
          autofocus: true,
          minLines: 1,
          maxLines: 8,
          decoration: const InputDecoration(hintText: '留空保存为空字符串；NULL 请使用专用按钮'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, '\u0000NULL'),
            child: const Text('设为 NULL'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('应用'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (!mounted || result == null) return;
    final changed = result == '\u0000NULL' ? null : result;
    setState(() {
      _rows[rowIndex][column] = changed;
      _captureCurrentDraft();
    });
  }

  Future<void> _saveCopy() async {
    final source = _path;
    if (source == null || _selected == null || _isView) return;
    _captureCurrentDraft();
    final destination = await FilePicker.platform.saveFile(
      dialogTitle: '保存数据库副本',
      fileName: '${p.basenameWithoutExtension(source)}_edited.sprk',
      type: FileType.custom,
      allowedExtensions: const ['sprk'],
    );
    if (destination == null || !mounted) return;
    final dst = destination.toLowerCase().endsWith('.sprk')
        ? destination
        : '$destination.sprk';
    if (await File(dst).exists()) {
      setState(() => _status = '目标文件已存在，请选择新文件名');
      return;
    }
    setState(() {
      _busy = true;
      _status = '正在写入并验证副本…';
    });
    String? copy;
    try {
      copy = await _service.copyToTemporary(
        source,
        prefix: 'superrack-export-',
      );
      final db = sqlite3.open(copy);
      try {
        db.execute('PRAGMA journal_mode=DELETE');
        db.execute('PRAGMA foreign_keys=ON');
        db.execute('BEGIN IMMEDIATE');
        try {
          for (final draft in _draftRowsByObject.entries) {
            final table = draft.key;
            final info = db.select('PRAGMA table_info(${_quote(table)})');
            final columns = info.map((row) => row['name'] as String).toList();
            final pk = info.where((r) => (r['pk'] as int) > 0).toList()
              ..sort((a, b) => (a['pk'] as int).compareTo(b['pk'] as int));
            if (pk.isEmpty) {
              throw SessionException('$table 没有主键，无法安全定位行并保存修改。');
            }
            final originalRows = db
                .select('SELECT * FROM ${_quote(table)}')
                .map((row) => Map<String, Object?>.from(row))
                .toList();
            if (draft.value.length != originalRows.length) {
              throw SessionException('$table 行数在编辑期间发生变化，请重新打开数据库。');
            }
            final sets = columns.map((c) => '${_quote(c)}=?').join(',');
            final where = pk
                .map((c) => '${_quote(c['name'] as String)} IS ?')
                .join(' AND ');
            for (var rowIndex = 0; rowIndex < draft.value.length; rowIndex++) {
              final row = draft.value[rowIndex];
              final values = columns.map((c) => row[c]).toList();
              final keys = pk
                  .map((c) => originalRows[rowIndex][c['name'] as String])
                  .toList();
              db.execute('UPDATE ${_quote(table)} SET $sets WHERE $where', [
                ...values,
                ...keys,
              ]);
            }
          }
          db.execute('COMMIT');
        } catch (_) {
          db.execute('ROLLBACK');
          rethrow;
        }
        final integrity = db
            .select('PRAGMA integrity_check')
            .first
            .values
            .first;
        if (integrity != 'ok') throw SessionException('完整性检查失败：$integrity');
        final foreignKeys = db.select('PRAGMA foreign_key_check');
        if (foreignKeys.isNotEmpty) {
          throw const SessionException('外键检查失败，修改没有保存。');
        }
      } finally {
        db.close();
      }
      final dstFile = File(dst);
      await dstFile.parent.create(recursive: true);
      final staged = File(
        p.join(
          dstFile.parent.path,
          '.${p.basename(dst)}.${DateTime.now().microsecondsSinceEpoch}.tmp',
        ),
      );
      try {
        if (await dstFile.exists()) {
          throw const SessionException('目标文件已存在，请选择新文件名。');
        }
        await File(copy).copy(staged.path);
        await SafeFilePublisher.publishNoReplace(staged, dstFile);
      } finally {
        if (await staged.exists()) await staged.delete();
      }
      if (mounted) {
        setState(() {
          _path = dst;
          _busy = false;
          _status = '副本已保存并通过 SQLite 完整性检查';
          _originalRows = _rows
              .map((row) => Map<String, Object?>.from(row))
              .toList();
          _draftRowsByObject.clear();
        });
        widget.onUnsavedChangesChanged?.call(false);
      }
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('已保存：$dst')));
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _status = '保存失败：$e';
        });
      }
    } finally {
      if (copy != null) await _service.deleteTemporaryCopy(copy);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope<Object?>(
    canPop: !_hasUnsavedChanges && !_busy,
    onPopInvokedWithResult: (didPop, _) => _handlePop(didPop),
    child: Scaffold(
      appBar: AppBar(
        title: const Text('SQLite 数据库浏览器'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => _handlePop(false),
        ),
        actions: [
          TextButton.icon(
            onPressed: _busy ? null : _open,
            icon: const Icon(Icons.folder_open),
            label: const Text('打开'),
          ),
          if (_selected != null && !_isView)
            TextButton.icon(
              onPressed: _busy ? null : _saveCopy,
              icon: const Icon(Icons.save_alt),
              label: const Text('另存为'),
            ),
        ],
      ),
      body: Column(
        children: [
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: Text(_path == null ? _status : p.basename(_path!)),
            subtitle: Text(_status),
          ),
          const Divider(height: 1),
          if (_showAdvancedWarning)
            MaterialBanner(
              leading: const Icon(Icons.warning_amber_rounded),
              content: const Text('高级功能：直接编辑数据库可能损坏文件，请确认了解操作影响后再修改。'),
              actions: [
                TextButton(
                  onPressed: () => setState(() => _showAdvancedWarning = false),
                  child: const Text('知道了'),
                ),
              ],
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                const Icon(Icons.search, size: 20),
                const SizedBox(width: 10),
                SizedBox(
                  width: 300,
                  child: TextField(
                    controller: _findController,
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: '查找',
                      suffixIcon: IconButton(
                        tooltip: '清除',
                        onPressed: () {
                          _findController.clear();
                          setState(() {
                            _findText = '';
                            _activeMatch = 0;
                          });
                        },
                        icon: const Icon(Icons.close),
                      ),
                    ),
                    onChanged: (value) => setState(() {
                      _findText = value;
                      _activeMatch = 0;
                    }),
                    onSubmitted: (_) => _navigateMatch(1),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: '上一个匹配项',
                  onPressed:
                      _findText.isEmpty ||
                          (_selected == null && _globalMatches.isEmpty)
                      ? null
                      : () => _navigateMatch(-1),
                  icon: const Icon(Icons.keyboard_arrow_up),
                ),
                IconButton(
                  tooltip: '下一个匹配项',
                  onPressed:
                      _findText.isEmpty ||
                          (_selected == null && _globalMatches.isEmpty)
                      ? null
                      : () => _navigateMatch(1),
                  icon: const Icon(Icons.keyboard_arrow_down),
                ),
                SizedBox(
                  width: 86,
                  child: Text(
                    _findText.isEmpty
                        ? ''
                        : _searchAllTables
                        ? '${_globalMatches.isEmpty ? 0 : _activeMatch + 1} / ${_globalMatches.length}'
                        : '${_selected == null || _matches.isEmpty ? 0 : _activeMatch + 1} / ${_matches.length}',
                    textAlign: TextAlign.center,
                  ),
                ),
                FilterChip(
                  label: const Text('Aa'),
                  selected: _matchCase,
                  tooltip: '区分大小写',
                  onSelected: (value) => setState(() {
                    _matchCase = value;
                    _activeMatch = 0;
                  }),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: _selected == null || _isView ? null : _showReplace,
                  icon: const Icon(Icons.find_replace),
                  label: const Text('替换'),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: _busy || _findText.isEmpty
                      ? null
                      : _findAcrossDatabase,
                  icon: const Icon(Icons.manage_search),
                  label: const Text('查找所有表'),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          if (_searchAllTables && _globalMatches.isNotEmpty)
            ListTile(
              dense: true,
              leading: const Icon(Icons.search),
              title: Text(
                '${_activeMatch + 1} / ${_globalMatches.length} · ${_globalMatches[_activeMatch].$1} · 第 ${_globalMatches[_activeMatch].$2 + 1} 行 · ${_globalMatches[_activeMatch].$3}',
              ),
              trailing: TextButton(
                onPressed: () => _activateGlobalMatch(_activeMatch),
                child: const Text('定位'),
              ),
            ),
          Expanded(
            child: Row(
              children: [
                SizedBox(
                  width: _sidebarWidth,
                  child: ListView(
                    children: [
                      for (final name in _objects)
                        ListTile(
                          selected: name == _selected,
                          leading: const Icon(Icons.table_chart_outlined),
                          title: Text(name, overflow: TextOverflow.ellipsis),
                          onTap: () => _selectObject(name),
                        ),
                    ],
                  ),
                ),
                MouseRegion(
                  cursor: SystemMouseCursors.resizeColumn,
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onHorizontalDragUpdate: (details) => setState(() {
                      _sidebarWidth = (_sidebarWidth + details.delta.dx).clamp(
                        160,
                        520,
                      );
                    }),
                    child: const SizedBox(
                      width: 8,
                      child: Center(child: VerticalDivider(width: 1)),
                    ),
                  ),
                ),
                Expanded(
                  child: _selected == null
                      ? const Center(child: Text('选择左侧数据表或视图'))
                      : _rows.isEmpty
                      ? Center(child: Text('$_selected 没有可显示的行'))
                      : Scrollbar(
                          thumbVisibility: true,
                          child: SingleChildScrollView(
                            controller: _tableScrollController,
                            scrollDirection: Axis.vertical,
                            child: SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              child: DataTable(
                                columns: [
                                  for (final c in _columns)
                                    DataColumn(
                                      label: Text(
                                        '${c['name']}  ${c['type'] ?? ''}',
                                      ),
                                    ),
                                ],
                                rows: [
                                  for (var i = 0; i < _rows.length; i++)
                                    DataRow(
                                      cells: [
                                        for (final c in _columns)
                                          (() {
                                            final column = c['name'] as String;
                                            final matchIndex = _searchAllTables
                                                ? _globalMatches.indexWhere(
                                                    (m) =>
                                                        m.$1 == _selected &&
                                                        m.$2 == i &&
                                                        m.$3 == column,
                                                  )
                                                : _matches.indexWhere(
                                                    (m) =>
                                                        m.$1 == i &&
                                                        m.$2 == column,
                                                  );
                                            final active =
                                                matchIndex >= 0 &&
                                                matchIndex == _activeMatch &&
                                                (_searchAllTables
                                                    ? _globalMatches.isNotEmpty
                                                    : _matches.isNotEmpty);
                                            return DataCell(
                                              Container(
                                                color: matchIndex >= 0
                                                    ? (active
                                                          ? Theme.of(context)
                                                                .colorScheme
                                                                .primaryContainer
                                                          : Theme.of(context)
                                                                .colorScheme
                                                                .tertiaryContainer
                                                                .withValues(
                                                                  alpha: .55,
                                                                ))
                                                    : null,
                                                constraints:
                                                    const BoxConstraints(
                                                      maxWidth: 260,
                                                    ),
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                      horizontal: 6,
                                                      vertical: 4,
                                                    ),
                                                child: Text(
                                                  _rows[i][column]
                                                          ?.toString() ??
                                                      'NULL',
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                ),
                                              ),
                                              onTap: () => _editCell(
                                                i,
                                                column,
                                                _rows[i][column],
                                              ),
                                            );
                                          })(),
                                      ],
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}
