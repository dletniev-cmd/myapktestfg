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
///   1) [_OnboardingStage] — статичный хиро: лого GitHub, заголовок и
///      подпись «всё, что нужно — на одном экране», sticky-кнопка
///      «Вставить ключ» внизу. На фоне — радиальные «призрачные»
///      подписи функций, летящие от центра лого к краям во все
///      360°; они плавно появляются за периметром хироблока
///      (защитная рамка вокруг лого + заголовка + подзаголовка)
///      и плавно гаснут к краям. При удержании пальца на экране
///      анимация плавно ускоряется (см. [_FeatureParticlesBackground]).
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

/// Один лейбл-описание функции, который может появиться как радиальная
/// частица. Пул хардкожен в [_kLabelPool] ниже — рантайм случайно берёт
/// из него лейблы для очередной «частицы» и подписывает её Iconify-иконкой.
class _LabelFeature {
  final String iconName;
  final String text;
  const _LabelFeature(this.iconName, this.text);
}

/// Стейтфул-обёртка над сценой онбординга. Хранит ValueNotifier
/// `_boostTick` — на каждый тап увеличиваем на 1. Фон подписан
/// на этот тик: на изменение поднимает целевую скорость до
/// [_kBoostFactor] и держит её [_kBoostHoldMs] мс, затем плавно
/// возвращает к 1.0.
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
  /// Счётчик тапов по экрану. Каждый pointerDown инкрементит — фон
  /// слышит это в [_FeatureParticlesBackgroundState._onBoost] и кратко
  /// ускоряет анимацию.
  final ValueNotifier<int> _boostTick = ValueNotifier<int>(0);

  @override
  void dispose() {
    _boostTick.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    // Listener верхнего уровня с HitTestBehavior.translucent — ловит
    // ВСЕ pointer down события для буста анимации, но НЕ блокирует
    // доставку событий лежащим ниже виджетам (кнопка «Вставить ключ»,
    // ссылка «Получить токен на GitHub», тогл темы — работают как
    // обычно).
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => _boostTick.value = _boostTick.value + 1,
      // Хиро + фон лежат в Stack. Фон ниже, на нём анимация — она
      // изолирована собственным RepaintBoundary внутри _FeatureParticlesBackground.
      // Передний план (лого/текст/кнопка) тоже обёрнут в RepaintBoundary,
      // чтобы каждый кадр фоновой анимации НЕ заставлял Flutter
      // перерисовывать дерево хиро (это ключевое для 60fps).
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
    required this.onPaste,
    required this.error,
    required this.pal,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Группа «лого + заголовок + подпись» строго по центру
        // свободной области (равные Spacer'ы сверху и снизу до CTA).
        const Spacer(),
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Лого GitHub. На светлой теме — акцентный фиолетовый,
            // на тёмной — белый.
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
          ],
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
//  Анимированный фон: радиальные подписи функций от центра к краям
// =====================================================================
//
// КАК УСТРОЕНО (важно для 60 fps на слабых девайсах):
//   • Фиксированный пул из [_kParticleCount] «частиц». Каждая частица —
//     это лейбл (Solar-иконка + короткая подпись), который летит из
//     центра экрана к одному из 360° углов. Никакого спавна/удаления
//     виджетов на каждом кадре: умершая частица «перерождается» (новый
//     угол / лейбл / длительность / пик-альфа) ВНУТРИ того же объекта
//     [_RadialParticle].
//   • Один общий [Ticker] на весь фон. На каждый тик апдейтится только
//     _animTimeMs (накопленное время с учётом текущего значения буста);
//     это ValueNotifier<double>, на который подписан ValueListenableBuilder
//     каждой _RadialParticleView — ребилдится только лист одной частицы,
//     не вся стадия.
//   • Защитная рамка вокруг хиро (лого + заголовок + подзаголовок):
//     её координаты замеряются после первого кадра через GlobalKey
//     (см. [_OnboardingStageState]). Частица, попавшая ВНУТРЬ — не
//     рисуется (return SizedBox.shrink()). Снаружи альфа линейно
//     поднимается от 0 до 1 на первых ~32 px от грани рамки — даёт
//     эффект «выползания» подписей из-за периметра логотипа.
//   • Радиус по времени: r = exitR · (t² · 0.5 + t · 0.5) — мягкий
//     easeOut. Альфа во времени: fade-in 0..0.10, peak 0.10..0.82,
//     fade-out 0.82..1.0 — частица плавно появляется и плавно гаснет.
//   • Буст при удержании пальца: на каждый тик _boost экспоненциально
//     интерполируется к 1.0 (без удержания) или к [_kBoostFactor]
//     (с удержанием); _animTimeMs += dt · _boost. Никакого скачкообразного
//     ускорения — анимация всегда остаётся плавной.
//   • Каждый _RadialParticleView обёрнут в собственный RepaintBoundary,
//     поэтому движение одной частицы НЕ заставляет соседние слои
//     перерисовываться. Хиро (лого/заголовок) тоже в RepaintBoundary.
//   • Альфа применяется напрямую к Color.withValues(alpha:) в
//     colorFilter Iconify и TextStyle.color — НИКАКОГО Opacity-виджета
//     (saveLayer убивает fps).

