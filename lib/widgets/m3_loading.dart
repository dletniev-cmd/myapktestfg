// ============================================================
// Material 3 «expressive» Loading Indicators.
//
// 1. M3LoadingIndicator — circular indeterminate. Обёртка над
//    официальным портом androidx.compose.material3.LoadingIndicator
//    из пакета `expressive_loading_indicator`. Кольцо плавно
//    морфит между серией RoundedPolygon'ов — это и есть «новый»
//    M3 expressive вид (https://m3.material.io/components/progress-indicators).
//
// 2. M3LinearProgress — linear determinate с wavy-эффектом
//    активного участка, stop-индикатором (точка в конце трека) и
//    track-gap'ом между активным сегментом и треком — ровно по
//    M3 expressive spec. Реализовано через CustomPainter, потому
//    что стоковый LinearProgressIndicator(year2023:false) в текущей
//    версии Flutter рисует только прямую полосу + stop-точку,
//    без wavy. Wavy — характерная фишка нового M3.
// ============================================================

import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:expressive_loading_indicator/expressive_loading_indicator.dart';

class M3LoadingIndicator extends StatelessWidget {
  final Color? color;
  final Color? backgroundColor;
  final double? strokeWidth;
  final StrokeCap? strokeCap;
  final double? value;
  final Animation<Color?>? valueColor;
  final double? size;

  const M3LoadingIndicator({
    super.key,
    this.color,
    this.backgroundColor,
    this.strokeWidth,
    this.strokeCap,
    this.value,
    this.valueColor,
    this.size,
  });

  @override
  Widget build(BuildContext context) {
    final effectiveColor = color ?? valueColor?.value;
    return ExpressiveLoadingIndicator(
      color: effectiveColor,
      constraints: size != null
          ? BoxConstraints.tightFor(width: size, height: size)
          : null,
      semanticsLabel: 'Loading',
    );
  }
}

/// M3 Expressive linear progress indicator (2024+).
///
/// Активный сегмент рисуется как синусоидальная волна толщины
/// [thickness] цвета [activeColor]. Трек (неактивная часть) —
/// прямая полоса того же thickness'а, но цвета [trackColor].
/// На конце трека — круглая точка («stop indicator»). Между
/// активной частью и треком — небольшой зазор (track gap), как в
/// новом M3 спеке.
///
/// При [progress] = null (или indeterminate=true) активный сегмент
/// бежит туда-сюда, имитируя indeterminate-режим. В этом приложении
/// прогресс рана всегда вычисляется явно (computeRunProgress), так
/// что обычно determinate-режим.
class M3LinearProgress extends StatefulWidget {
  /// Прогресс в диапазоне [0, 1]. Если null — indeterminate.
  final double? progress;
  final Color activeColor;
  final Color trackColor;

  /// Толщина (высота) самой полосы. M3 spec: 4dp/8dp/12dp.
  /// У нас по дефолту 6 — компромисс между видимостью и
  /// компактностью карточек.
  final double thickness;

  /// Включить wavy-эффект (M3 Expressive). Если false — рисуется
  /// прямая полоса (классика M3 2023).
  final bool wavy;

  const M3LinearProgress({
    super.key,
    required this.progress,
    required this.activeColor,
    required this.trackColor,
    this.thickness = 6,
    this.wavy = true,
  });

  @override
  State<M3LinearProgress> createState() => _M3LinearProgressState();
}

