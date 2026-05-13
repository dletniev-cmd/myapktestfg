import 'package:flutter/material.dart';
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
///   1) [_OnboardingStage] — свайп-онбординг из пяти страниц (логотип
///      GitHub + четыре описания фич) с точками-индикаторами внизу и
///      sticky-кнопкой «Вставить ключ».
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
// Стадия 1. Онбординг (свайп-страницы + sticky-кнопка)
// =====================================================================

/// Описание одной онбординг-страницы. Иконка — всегда Iconify SVG из
/// набора Solar/MDI (assets/icons/*.svg). Lottie-стикеры удалены —
/// они давали лаги при свайпе PageView (декод JSON, paint heavy paths)
/// и визуально были «дёрганые».
///
/// `iconSize` — это РАЗМЕР САМОЙ ИКОНКИ внутри фиксированного бокса
/// `_kIconBoxSize`. Внешний бокс одинаковый для всех страниц, чтобы
/// при смене страницы текст НЕ прыгал по вертикали (раньше лого
/// был 138, остальные 130 — при свайпе на стр.2 текст подскакивал на
/// 8px вверх, когда иконочная зона ужималась под маленькую иконку).
class _OnbPage {
  final String iconName;
  final double iconSize;
  final String title;
  final String sub;
  const _OnbPage({
    required this.iconName,
    required this.title,
    required this.sub,
    this.iconSize = 130,
  });
}

/// Внешний бокс иконочной зоны. Должен быть >= max(iconSize) всех
/// страниц, иначе бокс будет схлопываться под текущую иконку и
/// контент ниже будет прыгать.
const double _kIconBoxSize = 160;

