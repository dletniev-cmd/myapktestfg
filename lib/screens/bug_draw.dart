import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../iconify.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/common.dart';

class BugDrawScreen extends StatefulWidget {
  final BugItem bug;
  final Uint8List initial;
  final int? index;
  const BugDrawScreen(
      {super.key, required this.bug, required this.initial, this.index});
  @override
  State<BugDrawScreen> createState() => _BugDrawScreenState();
}

enum _Tool { pen, rect, arrow }

class _Stroke {
  final _Tool tool;
  final List<Offset> points; // pen: все точки. rect/arrow: [start, end]
  final Color color;
  final double width;

  // Кэш Path для пера — пересобирается лениво по мере добавления точек.
  // Без кэша на каждом кадре приходилось бы заново звать canvas.drawLine
  // на каждый сегмент (тысячи вызовов при заливке экрана), и кадр падал
  // до 5–10 fps. С Path рисуется одна непрерывная фигура и GPU сам
  // расставляет stroke-cap/join.
  Path? _path;
  int _pathLen = 0;

  _Stroke(this.tool, this.points, this.color, this.width);

  Path get path {
    if (_path == null) {
      _path = Path();
      if (points.isNotEmpty) _path!.moveTo(points[0].dx, points[0].dy);
      _pathLen = 1;
    }
    while (_pathLen < points.length) {
      final p = points[_pathLen];
      _path!.lineTo(p.dx, p.dy);
      _pathLen++;
    }
    return _path!;
  }
}

