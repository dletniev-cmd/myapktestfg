import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../iconify.dart';
import '../navigation.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'bug_constants.dart';
import 'bug_meta.dart';
import 'bugs.dart' show bugThumbColor;

class BugDetailScreen extends StatefulWidget {
  final String id;
  const BugDetailScreen({super.key, required this.id});
  @override
  State<BugDetailScreen> createState() => _BugDetailScreenState();
}

class _BugDetailScreenState extends State<BugDetailScreen> {
  bool _shotsReady = false;

  BugItem? get _bug {
    final ix = AppState.I.bugs.indexWhere((e) => e.id == widget.id);
    if (ix == -1) return null;
    return AppState.I.bugs[ix];
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_shotsReady) {
      final anim = ModalRoute.of(context)?.animation;
      if (anim == null || anim.isCompleted) {
        _shotsReady = true;
      } else {
        void listener(AnimationStatus status) {
          if (status == AnimationStatus.completed) {
            anim.removeStatusListener(listener);
            if (mounted) setState(() => _shotsReady = true);
          }
        }
        anim.addStatusListener(listener);
      }
    }
  }

  void _setStatus(String s) {
    final b = _bug;
    if (b == null) return;
    setState(() => b.status = s);
    AppState.I.saveBugs();
    AppState.I.touch();
  }

  BugItem? _deletedSnapshot;

  Future<void> _delete() async {
    final pal = context.pal;
    final ok = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => Container(
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 28),
        decoration: BoxDecoration(
          color: pal.bg,
          borderRadius:
              const BorderRadius.vertical(top: Radius.circular(28)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 38,
              height: 4,
              decoration: BoxDecoration(
                color: pal.cont2,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 18),
            Text('Удалить запись?',
                style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: pal.text)),
            const SizedBox(height: 18),
            PushButton(
              label: 'Удалить',
              icon: 'solar:trash-bin-2-bold',
              color: AppColors.red,
              onTap: () => Navigator.of(context).pop(true),
            ),
            const SizedBox(height: 8),
            GhostButton(
              label: 'Отменить',
              onTap: () => Navigator.of(context).pop(false),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;
    if (!mounted) return;
    // Схема без чёрного экрана при удалении:
    //   1) Берём снимок бага в _deletedSnapshot — чтобы build()
    //      во время slide-back продолжил рисовать контент бага,
    //      а не пустой экран (бага в AppState.bugs уже нет).
    //   2) Попаем с анимацией — экран плавно уезжает вправо
      //      с видимым контентом.
    //   3) Только ПОСЛЕ анимации и popped — реально удаляем
    //      баг из AppState, и BugsScreen видит обновлённый список.
    final route = ModalRoute.of(context);
    setState(() {
      _deletedSnapshot = _bug;
    });
    Navigator.of(context).pop();
    final id = widget.id;
    route?.completed.then((_) {
      AppState.I.bugs.removeWhere((e) => e.id == id);
      AppState.I.saveBugs();
      AppState.I.touch();
    });
  }

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    // Во время reverse-анимации после удаления берём snapshot—
    // AppState.bugs уже без этого бага, но экрану нужен фоллбэк
    // чтобы рисовать именно его, а не пустой placeholder.
    final bug = _bug ?? _deletedSnapshot;
    if (bug == null) {
      return Scaffold(
        backgroundColor: pal.bg,
        body: const Stack(
          children: [
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: TopFadeHeader(title: 'Детали'),
            ),
          ],
        ),
      );
    }
    final kind = kKindMeta[bug.kind] ?? kKindMeta['other']!;
    final pri = kPriMeta[bug.priority] ?? kPriMeta['med']!;
    final type = kTypeMeta[bug.type] ?? kTypeMeta['bug']!;

    // Баг n7850 (повторение для экрана деталей с инлайн-редактированием):
    // resize=false + kb-инсет уходит в bottom padding скролл-вью. Это
    // делает закрытие клавиатуры плавным, без скачкообразного «опускания»
    // содержимого.
    final viewInsetBottom = MediaQuery.of(context).viewInsets.bottom;
    return Scaffold(
      backgroundColor: pal.bg,
      resizeToAvoidBottomInset: false,
      body: Stack(
        children: [
          Positioned.fill(
            child: SingleChildScrollView(
              padding: EdgeInsets.only(
                top: MediaQuery.of(context).padding.top + kTopHeaderBarHeight,
                bottom: 32 + viewInsetBottom,
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [

              // Hero card with type icon + title + #id · timeAgo
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: pal.cont,
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 56,
                      height: 56,
                      decoration: BoxDecoration(
                        // Цвет миниатюры в открытой карточке должен совпадать
                        // с цветом миниатюры в списке багов — используем общий
                        // детерминированный hash-цвет (`bugThumbColor`), а не
                        // `type.color` (тот всегда красный/синий, из-за этого
                        // в списке зелёный, а в деталях красный — баг n7979).
                        color: bugThumbColor(bug),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      alignment: Alignment.center,
                      child: Iconify(type.icon,
                          size: 26, color: Colors.white),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            bug.title.isEmpty ? '—' : bug.title,
                            style: TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w700,
                              color: pal.text,
                              letterSpacing: -.2,
                              height: 1.2,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 4),
                          Row(children: [
                            Text(
                              '#${bug.id.substring(bug.id.length - 4)}',
                              style: TextStyle(
                                  fontSize: 12, color: pal.sub),
                            ),
                            const SizedBox(width: 6),
                            Container(
                              width: 2.5,
                              height: 2.5,
                              decoration: BoxDecoration(
                                color: pal.sub.withValues(alpha: 0.5),
                                borderRadius: BorderRadius.circular(99),
                              ),
                            ),
                            const SizedBox(width: 6),
                            Text(timeAgo(bug.createdAtMs),
                                style: TextStyle(
                                    fontSize: 12, color: pal.sub)),
                          ]),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),

              // Tags row: priority / kind / type
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  _BdTag(
                      label: pri.label,
                      color: pri.color,
                      icon: 'solar:flag-bold'),
                  _BdTag(
                      label: kind.label,
                      color: kind.color,
                      icon: kind.icon),
                  _BdTag(
                      label: type.label,
                      color: type.color,
                      icon: type.icon),
                ],
              ),
              const SizedBox(height: 16),

              // Status row
              const FormLabel('Статус',
                  padding: EdgeInsets.only(left: 4, bottom: 8, top: 4)),
              Row(children: [
                _BdStBtn(
                    label: 'Открыт',
                    dot: AppColors.orange,
                    active: bug.status == 'open',
                    onTap: () => _setStatus('open')),
                const SizedBox(width: 8),
                _BdStBtn(
                    label: 'В работе',
                    dot: AppColors.blue,
                    active: bug.status == 'prog',
                    onTap: () => _setStatus('prog')),
                const SizedBox(width: 8),
                _BdStBtn(
                    label: 'Закрыт',
                    dot: AppColors.green,
                    active: bug.status == 'done',
                    onTap: () => _setStatus('done')),
              ]),

              if (bug.description.isNotEmpty) ...[
                const FormLabel('Описание'),
                _Block(child: Text(bug.description,
                    style: TextStyle(
                        fontSize: 14, color: pal.text, height: 1.5))),
              ],

              if (bug.steps.isNotEmpty) ...[
                const FormLabel('Шаги воспроизведения'),
                _Block(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (var i = 0; i < bug.steps.length; i++)
                        Padding(
                          padding: EdgeInsets.only(
                              bottom: i == bug.steps.length - 1 ? 0 : 8),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Container(
                                width: 22,
                                height: 22,
                                decoration: BoxDecoration(
                                  color: AppColors.accent,
                                  borderRadius: BorderRadius.circular(99),
                                ),
                                alignment: Alignment.center,
                                child: Text('${i + 1}',
                                    style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 11,
                                        fontWeight: FontWeight.w700)),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Padding(
                                  padding: const EdgeInsets.only(top: 2),
                                  child: Text(bug.steps[i].text,
                                      style: TextStyle(
                                          color: pal.text,
                                          fontSize: 14,
                                          height: 1.4)),
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ],

              if (bug.shots.isNotEmpty) ...[
                const FormLabel('Скриншоты'),
                _BdShotsGrid(bug: bug, shotsReady: _shotsReady),
              ],

              if (bug.labels.isNotEmpty) ...[
                const FormLabel('Метки'),
                Wrap(spacing: 6, runSpacing: 6, children: [
                  for (final l in bug.labels)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: AppColors.accent.withValues(alpha: 0.18),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(l,
                          style: TextStyle(
                              color: AppColors.accent,
                              fontSize: 12,
                              fontWeight: FontWeight.w600)),
                    ),
                ]),
              ],
              const SizedBox(height: 22),
                  ],
                ),
              ),
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: TopFadeHeader(title: 'Детали', trailing: [
              // Размеры иконок-действий выравнены с разделом «Баги»
              // (там «Скачать архив» / «+» — 24/38 и 28/38). Раньше
              // было 20/36 — выглядело заметно мельче.
              IconBtn(
                icon: 'solar:settings-bold',
                iconSize: 24,
                size: 38,
                onTap: () => pushSlide(context, BugMetaScreen(bug: bug))
                    .then((_) => setState(() {})),
              ),
              IconBtn(
                icon: 'solar:trash-bin-trash-linear',
                iconSize: 24,
                size: 38,
                color: AppColors.red,
                onTap: _delete,
              ),
            ]),
          ),
        ],
      ),
    );
  }
}

