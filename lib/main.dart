import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'screens/home.dart';
import 'speech.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Edge-to-edge: статусбар и нав-бар прозрачные, контент рисуется
  // под ними. В сочетании с TopFadeHeader это даёт мягкое затемнение
  // сверху и плавный «уход» текста под статусбар.
  SystemChrome.setEnabledSystemUIMode(
    SystemUiMode.edgeToEdge,
    overlays: SystemUiOverlay.values,
  );
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    statusBarBrightness: Brightness.dark,
    systemNavigationBarColor: Colors.transparent,
    systemNavigationBarIconBrightness: Brightness.light,
    systemNavigationBarDividerColor: Colors.transparent,
    systemNavigationBarContrastEnforced: false,
  ));
  // Прогреваем speech_to_text заранее, чтобы первый toggle микрофона
  // не блокировал UI на инициализации нативного движка.
  // Не критично, поэтому без await.
  // ignore: discarded_futures
  SpeechService.I.init();
  runApp(const SuflyorApp());
}

class SuflyorApp extends StatelessWidget {
  const SuflyorApp({super.key});

  @override
  Widget build(BuildContext context) {
    final base = ThemeData.dark(useMaterial3: true);
    return MaterialApp(
      title: 'Суфлёр',
      debugShowCheckedModeBanner: false,
      theme: base.copyWith(
        scaffoldBackgroundColor: AppColors.bg,
        canvasColor: AppColors.bg,
        colorScheme: base.colorScheme.copyWith(
          primary: AppColors.accent,
          secondary: AppColors.accent,
          surface: AppColors.cont,
          onSurface: AppColors.text,
          surfaceTint: Colors.transparent,
        ),
        splashFactory: NoSplash.splashFactory,
        highlightColor: Colors.transparent,
        textSelectionTheme: TextSelectionThemeData(
          cursorColor: AppColors.accent,
          selectionColor: AppColors.accent.withValues(alpha: 0.35),
          selectionHandleColor: AppColors.accent,
        ),
      ),
      home: const HomeScreen(),
    );
  }
}
