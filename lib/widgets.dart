import 'package:flutter/material.dart';

import 'theme.dart';

/// Прозрачная плашка-фейд для зоны статусбара. Размещается в Stack
/// поверх контента, чтобы тот плавно «уходил» под статусбар.
class TopFadeOverlay extends StatelessWidget {
  final double extra;
  const TopFadeOverlay({super.key, this.extra = 28});

  @override
  Widget build(BuildContext context) {
    final topInset = MediaQuery.of(context).padding.top;
    return IgnorePointer(
      child: SizedBox(
        height: topInset + extra,
        width: double.infinity,
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: buildTopFadeGradient(AppColors.bg),
          ),
        ),
      ),
    );
  }
}

/// Шапка экрана: прозрачный фон, плавный градиент сверху, заголовок и
/// опциональные trailing-иконки. Контент основного экрана должен
/// учитывать высоту этой шапки в своём top-паддинге.
class TopFadeHeader extends StatelessWidget {
  final String title;
  final List<Widget> trailing;
  final VoidCallback? onBack;
  final double bottomPadding;

  const TopFadeHeader({
    super.key,
    required this.title,
    this.trailing = const [],
    this.onBack,
    this.bottomPadding = 22,
  });

  @override
  Widget build(BuildContext context) {
    final topInset = MediaQuery.of(context).padding.top;
    return Container(
      padding: EdgeInsets.fromLTRB(18, topInset + 10, 14, bottomPadding),
      decoration: BoxDecoration(
        gradient: buildTopFadeGradient(AppColors.bg),
      ),
      child: Row(
        children: [
          if (onBack != null) ...[
            _CircleIconButton(
              icon: Icons.arrow_back_ios_new_rounded,
              onTap: onBack,
            ),
            const SizedBox(width: 10),
          ],
          Expanded(
            child: Text(
              title,
              style: const TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.4,
                height: 1.15,
                color: AppColors.text,
              ),
            ),
          ),
          ...trailing,
        ],
      ),
    );
  }
}

class _CircleIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;
  const _CircleIconButton({required this.icon, this.onTap});

  @override
  Widget build(BuildContext context) {
    return CircleIconChip(icon: icon, onTap: onTap);
  }
}

/// Маленькая «пилюлька»-кнопка с иконкой 38×38 в стиле header-trailing.
class CircleIconChip extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;
  final Color? color;
  const CircleIconChip({
    super.key,
    required this.icon,
    this.onTap,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    return PressScale(
      onTap: onTap,
      scale: 0.92,
      child: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          color: color ?? AppColors.cont,
          borderRadius: BorderRadius.circular(AppRadii.btn),
        ),
        alignment: Alignment.center,
        child: Icon(icon, color: AppColors.text, size: 19),
      ),
    );
  }
}

/// Лёгкая «press-scale» обёртка — небольшое уменьшение виджета при
/// нажатии. Без opacity-дима, как в референсе.
class PressScale extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final double scale;
  final HitTestBehavior behavior;
  const PressScale({
    super.key,
    required this.child,
    this.onTap,
    this.scale = 0.97,
    this.behavior = HitTestBehavior.opaque,
  });

  @override
  State<PressScale> createState() => _PressScaleState();
}

class _PressScaleState extends State<PressScale> {
  bool _down = false;

  void _set(bool v) {
    if (mounted && _down != v) setState(() => _down = v);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: widget.behavior,
      onTapDown: (_) => _set(true),
      onTapUp: (_) => _set(false),
      onTapCancel: () => _set(false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _down ? widget.scale : 1.0,
        duration: const Duration(milliseconds: 110),
        curve: Curves.easeOut,
        child: widget.child,
      ),
    );
  }
}

/// Контейнер-карточка в стиле iOS-настроек.
class CardBox extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;
  final EdgeInsets margin;
  final Color? color;
  final double radius;
  const CardBox({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.margin = EdgeInsets.zero,
    this.color,
    this.radius = AppRadii.card,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: margin,
      padding: padding,
      decoration: BoxDecoration(
        color: color ?? AppColors.cont,
        borderRadius: BorderRadius.circular(radius),
      ),
      child: child,
    );
  }
}

/// Тайл-строка с иконкой, заголовком и trailing — для настроек.
class SettingsTile extends StatelessWidget {
  final IconData icon;
  final Color iconBg;
  final String title;
  final String? sub;
  final Widget? trailing;
  final VoidCallback? onTap;
  const SettingsTile({
    super.key,
    required this.icon,
    required this.iconBg,
    required this.title,
    this.sub,
    this.trailing,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return PressScale(
      onTap: onTap,
      scale: 1.0,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 14),
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
              child: Icon(icon, color: Colors.white, size: 19),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                      letterSpacing: -0.1,
                      color: AppColors.text,
                    ),
                  ),
                  if (sub != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      sub!,
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.sub,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (trailing != null) trailing!,
          ],
        ),
      ),
    );
  }
}

/// Основная «push»-кнопка с акцентным фоном.
class PrimaryButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onTap;
  final Color? color;
  final Color? textColor;
  final double height;

  const PrimaryButton({
    super.key,
    required this.label,
    this.icon,
    this.onTap,
    this.color,
    this.textColor,
    this.height = 54,
  });

  @override
  Widget build(BuildContext context) {
    return PressScale(
      onTap: onTap,
      scale: 0.98,
      child: Container(
        width: double.infinity,
        height: height,
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          color: color ?? AppColors.accent,
          borderRadius: BorderRadius.circular(AppRadii.btn),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 20, color: textColor ?? Colors.white),
              const SizedBox(width: 8),
            ],
            Text(
              label,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                letterSpacing: -0.2,
                color: textColor ?? Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Прозрачная «ghost»-кнопка с обводкой.
class GhostButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onTap;
  final double height;
  const GhostButton({
    super.key,
    required this.label,
    this.icon,
    this.onTap,
    this.height = 54,
  });

  @override
  Widget build(BuildContext context) {
    return PressScale(
      onTap: onTap,
      scale: 0.98,
      child: Container(
        width: double.infinity,
        height: height,
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          color: AppColors.cont,
          borderRadius: BorderRadius.circular(AppRadii.btn),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 20, color: AppColors.text),
              const SizedBox(width: 8),
            ],
            Text(
              label,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                letterSpacing: -0.2,
                color: AppColors.text,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Сегментированный селектор (для скорости / размера шрифта).
class SegmentSelector<T> extends StatelessWidget {
  final List<T> values;
  final List<String> labels;
  final T selected;
  final ValueChanged<T> onChanged;
  const SegmentSelector({
    super.key,
    required this.values,
    required this.labels,
    required this.selected,
    required this.onChanged,
  }) : assert(values.length == labels.length);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: AppColors.cont2,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          for (int i = 0; i < values.length; i++)
            Expanded(
              child: PressScale(
                onTap: () => onChanged(values[i]),
                scale: 0.96,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.easeOutCubic,
                  height: 36,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: selected == values[i]
                        ? AppColors.cont
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    labels[i],
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: selected == values[i]
                          ? AppColors.text
                          : AppColors.sub,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Лёгкая горизонтальная разделительная линия в стиле iOS.
class HairlineDivider extends StatelessWidget {
  final double indent;
  const HairlineDivider({super.key, this.indent = 16});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 0.5,
      margin: EdgeInsets.symmetric(horizontal: indent),
      color: AppColors.sep,
    );
  }
}
