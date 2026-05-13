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
//  Анимированный фон: «призрачные» описания функций летят на зрителя
// =====================================================================
//
// КАК УСТРОЕНО (важно для 60 fps):
//   • Один общий [Ticker] на весь фон. Список частиц меняется ОЧЕНЬ редко
//     (раз в ~800ms спавнится новая, и пара раз в 10s удаляется истёкшая) —
//     только тогда вызывается setState. Кадровые обновления (позиция,
//     scale, alpha) идут через ValueNotifier<int> _frameTick, на который
//     подписан каждый _ParticleView через ValueListenableBuilder —
//     ребилдится только лист дерева одной частицы, не вся стадия.
//   • Каждый _ParticleView обёрнут в собственный RepaintBoundary, поэтому
//     движение одной частицы НЕ заставляет соседние слои перерисовываться.
//   • Передний план (хиро) тоже в RepaintBoundary — он вообще не дёргается.
//   • Альфа применяется через Color.withValues(alpha:) внутри colorFilter
//     SVG-иконки и TextStyle.color текста. Никакого Opacity-виджета
//     (он делает saveLayer на каждый кадр и убивает fps).
//   • Никакой rotation/perspective — только Transform.translate + scale,
//     которые композируются на GPU без растровых slow-path'ов.
//   • Иконки Solar прогреты в svg.cache на старте (см. iconify_precache),
//     первый кадр частицы НЕ парсит SVG-XML.
//
// ТРАЕКТОРИЯ ОДНОЙ ЧАСТИЦЫ (8–12s, t ∈ [0..1]):
//   t = 0     → старт у центра, scale 0.35, alpha 0
//   t ~ 0.18  → alpha достигает peak (0.55–0.85, разное для каждой)
//   t = 0.55  → проходит «зону чтения» (scale ровно 1.0)
//   t ~ 0.82  → alpha начинает спадать
//   t = 1     → улетает к краю экрана (scale 1.8–2.6), alpha 0

class _FeatureParticlesBackground extends StatefulWidget {
  const _FeatureParticlesBackground();

  @override
  State<_FeatureParticlesBackground> createState() =>
      _FeatureParticlesBackgroundState();
}

