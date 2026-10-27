import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/session_tools.dart';
import '../widgets/editor_selection.dart';
import '../services/session_service.dart';
import '../services/session_tools_service.dart';

class MatrixScreen extends StatefulWidget {
  const MatrixScreen({
    super.key,
    required this.sessionPath,
    required this.onDraftChanged,
    required this.snapshots,
    required this.selectedSnapshotId,
    required this.allSnapshots,
    required this.onCommand,
    this.service,
  });
  final String sessionPath;
  final ValueChanged<List<MatrixEditDraft>> onDraftChanged;
  final List<SessionSnapshot> snapshots;
  final int? selectedSnapshotId;
  final bool allSnapshots;
  final ValueChanged<EditorCommand> onCommand;
  final SessionToolsService? service;

  @override
  State<MatrixScreen> createState() => _MatrixScreenState();
}

class _MatrixScreenState extends State<MatrixScreen> {
  SessionToolsService get _service =>
      widget.service ?? const SessionToolsService();
  final _horizontal = ScrollController();
  final _vertical = ScrollController();
  String get _sessionPath => widget.sessionPath;
  List<MatrixRack> _racks = const [];
  SessionSnapshot? _snapshot;
  final Map<int, bool> _rackOn = {};
  final Map<int, bool> _rackSafe = {};
  final Map<int, bool> _pluginBypass = {};
  final Map<int, bool> _pluginSafe = {};
  final Map<int, MatrixEditDraft> _draftsBySnapshot = {};
  final Map<String, GlobalKey> _cellKeys = {};
  bool _busy = false;
  String? _dragKey;
  bool? _dragTarget;
  Map<String, bool>? _dragBefore;
  Map<int, Map<String, bool>>? _dragAllBefore;
  bool _dragGlobal = false;
  bool _skipNextCellTap = false;
  bool _dragMoved = false;
  final Map<int, Map<String, bool>> _valuesBySnapshot = {};
  final Set<String> _selectedHeaders = {};
  final Map<String, GlobalKey> _headerKeys = {};
  String? _headerDragScope;
  Offset? _headerDragOrigin;
  bool _headerDragActive = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _horizontal.dispose();
    _vertical.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant MatrixScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedSnapshotId != widget.selectedSnapshotId ||
        oldWidget.sessionPath != widget.sessionPath) {
      final id = widget.selectedSnapshotId;
      if (id != null) _load(snapshotId: id);
    }
  }

  Future<void> _load({int? snapshotId}) async {
    setState(() => _busy = true);
    try {
      final snapshots = await _service.readSnapshots(_sessionPath);
      final available = snapshots.where((e) => e.rackCount > 0).toList();
      if (available.isEmpty) {
        throw const SessionException('会话中没有可编辑的 Snapshot。');
      }
      final selected = available.firstWhere(
        (e) => e.id == snapshotId,
        orElse: () => available.firstWhere(
          (e) => e.number == -1,
          orElse: () => available.first,
        ),
      );
      final racks = await _service.readMatrix(_sessionPath, selected.id);
      if (!mounted) return;
      setState(() {
        _snapshot = selected;
        _racks = racks;
        _rackOn.clear();
        _rackSafe.clear();
        _pluginBypass.clear();
        _pluginSafe.clear();
        final draft = _draftsBySnapshot[selected.id];
        if (draft != null) {
          _rackOn.addAll(draft.rackOn);
          _rackSafe.addAll(draft.rackRecallSafe);
          _pluginBypass.addAll(draft.pluginBypass);
          _pluginSafe.addAll(draft.pluginRecallSafe);
        }
        _baselinesBySnapshot[selected.id] = _valuesForDraft(null, racks);
        _valuesBySnapshot[selected.id] = _valuesForDraft(draft, racks);
        _busy = false;
      });
      _emitDraft();
    } catch (error) {
      if (mounted) {
        setState(() => _busy = false);
        _message('$error');
      }
    }
  }

  bool _current(String key, bool value) {
    final colon = key.indexOf(':');
    final type = key.substring(0, colon);
    final id = int.parse(key.substring(colon + 1));
    return switch (type) {
      'on' => _rackOn[id] ?? value,
      'rackSafe' => _rackSafe[id] ?? value,
      'bypass' => _pluginBypass[id] ?? value,
      'pluginSafe' => _pluginSafe[id] ?? value,
      _ => value,
    };
  }

  void _setCell(String key, bool original, bool value) {
    final colon = key.indexOf(':');
    final type = key.substring(0, colon);
    final id = int.parse(key.substring(colon + 1));
    setState(() {
      final map = switch (type) {
        'on' => _rackOn,
        'rackSafe' => _rackSafe,
        'bypass' => _pluginBypass,
        'pluginSafe' => _pluginSafe,
        _ => _rackOn,
      };
      if (value == original) {
        map.remove(id);
      } else {
        map[id] = value;
      }
    });
    _emitDraft();
  }

  Future<void> _applyAllSnapshots(String key, bool value) async {
    final before = await _captureAllSnapshotValues();
    final targets = <int, Map<String, bool>>{
      for (final entry in before.entries) entry.key: {key: value},
    };
    await _applySnapshotTargets(targets);
  }

  Future<void> _applySnapshotTargets(
    Map<int, Map<String, bool>> targets,
  ) async {
    for (final snapshot in widget.snapshots) {
      final target = targets[snapshot.id];
      if (target == null || target.isEmpty) continue;
      final racks = await _service.readMatrix(_sessionPath, snapshot.id);
      final baseline = _baselinesBySnapshot.putIfAbsent(
        snapshot.id,
        () => _valuesForDraft(null, racks),
      );
      final values = _valuesBySnapshot.putIfAbsent(
        snapshot.id,
        () => _valuesForDraft(_draftsBySnapshot[snapshot.id], racks),
      );
      values.addAll(target);
      final maps = <String, Map<int, bool>>{
        'on': {},
        'rackSafe': {},
        'bypass': {},
        'pluginSafe': {},
      };
      for (final entry in values.entries) {
        if (entry.value == baseline[entry.key]) continue;
        final parts = entry.key.split(':');
        maps[parts[0]]![int.parse(parts[1])] = entry.value;
      }
      final draft = MatrixEditDraft(
        snapshotId: snapshot.id,
        rackOn: maps['on']!,
        rackRecallSafe: maps['rackSafe']!,
        pluginBypass: maps['bypass']!,
        pluginRecallSafe: maps['pluginSafe']!,
      );
      if (draft.hasChanges) {
        _draftsBySnapshot[snapshot.id] = draft;
      } else {
        _draftsBySnapshot.remove(snapshot.id);
      }
    }
    widget.onDraftChanged(List.unmodifiable(_draftsBySnapshot.values));
    if (mounted && _snapshot != null) await _load(snapshotId: _snapshot!.id);
  }

  Future<Map<int, Map<String, bool>>> _captureAllSnapshotValues() async {
    final captured = <int, Map<String, bool>>{};
    for (final snapshot in widget.snapshots) {
      final racks = await _service.readMatrix(_sessionPath, snapshot.id);
      captured[snapshot.id] = _valuesForDraft(
        _draftsBySnapshot[snapshot.id],
        racks,
      );
    }
    return captured;
  }

  void _applyAllSnapshotValues(Map<int, Map<String, bool>> values) {
    for (final entry in values.entries) {
      _applySnapshotValues(entry.key, entry.value);
    }
    if (_snapshot != null) _load(snapshotId: _snapshot!.id);
  }

  Map<String, bool> _currentValues() => {
    for (final rack in _racks) ...{
      'on:${rack.id}': _current('on:${rack.id}', rack.isOn),
      'rackSafe:${rack.id}': _current('rackSafe:${rack.id}', rack.recallSafe),
      for (final plugin in rack.plugins) ...{
        'bypass:${plugin.id}': _current('bypass:${plugin.id}', plugin.bypass),
        'pluginSafe:${plugin.id}': _current(
          'pluginSafe:${plugin.id}',
          plugin.recallSafe,
        ),
      },
    },
  };

  Map<String, bool> _valuesForDraft(
    MatrixEditDraft? draft,
    List<MatrixRack> racks,
  ) {
    final values = <String, bool>{};
    for (final rack in racks) {
      values['on:${rack.id}'] = draft?.rackOn[rack.id] ?? rack.isOn;
      values['rackSafe:${rack.id}'] =
          draft?.rackRecallSafe[rack.id] ?? rack.recallSafe;
      for (final plugin in rack.plugins) {
        values['bypass:${plugin.id}'] =
            draft?.pluginBypass[plugin.id] ?? plugin.bypass;
        values['pluginSafe:${plugin.id}'] =
            draft?.pluginRecallSafe[plugin.id] ?? plugin.recallSafe;
      }
    }
    return values;
  }

  void _applyValues(Map<String, bool> values) {
    _rackOn.clear();
    _rackSafe.clear();
    _pluginBypass.clear();
    _pluginSafe.clear();
    for (final entry in values.entries) {
      final original = _originalForKey(entry.key);
      if (entry.value == original) continue;
      final split = entry.key.split(':');
      final id = int.parse(split[1]);
      switch (split[0]) {
        case 'on':
          _rackOn[id] = entry.value;
        case 'rackSafe':
          _rackSafe[id] = entry.value;
        case 'bypass':
          _pluginBypass[id] = entry.value;
        case 'pluginSafe':
          _pluginSafe[id] = entry.value;
      }
    }
    _emitDraft();
    if (mounted) setState(() {});
  }

  final Map<int, Map<String, bool>> _baselinesBySnapshot = {};

  void _applySnapshotValues(int snapshotId, Map<String, bool> values) {
    if (_snapshot?.id == snapshotId) {
      _applyValues(values);
      return;
    }
    final current = _valuesBySnapshot[snapshotId];
    if (current == null) return;
    current
      ..clear()
      ..addAll(values);
    final baseline = _baselinesBySnapshot[snapshotId] ?? const <String, bool>{};
    final maps = <String, Map<int, bool>>{
      'on': {},
      'rackSafe': {},
      'bypass': {},
      'pluginSafe': {},
    };
    for (final entry in values.entries) {
      if (entry.value == baseline[entry.key]) continue;
      final parts = entry.key.split(':');
      maps[parts[0]]![int.parse(parts[1])] = entry.value;
    }
    final draft = MatrixEditDraft(
      snapshotId: snapshotId,
      rackOn: maps['on']!,
      rackRecallSafe: maps['rackSafe']!,
      pluginBypass: maps['bypass']!,
      pluginRecallSafe: maps['pluginSafe']!,
    );
    if (draft.hasChanges) {
      _draftsBySnapshot[snapshotId] = draft;
    } else {
      _draftsBySnapshot.remove(snapshotId);
    }
    widget.onDraftChanged(List.unmodifiable(_draftsBySnapshot.values));
  }

  Future<void> _finishDrag() async {
    final before = _dragBefore;
    final allBefore = _dragAllBefore;
    if (!_dragGlobal && before == null) return;
    final global = _dragGlobal;
    if (!global || _dragMoved) _skipNextCellTap = true;
    final after = _currentValues();
    final dragKey = _dragKey;
    final target = _dragTarget;
    final moved = _dragMoved;
    _dragBefore = null;
    _dragAllBefore = null;
    _dragKey = null;
    _dragTarget = null;
    _dragGlobal = false;
    _dragMoved = false;
    if (global) {
      if (!moved || dragKey == null || target == null) return;
      final captured = allBefore ?? await _captureAllSnapshotValues();
      final keys = _dragGlobalKeys;
      _dragGlobalKeys = <String>{};
      final targets = <int, Map<String, bool>>{
        for (final id in captured.keys)
          id: {for (final key in keys) key: target},
      };
      await _applySnapshotTargets(targets);
      final allAfter = await _captureAllSnapshotValues();
      if (_snapshotValuesEqual(captured, allAfter)) return;
      widget.onCommand(
        EditorCommand(
          label: '批量调整状态',
          undo: () => _applyAllSnapshotValues(captured),
          redo: () => _applyAllSnapshotValues(allAfter),
        ),
      );
      return;
    }
    _dragGlobalKeys = <String>{};
    if (before == null || mapEquals(before, after)) return;
    final snapshotId = _snapshot?.id;
    if (snapshotId == null) return;
    widget.onCommand(
      EditorCommand(
        label: '批量调整状态',
        undo: () => _applySnapshotValues(snapshotId, before),
        redo: () => _applySnapshotValues(snapshotId, after),
      ),
    );
  }

  Set<String> _dragGlobalKeys = <String>{};

  Future<void> _activateCell(String key, bool active) async {
    if (_skipNextCellTap) {
      _skipNextCellTap = false;
      return;
    }
    final globalState =
        key.startsWith('rackSafe:') || key.startsWith('pluginSafe:');
    final allScope = widget.allSnapshots || globalState;
    final allBefore = allScope ? await _captureAllSnapshotValues() : null;
    final snapshotId = _snapshot?.id;
    final before = _currentValues();
    if (allScope) {
      await _applyAllSnapshots(key, !active);
    } else {
      _setCell(key, _originalForKey(key), !active);
    }
    final allAfter = allScope ? await _captureAllSnapshotValues() : null;
    final after = _currentValues();
    if (snapshotId == null) return;
    widget.onCommand(
      EditorCommand(
        label: '调整状态',
        undo: () => allScope
            ? _applyAllSnapshotValues(allBefore ?? const {})
            : _applySnapshotValues(snapshotId, before),
        redo: () => allScope
            ? _applyAllSnapshotValues(allAfter ?? const {})
            : _applySnapshotValues(snapshotId, after),
      ),
    );
  }

  void _emitDraft() {
    final draft = MatrixEditDraft(
      snapshotId: _snapshot?.id ?? -1,
      rackOn: Map.unmodifiable(_rackOn),
      rackRecallSafe: Map.unmodifiable(_rackSafe),
      pluginBypass: Map.unmodifiable(_pluginBypass),
      pluginRecallSafe: Map.unmodifiable(_pluginSafe),
    );
    if (draft.hasChanges) {
      _draftsBySnapshot[draft.snapshotId] = draft;
      _valuesBySnapshot[draft.snapshotId] = _currentValues();
      widget.onDraftChanged(List.unmodifiable(_draftsBySnapshot.values));
    } else {
      _draftsBySnapshot.remove(draft.snapshotId);
      widget.onDraftChanged(List.unmodifiable(_draftsBySnapshot.values));
    }
  }

  void _pointerDown(PointerDownEvent event) {
    if (event.kind != PointerDeviceKind.mouse ||
        (event.buttons & kPrimaryMouseButton) == 0) {
      return;
    }
    final cell = _hitCell(event.position);
    if (cell == null) return;
    final global =
        widget.allSnapshots ||
        cell.$1.startsWith('rackSafe:') ||
        cell.$1.startsWith('pluginSafe:');
    final target = !_current(cell.$1, cell.$2);
    _dragGlobal = global;
    _dragBefore = global ? null : _currentValues();
    _dragAllBefore = null;
    _dragKey = cell.$1;
    _dragTarget = target;
    _dragMoved = false;
    _dragGlobalKeys = {cell.$1};
    if (global) {
      _captureAllSnapshotValues().then((values) {
        if (_dragGlobal && _dragKey != null) {
          _dragAllBefore = values;
          _dragBefore = _currentValues();
        }
      });
    } else {
      _setCell(cell.$1, cell.$2, target);
    }
  }

  void _pointerMove(PointerMoveEvent event) {
    if (event.kind != PointerDeviceKind.mouse ||
        (event.buttons & kPrimaryMouseButton) == 0) {
      return;
    }
    final cell = _hitCell(event.position);
    final target = _dragTarget;
    if (cell == null || target == null || cell.$1 == _dragKey) return;
    _dragMoved = true;
    _dragKey = cell.$1;
    if (_dragGlobal) {
      _dragGlobalKeys.add(cell.$1);
    } else {
      _setCell(cell.$1, cell.$2, target);
    }
  }

  (String, bool)? _hitCell(Offset position) {
    for (final entry in _cellKeys.entries) {
      final render = entry.value.currentContext?.findRenderObject();
      if (render is! RenderBox || !render.hasSize) continue;
      final origin = render.localToGlobal(Offset.zero);
      if (position.dx >= origin.dx &&
          position.dy >= origin.dy &&
          position.dx <= origin.dx + render.size.width &&
          position.dy <= origin.dy + render.size.height) {
        return (entry.key, _originalForKey(entry.key));
      }
    }
    return null;
  }

  bool _originalForKey(String key) {
    final parts = key.split(':');
    final id = int.parse(parts[1]);
    switch (parts[0]) {
      case 'on':
        return _racks.firstWhere((r) => r.id == id).isOn;
      case 'rackSafe':
        return _racks.firstWhere((r) => r.id == id).recallSafe;
      case 'bypass':
        for (final rack in _racks) {
          for (final plugin in rack.plugins) {
            if (plugin.id == id) return plugin.bypass;
          }
        }
      case 'pluginSafe':
        for (final rack in _racks) {
          for (final plugin in rack.plugins) {
            if (plugin.id == id) return plugin.recallSafe;
          }
        }
    }
    return false;
  }

  Widget _cell(String type, int id, bool value, String tooltip) {
    final key = '$type:$id';
    final original = _originalForKey(key);
    final active = _current(key, original);
    final globalKey = _cellKeys.putIfAbsent(key, GlobalKey.new);
    final colorScheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: '$tooltip ${active ? 'on' : 'off'}',
      onTap: _busy ? null : () => _activateCell(key, active),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _busy ? null : () => _activateCell(key, active),
        child: Container(
          key: globalKey,
          width: 38,
          height: 34,
          margin: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
          decoration: BoxDecoration(
            color: active
                ? colorScheme.primaryContainer
                : colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(9),
            border: Border.all(
              width: _selectedHeaders.contains(key) ? 2 : 1,
              color: _selectedHeaders.contains(key)
                  ? colorScheme.secondary
                  : active
                  ? colorScheme.primary.withValues(alpha: .35)
                  : colorScheme.outlineVariant.withValues(alpha: .6),
            ),
          ),
          child: Icon(
            switch (type) {
              'on' => Icons.power_settings_new_rounded,
              'rackSafe' || 'pluginSafe' => Icons.shield_rounded,
              _ => Icons.volume_off_rounded,
            },
            size: 17,
            color: active
                ? colorScheme.primary
                : colorScheme.onSurfaceVariant.withValues(alpha: .45),
          ),
        ),
      ),
    );
  }

  void _message(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      autofocus: true,
      onKeyEvent: (_, event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.escape &&
            _selectedHeaders.isNotEmpty) {
          setState(_selectedHeaders.clear);
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_busy) const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: _racks.isEmpty
                ? const Center(child: CircularProgressIndicator())
                : _matrixCard(),
          ),
        ],
      ),
    );
  }

  Widget _matrixCard() => Card(
    margin: const EdgeInsets.only(top: 2),
    clipBehavior: Clip.antiAlias,
    child: Column(
      children: [
        EditorActionBar(
          actions: [
            for (final action in [
              ('on', '开启', Icons.power_settings_new_rounded),
              ('off', '关闭', Icons.power_off_rounded),
              ('invert', '翻转状态', Icons.swap_horiz_rounded),
            ])
              OutlinedButton.icon(
                onPressed: _busy || _selectedHeaders.isEmpty
                    ? null
                    : () => _applySelected(action.$1),
                icon: Icon(action.$3, size: 18),
                label: Text(action.$2),
              ),
          ],
          selection: EditorSelectionToolbar(
            count: _selectedHeaders.length,
            onSelectAll: () => _applyHeaderAction('row', 'selectAll'),
            onClear: () => setState(_selectedHeaders.clear),
            onInvert: () => _applyHeaderAction('row', 'invertSelection'),
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: Listener(
            onPointerDown: _pointerDown,
            onPointerMove: _pointerMove,
            onPointerUp: (_) => _finishDrag(),
            onPointerCancel: (_) => _finishDrag(),
            child: Scrollbar(
              controller: _vertical,
              thumbVisibility: true,
              child: SingleChildScrollView(
                controller: _vertical,
                child: Scrollbar(
                  controller: _horizontal,
                  thumbVisibility: true,
                  notificationPredicate: (n) => n.depth == 1,
                  child: SingleChildScrollView(
                    controller: _horizontal,
                    scrollDirection: Axis.horizontal,
                    child: _matrixTable(),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    ),
  );

  Widget _matrixTable() => DataTable(
    headingRowHeight: 42,
    dataRowMinHeight: 40,
    dataRowMaxHeight: 40,
    columnSpacing: 4,
    horizontalMargin: 18,
    columns: [
      DataColumn(label: _selectionHeader('Rack', 'row')),
      DataColumn(label: _selectionHeader('On', 'on')),
      DataColumn(label: _selectionHeader('Rack Safe', 'rackSafe')),
      for (var i = 1; i <= 8; i++) ...[
        DataColumn(label: _selectionHeader('$i B', 'bypass:$i')),
        DataColumn(label: _selectionHeader('$i S', 'pluginSafe:$i')),
      ],
    ],
    rows: [
      for (final rack in _racks)
        DataRow(
          cells: [
            DataCell(
              SizedBox(
                width: 170,
                child: _selectionHeader(
                  '${rack.number.toString().padLeft(2, '0')}  ${rack.name}',
                  'row:${rack.id}',
                ),
              ),
            ),
            DataCell(_cell('on', rack.id, rack.isOn, 'Rack On')),
            DataCell(
              _cell('rackSafe', rack.id, rack.recallSafe, 'Rack Recall Safe'),
            ),
            for (var slot = 0; slot < 8; slot++) ...[
              _pluginCell(rack, slot, false),
              _pluginCell(rack, slot, true),
            ],
          ],
        ),
    ],
  );

  Widget _selectionHeader(String label, String scope) {
    final keys = _keysForScope(scope);
    final selected = keys.isNotEmpty && keys.every(_selectedHeaders.contains);
    return Listener(
      key: _headerKeys.putIfAbsent(scope, GlobalKey.new),
      onPointerDown: (event) {
        if ((event.buttons & kPrimaryMouseButton) == 0) {
          return;
        }
        _headerDragScope = scope;
        _headerDragOrigin = event.position;
        _headerDragActive = false;
      },
      onPointerMove: (event) {
        if (_headerDragScope == null ||
            _headerDragOrigin == null ||
            (event.buttons & kPrimaryMouseButton) == 0) {
          return;
        }
        if (!_headerDragActive &&
            (event.position - _headerDragOrigin!).distance > 5) {
          _headerDragActive = true;
          _applyHeaderAction(_headerDragScope!, 'selectAll');
        }
        if (_headerDragActive) {
          for (final entry in _headerKeys.entries) {
            final box = entry.value.currentContext?.findRenderObject();
            if (box is RenderBox &&
                box.hasSize &&
                (box.localToGlobal(Offset.zero) & box.size).contains(
                  event.position,
                )) {
              _applyHeaderAction(entry.key, 'selectAll');
            }
          }
        }
      },
      onPointerUp: (_) {
        if (_headerDragScope != scope) return;
        if (!_headerDragActive) {
          _applyHeaderAction(scope, selected ? 'clear' : 'selectAll');
        }
        _headerDragScope = null;
        _headerDragOrigin = null;
        _headerDragActive = false;
      },
      onPointerCancel: (_) {
        _headerDragScope = null;
        _headerDragOrigin = null;
        _headerDragActive = false;
      },
      child: Tooltip(
        message: '点击或拖动选择 $label',
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
            decoration: BoxDecoration(
              color: selected
                  ? Theme.of(context).colorScheme.secondaryContainer
                  : null,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        ),
      ),
    );
  }

  void _applyHeaderAction(String scope, String action) {
    final keys = _keysForScope(scope);
    setState(() {
      if (action == 'clear') {
        _selectedHeaders.removeAll(keys);
      } else if (action == 'invertSelection') {
        for (final key in keys) {
          if (!_selectedHeaders.add(key)) _selectedHeaders.remove(key);
        }
      } else {
        _selectedHeaders.addAll(keys);
      }
    });
  }

  Set<String> _keysForScope(String scope) {
    final keys = <String>{};
    if (scope == 'row') {
      for (final rack in _racks) {
        keys.addAll(['on:${rack.id}', 'rackSafe:${rack.id}']);
        for (final plugin in rack.plugins) {
          keys.add('bypass:${plugin.id}');
          keys.add('pluginSafe:${plugin.id}');
        }
      }
    } else if (scope.startsWith('row:')) {
      final rackId = int.parse(scope.split(':').last);
      final rack = _racks.firstWhere((item) => item.id == rackId);
      keys.addAll(['on:${rack.id}', 'rackSafe:${rack.id}']);
      for (final plugin in rack.plugins) {
        keys.add('bypass:${plugin.id}');
        keys.add('pluginSafe:${plugin.id}');
      }
    } else {
      final pieces = scope.split(':');
      final type = pieces.first;
      final slot = pieces.length > 1 ? int.tryParse(pieces[1]) : null;
      for (final rack in _racks) {
        if (type == 'on') {
          keys.add('on:${rack.id}');
        } else if (type == 'rackSafe') {
          keys.add('rackSafe:${rack.id}');
        } else {
          for (final plugin in rack.plugins.where(
            (p) => p.slot == (slot ?? 1) - 1,
          )) {
            keys.add('$type:${plugin.id}');
          }
        }
      }
    }
    return keys;
  }

  Future<void> _applySelected(String action) async {
    final before = _currentValues();
    final allScope =
        widget.allSnapshots ||
        _selectedHeaders.any(
          (key) => key.startsWith('rackSafe:') || key.startsWith('pluginSafe:'),
        );
    final allBefore = allScope ? await _captureAllSnapshotValues() : null;
    if (allScope) {
      final targets = <int, Map<String, bool>>{};
      for (final entry in allBefore!.entries) {
        final values = entry.value;
        targets[entry.key] = {
          for (final key in _selectedHeaders)
            if (values.containsKey(key))
              key: action == 'invert' ? !values[key]! : action == 'on',
        };
      }
      await _applySnapshotTargets(targets);
    } else {
      for (final key in _selectedHeaders) {
        final value = _currentValues()[key];
        if (value == null) continue;
        final target = action == 'invert' ? !value : action == 'on';
        _setCell(key, _originalForKey(key), target);
      }
    }
    final after = _currentValues();
    final allAfter = allScope ? await _captureAllSnapshotValues() : null;
    final changed = allScope
        ? !_snapshotValuesEqual(allBefore!, allAfter!)
        : !mapEquals(before, after);
    if (changed) {
      final snapshotId = _snapshot?.id;
      if (snapshotId == null) return;
      widget.onCommand(
        EditorCommand(
          label: '批量调整状态',
          undo: () => allScope
              ? _applyAllSnapshotValues(allBefore ?? const {})
              : _applySnapshotValues(snapshotId, before),
          redo: () => allScope
              ? _applyAllSnapshotValues(allAfter ?? const {})
              : _applySnapshotValues(snapshotId, after),
        ),
      );
    }
    setState(() {});
  }

  bool _snapshotValuesEqual(
    Map<int, Map<String, bool>> left,
    Map<int, Map<String, bool>> right,
  ) {
    if (!setEquals(left.keys.toSet(), right.keys.toSet())) return false;
    for (final id in left.keys) {
      if (!mapEquals(left[id], right[id])) return false;
    }
    return true;
  }

  DataCell _pluginCell(MatrixRack rack, int slot, bool safe) {
    final plugin = rack.plugins.where((p) => p.slot == slot).firstOrNull;
    if (plugin == null) return const DataCell(SizedBox(width: 42));
    return DataCell(
      Tooltip(
        message:
            '${plugin.name} · Slot ${slot + 1}${safe ? ' · Recall Safe' : ' · Bypass'}',
        child: SizedBox(
          width: 42,
          child: Center(
            child: _cell(
              safe ? 'pluginSafe' : 'bypass',
              plugin.id,
              safe ? plugin.recallSafe : plugin.bypass,
              safe ? 'Plugin Recall Safe' : 'Plugin Bypass',
            ),
          ),
        ),
      ),
    );
  }
}
