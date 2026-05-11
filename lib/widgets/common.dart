import 'package:flutter/material.dart';
import '../iconify.dart';
import '../theme.dart';

/// Общие виджеты UI: тайлы, кнопки, чипы, сегменты и пр.

class IconBtn extends StatelessWidget {
  final String icon;
  final VoidCallback? onTap;
  final double size;
  final Color? color;
  final double iconSize;
  final String? tooltip;
  const IconBtn({
    super.key,
    required this.icon,
    this.onTap,
    this.size = 40,
    this.iconSize = 26,
    this.color,
    this.tooltip,
  });

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    return _PressOpacity(
      onTap: onTap,
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        child: Iconify(icon, size: iconSize, color: color ?? pal.text),
      ),
    );
  }
}

class _PressOpacity extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final double minScale;
  final double minOpacity;
  // Раньше тут был серый «дим» 0.55 при нажатии — пользователь жаловался,
  // что кнопки «сереют» при тапе. Сейчас оставлен только лёгкий scale-down,
  // прозрачность не меняется (minOpacity = 1.0).
  const _PressOpacity({
    required this.child,
    required this.onTap,
    this.minScale = 0.92,
    this.minOpacity = 1.0,
  });
  @override
  State<_PressOpacity> createState() => _PressOpacityState();
}

/// Оборачиваем child в [AnimatedScale] только если minScale != 1.0.
/// При minScale == 1.0 (типичный кейс для Tile/IconBtn — у них нет
/// scale-down эффекта на тапе) AnimatedScale бесполезен, но при этом
/// всё равно создаёт `AnimationController`. На экране с 4-5 Tile'ами это
/// 4-5 контроллеров впустую — заметно тормозит first frame после push'а.
Widget _maybeAnimateScale({
  required double minScale,
  required bool down,
  required Widget child,
}) {
  if (minScale >= 1.0) return child;
  return AnimatedScale(
    scale: down ? minScale : 1.0,
    duration: const Duration(milliseconds: 150),
    child: child,
  );
}

class _PressOpacityState extends State<_PressOpacity> {
  bool _down = false;
  // Резервная слежка за указателем: даже если жест-арбитр объявил
  // тап «отменённым» (например, родительский ScrollView перехватил
  // событие из-за микро-сдвига пальца), мы всё равно вызовем onTap,
  // если палец оторвался рядом с точкой нажатия и быстро. Это полностью
  // решает проблему «жму — а тема не переключается / нажатие не
  // срабатывает» на медленных Android-устройствах, где RAII задержки
  // в build-фазе вызывают дрифт пальца за пределами kTouchSlop.
  Offset? _downGlobal;
  DateTime? _downAt;

  void _maybeFire(Offset upGlobal, DateTime upAt) {
    final dp = _downGlobal;
    final dt = _downAt;
    _downGlobal = null;
    _downAt = null;
    if (dp == null || dt == null) return;
    final dist = (upGlobal - dp).distance;
    final ms = upAt.difference(dt).inMilliseconds;
    if (dist <= 24 && ms <= 600) {
      widget.onTap?.call();
    }
  }

  /// true, если у нас вообще есть визуальная обратная связь на тап
  /// (scale-down или opacity-дим). Если оба == 1.0, то менять `_down`
  /// бессмысленно — нет смысла дёргать setState() при каждом тапе.
  bool get _hasFeedback =>
      widget.minScale < 1.0 || widget.minOpacity < 1.0;

