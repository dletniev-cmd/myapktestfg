import 'package:flutter/material.dart';

import '../iconify.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/common.dart';

class FilesScreen extends StatefulWidget {
  const FilesScreen({super.key});
  @override
  State<FilesScreen> createState() => _FilesScreenState();
}

class _FilesScreenState extends State<FilesScreen> {
  String _filter = 'all';
  double _headerH = 0;

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    final files = AppState.I.stagedFiles;
    final existing = AppState.I.existingPaths;
    final entries = files.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    final filtered = entries.where((e) {
      final isMod = existing.contains(e.key);
      if (_filter == 'new') return !isMod;
      if (_filter == 'mod') return isMod;
      return true;
    }).toList();

    final newCount = entries.where((e) => !existing.contains(e.key)).length;
    final modCount = entries.length - newCount;

    final topPad = _headerH > 0
        ? _headerH
        : MediaQuery.of(context).padding.top + 200;

    return Scaffold(
      backgroundColor: pal.bg,
      body: Stack(
        children: [
          // Список файлов скроллится ПОД sticky-шапкой (с тем же мягким
          // градиент-фейдом, что и в разделе Actions). Из-за этого верхние
          // карточки плавно «уходят» под градиент при скролле, а не
          // обрываются за чипами.
          Positioned.fill(
            child: ListView.separated(
              physics: const BouncingScrollPhysics(),
              padding: EdgeInsets.fromLTRB(18, topPad, 18, 32),
              itemCount: filtered.length + 1,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (_, i) {
                if (i == filtered.length) {
                  return Padding(
                    padding: const EdgeInsets.only(top: 18),
                    child: PushButton(
                      label: 'Готово',
                      icon: 'solar:check-circle-bold',
                      onTap: () => Navigator.of(context).pop(),
                    ),
                  );
                }
                final e = filtered[i];
                final isMod = existing.contains(e.key);
                return _FileRow(
                  path: e.key,
                  size: e.value.length,
                  isMod: isMod,
                  onDelete: () {
                    setState(() {
                      files.remove(e.key);
                    });
                    AppState.I.touch();
                  },
                );
              },
            ),
          ),
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
                // Title row: back + title
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 0, 18, 14),
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
                          'Файлы',
                          style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -.4,
                            height: 1.15,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                // Stat boxes row
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 0, 18, 12),
                  child: Row(
                    children: [
                      Expanded(
                          child: _StatBox(
                              value: '${entries.length}',
                              label: 'ВСЕГО')),
                      const SizedBox(width: 8),
                      Expanded(
                          child: _StatBox(
                              value: '$newCount',
                              label: 'НОВЫЕ',
                              color: AppColors.green)),
                      const SizedBox(width: 8),
                      Expanded(
                          child: _StatBox(
                              value: '$modCount',
                              label: 'ИЗМЕНЕНЫ',
                              color: AppColors.orange)),
                    ],
                  ),
                ),
                // Filter chips
                SizedBox(
                  height: 38,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    physics: const BouncingScrollPhysics(),
                    padding: const EdgeInsets.symmetric(horizontal: 18),
                    children: [
                      _Chip(
                          label: 'Все',
                          active: _filter == 'all',
                          onTap: () => setState(() => _filter = 'all')),
                      const SizedBox(width: 8),
                      _Chip(
                          label: 'Новые',
                          active: _filter == 'new',
                          onTap: () => setState(() => _filter = 'new')),
                      const SizedBox(width: 8),
                      _Chip(
                          label: 'Изменены',
                          active: _filter == 'mod',
                          onTap: () => setState(() => _filter = 'mod')),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Компактная плашка статистики. Раньше использовался BackdropFilter
/// (runtime-блюр под плашкой) — это дорого и на медленных устройствах
/// заметно тормозит, особенно когда таких плашек в Row три-четыре штуки.
/// Заменили на сплошной полупрозрачный фон pal.cont с alpha — визуально
/// разницы почти не видно (под плашками всё равно однородный фон pal.bg).
class _StatBox extends StatelessWidget {
  final String value;
  final String label;
  final Color? color;
  const _StatBox(
      {required this.value, required this.label, this.color});
  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: pal.cont,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Text(
                value,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  color: color ?? pal.text,
                  letterSpacing: -.3,
                  height: 1.1,
                ),
              ),
              const SizedBox(height: 1),
              Text(
                label,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 10,
                  color: pal.sub,
                  fontWeight: FontWeight.w600,
                  letterSpacing: .3,
                  height: 1.1,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Чип фильтра «Все / Новые / Изменены» (баг n3976): теперь со
/// «стеклянным» blur-фоном как у остальных чипов. Внутреннее
/// центрирование текста делает сам [CtChip] (alignment.center в
/// контейнере).
class _Chip extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;
  const _Chip(
      {required this.label, required this.active, required this.onTap});
  @override
  Widget build(BuildContext context) {
    return CtChip(label: label, active: active, onTap: onTap);
  }
}

class _FileRow extends StatelessWidget {
  final String path;
  final int size;
  final bool isMod;
  final VoidCallback onDelete;
  const _FileRow({
    required this.path,
    required this.size,
    required this.isMod,
    required this.onDelete,
  });

  String _fmt(int b) {
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
    return '${(b / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    final iconName = _iconForPath(path);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: pal.cont,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: pal.cont2,
              borderRadius: BorderRadius.circular(10),
            ),
            alignment: Alignment.center,
            child: Iconify(iconName, size: 20, color: AppColors.accent),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(path,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: pal.text,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
                const SizedBox(height: 2),
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: (isMod
                                ? AppColors.orange
                                : AppColors.green)
                            .withValues(alpha: 0.16),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        isMod ? 'MOD' : 'NEW',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          color: isMod ? AppColors.orange : AppColors.green,
                          letterSpacing: .3,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(_fmt(size),
                        style:
                            TextStyle(fontSize: 12, color: pal.sub)),
                  ],
                ),
              ],
            ),
          ),
          PressScale(
            onTap: onDelete,
            scale: 0.92,
            child: Container(
              width: 32,
              height: 32,
              alignment: Alignment.center,
              child: Iconify('solar:close-circle-linear',
                  size: 18, color: pal.sub),
            ),
          ),
        ],
      ),
    );
  }
}

String _iconForPath(String path) {
  final lower = path.toLowerCase();
  if (lower.endsWith('.dart') ||
      lower.endsWith('.js') ||
      lower.endsWith('.ts') ||
      lower.endsWith('.kt') ||
      lower.endsWith('.java') ||
      lower.endsWith('.swift') ||
      lower.endsWith('.py')) {
    return 'solar:settings-bold';
  }
  if (lower.endsWith('.png') ||
      lower.endsWith('.jpg') ||
      lower.endsWith('.jpeg') ||
      lower.endsWith('.gif') ||
      lower.endsWith('.svg') ||
      lower.endsWith('.webp')) {
    return 'solar:gallery-add-bold';
  }
  if (lower.endsWith('.md') ||
      lower.endsWith('.txt') ||
      lower.endsWith('.json') ||
      lower.endsWith('.yaml') ||
      lower.endsWith('.yml') ||
      lower.endsWith('.xml')) {
    return 'solar:document-text-bold';
  }
  return 'solar:document-text-bold';
}
