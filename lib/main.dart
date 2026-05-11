import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'iconify_precache.dart';
import 'screens/shell.dart';
import 'screens/splash.dart';
import 'state.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Edge-to-edge режим — настраиваем один раз в main(), чтобы не
  // дёргать SystemChrome на каждый rebuild MaterialApp. Раньше build()
  // _RootState на любой touch() в AppState синхронно звал
  // SystemChrome.setSystemUIOverlayStyle через method-channel, что
  // забирало 2-4ms на UI-треде на каждый кадр пере-сборки (а пересборка
  // была буквально на любой чих — bug n/a в комментариях).
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge,
      overlays: SystemUiOverlay.values);
  _applyOverlayStyle(AppState.I.isDark);
  // Параллельно: грузим стейт и прогреваем кэш SVG, чтобы иконки рисовались
  // мгновенно во всех экранах без «лагов» при первом показе.
  await Future.wait<void>([
    AppState.I.load(),
    precacheAllSvgs(),
  ]);
  // После загрузки темы из SharedPreferences — обновляем overlay на
  // случай, если пользователь хранил «светлую» (в main() мы ставили
  // дефолтную тёмную).
  _applyOverlayStyle(AppState.I.isDark);
  runApp(const _Root());
}

SystemUiOverlayStyle _overlayFor(bool isDark) => SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
      statusBarBrightness: isDark ? Brightness.dark : Brightness.light,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarIconBrightness:
          isDark ? Brightness.light : Brightness.dark,
      systemNavigationBarDividerColor: Colors.transparent,
      systemNavigationBarContrastEnforced: false,
    );

void _applyOverlayStyle(bool isDark) {
  SystemChrome.setSystemUIOverlayStyle(_overlayFor(isDark));
}

class _Root extends StatefulWidget {
  const _Root();
  @override
  State<_Root> createState() => _RootState();
}

class _RootState extends State<_Root> {
  // Кэшируем тему/палитру между ребилдами: build() корневого _Root
  // дёргается на любой touch() в AppState (смена любого поля — от списка
  // багов до кэша репо), и пересборка ThemeData/AppPalette на каждый
  // вызов — это десятки аллокаций Color/TextStyle впустую.
  AppPalette? _palette;
  ThemeData? _theme;
  bool _lastIsDark = AppState.I.isDark;
  int _lastAccent = AppColors.accent.value;

  @override
  void initState() {
    super.initState();
    AppState.I.addListener(_onState);
  }

  @override
  void dispose() {
    AppState.I.removeListener(_onState);
    super.dispose();
  }

  void _onState() {
    // Сбрасываем кэш палитры/темы только когда реально меняется тема
    // или акцент. Раньше: setState({}) на каждое уведомление от
    // AppState — это пере-сборка ВСЕГО дерева, включая MaterialApp
    // (десятки внутренних виджетов).
    final isDark = AppState.I.isDark;
    final accent = AppColors.accent.value;
    if (isDark != _lastIsDark || accent != _lastAccent) {
      _palette = null;
      _theme = null;
      if (isDark != _lastIsDark) {
        _applyOverlayStyle(isDark);
        _lastIsDark = isDark;
      }
      _lastAccent = accent;
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = _palette ??=
        AppState.I.isDark ? AppPalette.darkPalette : AppPalette.lightPalette;
    final theme = _theme ??= _buildTheme(palette);
    final overlay = _overlayFor(palette.isDark);
    return AppPaletteScope(
      palette: palette,
      toggleTheme: () async {
        AppState.I.isDark = !AppState.I.isDark;
        await AppState.I.saveTheme();
        AppState.I.touch();
      },
      child: MaterialApp(
        title: 'GitHub Pusher',
        debugShowCheckedModeBanner: false,
        theme: theme,
        // AnnotatedRegion на корневом уровне, чтобы стиль системного UI
        // применялся ко всем экранам (включая push-роуты), не только к Shell.
        builder: (context, child) => AnnotatedRegion<SystemUiOverlayStyle>(
          value: overlay,
          child: child ?? const SizedBox.shrink(),
        ),
        home: AppState.I.token == null
            ? const SplashScreen()
            : const ShellScreen(),
      ),
    );
  }

  ThemeData _buildTheme(AppPalette p) {
    final base = p.isDark ? ThemeData.dark() : ThemeData.light();
    // Системный шрифт устройства: на Android — Roboto / системный шрифт
    // производителя, на iOS — San Francisco. Не подгружаем Google Fonts.
    final textTheme = base.textTheme.apply(
      bodyColor: p.text,
      displayColor: p.text,
      fontFamily: null,
    );
    return base.copyWith(
      scaffoldBackgroundColor: p.bg,
      colorScheme: base.colorScheme.copyWith(
        primary: p.accent,
        secondary: p.accent2,
        surface: p.cont,
        onSurface: p.text,
      ),
      textTheme: textTheme,
      // Гасим material ripple/highlight — приложение использует
      // собственные PressScale/_PressOpacity, а material splash на каждом
      // тапе создаёт лишний RenderObject + рисует анимацию-ripple на
      // верхнем слое, что особенно заметно во время push-перехода
      // (тап -> push -> ещё кадр-два ripple догоняет).
      splashFactory: NoSplash.splashFactory,
      highlightColor: Colors.transparent,
      // Дефолтный ZoomPageTransitionsBuilder на Android заметно дёргается
      // на middle-end железе при пушах через MaterialPageRoute. Мы
      // практически везде ходим через свой SlideRoute, но если где-то
      // сработает дефолтный path — лучше короткий fade без scale/elevation,
      // он рисуется одним cheap-проходом.
      pageTransitionsTheme: const PageTransitionsTheme(builders: {
        TargetPlatform.android: _FastFadeTransitionsBuilder(),
        TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
      }),
    );
  }
}

/// Лёгкий page-transition builder: короткий fade-through без scale/elevation
/// (особенно важно на Android, где дефолтный ZoomPageTransitions заметно
/// дёргается на middle-end железе).
class _FastFadeTransitionsBuilder extends PageTransitionsBuilder {
  const _FastFadeTransitionsBuilder();
  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return FadeTransition(opacity: animation, child: child);
  }
}