class _Block extends StatelessWidget {
  final Widget child;
  const _Block({required this.child});
  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: pal.cont,
        borderRadius: BorderRadius.circular(14),
      ),
      child: child,
    );
  }
}

class _BdTag extends StatelessWidget {
  final String label;
  final Color color;
  final String icon;
  const _BdTag(
      {required this.label, required this.color, required this.icon});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Iconify(icon, size: 13, color: color),
          const SizedBox(width: 5),
          Text(label.toUpperCase(),
              style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: color,
                  letterSpacing: .3)),
        ],
      ),
    );
  }
}

class _BdStBtn extends StatelessWidget {
  final String label;
  final Color dot;
  final bool active;
  final VoidCallback onTap;
  const _BdStBtn({
    required this.label,
    required this.dot,
    required this.active,
    required this.onTap,
  });
  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    return Expanded(
      child: PressScale(
        onTap: onTap,
        scale: 0.97,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
          decoration: BoxDecoration(
            color: pal.cont,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: active ? AppColors.accent : Colors.transparent,
              width: 1.5,
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: dot,
                  borderRadius: BorderRadius.circular(99),
                ),
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(label,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: pal.text)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Сетка скриншотов в деталях бага.
///
/// Логика отображения:
///   1. Пока экран ещё не «доехал» (slide-in анимация) — рисуем placeholder
///      по высоте сетки (без скриншотов и без спиннера, чтобы не оттягивать
///      внимание во время самой анимации).
///   2. Когда [shotsReady]=true — стартуем фоновое прекеширование всех
///      картинок через `precacheImage` (декод идёт асинхронно, по очереди
///      между скринами `Future.delayed(Duration.zero)` отдаёт UI-треду
///      кадры). В это время по центру сетки крутится ОДНО круглое кольцо.
///   3. Когда все картинки декодированы — сетка появляется одним общим
///      fade-in'ом через TweenAnimationBuilder, и каждый _Thumb рисуется
///      простым Hero + `Image.memory` (как в v45 — без миганий).
class _BdShotsGrid extends StatefulWidget {
  final BugItem bug;
  final bool shotsReady;
  const _BdShotsGrid({required this.bug, required this.shotsReady});
  @override
  State<_BdShotsGrid> createState() => _BdShotsGridState();
}

class _BdShotsGridState extends State<_BdShotsGrid> {
  bool _started = false;
  bool _allLoaded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _maybeStart();
  }

  @override
  void didUpdateWidget(_BdShotsGrid old) {
    super.didUpdateWidget(old);
    if (widget.shotsReady && !old.shotsReady) _maybeStart();
  }

  void _maybeStart() {
    if (_started || !widget.shotsReady) return;
    _started = true;
    _precacheAll();
  }

  /// Прекешируем картинки по очереди, чтобы декод не вылазил бурстом
  /// на GPU и UI оставался отзывчивым. Между скринами — `Future.delayed`
  /// (Duration.zero) отдаёт управление event-loop'у Flutter'а.
  Future<void> _precacheAll() async {
    final shots = widget.bug.shots;
    for (var i = 0; i < shots.length; i++) {
      if (!mounted) return;
      try {
        await precacheImage(MemoryImage(shots[i]), context);
      } catch (_) {
        // если декод упал — пропускаем, всё равно покажем сетку.
      }
      // yield event-loop'у — иначе всё это превращается в один тяжёлый кадр.
      await Future<void>.delayed(Duration.zero);
    }
    if (mounted) setState(() => _allLoaded = true);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (ctx, c) {
        const cols = 3;
        const gap = 6.0;
        final size = (c.maxWidth - gap * (cols - 1)) / cols;
        final rows = (widget.bug.shots.length / cols).ceil();
        final gridHeight = rows * size + (rows - 1).clamp(0, 100) * gap;

        if (!_allLoaded) {
          // Placeholder с одним кольцом по центру — не рисуем сами скрины.
          // Высота примерно как у будущей сетки (минимум одна строка),
          // чтобы layout не «прыгал» при появлении картинок.
          final h = gridHeight.clamp(size, double.infinity).toDouble();
          return SizedBox(
            width: c.maxWidth,
            height: h,
            child: Center(
              child: SizedBox(
                width: 38,
                height: 38,
                // Акцентный цвет (как везде в приложении), потолще,
                // скруглённые концы — чтоб смотрелось аккуратнее.
                child: CircularProgressIndicator(
                  strokeWidth: 3.2,
                  strokeCap: StrokeCap.round,
                  valueColor: AlwaysStoppedAnimation<Color>(
                    AppColors.accent,
                  ),
                ),
              ),
            ),
          );
        }

        // Все картинки в кеше — собираем сетку и плавно проявляем её
        // одной общей анимацией. Внутренние _Thumb'ы простые, без
        // собственных fade/спиннеров (как в v45) — это убирает
        // мигания при тапе.
        return TweenAnimationBuilder<double>(
          tween: Tween<double>(begin: 0.0, end: 1.0),
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOutCubic,
          builder: (_, value, child) => Opacity(opacity: value, child: child),
          child: Wrap(
            spacing: gap,
            runSpacing: gap,
            children: [
              for (var i = 0; i < widget.bug.shots.length; i++)
                _Thumb(
                  bug: widget.bug,
                  index: i,
                  heroTag: 'bug_${widget.bug.id}_shot_$i',
                  side: size,
                ),
            ],
          ),
        );
      },
    );
  }
}

/// Тамбнейл скриншота — простой v45-стиль: Hero + Image.memory, без
/// спиннеров, без AnimatedOpacity, без Stack. Никаких миганий по тапу.
class _Thumb extends StatelessWidget {
  final BugItem bug;
  final int index;
  final String heroTag;
  final double side;
  const _Thumb({
    required this.bug,
    required this.index,
    required this.heroTag,
    required this.side,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        Navigator.of(context).push(
          ShotsViewerRoute(
            shots: bug.shots,
            initialIndex: index,
            heroTagBuilder: (i) =>
                'bug_${heroTag.split('_shot_').first.split('_').last}_shot_$i',
          ),
        );
      },
      child: Hero(
        tag: heroTag,
        createRectTween: (a, b) => RectTween(begin: a, end: b),
        // Билдим внутренний Image ОДИН раз на весь flight и передаём
        // его через AnimatedBuilder.child — Image+MemoryImage не
        // пересбираются на каждый кадр полёта (это давало flicker в v51).
        // Меняется только радиус ClipRRect.
        flightShuttleBuilder: (_, anim, dir, __, ___) {
          final imgChild = Image.memory(
            bug.shots[index],
            fit: BoxFit.cover,
            filterQuality: FilterQuality.medium,
            gaplessPlayback: true,
          );
          return AnimatedBuilder(
            animation: anim,
            child: imgChild,
            builder: (_, child) {
              final r = 10 + (18 - 10) * anim.value;
              return ClipRRect(
                borderRadius: BorderRadius.circular(r),
                child: child,
              );
            },
          );
        },
        child: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Image.memory(
            bug.shots[index],
            width: side,
            height: side,
            fit: BoxFit.cover,
            filterQuality: FilterQuality.medium,
            gaplessPlayback: true,
          ),
        ),
      ),
    );
  }
}

