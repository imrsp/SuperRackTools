import 'dart:ui' show AppExitResponse;

import 'package:path/path.dart' as p;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/rack.dart';
import '../services/session_service.dart';
import '../models/session_tools.dart';
import '../services/session_tools_service.dart';
import 'create_session_screen.dart';
import 'matrix_screen.dart';
import 'presets_screen.dart';
import 'database_screen.dart';
import '../widgets/editor_selection.dart';

String _withSprkExtension(String path) {
  final stripped = path.replaceFirst(
    RegExp(r'(?:\.sprk)+$', caseSensitive: false),
    '.sprk',
  );
  return stripped.toLowerCase().endsWith('.sprk') ? stripped : '$path.sprk';
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.themeMode,
    required this.onThemeModeChanged,
  });

  final ThemeMode themeMode;
  final ValueChanged<ThemeMode> onThemeModeChanged;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  static const _fileOpenChannel = MethodChannel(
    'tech.rslive.superracktools/files',
  );
  final _tools = const SessionToolsService();
  final _editors = <TextEditingController>[];
  final _lastText = <String>[];
  final _originalNamesScroll = ScrollController();
  final _newNamesScroll = ScrollController();
  bool _syncingNameScroll = false;
  final _rowKeys = <String, GlobalKey>{};
  final Map<int, Map<int, String>> _nameDrafts = {};
  final Map<int, List<Rack>> _racksBySnapshot = {};
  final Map<int, List<TextEditingController>> _editorsBySnapshot = {};
  final Map<Rack, int> _snapshotForRack = {};
  final Set<String> _selectedRackKeys = {};
  final Map<int, MatrixEditDraft> _matrixDrafts = {};
  List<Rack> _racks = const [];
  List<SessionSnapshot> _snapshots = const [];
  SessionSnapshot? _selectedSnapshot;
  String? _source;
  String _status = '选择一个 .sprk 工程文件，开始编辑';
  bool? _dragSelectionTarget;
  bool _busy = false;
  int _editorGeneration = 0;
  PresetEditDraft? _presetDraft;
  final List<EditorCommand> _undoStack = [];
  final List<EditorCommand> _redoStack = [];
  bool _recordingHistory = false;
  int _snapshotMode = 0; // 0=current, 1=all, 2=specified
  bool get _allSnapshots => _snapshotMode == 1;
  int _editorPage = 0;
  bool _selectionDrag = false;
  Offset? _pendingSelectionDown;
  Rack? _pendingSelectionRack;
  final FocusNode _historyFocus = FocusNode();
  static const Map<ShortcutActivator, Intent> _historyShortcuts = {
    SingleActivator(LogicalKeyboardKey.keyZ, control: true): _UndoIntent(),
    SingleActivator(LogicalKeyboardKey.keyZ, meta: true): _UndoIntent(),
    SingleActivator(LogicalKeyboardKey.keyZ, control: true, shift: true):
        _RedoIntent(),
    SingleActivator(LogicalKeyboardKey.keyZ, meta: true, shift: true):
        _RedoIntent(),
    SingleActivator(LogicalKeyboardKey.keyY, control: true): _RedoIntent(),
    SingleActivator(LogicalKeyboardKey.keyY, meta: true): _RedoIntent(),
    SingleActivator(LogicalKeyboardKey.escape): _ExitSelectionIntent(),
  };
  Map<String, String>? _pendingNameHistoryBefore;
  bool _nameHistoryScheduled = false;
  bool _databaseHasPendingEdits = false;
  bool _exitPromptOpen = false;
  bool get _hasPendingEdits =>
      _nameDrafts.isNotEmpty ||
      _matrixDrafts.isNotEmpty ||
      (_presetDraft?.hasChanges ?? false);

  @override
  Future<AppExitResponse> didRequestAppExit() async {
    if (!_hasPendingEdits && !_databaseHasPendingEdits) {
      return AppExitResponse.exit;
    }
    if (_busy || _exitPromptOpen || !mounted) return AppExitResponse.cancel;
    _exitPromptOpen = true;
    try {
      final discard = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          title: const Text('退出 SuperRackTools？'),
          content: const Text('当前有未保存的修改。退出后这些修改将丢失。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('继续编辑'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('放弃并退出'),
            ),
          ],
        ),
      );
      return mounted && discard == true
          ? AppExitResponse.exit
          : AppExitResponse.cancel;
    } finally {
      _exitPromptOpen = false;
    }
  }

  void _onDatabasePendingEditsChanged(bool hasChanges) {
    if (!mounted || _databaseHasPendingEdits == hasChanges) return;
    setState(() => _databaseHasPendingEdits = hasChanges);
  }

  int get _changeCount {
    var count = 0;
    for (final snapshot in _snapshots) {
      final originalNames = _nameDrafts[snapshot.id] ?? const {};
      count += originalNames.length;
      final matrix = _matrixDrafts[snapshot.id];
      if (matrix != null) {
        count +=
            matrix.rackOn.length +
            matrix.rackRecallSafe.length +
            matrix.pluginBypass.length +
            matrix.pluginRecallSafe.length;
      }
    }
    final preset = _presetDraft;
    if (preset != null) {
      count += <int>{
        ...preset.renames.keys,
        ...preset.duplicateIds,
        ...preset.deleteIds,
        ...preset.importedXmlById.keys,
      }.length;
      if (preset.reordered) count++;
    }
    return count;
  }

  void _recordCommand(String label, VoidCallback undo, VoidCallback redo) {
    if (_pendingNameHistoryBefore != null) _commitPendingNameHistory();
    if (_recordingHistory) return;
    _undoStack.add(EditorCommand(label: label, undo: undo, redo: redo));
    _redoStack.clear();
    if (mounted) setState(() {});
  }

  void _undo() {
    if (_pendingNameHistoryBefore != null) _commitPendingNameHistory();
    if (_undoStack.isEmpty || _busy) return;
    final command = _undoStack.removeLast();
    _recordingHistory = true;
    command.undo();
    _recordingHistory = false;
    _redoStack.add(command);
    setState(() {});
  }

  void _redo() {
    if (_pendingNameHistoryBefore != null) _commitPendingNameHistory();
    if (_redoStack.isEmpty || _busy) return;
    final command = _redoStack.removeLast();
    _recordingHistory = true;
    command.redo();
    _recordingHistory = false;
    _undoStack.add(command);
    setState(() {});
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _originalNamesScroll.addListener(
      () => _syncNameScroll(_originalNamesScroll, _newNamesScroll),
    );
    _newNamesScroll.addListener(
      () => _syncNameScroll(_newNamesScroll, _originalNamesScroll),
    );
    _fileOpenChannel.setMethodCallHandler(_handleFileOpenCall);
    _drainPendingFiles();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _fileOpenChannel.setMethodCallHandler(null);
    _disposeEditors();
    _historyFocus.dispose();
    _originalNamesScroll.dispose();
    _newNamesScroll.dispose();
    super.dispose();
  }

  void _disposeEditors() {
    final editors = <TextEditingController>{..._editors};
    for (final list in _editorsBySnapshot.values) {
      editors.addAll(list);
    }
    for (final editor in editors) {
      editor.dispose();
    }
    _editors.clear();
    _editorsBySnapshot.clear();
  }

  void _syncNameScroll(ScrollController from, ScrollController to) {
    if (_syncingNameScroll || !from.hasClients || !to.hasClients) return;
    _syncingNameScroll = true;
    final max = to.position.maxScrollExtent;
    try {
      to.jumpTo(from.offset.clamp(0, max));
    } finally {
      _syncingNameScroll = false;
    }
  }

  Future<void> _open() async {
    final file = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['sprk'],
    );
    final path = file?.files.single.path;
    if (!mounted || path == null) return;
    await _load(path);
  }

  Future<void> _handleFileOpenCall(MethodCall call) async {
    if (call.method == 'openFile' && call.arguments is String) {
      await _load(call.arguments as String);
    }
  }

  Future<void> _drainPendingFiles() async {
    try {
      final paths = await _fileOpenChannel.invokeListMethod<String>(
        'drainOpenFiles',
      );
      if (paths != null && paths.isNotEmpty) await _load(paths.last);
    } on MissingPluginException {
      // The Windows runner does not yet register file-open associations.
    } on PlatformException catch (e) {
      if (mounted) _message('无法打开文件', e.message ?? e.code);
    }
  }

  Future<void> _load(
    String path, {
    bool afterSave = false,
    bool exitEditorOnCancel = false,
  }) async {
    if (!mounted) return;
    if (!afterSave && _hasPendingEdits) {
      final discard = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('丢弃未保存修改？'),
          content: const Text('当前编辑区的修改尚未保存。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('继续编辑'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('丢弃并打开'),
            ),
          ],
        ),
      );
      if (!mounted || discard != true) {
        if (mounted && discard == false && exitEditorOnCancel) {
          Navigator.of(context).pop();
        }
        return;
      }
    }
    setState(() {
      _busy = true;
      _status = '正在安全读取会话…';
    });
    try {
      final snapshots = await _tools.readSnapshots(path);
      final available = snapshots.where((s) => s.rackCount > 0).toList();
      if (available.isEmpty) {
        throw const SessionException('会话中没有可编辑的 Snapshot。');
      }
      final selected = available.firstWhere(
        (s) => s.number == -1,
        orElse: () => available.first,
      );
      final racks = await _tools.readSnapshotRacks(path, selected.id);
      if (!mounted) return;
      _disposeEditors();
      _racksBySnapshot.clear();
      _editorsBySnapshot.clear();
      _snapshotForRack.clear();
      _editors.clear();
      setState(() {
        _racksBySnapshot[selected.id] = racks;
        _snapshotForRack
          ..clear()
          ..addEntries(racks.map((rack) => MapEntry(rack, selected.id)));
        _racks = racks;
        _source = path;
        _nameDrafts.clear();
        _matrixDrafts.clear();
        _presetDraft = null;
        _undoStack.clear();
        _redoStack.clear();
        _snapshotMode = 0;
        _editorGeneration++;
        _snapshots = available;
        _selectedSnapshot = selected;
        _lastText
          ..clear()
          ..addAll(racks.map((r) => r.name));
        _rowKeys
          ..clear()
          ..addEntries(
            racks.map((r) => MapEntry(_rackSelectionKey(r), GlobalKey())),
          );
        _editors.addAll(racks.map((r) => TextEditingController(text: r.name)));
        _editorsBySnapshot[selected.id] = List.of(_editors);
        _busy = false;
        _status = '已载入 ${racks.length} 个 Rack · 编辑后保存为新副本';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = '读取失败';
      });
      _message('无法打开文件', '$e');
    }
  }

  Future<void> _selectSnapshot(int id, {bool captureDraft = true}) async {
    final source = _source;
    final snapshot = _snapshots.where((s) => s.id == id).firstOrNull;
    if (source == null || snapshot == null || _busy) return;
    _commitPendingNameHistory();
    if (captureDraft) _captureCurrentNameDraft();
    setState(() => _busy = true);
    try {
      final racks = await _tools.readSnapshotRacks(source, id);
      if (!mounted) return;
      setState(() {
        _racksBySnapshot[id] = racks;
        _snapshotForRack.addEntries(racks.map((rack) => MapEntry(rack, id)));
        _racks = racks;
        _selectedSnapshot = snapshot;
        _lastText
          ..clear()
          ..addAll(racks.map((r) => r.name));
        _rowKeys
          ..clear()
          ..addEntries(
            racks.map((r) => MapEntry(_rackSelectionKey(r), GlobalKey())),
          );
        final snapshotDraft = _nameDrafts[id] ?? const <int, String>{};
        final cachedEditors = _editorsBySnapshot[id];
        _editors
          ..clear()
          ..addAll(
            cachedEditors != null && cachedEditors.length == racks.length
                ? cachedEditors
                : racks.map(
                    (r) => TextEditingController(
                      text: snapshotDraft[r.id] ?? r.name,
                    ),
                  ),
          );
        _editorsBySnapshot[id] = List.of(_editors);
        _lastText
          ..clear()
          ..addAll(_editors.map((editor) => editor.text));
        _busy = false;
        _status = '${snapshot.name} · ${racks.length} Racks';
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _status = '读取 Snapshot 失败：$error';
        });
      }
    }
  }

  void _onNameChanged(int index, String value) {
    if (_recordingHistory) {
      _lastText[index] = value;
      return;
    }
    final previous = _lastText[index];
    if (_pendingNameHistoryBefore == null) {
      final before = _captureVisibleNameValues();
      before[_nameHistoryKey(index)] = previous;
      _pendingNameHistoryBefore = before;
    }
    _lastText[index] = value;
    final sourceKey = _rackSelectionKey(_racks[index]);
    if (!_selectedRackKeys.contains(sourceKey) ||
        _selectedRackKeys.length < 2) {
      _captureCurrentNameDraft();
      if (previous != value) _scheduleNameHistory();
      setState(() {});
      return;
    }
    var start = 0;
    while (start < previous.length &&
        start < value.length &&
        previous[start] == value[start]) {
      start++;
    }
    var oldEnd = previous.length;
    var newEnd = value.length;
    while (oldEnd > start &&
        newEnd > start &&
        previous[oldEnd - 1] == value[newEnd - 1]) {
      oldEnd--;
      newEnd--;
    }
    final insertion = value.substring(start, newEnd);
    for (var row = 0; row < _racks.length; row++) {
      if (row == index ||
          !_selectedRackKeys.contains(_rackSelectionKey(_racks[row]))) {
        continue;
      }
      final current = _editors[row].text;
      final from = start.clamp(0, current.length);
      final to = oldEnd.clamp(from, current.length);
      final updated = current.replaceRange(from, to, insertion);
      _editors[row].value = TextEditingValue(
        text: updated,
        selection: TextSelection.collapsed(offset: from + insertion.length),
      );
      _lastText[row] = updated;
    }
    _captureCurrentNameDraft();
    _scheduleNameHistory();
    setState(() {});
  }

  String _nameHistoryKey(int index) =>
      '${_snapshotForRack[_racks[index]] ?? _selectedSnapshot?.id}:${_racks[index].id}';

  void _scheduleNameHistory() {
    if (_nameHistoryScheduled) return;
    _nameHistoryScheduled = true;
    Future<void>.delayed(const Duration(milliseconds: 650), () {
      if (!mounted) return;
      _commitPendingNameHistory();
    });
  }

  void _commitPendingNameHistory() {
    _nameHistoryScheduled = false;
    final before = _pendingNameHistoryBefore;
    _pendingNameHistoryBefore = null;
    if (before == null) return;
    final after = _captureVisibleNameValues();
    _recordCommand(
      '编辑通道名称',
      () => _applyNameValues(before),
      () => _applyNameValues(after),
    );
  }

  Map<String, String> _captureVisibleNameValues() => {
    for (var i = 0; i < _racks.length && i < _editors.length; i++)
      _nameHistoryKey(i): _editors[i].text,
  };

  void _applyNameValues(Map<String, String> values) {
    final affectedSnapshots = <int>{};
    for (final entry in values.entries) {
      final parts = entry.key.split(':');
      final snapshotId = int.tryParse(parts[0]);
      final rackId = int.tryParse(parts.last);
      if (rackId == null) continue;
      final targetSnapshot = snapshotId ?? _selectedSnapshot?.id;
      if (targetSnapshot != null) affectedSnapshots.add(targetSnapshot);
      final racks = targetSnapshot == null
          ? _racks
          : _racksBySnapshot[targetSnapshot] ?? _racks;
      final editors = targetSnapshot == null
          ? _editors
          : _editorsBySnapshot[targetSnapshot] ?? _editors;
      final index = racks.indexWhere((rack) => rack.id == rackId);
      if (index < 0 || index >= editors.length) continue;
      editors[index].text = entry.value;
      if (targetSnapshot == _selectedSnapshot?.id && index < _lastText.length) {
        _lastText[index] = entry.value;
      }
    }
    if (_allSnapshots) {
      _captureCurrentNameDraft();
    } else {
      for (final snapshotId in affectedSnapshots) {
        _captureNameDraftForSnapshot(snapshotId);
      }
    }
    if (mounted) setState(() {});
  }

  void _captureCurrentNameDraft() {
    if (_allSnapshots) {
      for (final snapshotId in _racksBySnapshot.keys) {
        _captureNameDraftForSnapshot(snapshotId);
      }
      return;
    }
    final snapshot = _selectedSnapshot;
    if (snapshot == null) return;
    _captureNameDraftForSnapshot(snapshot.id);
  }

  void _captureNameDraftForSnapshot(int snapshotId) {
    final racks = _racksBySnapshot[snapshotId];
    final editors = _editorsBySnapshot[snapshotId];
    if (racks == null || editors == null || racks.length != editors.length) {
      return;
    }
    final changes = <int, String>{};
    for (var i = 0; i < racks.length; i++) {
      final value = editors[i].text.trim();
      if (value != racks[i].name) changes[racks[i].id] = value;
    }
    if (changes.isEmpty) {
      _nameDrafts.remove(snapshotId);
    } else {
      _nameDrafts[snapshotId] = changes;
    }
  }

  Future<void> _loadAllSnapshotNames() async {
    if (_source == null) return;
    _captureCurrentNameDraft();
    setState(() => _busy = true);
    try {
      final all = <int, List<Rack>>{};
      for (final snapshot in _snapshots) {
        all[snapshot.id] = await _tools.readSnapshotRacks(
          _source!,
          snapshot.id,
        );
      }
      if (!mounted) return;
      for (final editors in _editorsBySnapshot.values) {
        for (final editor in editors) {
          editor.dispose();
        }
      }
      _editorsBySnapshot.clear();
      _snapshotForRack
        ..clear()
        ..addEntries(
          all.entries.expand(
            (entry) => entry.value.map((rack) => MapEntry(rack, entry.key)),
          ),
        );
      for (final entry in all.entries) {
        _editorsBySnapshot[entry.key] = entry.value
            .map(
              (rack) => TextEditingController(
                text: _nameDrafts[entry.key]?[rack.id] ?? rack.name,
              ),
            )
            .toList();
      }
      final combined = <Rack>[];
      final combinedEditors = <TextEditingController>[];
      for (final snapshot in _snapshots) {
        combined.addAll(all[snapshot.id] ?? const []);
        combinedEditors.addAll(_editorsBySnapshot[snapshot.id] ?? const []);
      }
      setState(() {
        _racksBySnapshot
          ..clear()
          ..addAll(all);
        _racks = combined;
        _editors
          ..clear()
          ..addAll(combinedEditors);
        _lastText
          ..clear()
          ..addAll(combinedEditors.map((editor) => editor.text));
        _rowKeys
          ..clear()
          ..addEntries(
            combined.map(
              (rack) => MapEntry(_rackSelectionKey(rack), GlobalKey()),
            ),
          );
        _busy = false;
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _snapshotMode = 0;
        });
      }
      _message('读取全部快照失败', '$error');
    }
  }

  Rack? _rowAt(Offset position) {
    for (final rack in _racks) {
      final render = _rowKeys[_rackSelectionKey(rack)]?.currentContext
          ?.findRenderObject();
      if (render is! RenderBox || !render.hasSize) continue;
      final origin = render.localToGlobal(Offset.zero);
      if (position.dx >= origin.dx &&
          position.dx <= origin.dx + render.size.width &&
          position.dy >= origin.dy &&
          position.dy <= origin.dy + render.size.height) {
        return rack;
      }
    }
    return null;
  }

  String _rackSelectionKey(Rack rack) {
    if (!_allSnapshots) return 'rack:${rack.id}';
    final snapshotId = _snapshotForRack[rack] ?? _selectedSnapshot?.id;
    return '$snapshotId:${rack.id}';
  }

  void _setRackSelection(int id, bool selected, {String? selectionKey}) {
    final rack = _racks.firstWhere(
      (item) =>
          item.id == id &&
          (selectionKey == null || _rackSelectionKey(item) == selectionKey),
    );
    final key = selectionKey ?? _rackSelectionKey(rack);
    setState(() {
      if (selected) {
        _selectedRackKeys.add(key);
      } else {
        _selectedRackKeys.remove(key);
      }
      _captureCurrentNameDraft();
    });
  }

  void _beginSelectionDrag(Rack rack) {
    _selectionDrag = true;
    _dragSelectionTarget = !_selectedRackKeys.contains(_rackSelectionKey(rack));
  }

  void _finishSelectionDrag() {
    if (!_selectionDrag) return;
    _selectionDrag = false;
    _dragSelectionTarget = null;
  }

  void _applyRackSelection(Set<String> selection) {
    setState(() {
      _selectedRackKeys
        ..clear()
        ..addAll(selection);
    });
  }

  Set<String> _selectionForVisibleRacks(Iterable<Rack> racks) =>
      racks.map(_rackSelectionKey).toSet();

  Future<void> _setSnapshotMode(int mode) async {
    if (_snapshotMode == mode || _selectedSnapshot == null) return;
    _commitPendingNameHistory();
    _captureCurrentNameDraft();
    setState(() => _snapshotMode = mode);
    if (mode == 1) {
      await _loadAllSnapshotNames();
    } else if (mode == 0) {
      final active = _snapshots.firstWhere(
        (snapshot) => snapshot.number == -1,
        orElse: () => _snapshots.first,
      );
      await _selectSnapshot(active.id, captureDraft: false);
    } else {
      final named = _snapshots
          .where((snapshot) => snapshot.number != -1)
          .toList();
      if (named.isNotEmpty) {
        await _selectSnapshot(named.first.id, captureDraft: false);
      }
    }
  }

  Widget _snapshotControls() {
    final selected = _selectedSnapshot;
    return Row(
      children: [
        const Text('编辑模式', style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(width: 12),
        SegmentedButton<int>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: 0, label: Text('当前快照')),
            ButtonSegment(
              value: 1,
              label: Tooltip(
                message: '全部快照可能覆盖每个 Snapshot 中已有的设置。',
                child: Text('全部快照'),
              ),
            ),
            ButtonSegment(value: 2, label: Text('指定快照')),
          ],
          selected: {_snapshotMode},
          onSelectionChanged: _busy
              ? null
              : (value) => _setSnapshotMode(value.first),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 170,
          height: 48,
          child: _snapshotMode == 2
              ? DropdownButton<int>(
                  isExpanded: true,
                  value:
                      _snapshots.any(
                        (snapshot) =>
                            snapshot.id == selected?.id &&
                            snapshot.number != -1,
                      )
                      ? selected?.id
                      : null,
                  hint: const Text('选择快照'),
                  items: [
                    for (final snapshot in _snapshots.where(
                      (snapshot) => snapshot.number != -1,
                    ))
                      DropdownMenuItem(
                        value: snapshot.id,
                        child: Text(snapshot.name),
                      ),
                  ],
                  onChanged: _busy
                      ? null
                      : (id) {
                          if (id != null) _selectSnapshot(id);
                        },
                )
              : const SizedBox.shrink(),
        ),
      ],
    );
  }

  Future<void> _batchRename(String operation) async {
    final primary = TextEditingController();
    final secondary = TextEditingController();
    final result = await showDialog<(String, String)?>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(operation),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: primary,
              autofocus: true,
              decoration: InputDecoration(
                labelText: operation == '查找替换'
                    ? '查找'
                    : operation == '添加编号'
                    ? '起始编号'
                    : '文字',
              ),
            ),
            if (operation == '查找替换')
              TextField(
                controller: secondary,
                decoration: const InputDecoration(labelText: '替换为'),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(context, (primary.text, secondary.text)),
            child: const Text('应用'),
          ),
        ],
      ),
    );
    primary.dispose();
    secondary.dispose();
    if (result == null) return;
    final indices = [
      for (var i = 0; i < _racks.length; i++)
        if (_selectedRackKeys.isEmpty ||
            _selectedRackKeys.contains(_rackSelectionKey(_racks[i])))
          i,
    ];
    final before = _captureVisibleNameValues();
    setState(() {
      for (var n = 0; n < indices.length; n++) {
        final i = indices[n];
        final old = _editors[i].text;
        final updated = switch (operation) {
          '添加前缀' => '${result.$1}$old',
          '添加后缀' => '$old${result.$1}',
          '添加编号' =>
            '$old ${int.tryParse(result.$1) == null ? n + 1 : int.parse(result.$1) + n}',
          _ => result.$1.isEmpty ? old : old.replaceAll(result.$1, result.$2),
        };
        _editors[i].value = TextEditingValue(
          text: updated,
          selection: TextSelection.collapsed(offset: updated.length),
        );
        _lastText[i] = updated;
      }
      _captureCurrentNameDraft();
    });
    final after = _captureVisibleNameValues();
    _recordCommand(
      operation,
      () => _applyNameValues(before),
      () => _applyNameValues(after),
    );
  }

  Future<void> _createNewSession() async {
    final result = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => const CreateSessionScreen()),
    );
    if (result != null && mounted) await _load(result);
  }

  void _onMatrixDraftsChanged(List<MatrixEditDraft> drafts) {
    setState(() {
      _matrixDrafts
        ..clear()
        ..addEntries(drafts.map((draft) => MapEntry(draft.snapshotId, draft)));
    });
  }

  void _onMatrixCommand(EditorCommand command) =>
      _recordCommand(command.label, command.undo, command.redo);

  void _onPresetDraftChanged(PresetEditDraft draft) {
    setState(() => _presetDraft = draft.hasChanges ? draft : null);
  }

  Future<void> _save() async {
    final source = _source;
    if (source == null || !_hasPendingEdits) return;
    _commitPendingNameHistory();
    final summary = _changeSummary();
    final proceed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('保存修改摘要'),
        content: SizedBox(
          width: 440,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '共 $_changeCount 项修改将写入新的 .sprk 副本。',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 12),
              ...summary.entries.map(
                (e) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    children: [
                      Expanded(child: Text(e.key)),
                      Text(
                        '${e.value} 项',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              const Text('下一步将打开系统窗口选择保存位置。', style: TextStyle(fontSize: 12)),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('继续编辑'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(context, true),
            icon: const Icon(Icons.folder_open_rounded),
            label: const Text('选择保存位置'),
          ),
        ],
      ),
    );
    if (!mounted || proceed != true) return;
    final selected = await FilePicker.platform.saveFile(
      dialogTitle: '保存 SuperRack 文件副本',
      fileName: '${p.basenameWithoutExtension(source)}_renamed',
      type: FileType.custom,
      allowedExtensions: const ['sprk'],
      // Native save panels may not support accessory widgets; summary is shown
      // in the confirmation dialog immediately before opening the path picker.
    );
    if (!mounted || selected == null) return;
    final destination = _withSprkExtension(selected);
    setState(() {
      _busy = true;
      _status = '正在保存并验证数据库…';
    });
    try {
      _captureCurrentNameDraft();
      await _tools.saveCombinedEdits(
        source: source,
        destination: destination,
        namesBySnapshot: Map<int, Map<int, String>>.unmodifiable(
          _nameDrafts.map(
            (id, names) => MapEntry(id, Map<int, String>.unmodifiable(names)),
          ),
        ),
        matrixDrafts: List.unmodifiable(_matrixDrafts.values),
        presets: _presetDraft,
      );
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = '已保存并通过完整性检查';
      });
      await _load(destination, afterSave: true);
      if (mounted) _message('全部修改已保存', destination);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = '保存失败';
      });
      _message('未能保存会话', '$e');
    }
  }

  Map<String, int> _changeSummary() {
    final names = _nameDrafts.values.fold<int>(
      0,
      (sum, draft) => sum + draft.length,
    );
    final matrix = _matrixDrafts.values.fold<int>(
      0,
      (sum, d) =>
          sum +
          d.rackOn.length +
          d.rackRecallSafe.length +
          d.pluginBypass.length +
          d.pluginRecallSafe.length,
    );
    final preset = _presetDraft;
    final presetCount = preset == null
        ? 0
        : <int>{
                ...preset.renames.keys,
                ...preset.duplicateIds,
                ...preset.deleteIds,
                ...preset.importedXmlById.keys,
              }.length +
              (preset.reordered ? 1 : 0);
    return {'通道名称': names, '状态设置': matrix, '用户预设': presetCount};
  }

  Future<void> _pasteNames() async {
    final names = await showDialog<List<String>>(
      context: context,
      builder: (context) => BulkNamesDialog(
        initialNames: _editors.map((e) => e.text).toList(),
        rowCount: _racks.length,
      ),
    );
    if (!mounted) return;
    // The dialog's TextField owns Cmd+Z while it is open. Navigator restores
    // the pre-dialog focus when it closes, allowing the application-level
    // history shortcuts to resume without moving focus to the page root.
    if (names == null) return;
    final emptyIndex = names.indexWhere((e) => e.trim().isEmpty);
    if (names.length != _racks.length || emptyIndex >= 0) {
      _message(
        '名称列表有误',
        '需要 ${_racks.length} 行，当前 ${names.length} 行。${emptyIndex >= 0 ? '\n第 ${emptyIndex + 1} 行为空。' : ''}',
      );
      return;
    } else {
      final before = _captureVisibleNameValues();
      setState(() {
        for (var i = 0; i < names.length; i++) {
          _editors[i].text = names[i].trim();
          _lastText[i] = names[i].trim();
        }
        _captureCurrentNameDraft();
      });
      final after = _captureVisibleNameValues();
      _recordCommand(
        '批量粘贴通道名称',
        () => _applyNameValues(before),
        () => _applyNameValues(after),
      );
    }
  }

  void _message(String title, String detail) {
    if (!mounted) return;
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: SelectableText(detail),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final compactHeight = size.height < 760;
    return Shortcuts(
      shortcuts: _historyShortcuts,
      child: Actions(
        actions: <Type, Action<Intent>>{
          _UndoIntent: CallbackAction<_UndoIntent>(
            onInvoke: (_) {
              _undo();
              return null;
            },
          ),
          _RedoIntent: CallbackAction<_RedoIntent>(
            onInvoke: (_) {
              _redo();
              return null;
            },
          ),
          _ExitSelectionIntent: CallbackAction<_ExitSelectionIntent>(
            onInvoke: (_) {
              _clearSelection();
              return null;
            },
          ),
        },
        child: Focus(
          focusNode: _historyFocus,
          autofocus: true,
          child: Scaffold(
            body: SafeArea(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1320),
                  child: Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: 28,
                      vertical: compactHeight ? 12 : 24,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _header(),
                        SizedBox(height: compactHeight ? 8 : 14),
                        _fileCard(),
                        SizedBox(height: compactHeight ? 10 : 18),
                        Expanded(
                          child: _racks.isEmpty
                              ? _emptyState()
                              : Column(
                                  children: [
                                    _editorToolbar(),
                                    const SizedBox(height: 8),
                                    Expanded(child: _editorPageView()),
                                  ],
                                ),
                        ),
                        SizedBox(height: compactHeight ? 8 : 16),
                        _footer(),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _header() => Row(
    children: [
      Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primaryContainer,
          borderRadius: BorderRadius.circular(15),
        ),
        child: Icon(
          Icons.graphic_eq_rounded,
          color: Theme.of(context).colorScheme.onPrimaryContainer,
        ),
      ),
      const SizedBox(width: 14),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'SUPERRACKTOOLS BY SIMON@RSLIVETECH',
              style: TextStyle(
                color: Theme.of(context).colorScheme.primary,
                letterSpacing: 2.2,
                fontSize: 11,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 3),
            const Text(
              'SuperRack 文件整理工具',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
            ),
          ],
        ),
      ),
      IconButton(
        tooltip: '关于',
        icon: const Icon(Icons.info_outline_rounded),
        onPressed: _showAbout,
      ),
      PopupMenuButton<ThemeMode>(
        tooltip: '外观',
        initialValue: widget.themeMode,
        onSelected: widget.onThemeModeChanged,
        icon: Icon(_themeIcon(widget.themeMode)),
        itemBuilder: (context) => [
          _themeMenuItem(
            ThemeMode.system,
            Icons.brightness_auto_rounded,
            '跟随系统',
          ),
          _themeMenuItem(ThemeMode.light, Icons.light_mode_rounded, '浅色'),
          _themeMenuItem(ThemeMode.dark, Icons.dark_mode_rounded, '深色'),
        ],
      ),
      IconButton(
        tooltip: '新建工程',
        icon: const Icon(Icons.add_box_outlined),
        onPressed: _busy ? null : _createNewSession,
      ),
      IconButton(
        tooltip: 'SQLite 数据库浏览器（高级）',
        icon: const Icon(Icons.storage_rounded),
        onPressed: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => DatabaseScreen(
              initialPath: _source,
              onUnsavedChangesChanged: _onDatabasePendingEditsChanged,
              onPathChanged: (path) => _load(path, exitEditorOnCancel: true),
            ),
          ),
        ),
      ),
    ],
  );

  Future<void> _showAbout() => showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('关于 SuperRackTools'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _AboutInfoRow(label: '开发者', value: 'Simon Rao'),
            const SizedBox(height: 12),
            const _AboutInfoRow(label: '版本', value: 'v2.0.0'),
            const SizedBox(height: 12),
            _AboutLinkRow(
              label: 'GitHub',
              value: 'imrsp/SuperRackTools',
              icon: Icons.open_in_new_rounded,
              onPressed: () => _openAboutLink(
                Uri.https('github.com', '/imrsp/SuperRackTools'),
              ),
            ),
            const SizedBox(height: 12),
            _AboutLinkRow(
              label: '邮箱',
              value: 'i@rsp.ink',
              icon: Icons.mail_outline_rounded,
              onPressed: () =>
                  _openAboutLink(Uri(scheme: 'mailto', path: 'i@rsp.ink')),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('关闭'),
        ),
      ],
    ),
  );

  Future<void> _openAboutLink(Uri uri) async {
    final opened = await launchUrl(uri);
    if (!opened && mounted) _message('无法打开', uri.toString());
  }

  IconData _themeIcon(ThemeMode mode) => switch (mode) {
    ThemeMode.system => Icons.brightness_auto_rounded,
    ThemeMode.light => Icons.light_mode_rounded,
    ThemeMode.dark => Icons.dark_mode_rounded,
  };

  PopupMenuItem<ThemeMode> _themeMenuItem(
    ThemeMode mode,
    IconData icon,
    String label,
  ) => PopupMenuItem(
    value: mode,
    child: Row(
      children: [
        Icon(icon, size: 18),
        const SizedBox(width: 12),
        Expanded(child: Text(label)),
        if (widget.themeMode == mode) const Icon(Icons.check_rounded, size: 18),
      ],
    ),
  );

  Widget _fileCard() => Card(
    child: Padding(
      padding: const EdgeInsets.all(18),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.secondaryContainer,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Icon(
              Icons.audio_file_rounded,
              color: Theme.of(context).colorScheme.onSecondaryContainer,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('当前会话', style: TextStyle(fontSize: 12)),
                const SizedBox(height: 4),
                Text(
                  _source == null ? '尚未选择文件' : p.basename(_source!),
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          OutlinedButton.icon(
            onPressed: _busy ? null : _open,
            icon: const Icon(Icons.upload_file_rounded),
            label: const Text('打开文件'),
          ),
        ],
      ),
    ),
  );

  Widget _editorToolbar() => LayoutBuilder(
    builder: (context, constraints) {
      final navigation = SegmentedButton<int>(
        showSelectedIcon: false,
        segments: const [
          ButtonSegment(
            value: 0,
            label: Text('通道名称'),
            icon: Icon(Icons.drive_file_rename_outline_rounded),
          ),
          ButtonSegment(
            value: 1,
            label: Text('状态编辑'),
            icon: Icon(Icons.tune_rounded),
          ),
          ButtonSegment(
            value: 2,
            label: Text('用户预设'),
            icon: Icon(Icons.library_music_rounded),
          ),
        ],
        selected: {_editorPage},
        onSelectionChanged: (value) =>
            setState(() => _editorPage = value.first),
      );
      final history = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: _undoStack.isEmpty ? '撤销' : '撤销：${_undoStack.last.label}',
            onPressed: _undoStack.isEmpty ? null : _undo,
            icon: const Icon(Icons.undo_rounded),
          ),
          IconButton(
            tooltip: _redoStack.isEmpty ? '重做' : '重做：${_redoStack.last.label}',
            onPressed: _redoStack.isEmpty ? null : _redo,
            icon: const Icon(Icons.redo_rounded),
          ),
        ],
      );
      if (constraints.maxWidth < 1120) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(child: _snapshotControls()),
                history,
              ],
            ),
            Center(child: navigation),
          ],
        );
      }
      return Row(
        children: [
          Expanded(child: _snapshotControls()),
          navigation,
          const SizedBox(width: 12),
          history,
        ],
      );
    },
  );

  Widget _editorPageView() => IndexedStack(
    index: _editorPage,
    children: [
      _rackWorkspace(),
      MatrixScreen(
        key: ValueKey('matrix-$_editorGeneration'),
        sessionPath: _source!,
        onDraftChanged: _onMatrixDraftsChanged,
        snapshots: _snapshots,
        selectedSnapshotId: _selectedSnapshot?.id,
        allSnapshots: _allSnapshots,
        onCommand: _onMatrixCommand,
      ),
      PresetsScreen(
        key: ValueKey('presets-$_editorGeneration'),
        sessionPath: _source!,
        onDraftChanged: _onPresetDraftChanged,
        onCommand: _onMatrixCommand,
      ),
    ],
  );

  Widget _emptyState() => Card(
    child: Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.queue_music_rounded,
              size: 52,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(height: 18),
            const Text(
              '从一个干净的工作区开始',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              '会话以只读方式载入；保存时生成经过校验的新副本。',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: _busy ? null : _open,
              icon: const Icon(Icons.folder_open_rounded),
              label: const Text('选择 .sprk 文件'),
            ),
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: _busy ? null : _createNewSession,
              icon: const Icon(Icons.add_rounded),
              label: const Text('新建工程'),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _rackWorkspace() {
    final panes = [
      _namePane('原名称', '', true),
      _namePane('新名称', '点击/拖动多选，可粘贴 Excel 单列内容', false),
    ];
    final workspaceActions = [
      if (_racks.isNotEmpty)
        OutlinedButton.icon(
          onPressed: _busy ? null : _pasteNames,
          icon: const Icon(Icons.content_paste_rounded, size: 18),
          label: const Text('批量粘贴'),
        ),
      if (_racks.isNotEmpty) ...[
        OutlinedButton.icon(
          onPressed: _busy ? null : () => _batchRename('添加前缀'),
          icon: const Icon(Icons.vertical_align_top_rounded, size: 18),
          label: const Text('添加前缀'),
        ),
        OutlinedButton.icon(
          onPressed: _busy ? null : () => _batchRename('添加后缀'),
          icon: const Icon(Icons.vertical_align_bottom_rounded, size: 18),
          label: const Text('添加后缀'),
        ),
        OutlinedButton.icon(
          onPressed: _busy ? null : () => _batchRename('添加编号'),
          icon: const Icon(Icons.format_list_numbered_rounded, size: 18),
          label: const Text('添加编号'),
        ),
        OutlinedButton.icon(
          onPressed: _busy ? null : () => _batchRename('查找替换'),
          icon: const Icon(Icons.find_replace_rounded, size: 18),
          label: const Text('查找替换'),
        ),
      ],
    ];
    return Card(
      margin: const EdgeInsets.only(top: 2),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            EditorActionBar(
              actions: workspaceActions,
              selection: _selectionToolbar(),
            ),
            const Divider(height: 1),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: panes[0]),
                  const SizedBox(width: 14),
                  Expanded(child: panes[1]),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _namePane(String title, String hint, bool original) => Card(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              if (hint.isNotEmpty)
                Text(
                  hint,
                  style: TextStyle(
                    fontSize: 11,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Expanded(
            child: Listener(
              onPointerDown: original
                  ? null
                  : (event) {
                      if (event.kind != PointerDeviceKind.mouse ||
                          (event.buttons & kPrimaryMouseButton) == 0) {
                        return;
                      }
                      final row = _rowAt(event.position);
                      _pendingSelectionDown = event.position;
                      _pendingSelectionRack = row;
                    },
              onPointerMove: original
                  ? null
                  : (event) {
                      if ((event.buttons & kPrimaryMouseButton) == 0) {
                        return;
                      }
                      if (!_selectionDrag &&
                          _pendingSelectionDown != null &&
                          (event.position - _pendingSelectionDown!).distance >
                              5) {
                        final initial = _pendingSelectionRack;
                        if (initial != null) _beginSelectionDrag(initial);
                      }
                      if (!_selectionDrag) return;
                      final row = _rowAt(event.position);
                      if (row != null && _dragSelectionTarget != null) {
                        _setRackSelection(
                          row.id,
                          _dragSelectionTarget!,
                          selectionKey: _rackSelectionKey(row),
                        );
                      }
                    },
              onPointerUp: (_) {
                _finishSelectionDrag();
                _dragSelectionTarget = null;
                _pendingSelectionDown = null;
                _pendingSelectionRack = null;
              },
              onPointerCancel: (_) {
                _finishSelectionDrag();
                _dragSelectionTarget = null;
                _pendingSelectionDown = null;
                _pendingSelectionRack = null;
              },
              child: ListView.separated(
                controller: original ? _originalNamesScroll : _newNamesScroll,
                itemCount: _racks.length,
                separatorBuilder: (_, __) => const SizedBox(height: 7),
                itemBuilder: (context, i) => SizedBox(
                  height: 52,
                  child: Row(
                    children: [
                      SizedBox(
                        width: 56,
                        child: SelectableIndexBadge(
                          key: original
                              ? null
                              : _rowKeys[_rackSelectionKey(_racks[i])],
                          index: _racks[i].number.toString().padLeft(2, '0'),
                          selected: _selectedRackKeys.contains(
                            _rackSelectionKey(_racks[i]),
                          ),
                          onTap: original || _busy
                              ? null
                              : () => _toggleRackSelection(_racks[i].id),
                          width: 40,
                        ),
                      ),
                      Expanded(
                        child: original
                            ? Container(
                                height: 46,
                                alignment: Alignment.centerLeft,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 13,
                                ),
                                decoration: BoxDecoration(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.surfaceContainerHighest,
                                  borderRadius: BorderRadius.circular(13),
                                ),
                                child: Text(
                                  _racks[i].name,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              )
                            : Shortcuts(
                                shortcuts: _historyShortcuts,
                                child: TextField(
                                  controller: _editors[i],
                                  enabled: !_busy,
                                  decoration: const InputDecoration(
                                    isDense: true,
                                    contentPadding: EdgeInsets.symmetric(
                                      horizontal: 13,
                                      vertical: 13,
                                    ),
                                    hintText: '输入通道名称',
                                  ),
                                  onChanged: (value) =>
                                      _onNameChanged(i, value),
                                ),
                              ),
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
  );

  void _toggleRackSelection(int id) {
    final rack = _racks.firstWhere((item) => item.id == id);
    final key = _rackSelectionKey(rack);
    _setRackSelection(id, !_selectedRackKeys.contains(key), selectionKey: key);
  }

  Widget _selectionToolbar() => EditorSelectionToolbar(
    count: _selectedRackKeys.length,
    onSelectAll: () => _applyRackSelection(_selectionForVisibleRacks(_racks)),
    onClear: () => _applyRackSelection({}),
    onInvert: () => _applyRackSelection(
      _selectionForVisibleRacks(_racks).difference(_selectedRackKeys),
    ),
  );

  void _clearSelection() {
    if (_selectedRackKeys.isNotEmpty) _applyRackSelection({});
  }

  Widget _footer() => Card(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 10, 8),
      child: MediaQuery.sizeOf(context).width <= 720
          ? Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _statusRow(),
                if (_racks.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Wrap(
                    alignment: WrapAlignment.end,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 8,
                    children: [_saveButton()],
                  ),
                ],
              ],
            )
          : Row(
              children: [
                Expanded(child: _statusRow()),
                if (_racks.isNotEmpty) ...[_saveButton()],
              ],
            ),
    ),
  );

  Widget _statusRow() => Row(
    children: [
      if (_busy)
        const Padding(
          padding: EdgeInsets.only(right: 10),
          child: SizedBox(
            width: 15,
            height: 15,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      Expanded(
        child: Text(
          _racks.isEmpty ? _status : '$_changeCount 项待保存修改',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            fontSize: 12,
          ),
        ),
      ),
    ],
  );

  Widget _saveButton() => FilledButton.icon(
    onPressed: _busy || !_hasPendingEdits ? null : _save,
    icon: const Icon(Icons.save_alt_rounded),
    label: const Text('保存全部修改'),
  );
}

class _AboutInfoRow extends StatelessWidget {
  const _AboutInfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      SizedBox(
        width: 64,
        child: Text(
          label,
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ),
      Expanded(child: SelectableText(value)),
    ],
  );
}

class _AboutLinkRow extends StatelessWidget {
  const _AboutLinkRow({
    required this.label,
    required this.value,
    required this.icon,
    required this.onPressed,
  });

  final String label;
  final String value;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.center,
    children: [
      SizedBox(
        width: 64,
        child: Text(
          label,
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ),
      Expanded(
        child: Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: onPressed,
            icon: Icon(icon, size: 17),
            label: Text(value, maxLines: 1, overflow: TextOverflow.ellipsis),
            style: TextButton.styleFrom(
              padding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
              alignment: Alignment.centerLeft,
            ),
          ),
        ),
      ),
    ],
  );
}

class _UndoIntent extends Intent {
  const _UndoIntent();
}

class _RedoIntent extends Intent {
  const _RedoIntent();
}

class _ExitSelectionIntent extends Intent {
  const _ExitSelectionIntent();
}

class BulkNamesDialog extends StatefulWidget {
  const BulkNamesDialog({
    super.key,
    required this.initialNames,
    required this.rowCount,
  });
  final List<String> initialNames;
  final int rowCount;

  @override
  State<BulkNamesDialog> createState() => _BulkNamesDialogState();
}

class _BulkNamesDialogState extends State<BulkNamesDialog> {
  late final TextEditingController _controller;
  late final ScrollController _gutterScroll;
  late final ScrollController _textScroll;
  late final FocusNode _textFocusNode;
  Offset? _blockStart;
  Offset? _blockEnd;
  bool _blockDragging = false;
  bool _optionDown = false;
  final _bulkStackKey = GlobalKey();
  final _bulkFieldKey = GlobalKey();
  late final bool Function(KeyEvent) _hardwareKeyHandler;

  static const TextStyle _bulkTextStyle = TextStyle(
    fontFamily: 'Menlo',
    fontSize: 14,
    height: 24 / 14,
  );
  double get _lineHeight => _renderEditable()?.preferredLineHeight ?? 24;
  int get _visibleLineCount {
    final actual = _controller.text.split('\n').length;
    return actual > widget.rowCount ? actual : widget.rowCount;
  }

  double get _charWidth {
    final painter = TextPainter(
      text: const TextSpan(text: 'M', style: _bulkTextStyle),
      textDirection: TextDirection.ltr,
    )..layout();
    return painter.width;
  }

  RenderEditable? _renderEditable() {
    final root = _bulkFieldKey.currentContext?.findRenderObject();
    if (root == null) return null;
    RenderEditable? result;
    void visit(RenderObject node) {
      if (node is RenderEditable) {
        result = node;
        return;
      }
      node.visitChildren((child) {
        if (result == null) visit(child);
      });
    }

    visit(root);
    return result;
  }

  (int, int) _lineColumn(Offset point) {
    final editable = _renderEditable();
    final stack = _bulkStackKey.currentContext?.findRenderObject();
    if (editable == null || stack is! RenderBox) return (0, 0);
    final lines = _controller.text.split('\n');
    var lineStart = 0;
    var selectedLine = 0;
    var closestDistance = double.infinity;
    for (var row = 0; row < lines.length; row++) {
      final caret = editable.getLocalRectForCaret(
        TextPosition(offset: lineStart),
      );
      final centerY = stack
          .globalToLocal(editable.localToGlobal(caret.center))
          .dy;
      final distance = (point.dy - centerY).abs();
      if (distance < closestDistance) {
        closestDistance = distance;
        selectedLine = row;
      }
      lineStart += lines[row].length + 1;
    }

    lineStart = 0;
    for (var row = 0; row < selectedLine; row++) {
      lineStart += lines[row].length + 1;
    }
    final line = lines[selectedLine];
    double caretX(int column) {
      final offset = lineStart + column.clamp(0, line.length);
      final caret = editable.getLocalRectForCaret(TextPosition(offset: offset));
      return stack.globalToLocal(editable.localToGlobal(caret.centerLeft)).dx;
    }

    for (var column = 0; column < line.length; column++) {
      final right = caretX(column + 1);
      if (point.dx < right) return (selectedLine, column);
    }
    final endX = caretX(line.length);
    final extraColumn = point.dx <= endX
        ? 0
        : ((point.dx - endX) / _charWidth).floor();
    return (selectedLine, line.length + extraColumn.clamp(0, 100000));
  }

  List<Rect> _selectionRects() {
    final start = _blockStart;
    final end = _blockEnd;
    final editable = _renderEditable();
    final stack = _bulkStackKey.currentContext?.findRenderObject();
    if (start == null ||
        end == null ||
        editable == null ||
        stack is! RenderBox) {
      return const [];
    }
    final a = _lineColumn(start);
    final b = _lineColumn(end);
    final firstLine = a.$1 < b.$1 ? a.$1 : b.$1;
    final lastLine = a.$1 > b.$1 ? a.$1 : b.$1;
    final firstColumn = a.$2;
    final lastColumn = firstColumn;
    final lines = _controller.text.split('\n');
    final rects = <Rect>[];
    var lineStart = 0;
    for (var row = 0; row < lines.length; row++) {
      if (row >= firstLine && row <= lastLine) {
        final line = lines[row];
        final leftColumn = firstColumn.clamp(0, 100000);
        final rightColumn = lastColumn + 1;
        final leftCaret = editable.getLocalRectForCaret(
          TextPosition(offset: lineStart + leftColumn.clamp(0, line.length)),
        );
        final rightOffset = lineStart + rightColumn.clamp(0, line.length);
        final rightCaret = editable.getLocalRectForCaret(
          TextPosition(offset: rightOffset),
        );
        final overflow = (rightColumn - line.length).clamp(0, 100000);
        final left = stack
            .globalToLocal(editable.localToGlobal(leftCaret.centerLeft))
            .dx;
        final right =
            stack
                .globalToLocal(editable.localToGlobal(rightCaret.centerLeft))
                .dx +
            overflow * _charWidth;
        final centerY = stack
            .globalToLocal(
              editable.localToGlobal(
                editable
                    .getLocalRectForCaret(TextPosition(offset: lineStart))
                    .center,
              ),
            )
            .dy;
        final top = centerY - _lineHeight / 2;
        rects.add(Rect.fromLTRB(left, top, right, top + _lineHeight));
      }
      lineStart += lines[row].length + 1;
    }
    return rects;
  }

  void _replaceBlock(String insertion) {
    final start = _blockStart;
    final end = _blockEnd;
    if (start == null || end == null) return;
    final a = _lineColumn(start);
    final b = _lineColumn(end);
    final firstLine = a.$1 < b.$1 ? a.$1 : b.$1;
    final lastLine = a.$1 > b.$1 ? a.$1 : b.$1;
    final firstColumn = a.$2;
    final lastColumn = firstColumn;
    final lines = _controller.text.split('\n');
    var firstLineStart = 0;
    for (var row = 0; row < firstLine; row++) {
      firstLineStart += lines[row].length + 1;
    }
    final cursorOffset =
        firstLineStart +
        firstColumn.clamp(0, lines[firstLine].length) +
        insertion.length;
    for (var row = firstLine; row <= lastLine; row++) {
      while (lines.length <= row) {
        lines.add('');
      }
      final line = lines[row];
      final startColumn = firstColumn.clamp(0, line.length);
      final endColumn = (lastColumn + 1).clamp(startColumn, line.length);
      final left = line.substring(0, startColumn);
      final right = line.substring(endColumn);
      lines[row] = '$left$insertion$right';
    }
    _controller.value = TextEditingValue(
      text: lines.join('\n'),
      selection: TextSelection.collapsed(
        offset: cursorOffset.clamp(0, lines.join('\n').length),
      ),
    );
    _textFocusNode.requestFocus();
    setState(() {
      _blockStart = null;
      _blockEnd = null;
    });
  }

  KeyEventResult _onBulkKey(FocusNode node, KeyEvent event) {
    if (_blockStart == null || _blockEnd == null || event is! KeyDownEvent) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.backspace ||
        event.logicalKey == LogicalKeyboardKey.delete) {
      _replaceBlock('');
      return KeyEventResult.handled;
    }
    final character = event.character;
    if (character != null &&
        character.isNotEmpty &&
        character != '\n' &&
        character != '\r' &&
        !HardwareKeyboard.instance.isControlPressed &&
        !HardwareKeyboard.instance.isMetaPressed &&
        !HardwareKeyboard.instance.isAltPressed) {
      _replaceBlock(character);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  bool _handleHardwareKey(KeyEvent event) {
    if (event.logicalKey == LogicalKeyboardKey.altLeft ||
        event.logicalKey == LogicalKeyboardKey.altRight) {
      final pressed = event is KeyDownEvent || event is KeyRepeatEvent;
      if (mounted && _optionDown != pressed) {
        setState(() => _optionDown = pressed);
      }
      return false;
    }

    if (_blockStart == null || event is! KeyDownEvent) return false;
    if (event.logicalKey == LogicalKeyboardKey.backspace ||
        event.logicalKey == LogicalKeyboardKey.delete) {
      _replaceBlock('');
      return true;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      setState(() {
        _blockStart = null;
        _blockEnd = null;
      });
      return true;
    }
    return false;
  }

  @override
  void initState() {
    super.initState();
    _hardwareKeyHandler = _handleHardwareKey;
    HardwareKeyboard.instance.addHandler(_hardwareKeyHandler);
    _controller = TextEditingController(text: widget.initialNames.join('\n'));
    _textFocusNode = FocusNode();
    _controller.addListener(_onTextChanged);
    _gutterScroll = ScrollController();
    _textScroll = ScrollController();
    _textScroll.addListener(_syncGutter);
    _gutterScroll.addListener(_syncText);
  }

  void _onTextChanged() => setState(() {});

  void _syncGutter() {
    if (!_gutterScroll.hasClients || !_textScroll.hasClients) return;
    if ((_gutterScroll.offset - _textScroll.offset).abs() > .5) {
      _gutterScroll.jumpTo(
        _textScroll.offset.clamp(0, _gutterScroll.position.maxScrollExtent),
      );
    }
  }

  void _syncText() {
    if (!_gutterScroll.hasClients || !_textScroll.hasClients) return;
    if ((_textScroll.offset - _gutterScroll.offset).abs() > .5) {
      _textScroll.jumpTo(
        _gutterScroll.offset.clamp(0, _textScroll.position.maxScrollExtent),
      );
    }
  }

  @override
  void dispose() {
    _textScroll.removeListener(_syncGutter);
    _gutterScroll.removeListener(_syncText);
    _controller.removeListener(_onTextChanged);
    HardwareKeyboard.instance.removeHandler(_hardwareKeyHandler);
    _textFocusNode.dispose();
    _controller.dispose();
    _gutterScroll.dispose();
    _textScroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('批量粘贴通道名称'),
    content: SizedBox(
      width: 560,
      height: 420,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '每行一个名称；共 ${widget.rowCount} 行。可直接粘贴 Excel 单列；按住 Option 拖动可竖向选择。',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 10),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: 42,
                  child: ScrollConfiguration(
                    behavior: ScrollConfiguration.of(
                      context,
                    ).copyWith(scrollbars: false),
                    child: ListView.builder(
                      controller: _gutterScroll,
                      itemExtent: 24,
                      itemCount: _visibleLineCount > 0 ? _visibleLineCount : 1,
                      itemBuilder: (_, i) => Align(
                        alignment: Alignment.topRight,
                        child: Padding(
                          padding: const EdgeInsets.only(right: 10, top: 3),
                          child: Text(
                            '${i + 1}',
                            style: TextStyle(
                              fontFamily: 'monospace',
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                const VerticalDivider(width: 1),
                Expanded(
                  child: Focus(
                    autofocus: true,
                    onKeyEvent: _onBulkKey,
                    child: Listener(
                      onPointerDown: (event) {
                        if (_optionDown ||
                            HardwareKeyboard.instance.isAltPressed) {
                          final point = event.localPosition;
                          setState(() {
                            _blockStart = point;
                            _blockEnd = point;
                            _blockDragging = true;
                          });
                        } else if (_blockStart != null) {
                          setState(() {
                            _blockStart = null;
                            _blockEnd = null;
                          });
                        }
                      },
                      onPointerMove: (event) {
                        if (!_blockDragging) return;
                        setState(() => _blockEnd = event.localPosition);
                      },
                      onPointerUp: (_) => _blockDragging = false,
                      onPointerCancel: (_) => _blockDragging = false,
                      child: Stack(
                        key: _bulkStackKey,
                        fit: StackFit.expand,
                        children: [
                          Theme(
                            data: Theme.of(context).copyWith(
                              textSelectionTheme: Theme.of(context)
                                  .textSelectionTheme
                                  .copyWith(
                                    selectionColor: _blockStart == null
                                        ? null
                                        : Colors.transparent,
                                  ),
                            ),
                            child: TextField(
                              key: _bulkFieldKey,
                              focusNode: _textFocusNode,
                              controller: _controller,
                              scrollController: _textScroll,
                              showCursor: true,
                              expands: true,
                              minLines: null,
                              maxLines: null,
                              textAlignVertical: TextAlignVertical.top,
                              keyboardType: TextInputType.multiline,
                              style: _bulkTextStyle,
                              decoration: const InputDecoration(
                                border: InputBorder.none,
                                contentPadding: EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 3,
                                ),
                                hintText: '例如：\nLead\nGT\nBass',
                              ),
                            ),
                          ),
                          if (_blockStart != null && _blockEnd != null)
                            IgnorePointer(
                              child: CustomPaint(
                                painter: _BlockSelectionPainter(
                                  rects: _selectionRects(),
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.primary.withValues(alpha: .28),
                                ),
                              ),
                            ),
                        ],
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
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () {
          final names = _controller.text
              .replaceAll('\r\n', '\n')
              .replaceAll('\r', '\n')
              .split('\n');
          if (names.isNotEmpty && names.last.trim().isEmpty) names.removeLast();
          Navigator.pop(context, names);
        },
        child: const Text('应用'),
      ),
    ],
  );
}

class _BlockSelectionPainter extends CustomPainter {
  const _BlockSelectionPainter({required this.rects, required this.color});
  final List<Rect> rects;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    for (final rect in rects) {
      canvas.drawRect(rect, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _BlockSelectionPainter oldDelegate) =>
      oldDelegate.rects != rects || oldDelegate.color != color;
}
