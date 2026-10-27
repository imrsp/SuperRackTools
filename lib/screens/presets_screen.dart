import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../models/session_tools.dart';
import '../services/session_tools_service.dart';
import '../widgets/editor_selection.dart';

class PresetsScreen extends StatefulWidget {
  const PresetsScreen({
    super.key,
    required this.sessionPath,
    required this.onDraftChanged,
    required this.onCommand,
    this.service,
  });

  final String sessionPath;
  final ValueChanged<PresetEditDraft> onDraftChanged;
  final ValueChanged<EditorCommand> onCommand;
  final SessionToolsService? service;

  @override
  State<PresetsScreen> createState() => _PresetsScreenState();
}

class _PresetsScreenState extends State<PresetsScreen> {
  SessionToolsService get _service =>
      widget.service ?? const SessionToolsService();
  String get _sessionPath => widget.sessionPath;
  List<UserPreset> _presets = const [];
  final Set<int> _selected = {};
  final Map<int, String> _renames = {};
  final Set<int> _duplicates = {};
  final Set<int> _deletes = {};
  final Map<int, String> _importedXmlById = {};
  final ScrollController _presetsScrollController = ScrollController();
  int _nextDraftId = -1;
  bool _busy = false;
  bool _reordered = false;
  int _nextDuplicateId = -1000000;
  bool _dragSelecting = false;
  bool? _dragTarget;
  Offset? _pendingSelectionDown;
  int? _pendingSelectionId;
  final Map<int, GlobalKey> _rowKeys = {};
  List<int> _originalOrder = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _presetsScrollController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _busy = true);
    try {
      final presets = await _service.readUserPresets(_sessionPath);
      if (!mounted) return;
      setState(() {
        // The SQLite reader returns a fixed-length list. This screen inserts
        // draft copies and reorders rows, so keep a mutable working copy.
        _presets = List<UserPreset>.of(presets);
        _originalOrder = presets.map((preset) => preset.id).toList();
        _selected.clear();
        _renames.clear();
        _duplicates.clear();
        _deletes.clear();
        _importedXmlById.clear();
        _nextDraftId = -1;
        _reordered = false;
        _busy = false;
        _emitDraft();
      });
    } catch (error) {
      if (mounted) {
        setState(() => _busy = false);
        _message('$error');
      }
    }
  }

  void _message(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  void _emitDraft() => widget.onDraftChanged(
    PresetEditDraft(
      orderedPresets: List.unmodifiable(_presets),
      renames: Map.unmodifiable(_renames),
      duplicateIds: Set.unmodifiable(_duplicates),
      deleteIds: Set.unmodifiable(_deletes),
      importedXmlById: Map.unmodifiable(_importedXmlById),
      reordered: _reordered,
    ),
  );

  Future<void> _rename(UserPreset preset) async {
    final value = await showDialog<String>(
      context: context,
      builder: (context) => _PresetNameDialog(
        title: '重命名预设',
        initialName: _renames[preset.id] ?? preset.name,
        confirmLabel: '确定',
      ),
    );
    if (value == null || value.isEmpty || !mounted) return;
    final before = _snapshotDraft();
    setState(() {
      _renames[preset.id] = value;
      _emitDraft();
    });
    final after = _snapshotDraft();
    widget.onCommand(
      EditorCommand(
        label: '重命名预设',
        undo: () => _restoreDraft(before),
        redo: () => _restoreDraft(after),
      ),
    );
  }

  Future<void> _duplicate(UserPreset preset) async {
    final name = await showDialog<String>(
      context: context,
      builder: (context) => _PresetNameDialog(
        title: '复制预设',
        initialName: '${_displayName(preset)} Copy',
        fieldLabel: '新预设名称',
        confirmLabel: '创建副本',
      ),
    );
    if (name == null || name.isEmpty || !mounted) return;
    try {
      final sourceXml =
          _importedXmlById[preset.id] ??
          await _service.readPresetXml(_sessionPath, preset.id);
      if (!mounted) return;
      final before = _snapshotDraft();
      final id = _nextDuplicateId--;
      final index = _presets.indexWhere((entry) => entry.id == preset.id);
      final rowKey = GlobalKey();
      setState(() {
        _presets.insert(
          index < 0 ? _presets.length : index + 1,
          UserPreset(id: id, name: name),
        );
        _rowKeys[id] = rowKey;
        _renames[id] = name;
        _importedXmlById[id] = sourceXml;
        _reordered = true;
        _emitDraft();
      });
      final after = _snapshotDraft();
      widget.onCommand(
        EditorCommand(
          label: '复制预设',
          undo: () => _restoreDraft(before),
          redo: () => _restoreDraft(after),
        ),
      );
      await WidgetsBinding.instance.endOfFrame;
      if (rowKey.currentContext != null) {
        await Scrollable.ensureVisible(
          rowKey.currentContext!,
          alignment: 0.45,
          duration: const Duration(milliseconds: 220),
        );
      }
      if (mounted) _message('已创建副本：$name');
    } catch (error) {
      if (mounted) _message('复制预设失败：$error');
    }
  }

  void _markDelete() {
    if (_selected.isEmpty) return;
    final before = _snapshotDraft();
    setState(() {
      _deletes.addAll(_selected);
      _selected.clear();
      _emitDraft();
    });
    final after = _snapshotDraft();
    widget.onCommand(
      EditorCommand(
        label: '删除预设',
        undo: () => _restoreDraft(before),
        redo: () => _restoreDraft(after),
      ),
    );
  }

  void _deletePreset(UserPreset preset) {
    final before = _snapshotDraft();
    setState(() {
      _deletes.add(preset.id);
      _selected.remove(preset.id);
      _emitDraft();
    });
    final after = _snapshotDraft();
    widget.onCommand(
      EditorCommand(
        label: '删除预设',
        undo: () => _restoreDraft(before),
        redo: () => _restoreDraft(after),
      ),
    );
  }

  Future<void> _exportSelected() async {
    if (_selected.isEmpty) return;
    final picked = await FilePicker.platform.saveFile(
      dialogTitle: '导出所选预设',
      fileName: '${p.basenameWithoutExtension(_sessionPath)}_presets.xps',
      type: FileType.custom,
      allowedExtensions: const ['xps'],
    );
    if (picked == null) return;
    final destination = picked.toLowerCase().endsWith('.xps')
        ? picked
        : '$picked.xps';
    try {
      await _service.exportXps(
        sessionPath: _sessionPath,
        destination: destination,
        selectedIds: Set<int>.from(_selected),
        draft: _currentDraft,
      );
      if (mounted) _message('已导出 ${_selected.length} 个预设');
    } catch (error) {
      _message('$error');
    }
  }

  Future<void> _importSelected() async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['xps'],
    );
    final xpsPath = picked?.files.single.path;
    if (xpsPath == null || !mounted) return;
    try {
      final options = await _service.readXpsPresetNames(xpsPath);
      if (!mounted) return;
      final indexes = await showDialog<Set<int>>(
        context: context,
        builder: (context) => _PresetPickerDialog(presets: options),
      );
      if (indexes == null || indexes.isEmpty || !mounted) return;
      final imported = await _service.readXpsPresetData(xpsPath, indexes);
      if (!mounted) return;
      final before = _snapshotDraft();
      setState(() {
        for (final entry in imported) {
          final id = _nextDraftId--;
          var name = entry.name.trim().isEmpty ? 'Imported Preset' : entry.name;
          final base = name;
          var suffix = 2;
          final existingNames = _presets.map(_displayName).toSet();
          while (existingNames.any(
            (item) => item.toLowerCase() == name.toLowerCase(),
          )) {
            name = '$base ($suffix)';
            suffix++;
          }
          _presets.add(UserPreset(id: id, name: name));
          if (name != entry.name) _renames[id] = name;
          _importedXmlById[id] = entry.xml;
          _selected.add(id);
        }
        _emitDraft();
      });
      final after = _snapshotDraft();
      widget.onCommand(
        EditorCommand(
          label: '导入预设',
          undo: () => _restoreDraft(before),
          redo: () => _restoreDraft(after),
        ),
      );
      _message('已加入 ${imported.length} 个待保存预设');
    } catch (error) {
      if (mounted) {
        setState(() => _busy = false);
        _message('$error');
      }
    }
  }

  PresetEditDraft get _currentDraft => PresetEditDraft(
    orderedPresets: List.unmodifiable(_presets),
    renames: Map.unmodifiable(_renames),
    duplicateIds: Set.unmodifiable(_duplicates),
    deleteIds: Set.unmodifiable(_deletes),
    importedXmlById: Map.unmodifiable(_importedXmlById),
    reordered: _reordered,
  );

  PresetEditDraft _snapshotDraft() => _currentDraft;
  void _restoreDraft(PresetEditDraft draft) {
    setState(() {
      _presets = List.of(draft.orderedPresets);
      _renames
        ..clear()
        ..addAll(draft.renames);
      _duplicates
        ..clear()
        ..addAll(draft.duplicateIds);
      _deletes
        ..clear()
        ..addAll(draft.deleteIds);
      _importedXmlById
        ..clear()
        ..addAll(draft.importedXmlById);
      final validIds = draft.orderedPresets.map((preset) => preset.id).toSet();
      _selected.removeWhere((id) => !validIds.contains(id));
      _reordered = draft.reordered;
      _emitDraft();
    });
  }

  void _select(int id, bool selected) {
    setState(() {
      if (selected) {
        _selected.add(id);
      } else {
        _selected.remove(id);
      }
    });
  }

  void _changeSelection(Set<int> selection) {
    setState(() {
      _selected
        ..clear()
        ..addAll(selection);
    });
  }

  void _beginDragSelect(int id) {
    _dragSelecting = true;
    _dragTarget = !_selected.contains(id);
  }

  void _finishDragSelect() {
    if (!_dragSelecting) return;
    _dragSelecting = false;
    _dragTarget = null;
  }

  UserPreset? _presetAt(Offset position) {
    for (final preset in _presets) {
      final render = _rowKeys[preset.id]?.currentContext?.findRenderObject();
      if (render is! RenderBox || !render.hasSize) continue;
      final origin = render.localToGlobal(Offset.zero);
      if (position.dx >= origin.dx &&
          position.dx <= origin.dx + render.size.width &&
          position.dy >= origin.dy &&
          position.dy <= origin.dy + render.size.height) {
        return preset;
      }
    }
    return null;
  }

  String _displayName(UserPreset preset) => _renames[preset.id] ?? preset.name;

  @override
  Widget build(BuildContext context) => Focus(
    autofocus: true,
    onKeyEvent: (_, event) {
      if (event is KeyDownEvent &&
          event.logicalKey == LogicalKeyboardKey.escape &&
          _selected.isNotEmpty) {
        _changeSelection({});
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    },
    child: Column(
      children: [
        if (_busy) const LinearProgressIndicator(minHeight: 2),
        Expanded(
          child: Card(
            margin: const EdgeInsets.only(top: 2),
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                EditorActionBar(
                  actions: [
                    OutlinedButton.icon(
                      onPressed: _busy ? null : _importSelected,
                      icon: const Icon(Icons.file_open_rounded, size: 18),
                      label: const Text('导入 XPS'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _busy || _selected.isEmpty
                          ? null
                          : _exportSelected,
                      icon: const Icon(Icons.ios_share_rounded, size: 18),
                      label: const Text('导出所选'),
                    ),
                  ],
                  selection: _selectionToolbar(),
                ),
                const Divider(height: 1),
                Expanded(
                  child: _presets.isEmpty
                      ? const Center(child: Text('没有 User Presets'))
                      : Listener(
                          onPointerDown: (event) {
                            if (event.kind == PointerDeviceKind.mouse &&
                                (event.buttons & kPrimaryMouseButton) != 0) {
                              final item = _presetAt(event.position);
                              _pendingSelectionDown = event.position;
                              _pendingSelectionId = item?.id;
                            }
                          },
                          onPointerMove: (event) {
                            if ((event.buttons & kPrimaryMouseButton) == 0) {
                              return;
                            }
                            if (!_dragSelecting &&
                                _pendingSelectionDown != null &&
                                (event.position - _pendingSelectionDown!)
                                        .distance >
                                    5) {
                              final initialId = _pendingSelectionId;
                              if (initialId != null) {
                                _beginDragSelect(initialId);
                              }
                            }
                            if (!_dragSelecting) return;
                            final item = _presetAt(event.position);
                            if (item != null && _dragTarget != null) {
                              _select(item.id, _dragTarget!);
                            }
                          },
                          onPointerUp: (_) {
                            _finishDragSelect();
                            _pendingSelectionDown = null;
                            _pendingSelectionId = null;
                          },
                          onPointerCancel: (_) {
                            _finishDragSelect();
                            _pendingSelectionDown = null;
                            _pendingSelectionId = null;
                          },
                          child: ReorderableListView.builder(
                            buildDefaultDragHandles: false,
                            scrollController: _presetsScrollController,
                            itemCount: _presets.length,
                            onReorderItem: (oldIndex, newIndex) {
                              final before = List<UserPreset>.of(_presets);
                              setState(() {
                                final item = _presets.removeAt(oldIndex);
                                _presets.insert(newIndex, item);
                                _reordered = true;
                                _emitDraft();
                              });
                              final after = List<UserPreset>.of(_presets);
                              widget.onCommand(
                                EditorCommand(
                                  label: '调整预设顺序',
                                  undo: () => _restoreOrder(before),
                                  redo: () => _restoreOrder(after),
                                ),
                              );
                            },
                            itemBuilder: (context, index) {
                              final preset = _presets[index];
                              final deleted = _deletes.contains(preset.id);
                              final key = _rowKeys.putIfAbsent(
                                preset.id,
                                GlobalKey.new,
                              );
                              return ListTile(
                                key: ValueKey(preset.id),
                                subtitle:
                                    _importedXmlById.containsKey(preset.id)
                                    ? const Text('待保存')
                                    : null,
                                leading: SelectableIndexBadge(
                                  key: key,
                                  index: '${index + 1}'.padLeft(2, '0'),
                                  selected: _selected.contains(preset.id),
                                  onTap: deleted
                                      ? null
                                      : () => _select(
                                          preset.id,
                                          !_selected.contains(preset.id),
                                        ),
                                  width: 40,
                                  height: 38,
                                ),
                                title: Text(
                                  _displayName(preset),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: deleted
                                      ? const TextStyle(
                                          decoration:
                                              TextDecoration.lineThrough,
                                        )
                                      : null,
                                ),
                                onTap: null,
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    IconButton(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.onSurfaceVariant,
                                      tooltip: '重命名',
                                      onPressed: deleted
                                          ? null
                                          : () => _rename(preset),
                                      icon: const Icon(Icons.edit_rounded),
                                    ),
                                    IconButton(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.onSurfaceVariant,
                                      tooltip: '复制',
                                      onPressed: deleted
                                          ? null
                                          : () => _duplicate(preset),
                                      icon: const Icon(
                                        Icons.control_point_duplicate_rounded,
                                      ),
                                    ),
                                    IconButton(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.onSurfaceVariant,
                                      tooltip: '删除',
                                      onPressed: deleted
                                          ? null
                                          : () => _deletePreset(preset),
                                      icon: const Icon(
                                        Icons.delete_outline_rounded,
                                      ),
                                    ),
                                    const SizedBox(width: 24),
                                    Tooltip(
                                      message: '拖动调整预设顺序',
                                      child: ReorderableDragStartListener(
                                        index: index,
                                        child: const Padding(
                                          padding: EdgeInsets.all(10),
                                          child: Icon(
                                            Icons.drag_handle_rounded,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                        ),
                ),
              ],
            ),
          ),
        ),
      ],
    ),
  );

  void _restoreOrder(List<UserPreset> order) => setState(() {
    _presets = List.of(order);
    _reordered = !listEquals(
      _presets.map((preset) => preset.id).where((id) => id > 0).toList(),
      _originalOrder,
    );
    _emitDraft();
  });

  Widget _selectionToolbar() => EditorSelectionToolbar(
    count: _selected.length,
    onSelectAll: () => _changeSelection(
      _presets
          .where((preset) => !_deletes.contains(preset.id))
          .map((preset) => preset.id)
          .toSet(),
    ),
    onClear: () => _changeSelection({}),
    onInvert: () => _changeSelection(
      _presets
          .where(
            (preset) =>
                !_deletes.contains(preset.id) && !_selected.contains(preset.id),
          )
          .map((preset) => preset.id)
          .toSet(),
    ),
    onCopy: _selected.length == 1
        ? () => _duplicate(
            _presets.firstWhere((preset) => preset.id == _selected.first),
          )
        : null,
    onDelete: _markDelete,
  );
}

class _PresetPickerDialog extends StatefulWidget {
  const _PresetPickerDialog({required this.presets});
  final List<XpsPresetInfo> presets;

  @override
  State<_PresetPickerDialog> createState() => _PresetPickerDialogState();
}

class _PresetPickerDialogState extends State<_PresetPickerDialog> {
  final Set<int> _selected = {};

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('选择预设 · ${widget.presets.length}'),
    content: SizedBox(
      width: 480,
      height: 480,
      child: ListView.builder(
        itemCount: widget.presets.length,
        itemBuilder: (context, index) {
          final preset = widget.presets[index];
          return CheckboxListTile(
            value: _selected.contains(preset.index),
            title: Text(
              preset.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            onChanged: (value) => setState(() {
              if (value == true) {
                _selected.add(preset.index);
              } else {
                _selected.remove(preset.index);
              }
            }),
          );
        },
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, _selected),
        child: const Text('导入'),
      ),
    ],
  );
}

class _PresetNameDialog extends StatefulWidget {
  const _PresetNameDialog({
    required this.title,
    required this.initialName,
    required this.confirmLabel,
    this.fieldLabel,
  });

  final String title;
  final String initialName;
  final String confirmLabel;
  final String? fieldLabel;

  @override
  State<_PresetNameDialog> createState() => _PresetNameDialogState();
}

class _PresetNameDialogState extends State<_PresetNameDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialName,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: TextField(
      controller: _controller,
      autofocus: true,
      decoration: widget.fieldLabel == null
          ? null
          : InputDecoration(labelText: widget.fieldLabel),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, _controller.text.trim()),
        child: Text(widget.confirmLabel),
      ),
    ],
  );
}
