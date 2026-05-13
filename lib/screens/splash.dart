import 'dart:math' as math;

import 'package:flutter/foundation.dart';
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
///   1) [_OnboardingStage] — хиро: лого GitHub строго по центру, под ним
///      заголовок «GitHub Pusher» и подпись «всё, что нужно — на одном
///      экране», sticky-кнопка «Вставить ключ» внизу. На фоне — «призрачные»
///      подписи функций (иконка + текст), которые ВЫЛЕТАЮТ ИЗ ЛОГО,
///      плавно отлетают наружу и растворяются по краю экрана. Внутрь
///      самого лого подписи не заходят. По тапу в любое место экрана
///      частицы кратко (~1.5 с) ускоряются (см. [_FeatureParticlesBackground]).
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
// Стадия 1. Онбординг (статичный хиро + частицы, вылетающие из лого)
// =====================================================================

class _OnboardingStage extends StatefulWidget {
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
  State<_OnboardingStage> createState() => _OnboardingStageState();
}

class _OnboardingStageState extends State<_OnboardingStage> {
  /// Сигнал «тапни — ускорь частицы». Каждый pointerDown по любой части
  /// экрана инкрементирует это значение; [_FeatureParticlesBackground]
  /// подписан и поднимает локальную скорость анимации на ~1.5 секунды.
  final ValueNotifier<int> _boostTick = ValueNotifier<int>(0);

