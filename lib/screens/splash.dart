import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api.dart';
import '../iconify.dart';
import '../notifications.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'shell.dart';

/// Экран входа.
///
/// Состоит из двух стадий, между которыми переключаемся внутри одного
/// Scaffold'а (через AnimatedSwitcher):
///
///   1) [_OnboardingStage] — статичный хиро: лого GitHub, заголовок и
///      подпись «всё, что нужно — на одном экране», sticky-кнопка
///      «Вставить ключ» внизу. На фоне — «призрачные» подписи функций
///      с Solar-иконками, расположенные ДВУМЯ колонками слева и справа
///      от центра. Они стоят на фиксированных местах с лёгким наклоном
///      (-8° слева, +8° справа) и плавно «дышат» — без полёта,
///      масштабирования и спавна (см. [_FeatureParticlesBackground]).
///   2) [_PermissionsStage] — показывается после того, как токен проверен;
///      содержит тумблеры разрешений (уведомления, доступ к галерее)
///      и кнопку «Начать».
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});
  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  // Стадии: 0 — онбординг + вставка ключа, 1 — разрешения.
  int _stage = 0;
  bool _loading = false;
  // Сообщение об ошибке. Намеренно НЕ показываем ничего для
  // «формат не похож на токен» / «пустой буфер» — если ключ не вставился,
  // юзеру и так очевидно по отсутствию перехода на следующий экран.
  // Показываем только реальные сетевые/auth ошибки (401 от GitHub и т.п.).
  String _error = '';

  Future<void> _pasteToken() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final data = await Clipboard.getData('text/plain');
      final raw = (data?.text ?? '').trim();
      if (raw.isEmpty) {
        // Молча выходим — пустой буфер обмена это не ошибка приложения.
        setState(() => _loading = false);
        return;
      }
      // быстрая валидация: ghp_, gho_, ghs_, ghu_, ghr_, github_pat_
      final ok =
          RegExp(r'^(ghp|gho|ghs|ghu|ghr)_|^github_pat_').hasMatch(raw);
      if (!ok) {
        // Не похоже на токен — молча игнорируем без надписи под кнопкой.
        // Пользователь видит, что переход не случился, и сам разберётся.
        setState(() => _loading = false);
        return;
      }
      final api = GhApi(raw);
      final user = await api.me();
      await AppState.I.saveToken(raw);
      AppState.I.user = user;
      // Сохраняем профиль в SharedPreferences сразу, чтобы при холодном
      // запуске пользователь видел аватарку и счётчики мгновенно.
      // ignore: discarded_futures
      AppState.I.saveUser();
      AppState.I.touch();
      // Параллельно с показом экрана разрешений греем тяжёлые ресурсы,
      // чтобы ShellScreen открывался по уже готовым данным.
      // ignore: discarded_futures
      _warmUpForShell(api, user.avatarUrl);
      if (!mounted) return;
      setState(() {
        _loading = false;
        _stage = 1;
      });
    } catch (e) {
      setState(() {
        _loading = false;
        _error =
            'Не удалось войти: ${e.toString().replaceAll('Exception: ', '')}';
      });
    }
  }

  /// Прогрев данных для ShellScreen — пока пользователь смотрит на экран
  /// разрешений и решает что включать, мы фоном тянем профиль/репо/аватарку.
  Future<void> _warmUpForShell(GhApi api, String avatarUrl) async {
    if (avatarUrl.isNotEmpty && mounted) {
      try {
        await precacheImage(NetworkImage(avatarUrl), context);
      } catch (_) {}
    }
    try {
      final repos = await api.myRepos();
      if (!mounted) return;
      AppState.I.repos = repos;
      AppState.I.activeRepo ??= repos.isNotEmpty ? repos.first : null;
      // ignore: discarded_futures
      AppState.I.saveRepos();
    } catch (_) {
      // Молча игнорируем — Shell сделает свой запрос и покажет ошибку.
    }
  }

  void _finishToShell() {
    Navigator.of(context).pushAndRemoveUntil(
      _FadeRoute(child: const ShellScreen()),
      (_) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    // AnimatedContainer на корне даёт плавный переход цвета фона при
    // смене темы (300мс). Содержимое (текст/иконки) ловит новый
    // палитру мгновенно, но в сочетании с анимированным фоном это
    // выглядит как естественная мягкая смена темы (как в Telegram).
    return Scaffold(
      backgroundColor: pal.bg,
      body: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
        color: pal.bg,
        child: SafeArea(
          child: Stack(
            children: [
              // Основной контент стадии (онбординг / разрешения).
              Positioned.fill(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 360),
                  switchInCurve: Curves.easeOutCubic,
                  switchOutCurve: Curves.easeInCubic,
                  transitionBuilder: (child, anim) {
                    final slide = Tween<Offset>(
                      begin: const Offset(0.06, 0),
                      end: Offset.zero,
                    ).animate(anim);
                    return FadeTransition(
                      opacity: anim,
                      child: SlideTransition(position: slide, child: child),
                    );
                  },
                  child: _stage == 0
                      ? _OnboardingStage(
                          key: const ValueKey('onb'),
                          loading: _loading,
                          error: _error,
                          onPaste: _pasteToken,
                        )
                      : _PermissionsStage(
                          key: const ValueKey('perm'),
                          onStart: _finishToShell,
                        ),
                ),
              ),
              // Кнопка смены темы — небольшой круглый тогл в правом
              // верхнем углу. Видна ТОЛЬКО на стадии онбординга:
              // на экране разрешений она не нужна и визуально мешает
              // success-чеку и заголовку "Ключ принят".
              if (_stage == 0)
                Positioned(
                  top: 8,
                  right: 12,
                  child: _ThemeToggleButton(),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Круглая кнопка смены темы в правом верхнем углу splash.
///
/// При тапе вызывает `AppPaletteScope.of(context).toggleTheme()`,
/// который флипает `AppState.I.isDark` и зовёт `touch()`. После
/// touch'а корневой `_Root` пересобирает MaterialApp с новой палитрой,
/// и InheritedWidget доставляет её сюда.
///
/// Анимация:
///   • Иконка sun/moon меняется через `AnimatedSwitcher` с поворотом
///     на 180° и fade — небольшой «солнечно-лунный» спин.
///   • Фон/border кнопки анимируется через `AnimatedContainer` (300мс).
///   • Фон всего splash тоже анимируется через `AnimatedContainer`
///     в корне `_SplashScreenState.build` — это даёт плавный переход
///     цвета подложки при смене темы.
class _ThemeToggleButton extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    final isDark = pal.isDark;
    final iconName = isDark ? 'solar:sun-2-bold' : 'solar:moon-stars-bold';
    // Чистая иконка без подложки/обводки — юзер просил «сама по себе».
    // Обе темы используют акцентный цвет (как и логотип на светлой теме).
    final iconColor = AppColors.accent;
    // Хит-зона 44×44 для удобного тапа, но визуально — только иконка.
    return PressScale(
      onTap: () => AppPaletteScope.of(context).toggleTheme(),
      scale: 0.88,
      child: SizedBox(
        width: 44,
        height: 44,
        child: Center(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 320),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            transitionBuilder: (child, anim) {
              final rotate = Tween<double>(begin: 0.5, end: 0.0).animate(
                CurvedAnimation(parent: anim, curve: Curves.easeOutCubic),
              );
              return FadeTransition(
                opacity: anim,
                child: RotationTransition(turns: rotate, child: child),
              );
            },
            child: Iconify(
              iconName,
              key: ValueKey<bool>(isDark),
              size: 26,
              color: iconColor,
            ),
          ),
        ),
      ),
    );
  }
}

/// Fade-переход для splash → shell. Используем именно здесь (а не общий
/// `SlideRoute`), потому что первый кадр ShellScreen тяжёлый: внутри
/// IndexedStack с ProfileScreen, который читает AppState и строит
/// карточку профиля + действия + плитки. Со slide-анимацией каждый
/// кадр заставлял Flutter полностью раскадрировать это дерево в новой
/// позиции; с fade — дерево рисуется один раз и потом меняется только
/// альфа композитного слоя, что в разы дешевле.
class _FadeRoute<T> extends PageRouteBuilder<T> {
  _FadeRoute({required Widget child})
      : super(
          opaque: true,
          transitionDuration: const Duration(milliseconds: 320),
          reverseTransitionDuration: const Duration(milliseconds: 320),
          pageBuilder: (_, __, ___) => child,
          transitionsBuilder: (_, anim, __, child) {
            final curved = CurvedAnimation(
              parent: anim,
              curve: Curves.easeOut,
            );
            return FadeTransition(opacity: curved, child: child);
          },
        );
}

// =====================================================================
// Стадия 1. Онбординг (статичный хиро + летающие описания функций)
// =====================================================================

/// Описание одной «призрачной» подписи на фоне: иконка из набора Solar
/// + короткая подпись. Конкретные экземпляры хардкожены в
/// [_kFloatingLayout] ниже (5 слева, 5 справа), вместе с их позицией,
/// наклоном и параметрами «дыхания».
class _GhostFeature {
  final String iconName;
  final String text;
  const _GhostFeature(this.iconName, this.text);
}

class _OnboardingStage extends StatelessWidget {
  final bool loading;
  final String error;
  final Future<void> Function() onPaste;
  const _OnboardingStage({
    super.key,
    required this.loading,
    required this.error,
    required this.onPaste,
  });

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    // Хиро + фон лежат в Stack. Фон ниже, на нём анимация — она
    // изолирована собственным RepaintBoundary внутри _FeatureParticlesBackground.
    // Передний план (лого/текст/кнопка) тоже обёрнут в RepaintBoundary,
    // чтобы каждый кадр фоновой анимации НЕ заставлял Flutter перерисовывать
    // дерево хиро (это ключевое для 60fps).
    return Stack(
      fit: StackFit.expand,
      children: [
        const Positioned.fill(child: _FeatureParticlesBackground()),
        Positioned.fill(
          child: RepaintBoundary(
            child: _OnboardingHero(
              loading: loading,
              error: error,
              onPaste: onPaste,
              pal: pal,
            ),
          ),
        ),
      ],
    );
  }
}

