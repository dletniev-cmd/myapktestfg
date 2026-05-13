// ============================================================
// Material 3 «expressive» Loading Indicator — обёртка над
// официальным портом из пакета `expressive_loading_indicator`.
// Drop-in API, совместимый с CircularProgressIndicator.
// ============================================================

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