/// Пул лейблов, из которого случайно берётся «начинка» очередной частицы.
/// Длина пула > [_kParticleCount], так что в одном кадре повторов почти
/// не бывает; даже если случайно совпало — это незаметно из-за разной
/// фазы/альфы/направления.
const List<_LabelFeature> _kLabelPool = [
  _LabelFeature('solar:gallery-add-bold', 'Скриншоты к багам'),
  _LabelFeature('solar:cloud-upload-bold', 'Заливай файлы'),
  _LabelFeature('solar:download-square-bold', 'Скачивай APK'),
  _LabelFeature('solar:folder-with-files-bold', 'Все репозитории'),
  _LabelFeature('solar:branching-paths-up-bold', 'Ветки и коммиты'),
  _LabelFeature('solar:eye-bold', 'Следи за статусом'),
  _LabelFeature('solar:rocket-bold', 'Запускай Actions'),
  _LabelFeature('solar:bell-bold', 'Уведомления'),
  _LabelFeature('solar:star-bold', 'Избранные репо'),
  _LabelFeature('solar:check-circle-bold', 'Сборка готова'),
  _LabelFeature('solar:tag-bold', 'Релизы и теги'),
  _LabelFeature('solar:bug-bold', 'Issues и баги'),
];

/// Размер лого GitHub на экране входа. Вынесен в константу, чтобы
/// фоновые частицы посчитали от этого радиус «ободка» и никогда
/// не залетали внутрь силуэта.
const double _kLogoSize = 156;
/// Радиус спавна частиц (от центра экрана): чуть больше
/// радиуса лого, чтобы текст рядом с иконкой тоже не наезжал
/// на silhouette.
const double _kLogoRadius = _kLogoSize / 2 + 14;

const int _kParticleCount = 11;
const double _kParticleDurMinMs = 7000;
const double _kParticleDurSpanMs = 3500;
/// Базовая пик-альфа: сравниваем с light темой на светло-сером фоне
/// с базовым вариантом 0.5 это практически невидимо — подняли.
const double _kParticlePeakMin = 0.65;
const double _kParticlePeakSpan = 0.25;
/// Сколько раз ускоряемся при тапе.
const double _kBoostFactor = 2.4;
/// Сколько держим ускорение после тапа до начала decay.
const int _kBoostHoldMs = 1500;
/// Коэффициент экспоненциального сглаживания скорости
/// (`_boost += (target - _boost) * _kBoostEase`).
const double _kBoostEase = 0.18;

/// Изменяемое состояние одной радиальной частицы. Поля мутабельные:
/// когда возраст частицы превышает [durMs], мы «перерождаем» её
/// внутри того же объекта (см. [_FeatureParticlesBackgroundState._respawn]),
/// чтобы не аллоцировать новые объекты в горячем пути.
class _RadialParticle {
  double bornAtMs;
  double durMs;
  double angle;
  double peakAlpha;
  int labelIndex;
  _RadialParticle({
    required this.bornAtMs,
    required this.durMs,
    required this.angle,
    required this.peakAlpha,
    required this.labelIndex,
  });
}