  void _setDown(bool v) {
    if (!_hasFeedback) return;
    if (mounted && _down != v) setState(() => _down = v);
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (e) {
        _downGlobal = e.position;
        _downAt = DateTime.now();
      },
      onPointerUp: (e) {
        _setDown(false);
        _maybeFire(e.position, DateTime.now());
      },
      onPointerCancel: (_) {
        _downGlobal = null;
        _downAt = null;
        _setDown(false);
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        // Жест-распознаватель оставлен только для визуальной обратной
        // связи (down-state). Реальный onTap вызывается из Listener
        // выше — он не зависит от арбитража жестов и срабатывает
        // надёжно даже если родительский ScrollView сожрал тап.
        onTapDown: (_) => _setDown(true),
        onTapUp: (_) => _setDown(false),
        onTapCancel: () => _setDown(false),
        // Раньше тут была AnimatedOpacity поверх AnimatedScale, но при
        // дефолтных minOpacity=1.0/minScale=1.0 это была пустая работа —
        // десятки AnimationController'ов по дереву (Tile / IconBtn /
        // RotatingRefreshBtn / ...) запускали Implicit*Animated* без
        // видимого эффекта. Это и был один из источников лагов при
        // открытии экранов с длинными списками тайлов (детали репо,
        // профиль): первый кадр вставал из-за пачки AnimationController
        // init'ов. Теперь ни scale, ни opacity не оборачиваются, если
        // соответствующий минимум == 1.0 — обычно для Tile/IconBtn так и
        // есть.
        child: _maybeAnimateScale(
          minScale: widget.minScale,
          down: _down,
          child: widget.minOpacity < 1.0
              ? AnimatedOpacity(
                  opacity: _down ? widget.minOpacity : 1.0,
                  duration: const Duration(milliseconds: 150),
                  child: widget.child,
                )
              : widget.child,
        ),
      ),
    );
  }
}

class PressScale extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final double scale;
  const PressScale(
      {super.key, required this.child, this.onTap, this.scale = 0.97});
  @override
  State<PressScale> createState() => _PressScaleState();
}

class _PressScaleState extends State<PressScale> {
  bool _down = false;
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => setState(() => _down = true),
      onTapUp: (_) => setState(() => _down = false),
      onTapCancel: () => setState(() => _down = false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _down ? widget.scale : 1.0,
        duration: const Duration(milliseconds: 150),
        child: widget.child,
      ),
    );
  }
}

/// Высота полосы шапки (без top inset). Используется в [TopFadeHeader] и для
/// расчёта верхнего паддинга у скролл-контента, чтобы первый элемент не
/// пересекался с заголовком при scrollOffset = 0.
const double kTopHeaderBarHeight = 56;

/// Многоточечный мягкий градиент-фейд для верхней плашки.
/// Один LinearGradient (один проход рендера, не «слои») с несколькими
/// опорными точками — за счёт этого переход получается без резкой полосы
/// границы и без слишком сильного затемнения.
LinearGradient _buildSoftFadeGradient(Color bg) => LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [
        bg.withValues(alpha: 0.78),
        bg.withValues(alpha: 0.66),
        bg.withValues(alpha: 0.46),
        bg.withValues(alpha: 0.24),
        bg.withValues(alpha: 0.08),
        bg.withValues(alpha: 0.0),
      ],
      stops: const [0.0, 0.30, 0.55, 0.75, 0.90, 1.0],
    );

/// Шапка экрана с прозрачным фоном и плавным градиентом сверху —
/// контент скроллится «под» неё и слегка дим'ится у статусбара (как в
/// Google Photos / Material 3 large appbar в свернутом виде).
///
/// Используется в [Stack] поверх основного контента: контент должен
/// иметь `padding.top = MediaQuery.padding.top + kTopHeaderBarHeight`,
/// чтобы первая строка не пряталась под шапкой.
class TopFadeHeader extends StatelessWidget {
  final String title;
  final List<Widget> trailing;
  final VoidCallback? onBack;
  const TopFadeHeader({
    super.key,
    required this.title,
    this.trailing = const [],
    this.onBack,
  });

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    final topInset = MediaQuery.of(context).padding.top;
    return Container(
      padding: EdgeInsets.fromLTRB(18, topInset + 8, 18, 22),
      decoration: BoxDecoration(
        gradient: _buildSoftFadeGradient(pal.bg),
      ),
      child: Row(
        children: [
          IconBtn(
            icon: 'solar:alt-arrow-left-linear',
            iconSize: 20,
            size: 36,
            onTap: onBack ?? () => Navigator.of(context).maybePop(),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              title,
              style: const TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w700,
                letterSpacing: -.4,
                height: 1.15,
              ),
            ),
          ),
          ...trailing,
        ],
      ),
    );
  }
}