class _M3LinearProgressState extends State<M3LinearProgress>
    with SingleTickerProviderStateMixin {
  late final AnimationController _wave = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  );

  @override
  void initState() {
    super.initState();
    // Тикер запускаем ТОЛЬКО для wavy-варианта. Прямая полоса
    // (`wavy=false`, используется в Actions/Run Detail) визуально
    // не зависит от фазы — раньше она всё равно ребилдилась
    // каждый кадр и давала лаг при активной сборке.
    if (widget.wavy) _wave.repeat();
  }

  @override
  void didUpdateWidget(M3LinearProgress old) {
    super.didUpdateWidget(old);
    if (widget.wavy && !_wave.isAnimating) _wave.repeat();
    if (!widget.wavy && _wave.isAnimating) _wave.stop();
  }

  @override
  void dispose() {
    _wave.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Прогресс приходит с пуллинга API раз в несколько секунд.
    // Если рисовать его «как есть», полоса стоит — потом скачком
    // прыгает на новое значение. Чтобы движение было плавным,
    // оборачиваем значение в TweenAnimationBuilder: при каждом
    // апдейте полоса плавно «доезжает» до нового процента за 800мс.
    final actual = widget.progress?.clamp(0.0, 1.0);

    // RepaintBoundary: важная штука для списков (Actions). Без
    // неё каждый кадр wave-анимации инвалидирует layer всего
    // ListView, и при скролле каждый кадр перерисовывал бы ВСЕ
    // карточки с прогрессом. С границей — wave изолирован.
    return RepaintBoundary(
      child: SizedBox(
        height: widget.thickness + 2,
        width: double.infinity,
        child: TweenAnimationBuilder<double>(
          // begin=0 используется ТОЛЬКО для самого первого рендера.
          // TweenAnimationBuilder при последующих обновлениях
          // tween.end автоматически берёт текущее отображаемое
          // значение как новое begin — плавный плыв от старого
          // к новому, без скачков.
          tween: Tween<double>(begin: 0.0, end: actual ?? 0.0),
          duration: const Duration(milliseconds: 800),
          curve: Curves.easeOutCubic,
          builder: (_, animatedProgress, __) {
            return AnimatedBuilder(
              animation: _wave,
              builder: (_, __) {
                return CustomPaint(
                  painter: _M3LinearPainter(
                    progress: actual == null ? null : animatedProgress,
                    activeColor: widget.activeColor,
                    trackColor: widget.trackColor,
                    thickness: widget.thickness,
                    wavePhase: _wave.value,
                    wavy: widget.wavy,
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }
}

class _M3LinearPainter extends CustomPainter {
  final double? progress;
  final Color activeColor;
  final Color trackColor;
  final double thickness;
  final double wavePhase;
  final bool wavy;

  _M3LinearPainter({
    required this.progress,
    required this.activeColor,
    required this.trackColor,
    required this.thickness,
    required this.wavePhase,
    required this.wavy,
  });

  // Префабы Paint'ов: одно выделение на жизнь painter'а, а не на
  // каждый кадр — без этого ListView с активными прогресс-барами
  // создавал бы десятки Paint'ов в секунду.
  static final Paint _activePaint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;
  static final Paint _trackPaint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round;
  static final Paint _dotPaint = Paint()..style = PaintingStyle.fill;

  @override
  void paint(Canvas canvas, Size size) {
    final cy = size.height / 2;
    final p = (progress ?? 0.0).clamp(0.0, 1.0);

    // Track gap по M3 spec — зазор между активным сегментом
    // и треком. 4dp в спеке, но с rounded-cap'ами на обоих концах
    // визуальный gap становится меньше → берём 6dp чтобы он
    // был чётко виден (юзер жаловался что не похоже на M3).
    const double gap = 6.0;

    // Stop indicator (круглая точка) рисуется ТОЛЬКО для прямой
    // полосы (`wavy=false`). У wavy-полосы концы волны со
    // `StrokeCap.round` сами по себе и есть «индикатор», а
    // отдельная точка на средней линии визуально «отрывается»
    // от синусоидальной траектории — это и был баг про
    // «какую-то точку» в карточке заливки.
    final double dotR = thickness / 2;

    // Активный участок: ограничиваем `[thickness/2, w-thickness/2]`,
    // чтобы rounded-cap-ы волны/прямой не выходили за рамку.
    final double maxRight = size.width - thickness / 2;
    final double activeEnd = (p * size.width).clamp(thickness / 2, maxRight);
    // Трек начинается после gap'а и доходит до края (минус
    // место для точки если она рисуется).
    final double trackStart = (activeEnd + gap).clamp(0.0, size.width);
    final double trackEnd = wavy
        ? maxRight
        : (size.width - dotR * 2).clamp(0.0, size.width);

    // --- Трек (неактивная часть).
    if (trackEnd > trackStart) {
      _trackPaint
        ..color = trackColor
        ..strokeWidth = thickness;
      canvas.drawLine(
        Offset(trackStart, cy),
        Offset(trackEnd, cy),
        _trackPaint,
      );
    }

    // --- Stop indicator (только для прямой). По M3 spec
    // на финише точка перекрашивается в цвет активной части.
    if (!wavy) {
      _dotPaint.color = p >= 0.999 ? activeColor : trackColor;
      canvas.drawCircle(Offset(size.width - dotR, cy), dotR, _dotPaint);
    }

    // --- Активный сегмент.
    if (activeEnd <= thickness / 2 + 0.5) return;
    _activePaint
      ..color = activeColor
      ..strokeWidth = thickness;

    if (!wavy || activeEnd - thickness / 2 < thickness * 2) {
      // На очень коротких прогрессах wavy визуально превращается
      // в зигзаг и выглядит хуже прямой линии — рисуем прямую.
      canvas.drawLine(
        Offset(thickness / 2, cy),
        Offset(activeEnd, cy),
        _activePaint,
      );
      return;
    }

    // Синусоида: амплитуда ~ половина свободного места над
    // полосой, длина волны ~ 4× толщина. Фаза двигается через
    // wavePhase, что создаёт ощущение «бегущей волны» —
    // классическая фича M3 Expressive.
    final double baseAmp = thickness * 0.55;
    final double wavelength = thickness * 4.5;
    final double k = 2 * math.pi / wavelength;
    // Сдвиг фазы за один цикл — на одну длину волны вперёд.
    final double phase = -wavePhase * 2 * math.pi;
    // Taper zone: амплитуда плавно вырастает с 0 до baseAmp на
    // первом отрезке и так же спадает к концу — волна аккуратно
    // «уседает» в центральную линию вместо обрыва на пике.
    final double start = thickness / 2;
    final double taper = thickness * 1.5;

    final path = Path();
    const double step = 1.0;
    double x = start;
    double ampAt(double xv) {
      final fromStart = xv - start;
      final fromEnd = activeEnd - xv;
      final tStart = (fromStart / taper).clamp(0.0, 1.0);
      final tEnd = (fromEnd / taper).clamp(0.0, 1.0);
      final attenuation = math.min(tStart, tEnd);
      return baseAmp * attenuation;
    }

    path.moveTo(x, cy + ampAt(x) * math.sin(k * x + phase));
    while (x < activeEnd) {
      x += step;
      if (x > activeEnd) x = activeEnd;
      final y = cy + ampAt(x) * math.sin(k * x + phase);
      path.lineTo(x, y);
    }
    canvas.drawPath(path, _activePaint);
  }

  @override
  bool shouldRepaint(covariant _M3LinearPainter old) {
    // Прямой вариант (wavy=false) НЕ зависит от фазы, поэтому
    // никаких per-frame перерисовок. progress всё ещё триггерит
    // repaint, что и нужно.
    if (old.progress != progress ||
        old.activeColor != activeColor ||
        old.trackColor != trackColor ||
        old.thickness != thickness ||
        old.wavy != wavy) {
      return true;
    }
    return wavy && old.wavePhase != wavePhase;
  }
}

/// Текстовый виджет с «живой» сменой содержимого: при изменении
/// `text` старая строка плавно уезжает вверх и растворяется, а новая
/// поднимается снизу из прозрачности — ровно как у показаний таймера
/// в современных Material 3 экранах. Используется для счётчиков
/// в стиле «обновлено 3с назад», где цифры тикают каждую секунду
/// и должны меняться красиво, а не дёргаться.
///
/// Анимируется ВСЁ содержимое виджета — поэтому в реальном UI
/// мы оборачиваем в [RisingText] только ту часть, которая меняется
/// часто (например, цифру), а статичный префикс/суффикс выводим
/// рядом обычным [Text]. Юзер прямо просил: «анимируется аж весь
/// текст, а надо только цифру!!». Также корректно обрабатывает
/// смену длины (например, «9» → «10») благодаря невидимой
/// «распорке» внутри Stack.
class RisingText extends StatefulWidget {
  final String text;
  final TextStyle? style;
  final Duration duration;
  final Curve curve;
  final TextAlign textAlign;

  /// Доля высоты глифа, на которую старый/новый текст сдвигаются
  /// по вертикали при анимации. 0.6 даёт «солидное» движение, не
  /// слишком резкое и не слишком ленивое.
  final double slideFraction;

  const RisingText({
    super.key,
    required this.text,
    this.style,
    this.duration = const Duration(milliseconds: 320),
    this.curve = Curves.easeOutCubic,
    this.textAlign = TextAlign.start,
    // 0.35 (а не 0.6, как было раньше) — старый текст уезжает мягче,
    // буквально на треть высоты строки. Большая slideFraction в связке
    // с ClipRect давала «бритвенный» срез сверху, юзер жаловался:
    // «когда растворяется ещё сверху обрезвается чем-то, это ужасно».
    // Сейчас ClipRect убран и slide маленький — текст красиво
    // приподнимается и тает, не «спотыкаясь» о невидимую линию.
    this.slideFraction = 0.35,
  });

  @override
  State<RisingText> createState() => _RisingTextState();
}

class _RisingTextState extends State<RisingText>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: widget.duration,
    value: 1.0,
  );
  late String _current;
  String? _previous;

  @override
  void initState() {
    super.initState();
    _current = widget.text;
  }

  @override
  void didUpdateWidget(covariant RisingText old) {
    super.didUpdateWidget(old);
    if (old.duration != widget.duration) {
      _ctrl.duration = widget.duration;
    }
    if (old.text != widget.text) {
      _previous = _current;
      _current = widget.text;
      _ctrl.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final style = widget.style;
    final fontSize = style?.fontSize ?? DefaultTextStyle.of(context).style.fontSize ?? 14.0;
    final slide = fontSize * widget.slideFraction;
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, __) {
        final t = widget.curve.transform(_ctrl.value);
        // На завершённой анимации (t == 1) или если предыдущего
        // текста не было (первый кадр) — рисуем только текущую строку,
        // без Stack/ClipRect. Это даёт нативный layout и нулевой
        // оверхед, пока секунда не тикнула.
        if (t >= 1.0 || _previous == null) {
          return Text(
            _current,
            style: style,
            textAlign: widget.textAlign,
            maxLines: 1,
            softWrap: false,
          );
        }
        // Без ClipRect: раньше Stack оборачивался в ClipRect, и старый
        // текст при slide-вверх «упирался» в верхнюю кромку Stack'a и
        // обрезался ножом по самой яркой части. Теперь slide маленький
        // (~0.35 * fontSize), overflow уходит в свободное пространство
        // над/под status-строкой (там и так пустое место у нас по
        // дизайну), и пользователь видит мягкий лифт + растворение,
        // без «срезания» сверху.
        //
        // Кривая opacity у уходящего текста — ease-out-quad: к моменту
        // когда он уехал заметно вверх, он уже почти прозрачный, так
        // что overflow визуально не выходит за пределы своей строки.
        final fadeOut = (1 - t) * (1 - t);
        final fadeIn = t;
        return Stack(
          alignment: widget.textAlign == TextAlign.end
              ? AlignmentDirectional.centerEnd
              : AlignmentDirectional.centerStart,
          clipBehavior: Clip.none,
          children: [
            // Невидимая «распорка»: гарантирует, что Stack займёт
            // ширину/высоту самой широкой из двух строк, иначе
            // Transform.translate выходит за границы layout'а
            // и текст «обрезается» соседним виджетом.
            Opacity(
              opacity: 0,
              child: Text(
                _previous!.length >= _current.length ? _previous! : _current,
                style: style,
                maxLines: 1,
                softWrap: false,
              ),
            ),
            // Старый текст уезжает вверх и тает (быстрее).
            Transform.translate(
              offset: Offset(0, -slide * t),
              child: Opacity(
                opacity: fadeOut,
                child: Text(
                  _previous!,
                  style: style,
                  textAlign: widget.textAlign,
                  maxLines: 1,
                  softWrap: false,
                ),
              ),
            ),
            // Новый текст приезжает снизу и проявляется.
            Transform.translate(
              offset: Offset(0, slide * (1 - t)),
              child: Opacity(
                opacity: fadeIn,
                child: Text(
                  _current,
                  style: style,
                  textAlign: widget.textAlign,
                  maxLines: 1,
                  softWrap: false,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