class _BugDrawScreenState extends State<BugDrawScreen> {
  final GlobalKey _repaintKey = GlobalKey();
  final TransformationController _zoom = TransformationController();
  ui.Image? _img;
  final List<_Stroke> _strokes = [];
  _Tool _tool = _Tool.pen;
  // Стартовый цвет пера — палитровый красный. Раньше был захардкожен
  // 0xFFFF3B30 «как в HTML», но после обновления палитры (n7979) он
  // отличался от остальных красных в приложении. Берём из палитры.
  Color _color = AppColors.red;
  double _width = 4;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _decode();
  }

  Future<void> _decode() async {
    final codec = await ui.instantiateImageCodec(widget.initial);
    final frame = await codec.getNextFrame();
    setState(() => _img = frame.image);
  }

  @override
  void dispose() {
    _zoom.dispose();
    super.dispose();
  }

  /// Перед выходом из редактора форсируем скрытие клавиатуры
  /// и сброс фокуса. Иначе при возврате на экран с TextField в фокусе
  /// системная клавиатура резко вылетает и экран «подпрыгивает».
  void _exit() {
    FocusManager.instance.primaryFocus?.unfocus();
    Navigator.of(context).maybePop();
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      // RepaintBoundary может ещё не быть приклеен к дереву, если юзер
      // ткнул «Save» до того, как картинка успела раскодироваться.
      // В этом случае просто выходим — повторный тап сработает.
      final ctx = _repaintKey.currentContext;
      final ro = ctx?.findRenderObject();
      if (ro is! RenderRepaintBoundary) return;
      final img = await ro.toImage(pixelRatio: 2.0);
      final byteData = await img.toByteData(format: ui.ImageByteFormat.png);
      final bytes = byteData?.buffer.asUint8List();
      if (bytes == null) return;
      if (widget.index == null) {
        widget.bug.shots.add(bytes);
      } else {
        widget.bug.shots[widget.index!] = bytes;
        widget.bug.invalidateCache(widget.index!);
      }
      // Дожидаемся фактического сохранения в SharedPreferences — иначе
      // при немедленном Navigator.pop() и быстром выходе из приложения
      // последний штрих мог потеряться.
      await AppState.I.saveBugs();
      if (mounted) {
        FocusManager.instance.primaryFocus?.unfocus();
        Navigator.of(context).pop();
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    return Scaffold(
      backgroundColor: pal.bg,
      // Редактор не содержит ввода, поэтому отключаем resize под клавиатуру.
      // Это исключает возможные «подпрыгивания» лейаута при появлении клавы в соседнем экране.
      resizeToAvoidBottomInset: false,
      body: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
          child: Column(
            children: [
              // ===== TOP ISLAND =====
              _Island(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
                  child: Row(
                    children: [
                      _CircleBtn(
                        icon: 'solar:close-circle-bold',
                        bg: pal.cont2,
                        fg: pal.text,
                        onTap: _exit,
                      ),
                      const Expanded(
                        child: Center(
                          child: Text('Редактор',
                              style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: -.3)),
                        ),
                      ),
                      _CircleBtn(
                        icon: 'solar:check-circle-bold',
                        bg: AppColors.accent,
                        fg: Colors.white,
                        onTap: _saving ? null : _save,
                      ),
                    ],
                  ),
                ),
              ),
              // ===== CANVAS =====
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  child: Center(
                    child: _img == null
                        ? CircularProgressIndicator(
                            color: AppColors.accent,
                            strokeCap: StrokeCap.round)
                        : LayoutBuilder(builder: (_, c) {
                            // Картинку вписываем в доступный бокс с
                            // пропорцией, скруглённую — без обёртки-поля.
                            final iw = _img!.width.toDouble();
                            final ih = _img!.height.toDouble();
                            final scale = math.min(
                                c.maxWidth / iw, c.maxHeight / ih);
                            final w = iw * scale;
                            final h = ih * scale;
                            return InteractiveViewer(
                              transformationController: _zoom,
                              minScale: 1.0,
                              maxScale: 6.0,
                              panEnabled: false,
                              scaleEnabled: true,
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(18),
                                child: SizedBox(
                                  width: w,
                                  height: h,
                                  child: RepaintBoundary(
                                    key: _repaintKey,
                                    child: _DrawCanvas(
                                      image: _img!,
                                      strokes: _strokes,
                                      color: _color,
                                      width: _width,
                                      tool: _tool,
                                      onChange: () => setState(() {}),
                                    ),
                                  ),
                                ),
                              ),
                            );
                          }),
                  ),
                ),
              ),
              // ===== BOTTOM ISLAND =====
              _Island(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Tools row: pen / rect / arrow | colors | undo
                      Row(
                        children: [
                          _ToolBtn(
                            icon: 'solar:pen-bold',
                            active: _tool == _Tool.pen,
                            onTap: () => setState(() => _tool = _Tool.pen),
                          ),
                          const SizedBox(width: 4),
                          _ToolBtn(
                            icon: 'solar:stop-bold',
                            active: _tool == _Tool.rect,
                            onTap: () => setState(() => _tool = _Tool.rect),
                          ),
                          const SizedBox(width: 4),
                          _ToolBtn(
                            icon: 'solar:arrow-right-up-bold',
                            active: _tool == _Tool.arrow,
                            onTap: () => setState(() => _tool = _Tool.arrow),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Row(
                              mainAxisAlignment:
                                  MainAxisAlignment.spaceEvenly,
                              children: [
                                for (final c in const [
                                  Color(0xFFFF3B30),
                                  Color(0xFFFF9500),
                                  Color(0xFF34C759),
                                  Colors.white,
                                  Color(0xFF8774E1),
                                ])
                                  GestureDetector(
                                    behavior: HitTestBehavior.opaque,
                                    onTap: () => setState(() => _color = c),
                                    child: AnimatedContainer(
                                      duration:
                                          const Duration(milliseconds: 150),
                                      width: _color == c ? 26 : 22,
                                      height: _color == c ? 26 : 22,
                                      decoration: BoxDecoration(
                                        color: c,
                                        shape: BoxShape.circle,
                                        border: Border.all(
                                          color: _color == c
                                              ? AppColors.accent
                                              : Colors.transparent,
                                          width: 2.5,
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          _CircleBtn(
                            icon: 'solar:undo-left-round-bold',
                            bg: pal.cont2,
                            fg: pal.text,
                            onTap: _strokes.isEmpty
                                ? null
                                : () => setState(() => _strokes.removeLast()),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      // Width slider
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: Row(children: [
                          Iconify('solar:pen-bold', size: 16, color: pal.sub),
                          Expanded(
                            child: SliderTheme(
                              data: SliderTheme.of(context).copyWith(
                                trackHeight: 3,
                                thumbShape: const RoundSliderThumbShape(
                                    enabledThumbRadius: 8),
                                overlayShape: const RoundSliderOverlayShape(
                                    overlayRadius: 14),
                              ),
                              child: Slider(
                                value: _width,
                                min: 1,
                                max: 18,
                                activeColor: AppColors.accent,
                                onChanged: (v) =>
                                    setState(() => _width = v),
                              ),
                            ),
                          ),
                          SizedBox(
                            width: 36,
                            child: Text('${_width.toStringAsFixed(0)}px',
                                textAlign: TextAlign.right,
                                style: TextStyle(
                                    color: pal.sub,
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600)),
                          ),
                        ]),
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
}

class _Island extends StatelessWidget {
  final Widget child;
  const _Island({required this.child});
  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    return Container(
      decoration: BoxDecoration(
        color: pal.cont,
        borderRadius: BorderRadius.circular(22),
      ),
      child: child,
    );
  }
}

class _CircleBtn extends StatelessWidget {
  final String icon;
  final Color bg;
  final Color fg;
  final VoidCallback? onTap;
  const _CircleBtn(
      {required this.icon,
      required this.bg,
      required this.fg,
      required this.onTap});
  @override
  Widget build(BuildContext context) {
    return PressScale(
      onTap: onTap,
      scale: 0.92,
      child: Opacity(
        opacity: onTap == null ? 0.4 : 1,
        child: Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
          alignment: Alignment.center,
          child: Iconify(icon, size: 22, color: fg),
        ),
      ),
    );
  }
}

class _ToolBtn extends StatelessWidget {
  final String icon;
  final bool active;
  final VoidCallback onTap;
  const _ToolBtn({
    required this.icon,
    required this.active,
    required this.onTap,
  });
  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    return PressScale(
      onTap: onTap,
      scale: 0.92,
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: active ? AppColors.accent.withValues(alpha: 0.20) : pal.cont2,
          borderRadius: BorderRadius.circular(11),
        ),
        alignment: Alignment.center,
        child: Iconify(icon,
            size: 18, color: active ? AppColors.accent : pal.text),
      ),
    );
  }
}

class _DrawCanvas extends StatefulWidget {
  final ui.Image image;
  final List<_Stroke> strokes;
  final Color color;
  final double width;
  final _Tool tool;
  final VoidCallback onChange;
  const _DrawCanvas({
    required this.image,
    required this.strokes,
    required this.color,
    required this.width,
    required this.tool,
    required this.onChange,
  });
  @override
  State<_DrawCanvas> createState() => _DrawCanvasState();
}

class _DrawCanvasState extends State<_DrawCanvas> {
  _Stroke? _current;
  // Минимальное расстояние между соседними точками пера: меньше точек —
  // меньше памяти и быстрее рендер. На глаз 1.5 px ≈ безотличимо от
  // полного потока pan-событий, но в 3–5 раз меньше нагрузка.
  static const double _kPenMinDist = 1.5;
  // Notifier для CustomPaint — заставляет painter перерисоваться без
  // setState() всего виджета. Рисование больше не вызывает rebuild
  // дерева, только paint frame, что критично для плавности 60 fps при
  // большом количестве точек.
  final ValueNotifier<int> _repaint = ValueNotifier<int>(0);

  void _bump() => _repaint.value = _repaint.value + 1;

  @override
  void dispose() {
    _repaint.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _DrawCanvas old) {
    super.didUpdateWidget(old);
    // Если родитель удалил/изменил список штрихов снаружи (например,
    // нажата кнопка Undo в нижнем тулбаре), painter не узнает об этом
    // через свой внутренний _repaint-нотификатор — нужно явно дёрнуть
    // его, иначе на экране остаётся «застывший» удалённый штрих и
    // пользователю кажется, что Undo «не работает».
    //
    // Сравнивать `old.strokes.length` с `widget.strokes.length`
    // бесполезно: родитель передаёт ОДНУ И ТУ ЖЕ List-ссылку, поэтому
    // после `removeLast()` обе длины уже одинаковые. Просто всегда
    // дёргаем repaint при любом ребилде родителя — родитель ребилдится
    // только на изменение инструмента/цвета/Undo, лишних кадров нет.
    _bump();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onPanStart: (d) {
        if (widget.tool == _Tool.pen) {
          _current = _Stroke(
              _Tool.pen, [d.localPosition], widget.color, widget.width);
        } else {
          _current = _Stroke(widget.tool,
              [d.localPosition, d.localPosition], widget.color, widget.width);
        }
        widget.strokes.add(_current!);
        _bump();
      },
      onPanUpdate: (d) {
        final cur = _current;
        if (cur == null) return;
        if (cur.tool == _Tool.pen) {
          final last = cur.points.last;
          final dx = d.localPosition.dx - last.dx;
          final dy = d.localPosition.dy - last.dy;
          if (dx * dx + dy * dy < _kPenMinDist * _kPenMinDist) return;
          cur.points.add(d.localPosition);
        } else {
          // rect / arrow: только конечная точка двигается
          cur.points[1] = d.localPosition;
        }
        _bump();
      },
      onPanEnd: (_) {
        _current = null;
        // По окончании штриха вызываем onChange один раз, чтобы родитель
        // мог, например, обновить состояние «Undo» — но теперь это не
        // запускает rebuild для каждой pan-точки.
        widget.onChange();
      },
      child: CustomPaint(
        // repaint: notifier — единственный триггер перерисовки во время
        // рисования. В paint() читаются актуальные strokes и активный
        // _current, так что одного бампa notifier-а хватает.
        painter: _CanvasPainter(
          image: widget.image,
          strokes: widget.strokes,
          repaint: _repaint,
        ),
        child: const SizedBox.expand(),
      ),
    );
  }
}

class _CanvasPainter extends CustomPainter {
  final ui.Image image;
  final List<_Stroke> strokes;
  _CanvasPainter({
    required this.image,
    required this.strokes,
    required Listenable repaint,
  }) : super(repaint: repaint);

  @override
  void paint(Canvas canvas, Size size) {
    // image — у бокса задана пропорция картинки, поэтому fit: cover/contain
    // даст одинаковый результат и не оставит полос.
    final iw = image.width.toDouble();
    final ih = image.height.toDouble();
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, iw, ih),
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint()..filterQuality = FilterQuality.medium,
    );
    for (final s in strokes) {
      final paint = Paint()
        ..color = s.color
        ..strokeWidth = s.width
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke;
      switch (s.tool) {
        case _Tool.pen:
          if (s.points.length == 1) {
            // Одиночная точка — рисуем заполненный кружок (бывший fallback).
            canvas.drawCircle(s.points[0], s.width / 2,
                Paint()..color = s.color);
          } else {
            // Один drawPath для всего штриха вместо drawLine на каждый
            // сегмент. На длинных штрихах это в 5–10 раз быстрее.
            canvas.drawPath(s.path, paint);
          }
          break;
        case _Tool.rect:
          if (s.points.length >= 2) {
            final rect = Rect.fromPoints(s.points[0], s.points[1]);
            canvas.drawRRect(
                RRect.fromRectAndRadius(rect, const Radius.circular(6)),
                paint);
          }
          break;
        case _Tool.arrow:
          if (s.points.length >= 2) {
            final p1 = s.points[0];
            final p2 = s.points[1];
            canvas.drawLine(p1, p2, paint);
            // arrow head
            final dx = p2.dx - p1.dx;
            final dy = p2.dy - p1.dy;
            final len = math.sqrt(dx * dx + dy * dy);
            if (len > 1) {
              final ux = dx / len;
              final uy = dy / len;
              final headLen = math.max(s.width * 4, 14.0);
              const headAngle = math.pi / 6;
              final cosA = math.cos(headAngle);
              final sinA = math.sin(headAngle);
              // rotate -uy * headLen, ux * headLen by ±headAngle
              final hx1 = -ux * cosA + uy * sinA;
              final hy1 = -uy * cosA - ux * sinA;
              final hx2 = -ux * cosA - uy * sinA;
              final hy2 = -uy * cosA + ux * sinA;
              canvas.drawLine(
                  p2,
                  Offset(p2.dx + hx1 * headLen, p2.dy + hy1 * headLen),
                  paint);
              canvas.drawLine(
                  p2,
                  Offset(p2.dx + hx2 * headLen, p2.dy + hy2 * headLen),
                  paint);
            }
          }
          break;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _CanvasPainter oldDelegate) =>
      oldDelegate.image != image || oldDelegate.strokes != strokes;
}