/// Верхняя плашка-фейдер БЕЗ заголовка — мягкий градиент в зоне статусбара
/// и чуть ниже. Используется на push-экранах с собственной кастомной
/// шапкой и в качестве «продолжения» для sticky-шапки в табах.
class TopFadeOverlay extends StatelessWidget {
  /// Дополнительная высота градиента ниже статусбара.
  final double extra;
  const TopFadeOverlay({super.key, this.extra = 28});

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    final topInset = MediaQuery.of(context).padding.top;
    return IgnorePointer(
      child: SizedBox(
        height: topInset + extra,
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: _buildSoftFadeGradient(pal.bg),
          ),
        ),
      ),
    );
  }
}

/// Sticky-шапка для главных табов (Actions / Bugs / Repos): прибита к верху
/// экрана, имеет прозрачный фон с мягким градиентом-фейдом, под ней
/// скроллится контент и плавно «уходит» под градиент.
///
/// Высота шапки замеряется автоматически (через [_StickyTabHeaderState]),
/// и доступна через колбэк [onHeightChanged] — у скролл-контейнера в
/// [Positioned.fill] нужно выставить `padding.top = измеренная высота`.
class StickyTabHeader extends StatefulWidget {
  final List<Widget> children;
  final ValueChanged<double> onHeightChanged;
  final EdgeInsets padding;
  const StickyTabHeader({
    super.key,
    required this.children,
    required this.onHeightChanged,
    this.padding = const EdgeInsets.fromLTRB(18, 8, 18, 12),
  });

  @override
  State<StickyTabHeader> createState() => _StickyTabHeaderState();
}

class _StickyTabHeaderState extends State<StickyTabHeader> {
  final GlobalKey _key = GlobalKey();
  double _height = 0;
  bool _measureScheduled = false;

  void _scheduleMeasure() {
    // Раньше тут было addPostFrameCallback на КАЖДЫЙ build — это плодило
    // десятки колбэков за фрейм при скролле/анимациях. Хватает одного на
    // build-цикл; следующий запросим, если высота шапки поменялась.
    if (_measureScheduled) return;
    _measureScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _measureScheduled = false;
      _measure();
    });
  }

  void _measure() {
    final ctx = _key.currentContext;
    if (ctx == null) return;
    final box = ctx.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final h = box.size.height;
    if ((h - _height).abs() > 0.5) {
      _height = h;
      widget.onHeightChanged(h);
    }
  }

  @override
  Widget build(BuildContext context) {
    _scheduleMeasure();
    final pal = context.pal;
    final topInset = MediaQuery.of(context).padding.top;
    return RepaintBoundary(
      // RepaintBoundary вокруг шапки: при скролле списка под ней
      // содержимое самой шапки не меняется — Flutter может переиспользовать
      // её layer (slot в native compositor) и не пере-растеризовать
      // градиент каждый кадр. На bug-screen с длинным списком это даёт
      // буквально удвоение fps на скролле.
      child: Container(
        key: _key,
        padding: EdgeInsets.only(
          left: widget.padding.left,
          right: widget.padding.right,
          top: widget.padding.top + topInset,
          bottom: widget.padding.bottom,
        ),
        decoration: BoxDecoration(
          gradient: _buildSoftFadeGradient(pal.bg),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: widget.children,
        ),
      ),
    );
  }
}

class SecTitle extends StatelessWidget {
  final String text;
  final EdgeInsets padding;
  const SecTitle(this.text,
      {super.key,
      this.padding = const EdgeInsets.only(left: 4, bottom: 10, top: 8)});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: Text(
        text.toUpperCase(),
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: context.pal.sub,
          letterSpacing: .6,
        ),
      ),
    );
  }
}