class _FeatureParticlesBackground extends StatefulWidget {
  /// Счётчик тапов по экрану. На каждое изменение (инкремент)
  /// поднимаем целевую скорость до [_kBoostFactor] на [_kBoostHoldMs] мс,
  /// потом плавно возвращаем к 1.0.
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
  final math.Random _rng = math.Random();
  late final List<_RadialParticle> _particles;

  /// Накопленное «время анимации» с учётом текущего значения буста.
  /// На него опираются возраст/фаза каждой частицы. На каждый тик
  /// мы добавляем `dt · _boost` и кладём новое значение в
  /// `_animTimeMs.value` — ValueListenableBuilder в листьях частиц
  /// перерисует только себя.
  final ValueNotifier<double> _animTimeMs = ValueNotifier<double>(0);
  Duration _lastElapsed = Duration.zero;
  double _boost = 1.0;
  /// Момент (эпоха, мс), до которого boost-таргет равен [_kBoostFactor].
  /// После этого времени таргет = 1.0 и _boost экспоненциально
  /// сходится к 1.0.
  int _boostUntilEpochMs = 0;

  @override
  void initState() {
    super.initState();
    _particles = List.generate(_kParticleCount, (_) {
      final dur =
          _kParticleDurMinMs + _rng.nextDouble() * _kParticleDurSpanMs;
      // Стартовый возраст — случайный отрезок от 0 до durMs, чтобы все
      // частицы не вылетали одновременно из одной точки.
      final age = _rng.nextDouble() * dur;
      return _RadialParticle(
        bornAtMs: -age,
        durMs: dur,
        angle: _randomAngle(),
        peakAlpha:
            _kParticlePeakMin + _rng.nextDouble() * _kParticlePeakSpan,
        labelIndex: _rng.nextInt(_kLabelPool.length),
      );
    });
    widget.boostTick.addListener(_onBoost);
    _ticker = createTicker(_onTick)..start();
  }

  void _onBoost() {
    _boostUntilEpochMs =
        DateTime.now().millisecondsSinceEpoch + _kBoostHoldMs;
  }

  /// Случайный угол с лёгким уклоном к горизонтали: чтобы подписи
  /// реже проходили строго над/под заголовком, мы смешиваем raw-угол
  /// с ближайшей горизонталью (0° или 180°) в пропорции 70/30.
  double _randomAngle() {
    final raw = _rng.nextDouble() * 2 * math.pi;
    final target = math.cos(raw) >= 0 ? 0.0 : math.pi;
    return raw * 0.7 + target * 0.3;
  }

  void _onTick(Duration elapsed) {
    if (_lastElapsed == Duration.zero) {
      // На первом тике dt считать не от чего; просто запомним момент.
      _lastElapsed = elapsed;
      return;
    }
    final dtMs = (elapsed - _lastElapsed).inMicroseconds / 1000.0;
    _lastElapsed = elapsed;
    final nowEpoch = DateTime.now().millisecondsSinceEpoch;
    final boostTarget =
        nowEpoch < _boostUntilEpochMs ? _kBoostFactor : 1.0;
    _boost += (boostTarget - _boost) * _kBoostEase;
    final nextMs = _animTimeMs.value + dtMs * _boost;
    // «Умершие» частицы (age >= durMs) перерождаем — используем nextMs
    // как новый bornAtMs, чтобы возраст начался с нуля сразу после
    // обновления времени.
    for (final p in _particles) {
      if (nextMs - p.bornAtMs >= p.durMs) {
        _respawn(p, nextMs);
      }
    }
    _animTimeMs.value = nextMs;
  }

  void _respawn(_RadialParticle p, double now) {
    p.bornAtMs = now;
    p.durMs = _kParticleDurMinMs + _rng.nextDouble() * _kParticleDurSpanMs;
    p.angle = _randomAngle();
    p.peakAlpha =
        _kParticlePeakMin + _rng.nextDouble() * _kParticlePeakSpan;
    p.labelIndex = _rng.nextInt(_kLabelPool.length);
  }

