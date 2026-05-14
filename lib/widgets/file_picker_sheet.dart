import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';

import '../iconify.dart';
import '../theme.dart';
import 'common.dart';
import 'm3_loading.dart';

/// Результат выбора файла из [pickFileBottomSheet].
class PickedFile {
  final String name;
  final Uint8List bytes;
  const PickedFile({required this.name, required this.bytes});
}

/// Открывает кастомный bottom-sheet для выбора файла с устройства.
/// Возвращает [PickedFile] или `null`, если пользователь закрыл шит.
///
/// Юзер просил: «при заливке файлов... сделай свою собственную панель».
/// Раньше тут вызывался FilePicker.platform.pickFiles, который
/// открывает СИСТЕМНУЮ панель Android'а (тёмная, без скруглений, не
/// в стиле приложения). Теперь — наш шит:
///   • bottom-sheet в стиле приложения (рандиус, palette);
///   • быстрый доступ к Download / Documents / DCIM / приложению;
///   • переход по папкам + хлебные крошки;
///   • файлы фильтруются по [allowedExtensions] (например `['zip']`);
///   • если прямой доступ к /storage/emulated/0/Download не работает
///     (новые Android'ы со scoped storage без MANAGE_EXTERNAL_STORAGE),
///     показываем кнопку «Открыть системную панель» как fallback —
///     юзер всё равно сможет найти свой ZIP, просто через SAF.
///
/// [allowedExtensions] — расширения без точки (`['zip']`). Если null,
/// показываем все файлы.
Future<PickedFile?> pickFileBottomSheet(
  BuildContext context, {
  List<String>? allowedExtensions,
}) async {
  return showModalBottomSheet<PickedFile?>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.55),
    transitionAnimationController: AnimationController(
      vsync: Navigator.of(context),
      duration: const Duration(milliseconds: 380),
      reverseDuration: const Duration(milliseconds: 260),
    ),
    builder: (_) => _FilePickerSheet(allowedExtensions: allowedExtensions),
  );
}

class _FilePickerSheet extends StatefulWidget {
  final List<String>? allowedExtensions;
  const _FilePickerSheet({this.allowedExtensions});

  @override
  State<_FilePickerSheet> createState() => _FilePickerSheetState();
}

/// Одна запись в списке: либо папка, либо файл.
class _Entry {
  final String name;
  final String path;
  final bool isDir;
  final int size;
  final DateTime? modified;
  const _Entry({
    required this.name,
    required this.path,
    required this.isDir,
    required this.size,
    this.modified,
  });
}

/// Корневые «закладки» для быстрого доступа.
class _Root {
  final String label;
  final String path;
  final String icon;
  const _Root(this.label, this.path, this.icon);
}

class _FilePickerSheetState extends State<_FilePickerSheet> {
  /// Текущий путь. `null` → главный экран со списком корней.
  String? _path;
  List<_Entry> _entries = const [];
  bool _loading = false;
  String? _error;
  bool _opening = false;

  List<_Root> _roots = const [];

  @override
  void initState() {
    super.initState();
    _initRoots();
  }

  /// Заполняет список корней. /storage/emulated/0 — основная карта на
  /// Android'е, а internal-папка приложения — на случай если есть
  /// staged ZIP'ы там.
  Future<void> _initRoots() async {
    final roots = <_Root>[
      const _Root('Загрузки', '/storage/emulated/0/Download',
          'solar:download-square-bold'),
      const _Root('Документы', '/storage/emulated/0/Documents',
          'solar:document-text-bold'),
      const _Root(
          'DCIM', '/storage/emulated/0/DCIM', 'solar:gallery-add-bold'),
      const _Root('Внутренняя память', '/storage/emulated/0',
          'solar:ssd-square-bold'),
    ];
    // Папка приложения — туда можно сохранять ZIP'ы через share-меню.
    try {
      final appDir = await getApplicationDocumentsDirectory();
      roots.add(
          _Root('Папка приложения', appDir.path, 'solar:folder-with-files-bold'));
    } catch (_) {/* не критично */}
    if (mounted) setState(() => _roots = roots);
  }