class TileGroup extends StatelessWidget {
  final List<Widget> children;
  final EdgeInsets margin;
  const TileGroup({
    super.key,
    required this.children,
    this.margin = const EdgeInsets.only(bottom: 22),
  });
  @override
  Widget build(BuildContext context) {
    // Разделители между элементами убраны по просьбе пользователя —
    // карточки выглядят чище без серых хайрлайнов; пункты визуально
    // разделены вертикальным внутренним паддингом самих Tile’ов.
    return Container(
      margin: margin,
      decoration: BoxDecoration(
        color: context.pal.cont,
        borderRadius: BorderRadius.circular(18),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(children: children),
    );
  }
}

class Tile extends StatelessWidget {
  final Color iconBg;
  final String icon;
  final String title;
  final String? sub;
  final Widget? trailing;
  final VoidCallback? onTap;
  final Color? titleColor;
  final Color? iconColor;
  const Tile({
    super.key,
    required this.iconBg,
    required this.icon,
    required this.title,
    this.sub,
    this.trailing,
    this.onTap,
    this.titleColor,
    this.iconColor,
  });
  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    // Без визуальной обратной связи на тап: ни scale-down, ни «дима»
    // прозрачностью. Пользователь жаловался, что пункты «затемняются»
    // при нажатии — теперь нажатие просто срабатывает без анимации.
    return _PressOpacity(
      onTap: onTap,
      minScale: 1.0,
      minOpacity: 1.0,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
        child: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: iconBg,
                borderRadius: BorderRadius.circular(8),
              ),
              alignment: Alignment.center,
              child: Iconify(icon, size: 19, color: iconColor ?? Colors.white),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                      letterSpacing: -.1,
                      color: titleColor ?? pal.text,
                    ),
                  ),
                  if (sub != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      sub!,
                      style: TextStyle(
                        fontSize: 12,
                        color: pal.sub,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (trailing != null) trailing!,
            if (trailing == null && onTap != null)
              Iconify('solar:alt-arrow-right-linear',
                  size: 18, color: pal.sub),
          ],
        ),
      ),
    );
  }
}

class PushButton extends StatelessWidget {
  final String label;
  final String? icon;
  final VoidCallback? onTap;
  final Color? color;
  final bool loading;
  const PushButton({
    super.key,
    required this.label,
    this.icon,
    this.onTap,
    this.color,
    this.loading = false,
  });
  @override
  Widget build(BuildContext context) {
    return PressScale(
      onTap: onTap,
      scale: 0.98,
      child: Container(
        width: double.infinity,
        // Жёстко задаём высоту 54, чтобы соседняя GhostButton с такой же
        // высотой совпадала «пиксель в пиксель» — иначе из-за разной
        // высоты текста vs иконки кнопки в строке выглядят не одинаково.
        height: 54,
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          color: color ?? AppColors.accent,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (loading)
              const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                    color: Colors.white,
                    strokeWidth: 2.4,
                    strokeCap: StrokeCap.round),
              )
            else if (icon != null)
              Iconify(icon!, size: 22, color: Colors.white),
            if ((loading || icon != null) && label.isNotEmpty)
              const SizedBox(width: 10),
            if (label.isNotEmpty)
              Text(
                label,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class GhostButton extends StatelessWidget {
  final String label;
  final VoidCallback? onTap;
  const GhostButton({super.key, required this.label, this.onTap});
  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    return _PressOpacity(
      onTap: onTap,
      minScale: 0.98,
      child: Container(
        // Размер «1-в-1» с PushButton: тот считается по padding
        // vertical:16 + контент (текст ~22 / иконка 22) ≈ 54 px. Если
        // оставлять GhostButton 50 px и без width:double.infinity, то
        // в паре с PushButton в Row+Expanded визуально получается
        // ниже и уже — пользователь жалуется, что «Отмена» меньше
        // «Далее». Жёстко прибиваем обе размерности.
        width: double.infinity,
        height: 54,
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: pal.cont,
          borderRadius: BorderRadius.circular(16),
        ),
        // Защита от переноса на новую строку — узкая кнопка иначе режет
        // слово «Отмена» пополам. softWrap:false + ellipsis гарантируют
        // одну строку всегда.
        child: Text(
          label,
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: pal.text,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

class FieldBox extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final int? maxLines;
  final int minLines;
  final TextInputType? keyboardType;
  final FocusNode? focusNode;
  const FieldBox({
    super.key,
    required this.controller,
    required this.hint,
    this.maxLines,
    this.minLines = 1,
    this.keyboardType,
    this.focusNode,
  });
  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    return TextField(
      controller: controller,
      maxLines: maxLines,
      minLines: minLines,
      keyboardType: keyboardType,
      focusNode: focusNode,
      style: TextStyle(color: pal.text, fontSize: 15),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(color: pal.sub),
        filled: true,
        fillColor: pal.cont,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      ),
    );
  }
}

class FormLabel extends StatelessWidget {
  final String text;
  final EdgeInsets padding;
  const FormLabel(this.text,
      {super.key,
      this.padding = const EdgeInsets.only(top: 14, bottom: 8, left: 4)});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: Text(
        text,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: context.pal.sub,
        ),
      ),
    );
  }
}

