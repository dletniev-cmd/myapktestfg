import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../iconify.dart';
import '../theme.dart';

/// Описание пункта iOS-style контекстного меню.
class CtxMenuItem {
  final String icon;
  final String label;
  final String? sub;
  final bool danger;
  final VoidCallback? onTap;
  CtxMenuItem({
    required this.icon,
    required this.label,
    this.sub,
    this.danger = false,
    this.onTap,
  });
}

/// Контроллер «живой» позиции пальца для overlay меню — нужен для
/// drag-to-select (баг n2486): пользователь удерживает карточку, не
/// отрывая палец ведёт по пунктам, и тот пункт, на котором палец сейчас,
/// слегка «приседает» (scale-down + лёгкое выделение фоном). На отпускание
/// именно этот пункт срабатывает.
class _MenuPointerController extends ChangeNotifier {
  Offset? _pos;
  bool _lifted = false;
  Offset? get pos => _pos;
  bool get lifted => _lifted;
  void update(Offset p) {
    _pos = p;
    _lifted = false;
    notifyListeners();
  }
  void lift(Offset p) {
    _pos = p;
    _lifted = true;
    notifyListeners();
  }
}

/// Оборачивает любой виджет: long-press поднимает карточку, блюрит фон
/// и показывает iOS-style меню над/под ней. Совпадает с .ctx-overlay/.ctx-menu из HTML.
class LongPressMenu extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final List<CtxMenuItem> Function() menuBuilder;
  final BorderRadius borderRadius;

  const LongPressMenu({
    super.key,
    required this.child,
    required this.menuBuilder,
    this.onTap,
    this.borderRadius = const BorderRadius.all(Radius.circular(16)),
  });

  @override
  State<LongPressMenu> createState() => _LongPressMenuState();
}

class _LongPressMenuState extends State<LongPressMenu> {
  bool _pressing = false;
  bool _overlayActive = false;
  OverlayEntry? _entry;
  _MenuPointerController? _pointer;

  void _open(Offset globalPos) {
    final overlay = Overlay.of(context, rootOverlay: true);
    final renderBox = context.findRenderObject() as RenderBox?;
    if (renderBox == null) return;
    final size = renderBox.size;
    final origin = renderBox.localToGlobal(Offset.zero);

    final items = widget.menuBuilder();
    final cardSnapshot = widget.child;

    setState(() {
      _overlayActive = true;
      _pressing = false;
    });

    HapticFeedback.mediumImpact();

    _pointer = _MenuPointerController()..update(globalPos);

    late OverlayEntry entry;
    entry = OverlayEntry(builder: (ctx) {
      return _CtxOverlay(
        cardSize: size,
        cardOrigin: origin,
        borderRadius: widget.borderRadius,
        items: items,
        cardChild: cardSnapshot,
        pointer: _pointer!,
        onClose: () {
          if (_entry == entry) {
            entry.remove();
            _entry = null;
            _pointer?.dispose();
            _pointer = null;
            if (mounted) setState(() => _overlayActive = false);
          }
        },
      );
    });
    _entry = entry;
    overlay.insert(entry);
  }

  @override
  void dispose() {
    _pointer?.dispose();
    _pointer = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _overlayActive ? null : widget.onTap,
      onTapDown:
          _overlayActive ? null : (_) => setState(() => _pressing = true),
      onTapUp:
          _overlayActive ? null : (_) => setState(() => _pressing = false),
      onTapCancel:
          _overlayActive ? null : () => setState(() => _pressing = false),
      // Баг n2486 (drag-to-select): открываем меню по long-press НО продолжаем
      // получать события onLongPressMoveUpdate / onLongPressEnd — они
      // приходят БЕЗ отпускания пальца, и через это мы шлём текущую позицию
      // курсора в overlay. Когда палец оторвался — overlay сам разбирается,
      // под каким пунктом он был, и инициирует tap.
      onLongPressStart: _overlayActive
          ? null
          : (d) {
              setState(() => _pressing = false);
              _open(d.globalPosition);
            },
      onLongPressMoveUpdate: _overlayActive
          ? (d) => _pointer?.update(d.globalPosition)
          : null,
      onLongPressEnd: _overlayActive
          ? (d) => _pointer?.lift(d.globalPosition)
          : null,
      child: Visibility(
        visible: !_overlayActive,
        maintainState: true,
        maintainAnimation: true,
        maintainSize: true,
        child: AnimatedScale(
          scale: _pressing ? 0.99 : 1.0,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOutCubic,
          child: widget.child,
        ),
      ),
    );
  }
}