class _RoundedShot extends StatelessWidget {
  final Uint8List bytes;
  final BoxFit fit;
  final double radius;
  const _RoundedShot({
    required this.bytes,
    required this.fit,
    required this.radius,
  });
  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: Image.memory(
        bytes,
        fit: fit,
        filterQuality: FilterQuality.medium,
        gaplessPlayback: true,
      ),
    );
  }
}

/// Кастомный маршрут для просмотра скринов:
/// — opaque:false → нижний экран остаётся на месте под просмотром.
/// — NoSlideOnPush → SlideRoute родителя НЕ запускает свою secondary
///   анимацию (иначе экран багов уезжал бы влево, а при закрытии
///   возвращался бы сбоку — то самое «выдвижение», которое user видел).
/// — barrierColor:null → затемнение рисуем сами в виджете, чтобы
///   управлять им и при свайпе тоже.
/// — без transitionsBuilder, чтобы не было паразитной fade/scale —
///   за «появление» отвечает Hero (миниатюра → полный экран) и наш
///   собственный backdrop, который завязан на route.animation.
class ShotsViewerRoute<T> extends PageRoute<T> with NoSlideOnPush {
  final List<Uint8List> shots;
  final int initialIndex;
  final String Function(int index) heroTagBuilder;

  ShotsViewerRoute({
    required this.shots,
    required this.initialIndex,
    required this.heroTagBuilder,
  });

