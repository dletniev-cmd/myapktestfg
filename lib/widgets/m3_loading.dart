// ============================================================
// Material 3 «expressive» Loading Indicator — обёртка над
// официальным портом из пакета `expressive_loading_indicator`.
//
// Пакет — порт компонента `LoadingIndicator` из
// `androidx.compose.material3` на Flutter (формы и тайминги
// совпадают с M3 спекой: непрерывное вращение + морф между
// RoundedPolygon-ами через `material_new_shapes`).
//
// Здесь мы оборачиваем его в drop-in API, совместимый с
// `CircularProgressIndicator` — принимает те же `color`,
// `strokeWidth`, `strokeCap`, `backgroundColor`, `value` (последние
// у блоба не используются и просто игнорируются), плюс опциональный
// `size`. Это позволило массово заменить
// `CircularProgressIndicator` → `M3LoadingIndicator` по всем экранам
// без правки аргументов на местах.
// ============================================================

import 'package:flutter/material.dart';
import 'package:expressive_loading_indicator/expressive_loading_indicator.dart';

class M3LoadingIndicator extends StatelessWidget {
  /// Цвет «активного» индикатора (самого блоба). Если null — берётся
  /// `colorScheme.primary` через сам ExpressiveLoadingIndicator.
  final Color? color;

  /// Ниже — параметры от CircularProgressIndicator. Сохранены ради
  /// drop-in совместимости, при отрисовке игнорируются.
  final Color? backgroundColor;
  final double? strokeWidth;
  final StrokeCap? strokeCap;
  final double? value;

  /// Опциональный фиксированный размер (если виджет не оборачивают
  /// в SizedBox снаружи). M3 default — 38dp активного индикатора
  /// внутри 48dp контейнера; здесь даём прямой `size`, который
  /// конвертируется в BoxConstraints для самого индикатора.
  final double? size;

  const M3LoadingIndicator({
    super.key,
    this.color,
    this.backgroundColor,
    this.strokeWidth,
    this.strokeCap,
    this.value,
    this.size,
  });

  @override
  Widget build(BuildContext context) {
    final indicator = ExpressiveLoadingIndicator(
      color: color,
      // Если size явно задан — пробрасываем как жёсткий констрейнт,
      // иначе пусть растягивается под родительский SizedBox.
      constraints: size != null
          ? BoxConstraints.tightFor(width: size, height: size)
          : null,
      semanticsLabel: 'Loading',
    );
    return indicator;
  }
}