/// Статичный хиро: лого GitHub + заголовок + подпись, sticky-кнопка
/// «Вставить ключ» внизу. Никаких PageView/каруселей — всё на месте.
class _OnboardingHero extends StatelessWidget {
  final bool loading;
  final String error;
  final Future<void> Function() onPaste;
  final AppPalette pal;
  const _OnboardingHero({
    required this.loading,
    required this.error,
    required this.onPaste,
    required this.pal,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Верхний воздух больше нижнего → группа «лого+текст»
        // визуально ровно по центру свободной области.
        const Spacer(flex: 2),
        // Лого GitHub. На светлой теме — акцентный фиолетовый,
        // на тёмной — белый (как и было).
        Iconify(
          'mdi:github',
          size: 156,
          color: pal.isDark ? pal.text : AppColors.accent,
        ),
        const SizedBox(height: 20),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'GitHub Pusher',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w600,
                  letterSpacing: -.3,
                  color: pal.text,
                ),
              ),
              const SizedBox(height: 10),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 320),
                child: Text(
                  'всё, что нужно — на одном экране',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 14.5,
                    color: pal.sub,
                    height: 1.5,
                  ),
                ),
              ),
            ],
          ),
        ),
        const Spacer(flex: 1),
        // Нижний блок: кнопка + ссылка + ошибка/хинт.
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              PressScale(
                onTap: loading ? null : () => onPaste(),
                scale: 0.97,
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  decoration: BoxDecoration(
                    color: AppColors.accent,
                    borderRadius: BorderRadius.circular(18),
                    boxShadow: [
                      BoxShadow(
                        color: AppColors.accent.withValues(alpha: 0.20),
                        blurRadius: 20,
                        offset: const Offset(0, 8),
                      ),
                    ],
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (loading)
                        const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                            color: Colors.white,
                            strokeWidth: 2.4,
                            strokeCap: StrokeCap.round,
                          ),
                        )
                      else
                        const Iconify(
                          'solar:clipboard-add-bold',
                          size: 22,
                          color: Colors.white,
                        ),
                      const SizedBox(width: 10),
                      Text(
                        loading ? 'Проверяем…' : 'Вставить ключ',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              PressScale(
                onTap: () => launchUrl(
                  Uri.parse(
                    'https://github.com/settings/tokens/new?scopes=repo,delete_repo,workflow&description=GitHub%20Pusher',
                  ),
                  mode: LaunchMode.externalApplication,
                ),
                scale: 0.97,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Iconify(
                        'solar:link-bold',
                        size: 16,
                        color: AppColors.accent,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        'Получить токен на GitHub',
                        style: TextStyle(
                          color: AppColors.accent,
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              SizedBox(
                height: error.isEmpty ? 6 : 22,
                child: error.isEmpty
                    ? const SizedBox.shrink()
                    : Text(
                        error,
                        style: const TextStyle(
                          color: AppColors.red,
                          fontSize: 13,
                        ),
                        textAlign: TextAlign.center,
                      ),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 2, bottom: 2),
                child: Text(
                  'Ваш токен хранится только на устройстве',
                  style: TextStyle(color: pal.sub, fontSize: 12),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// =====================================================================
//  Анимированный фон: «призрачные» подписи функций плавают по бокам
// =====================================================================
//
// КАК УСТРОЕНО (важно для 60 fps на слабых девайсах):
//   • Подписи зафиксированы на своих местах — две колонки по бокам от
//     центра экрана (5 слева, 5 справа). НЕТ спавна/умирания, НЕТ
//     радиального вылета — это и убивало fps в прежней версии.
//   • Каждая подпись наклонена один раз: слева ~ -8°, справа ~ +8°.
//     Поворот применяется как СТАТИЧНЫЙ Transform.rotate (один раз
//     за время жизни виджета), а не на каждый кадр.
//   • Кадровая анимация — только лёгкий «дыхательный» drift:
//     Transform.translate(Offset(sin(t)*~9, cos(t)*~7)). Это самая
//     дешёвая трансформация — без saveLayer, без матричных raster slow-path.
//   • Один общий [Ticker] на весь фон. Кадровые обновления идут через
//     ValueNotifier<int> _frameTick, на который подписан каждый
//     _FloatingFeatureView через ValueListenableBuilder — ребилдится
//     только лист дерева одной подписи, не вся стадия.
//   • Каждый _FloatingFeatureView обёрнут в собственный RepaintBoundary,
//     поэтому drift одной подписи НЕ заставляет соседние слои
//     перерисовываться. Хиро (лого/заголовок) тоже в RepaintBoundary.
//   • Альфа применяется напрямую к Color.withValues(alpha:) в
//     colorFilter Iconify и TextStyle.color — НИКАКОГО Opacity-виджета
//     (saveLayer убивает fps).
//   • Никакого scale per-frame, никакого spawn/despawn, никаких
//     setState'ов на каждый тик. Только translate + alpha по sin/cos.

/// Один «островок» подписи, который плавает на своём месте.
class _FloatingFeature {
  final _GhostFeature feature;
  final bool onLeft;          // true → колонка слева, false → справа
  final double topFrac;       // 0..1, относительная высота от верха фона
  final double sideInset;     // отступ от ближайшего края (px)
  final double tiltDeg;       // фиксированный наклон в градусах
  final double baseAlpha;     // 0..1
  final double driftAmpX;     // px, амплитуда плавания по X
  final double driftAmpY;     // px, амплитуда плавания по Y
  final double driftPeriodMs; // период колебаний по X (по Y чуть длиннее)
  final double phase;         // 0..2π — сдвиг фазы, чтобы подписи не «дышали в такт»
  final double fontSize;
  const _FloatingFeature({
    required this.feature,
    required this.onLeft,
    required this.topFrac,
    required this.sideInset,
    required this.tiltDeg,
    required this.baseAlpha,
    required this.driftAmpX,
    required this.driftAmpY,
    required this.driftPeriodMs,
    required this.phase,
    required this.fontSize,
  });
}

/// Хардкод-раскладка подписей по сторонам. Подобраны:
///   • Y-позиции так, чтобы НЕ перекрывать центральный блок «лого +
///     заголовок + подзаголовок» (≈ 30%–55% высоты) и нижнюю
///     sticky-кнопку (≈ ниже 78%).
///   • Фазы рассыпаны на (0..2π) — подписи дышат вразнобой.
///   • Тилт чередуется -8/-7° слева и +7/+8° справа — даёт лёгкую
///     «рукописную» нерегулярность как на референсном прототипе.
const List<_FloatingFeature> _kFloatingLayout = [
  // ───── Левая колонка (-8°/-7°) ─────
  _FloatingFeature(
    feature: _GhostFeature('solar:gallery-add-bold', 'Скриншоты к багам'),
    onLeft: true, topFrac: 0.10, sideInset: 18, tiltDeg: -8,
    baseAlpha: 0.55, driftAmpX: 8, driftAmpY: 6, driftPeriodMs: 6400, phase: 0.0,
    fontSize: 14.5,
  ),
  _FloatingFeature(
    feature: _GhostFeature('solar:cloud-upload-bold', 'Заливай файлы'),
    onLeft: true, topFrac: 0.24, sideInset: 12, tiltDeg: -7,
    baseAlpha: 0.52, driftAmpX: 9, driftAmpY: 7, driftPeriodMs: 7300, phase: 1.1,
    fontSize: 14.5,
  ),
  _FloatingFeature(
    feature: _GhostFeature('solar:download-square-bold', 'Скачивай APK'),
    onLeft: true, topFrac: 0.42, sideInset: 24, tiltDeg: -8,
    baseAlpha: 0.50, driftAmpX: 10, driftAmpY: 6, driftPeriodMs: 6800, phase: 2.3,
    fontSize: 14.5,
  ),
  _FloatingFeature(
    feature: _GhostFeature('solar:folder-with-files-bold', 'Все репозитории'),
    onLeft: true, topFrac: 0.57, sideInset: 14, tiltDeg: -7,
    baseAlpha: 0.55, driftAmpX: 8, driftAmpY: 7, driftPeriodMs: 7900, phase: 3.5,
    fontSize: 14.5,
  ),
  _FloatingFeature(
    feature: _GhostFeature('solar:branching-paths-up-bold', 'Ветки и коммиты'),
    onLeft: true, topFrac: 0.69, sideInset: 22, tiltDeg: -8,
    baseAlpha: 0.58, driftAmpX: 9, driftAmpY: 7, driftPeriodMs: 6200, phase: 4.7,
    fontSize: 14.5,
  ),

  // ───── Правая колонка (+7°/+8°) ─────
  _FloatingFeature(
    feature: _GhostFeature('solar:eye-bold', 'Следи за статусом'),
    onLeft: false, topFrac: 0.14, sideInset: 14, tiltDeg: 8,
    baseAlpha: 0.52, driftAmpX: 9, driftAmpY: 7, driftPeriodMs: 7200, phase: 0.6,
    fontSize: 14.5,
  ),
  _FloatingFeature(
    feature: _GhostFeature('solar:rocket-bold', 'Запускай Actions'),
    onLeft: false, topFrac: 0.28, sideInset: 22, tiltDeg: 7,
    baseAlpha: 0.55, driftAmpX: 8, driftAmpY: 6, driftPeriodMs: 6900, phase: 1.8,
    fontSize: 14.5,
  ),
  _FloatingFeature(
    feature: _GhostFeature('solar:bell-bold', 'Уведомления'),
    onLeft: false, topFrac: 0.43, sideInset: 16, tiltDeg: 8,
    baseAlpha: 0.50, driftAmpX: 10, driftAmpY: 7, driftPeriodMs: 7600, phase: 3.0,
    fontSize: 14.5,
  ),
  _FloatingFeature(
    feature: _GhostFeature('solar:star-bold', 'Избранные репо'),
    onLeft: false, topFrac: 0.57, sideInset: 24, tiltDeg: 7,
    baseAlpha: 0.55, driftAmpX: 8, driftAmpY: 7, driftPeriodMs: 6400, phase: 4.2,
    fontSize: 14.5,
  ),
  _FloatingFeature(
    feature: _GhostFeature('solar:check-circle-bold', 'Сборка готова'),
    onLeft: false, topFrac: 0.69, sideInset: 16, tiltDeg: 8,
    baseAlpha: 0.58, driftAmpX: 9, driftAmpY: 6, driftPeriodMs: 7100, phase: 5.4,
    fontSize: 14.5,
  ),
];

class _FeatureParticlesBackground extends StatefulWidget {
  const _FeatureParticlesBackground();

  @override
  State<_FeatureParticlesBackground> createState() =>
      _FeatureParticlesBackgroundState();
}

class _FeatureParticlesBackgroundState
    extends State<_FeatureParticlesBackground>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;

  /// «Тик кадра» в микросекундах. Каждый _FloatingFeatureView слушает
  /// его через ValueListenableBuilder — ребилдятся только листья (одна
  /// подпись), а не вся стадия. setState не вызывается вообще.
  final ValueNotifier<int> _frameTick = ValueNotifier<int>(0);

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((elapsed) {
      _frameTick.value = elapsed.inMicroseconds;
    })..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _frameTick.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    final iconColor = AppColors.accent;
    // Текст подписи — основной цвет темы (контраст), альфа применяется
    // на каждый кадр через TextStyle.color.withValues(alpha:).
    final textColor = pal.text;

    return RepaintBoundary(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final size = Size(constraints.maxWidth, constraints.maxHeight);
          return Stack(
            clipBehavior: Clip.hardEdge,
            children: [
              for (int i = 0; i < _kFloatingLayout.length; i++)
                _FloatingFeatureView(
                  key: ValueKey<int>(i),
                  data: _kFloatingLayout[i],
                  bgSize: size,
                  iconColor: iconColor,
                  textColor: textColor,
                  frameTick: _frameTick,
                ),
            ],
          );
        },
      ),
    );
  }
}

/// Виджет одной плавающей подписи. ValueListenableBuilder делает rebuild
/// ТОЛЬКО этого внутреннего поддерева (Transform.translate + Row), а
/// собственный RepaintBoundary локализует репейнт в отдельный слой.
class _FloatingFeatureView extends StatelessWidget {
  final _FloatingFeature data;
  final Size bgSize;
  final Color iconColor;
  final Color textColor;
  final ValueNotifier<int> frameTick;
  const _FloatingFeatureView({
    super.key,
    required this.data,
    required this.bgSize,
    required this.iconColor,
    required this.textColor,
    required this.frameTick,
  });

  @override
  Widget build(BuildContext context) {
    final top = data.topFrac * bgSize.height;
    // Поворот фиксированный — считаем один раз снаружи ValueListenableBuilder,
    // чтобы Transform.rotate не пересоздавался каждый кадр.
    final tiltRad = data.tiltDeg * math.pi / 180.0;
    final iconSize = data.fontSize * 1.45;
    return Positioned(
      left: data.onLeft ? data.sideInset : null,
      right: data.onLeft ? null : data.sideInset,
      top: top,
      child: RepaintBoundary(
        child: ValueListenableBuilder<int>(
          valueListenable: frameTick,
          builder: (_, micros, __) {
            final tSec = micros / 1e6;
            // Плавный «дыхательный» drift: разные периоды по X и Y
            // дают круговой Lissajous-овал, а фазы (data.phase, *0.7)
            // разводят соседние подписи, чтобы они не двигались синхронно.
            final periodSec = data.driftPeriodMs / 1000.0;
            final omegaX = 2 * math.pi / periodSec;
            final omegaY = 2 * math.pi / (periodSec + 1.4);
            final dx = math.sin(omegaX * tSec + data.phase) * data.driftAmpX;
            final dy = math.cos(omegaY * tSec + data.phase * 0.7) * data.driftAmpY;
            // Лёгкая пульсация альфы ±0.05 — чтобы подписи «жили»,
            // но не мигали навязчиво.
            final alpha = (data.baseAlpha +
                    math.sin(tSec * 0.55 + data.phase) * 0.05)
                .clamp(0.0, 1.0);
            final ic = iconColor.withValues(alpha: alpha);
            final tc = textColor.withValues(alpha: alpha);
            return Transform.translate(
              offset: Offset(dx, dy),
              child: Transform.rotate(
                angle: tiltRad,
                alignment: Alignment.center,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Iconify(
                      data.feature.iconName,
                      size: iconSize,
                      color: ic,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      data.feature.text,
                      maxLines: 1,
                      softWrap: false,
                      style: TextStyle(
                        color: tc,
                        fontSize: data.fontSize,
                        fontWeight: FontWeight.w500,
                        letterSpacing: 0.1,
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

// =====================================================================
// Стадия 2. Разрешения + кнопка «Начать»
// =====================================================================

class _PermissionsStage extends StatefulWidget {
  final VoidCallback onStart;
  const _PermissionsStage({super.key, required this.onStart});
  @override
  State<_PermissionsStage> createState() => _PermissionsStageState();
}

class _PermissionsStageState extends State<_PermissionsStage> {
  /// Локальные галки. Реальное системное разрешение Android запрашиваем
  /// только когда юзер ВКЛЮЧИЛ свитч (а не сразу при заходе) — это
  /// убирает «лаги» первого захода, когда сразу после готово выскакивал
  /// системный диалог разрешений посреди анимации.
  bool _notif = false;
  bool _photos = false;
  bool _busy = false;

  Future<void> _toggleNotif(bool v) async {
    if (_busy) return;
    setState(() => _busy = true);
    if (v) {
      // Включаем — инициализируем плагин и запрашиваем системное
      // разрешение POST_NOTIFICATIONS. Если юзер откажет — оставляем
      // включёнными в нашем стейте всё равно: при следующей попытке
      // показать уведомление Android просто не покажет, мы это
      // обработаем без падений.
      final granted = await NotificationService.I.requestSystemPermission();
      await NotificationService.I.setEnabled(true);
      if (!granted && mounted) {
        // Сразу даём фидбек, что системно отклонено — но в нашем
        // стейте всё равно ON, чтобы пользователь мог зайти в системные
        // настройки и разрешить вручную.
      }
    } else {
      await NotificationService.I.setEnabled(false);
    }
    if (!mounted) return;
    setState(() {
      _notif = v;
      _busy = false;
    });
  }

  Future<void> _togglePhotos(bool v) async {
    if (_busy) return;
    setState(() => _busy = true);
    if (v) {
      // Запрашиваем системное разрешение на чтение медиа через
      // photo_manager. Если откажут — оставляем переключатель ON
      // в локальном стейте, потому что в любом случае при попытке
      // открыть пикер мы заново запросим разрешение.
      await AppState.I.requestGalleryPermission();
    }
    if (!mounted) return;
    setState(() {
      _photos = v;
      _busy = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 8),
          // Большой success-чек сверху.
          Center(
            child: Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(
                color: AppColors.green.withValues(alpha: 0.14),
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: const Iconify(
                'solar:check-circle-bold',
                size: 56,
                color: AppColors.green,
              ),
            ),
          ),
          const SizedBox(height: 22),
          Text(
            'Ключ принят',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w700,
              letterSpacing: -.4,
              color: pal.text,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Настройте разрешения, которые нужны прямо сейчас. Их можно изменить в любой момент в настройках.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14,
              color: pal.sub,
              height: 1.45,
            ),
          ),
          const SizedBox(height: 28),
          // Группа тумблеров.
          _PermTile(
            icon: 'solar:bell-bold',
            title: 'Уведомления',
            sub: 'Чтобы знать о завершении сборки и загрузки',
            value: _notif,
            onChanged: _toggleNotif,
            isFirst: true,
          ),
          _PermTile(
            icon: 'solar:gallery-add-bold',
            title: 'Доступ к галерее',
            sub: 'Чтобы прикреплять скриншоты к багам',
            value: _photos,
            onChanged: _togglePhotos,
            isLast: true,
          ),
          const Spacer(),
          // Кнопка «Начать».
          PressScale(
            onTap: widget.onStart,
            scale: 0.97,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 16),
              decoration: BoxDecoration(
                color: AppColors.accent,
                borderRadius: BorderRadius.circular(18),
                boxShadow: [
                  BoxShadow(
                    color: AppColors.accent.withValues(alpha: 0.20),
                    blurRadius: 20,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: const [
                  Iconify(
                    'solar:arrow-right-bold',
                    size: 22,
                    color: Colors.white,
                  ),
                  SizedBox(width: 10),
                  Text(
                    'Начать',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 4),
        ],
      ),
    );
  }
}

class _PermTile extends StatelessWidget {
  final String icon;
  final String title;
  final String sub;
  final bool value;
  final Future<void> Function(bool) onChanged;
  final bool isFirst;
  final bool isLast;
  const _PermTile({
    required this.icon,
    required this.title,
    required this.sub,
    required this.value,
    required this.onChanged,
    this.isFirst = false,
    this.isLast = false,
  });

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    final radTop = isFirst ? const Radius.circular(16) : Radius.zero;
    final radBot = isLast ? const Radius.circular(16) : Radius.zero;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => onChanged(!value),
      child: Container(
        decoration: BoxDecoration(
          color: pal.cont,
          borderRadius: BorderRadius.only(
            topLeft: radTop,
            topRight: radTop,
            bottomLeft: radBot,
            bottomRight: radBot,
          ),
          border: isLast
              ? null
              : Border(
                  bottom: BorderSide(color: pal.sep, width: 0.6),
                ),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        child: Row(
          children: [
            SizedBox(
              width: 36,
              height: 36,
              child: Center(
                child: Iconify(icon, size: 28, color: AppColors.accent),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: pal.text,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    sub,
                    style: TextStyle(
                      fontSize: 12.5,
                      color: pal.sub,
                      height: 1.35,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            _PermSwitch(active: value),
          ],
        ),
      ),
    );
  }
}

/// Свитч с зелёным треком (как iOS) — отличается от ThemedSwitch
/// акцентом «системного» вида разрешений.
class _PermSwitch extends StatelessWidget {
  final bool active;
  const _PermSwitch({required this.active});
  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    const trackOn = AppColors.green;
    final trackOff =
        pal.isDark ? const Color(0xFF3A3A3F) : const Color(0xFFD8D8DC);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      width: 46,
      height: 28,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: active ? trackOn : trackOff,
        borderRadius: BorderRadius.circular(99),
      ),
      child: AnimatedAlign(
        alignment:
            active ? Alignment.centerRight : Alignment.centerLeft,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        child: Container(
          width: 22,
          height: 22,
          decoration: const BoxDecoration(
            color: Colors.white,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: Color(0x33000000),
                blurRadius: 4,
                offset: Offset(0, 1),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