  @override
  Color? get barrierColor => null;
  @override
  bool get barrierDismissible => false;
  @override
  String? get barrierLabel => null;
  @override
  bool get opaque => false;
  @override
  bool get maintainState => true;
  @override
  Duration get transitionDuration => const Duration(milliseconds: 390);
  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 360);

  @override
  Widget buildPage(BuildContext context, Animation<double> animation,
      Animation<double> secondaryAnimation) {
    return ShotsViewer(
      shots: shots,
      initialIndex: initialIndex,
      heroTagBuilder: heroTagBuilder,
      routeAnimation: animation,
    );
  }

  @override
  Widget buildTransitions(BuildContext context, Animation<double> animation,
      Animation<double> secondaryAnimation, Widget child) {
    // Никакой обёрточной анимации — Hero и наш Stack сами всё рисуют.
    return child;
  }
}

/// Полноэкранный плавный просмотр скриншотов:
/// — Hero-перелёт из миниатюры с сохранением скруглённых углов
/// — PageView для свайпа между скринами
/// — drag вверх/вниз для закрытия с плавным «улётом» обратно
/// — Зум намеренно НЕ реализован (раньше был double-tap zoom через
///   InteractiveViewer — иногда конфликтовал с drag-to-close и свайпом
///   между страницами; по желанию юзера убран полностью).
class ShotsViewer extends StatefulWidget {
  final List<Uint8List> shots;
  final int initialIndex;
  final String Function(int index) heroTagBuilder;
  final Animation<double> routeAnimation;
  const ShotsViewer({
    super.key,
    required this.shots,
    required this.initialIndex,
    required this.heroTagBuilder,
    required this.routeAnimation,
  });
  @override
  State<ShotsViewer> createState() => _ShotsViewerState();
}