  @override
  void dispose() {
    _boostTick.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    // Listener с translucent-поведением ловит все тапы в bounds, НО НЕ
    // блокирует их — нижележащие GestureDetector'ы (кнопка «Вставить ключ»,
    // ссылка «Получить токен», тогл темы) продолжают получать события.
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => _boostTick.value = _boostTick.value + 1,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fill(
            child: _FeatureParticlesBackground(boostTick: _boostTick),
          ),
          Positioned.fill(
            child: RepaintBoundary(
              child: _OnboardingHero(
                loading: widget.loading,
                error: widget.error,
                onPaste: widget.onPaste,
                pal: pal,
              ),
            ),
          ),
        ],
      ),
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
        // Группа «лого + заголовок + подзаголовок» строго по центру
        // свободной области (равные Spacer'ы сверху и снизу до CTA).
        const Spacer(),
        // Лого GitHub. На светлой теме — акцентный фиолетовый,
        // на тёмной — белый (как и было).
        Iconify(
          'mdi:github',
          size: _kLogoSize,
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
        const Spacer(),
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
//  Анимированный фон: «призрачные» подписи вылетают из лого и тают
// =====================================================================
//
// КАК УСТРОЕНО:
//   • Подписи (иконка + текст из [_kFeaturePool]) спавнятся не в каком-то
//     фиксированном месте, а ровно на радиусе [_kLogoRadius] от центра
//     экрана — это «ободок» вокруг логотипа. Внутрь лого они НЕ
//     заходят никогда.
//   • Каждая частица за время своей жизни (~6.5–8 с) плавно отлетает
//     от лого до максимального радиуса [_radius] (≈ 62% min(W,H)),
//     ускоряясь по [_easeOutCubic] (бойкий старт, мягкое замедление).
//   • Альфа имеет огибающую 0→peak→0: появилась у края лого, доросла
//     до 0.55, доплыла до края и плавно растворилась. Никаких
//     Opacity-виджетов — альфа применяется напрямую к Color.withValues.
//   • Углы вылета распределены по 360°, но с лёгким уклоном к
//     горизонтали (0° / 180°), чтобы подписи реже залетали прямо
//     поверх заголовка «GitHub Pusher» под лого.
//   • Когда life >= 1, частица «перерождается» с новым углом, новой
//     иконкой+текстом из пула и новым lifetime. Размер пула сильно
//     больше количества частиц, так что подписи на экране почти не
//     повторяются одновременно.
//   • Один общий [Ticker] на весь фон. Каждый кадр продвигает
//     локальное время [_localMs] на dt × speed (мс). [_speed] плавно
//     стремится к [_speedTarget] через экспоненциальное сглаживание.
//   • При тапе по экрану [_OnboardingStageState] инкрементит [boostTick],
//     мы выставляем speedTarget=2.4 на 1.5 с — частицы кратко ускоряются
//     и плавно возвращаются к обычной скорости.
//   • Все ребилды локализованы: один RepaintBoundary на весь фон, и
//     по одному на каждый [_ParticleView]. ValueListenableBuilder на
//     _frameTick ребилдит только листья — setState за весь lifecycle
//     не вызывается.

/// Логотип GitHub на экране входа. Размер вынесен в константу, чтобы
/// частицы могли посчитать «радиус лого» и не залетать внутрь.
const double _kLogoSize = 156;
/// Радиус спавна частиц: чуть больше радиуса лого, чтобы текст рядом
/// с иконкой тоже не наезжал на silhouette лого.
const double _kLogoRadius = _kLogoSize / 2 + 14;

/// Описание одной подписи фичи (иконка + короткий текст).
class _GhostFeature {
  final String iconName;
  final String text;
  const _GhostFeature(this.iconName, this.text);
}

/// Пул подписей, из которого случайно достаём при каждом «рождении»
/// частицы. Чем больше пул относительно [_kPopulation], тем реже на
/// экране одновременно встречаются дубликаты.
const List<_GhostFeature> _kFeaturePool = [
  _GhostFeature('solar:gallery-add-bold', 'Скриншоты к багам'),
  _GhostFeature('solar:cloud-upload-bold', 'Заливай файлы'),
  _GhostFeature('solar:download-square-bold', 'Скачивай APK'),
  _GhostFeature('solar:folder-with-files-bold', 'Все репозитории'),
  _GhostFeature('solar:branching-paths-up-bold', 'Ветки и коммиты'),
  _GhostFeature('solar:eye-bold', 'Следи за статусом'),
  _GhostFeature('solar:rocket-bold', 'Запускай Actions'),
  _GhostFeature('solar:bell-bold', 'Уведомления'),
  _GhostFeature('solar:star-bold', 'Избранные репо'),
  _GhostFeature('solar:check-circle-bold', 'Сборка готова'),
];

/// Сколько частиц одновременно живёт на экране.
const int _kPopulation = 10;
/// Средний lifetime частицы (около этого ± [_kLifetimeJitterMs]).
const int _kLifetimeAvgMs = 7200;
const int _kLifetimeJitterMs = 1400;

/// Параметры одной живой частицы. Поля мутабельные — при «перерождении»
/// мы переиспользуем тот же объект (и тот же [_ParticleView] в дереве),
/// чтобы не дёргать createElement/inflateWidget на каждый цикл.
class _Particle {
  /// Локальное время рождения (мс). Возраст частицы = _localMs - birthMs.
  double birthMs;
  /// Полное время жизни (мс).
  double lifetimeMs;
  /// Угол вылета (радианы, от центра экрана).
  double angle;
  /// Индекс в [_kFeaturePool] — какую подпись показывать.
  int poolIdx;
  /// Размер шрифта (px) — небольшая вариация на ±1.5 даёт ощущение
  /// глубины (более крупные подписи кажутся ближе).
  double fontSize;
  _Particle({
    required this.birthMs,
    required this.lifetimeMs,
    required this.angle,
    required this.poolIdx,
    required this.fontSize,
  });
}

double _easeOutCubic(double x) {
  final t = 1 - x;
  return 1 - t * t * t;
}

/// Огибающая яркости: 0 → peak за первые 12%, плато до 70%, плавное
/// растворение к концу жизни. peak задаём один раз.
double _alphaEnvelope(double life, double peak) {
  if (life < 0.12) return peak * (life / 0.12);
  if (life < 0.70) return peak;
  final k = (life - 0.70) / 0.30;
  return peak * (1 - k);
}

class _FeatureParticlesBackground extends StatefulWidget {
  final ValueListenable<int> boostTick;
  const _FeatureParticlesBackground({required this.boostTick});

  @override
  State<_FeatureParticlesBackground> createState() =>
      _FeatureParticlesBackgroundState();
}

class _FeatureParticlesBackgroundState
    extends State<_FeatureParticlesBackground>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;

  /// «Тик кадра» в микросекундах _localMs. Каждый _ParticleView слушает
  /// его через ValueListenableBuilder — ребилдятся только листья.
  final ValueNotifier<int> _frameTick = ValueNotifier<int>(0);

  /// Внутренние часы анимации (мс). Идут как dt × _speed, поэтому при
  /// boost'е сами «ускоряются» — все формулы за пределами здесь о speed
  /// ничего знать не должны.
  double _localMs = 0;
  Duration _lastElapsed = Duration.zero;

  /// Сглаженный множитель скорости. После тапа поднимаем target до 2.4
  /// на 1500 мс, потом он сам уезжает обратно к 1.0 (экспоненциальное
  /// сглаживание с k = 1 - exp(-dt * 3.5)).
  double _speed = 1.0;
  double _speedTarget = 1.0;
  int _boostUntilMs = 0;

  late final List<_Particle> _particles;
  final math.Random _rng = math.Random();

  @override
  void initState() {
    super.initState();
    // Распределяем рождения по фазам, чтобы при первом кадре частицы
    // были на разных стадиях жизни — без визуального «залпа».
    _particles = List.generate(_kPopulation, (i) {
      final lifetime = _kLifetimeAvgMs +
          (_rng.nextDouble() - 0.5) * 2 * _kLifetimeJitterMs;
      final stagger = -lifetime * (i / _kPopulation);
      return _Particle(
        birthMs: stagger,
        lifetimeMs: lifetime,
        angle: _randomAngle(),
        poolIdx: _rng.nextInt(_kFeaturePool.length),
        fontSize: 14.0 + (_rng.nextDouble() - 0.5) * 2.6,
      );
    });

    widget.boostTick.addListener(_onBoost);

    _ticker = createTicker((elapsed) {
      final delta = elapsed - _lastElapsed;
      _lastElapsed = elapsed;
      final dtSec = delta.inMicroseconds / 1e6;
      // Никогда не двигаемся отрицательно/слишком сильно (защита от
      // первого кадра, где elapsed может скакнуть).
      final dt = dtSec.clamp(0.0, 0.05);

      // Плавный возврат скорости.
      final nowEpochMs = DateTime.now().millisecondsSinceEpoch;
      if (nowEpochMs > _boostUntilMs) _speedTarget = 1.0;
      final k = 1 - math.exp(-dt * 3.5);
      _speed += (_speedTarget - _speed) * k;

      _localMs += dt * 1000 * _speed;

      // Перерождения. Делаем именно тут, чтобы _ParticleView не дёргал
      // нашу скорость и пул — он только читает уже актуальные поля.
      for (final p in _particles) {
        final age = _localMs - p.birthMs;
        if (age >= p.lifetimeMs) {
          p.birthMs = _localMs - 1;
          p.lifetimeMs = _kLifetimeAvgMs +
              (_rng.nextDouble() - 0.5) * 2 * _kLifetimeJitterMs;
          p.angle = _randomAngle();
          p.poolIdx = _rng.nextInt(_kFeaturePool.length);
          p.fontSize = 14.0 + (_rng.nextDouble() - 0.5) * 2.6;
        }
      }

      // Поднимаем тик — слушатели перерисуют именно свои поддеревья.
      _frameTick.value = elapsed.inMicroseconds;
    })..start();
  }

  void _onBoost() {
    _speedTarget = 2.4;
    _boostUntilMs = DateTime.now().millisecondsSinceEpoch + 1500;
  }

  /// Случайный угол с лёгким уклоном к горизонтали: чтобы подписи реже
  /// проходили строго над/под лого, мы смешиваем raw-угол с ближайшей
  /// горизонталью (0° или 180°) в пропорции 70/30.
  double _randomAngle() {
    final raw = _rng.nextDouble() * 2 * math.pi;
    final target = math.cos(raw) >= 0 ? 0.0 : math.pi;
    return raw * 0.7 + target * 0.3;
  }

  @override
  void dispose() {
    widget.boostTick.removeListener(_onBoost);
    _ticker.dispose();
    _frameTick.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    final iconColor = AppColors.accent;
    final textColor = pal.text;

    return RepaintBoundary(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final size = Size(constraints.maxWidth, constraints.maxHeight);
          final cx = size.width / 2;
          final cy = size.height / 2;
          final maxR = math.min(size.width, size.height) * 0.62;
          return Stack(
            clipBehavior: Clip.hardEdge,
            children: [
              for (int i = 0; i < _particles.length; i++)
                _ParticleView(
                  key: ValueKey<int>(i),
                  particle: _particles[i],
                  centerX: cx,
                  centerY: cy,
                  logoR: _kLogoRadius,
                  maxR: maxR,
                  iconColor: iconColor,
                  textColor: textColor,
                  frameTick: _frameTick,
                  getLocalMs: _getLocalMs,
                ),
            ],
          );
        },
      ),
    );
  }

  double _getLocalMs() => _localMs;
}

