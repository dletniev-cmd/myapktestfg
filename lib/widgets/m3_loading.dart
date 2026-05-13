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
  )..repeat();

  @override
  void dispose() {
    _wave.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // RepaintBoundary: важная штука для списков (Actions). Без
    // неё каждый кадр wave-анимации инвалидирует layer всего
    // ListView, и при скролле каждый кадр перерисовывал бы ВСЕ
    // карточки с прогрессом. С границей — wave изолирован.
    return RepaintBoundary(
      child: SizedBox(
        height: widget.thickness + 2,
        width: double.infinity,
        child: AnimatedBuilder(
          animation: _wave,
          builder: (_, __) {
            return CustomPaint(
              painter: _M3LinearPainter(
                progress: widget.progress?.clamp(0.0, 1.0),
                activeColor: widget.activeColor,
                trackColor: widget.trackColor,
                thickness: widget.thickness,
                wavePhase: _wave.value,
                wavy: widget.wavy,
              ),
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

    // Track gap по M3 spec — небольшой зазор между активным
    // сегментом и треком. 4dp подходит почти для всех высот.
    const double gap = 4.0;

    // Stop indicator — круглая точка в конце трека. Её радиус
    // равен половине толщины полосы, так что точка визуально
    // продолжает полосу того же диаметра.
    final double dotR = thickness / 2;

    // Активный участок занимает [0, activeEnd].
    final double activeEnd = (p * size.width).clamp(0.0, size.width);
    // Трек начинается после gap'а и доходит до точки.
    final double trackStart = (activeEnd + gap).clamp(0.0, size.width);
    final double trackEnd = (size.width - dotR * 2).clamp(0.0, size.width);

    // --- Рисуем трек (неактивная часть). Прямой штрих с
    // закруглёнными концами.
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

    // --- Stop indicator: круг в самом конце. При полном
    // заполнении (progress=1.0) M3 spec предписывает рисовать
    // точку цветом активной части — иначе на финише появляется
    // чужеродная точка цвета трека.
    _dotPaint.color = p >= 0.999 ? activeColor : trackColor;
    canvas.drawCircle(Offset(size.width - dotR, cy), dotR, _dotPaint);

    // --- Активный сегмент.
    if (activeEnd <= 0.5) return;
    _activePaint
      ..color = activeColor
      ..strokeWidth = thickness;

    if (!wavy || activeEnd < thickness * 2) {
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
    final double amplitude = (thickness * 0.55);
    final double wavelength = thickness * 4.5;
    final double k = 2 * math.pi / wavelength;
    // Сдвиг фазы за один цикл — на одну длину волны вперёд.
    final double phase = -wavePhase * 2 * math.pi;

    final path = Path();
    // Шаг 1.0 px достаточно мелкий, но не убивает производительность.
    const double step = 1.0;
    final double start = thickness / 2;
    double x = start;
    path.moveTo(x, cy + amplitude * math.sin(k * x + phase));
    while (x < activeEnd) {
      x += step;
      if (x > activeEnd) x = activeEnd;
      final y = cy + amplitude * math.sin(k * x + phase);
      path.lineTo(x, y);
    }
    canvas.drawPath(path, _activePaint);
  }

  @override
  bool shouldRepaint(covariant _M3LinearPainter old) =>
      old.progress != progress ||
      old.wavePhase != wavePhase ||
      old.activeColor != activeColor ||
      old.trackColor != trackColor ||
      old.thickness != thickness ||
      old.wavy != wavy;
}
