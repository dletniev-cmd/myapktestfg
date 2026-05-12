import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lottie/lottie.dart';
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
        setState(() {
          _loading = false;
          _error = 'Буфер обмена пуст';
        });
        return;
      }
      // быстрая валидация: ghp_, gho_, ghs_, ghu_, ghr_, github_pat_
      final ok =
          RegExp(r'^(ghp|gho|ghs|ghu|ghr)_|^github_pat_').hasMatch(raw);
      if (!ok) {
        setState(() {
          _loading = false;
          _error = 'Это не похоже на токен (ghp_… / github_pat_…)';
        });
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
    return Scaffold(
      backgroundColor: pal.bg,
      body: SafeArea(
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

/// Описание одной онбординг-страницы. Иконка может быть либо SVG из
/// набора Iconify (поле [iconifyName]) — для первой страницы с лого
/// GitHub, либо анимированный Lottie-стикер (поле [lottieAsset]) —
/// для страниц с описанием фич. В каждый момент времени НЕНУЛЕВОЕ
/// должно быть только одно из двух полей.
class _OnbPage {
  final String? iconifyName;
  final String? lottieAsset;
  final double iconSize;
  final String title;
  final String sub;
  const _OnbPage({
    this.iconifyName,
    this.lottieAsset,
    required this.title,
    required this.sub,
    this.iconSize = 150,
  });
}

const List<_OnbPage> _onbPages = [
  _OnbPage(
    iconifyName: 'mdi:github',
    iconSize: 150,
    title: 'GitHub Pusher',
    sub: 'Свайпни, чтобы узнать что умеет приложение.',
  ),
  _OnbPage(
    lottieAsset: 'assets/lottie/cloud.json',
    title: 'Заливай файлы',
    sub:
        'Прямо с телефона отправляй файлы в любой свой репозиторий — без коммитов вручную.',
  ),
  _OnbPage(
    lottieAsset: 'assets/lottie/robot.json',
    title: 'Запускай Actions',
    sub:
        'Следи за статусом сборок и перезапускай их одним тапом прямо из приложения.',
  ),
  _OnbPage(
    lottieAsset: 'assets/lottie/bag.json',
    title: 'Скачивай APK',
    sub:
        'Артефакты сборки доступны сразу — устанавливай новый билд без перехода в браузер.',
  ),
  _OnbPage(
    lottieAsset: 'assets/lottie/lock.json',
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

  // Дробная позиция PageView'а 0..count-1. Используется только для
  // плавных точек-индикаторов (активная вытягивается в полоску
  // в реальном времени вместе с пальцем).
  double _page = 0;

  // Это ключевое для Telegram-style поведения: settledIndex обновляется
  // ТОЛЬКО в `PageView.onPageChanged`, т.е. ПОСЛЕ того как юзер отпустил
  // палец и PageView докатился до целой страницы. Иконочный
  // AnimatedSwitcher биндится именно на этот индекс, поэтому пока
  // тянешь пальцем — иконка не меняется, только после отпускания.
  int _settledIndex = 0;

  // Кэш предзагруженных LottieComposition'ов. Декодим один раз в
  // `initState`, дальше Lottie берёт готовый `LottieComposition` без
  // повторного парсинга JSON.
  final Map<String, Future<LottieComposition>> _lottieCache = {};

  @override
  void initState() {
    super.initState();
    _pc.addListener(_onScroll);
    for (final p in _onbPages) {
      final a = p.lottieAsset;
      if (a != null) {
        _lottieCache[a] = AssetLottie(a).load();
      }
    }
  }

  void _onScroll() {
    final p = _pc.hasClients ? (_pc.page ?? 0).toDouble() : 0.0;
    if ((p - _page).abs() < 0.001) return;
    setState(() => _page = p);
  }

  void _onPageChanged(int i) {
    if (i == _settledIndex) return;
    setState(() => _settledIndex = i);
  }

  @override
  void dispose() {
    _pc.removeListener(_onScroll);
    _pc.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    return Column(
      children: [
        // ============== ВЕРХНИЙ ВОЗДУХ — как в Telegram ==============
        const Spacer(flex: 18),
        // ============== ИКОНОЧНАЯ ЗОНА (фиксирована, НЕ свайпается) ==============
        // Иконка биндится на `_settledIndex`, который обновляется ТОЛЬКО
        // в `PageView.onPageChanged` (т.е. после того как палец отпущен
        // и PageView докатился до целой страницы). Пока юзер тянет
        // пальцем — иконка стоит на месте. Когда страница защёлкивается —
        // AnimatedSwitcher плавно crossfade'ит иконку на новую.
        RepaintBoundary(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 280),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            transitionBuilder: (child, anim) {
              final scale = Tween<double>(begin: 0.88, end: 1.0).animate(
                CurvedAnimation(parent: anim, curve: Curves.easeOutBack),
              );
              return FadeTransition(
                opacity: anim,
                child: ScaleTransition(scale: scale, child: child),
              );
            },
            child: _IconForPage(
              key: ValueKey<int>(_settledIndex),
              page: _onbPages[_settledIndex],
              lottieCache: _lottieCache,
              textColor: pal.text,
            ),
          ),
        ),
        const Spacer(flex: 3),
        // ============== ТЕКСТ (свайпается вместе с пальцем, edge-to-edge) ==============
        // PageView во всю ширину экрана — без бокового паддинга, чтобы
        // соседние страницы при свайпе уходили за край экрана.
        // Горизонтальный паддинг 24 у текста — внутри страницы.
        SizedBox(
          height: 130,
          child: PageView.builder(
            controller: _pc,
            itemCount: _onbPages.length,
            physics: const BouncingScrollPhysics(),
            // Ключевой момент: onPageChanged срабатывает ТОЛЬКО после
            // того как PageView докатился до целой страницы (обычно
            // после отпускания пальца). Именно тут мы переключаем
            // _settledIndex → иконка плавно меняется.
            onPageChanged: _onPageChanged,
            itemBuilder: (_, i) {
              final dist = (i - _page).abs().clamp(0.0, 1.0);
              final opacity = (1.0 - dist).clamp(0.0, 1.0);
              return RepaintBoundary(
                child: Opacity(
                  opacity: opacity,
                  child: _OnbTextPage(page: _onbPages[i]),
                ),
              );
            },
          ),
        ),
        const Spacer(flex: 2),
        // ============== ТОЧКИ + КНОПКА + ХВОСТ ==============
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
          child: Column(
            children: [
              _Dots(count: _onbPages.length, position: _page),
              const SizedBox(height: 18),
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
              const SizedBox(height: 14),
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
              const SizedBox(height: 10),
              SizedBox(
                height: 22,
                child: Text(
                  widget.error,
                  style: const TextStyle(
                    color: AppColors.red,
                    fontSize: 13,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
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

/// Одна иконка для текущей _settledIndex страницы. Рисует либо
/// Lottie-стикер, либо Iconify SVG. Анимация Lottie всегда активна —
/// `AnimatedSwitcher` рендерит ровно один экземпляр в каждый момент
/// времени (кроме короткого crossfade'а), соседние не существуют.
///
/// Обёрнута в `RepaintBoundary` — repaint Lottie не вызывает
/// перекраску остального дерева (текста, точек).
class _IconForPage extends StatelessWidget {
  final _OnbPage page;
  final Map<String, Future<LottieComposition>> lottieCache;
  final Color textColor;
  const _IconForPage({
    super.key,
    required this.page,
    required this.lottieCache,
    required this.textColor,
  });

  @override
  Widget build(BuildContext context) {
    final lottieAsset = page.lottieAsset;
    final size = page.iconSize;
    final Widget icon;
    if (lottieAsset != null) {
      icon = FutureBuilder<LottieComposition>(
        future: lottieCache[lottieAsset],
        builder: (_, snap) {
          final comp = snap.data;
          if (comp == null) {
            // Декод стартует в `initState` — на практике юзер этого
            // placeholder'а не видит.
            return SizedBox(width: size, height: size);
          }
          return Lottie(
            composition: comp,
            width: size,
            height: size,
            fit: BoxFit.contain,
            animate: true,
            repeat: true,
            // 30fps вместо FrameRate.max — для TG-стикеров визуально
            // неотличимо, но в 2× меньше painting'а.
            frameRate: FrameRate(30),
          );
        },
      );
    } else {
      icon = Iconify(
        page.iconifyName ?? 'mdi:github',
        size: size,
        color: textColor,
      );
    }
    return RepaintBoundary(
      child: SizedBox(width: size, height: size, child: Center(child: icon)),
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
          const SizedBox(height: 12),
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

class _Dots extends StatelessWidget {
  final int count;
  /// Дробная позиция страницы (0..count-1). Активная точка плавно
  /// перетягивается между соседями.
  final double position;
  const _Dots({required this.count, required this.position});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (int i = 0; i < count; i++) ...[
          if (i > 0) const SizedBox(width: 8),
          _SingleDot(active: (i - position).abs().clamp(0.0, 1.0)),
        ],
      ],
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
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
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