/// Одна частица. ValueListenableBuilder делает rebuild ТОЛЬКО этого
/// поддерева, RepaintBoundary локализует репейнт в отдельный слой.
class _ParticleView extends StatelessWidget {
  final _Particle particle;
  final double centerX;
  final double centerY;
  final double logoR;
  final double maxR;
  final Color iconColor;
  final Color textColor;
  final ValueListenable<int> frameTick;
  final double Function() getLocalMs;
  const _ParticleView({
    super.key,
    required this.particle,
    required this.centerX,
    required this.centerY,
    required this.logoR,
    required this.maxR,
    required this.iconColor,
    required this.textColor,
    required this.frameTick,
    required this.getLocalMs,
  });

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: ValueListenableBuilder<int>(
        valueListenable: frameTick,
        builder: (_, __, ___) {
          final t = getLocalMs();
          final age = t - particle.birthMs;
          final life = age / particle.lifetimeMs;
          if (life <= 0 || life >= 1) {
            return const SizedBox.shrink();
          }

          final cosA = math.cos(particle.angle);
          final sinA = math.sin(particle.angle);
          final dist = logoR + _easeOutCubic(life) * (maxR - logoR);
          final dx = centerX + cosA * dist;
          final dy = centerY + sinA * dist;

          const peak = 0.55;
          final alpha = _alphaEnvelope(life, peak).clamp(0.0, 1.0);
          final ic = iconColor.withValues(alpha: alpha);
          final tc = textColor.withValues(alpha: alpha);

          final feat = _kFeaturePool[particle.poolIdx];
          final iconSize = particle.fontSize * 1.4;

          // Позиционируем по center-якорю частицы. Переводим через
          // FractionalTranslation(-0.5,-0.5) после позиции — так центр
          // Row'а оказывается ровно в (dx, dy).
          return Positioned(
            left: dx,
            top: dy,
            child: FractionalTranslation(
              translation: const Offset(-0.5, -0.5),
              child: IgnorePointer(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Iconify(
                      feat.iconName,
                      size: iconSize,
                      color: ic,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      feat.text,
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