  /// Открывает папку и подгружает её содержимое. Если путь недоступен —
  /// выставляет [_error] и оставляет _entries пустым.
  Future<void> _open(String path) async {
    setState(() {
      _loading = true;
      _error = null;
      _path = path;
      _entries = const [];
    });
    try {
      final dir = Directory(path);
      if (!await dir.exists()) {
        if (!mounted) return;
        setState(() {
          _loading = false;
          _error = 'Папка не найдена';
        });
        return;
      }
      final raw = await dir.list(followLinks: false).toList();
      final entries = <_Entry>[];
      for (final fse in raw) {
        try {
          final st = await fse.stat();
          final name = fse.path.split('/').last;
          if (name.startsWith('.')) continue; // скрытые
          if (st.type == FileSystemEntityType.directory) {
            entries.add(_Entry(
              name: name,
              path: fse.path,
              isDir: true,
              size: 0,
              modified: st.modified,
            ));
          } else if (st.type == FileSystemEntityType.file) {
            // Фильтрация по расширению.
            final allowed = widget.allowedExtensions;
            if (allowed != null && allowed.isNotEmpty) {
              final ext = name.contains('.')
                  ? name.split('.').last.toLowerCase()
                  : '';
              if (!allowed.contains(ext)) continue;
            }
            entries.add(_Entry(
              name: name,
              path: fse.path,
              isDir: false,
              size: st.size,
              modified: st.modified,
            ));
          }
        } catch (_) {/* пропускаем недоступные элементы */}
      }
      entries.sort((a, b) {
        if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
      if (!mounted) return;
      setState(() {
        _loading = false;
        _entries = entries;
      });
    } catch (e) {
      if (!mounted) return;
      // Самый частый кейс на Android 11+: scoped storage блокирует
      // прямой доступ к /storage/emulated/0/Download. Показываем
      // дружелюбное сообщение + кнопку открыть системную панель.
      setState(() {
        _loading = false;
        _error = 'Нет доступа к этой папке';
      });
    }
  }

  void _goUp() {
    final p = _path;
    if (p == null) return;
    final idx = p.lastIndexOf('/');
    if (idx <= 0) {
      setState(() {
        _path = null;
        _entries = const [];
        _error = null;
      });
      return;
    }
    _open(p.substring(0, idx));
  }

  Future<void> _selectFile(_Entry e) async {
    if (_opening) return;
    setState(() => _opening = true);
    try {
      final bytes = await File(e.path).readAsBytes();
      if (!mounted) return;
      Navigator.of(context).pop(PickedFile(name: e.name, bytes: bytes));
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _opening = false;
        _error = 'Не удалось прочитать файл';
      });
    }
  }

  /// Fallback: вызвать системный picker. Юзер хочет «свою панель», но
  /// если scoped storage не пускает к Downloads напрямую, кнопка
  /// «Системная панель» хотя бы даст возможность завершить выбор.
  Future<void> _useSystemPicker() async {
    if (_opening) return;
    setState(() => _opening = true);
    try {
      final res = await FilePicker.platform.pickFiles(
        type: widget.allowedExtensions != null
            ? FileType.custom
            : FileType.any,
        allowedExtensions: widget.allowedExtensions,
        withData: true,
      );
      if (!mounted) return;
      if (res == null || res.files.isEmpty) {
        setState(() => _opening = false);
        return;
      }
      final f = res.files.first;
      final bytes = f.bytes;
      if (bytes == null) {
        setState(() {
          _opening = false;
          _error = 'Не удалось прочитать файл';
        });
        return;
      }
      Navigator.of(context).pop(PickedFile(name: f.name, bytes: bytes));
    } catch (_) {
      if (!mounted) return;
      setState(() => _opening = false);
    }
  }

