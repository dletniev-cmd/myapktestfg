import 'dart:math' as math;
import '../widgets/m3_loading.dart';

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
///      «Вставить ключ» внизу. На фоне — печатающиеся строки кода и
///      коротких описаний функций (см. [_CodeRainBackground]). Появляются
///      плавно через ≈3 секунды после захода — раньше тут ещё крутились
///      «призрачные» карточки с иконками функций, юзер прямо просил их
///      убрать и оставить только блоки кода в стиле терминала.
///   2) [_PermissionsStage] — показывается после того, как токен проверен;
///      содержит тумблеры разрешений (уведомления, доступ к галерее)
///      и кнопку «Начать».
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});
  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  // Стадии: 0 — онбординг + вставка ключа, 1 — разрешения.
  int _stage = 0;
  bool _loading = false;
  // Сообщение об ошибке. Намеренно НЕ показываем ничего для
  // «формат не похож на токен» / «пустой буфер» — если ключ не вставился,
  // юзеру и так очевидно по отсутствию перехода на следующий экран.
  // Показываем только реальные сетевые/auth ошибки (401 от GitHub и т.p.).
  String _error = '';

  // Контроллер плавного появления фонового слоя (печатающиеся строки кода).
  // Юзер: «появляться они должны начинать плавно, через секунды три».
  // Реализуем как «3 сек тишины → плавный fade-in за 2.2 сек». Делаем
  // это одним контроллером длительностью 5.2с с CurvedAnimation
  // (Interval 3000/5200..1.0). До 3-й секунды значение остаётся 0, потом
  // плавно идёт к 1.
  // Этот же контроллер срабатывает и при выходе из настроек (logout →
  // SplashScreen пересоздаётся, и появление кода снова начинается через
  // 3 секунды).
  late final AnimationController _bgFade = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 5200),
  );
  late final Animation<double> _bgFadeCurve = CurvedAnimation(
    parent: _bgFade,
    curve: const Interval(
      // 3000мс задержки из 5200мс общей длительности → 0.5769…
      3000 / 5200,
      1.0,
      curve: Curves.easeOutCubic,
    ),
  );

  @override
  void initState() {
    super.initState();
    // Стартуем сразу после монтирования. Сам контроллер крутится
    // 5.2 секунды, но `Interval` держит прозрачность на нуле первые
    // 3 секунды — экран реально стартует пустым, как и просил юзер.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _bgFade.forward();
    });
  }

  @override
  void dispose() {
    _bgFade.dispose();
    super.dispose();
  }

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
    // ВАЖНО: фоновые слои (_CodeRainBackground / _FeatureParticlesBackground)
    // лежат СНАРУЖИ SafeArea и расползаются на весь экран — иначе сверху
    // (под status bar) и снизу появлялась видимая «полоса», за которую
    // строки кода и частицы не залетали.
    // Listener тоже снаружи SafeArea — удержание пальца ловится на любой
    // точке экрана, включая зону под статусбаром и навбаром.
    return Scaffold(
      backgroundColor: pal.bg,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Фон живёт ТОЛЬКО на онбординге (stage 0). На экране
          // разрешений (stage 1) его быть не должно — юзер просил.
          // AnimatedSwitcher даёт мягкий fade-out при переходе, чтобы
          // фон не «обрубался» резко.
          //
          // Раньше тут лежал и _FeatureParticlesBackground (летящие
          // карточки с иконками функций). Юзер: «убери типи эти
          // карточки с иконками где описание функций итп!! оставь
          // только блоки кода которые печатаются» — убрано полностью.
          Positioned.fill(
            child: IgnorePointer(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 280),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                child: _stage == 0
                    ? FadeTransition(
                        key: const ValueKey('bg0'),
                        // _bgFadeCurve = Interval(3000/5200..1.0).
                        // До 3-й секунды прозрачность = 0 (экран пустой),
                        // потом плавно (easeOutCubic, ~2.2с) выходит на 1.
                        opacity: _bgFadeCurve,
                        child: const _CodeRainBackground(),
                      )
                    : const SizedBox.expand(key: ValueKey('bg1')),
              ),
            ),
          ),
          Positioned.fill(
            child: Listener(
              behavior: HitTestBehavior.translucent,
              // Юзер: «ускорение при удержании совсем немного и очень
              // плавное». Снизили таргет с 2.2× до 1.25× — анимации
              // лишь чуть-чуть оживают под пальцем, без эффекта «они
              // вдруг побежали». Плавность достигается тем, что в
              // тиках частицы/код-дождь экспоненциально подъезжают к
              // таргету (см. _onTick), а не прыгают на него мгновенно.
              onPointerDown: (_) => _kSplashSpeedTarget.value = 1.25,
              onPointerUp: (_) => _kSplashSpeedTarget.value = 1.0,
              onPointerCancel: (_) => _kSplashSpeedTarget.value = 1.0,
              child: SafeArea(
                child: Stack(
                  children: [
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
                            child: SlideTransition(
                                position: slide, child: child),
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
            ),
          ),
        ],
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
          // Анимация 1-в-1 как у кнопки темы на экране профиля
          // (см. ProfileScreen): новая иконка въезжает с поворотом
          // 0.25→0 (90°→0°) + scale 0→1. Старая ушла «обратно» —
          // AnimatedSwitcher играет тот же transitionBuilder в reverse.
          // 220мс — длительность из профиля, чтобы переключение между
          // экранами не выглядело по-разному.
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 220),
            transitionBuilder: (child, anim) => RotationTransition(
              turns: Tween<double>(begin: 0.25, end: 0.0).animate(anim),
              child: ScaleTransition(scale: anim, child: child),
            ),
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
// Стадия 1. Онбординг (статичный хиро + печатающиеся строки кода)
// =====================================================================

/// Глобальная "скорость" фоновых анимаций splash.
/// 1.0 — спокойный режим, 1.25 — пользователь зажал палец где-то на экране.
/// [_CodeRainBackground] мягко доводит свою локальную скорость до этого
/// таргета на каждом тике — это и даёт «плавное ускорение при удержании».
///
/// Раньше тут жили ещё и «призрачные фичи» (_FeatureParticlesBackground)
/// с летящими иконками — юзер прямо просил их убрать и оставить только
/// блоки кода в стиле терминала.
final ValueNotifier<double> _kSplashSpeedTarget = ValueNotifier<double>(1.0);

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
  @override
  void dispose() {
    _kSplashSpeedTarget.value = 1.0;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    // Фоны (code rain + particles) и Listener для удержания пальца теперь
    // живут на уровне _SplashScreen — снаружи SafeArea, во весь экран.
    // Здесь остаётся только сам hero-контент онбординга.
    return RepaintBoundary(
      child: _OnboardingHero(
        loading: widget.loading,
        error: widget.error,
        onPaste: widget.onPaste,
        pal: pal,
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
                          child: M3LoadingIndicator(
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
// Фон: «дождь кода» — короткие строки git/cli печатаются в реальном
// времени и медленно уплывают вверх. Распределяются по СЛОТАМ
// (14 строк × лево/право), поэтому никогда не накладываются друг на
// друга и не лезут в центр под лого. Скорость общая через
// _kSplashSpeedTarget — при удержании пальца ускоряется так же, как
// и частицы.
// =====================================================================

/// Пул строк, которые «печатаются» в код-дождевом фоне.
///
/// Состав согласован с юзером: «помимо кода, в стиле кода появляется
/// печатается текст типо: приложение разработал даниил летниев, ну и
/// там уже также появляются текст описания каких-то функций». Всё
/// рендерится одним и тем же монопшинным виджетом [_CodeLineView] с
/// одной и той же анимацией печати — то есть авторская строка и
/// фичи-описания визуально неотличимы от обычных команд: только их
/// СОДЕРЖИМОЕ отличается от стандартного `git ...` / `flutter ...`.
///
/// Префиксы «# » у фич-описаний — это shell-style комментарий, как раз
/// чтобы они «жили» в той же стилистике терминала, что и команды.
const List<String> _kCodeSnippets = [
  // ─── Авторская строка (юзер прямо просил включить) ───────────
  'приложение разработал даниил летниев',
  '# author: даниил летниев',
  '// (c) daniil letniev',

  // ─── Описания функций приложения в стиле комментариев ────────
  '# заливай файлы — push в существующий репо',
  '# запускай GitHub Actions из приложения',
  '# скачивай APK прямо из release',
  '# баг-трекер со скриншотами и метками',
  '# уведомления о статусах сборок',
  '# просмотр кода и веток репозитория',
  '# твои репозитории всегда под рукой',
  '# мгновенный пуш одним тапом',
  '# редактор скриншотов прямо в баге',
  '# токен хранится только на устройстве',

  // ─── Обычные shell/git/flutter-команды ───────────────────────
  'git add .',
  'git commit -m "feat: splash polish"',
  'git push origin main',
  'git pull --rebase',
  'git checkout -b feature/particles',
  'git status',
  'git log --oneline -n 5',
  'gh pr create --fill',
  'git stash pop',
  'git fetch --all --prune',
  'git switch main',
  'flutter pub get',
  'flutter build apk',
  '→ pushed 3 objects',
  '✓ build succeeded',
  '* main 4f2a1b9',
  'remote: Compressing objects: 100%',
  'Counting objects: 12, done.',
];

class _CodeRainBackground extends StatefulWidget {
  const _CodeRainBackground();
  @override
  State<_CodeRainBackground> createState() => _CodeRainBackgroundState();
}

class _CodeSlot {
  final int row;
  final bool right; // true = правая колонка, false = левая
  bool busy = false;
  _CodeSlot(this.row, this.right);
}

class _CodeLine {
  final int id;
  final String text;
  final _CodeSlot slot;
  final int startedAtMicros;
  final int lifeMs;
  int typedChars = 0;
  _CodeLine({
    required this.id,
    required this.text,
    required this.slot,
    required this.startedAtMicros,
    required this.lifeMs,
  });
  bool deadAt(int now) => (now - startedAtMicros) >= lifeMs * 1000;
}

class _CodeRainBackgroundState extends State<_CodeRainBackground>
    with SingleTickerProviderStateMixin {
  static const int _kRows = 14;
  // Юзер прямо просил «строки кода реже». Снизили одновременных
  // с 8 до 4. Спавн-пауза (gapMicros в _onTick) тоже выросла
  // с 700мс до 1800мс — свободные слоты заполняются спокойно,
  // по одной строке примерно каждые полторы-две секунды, а не вереницей.
  static const int _kMaxLines = 4;

  late final Ticker _ticker;
  Duration _realLast = Duration.zero;
  int _scaledMicros = 0;
  int _lastSpawnMicros = -2000000;
  double _speed = 1.0;
  int _idCursor = 0;

  final math.Random _rnd = math.Random();
  final List<_CodeSlot> _slots = [];
  final List<_CodeLine> _lines = [];
  final ValueNotifier<int> _frameTick = ValueNotifier<int>(0);

  @override
  void initState() {
    super.initState();
    for (int r = 0; r < _kRows; r++) {
      _slots.add(_CodeSlot(r, false));
      _slots.add(_CodeSlot(r, true));
    }
    _ticker = createTicker(_onTick)..start();
    // Никакого pre-spawn'а. Раньше было 4 строки пред-выведено «чтобы
    // экран сразу не был пустым» — но юзер как раз хочет плавное
    // появление (fade-in 5с + спавн-пауза 1800мс), и эти пред-
    // выведенные строки жили вопреки фейду. Первая строка
    // появится через _spawn в _onTick после первого gap'а.
  }

  @override
  void dispose() {
    _ticker.dispose();
    _frameTick.dispose();
    super.dispose();
  }

  void _onTick(Duration elapsed) {
    final dtMicros = (elapsed - _realLast).inMicroseconds.clamp(0, 250000);
    _realLast = elapsed;
    final target = _kSplashSpeedTarget.value;
    // 600000 мкс = ~600мс «полураспад» перехода скорости к таргету.
    // Раньше было 220000 (~220мс) — слишком резкое ускорение.
    // Юзер прямо просил: «ускорение при удержании совсем немного
    // и очень плавное».
    final k = 1 - math.exp(-dtMicros / 600000.0);
    _speed += (target - _speed) * k;
    _scaledMicros += (dtMicros * _speed).round();

    // Каденция спавна: 1800мс сцены (раньше 700мс). Это в ~2.5 раза
    // реже появляются новые строки — по прямой просьбе юзера.
    const gapMicros = 1800 * 1000;
    if (_scaledMicros - _lastSpawnMicros > gapMicros &&
        _lines.length < _kMaxLines) {
      _spawn();
      _lastSpawnMicros = _scaledMicros;
    }

    bool removed = false;
    for (int i = _lines.length - 1; i >= 0; i--) {
      final l = _lines[i];
      if (l.deadAt(_scaledMicros)) {
        l.slot.busy = false;
        _lines.removeAt(i);
        removed = true;
      }
    }

    _frameTick.value = _scaledMicros;
    if (removed && mounted) setState(() {});
  }

  _CodeSlot? _pickSlot() {
    final free = _slots.where((s) => !s.busy).toList();
    if (free.isEmpty) return null;
    return free[_rnd.nextInt(free.length)];
  }

  void _spawn({double initialAgeFrac = 0.0}) {
    final slot = _pickSlot();
    if (slot == null) return;
    slot.busy = true;
    final text = _kCodeSnippets[_rnd.nextInt(_kCodeSnippets.length)];
    final lifeMs = 4200 + _rnd.nextInt(2200);
    final start = _scaledMicros - (lifeMs * 1000 * initialAgeFrac).round();
    _lines.add(_CodeLine(
      id: _idCursor++,
      text: text,
      slot: slot,
      startedAtMicros: start,
      lifeMs: lifeMs,
    ));
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    // Полупрозрачный акцент — заметно, но не отвлекает от лого.
    final color = AppColors.accent.withValues(alpha: 0.42);

    // Раньше здесь был ShaderMask с радиальным градиентом: центр
    // прозрачный (под лого), края непрозрачные. Это создавало
    // saveLayer НА КАЖДЫЙ КАДР — все текстовые виджеты
    // перерастеризовались при каждом тике (typing-эффект, дрейф).
    // На мобильных устройствах ShaderMask забирает 4-8мс/кадр,
    // что и вызывало ощутимый jank, о котором юзер писал
    // («ваще чото всё подлагивает»).
    //
    // Код-строки и так живут в фиксированных слотах (14 строк ×
    // лево/право), а центр свободен — маска больше не нужна.
    // RepaintBoundary остаётся: ребилды внутри _CodeLineView
    // через ValueNotifier изолированы от остального дерева.
    return RepaintBoundary(
      child: ClipRect(
        child: LayoutBuilder(
          builder: (_, c) {
            final rowH = c.maxHeight / _kRows;
            return Stack(
              fit: StackFit.expand,
              children: [
                for (final l in _lines)
                  _CodeLineView(
                    key: ValueKey<int>(l.id),
                    line: l,
                    rowTop: l.slot.row * rowH + rowH * 0.18,
                    color: color,
                    frameTick: _frameTick,
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _CodeLineView extends StatelessWidget {
  final _CodeLine line;
  final double rowTop;
  final Color color;
  final ValueNotifier<int> frameTick;
  const _CodeLineView({
    super.key,
    required this.line,
    required this.rowTop,
    required this.color,
    required this.frameTick,
  });

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: frameTick,
      builder: (_, nowMicros, __) {
        final age = nowMicros - line.startedAtMicros;
        if (age < 0 || age >= line.lifeMs * 1000) {
          return const SizedBox.shrink();
        }
        // Печатаем за первые 45% жизни.
        final typedFrac =
            (age / (line.lifeMs * 1000.0 * 0.45)).clamp(0.0, 1.0);
        final chars = (typedFrac * line.text.length).floor();
        final shown = line.text.substring(0, chars);

        // Альфа: 400мс in / 700мс out.
        final lifeMicros = line.lifeMs * 1000;
        double a;
        if (age < 400000) {
          a = age / 400000.0;
        } else if (age > lifeMicros - 700000) {
          a = ((lifeMicros - age) / 700000.0).clamp(0.0, 1.0);
        } else {
          a = 1.0;
        }

        // Лёгкий дрейф вверх.
        final lifeFrac = age / lifeMicros;
        final dy = -lifeFrac * 24.0;

        final caret = Container(
          width: 5,
          height: 11,
          margin: const EdgeInsets.only(left: 2),
          color: color.withValues(alpha: a * 0.75),
        );
        final textWidget = Text(
          shown,
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.clip,
          style: TextStyle(
            fontFamily: 'monospace',
            fontFeatures: const [FontFeature.tabularFigures()],
            fontSize: 11,
            height: 1.2,
            color: color.withValues(alpha: a),
          ),
        );
        final row = Row(
          mainAxisSize: MainAxisSize.min,
          children: [textWidget, caret],
        );
        return Positioned(
          top: rowTop + dy,
          left: line.slot.right ? null : 12,
          right: line.slot.right ? 12 : null,
          child: RepaintBoundary(child: row),
        );
      },
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
