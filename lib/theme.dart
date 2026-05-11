import 'package:flutter/material.dart';

/// Цветовые токены приложения.
///
/// Палитра обновлена (баг n7979): прежние «громкие» iOS-цвета
/// (#FF3B30, #007AFF и т.п.) выглядели на тёмном фоне «кислотно» —
/// заменены на чуть менее насыщенные, более гармоничные оттенки.
/// Базовые нейтральные тона (фон, контейнеры, текст) оставлены без
/// изменений, потому что к ним претензий нет.
class AppColors {
  AppColors._();

  // Акцент — по умолчанию лавандово-фиолетовый. Пользователь может
  // поменять через «Оформление → Акцентный цвет». Значение мутабельно,
  // чтобы 70+ мест, где используется `AppColors.accent`, подхватывали
  // новый цвет без правок в каждом файле.
  static Color accent = const Color(0xFF9885E2);
  static Color accent2 = const Color(0xFF7E6BD0);
  static const Color defaultAccent = Color(0xFF9885E2);

  /// Обновляет accent-пару. `accent2` вычисляется как чуть более тёмная
  /// версия того же оттенка (HSL lightness −0.08).
  static void setAccent(Color c) {
    accent = c;
    final hsl = HSLColor.fromColor(c);
    accent2 = hsl.withLightness((hsl.lightness - 0.08).clamp(0.0, 1.0)).toColor();
  }

  // semantic — после фидбэка «выцветшие» подняли насыщенность,
  // но не возвращаем «громкий» iOS-набор полностью.
  static const red = Color(0xFFFF4D55);
  static const orange = Color(0xFFFF8E2B);
  static const yellow = Color(0xFFFFC83D);
  static const green = Color(0xFF34C969);
  static const lime = Color(0xFF7BD13D);
  static const teal = Color(0xFF2DCFC4);
  static const cyan = Color(0xFF3FCBE6);
  static const blue = Color(0xFF3990FF);
  static const indigo = Color(0xFF6C7BFF);
  static const purple = Color(0xFFA66BD9);
  static const magenta = Color(0xFFE260D6);
  static const pink = Color(0xFFFF5C89);
  static const rose = Color(0xFFFF7AAB);
  static const dark = Color(0xFF2C2C2E);

  // dark theme
  static const bgDark = Color(0xFF000000);
  static const contDark = Color(0xFF1C1C1E);
  static const cont2Dark = Color(0xFF2C2C2E);
  static const textDark = Color(0xFFFFFFFF);
  static const subDark = Color(0xFF8E8E93);
  static const sepDark = Color(0x2E96969A);

  // light theme.
  //
  // НА. Раньше фон был белый (`#FFFFFF`), а контейнеры светло-серые
  // (`#F2F2F7`) — это «обратное» как iOS Settings/Telegram, из-за чего
  // карточки визуально сливались с фоном. Свопнули:
  //   bg     → нейтральный серый (iOS systemGroupedBackground)
  //   cont   → чисто белый — карточки чётко стоят на фоне
  //   cont2  → чуть тёмнее bg — для wells/secondary плашек внутри карточек
  //   sep    → iOS-сепаратор (rgba 60,60,67,36%)
  static const bgLight = Color(0xFFF2F2F7);
  static const contLight = Color(0xFFFFFFFF);
  static const cont2Light = Color(0xFFE5E5EA);
  static const textLight = Color(0xFF000000);
  static const subLight = Color(0xFF6D6D72);
  static const sepLight = Color(0x5C3C3C43);
}

class AppTokens {
  AppTokens._();
  static const rCard = 16.0;
  static const rTile = 22.0;
  static const rIcon = 12.0;
  static const rBtn = 16.0;
}

class AppPalette {
  final Color bg;
  final Color cont;
  final Color cont2;
  final Color text;
  final Color sub;
  final Color sep;
  final Color accent;
  final Color accent2;
  final Color red;
  final Color orange;
  final Color green;
  final Color blue;
  final Color teal;
  final Color purple;
  final Color pink;
  final Color dark;
  final bool isDark;

  AppPalette({
    required this.bg,
    required this.cont,
    required this.cont2,
    required this.text,
    required this.sub,
    required this.sep,
    required this.isDark,
    Color? accent,
    Color? accent2,
    this.red = AppColors.red,
    this.orange = AppColors.orange,
    this.green = AppColors.green,
    this.blue = AppColors.blue,
    this.teal = AppColors.teal,
    this.purple = AppColors.purple,
    this.pink = AppColors.pink,
    this.dark = AppColors.dark,
  })  : accent = accent ?? AppColors.accent,
        accent2 = accent2 ?? AppColors.accent2;

  static AppPalette get darkPalette => AppPalette(
    bg: AppColors.bgDark,
    cont: AppColors.contDark,
    cont2: AppColors.cont2Dark,
    text: AppColors.textDark,
    sub: AppColors.subDark,
    sep: AppColors.sepDark,
    isDark: true,
  );

  static AppPalette get lightPalette => AppPalette(
    bg: AppColors.bgLight,
    cont: AppColors.contLight,
    cont2: AppColors.cont2Light,
    text: AppColors.textLight,
    sub: AppColors.subLight,
    sep: AppColors.sepLight,
    isDark: false,
  );
}

class AppPaletteScope extends InheritedWidget {
  final AppPalette palette;
  final VoidCallback toggleTheme;
  AppPaletteScope({
    super.key,
    required this.palette,
    required this.toggleTheme,
    required super.child,
  });

  static AppPaletteScope of(BuildContext context) {
    final s = context.dependOnInheritedWidgetOfExactType<AppPaletteScope>();
    assert(s != null, 'AppPaletteScope not found');
    return s!;
  }

  @override
  bool updateShouldNotify(AppPaletteScope oldWidget) =>
      oldWidget.palette.isDark != palette.isDark ||
      oldWidget.palette.accent != palette.accent;
}

extension PaletteX on BuildContext {
  AppPalette get pal => AppPaletteScope.of(this).palette;
}