  String _formatSize(int b) {
    if (b < 1024) return '$b Б';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} КБ';
    if (b < 1024 * 1024 * 1024) {
      return '${(b / 1024 / 1024).toStringAsFixed(1)} МБ';
    }
    return '${(b / 1024 / 1024 / 1024).toStringAsFixed(2)} ГБ';
  }

  String _fileIcon(String name) {
    final n = name.toLowerCase();
    if (n.endsWith('.zip') ||
        n.endsWith('.rar') ||
        n.endsWith('.7z') ||
        n.endsWith('.tar') ||
        n.endsWith('.gz') ||
        n.endsWith('.bz2')) {
      return 'solar:archive-bold';
    }
    if (n.endsWith('.png') ||
        n.endsWith('.jpg') ||
        n.endsWith('.jpeg') ||
        n.endsWith('.gif') ||
        n.endsWith('.webp') ||
        n.endsWith('.bmp')) {
      return 'solar:gallery-add-bold';
    }
    if (n.endsWith('.txt') ||
        n.endsWith('.md') ||
        n.endsWith('.json') ||
        n.endsWith('.yaml') ||
        n.endsWith('.yml') ||
        n.endsWith('.xml') ||
        n.endsWith('.log')) {
      return 'solar:document-text-bold';
    }
    if (n.endsWith('.dart') ||
        n.endsWith('.kt') ||
        n.endsWith('.java') ||
        n.endsWith('.py') ||
        n.endsWith('.js') ||
        n.endsWith('.ts') ||
        n.endsWith('.html') ||
        n.endsWith('.css')) {
      return 'solar:code-square-bold';
    }
    return 'solar:document-add-bold';
  }

  Color _fileIconColor(String name, AppPalette pal) {
    final n = name.toLowerCase();
    if (n.endsWith('.zip') ||
        n.endsWith('.rar') ||
        n.endsWith('.7z') ||
        n.endsWith('.tar') ||
        n.endsWith('.gz') ||
        n.endsWith('.bz2')) {
      return AppColors.orange;
    }
    if (n.endsWith('.png') ||
        n.endsWith('.jpg') ||
        n.endsWith('.jpeg') ||
        n.endsWith('.gif') ||
        n.endsWith('.webp') ||
        n.endsWith('.bmp')) {
      return AppColors.green;
    }
    return pal.accent;
  }

  /// Хлебные крошки: короткое имя пути (.../Download) или название
  /// корня. Чтобы не растягивать ширину при глубокой иерархии.
  String _breadcrumb(String path) {
    // Подменяем известные префиксы человекочитаемыми названиями.
    for (final r in _roots) {
      if (path == r.path) return r.label;
      if (path.startsWith('${r.path}/')) {
        final rel = path.substring(r.path.length + 1);
        return '${r.label} › $rel';
      }
    }
    return path;
  }

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    final mq = MediaQuery.of(context);
    // Шит занимает примерно 78% экрана. На больших телефонах не
    // распирает на весь экран, чтобы было видно «под ним» подложку.
    final maxH = mq.size.height * 0.78;
    return Padding(
      padding: EdgeInsets.only(
        top: mq.viewPadding.top + 20,
      ),
      child: ClipRRect(
        borderRadius:
            const BorderRadius.vertical(top: Radius.circular(24)),
        child: Container(
          color: pal.cont,
          constraints: BoxConstraints(maxHeight: maxH),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 8),
              // «Хваталка» — индикатор drag-to-dismiss.
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: pal.sub.withValues(alpha: 0.25),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 10),
              _header(pal),
              if (_path != null) _crumb(pal),
              const SizedBox(height: 4),
              Flexible(child: _body(pal)),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
                  child: Row(
                    children: [
                      Expanded(
                        child: _MaterialButton(
                          icon: 'solar:folder-open-bold',
                          label: 'Системная панель',
                          onTap: _opening ? null : _useSystemPicker,
                          accent: false,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header(AppPalette pal) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 4, 12, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (_path != null)
            IconBtn(
              icon: 'solar:alt-arrow-left-linear',
              onTap: _goUp,
            ),
          if (_path != null) const SizedBox(width: 8),
          Expanded(
            child: Text(
              _path == null ? 'Выбор файла' : 'Папка',
              style: TextStyle(
                fontSize: 19,
                fontWeight: FontWeight.w700,
                color: pal.text,
                letterSpacing: -.3,
                height: 1.15,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          IconBtn(
            icon: 'solar:close-circle-bold',
            onTap: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }

  Widget _crumb(AppPalette pal) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 0, 18, 4),
      child: Text(
        _breadcrumb(_path!),
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w500,
          color: pal.sub,
          height: 1.3,
        ),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  Widget _body(AppPalette pal) {
    if (_path == null) {
      // Главный экран — список корней-закладок.
      return ListView(
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(12, 2, 12, 8),
        children: [
          for (var i = 0; i < _roots.length; i++)
            AppearOnMount(
              key: ValueKey('root_${_roots[i].path}'),
              delay: Duration(milliseconds: (i * 35).clamp(0, 200)),
              child: _RootTile(
                root: _roots[i],
                onTap: _opening ? null : () => _open(_roots[i].path),
              ),
            ),
        ],
      );
    }
    if (_loading) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: 40),
          child: SizedBox(
            width: 40,
            height: 40,
            child: M3LoadingIndicator(
              strokeWidth: 3,
              strokeCap: StrokeCap.round,
            ),
          ),
        ),
      );
    }
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Iconify('solar:forbidden-circle-bold',
                size: 44, color: pal.sub.withValues(alpha: 0.5)),
            const SizedBox(height: 10),
            Text(
              _error!,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: pal.text,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Попробуйте открыть другую папку или\nсистемную панель ниже.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12.5,
                color: pal.sub,
                height: 1.35,
              ),
            ),
          ],
        ),
      );
    }
    if (_entries.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Iconify('solar:inbox-bold',
                size: 44, color: pal.sub.withValues(alpha: 0.5)),
            const SizedBox(height: 10),
            Text(
              widget.allowedExtensions != null
                  ? 'Здесь нет подходящих файлов'
                  : 'Папка пуста',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: pal.text,
              ),
            ),
          ],
        ),
      );
    }
    return ListView.builder(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(12, 2, 12, 8),
      itemCount: _entries.length,
      itemBuilder: (_, i) {
        final e = _entries[i];
        return AppearOnMount(
          key: ValueKey('entry_${e.path}'),
          delay: Duration(milliseconds: (i * 22).clamp(0, 180)),
          child: _EntryTile(
            entry: e,
            iconName: e.isDir ? 'solar:folder-bold' : _fileIcon(e.name),
            iconColor: e.isDir ? pal.accent : _fileIconColor(e.name, pal),
            subtitle: e.isDir
                ? 'Папка'
                : _formatSize(e.size),
            onTap: _opening
                ? null
                : () => e.isDir ? _open(e.path) : _selectFile(e),
          ),
        );
      },
    );
  }
}