  @override
  void dispose() {
    widget.boostTick.removeListener(_onBoost);
    _ticker.dispose();
    _animTimeMs.dispose();
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
          // exitR — «радиус ухода»: половина диагонали + запас, чтобы
          // лейблы успели уйти за край экрана прежде, чем их альфа
          // упрётся в 0.
          final exitR = math.sqrt(
                    size.width * size.width + size.height * size.height,
                  ) /
                  2 +
              24;
          return Stack(
            fit: StackFit.expand,
            clipBehavior: Clip.none,
            children: [
              for (int i = 0; i < _particles.length; i++)
                _RadialParticleView(
                  key: ValueKey<int>(i),
                  particle: _particles[i],
                  bgSize: size,
                  exitR: exitR,
                  animTimeMs: _animTimeMs,
                  iconColor: iconColor,
                  textColor: textColor,
                ),
            ],
          );
        },
      ),
    );
  }
}

/// Виджет одной радиальной частицы. ValueListenableBuilder ребилдит
/// ТОЛЬКО Positioned внутри — родительский Stack из
/// _FeatureParticlesBackground остаётся стабильным.
///
/// Частица появляется ровно на радиусе [_kLogoRadius] от центра экрана
/// (т.е. сразу «на ободке» лого), и за время жизни плавно отлетает до
/// [exitR]. Внутрь силуэта она никогда не залетает по конструкции.
class _RadialParticleView extends StatelessWidget {
  final _RadialParticle particle;
  final Size bgSize;
  final double exitR;
  final ValueListenable<double> animTimeMs;
  final Color iconColor;
  final Color textColor;
  const _RadialParticleView({
    super.key,
    required this.particle,
    required this.bgSize,
    required this.exitR,
    required this.animTimeMs,
    required this.iconColor,
    required this.textColor,
  });

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: ValueListenableBuilder<double>(
        valueListenable: animTimeMs,
        builder: (_, currentMs, __) {
          final age = currentMs - particle.bornAtMs;
          if (age <= 0) return const SizedBox.shrink();
          final t = (age / particle.durMs).clamp(0.0, 1.0);
          // easeOutCubic: бойкий старт у края лого, мягкое замедление
          // к краю экрана. Координата старта = _kLogoRadius, финиш = exitR.
          final tInv = 1.0 - t;
          final eased = 1.0 - tInv * tInv * tInv;
          final r = _kLogoRadius + (exitR - _kLogoRadius) * eased;
          final cx = bgSize.width / 2;
          final cy = bgSize.height / 2;
          final x = cx + math.cos(particle.angle) * r;
          final y = cy + math.sin(particle.angle) * r;
          final alpha = _alphaByT(t, particle.peakAlpha).clamp(0.0, 1.0);
          if (alpha < 0.01) return const SizedBox.shrink();
          final label = _kLabelPool[particle.labelIndex];
          final ic = iconColor.withValues(alpha: alpha);
          final tc = textColor.withValues(alpha: alpha);
          return Positioned(
            left: x,
            top: y,
            // FractionalTranslation сдвигает лейбл так, чтобы (x, y)
            // оказалась его геометрическим центром — без знания реальной
            // ширины Row'а.
            child: IgnorePointer(
              child: FractionalTranslation(
                translation: const Offset(-0.5, -0.5),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Iconify(label.iconName, size: 18, color: ic),
                    const SizedBox(width: 8),
                    Text(
                      label.text,
                      maxLines: 1,
                      softWrap: false,
                      style: TextStyle(
                        color: tc,
                        fontSize: 14.5,
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

/// Альфа по времени жизни частицы:
///   t ∈ [0, fadeInUntil]            — линейный fade-in 0..peak
///   t ∈ [fadeInUntil, fadeOutFrom]  — peak
///   t ∈ [fadeOutFrom, 1]            — линейный fade-out peak..0
double _alphaByT(
  double t,
  double peak, {
  double fadeInUntil = 0.10,
  double fadeOutFrom = 0.82,
}) {
  if (t < fadeInUntil) return peak * (t / fadeInUntil);
  if (t > fadeOutFrom) {
    return peak * (1 - (t - fadeOutFrom) / (1 - fadeOutFrom));
  }
  return peak;
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