class _CtxOverlay extends StatefulWidget {
  final Size cardSize;
  final Offset cardOrigin;
  final BorderRadius borderRadius;
  final List<CtxMenuItem> items;
  final Widget cardChild;
  final VoidCallback onClose;
  final _MenuPointerController pointer;
  const _CtxOverlay({
    required this.cardSize,
    required this.cardOrigin,
    required this.borderRadius,
    required this.items,
    required this.cardChild,
    required this.onClose,
    required this.pointer,
  });
  @override
  State<_CtxOverlay> createState() => _CtxOverlayState();
}

class _CtxOverlayState extends State<_CtxOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  bool _closing = false;

  // Глобальные ключи на каждый пункт — нужны для расчёта bounding box
  // при drag-to-select.
  late final List<GlobalKey> _itemKeys;

  // Индекс пункта, над которым сейчас палец. -1 — никто.
  int _hoverIndex = -1;

  @override
  void initState() {
    super.initState();
    _itemKeys = List.generate(widget.items.length, (_) => GlobalKey());
    // Один контроллер для ВСЕХ анимаций оверлея (блюр, тень карточки,
    // opacity и scale меню).
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 240),
      reverseDuration: const Duration(milliseconds: 240),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _ctrl.forward();
    });
    widget.pointer.addListener(_onPointer);
  }

  void _onPointer() {
    if (_closing) return;
    final v = widget.pointer.pos;
    if (v == null) return;
    final lifted = widget.pointer.lifted;
    final hover = _hitTestItems(v);
    if (hover != _hoverIndex) {
      setState(() => _hoverIndex = hover);
      if (hover != -1) HapticFeedback.selectionClick();
    }
    if (lifted) {
      // Палец оторвался. Если был наведён на пункт — фаерим его.
      if (hover != -1) {
        final item = widget.items[hover];
        _close(item.onTap);
      } else {
        _close();
      }
    }
  }

  /// Возвращает индекс пункта, над которым сейчас [globalPos], или -1.
  int _hitTestItems(Offset globalPos) {
    for (var i = 0; i < _itemKeys.length; i++) {
      final ctx = _itemKeys[i].currentContext;
      if (ctx == null) continue;
      final box = ctx.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) continue;
      final origin = box.localToGlobal(Offset.zero);
      final rect = origin & box.size;
      if (rect.contains(globalPos)) return i;
    }
    return -1;
  }

  @override
  void dispose() {
    widget.pointer.removeListener(_onPointer);
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _close([VoidCallback? onAfter]) async {
    if (_closing) return;
    _closing = true;
    await _ctrl.reverse();
    widget.onClose();
    onAfter?.call();
  }

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    final media = MediaQuery.of(context);
    final screenH = media.size.height;
    final menuMaxHeight = widget.items.length * 50.0 + 8.0;
    final spaceBelow =
        screenH - (widget.cardOrigin.dy + widget.cardSize.height);
    final spaceAbove = widget.cardOrigin.dy;
    final showAbove = spaceBelow < menuMaxHeight + 36 &&
        spaceAbove > menuMaxHeight + 36;

    return Material(
      color: Colors.transparent,
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (_, __) {
          final t = Curves.easeOutCubic.transform(_ctrl.value);
          final menuT = (t).clamp(0.0, 1.0);
          return Stack(
            children: [
              // Фон-размытие: BackdropFilter с фиксированной sigma (анимация sigma
              // очень дорогая — каждый кадр пересчитывается блюр на GPU без кэша).
              // Используем постоянный блюр + фейдим оверлей через opacity — GPU
              // растрирует блюр один раз и тянет это легко.
              Positioned.fill(
                child: GestureDetector(
                  onTap: _close,
                  child: Opacity(
                    opacity: t,
                    child: const RepaintBoundary(
                      child: _BlurBackdrop(),
                    ),
                  ),
                ),
              ),
              // Поднимаемая карточка-клон.
              Positioned(
                left: widget.cardOrigin.dx,
                top: widget.cardOrigin.dy,
                width: widget.cardSize.width,
                height: widget.cardSize.height,
                child: Transform.scale(
                  scale: 1.0 + 0.015 * t,
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: widget.borderRadius,
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.55 * t),
                          blurRadius: 70 * t,
                          offset: Offset(0, 22 * t),
                        ),
                      ],
                    ),
                    child: ClipRRect(
                      borderRadius: widget.borderRadius,
                      child: AbsorbPointer(child: widget.cardChild),
                    ),
                  ),
                ),
              ),
              // Меню.
              Positioned(
                left: widget.cardOrigin.dx + widget.cardSize.width / 2,
                top: showAbove
                    ? null
                    : widget.cardOrigin.dy + widget.cardSize.height + 12,
                bottom: showAbove
                    ? screenH - widget.cardOrigin.dy + 12
                    : null,
                child: FractionalTranslation(
                  translation: const Offset(-0.5, 0),
                  child: Opacity(
                    opacity: menuT,
                    child: Transform.scale(
                      alignment: showAbove
                          ? Alignment.bottomCenter
                          : Alignment.topCenter,
                      scale: 0.94 + 0.06 * menuT,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(
                          minWidth: 200,
                          maxWidth: 260,
                        ),
                        child: Container(
                          decoration: BoxDecoration(
                            color: pal.cont,
                            borderRadius: BorderRadius.circular(14),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.55 * t),
                                blurRadius: 60,
                                offset: const Offset(0, 22),
                              ),
                            ],
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              for (var i = 0; i < widget.items.length; i++)
                                _CtxItem(
                                  key: _itemKeys[i],
                                  item: widget.items[i],
                                  hovered: _hoverIndex == i,
                                  onTap: () =>
                                      _close(widget.items[i].onTap),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _CtxItem extends StatefulWidget {
  final CtxMenuItem item;
  final VoidCallback onTap;
  final bool hovered;
  const _CtxItem(
      {super.key,
      required this.item,
      required this.onTap,
      this.hovered = false});
  @override
  State<_CtxItem> createState() => _CtxItemState();
}

class _CtxItemState extends State<_CtxItem> {
  bool _down = false;
  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    final color = widget.item.danger ? pal.red : pal.text;
    final iconColor = widget.item.danger ? pal.red : pal.accent;
    // Hovered (drag-to-select): пункт «приседает» (scale 0.97). Без фона —
    // пользователь просил убрать всякие серые/фоновые подсветки. Чёткую
    // обратную связь даёт именно сжатие + тактильный отклик (баг n2486).
    final isActive = widget.hovered || _down;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => setState(() => _down = true),
      onTapUp: (_) => setState(() => _down = false),
      onTapCancel: () => setState(() => _down = false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: isActive ? 0.985 : 1.0,
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeInOutCubic,
        child: Container(
          color: Colors.transparent,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
            child: Row(
              children: [
                Iconify(widget.item.icon, size: 19, color: iconColor),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        widget.item.label,
                        style: TextStyle(
                          fontSize: 14.5,
                          fontWeight: FontWeight.w500,
                          color: color,
                        ),
                      ),
                      if (widget.item.sub != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            widget.item.sub!,
                            style: TextStyle(
                                fontSize: 11.5,
                                fontWeight: FontWeight.w500,
                                color: pal.sub),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Постоянный блюр-слой: BackdropFilter с фиксированной sigma + затемнение.
/// Анимируем только Opacity у родителя — это копеечная операция в GPU,
/// тогда как анимация sigma пересчитывает фильтр на каждом кадре и сильно
/// нагружает middle-end девайсы.
class _BlurBackdrop extends StatelessWidget {
  const _BlurBackdrop();
  @override
  Widget build(BuildContext context) {
    return BackdropFilter(
      filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
      child: Container(color: Colors.black.withValues(alpha: 0.32)),
    );
  }
}