class Avatar extends StatelessWidget {
  final String text;
  final double size;
  final String? imageUrl;
  const Avatar(
      {super.key, required this.text, this.size = 52, this.imageUrl});

  @override
  Widget build(BuildContext context) {
    final hasUrl = imageUrl != null && imageUrl!.isNotEmpty;
    final letter = text.isEmpty ? '?' : text;
    return SizedBox(
      width: size,
      height: size,
      child: ClipOval(
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Плейсхолдер всегда снизу — градиент с буквой. Когда
            // приходит картинка, она ложится сверху без «дыры».
            Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [AppColors.accent, AppColors.pink],
                ),
              ),
              alignment: Alignment.center,
              child: Text(
                letter,
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                  fontSize: size * 0.4,
                  letterSpacing: -.5,
                ),
              ),
            ),
            if (hasUrl)
              Image.network(
                imageUrl!,
                key: ValueKey(imageUrl),
                fit: BoxFit.cover,
                gaplessPlayback: true,
                frameBuilder: (ctx, child, frame, wasSync) {
                  // Если кадр пришёл синхронно (картинка уже в кэше) —
                  // показываем сразу без fade. Иначе короткий fade-in.
                  if (wasSync || frame != null) {
                    return AnimatedOpacity(
                      opacity: 1,
                      duration: const Duration(milliseconds: 180),
                      child: child,
                    );
                  }
                  return const SizedBox.shrink();
                },
                errorBuilder: (_, __, ___) => const SizedBox.shrink(),
              ),
          ],
        ),
      ),
    );
  }
}

