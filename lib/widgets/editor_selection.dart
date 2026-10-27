import 'package:flutter/material.dart';

class SelectableIndexBadge extends StatelessWidget {
  const SelectableIndexBadge({
    super.key,
    required this.index,
    required this.selected,
    this.onTap,
    this.width = 48,
    this.height = 38,
  });

  final String index;
  final bool selected;
  final VoidCallback? onTap;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOutCubic,
        width: width,
        height: height,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected
              ? colors.primaryContainer
              : colors.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(
          index,
          style: TextStyle(
            fontWeight: FontWeight.w700,
            color: selected ? colors.primary : colors.onSurfaceVariant,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ),
    );
  }
}

class EditorSelectionToolbar extends StatelessWidget {
  const EditorSelectionToolbar({
    super.key,
    required this.count,
    required this.onSelectAll,
    required this.onClear,
    required this.onInvert,
    this.onCopy,
    this.onDelete,
  });

  final int count;
  final VoidCallback onSelectAll;
  final VoidCallback onClear;
  final VoidCallback onInvert;
  final VoidCallback? onCopy;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return PopupMenuButton<String>(
      tooltip: '选择操作',
      onSelected: (action) {
        switch (action) {
          case 'all':
            onSelectAll();
          case 'clear':
            onClear();
          case 'invert':
            onInvert();
          case 'copy':
            onCopy?.call();
          case 'delete':
            onDelete?.call();
        }
      },
      itemBuilder: (_) => [
        const PopupMenuItem(value: 'all', child: Text('全选')),
        const PopupMenuItem(value: 'clear', child: Text('全不选')),
        const PopupMenuItem(value: 'invert', child: Text('反选')),
        if (onCopy != null)
          PopupMenuItem(
            value: 'copy',
            enabled: count == 1,
            child: const Text('复制'),
          ),
        if (onDelete != null)
          PopupMenuItem(
            value: 'delete',
            enabled: count > 0,
            child: const Text('删除'),
          ),
      ],
      child: Container(
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: colors.secondaryContainer,
          borderRadius: BorderRadius.circular(18),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.checklist_rounded,
              size: 18,
              color: colors.onSecondaryContainer,
            ),
            const SizedBox(width: 8),
            Text(
              '$count 已选',
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: colors.onSecondaryContainer,
              ),
            ),
            const SizedBox(width: 4),
            Icon(
              Icons.expand_more_rounded,
              size: 18,
              color: colors.onSecondaryContainer,
            ),
          ],
        ),
      ),
    );
  }
}

/// Shared single-row action bar keeps all editors aligned to the same inset.
class EditorActionBar extends StatelessWidget {
  const EditorActionBar({
    super.key,
    required this.actions,
    required this.selection,
  });
  final List<Widget> actions;
  final Widget selection;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
    child: Row(
      children: [
        Expanded(
          child: OutlinedButtonTheme(
            data: OutlinedButtonThemeData(
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(0, 36),
                padding: const EdgeInsets.symmetric(horizontal: 12),
              ),
            ),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (var i = 0; i < actions.length; i++) ...[
                    if (i > 0) const SizedBox(width: 8),
                    actions[i],
                  ],
                ],
              ),
            ),
          ),
        ),
        const SizedBox(width: 16),
        selection,
      ],
    ),
  );
}