class _FeatureParticlesBackgroundState
    extends State<_FeatureParticlesBackground>
    with SingleTickerProviderStateMixin {
  /// Максимум одновременно живых частиц. 6 — компромисс между «фон живой»
  /// и «не нагружаем GPU на слабых устройствах».
  static const int _kMaxParticles = 6;

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
    // Pre-spawn пары частиц со сдвигом по времени — чтобы юзер увидел
    // движение мгновенно при открытии экрана, а не пустой фон первые 2с.
    _spawn(initialAgeFrac: 0.10);
    _spawn(initialAgeFrac: 0.34);
    _spawn(initialAgeFrac: 0.58);
  }

  @override
  void dispose() {
    _ticker.dispose();
    _frameTick.dispose();
    super.dispose();
  }

  void _onTick(Duration elapsed) {
    _now = elapsed;
    // Спавним новую частицу каждые ~750–1000ms, если есть место. Лёгкая
    // случайность даёт «живое» дыхание, не строго метроном.
    final spawnGap = 750 + _rnd.nextInt(250);
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

    // Триггерим репейнт всех живых частиц одним сигналом — но НЕ rebuild
    // дерева. _frameTick → ValueListenableBuilder → внутренняя часть
    // ребилдится только в листе RepaintBoundary'а.
    _frameTick.value = elapsed.inMicroseconds;

    // setState нужен ТОЛЬКО когда состав частиц меняется (новая или
    // умершая), потому что Stack рендерит фиксированный список children.
    if (removed && mounted) setState(() {});
  }

  void _spawn({double initialAgeFrac = 0.0}) {
    final feature = _kGhostFeatures[_featureCursor % _kGhostFeatures.length];
    _featureCursor++;
    final durationMs = 8000 + _rnd.nextInt(4000);          // 8–12s
    final angle = _rnd.nextDouble() * 2 * math.pi;          // 0..360°
    final endScale = 1.8 + _rnd.nextDouble() * 0.8;         // 1.8–2.6
    final peakAlpha = 0.55 + _rnd.nextDouble() * 0.30;      // 0.55–0.85
    final fontSize = 14.0 + _rnd.nextDouble() * 2;          // 14–16
    final startMicros =
        _now.inMicroseconds - (durationMs * 1000 * initialAgeFrac).round();
    _particles.add(_Particle(
      id: _idCursor++,
      feature: feature,
      angle: angle,
      durationMs: durationMs,
      endScale: endScale,
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
    // Текст подписи — основной цвет темы (контраст), альфа применяется
    // на каждый кадр через TextStyle.color.withValues(alpha:).
    final textColor = pal.text;

    return RepaintBoundary(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final size = Size(constraints.maxWidth, constraints.maxHeight);
          // Радиус «вылета»: до края экрана + запас, чтобы к t=1 точно
          // ушла за пределы видимой области.
          final exitRadius = math.sqrt(
                size.width * size.width + size.height * size.height,
              ) /
                  2 +
              80;
          // Точка «эмиссии» частиц — примерно центр логотипа. В Column'е
          // хиро лого сидит на ~38% от верха SafeArea (Spacer flex 2/1 +
          // нижний блок кнопки), поэтому смещаем точку эмиссии вверх
          // от геометрического центра экрана.
          final emitY = -size.height * 0.10;
          return Stack(
            alignment: Alignment.center,
            fit: StackFit.expand,
            clipBehavior: Clip.hardEdge,
            children: [
              for (final p in _particles)
                _ParticleView(
                  key: ValueKey<int>(p.id),
                  particle: p,
                  exitRadius: exitRadius,
                  emitDy: emitY,
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

/// Данные одной летящей «фичи». Неизменяемые поля: всё, что нужно для
/// расчёта позиции, scale и alpha в любой момент времени, известно
/// заранее. На каждый кадр мы просто пересчитываем t = (now-start)/dur.
class _Particle {
  final int id;
  final _GhostFeature feature;
  final double angle;
  final int durationMs;
  final double endScale;
  final double peakAlpha;
  final double fontSize;
  final int startedAtMicros;
  const _Particle({
    required this.id,
    required this.feature,
    required this.angle,
    required this.durationMs,
    required this.endScale,
    required this.peakAlpha,
    required this.fontSize,
    required this.startedAtMicros,
  });
  bool deadAt(Duration now) =>
      (now.inMicroseconds - startedAtMicros) >= durationMs * 1000;
}

/// Виджет одной частицы. ValueListenableBuilder делает rebuild ТОЛЬКО
/// этого внутреннего поддерева (Transform + Row(Iconify, Text)), а
/// собственный RepaintBoundary локализует репейнт в отдельный слой.
class _ParticleView extends StatelessWidget {
  final _Particle particle;
  final double exitRadius;
  /// Вертикальный сдвиг точки эмиссии от центра Stack'а. Отрицательное
  /// значение поднимает точку рождения частиц вверх (к логотипу).
  final double emitDy;
  final Color iconColor;
  final Color textColor;
  final ValueNotifier<int> frameTick;
  const _ParticleView({
    super.key,
    required this.particle,
    required this.exitRadius,
    required this.emitDy,
    required this.iconColor,
    required this.textColor,
    required this.frameTick,
  });

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: ValueListenableBuilder<int>(
        valueListenable: frameTick,
        builder: (_, nowMicros, __) {
          final dt = (nowMicros - particle.startedAtMicros) /
              (particle.durationMs * 1000.0);
          if (dt <= 0.0 || dt >= 1.0) return const SizedBox.shrink();
          final t = dt;

          // Радиальная позиция: квадратичный easing — у логотипа медленно,
          // к краю экрана разгоняется (эффект «летят на тебя»).
          final eased = t * t;
          final r = eased * exitRadius;
          final dx = math.cos(particle.angle) * r;
          final dy = math.sin(particle.angle) * r;

          // Масштаб: 0.35 в начале → 1.0 ровно при t=0.55 (зона чтения) →
          // endScale в конце.
          double scale;
          if (t <= 0.55) {
            scale = 0.35 + (1.0 - 0.35) * (t / 0.55);
          } else {
            scale = 1.0 + (particle.endScale - 1.0) * ((t - 0.55) / 0.45);
          }

          // Альфа: 0 → peak (t=0.18) → удерживаем → 0 (t=1).
          double alpha;
          if (t < 0.18) {
            alpha = particle.peakAlpha * (t / 0.18);
          } else if (t < 0.82) {
            alpha = particle.peakAlpha;
          } else {
            alpha = particle.peakAlpha * (1.0 - (t - 0.82) / 0.18);
          }
          if (alpha <= 0.0) return const SizedBox.shrink();

          // Цвета с пред-применённой альфой — НИКАКОГО Opacity-виджета
          // (он делает saveLayer и убивает fps). colorFilter Iconify и
          // TextStyle.color поддерживают альфа-канал нативно.
          final ic = iconColor.withValues(alpha: alpha);
          final tc = textColor.withValues(alpha: alpha);
          final iconSize = particle.fontSize * 1.45;

          // Stack alignment=center → этот child лежит layout-центром
          // в центре фона. Сначала поднимаем точку эмиссии к логотипу
          // (emitDy), потом радиально смещаем на (dx, dy). Transform.scale
          // с alignment center (по умолчанию) скейлит вокруг центра Row'а.
          return Transform.translate(
            offset: Offset(dx, dy + emitDy),
            child: Transform.scale(
              scale: scale,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Iconify(
                    particle.feature.iconName,
                    size: iconSize,
                    color: ic,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    particle.feature.text,
                    maxLines: 1,
                    softWrap: false,
                    style: TextStyle(
                      color: tc,
                      fontSize: particle.fontSize,
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