class _ShotsViewerState extends State<ShotsViewer>
    with TickerProviderStateMixin {
  late int _index = widget.initialIndex;
  late final PageController _pc =
      PageController(initialPage: widget.initialIndex);
  // ValueNotifier вместо обычного поля + setState — без него каждый
  // pixel движения пальца пересобирал бы всё дерево виджетов вьюера
  // (PageView, Hero, ColoredBox, счётчик и т.д.). Через notifier
  // перерисовывается только Transform-обёртка фотки, backdrop и счётчик
  // — PageView строится один раз и переиспользуется.
  final ValueNotifier<Offset> _dragV = ValueNotifier<Offset>(Offset.zero);

  // Отдельный контроллер прозрачности для счётчика «1 / N».
  //
  // Зависимости от `routeAnimation` нет — раньше из-за этого счётчик «мигал»
  // при открытии (статус-кадры между концом Hero-полёта и стартом своей
  // анимации). Теперь схема такая:
  //   • стартуем невидимыми и НЕ показываемся сами;
  //   • первое и каждое следующее листание — плавный fade-in (350мс)
  //     и таймер скрытия на 2 сек;
  //   • при закрытии вьюера (route reverse) — мгновенно дёргаем
  //     `_counterCtl.reverse()`, чтобы счётчик плавно растворялся
  //     синхронно с самим экраном.
  late final AnimationController _counterCtl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 350),
    reverseDuration: const Duration(milliseconds: 280),
  );
  Timer? _hideTimer;

  // Snap-back контроллер: после отпускания пальца плавно возвращает
  // _dragV в Offset.zero за 220мс по Curves.easeOutCubic.
  late final AnimationController _snapCtl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  );
  Offset _snapFrom = Offset.zero;

  @override
  void initState() {
    super.initState();
    // Слушаем закрытие route — на reverse гасим счётчик, чтобы он не висел
    // в кадре до конца fade-out экрана.
    widget.routeAnimation.addStatusListener(_onRouteStatus);
    _snapCtl.addListener(() {
      // value 0 → 1, easeOut по нему. Возвращаемся из _snapFrom в zero.
      final p = Curves.easeOutCubic.transform(_snapCtl.value);
      _dragV.value = Offset.lerp(_snapFrom, Offset.zero, p) ?? Offset.zero;
    });
  }

  void _onRouteStatus(AnimationStatus s) {
    if (s == AnimationStatus.reverse || s == AnimationStatus.dismissed) {
      _hideTimer?.cancel();
      if (_counterCtl.value > 0) _counterCtl.reverse();
    }
  }

  void _bumpVisibility() {
    if (!mounted) return;
    _hideTimer?.cancel();
    _counterCtl.forward();
    _hideTimer = Timer(const Duration(milliseconds: 2000), () {
      if (!mounted) return;
      _counterCtl.reverse();
    });
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    widget.routeAnimation.removeStatusListener(_onRouteStatus);
    _counterCtl.dispose();
    _snapCtl.dispose();
    _pc.dispose();
    _dragV.dispose();
    super.dispose();
  }

  void _close() => Navigator.of(context).maybePop();

  // Прогресс drag-смахивания 0..1 для затухания фона/масштаба фотки.
  double _dragProgress(Offset drag, Size size) =>
      (drag.dy.abs() / (size.height * 0.5)).clamp(0.0, 1.0);

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    // Прозрачный статус-бар поверх фотки + белые иконки, чтобы время и
    // процент батареи читались на тёмном фоне фотки. Никакого immersive
    // режима — ничего не прячем, ничего не восстанавливаем. Никаких
    // чёрных плашек.
    //
    // Структура: верхнеуровневый build НЕ зависит от _dragV — он
    // строится один раз. Все зависящие от drag-офсета слои обёрнуты в
    // ValueListenableBuilder, чтобы drag не дёргал rebuild дорогих
    // деревьев (PageView, Hero, Image.memory).
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarIconBrightness: Brightness.light,
      ),
      child: Scaffold(
      // Прозрачный Scaffold + полнопрозрачный backdrop ниже (см. Stack):
      // фон фактически рисует backdrop с opacity = routeAnimation.value
      // (а на свайпе закрытия линейно гаснет вместе с (1-t)). Это даёт
      // мягкий fade-in при открытии и fade-out при свайпе вниз.
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          // backdrop — плавный чёрный.
          // opacity = curve(routeAnimation.value) * (1 - t):
          //   • forward (открытие): 0 → 1 за transitionDuration с
          //     Curves.easeInOutCubic.
          //   • completed: 1.0.
          //   • reverse (системный «назад»): 1 → 0 — плавно гаснет.
          //   • drag-down (свайп закрытия): домножается на (1-t).
          Positioned.fill(
            child: ValueListenableBuilder<Offset>(
              valueListenable: _dragV,
              builder: (_, drag, __) {
                final t = _dragProgress(drag, size);
                return AnimatedBuilder(
                  animation: widget.routeAnimation,
                  builder: (_, __) {
                    final eased = Curves.easeInOutCubic
                        .transform(widget.routeAnimation.value);
                    final dim = (eased * (1 - t)).clamp(0.0, 1.0);
                    return IgnorePointer(
                      child: ColoredBox(
                        color: Colors.black.withValues(alpha: dim),
                      ),
                    );
                  },
                );
              },
            ),
          ),
          // PageView со скринами + жесты свайпа на закрытие.
          // PageView строится один раз и кэшируется как `child`
          // ValueListenableBuilder'a — на каждый кадр drag'a меняется
          // только Transform-матрица.
          //
          // Зум убран полностью — остался только drag-to-close + свайпы
          // между фотками внутри PageView.
          ValueListenableBuilder<Offset>(
            valueListenable: _dragV,
            child: PageView.builder(
              controller: _pc,
              itemCount: widget.shots.length,
              onPageChanged: (i) {
                setState(() => _index = i);
                // Каждое листание — снова показываем счётчик и
                // перезапускаем таймер скрытия.
                _bumpVisibility();
              },
              itemBuilder: (_, i) {
                // Полноэкранный режим: скрин занимает весь экран. Углы
                // остаются скруглёнными (радиус 18) — во время Hero-полёта
                // плавно интерполируются 10 → 18, чтобы переход с миниатюры
                // был без скачка радиуса.
                //
                // ВАЖНО: и shuttle, и destination используют ТОТ ЖЕ
                // Image-instance, переданный через AnimatedBuilder.child,
                // чтобы Image-widget на каждый кадр полёта НЕ переподписывался
                // на ImageStream и не было визуального флика на стыке кадров.
                return Hero(
                  tag: widget.heroTagBuilder(i),
                  createRectTween: (a, b) => RectTween(begin: a, end: b),
                  flightShuttleBuilder: (_, anim, dir, __, ___) {
                    final imgChild = Image.memory(
                      widget.shots[i],
                      fit: BoxFit.cover,
                      filterQuality: FilterQuality.medium,
                      gaplessPlayback: true,
                    );
                    return AnimatedBuilder(
                      animation: anim,
                      child: imgChild,
                      builder: (_, child) {
                        final r = 10 + (18 - 10) * anim.value;
                        return ClipRRect(
                          borderRadius: BorderRadius.circular(r),
                          child: child,
                        );
                      },
                    );
                  },
                  child: _RoundedShot(
                    bytes: widget.shots[i],
                    fit: BoxFit.cover,
                    radius: 18,
                  ),
                );
              },
            ),
            builder: (_, drag, child) {
              // Чистый Transform — без AnimatedContainer и его
              // BoxDecorationTween/Matrix4Tween-пайплайна, который
              // на каждый кадр пальца аллоцировал лишние объекты и
              // давал «рывки за пальцем». Тут transform применяется
              // напрямую, фотка следует за пальцем 1-в-1.
              final dy = drag.dy;
              final t = _dragProgress(drag, size);
              final scale = 1 - t * 0.16;
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onVerticalDragStart: (_) {
                  // Останавливаем snap-back, если он ещё идёт от прошлого
                  // отпускания, и сбрасываем drag в ноль.
                  _snapCtl.stop();
                  _dragV.value = Offset.zero;
                },
                onVerticalDragUpdate: (d) {
                  _dragV.value += Offset(0, d.delta.dy);
                },
                onVerticalDragEnd: (d) {
                  final velocity = d.primaryVelocity ?? 0;
                  if (_dragV.value.dy.abs() > size.height * 0.18 ||
                      velocity.abs() > 1200) {
                    _close();
                  } else {
                    // Snap-back: плавно возвращаем фотку из текущего offset'a
                    // в Offset.zero за 220мс через AnimationController.
                    _snapFrom = _dragV.value;
                    _snapCtl.forward(from: 0);
                  }
                },
                onVerticalDragCancel: () {
                  _snapFrom = _dragV.value;
                  _snapCtl.forward(from: 0);
                },
                child: Transform(
                  transform: Matrix4.identity()
                    ..translate(0.0, dy)
                    ..scale(scale, scale),
                  alignment: Alignment.center,
                  child: child,
                ),
              );
            },
          ),
          // Счётчик скриншотов сверху по центру.
          //
          // Логика прозрачности теперь полностью независима от
          // `routeAnimation` (раньше из-за этого счётчик «мигал» —
          // между концом Hero-полёта и стартом своего fade происходила
          // пара кадров с opacity = 0). Сейчас:
          //   • стартуем невидимыми;
          //   • через 1.2 сек после открытия — плавный fade-in (350мс);
          //   • при каждом листании — снова показываем и перезапускаем
          //     таймер скрытия;
          //   • через 2 сек простоя — плавный fade-out (280мс).
          // На свайпе закрытия дополнительно домножаем на (1-t), чтобы
          // счётчик плавно растворялся вместе с фоном.
          if (widget.shots.length > 1)
            Positioned(
              top: MediaQuery.of(context).viewPadding.top + 8,
              left: 0,
              right: 0,
              child: IgnorePointer(
                child: ValueListenableBuilder<Offset>(
                  valueListenable: _dragV,
                  child: Center(
                    child: _ViewerPill(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 8),
                      circle: false,
                      child: Text(
                        '${_index + 1} / ${widget.shots.length}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                  builder: (_, drag, child) {
                    final t = _dragProgress(drag, size);
                    return AnimatedBuilder(
                      animation: _counterCtl,
                      builder: (_, __) {
                        final op = (_counterCtl.value * (1 - t))
                            .clamp(0.0, 1.0);
                        if (op == 0) return const SizedBox.shrink();
                        return Opacity(opacity: op, child: child);
                      },
                    );
                  },
                ),
              ),
            ),
        ],
      ),
      ),
    );
  }
}

class _ViewerPill extends StatelessWidget {
  final Widget child;
  final EdgeInsets? padding;
  final bool circle;
  const _ViewerPill({
    required this.child,
    this.padding,
    this.circle = true,
  });
  @override
  Widget build(BuildContext context) {
    return Container(
      width: circle ? 38 : null,
      height: circle ? 38 : null,
      padding: padding,
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        shape: circle ? BoxShape.circle : BoxShape.rectangle,
        borderRadius: circle ? null : BorderRadius.circular(20),
      ),
      alignment: circle ? Alignment.center : null,
      child: child,
    );
  }
}


