import 'package:flutter/foundation.dart';

class SessionSnapshot {
  const SessionSnapshot({
    required this.id,
    required this.number,
    required this.name,
    required this.rackCount,
  });

  final int id;
  final int number;
  final String name;
  final int rackCount;
}

class UserPreset {
  const UserPreset({required this.id, required this.name});

  final int id;
  final String name;
}

class XpsPresetInfo {
  const XpsPresetInfo({required this.name, required this.index});

  final String name;
  final int index;
}

class XpsPresetData {
  const XpsPresetData({
    required this.index,
    required this.name,
    required this.xml,
  });

  final int index;
  final String name;
  final String xml;
}

class PresetEditDraft {
  const PresetEditDraft({
    required this.orderedPresets,
    required this.renames,
    required this.duplicateIds,
    required this.deleteIds,
    required this.importedXmlById,
    required this.reordered,
  });

  final List<UserPreset> orderedPresets;
  final Map<int, String> renames;
  final Set<int> duplicateIds;
  final Set<int> deleteIds;
  final Map<int, String> importedXmlById;
  final bool reordered;

  bool get hasChanges =>
      renames.isNotEmpty ||
      duplicateIds.isNotEmpty ||
      deleteIds.isNotEmpty ||
      importedXmlById.keys.any((id) => !deleteIds.contains(id)) ||
      reordered;
}

class MatrixEditDraft {
  const MatrixEditDraft({
    required this.snapshotId,
    required this.rackOn,
    required this.rackRecallSafe,
    required this.pluginBypass,
    required this.pluginRecallSafe,
  });

  final int snapshotId;
  final Map<int, bool> rackOn;
  final Map<int, bool> rackRecallSafe;
  final Map<int, bool> pluginBypass;
  final Map<int, bool> pluginRecallSafe;

  bool get hasChanges =>
      rackOn.isNotEmpty ||
      rackRecallSafe.isNotEmpty ||
      pluginBypass.isNotEmpty ||
      pluginRecallSafe.isNotEmpty;
}

/// One user-visible edit transaction for global undo and redo.
class EditorCommand {
  const EditorCommand({
    required this.label,
    required this.undo,
    required this.redo,
  });

  final String label;
  final VoidCallback undo;
  final VoidCallback redo;
}

class MatrixPlugin {
  const MatrixPlugin({
    required this.id,
    required this.slot,
    required this.name,
    required this.bypass,
    required this.recallSafe,
  });

  final int id;
  final int slot;
  final String name;
  final bool bypass;
  final bool recallSafe;
}

class MatrixRack {
  const MatrixRack({
    required this.id,
    required this.number,
    required this.name,
    required this.isOn,
    required this.recallSafe,
    required this.plugins,
  });

  final int id;
  final int number;
  final String name;
  final bool isOn;
  final bool recallSafe;
  final List<MatrixPlugin> plugins;
}

class SessionBlueprint {
  const SessionBlueprint({
    required this.rackNames,
    required this.snapshotNames,
    required this.namesBySnapshot,
  });

  final List<String> rackNames;
  final List<String> snapshotNames;
  final Map<String, List<String>> namesBySnapshot;
}
