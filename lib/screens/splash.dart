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
///      «Вставить ключ» внизу. На фоне — «призрачные» описания функций
///      с Solar-иконками, которые радиально «летят на зрителя» из-за
///      логотипа и растворяются у краёв экрана (см. [_FeatureParticlesBackground]).
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
    // ВАЖНО: убрали AnimatedContainer вокруг body. Раньше при смене темы
    // фон мягко перетекал 300мс, а ВСЁ остальное (текст/иконки/частицы)
    // переключалось мгновенно — это и воспринималось как «лаг темы».
    // Теперь все слои меняют цвет одновременно — переключение мгновенное
    // и чистое.
    return Scaffold(
      backgroundColor: pal.bg,
      body: SafeArea(
        child: Stack(
          children: [
            // Основной контент стадии (онбординг / разрешения).
            Positioned.fill(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 320),
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
            if (_stage == 0)
              Positioned(
                top: 8,
                right: 12,
                child: _ThemeToggleButton(),
              ),
          ],
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

/// Описание одной «призрачной» фичи, которая летит на фоне:
/// иконка из набора Solar + короткая подпись.
class _GhostFeature {
  final String iconName;
  final String text;
  const _GhostFeature(this.iconName, this.text);
}

/// Пул описаний функций, которые «пролетают» через фон. Порядок
/// и состав согласованы по прототипу.
const List<_GhostFeature> _kGhostFeatures = [
  _GhostFeature('solar:cloud-upload-bold',       'Заливай файлы'),
  _GhostFeature('solar:rocket-bold',             'Запускай Actions'),
  _GhostFeature('solar:download-square-bold',    'Скачивай APK'),
  _GhostFeature('solar:lock-keyhole-bold',       'Только на устройстве'),
  _GhostFeature('solar:bell-bold',               'Уведомления о сборках'),
  _GhostFeature('solar:code-square-bold',        'Просмотр кода'),
  _GhostFeature('solar:bug-bold',                'Баг-трекер'),
  _GhostFeature('solar:branching-paths-up-bold', 'Ветки и коммиты'),
  _GhostFeature('solar:folder-with-files-bold',  'Все репозитории'),
  _GhostFeature('solar:refresh-bold',            'Перезапуск Actions'),
  _GhostFeature('solar:gallery-add-bold',        'Скриншоты к багам'),
  _GhostFeature('solar:star-bold',               'Избранные репо'),
  _GhostFeature('solar:eye-bold',                'Следи за статусом'),
  _GhostFeature('solar:document-add-bold',       'Новый файл'),
  _GhostFeature('solar:clipboard-add-bold',      'Вставь токен'),
  _GhostFeature('solar:bolt-bold',               'Мгновенный пуш'),
  _GhostFeature('solar:check-circle-bold',       'Сборка готова'),
  _GhostFeature('solar:hand-stars-bold',         'Минимум кликов'),
  _GhostFeature('solar:server-bold',             'Actions онлайн'),
  _GhostFeature('solar:flag-bold',               'Релизы'),
];

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
        // 1:1 — группа «лого+текст» строго посередине между верхом
        // и нижним блоком кнопки. Раньше было 2:1 и группа уезжала вверх.
        const Spacer(flex: 1),
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
//  Анимированный фон: чипы-описания фич, плавающие ВОКРУГ логотипа
// =====================================================================
//
// КАК УСТРОЕНО (важно для 60 fps и «без лагов»):
//   • Один общий [Ticker] на весь фон. Список частиц меняется редко
//     (новая раз в ~1.4с), поэтому setState вызывается только в момент
//     спавна/смерти. Кадровые обновления (translate + opacity) идут
//     через ValueNotifier<int> _frameTick → ValueListenableBuilder в
//     каждом _ParticleView, поэтому ребилд локализован в листе.
//   • Каждый _ParticleView обёрнут в RepaintBoundary — движение одной
//     частицы НЕ заставляет соседние слои перерисовываться.
//   • Цвета иконки/текста ФИКСИРОВАНЫ (не пересчитываются на кадр) —
//     прозрачность через виджет Opacity, чтобы не убивать SVG raster
//     cache на каждом кадре. Для 6 частиц saveLayer практически бесплатен,
//     а вот пересоздание ColorFilter каждый кадр заметно дёргалось.
//   • Никакого rotation/perspective/blur — только Transform.translate
//     + Opacity, всё композируется на GPU.
//
// ТРАЕКТОРИЯ ОДНОЙ ЧАСТИЦЫ (8–10s, t ∈ [0..1]):
//   • Спавнится НА КОЛЬЦЕ радиусом ~110px от центра лого (логотип 156px,
//     радиус 78 — между лого и частицей всегда ~30px воздуха, частицы
//     никогда не заходят на лого).
//   • Линейно по радиусу уплывает к радиусу 240–290px и растворяется.
//   • Размер ПОЧТИ НЕ МЕНЯЕТСЯ: 0.96 → 1.04 (никаких «появлений из точки»).
//   • Альфа: 0 → peak (за первые 22% времени) → держится → 0 (за последние 28%).

class _FeatureParticlesBackground extends StatefulWidget {
  const _FeatureParticlesBackground();

  @override
  State<_FeatureParticlesBackground> createState() =>
      _FeatureParticlesBackgroundState();
}

class _FeatureParticlesBackgroundState
    extends State<_FeatureParticlesBackground>
    with SingleTickerProviderStateMixin {
  /// Максимум одновременно живых частиц. Больше — плотнее «облако» и
  /// меньше «дыр» по таймингу; меньше — спокойнее. 7 = баланс.
  static const int _kMaxParticles = 7;

  /// Внутренний радиус «эмиссии» — частицы рождаются на этой окружности
  /// вокруг центра лого. 110 > половина лого (78) + воздух 30. Это
  /// гарантия, что НИЧЕГО никогда не появляется на самом логотипе.
  static const double _kInnerRadius = 110.0;

  /// Геометрический сдвиг центра лого относительно центра Stack'а.
  /// Хиро в Column'е: Spacer(1) — Лого+Текст(~225) — Spacer(1) —
  /// нижний блок(~200). При таком раскладе центр лого оказывается
  /// примерно на 110px ВЫШЕ центра экрана (см. вывод формулы в
  /// комментарии ниже). Используем как константу — для всех
  /// разумных высот экрана это значение почти не плывёт.
  ///
  ///   freeH = H − heroBlock(225) − bottomBlock(200) = H − 425
  ///   topSpacer = freeH/2 = (H − 425)/2
  ///   logoCenterY = topSpacer + 78 = (H − 425)/2 + 78
  ///   stackCenterY = H/2
  ///   emitDy = logoCenterY − stackCenterY = (78 − 425/2) ≈ −134.5
  static const double _kEmitDy = -134.5;

  late final Ticker _ticker;
  Duration _now = Duration.zero;
  Duration _lastSpawn = Duration.zero;
  final math.Random _rnd = math.Random();
  final List<_Particle> _particles = [];
  int _featureCursor = 0;
  int _idCursor = 0;

  /// «Тик кадра» в микросекундах. Каждый _ParticleView слушает его через
  /// ValueListenableBuilder — ребилдятся только листья (одна частица),
  /// а не вся стадия.
  final ValueNotifier<int> _frameTick = ValueNotifier<int>(0);

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick)..start();
    // Pre-spawn — чтобы юзер увидел движение мгновенно при открытии,
    // равномерно разнесено по фазам.
    _spawn(initialAgeFrac: 0.05);
    _spawn(initialAgeFrac: 0.22);
    _spawn(initialAgeFrac: 0.40);
    _spawn(initialAgeFrac: 0.58);
    _spawn(initialAgeFrac: 0.76);
  }

  @override
  void dispose() {
    _ticker.dispose();
    _frameTick.dispose();
    super.dispose();
  }

  void _onTick(Duration elapsed) {
    _now = elapsed;
    // Спавним новую частицу каждые ~1300–1600мс — равномерно, не пачкой.
    final spawnGap = 1300 + _rnd.nextInt(300);
    final due = (elapsed - _lastSpawn).inMilliseconds >= spawnGap;
    if (due && _particles.length < _kMaxParticles) {
      _spawn();
      _lastSpawn = elapsed;
    }

    bool removed = false;
    for (int i = _particles.length - 1; i >= 0; i--) {
      if (_particles[i].deadAt(_now)) {
        _particles.removeAt(i);
        removed = true;
      }
    }

    _frameTick.value = elapsed.inMicroseconds;

    if (removed && mounted) setState(() {});
  }

  void _spawn({double initialAgeFrac = 0.0}) {
    final feature = _kGhostFeatures[_featureCursor % _kGhostFeatures.length];
    _featureCursor++;
    final durationMs = 8000 + _rnd.nextInt(2000);          // 8–10s
    final angle = _rnd.nextDouble() * 2 * math.pi;          // 0..360°
    final endRadius = 240.0 + _rnd.nextDouble() * 50.0;     // 240–290
    final peakAlpha = 0.55 + _rnd.nextDouble() * 0.25;      // 0.55–0.80
    final fontSize = 14.0 + _rnd.nextDouble() * 1.5;        // 14–15.5
    final startMicros =
        _now.inMicroseconds - (durationMs * 1000 * initialAgeFrac).round();
    _particles.add(_Particle(
      id: _idCursor++,
      feature: feature,
      angle: angle,
      durationMs: durationMs,
      endRadius: endRadius,
      peakAlpha: peakAlpha,
      fontSize: fontSize,
      startedAtMicros: startMicros,
    ));
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    final iconColor = AppColors.accent;
    final textColor = pal.text;

    return RepaintBoundary(
      child: Stack(
        alignment: Alignment.center,
        fit: StackFit.expand,
        clipBehavior: Clip.hardEdge,
        children: [
          for (final p in _particles)
            _ParticleView(
              key: ValueKey<int>(p.id),
              particle: p,
              innerRadius: _kInnerRadius,
              emitDy: _kEmitDy,
              iconColor: iconColor,
              textColor: textColor,
              frameTick: _frameTick,
            ),
        ],
      ),
    );
  }
}

class _Particle {
  final int id;
  final _GhostFeature feature;
  final double angle;
  final int durationMs;
  final double endRadius;
  final double peakAlpha;
  final double fontSize;
  final int startedAtMicros;
  const _Particle({
    required this.id,
    required this.feature,
    required this.angle,
    required this.durationMs,
    required this.endRadius,
    required this.peakAlpha,
    required this.fontSize,
    required this.startedAtMicros,
  });
  bool deadAt(Duration now) =>
      (now.inMicroseconds - startedAtMicros) >= durationMs * 1000;
}

class _ParticleView extends StatelessWidget {
  final _Particle particle;
  final double innerRadius;
  final double emitDy;
  final Color iconColor;
  final Color textColor;
  final ValueNotifier<int> frameTick;
  const _ParticleView({
    super.key,
    required this.particle,
    required this.innerRadius,
    required this.emitDy,
    required this.iconColor,
    required this.textColor,
    required this.frameTick,
  });

  @override
  Widget build(BuildContext context) {
    // Чип строится ОДИН РАЗ с фиксированными цветами. На кадровом
    // ребилде меняются только Transform.translate и Opacity — это
    // даёт идеальную плавность: SVG-raster cache не инвалидируется.
    final iconSize = particle.fontSize * 1.45;
    final chip = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Iconify(
          particle.feature.iconName,
          size: iconSize,
          color: iconColor,
        ),
        const SizedBox(width: 8),
        Text(
          particle.feature.text,
          maxLines: 1,
          softWrap: false,
          style: TextStyle(
            color: textColor,
            fontSize: particle.fontSize,
            fontWeight: FontWeight.w500,
            letterSpacing: 0.1,
          ),
        ),
      ],
    );

    return RepaintBoundary(
      child: ValueListenableBuilder<int>(
        valueListenable: frameTick,
        child: chip,
        builder: (_, nowMicros, builtChip) {
          final t = (nowMicros - particle.startedAtMicros) /
              (particle.durationMs * 1000.0);
          if (t <= 0.0 || t >= 1.0) return const SizedBox.shrink();

          // Радиус: linear от innerRadius до endRadius. Без квадратичного
          // easing — хочется РОВНОЕ движение, а не «разгон к краю».
          final r = innerRadius + (particle.endRadius - innerRadius) * t;
          final dx = math.cos(particle.angle) * r;
          final dy = math.sin(particle.angle) * r;

          // Размер ПРАКТИЧЕСКИ постоянен: 0.96 → 1.04. Никакого
          // «появления из точки» — частица сразу почти финального размера.
          final scale = 0.96 + 0.08 * t;

          // Альфа: 0 → peak за первые 22% → держим → 0 за последние 28%.
          double alpha;
          if (t < 0.22) {
            alpha = particle.peakAlpha * (t / 0.22);
          } else if (t < 0.72) {
            alpha = particle.peakAlpha;
          } else {
            alpha = particle.peakAlpha * (1.0 - (t - 0.72) / 0.28);
          }
          if (alpha <= 0.0) return const SizedBox.shrink();

          return Transform.translate(
            offset: Offset(dx, dy + emitDy),
            child: Opacity(
              opacity: alpha,
              child: Transform.scale(
                scale: scale,
                child: builtChip,
              ),
            ),
          );
        },
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
          // Раньше между плитками была серая полоса (BorderSide pal.sep).
          // Убрана по запросу — плитки теперь визуально слитные.
        
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
