import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../models/session_tools.dart';
import '../services/session_blueprint_parser.dart';
import '../services/session_service.dart';
import '../services/session_tools_service.dart';

class CreateSessionScreen extends StatefulWidget {
  const CreateSessionScreen({super.key});

  @override
  State<CreateSessionScreen> createState() => _CreateSessionScreenState();
}

class _CreateSessionScreenState extends State<CreateSessionScreen> {
  final _parser = const SessionBlueprintParser();
  final _service = const SessionToolsService();
  final _channels = TextEditingController();
  final _snapshots = TextEditingController();
  String? _error;
  bool _busy = false;
  SessionBlueprint? _preview;

  @override
  void dispose() {
    _channels.dispose();
    _snapshots.dispose();
    super.dispose();
  }

  void _updatePreview() {
    try {
      final parsed = _parser.plainText(_channels.text, _snapshots.text);
      setState(() {
        _preview = parsed;
        _error = null;
      });
    } on SessionException catch (e) {
      setState(() {
        _preview = null;
        _error = e.message;
      });
    }
  }

  Future<void> _importCsv(TextEditingController target) async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['csv'],
    );
    final path = result?.files.single.path;
    if (path == null || !mounted) return;
    try {
      final names = _parser.singleColumnCsv(await File(path).readAsString());
      target.text = names.join('\n');
      _updatePreview();
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('已导入 ${names.length} 个名称')));
      }
    } on SessionException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.message)));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('读取 CSV 失败：$error')));
      }
    }
  }

  String _withSprkExtension(String path) {
    final stripped = path.replaceFirst(
      RegExp(r'(?:\.sprk)+$', caseSensitive: false),
      '.sprk',
    );
    return stripped.toLowerCase().endsWith('.sprk') ? stripped : '$path.sprk';
  }

  Future<void> _create() async {
    _updatePreview();
    final blueprint = _preview;
    if (blueprint == null) return;
    final picked = await FilePicker.platform.saveFile(
      dialogTitle: '创建 SuperRack 会话',
      fileName: 'Untitled',
      type: FileType.custom,
      allowedExtensions: const ['sprk'],
    );
    if (picked == null || !mounted) return;
    final destination = _withSprkExtension(picked);
    setState(() => _busy = true);
    Directory? stageDirectory;
    try {
      final bytes = await rootBundle.load('assets/Empty Session.sprk');
      stageDirectory = await Directory.systemTemp.createTemp(
        'superrack-template-',
      );
      final template = File(p.join(stageDirectory.path, 'Empty Session.sprk'));
      await template.writeAsBytes(bytes.buffer.asUint8List(), flush: true);
      await _service.createSession(
        templatePath: template.path,
        destination: destination,
        blueprint: blueprint,
      );
      if (!mounted) return;
      Navigator.pop(context, destination);
    } catch (error) {
      if (mounted) {
        setState(() => _busy = false);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$error')));
      }
    } finally {
      if (stageDirectory != null && await stageDirectory.exists()) {
        await stageDirectory.delete(recursive: true);
      }
    }
  }

  Widget _nameEditor({
    required String title,
    required String hint,
    required TextEditingController controller,
    required String importLabel,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
      const SizedBox(height: 6),
      Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton.icon(
          onPressed: _busy ? null : () => _importCsv(controller),
          icon: const Icon(Icons.upload_file_rounded),
          label: Text(importLabel),
        ),
      ),
      const SizedBox(height: 8),
      Expanded(
        child: TextField(
          controller: controller,
          enabled: !_busy,
          maxLines: null,
          expands: true,
          textAlignVertical: TextAlignVertical.top,
          decoration: InputDecoration(hintText: hint, alignLabelWithHint: true),
          onChanged: (_) => _updatePreview(),
        ),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('新建工程')),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 920),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '每行一个名称。CSV 只需一列；导入会覆盖对应的名称框。',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      flex: 2,
                      child: _nameEditor(
                        title: '通道名称',
                        hint: '每行一个通道名称',
                        controller: _channels,
                        importLabel: '导入通道名',
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _nameEditor(
                        title: '新建 Snapshot（可选）',
                        hint: '留空以保留模板中的 Snapshot；如需新增，每行填写一个名称',
                        controller: _snapshots,
                        importLabel: '导入 Snapshot 名',
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _error ??
                          (_preview == null
                              ? '输入通道名称以预览工程'
                              : '${_preview!.rackNames.length} 个通道 · '
                                    '${_preview!.snapshotNames.isEmpty ? '保留模板 Snapshot' : '新增 ${_preview!.snapshotNames.length} 个 Snapshot'}'),
                      style: TextStyle(
                        color: _error == null
                            ? Theme.of(context).colorScheme.onSurfaceVariant
                            : Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                  FilledButton.icon(
                    onPressed: _busy || _preview == null ? null : _create,
                    icon: _busy
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.add_rounded),
                    label: const Text('创建 .sprk'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
