import 'package:flutter/material.dart';

import '../api.dart';
import '../iconify.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/common.dart';

class RepoTreeScreen extends StatefulWidget {
  final GhRepo repo;
  const RepoTreeScreen({super.key, required this.repo});
  @override
  State<RepoTreeScreen> createState() => _RepoTreeScreenState();
}

class _RepoTreeScreenState extends State<RepoTreeScreen> {
  bool _loading = true;
  String? _error;
  // Корень дерева: пустой путь '' = корень репозитория.
  _TreeNode _root = _TreeNode(name: '', isDir: true);
  // Раскрытые папки (путь относительно корня). Корень всегда раскрыт.
  final Set<String> _expanded = {''};
  // Замеренная высота sticky-шапки — нужна, чтобы задать верхний padding
  // прокрутке так, чтобы первая ветка не пряталась под градиентом.
  double _headerH = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final entries = await AppState.I.api!
          .repoTree(widget.repo.fullName, widget.repo.defaultBranch);
      setState(() {
        _root = _buildTree(entries);
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  // ------------------------------------------------------------------------
  // Дерево
  // ------------------------------------------------------------------------

  _TreeNode _buildTree(List<GhTreeEntry> entries) {
    final root = _TreeNode(name: '', isDir: true);
    for (final e in entries) {
      final parts = e.path.split('/');
      var node = root;
      for (var i = 0; i < parts.length; i++) {
        final isLast = i == parts.length - 1;
        final name = parts[i];
        final existing = node.childByName(name);
        if (existing != null) {
          node = existing;
          continue;
        }
        final child = _TreeNode(
          name: name,
          isDir: !isLast || e.type == 'tree',
          size: isLast ? e.size : 0,
          fullPath: parts.sublist(0, i + 1).join('/'),
        );
        node.children.add(child);
        node = child;
      }
    }
    _sortRecursive(root);
    return root;
  }

  void _sortRecursive(_TreeNode n) {
    n.children.sort((a, b) {
      if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    for (final c in n.children) {
      if (c.isDir) _sortRecursive(c);
    }
  }

  // Линейный список «видимых» узлов (учитывая, какие папки раскрыты).
  List<_VisibleNode> _flatten() {
    final out = <_VisibleNode>[];
    void walk(_TreeNode n, int depth) {
      for (final c in n.children) {
        out.add(_VisibleNode(node: c, depth: depth));
        if (c.isDir && _expanded.contains(c.fullPath)) {
          walk(c, depth + 1);
        }
      }
    }

    walk(_root, 0);
    return out;
  }

  void _toggle(_TreeNode n) {
    if (!n.isDir) return;
    setState(() {
      if (_expanded.contains(n.fullPath)) {
        _expanded.remove(n.fullPath);
      } else {
        _expanded.add(n.fullPath);
      }
    });
  }

  String _format(int b) {
    if (b <= 0) return '';
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
    return '${(b / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  // ------------------------------------------------------------------------
  // Build
  // ------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;

    // Глобальная статистика по всему дереву.
    int totalFiles = 0;
    int totalFolders = 0;
    void countAll(_TreeNode n) {
      for (final c in n.children) {
        if (c.isDir) {
          totalFolders++;
          countAll(c);
        } else {
          totalFiles++;
        }
      }
    }

    if (!_loading && _error == null) countAll(_root);

    final visible = (!_loading && _error == null) ? _flatten() : <_VisibleNode>[];

    final topPad = _headerH > 0
        ? _headerH
        : MediaQuery.of(context).padding.top + 140;

    return Scaffold(
      backgroundColor: pal.bg,
      body: Stack(
        children: [
          Positioned.fill(
            child: _loading
                ? Center(
                    child: CircularProgressIndicator(
                        color: AppColors.accent, strokeCap: StrokeCap.round))
                : _error != null
                    ? Padding(
                        padding: EdgeInsets.fromLTRB(18, topPad, 18, 32),
                        child: Center(
                          child: Text(_error!,
                              style: TextStyle(color: pal.sub)),
                        ),
                      )
                    : ListView.separated(
                        physics: const BouncingScrollPhysics(),
                        padding: EdgeInsets.fromLTRB(18, topPad, 18, 32),
                        itemCount: visible.length,
                        // Без фоновых плашек у строк сама плотная сетка
                        // выглядит лучше — убираем лишний gap, оставляем
                        // нулевой разделитель.
                        separatorBuilder: (_, __) => const SizedBox.shrink(),
                        itemBuilder: (_, i) {
                          final v = visible[i];
                          return _TreeRow(
                            node: v.node,
                            depth: v.depth,
                            expanded: _expanded.contains(v.node.fullPath),
                            sizeLabel: _format(v.node.size),
                            onTap: () => _toggle(v.node),
                          );
                        },
                      ),
          ),
          // Sticky-шапка: заголовок + компактные плашки статистики.
          // Всё лежит над контентом и градиентом-фейдом — список под
          // ней мягко растворяется при скролле.
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: StickyTabHeader(
              padding: const EdgeInsets.fromLTRB(0, 8, 0, 12),
              onHeightChanged: (h) {
                if ((h - _headerH).abs() > 0.5) {
                  setState(() => _headerH = h);
                }
              },
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(6, 0, 12, 0),
                  child: Row(
                    children: [
                      IconBtn(
                        icon: 'solar:alt-arrow-left-linear',
                        iconSize: 20,
                        size: 36,
                        onTap: () => Navigator.of(context).maybePop(),
                      ),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: Text(
                          'Карта репозитория',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -.4,
                            height: 1.15,
                          ),
                        ),
                      ),
                      IconBtn(
                        icon: 'solar:refresh-bold',
                        iconSize: 22,
                        size: 36,
                        onTap: _load,
                      ),
                    ],
                  ),
                ),
                if (!_loading && _error == null) ...[
                  const SizedBox(height: 10),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 18),
                    child: Row(
                      children: [
                        _MiniStat(num: '$totalFiles', label: 'файлов'),
                        const SizedBox(width: 6),
                        const _MiniStat(
                            num: '0',
                            label: 'локальных',
                            numColor: AppColors.green),
                        const SizedBox(width: 6),
                        _MiniStat(num: '$totalFolders', label: 'папок'),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Row, Stat, helpers
// ---------------------------------------------------------------------------

class _MiniStat extends StatelessWidget {
  final String num;
  final String label;
  final Color? numColor;
  const _MiniStat({required this.num, required this.label, this.numColor});
  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    // Раньше плашки были массивными (22pt цифры, vert padding 14). Теперь
    // делаем их компактнее и менее шумными — 16pt цифры, padding 8/10.
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
        decoration: BoxDecoration(
          color: pal.cont,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(num,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  color: numColor ?? pal.text,
                  height: 1.0,
                )),
            const SizedBox(width: 5),
            Flexible(
              child: Text(label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    color: pal.sub,
                    height: 1.1,
                  )),
            ),
          ],
        ),
      ),
    );
  }
}

class _TreeRow extends StatelessWidget {
  final _TreeNode node;
  final int depth;
  final bool expanded;
  final String sizeLabel;
  final VoidCallback onTap;
  const _TreeRow({
    required this.node,
    required this.depth,
    required this.expanded,
    required this.sizeLabel,
    required this.onTap,
  });
  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    final isDir = node.isDir;
    // Без фоновой плашки у строки — как в HTML-эталоне (.tree-row).
    // Сами строки сидят в общей карточке-фоне `pal.cont` уровня выше,
    // поэтому отдельные контейнеры тут лишний шум.
    return PressScale(
      onTap: isDir ? onTap : null,
      scale: 0.99,
      child: Padding(
        padding: EdgeInsets.only(left: depth * 18.0),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          child: Row(
            children: [
              SizedBox(
                width: 14,
                child: isDir
                    ? AnimatedRotation(
                        duration: const Duration(milliseconds: 180),
                        turns: expanded ? 0.25 : 0.0,
                        child: Iconify('solar:alt-arrow-right-linear',
                            size: 13, color: pal.sub),
                      )
                    : const SizedBox(),
              ),
              const SizedBox(width: 8),
              Iconify(
                isDir ? 'solar:folder-bold' : 'solar:document-text-bold',
                size: 18,
                color: isDir ? AppColors.accent : pal.sub,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(node.name,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: pal.text,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
              ),
              if (!isDir && sizeLabel.isNotEmpty)
                Text(sizeLabel,
                    style: TextStyle(
                      fontSize: 11,
                      color: pal.sub,
                    )),
            ],
          ),
        ),
      ),
    );
  }
}

class _TreeNode {
  final String name;
  final bool isDir;
  final int size;
  final String fullPath;
  final List<_TreeNode> children = [];
  _TreeNode({
    required this.name,
    required this.isDir,
    this.size = 0,
    this.fullPath = '',
  });

  _TreeNode? childByName(String name) {
    for (final c in children) {
      if (c.name == name) return c;
    }
    return null;
  }
}

class _VisibleNode {
  final _TreeNode node;
  final int depth;
  _VisibleNode({required this.node, required this.depth});
}