/// Tile для корневой закладки.
class _RootTile extends StatelessWidget {
  final _Root root;
  final VoidCallback? onTap;
  const _RootTile({required this.root, this.onTap});

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: PressScale(
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            color: pal.bg.withValues(alpha: pal.isDark ? 0.55 : 0.7),
            borderRadius: BorderRadius.circular(14),
          ),
          padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: pal.accent.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Center(
                  child: Iconify(root.icon, size: 22, color: pal.accent),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  root.label,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: pal.text,
                    height: 1.2,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Iconify('solar:alt-arrow-right-linear',
                  size: 18, color: pal.sub),
            ],
          ),
        ),
      ),
    );
  }
}

/// Tile для папки или файла.
class _EntryTile extends StatelessWidget {
  final _Entry entry;
  final String iconName;
  final Color iconColor;
  final String subtitle;
  final VoidCallback? onTap;
  const _EntryTile({
    required this.entry,
    required this.iconName,
    required this.iconColor,
    required this.subtitle,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: PressScale(
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            color: pal.bg.withValues(alpha: pal.isDark ? 0.45 : 0.6),
            borderRadius: BorderRadius.circular(12),
          ),
          padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
          child: Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: iconColor.withValues(alpha: 0.13),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Center(
                  child: Iconify(iconName, size: 20, color: iconColor),
                ),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      entry.name,
                      style: TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w600,
                        color: pal.text,
                        height: 1.2,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w500,
                        color: pal.sub,
                        height: 1.2,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              if (entry.isDir)
                Iconify('solar:alt-arrow-right-linear',
                    size: 18, color: pal.sub),
            ],
          ),
        ),
      ),
    );
  }
}

/// Маленькая кнопка в стиле приложения для футера (использовать
/// системный пикер). Можно было бы взять общий [IconBtn], но тут
/// нужен текст рядом — поэтому свой компактный виджет.
class _MaterialButton extends StatelessWidget {
  final String icon;
  final String label;
  final VoidCallback? onTap;
  final bool accent;
  const _MaterialButton({
    required this.icon,
    required this.label,
    this.onTap,
    this.accent = false,
  });

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    final fg = accent ? Colors.white : pal.text;
    final bg = accent
        ? pal.accent
        : pal.bg.withValues(alpha: pal.isDark ? 0.55 : 0.7);
    return PressScale(
      onTap: onTap,
      child: Container(
        height: 44,
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(12),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Iconify(icon, size: 18, color: fg),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: fg,
                height: 1.0,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
