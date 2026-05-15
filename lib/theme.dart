import 'package:flutter/material.dart';

/// Цветовая палитра «Суфлёра».
///
/// Базовые токены взяты из дизайн-системы референсного приложения:
/// чёрный фон с тёмно-серыми контейнерами в духе iOS-настроек и
/// акцентным лавандово-фиолетовым.
class AppColors {
  AppColors._();

  static const Color accent = Color(0xFF9885E2);
  static const Color accent2 = Color(0xFF7E6BD0);

  static const Color red = Color(0xFFFF4D55);
  static const Color orange = Color(0xFFFF8E2B);
  static const Color yellow = Color(0xFFFFC83D);
  static const Color green = Color(0xFF34C969);
  static const Color blue = Color(0xFF3990FF);
  static const Color purple = Color(0xFFA66BD9);
  static const Color pink = Color(0xFFFF5C89);

  // Dark theme — основной режим приложения.
  static const Color bg = Color(0xFF000000);
  static const Color cont = Color(0xFF1C1C1E);
  static const Color cont2 = Color(0xFF2C2C2E);
  static const Color text = Color(0xFFFFFFFF);
  static const Color sub = Color(0xFF8E8E93);
  static const Color sep = Color(0x2E96969A);
}

class AppRadii {
  AppRadii._();
  static const double card = 18.0;
  static const double tile = 22.0;
  static const double btn = 16.0;
  static const double pill = 999.0;
}

/// Мягкий градиент-фейд для зоны статусбара: содержимое плавно
/// «тонет» под прозрачным верхом экрана, без резкой полосы границы.
LinearGradient buildTopFadeGradient(Color bg) => LinearGradient(
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