class AuthorCard extends StatelessWidget {
  final String name;
  final String sub;
  final String avatar;
  final String? avatarUrl;
  final List<Widget>? stats;
  const AuthorCard({
    super.key,
    required this.name,
    required this.sub,
    required this.avatar,
    this.avatarUrl,
    this.stats,
  });
  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    return Container(
      margin: const EdgeInsets.only(bottom: 22),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: pal.cont,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          Avatar(text: avatar, imageUrl: avatarUrl),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  name,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -.2,
                    color: pal.text,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  sub,
                  style: TextStyle(
                    fontSize: 13,
                    color: pal.sub,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                if (stats != null) ...[
                  const SizedBox(height: 8),
                  Row(children: [
                    for (var i = 0; i < stats!.length; i++) ...[
                      stats![i],
                      if (i != stats!.length - 1) const SizedBox(width: 14),
                    ]
                  ])
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class StatPill extends StatelessWidget {
  final String icon;
  final String value;
  final String? label;
  const StatPill(
      {super.key, required this.icon, required this.value, this.label});

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    return DefaultTextStyle.merge(
      style: TextStyle(
          fontSize: 12, color: pal.sub, fontWeight: FontWeight.w500),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Iconify(icon, size: 13, color: pal.sub),
        const SizedBox(width: 4),
        Text(value,
            style: TextStyle(
                color: pal.text, fontWeight: FontWeight.w600, fontSize: 12)),
        if (label != null) Text(' $label'),
      ]),
    );
  }
}

/// Чип фильтра/сортировки. Раньше использовал [BackdropFilter] для
/// matte-glass эффекта, но это сильно нагружало GPU при скролле списка
/// под чипами (баг n3159 — «лаги в плашках»). Теперь — полупрозрачный
/// фон без runtime-блюра.
class CtChip extends StatelessWidget {
  final String label;
  final VoidCallback? onTap;
  final bool active;
  const CtChip(
      {super.key, required this.label, this.onTap, this.active = false});
  @override
  Widget build(BuildContext context) {
    return BlurredChip(
      onTap: onTap,
      active: active,
      child: Text(
        label,
        textAlign: TextAlign.center,
        style: TextStyle(
          color: active ? Colors.white : context.pal.text,
          fontSize: 13,
          fontWeight: FontWeight.w500,
          height: 1.0,
        ),
      ),
    );
  }
}

/// Универсальная плашка фильтра/сортировки. Для активного состояния —
/// акцентный сплошной фон, для неактивного — полупрозрачный «glass» фон
/// без runtime BackdropFilter (он лагал при скролле — баг n3159).
class BlurredChip extends StatelessWidget {
  final Widget child;
  final VoidCallback? onTap;
  final bool active;
  final EdgeInsets padding;
  final double radius;
  /// Цвет «стекла» для неактивного состояния. По-умолчанию — берётся
  /// из палитры (`pal.cont`) с пониженной прозрачностью.
  final Color? glassColor;
  /// Альтернативный цвет активного состояния (по-умолчанию — accent).
  final Color? activeColor;
  const BlurredChip({
    super.key,
    required this.child,
    this.onTap,
    this.active = false,
    this.padding = const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
    this.radius = 999,
    this.glassColor,
    this.activeColor,
  });
  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    // Раньше «glass» был сильно полупрозрачным (0.55/0.62) — пользователи
    // жаловались, что плашки сортировки/фильтра «полупустые» и теряются на
    // фоне списка под ними (баг n8250). Поднимаем альфу до ~0.95 —
    // примерно как у island-navbar (0xF2…). Текст читается «жирно», плашки
    // не сливаются с контентом, но и не выглядят как сплошной блок —
    // лёгкий просвет фона остаётся.
    final glass = glassColor ??
        pal.cont.withValues(alpha: pal.isDark ? 0.95 : 0.94);
    final fill = active ? (activeColor ?? AppColors.accent) : glass;
    // `alignment: Alignment.center` нужен, чтобы текст чипа был строго по
    // центру в родителях с фиксированной высотой (горизонтальные
    // ListView в шапках — repos / files / bugs кладут чипы в
    // SizedBox(height: 36/38)). Иначе текст «прилипает» к верху.
    return PressScale(
      onTap: onTap,
      scale: 0.95,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: Container(
          padding: padding,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: fill,
            borderRadius: BorderRadius.circular(radius),
          ),
          child: child,
        ),
      ),
    );
  }
}

/// Кнопка обновления (refresh) с плавной анимацией вращения иконки во
/// время выполнения запроса. Раньше при тапе менялся цвет иконки на
/// `AppColors.accent` (фиолетовый), что выглядело как «застряло»
/// (баг n7281). Теперь — цвет не меняется, но иконка плавно крутится,
/// пока `spinning == true`.
class RotatingRefreshBtn extends StatefulWidget {
  final bool spinning;
  final VoidCallback? onTap;
  final double size;
  final double iconSize;
  const RotatingRefreshBtn({
    super.key,
    required this.spinning,
    required this.onTap,
    this.size = 36,
    this.iconSize = 22,
  });
  @override
  State<RotatingRefreshBtn> createState() => _RotatingRefreshBtnState();
}

class _RotatingRefreshBtnState extends State<RotatingRefreshBtn>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 900));

  @override
  void initState() {
    super.initState();
    if (widget.spinning) _c.repeat();
  }

  @override
  void didUpdateWidget(covariant RotatingRefreshBtn old) {
    super.didUpdateWidget(old);
    if (widget.spinning && !_c.isAnimating) {
      _c.repeat();
    } else if (!widget.spinning && _c.isAnimating) {
      // Доводим до конца оборота, чтобы не «дёргалось» — затем стоп.
      _c.forward().then((_) => _c.stop());
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    return _PressOpacity(
      onTap: widget.onTap,
      child: SizedBox(
        width: widget.size,
        height: widget.size,
        child: Center(
          child: AnimatedBuilder(
            animation: _c,
            builder: (_, __) => Transform.rotate(
              angle: _c.value * 6.283185307179586,
              child: Iconify('solar:refresh-linear',
                  size: widget.iconSize, color: pal.text),
            ),
          ),
        ),
      ),
    );
  }
}