const List<_OnbPage> _onbPages = [
  _OnbPage(
    iconName: 'mdi:github',
    iconSize: 156, // лого крупнее остальных (фактический размер ~140 из-за внутренних полей SVG)
    title: 'GitHub Pusher',
    sub: 'Свайпни, чтобы узнать что умеет приложение.',
  ),
  _OnbPage(
    iconName: 'solar:cloud-upload-bold',
    title: 'Заливай файлы',
    sub:
        'Прямо с телефона отправляй файлы в любой свой репозиторий — без коммитов вручную.',
  ),
  _OnbPage(
    iconName: 'solar:rocket-bold',
    title: 'Запускай Actions',
    sub:
        'Следи за статусом сборок и перезапускай их одним тапом прямо из приложения.',
  ),
  _OnbPage(
    iconName: 'solar:download-square-bold',
    title: 'Скачивай APK',
    sub:
        'Артефакты сборки доступны сразу — устанавливай новый билд без перехода в браузер.',
  ),
  _OnbPage(
    iconName: 'solar:lock-keyhole-bold',
    title: 'Только на устройстве',
    sub:
        'Токен хранится локально и не отправляется на сторонние серверы. Полный контроль остаётся у вас.',
  ),
];

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
  late final PageController _pc = PageController();

  // Это ключевое для Telegram-style поведения: settledIndex обновляется
  // ТОЛЬКО в `PageView.onPageChanged`, т.е. ПОСЛЕ того как юзер отпустил
  // палец и PageView докатился до целой страницы. Иконочный
  // AnimatedSwitcher биндится именно на этот индекс, поэтому пока
  // тянешь пальцем — иконка не меняется, только после отпускания.
  int _settledIndex = 0;

  void _onPageChanged(int i) {
    if (i == _settledIndex) return;
    setState(() => _settledIndex = i);
  }

  @override
  void dispose() {
    _pc.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    // Layout:
    //   • flex 2 сверху, flex 1 снизу — верхний воздух в 2 раза больше
    //     нижнего, так группа «иконка + текст» оказывается ровно по
    //     середине экрана (раньше она была заметно выше центра, потому
    //     что нижний фикс-блок съедал ~155px и спейсеры flex 1/1 делили
    //     остаток в нижней половине экрана пополам).
    //   • Нижний блок прижат к bottom (padding 4 снизу), gap'ы между
    //     кнопкой/линком/подсказкой уменьшены — это «опускает» кнопку
    //     ниже по экрану, как и просил пользователь.
    return Column(
      children: [
        // ============== ВЕРХНИЙ ВОЗДУХ ==============
        const Spacer(flex: 2),
        // ============== ИКОНОЧНАЯ ЗОНА (фиксирована, НЕ свайпается) ==============
        // Иконка биндится на `_settledIndex`, который обновляется ТОЛЬКО
        // в `PageView.onPageChanged` (т.е. после того как палец отпущен
        // и PageView докатился до целой страницы). Пока юзер тянет
        // пальцем — иконка стоит на месте. Когда страница защёлкивается —
        // AnimatedSwitcher плавно меняет иконку на новую.
        //
        // КРИТИЧНО: внешний SizedBox с фиксированным `_kIconBoxSize` —
        // защита от «прыжка» текста при свайпе. У иконок разный
        // визуальный размер (156 у лого, 130 у остальных), и если
        // не закрепить outer-бокс, AnimatedSwitcher через Stack
        // ужимался под текущую иконку, а текст ниже подскакивал на
        // 8-26px. С фикс-боксом outer-размер всегда 160, иконки внутри
        // центрируются — ничего не прыгает.
        SizedBox(
          width: _kIconBoxSize,
          height: _kIconBoxSize,
          child: RepaintBoundary(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 420),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              // Анимация смены иконки — Rotate Spin: иконка поворачивается
              // на 180° с одновременным уменьшением до 0.6 и fade. Старая
              // «улетает» с поворотом и уменьшением, новая «прилетает»
              // с противоположного угла, восстанавливая нормальный
              // размер и ориентацию. Заметно, но не утомляет — похоже
              // на смену темы (юзер выбрал вариант №4 из HTML-превью).
              //
              // Анимация включается ТОЛЬКО при смене _settledIndex
              // (т.е. ПОСЛЕ отпускания пальца и защёлкивания страницы) —
              // пока юзер тянет, ничего не моргает.
              transitionBuilder: (child, anim) {
                final curved = CurvedAnimation(
                  parent: anim,
                  curve: Curves.easeOutCubic,
                  reverseCurve: Curves.easeInCubic,
                );
                final rotate = Tween<double>(
                  begin: 0.5,
                  end: 0.0,
                ).animate(curved);
                final scale = Tween<double>(
                  begin: 0.6,
                  end: 1.0,
                ).animate(curved);
                return FadeTransition(
                  opacity: anim,
                  child: RotationTransition(
                    turns: rotate,
                    child: ScaleTransition(scale: scale, child: child),
                  ),
                );
              },
              layoutBuilder: (currentChild, previousChildren) {
                // Кастомный layout — все children выровнены по центру
                // фикс-бокса, ничего не растягивает родителя.
                return Stack(
                  alignment: Alignment.center,
                  children: [
                    ...previousChildren,
                    if (currentChild != null) currentChild,
                  ],
                );
              },
              child: _IconForPage(
                key: ValueKey<int>(_settledIndex),
                page: _onbPages[_settledIndex],
                isDark: pal.isDark,
                textColor: pal.text,
              ),
            ),
          ),
        ),
        // Плотный gap между иконкой и заголовком (20px) — иконка
        // прижата к тексту, единая группа.
        const SizedBox(height: 20),
        // ============== ТЕКСТ (свайпается вместе с пальцем, edge-to-edge) ==============
        // PageView во всю ширину экрана — без бокового паддинга, чтобы
        // соседние страницы при свайпе уходили за край экрана.
        // Горизонтальный паддинг 24 у текста — внутри страницы.
        SizedBox(
          height: 130,
          child: PageView.builder(
            controller: _pc,
            itemCount: _onbPages.length,
            // PageScrollPhysics — нативная физика для PageView с
            // правильным snap-поведением. Раньше тут была
            // ClampingScrollPhysics — она тормозит overscroll, но
            // также делает свайп «вязким» на границах. PageScroll
            // даёт плавный snap-feel как в нативных Telegram/Stories.
            physics: const PageScrollPhysics(parent: BouncingScrollPhysics()),
            // Прекэшируем соседние страницы — pageView обычно держит
            // одну страницу и одну соседнюю; явно поднимаем cacheExtent,
            // чтобы при первом свайпе следующая страница не строилась
            // в первом кадре скролла (это давало 1-кадровый jank).
            allowImplicitScrolling: true,
            // onPageChanged срабатывает ТОЛЬКО после того как PageView
            // докатился до целой страницы (обычно после отпускания
            // пальца). Тут мы переключаем _settledIndex → иконка
            // плавно меняется. Никаких setState на каждый кадр скролла.
            onPageChanged: _onPageChanged,
            itemBuilder: (_, i) {
              return RepaintBoundary(
                child: _OnbTextPage(page: _onbPages[i]),
              );
            },
          ),
        ),
        // Нижний воздух — в 2 раза меньше верхнего, чтобы группа
        // «иконка+текст» визуально была ровно по центру экрана.
        const Spacer(flex: 1),
        // ============== ТОЧКИ + КНОПКА + ХВОСТ ==============
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Точки-индикаторы. Слушают PageController через
              // AnimatedBuilder — пересобираются ТОЛЬКО они, а не вся
              // онбординг-стадия. Раньше `_pc.addListener` дёргал
              // `setState(() => _page = p)` на всё дерево — это был
              // основной источник лагов при свайпе.
              _Dots(controller: _pc, count: _onbPages.length),
              const SizedBox(height: 22),
              // Кнопка «Вставить ключ» — sticky внизу.
              PressScale(
                onTap: widget.loading ? null : () => widget.onPaste(),
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
                      if (widget.loading)
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
                        widget.loading ? 'Проверяем…' : 'Вставить ключ',
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
              // Ссылка «Получить токен на GitHub» под кнопкой.
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
              // Зона для возможной ошибки (auth/network). Реальный
              // текст показывается только если `_error` непустой —
              // для invalid-format / empty-clipboard мы НЕ ставим
              // ошибку (см. _pasteToken: молча выходим).
              SizedBox(
                height: widget.error.isEmpty ? 6 : 22,
                child: widget.error.isEmpty
                    ? const SizedBox.shrink()
                    : Text(
                        widget.error,
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

/// Одна иконка для текущей _settledIndex страницы.
///
/// Раньше тут рисовался Lottie-стикер (cloud/robot/bag/lock.json) —
/// большой Telegram JSON анимация, тяжёлая на декоде и paint'е.
/// На свайпе PageView пользователь жаловался на лаги — Lottie
/// постоянно играл свой 60fps цикл и забирал кучу UI-thread времени.
///
/// Теперь — обычный SVG из набора Solar (Iconify). SVG-иконки
/// прогреты в `svg.cache` на старте (см. precacheAllSvgs), декодятся
/// один раз и рисуются мгновенно. Никакой анимации внутри иконки —
/// движение полностью под контролем AnimatedSwitcher между страницами.
class _IconForPage extends StatelessWidget {
  final _OnbPage page;
  final bool isDark;
  final Color textColor;
  const _IconForPage({
    super.key,
    required this.page,
    required this.isDark,
    required this.textColor,
  });

  @override
  Widget build(BuildContext context) {
    final size = page.iconSize;
    final isLogo = page.iconName == 'mdi:github';
    // GitHub-лого:
    //   • в светлой теме — акцентный фиолетовый (попросил юзер),
    //   • в тёмной теме — нейтральный белый (pal.text) как раньше.
    // Остальные иконки — всегда акцентный фиолетовый, чтобы страницы
    // визуально не были «серой стеной».
    final Color color = isLogo
        ? (isDark ? textColor : AppColors.accent)
        : AppColors.accent;
    return Iconify(
      page.iconName,
      size: size,
      color: color,
    );
  }
}

/// Текстовая половина одной онбординг-страницы (заголовок + подпись).
/// Без иконки — иконка вынесена в отдельную зону над PageView'ом, чтобы
/// при свайпе оставаться на месте (как стикер в Telegram). Свой
/// внутренний горизонтальный паддинг 24px — потому что снаружи у
/// PageView'а паддинга НЕТ (иначе соседние страницы при свайпе
/// «обрезаются» по краю отступа, а юзер хочет чтобы они уходили за
/// край экрана).
class _OnbTextPage extends StatelessWidget {
  final _OnbPage page;
  const _OnbTextPage({required this.page});
  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Внутреннего верхнего паддинга нет — gap между иконкой и
          // заголовком задаётся снаружи (20px) ровно.
          Text(
            page.title,
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
              page.sub,
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
    );
  }
}

/// Точки-индикаторы. Слушают `PageController` через `AnimatedBuilder`,
/// поэтому при свайпе пересобираются ТОЛЬКО они — родительский
/// `_OnboardingStage` не делает rebuild на каждый кадр скролла.
///
/// Раньше было: addListener → setState на всю стадию → ребилд PageView,
/// Lottie, кнопок и всего дерева 60+ раз в секунду = лаги.
class _Dots extends StatelessWidget {
  final PageController controller;
  final int count;
  const _Dots({required this.controller, required this.count});

  double _readPage() {
    if (!controller.hasClients) return 0.0;
    final p = controller.page;
    if (p != null) return p;
    // initialPage до того как контроллер прикреплён — берём из
    // ScrollPosition'а виды viewportDimension/pixels (на ранних кадрах
    // PageController.page может быть null).
    return controller.initialPage.toDouble();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: controller,
        builder: (_, __) {
          final position = _readPage();
          return Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (int i = 0; i < count; i++) ...[
                if (i > 0) const SizedBox(width: 8),
                _SingleDot(active: (i - position).abs().clamp(0.0, 1.0)),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _SingleDot extends StatelessWidget {
  /// 0 — это активная страница, 1 — соседняя. Промежуточные значения
  /// дают плавное «дыхание» при свайпе.
  final double active;
  const _SingleDot({required this.active});
  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    // 0 -> «полоска» (active), 1 -> «обычная точка» (inactive).
    final t = 1.0 - active;
    final width = 7 + 16 * t; // 7..23
    final col = Color.lerp(
      pal.sub.withValues(alpha: 0.32),
      AppColors.accent,
      t,
    )!;
    // Без AnimatedContainer — само значение `active` уже плавно меняется
    // каждый кадр (из AnimatedBuilder на ScrollPosition), так что лишняя
    // implicit-анимация даёт «дребезг» и тратит ресурсы.
    return Container(
      width: width,
      height: 7,
      decoration: BoxDecoration(
        color: col,
        borderRadius: BorderRadius.circular(8),
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
