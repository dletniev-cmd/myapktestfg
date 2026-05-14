import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../widgets/m3_loading.dart';

import '../api.dart';
import '../iconify.dart';
import '../navigation.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/long_press_menu.dart';
import 'actions_archive.dart' show downloadAndShareArtifact;
import 'run_detail.dart';

/// Actions экран — 1:1 с HTML версией.
class ActionsScreen extends StatefulWidget {
  const ActionsScreen({super.key});
  @override
  State<ActionsScreen> createState() => _ActionsScreenState();
}

/// Глобальный «pulse»-тикер для лейблов времени (5с назад, 3м назад,
/// elapsed «12:34» и т.п.). Один Timer на всё приложение, инкрементит
/// ValueNotifier раз в секунду. Лейблы подписываются через
/// [ValueListenableBuilder] и ребилдят ТОЛЬКО себя, а не весь экран
/// Actions. Раньше тут крутился `Timer.periodic(1s, () => setState(){})`
/// в `_ActionsScreenState` — он каждую секунду пере-сoбирал ВЕСЬ
/// ListView, что и было самой жирной причиной лагов скролла в Actions.
final ValueNotifier<int> _liveSecondTick = ValueNotifier<int>(0);
Timer? _liveSecondTimer;
int _liveSecondSubs = 0;
void _attachLiveTick() {
  _liveSecondSubs++;
  _liveSecondTimer ??=
      Timer.periodic(const Duration(seconds: 1), (_) {
    _liveSecondTick.value++;
  });
}

void _detachLiveTick() {
  _liveSecondSubs--;
  if (_liveSecondSubs <= 0) {
    _liveSecondTimer?.cancel();
    _liveSecondTimer = null;
    _liveSecondSubs = 0;
  }
}

class _ActionsScreenState extends State<ActionsScreen>
    with TickerProviderStateMixin {
  bool _loading = false;
  // _manualLoading == true только пока идёт рефреш, запущенный самим
  // пользователем через тап по кнопке. Фоновый таймер (каждые 4с) «тихий» —
  // в этом случае заголовок/статус НЕ показывают «Обновление…». Юзер
  // просил явно: «сделай чтобы писало обновление только при нажатии на
  // кнопку. Обновление по факту идёт в фоне, каждые 4 секунды».
  bool _manualLoading = false;
  String? _error;
  List<GhRun> _runs = [];
  String _filter = 'all';
  Timer? _autoRefresh;
  // Время последнего УСПЕШНОГО фонового запроса к API — от этого момента
  // отсчитывается «Обновлено Nс назад» в статусе _LiveHead. Раньше
  // мы отнимали время от updatedAt первого рана, но это неправильно:
  // updatedAt обновляется НЕ на каждый полл GitHub'ом (он меняется только
  // при реальных изменениях рана), и «Nс назад» мог неожиданно прыгать на «15»
  // вместо «4». Теперь берём точное время нашего полла.
  DateTime? _lastFetchAt;
  double _headerH = 0;

  // Срез AppState, на который Actions реально реагирует. Без этого
  // на любое `notifyListeners()` (заливки, build-poller, кэши) экран
  // безусловно ребилдился. Теперь — только когда меняется активный
  // репо или кэш ранов из фонового поллера.
  String? _lastActiveRepoFull;
  int _lastCachedRunsId = -1;

  @override
  void initState() {
    super.initState();
    _captureSnapshot();
    AppState.I.addListener(_onState);
    _attachLiveTick();
    _restoreCache();
    // Юзер: «при первом заходе статус „обновлено сек назад“ почему-то
    // не виден, видна только точка рядом.. а потом резко чото
    // появляется, экран дёргается». Причина была в том, что
    // _lastFetchAt при первом монтировании был null, _agoParts()
    // возвращал null, и весь блок «обновлено N с назад» был свёрнут
    // в SizedBox.shrink. Когда первый _refresh завершался, блок
    // внезапно появлялся и вызывал layout-jolt.
    //
    // Чиним просто: при монтировании сразу проставляем _lastFetchAt
    // = now. Тогда с первого же кадра в шапке стоит «обновлено 0с
    // назад», layout стабильный, дальнейшее обновление поля только
    // двигает счётчик секунд — никаких внезапных появлений блока.
    _lastFetchAt = DateTime.now();
    _refresh();
    _autoRefresh =
        Timer.periodic(const Duration(seconds: 4), (_) => _refresh());
  }

  void _captureSnapshot() {
    _lastActiveRepoFull = AppState.I.activeRepo?.fullName;
    _lastCachedRunsId = identityHashCode(AppState.I.cachedRuns);
  }

  void _restoreCache() {
    final repo = AppState.I.activeRepo;
    if (repo != null &&
        AppState.I.cachedRuns != null &&
        AppState.I.cachedRunsRepo == repo.fullName) {
      _runs = AppState.I.cachedRuns!;
    }
  }

  @override
  void dispose() {
    AppState.I.removeListener(_onState);
    _detachLiveTick();
    _autoRefresh?.cancel();
    super.dispose();
  }

  void _onState() {
    final newActive = AppState.I.activeRepo?.fullName;
    final newRunsId = identityHashCode(AppState.I.cachedRuns);
    if (newActive != _lastActiveRepoFull || newRunsId != _lastCachedRunsId) {
      _lastActiveRepoFull = newActive;
      _lastCachedRunsId = newRunsId;
      // Если фоновой поллер обновил cachedRuns — подтягиваем их в
      // локальный _runs, иначе экран рисует устаревший снимок.
      if (newActive != null &&
          AppState.I.cachedRunsRepo == newActive &&
          AppState.I.cachedRuns != null) {
        _runs = AppState.I.cachedRuns!;
      }
      if (mounted) setState(() {});
    }
  }

  /// `manual=true` — рефреш запущен по тапу пользователя по кнопке,
  /// в этом случае показываем «Обновление…» в заголовке и во время
  /// запроса крутим spinner на кнопке. По дефолту (`manual=false`) —
  /// фоновый полл таймером, в UI он НИКАК не виден (юзерское
  /// требование).
  Future<void> _refresh({bool manual = false}) async {
    final api = AppState.I.api;
    final repo = AppState.I.activeRepo;
    if (api == null || repo == null) return;
    setState(() {
      _loading = true;
      if (manual) {
        _manualLoading = true;
      }
    });
    // На быстром интернете GitHub отвечает за 100-200ms. Если просто
    // снять «Обновление…» сразу после возврата API — заголовок
    // моргнёт «Идёт сборка → Обновление… → Идёт сборка» за полсекунды,
    // что выглядит как баг (юзер: «при нажатии на кнопку обновить,
    // надпись меняется на обновление, а потом резко почему-то
    // выскакивает назад»). Поэтому для manual=true гарантируем, что
    // «Обновление…» провисит минимум 700ms — достаточно, чтобы
    // пользователь успел его прочитать и понять, что обновление
    // действительно запустилось.
    final Future<void>? minHold = manual
        ? Future<void>.delayed(const Duration(milliseconds: 700))
        : null;
    try {
      // Лимит 20 последних запусков — по просьбе пользователя. Раньше
      // тянулось дефолтно 30, на «болтливых» репо длинный список бил
      // по скроллу из-за десятков _RunCard'ов в памяти.
      final runs = await api.workflowRuns(repo.fullName, perPage: 20);
      if (!mounted) return;
      // Сначала отдаём список трекеру — он сравнит со снимком и при
      // необходимости пришлёт уведомления о смене статуса. И только
      // потом обновляем cachedRuns (иначе трекер не увидит «дельты»).
      AppState.I.observeRuns(runs, repoFullName: repo.fullName);
      // Применяем данные сразу (карточки могут перестроиться), а
      // флаг manualLoading снимаем уже после minHold ниже — чтобы
      // заголовок «Обновление…» подержался корректное время.
      setState(() {
        _runs = runs;
        _loading = false;
        _error = null;
        _lastFetchAt = DateTime.now();
      });
      AppState.I.cachedRuns = runs;
      AppState.I.cachedRunsRepo = repo.fullName;
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    } finally {
      if (minHold != null) await minHold;
      if (mounted && _manualLoading) {
        setState(() => _manualLoading = false);
      }
    }
  }

  List<GhRun> get _filtered {
    return _runs.where((r) {
      switch (_filter) {
        case 'running':
          return r.status != 'completed';
        case 'success':
          return r.status == 'completed' && r.conclusion == 'success';
        case 'fail':
          return r.status == 'completed' &&
              r.conclusion.isNotEmpty &&
              r.conclusion != 'success';
        default:
          return true;
      }
    }).toList();
  }

  int _count(String f) => _runs.where((r) {
        switch (f) {
          case 'running':
            return r.status != 'completed';
          case 'success':
            return r.status == 'completed' && r.conclusion == 'success';
          case 'fail':
            return r.status == 'completed' &&
                r.conclusion.isNotEmpty &&
                r.conclusion != 'success';
          default:
            return true;
        }
      }).length;

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    final repo = AppState.I.activeRepo;
    final running = _runs.where((r) => r.status != 'completed').length;
    // Статус для индикатора-точки:
    //   error → красный, live → зелёный (есть активные сборки),
    //   working → акцент (ТОЛЬКО при ручном рефреше), idle → серый.
    // Раньше любой `_loading=true` (включая фоновый) переключал в working —
    // отсюда «постоянно мигающее Обновление». Теперь working только если
    // _manualLoading.
    final liveStatus = _error != null
        ? _LiveStatus.error
        : (_manualLoading
            ? _LiveStatus.working
            : (running > 0 ? _LiveStatus.live : _LiveStatus.idle));
    return Stack(
      children: [
        Positioned.fill(
          child: _buildList(pal, repo),
        ),
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: StickyTabHeader(
            onHeightChanged: (h) {
              if ((h - _headerH).abs() > 0.5) {
                setState(() => _headerH = h);
              }
            },
            children: [
              _LiveHead(
                status: liveStatus,
                running: running,
                lastFetchAt: _lastFetchAt,
                manualLoading: _manualLoading,
                // Кнопка обновления:
                //  * Не реагирует на фоновый _loading — тап доступен даже когда
                //    бэкграунд-полл в воздухе (иначе кнопка «зависла бы»
                //    каждые 4 сек).
                //  * Реагирует на _manualLoading — пока крутится spinner от
                //    нашего ручного тапа, повторно нажать нельзя.
                onRefresh: _manualLoading ? null : () => _refresh(manual: true),
              ),
              _ActionsFilter(
                filter: _filter,
                counts: {
                  'all': _count('all'),
                  'running': _count('running'),
                  'success': _count('success'),
                  'fail': _count('fail'),
                },
                onChanged: (f) => setState(() => _filter = f),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildList(AppPalette pal, GhRepo? repo) {
    // Карточки скроллятся ПОД sticky-шапкой (см. Positioned выше).
    // Верхний паддинг = измеренная высота шапки, чтобы первый элемент
    // не прятался под ней при scrollOffset = 0.
    final topPad = _headerH > 0
        ? _headerH
        : MediaQuery.of(context).padding.top + 100;
    final padding = EdgeInsets.fromLTRB(18, topPad, 18, 110);

    Widget wrap(Widget body) => ListView(
          physics: const BouncingScrollPhysics(),
          padding: padding,
          children: [body],
        );

    if (repo == null) {
      return wrap(_empty(pal,
          icon: 'solar:folder-with-files-bold',
          title: 'Не выбран репозиторий',
          sub: 'Выберите активный репо выше'));
    }
    if (_loading && _runs.isEmpty) {
      return wrap(Padding(
        padding: const EdgeInsets.only(top: 80),
        child: Center(
            child: M3LoadingIndicator(
                color: AppColors.accent, strokeCap: StrokeCap.round)),
      ));
    }
    if (_error != null && _runs.isEmpty) {
      return wrap(_empty(pal,
          icon: 'solar:close-circle-bold',
          title: 'Ошибка',
          sub: _error!));
    }
    final filtered = _filtered;
    if (filtered.isEmpty) {
      return wrap(_empty(pal,
          icon: 'solar:inbox-bold',
          title: _runs.isEmpty
              ? 'Запусков ещё не было'
              : 'Нет запусков с этим фильтром',
          sub: ''));
    }
    // Юзер (баг n8081): «убери ебучее плавное появление карточек!!! и
    // везде, где оно используется, убери его». Никаких AppearOnMount /
    // AppearGate — карточки появляются мгновенно при монтировании.
    return ListView.builder(
      physics: const BouncingScrollPhysics(),
      padding: padding,
      itemCount: filtered.length,
      itemBuilder: (_, i) {
        final run = filtered[i];
        // RepaintBoundary вокруг карточки рана — даже когда обновляется
        // живой meta-лейбл (раз в секунду), Flutter не будет
        // перерисовывать соседние карточки в списке.
        return RepaintBoundary(
          child: Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _RunCard(
              run: run,
              onTap: () => pushSlide(context, RunDetailScreen(run: run)),
              onRefresh: _refresh,
            ),
          ),
        );
      },
    );
  }

  Widget _empty(AppPalette pal,
      {required String icon,
      required String title,
      required String sub}) {
    return Padding(
      padding: const EdgeInsets.only(top: 60),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Iconify(icon, size: 56, color: pal.sub.withValues(alpha: 0.5)),
          const SizedBox(height: 12),
          Text(title,
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: pal.text,
                  fontSize: 16,
                  fontWeight: FontWeight.w600)),
          if (sub.isNotEmpty) ...[
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text(sub,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: pal.sub, fontSize: 13)),
            ),
          ],
        ],
      ),
    );
  }
}

enum _LiveStatus { live, working, error, idle }

class _LiveHead extends StatefulWidget {
  final _LiveStatus status;
  final int running;
  final DateTime? lastFetchAt;
  final bool manualLoading;
  final VoidCallback? onRefresh;
  const _LiveHead({
    required this.status,
    required this.running,
    required this.lastFetchAt,
    required this.manualLoading,
    required this.onRefresh,
  });
  @override
  State<_LiveHead> createState() => _LiveHeadState();
}

class _LiveHeadState extends State<_LiveHead>
    with SingleTickerProviderStateMixin {
  late final AnimationController _dotCtrl =
      AnimationController(vsync: this, duration: const Duration(seconds: 2))
        ..repeat(reverse: true);

  @override
  void didUpdateWidget(covariant _LiveHead old) {
    super.didUpdateWidget(old);
    final dur = widget.status == _LiveStatus.working
        ? const Duration(milliseconds: 1200)
        : const Duration(seconds: 2);
    if (_dotCtrl.duration != dur) {
      _dotCtrl.duration = dur;
      _dotCtrl
        ..reset()
        ..repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _dotCtrl.dispose();
    super.dispose();
  }

  Color _dotColor() {
    switch (widget.status) {
      case _LiveStatus.live:
        return const Color(0xFF34C759);
      case _LiveStatus.working:
        return AppColors.accent;
      case _LiveStatus.error:
        return const Color(0xFFFF6B6B);
      case _LiveStatus.idle:
        return const Color(0xFF8E8E93);
    }
  }

  /// Текст для БОЛЬШОГО заголовка слева сверху.
  /// «Обновление…» теперь появляется ТОЛЬКО при ручном тапе по
  /// кнопке (юзерское требование). Фоновый таймер каждые 4 секунды
  /// заголовок НЕ дёргает — он стабильно держится на «Идёт сборка»
  /// (если есть активные раны) или просто «Actions».
  String _titleText() {
    if (widget.status == _LiveStatus.error) return 'Ошибка';
    if (widget.manualLoading) return 'Обновление…';
    if (widget.running > 0) return 'Идёт сборка';
    return 'Actions';
  }

  /// Префикс статус-строки (всё кроме секундомера). Меняется редко —
  /// при смене статуса, а не каждую секунду.
  String _statusPrefix() {
    switch (widget.status) {
      case _LiveStatus.error:
        return 'Ошибка';
      case _LiveStatus.working:
        return 'Обновление…';
      case _LiveStatus.live:
        // Если активных сборок несколько — показываем счётчик. На
        // одной — обходимся зелёной точкой + «обновлено N с назад».
        if (widget.running > 1) return '${widget.running} активных • ';
        return '';
      case _LiveStatus.idle:
        return '';
    }
  }

  /// Динамический «обновлено N сек назад» — обновляется каждую секунду.
  /// Возвращает разбивку на три части:
  ///   prefix «обновлено » (никогда не меняется — статичный Text)
  ///   value «N»           (меняется каждую секунду — [RisingText])
  ///   suffix «с назад» (меняется редко при переходе сек/мин/час/дни)
  ///
  /// Раньше всё собиралось в одну строку и RisingText анимировали
  /// весь текст (юзер жаловался: ±анимируется аж весь текст, а
  /// надо только цифру»). Теперь разделяем части и выводим их
  /// отдельными виджетами в Row — визуально то же самое «obnovleno Nс
  /// nazad», но анимируется только цифра.
  ({String prefix, String value, String suffix})? _agoParts() {
    if (widget.status == _LiveStatus.error ||
        widget.status == _LiveStatus.working) {
      return null;
    }
    final last = widget.lastFetchAt;
    if (last == null) return null;
    final diff = DateTime.now().difference(last);
    final secs = diff.inSeconds;
    const prefix = 'обновлено ';
    if (secs < 60) {
      return (prefix: prefix, value: '$secs', suffix: 'с назад');
    }
    if (secs < 3600) {
      return (prefix: prefix, value: '${diff.inMinutes}', suffix: 'м назад');
    }
    if (secs < 86400) {
      return (prefix: prefix, value: '${diff.inHours}', suffix: 'ч назад');
    }
    return (prefix: prefix, value: '${diff.inDays}', suffix: 'д назад');
  }

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    final dotC = _dotColor();
    final pulse = widget.status == _LiveStatus.live ||
        widget.status == _LiveStatus.working;
    final subStyle = TextStyle(
      fontSize: 12.5,
      fontWeight: FontWeight.w500,
      color: pal.sub,
      // Tabular figures — все цифры одинаковой ширины. Без этого «9с»
      // → «10с» немного «шевелится» из-за пропорциональных глифов.
      fontFeatures: const [FontFeature.tabularFigures()],
      height: 1.2,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 4, 2, 18),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // БОЛЬШОЙ заголовок: Actions / Обновление… / Идёт
                // сборка / Ошибка.
                //
                // Раньше тут был AnimatedSwitcher с FadeTransition +
                // SizeTransition(axis: horizontal). На первом
                // build'е это давало неприятный «pop-in»: заголовок
                // рос от width=0, opacity=0 за 340ms — пользователь
                // видел только точку статуса, а сам тайтл «выскакивал»
                // спустя долю секунды. Юзер жаловался: «при первом
                // заходе зоголвка сначала нет, только точка эта, а
                // потом резко он появляется».
                //
                // Используем кастомный _FadeOnChangeText: первый рендер
                // моментальный (нет анимации), все следующие смены
                // строки плавно cross-fade'ятся без SizeTransition.
                // Никакого «pop-in», и горизонтальная ширина не
                // прыгает (текст просто переключается).
                _FadeOnChangeText(
                  text: _titleText(),
                  duration: const Duration(milliseconds: 220),
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -.4,
                    color: pal.text,
                    height: 1.15,
                  ),
                ),
                const SizedBox(height: 6),
                DefaultTextStyle.merge(
                  style: subStyle,
                  child: Row(children: [
                    AnimatedBuilder(
                      animation: _dotCtrl,
                      builder: (_, __) {
                        final t = _dotCtrl.value;
                        final scale = pulse ? 1 + .15 * t : 1.0;
                        final opacity = pulse ? .55 + .45 * t : .9;
                        return Opacity(
                          opacity: opacity,
                          child: Transform.scale(
                            scale: scale,
                            child: Container(
                              width: 6,
                              height: 6,
                              decoration: BoxDecoration(
                                color: dotC,
                                shape: BoxShape.circle,
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                    const SizedBox(width: 7),
                    // Префикс ("Обновление…" / "Ошибка" / "3 активных • ").
                    // Меняется редко. Тоже выводим через _FadeOnChangeText
                    // — первая строка появляется моментально, смены
                    // плавно cross-fade'ятся без SizeTransition.
                    if (_statusPrefix().isNotEmpty)
                      _FadeOnChangeText(
                        text: _statusPrefix(),
                        duration: const Duration(milliseconds: 220),
                        style: subStyle,
                      ),
                    // Живой «обновлено Nс назад» — RisingText ребилдит
                    // только сам себя, тикает раз в секунду через
                    // глобальный _liveSecondTick, и каждый раз когда
                    // строка меняется (например «3с» → «4с») он
                    // плавно поднимает текст вверх + растворяет старый,
                    // и новый рождается снизу. Именно ту анимацию
                    // юзер просил: «одна уезжает вверх плавно
                    // растворяясь, в другая выкзет снизу тоже выходя
                    // из растворения, постепенно появляясь».
                    // «Обновлено Nс назад» разбито на три виджета:
                    //  * Статичный Text(«обновлено ») — не анимируется.
                    //  * RisingText(«N») — живо поднимает вверх
                    //    старую цифру и достаёт новую снизу по тикам
                    //    _liveSecondTick. ImpacthZ — только эта
                    //    часть ребилдится каждую секунду.
                    //  * RisingText(«с назад») — почти всегда
                    //    повторяет себя, анимирует только при переходе
                    //    с/м/ч/д (раз в минуту/час/сутки).
                    //
                    // Юзер жаловался: «анимируется аж весь текст, а надо
                    // только цифру!!» — именно это исправлено».
                    Flexible(
                      child: ValueListenableBuilder<int>(
                        valueListenable: _liveSecondTick,
                        builder: (_, __, ___) {
                          final parts = _agoParts();
                          if (parts == null) {
                            return const SizedBox.shrink();
                          }
                          return Row(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.baseline,
                            textBaseline: TextBaseline.alphabetic,
                            children: [
                              Text(parts.prefix, style: subStyle),
                              RisingText(
                                text: parts.value,
                                style: subStyle,
                              ),
                              const Text(' '),
                              RisingText(
                                text: parts.suffix,
                                style: subStyle,
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                  ]),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          // RotatingRefreshBtn с дефолтами (size=36, iconSize=22) —
          // ровно такие же размеры, как у кнопок в bugs.dart и
          // profile.dart (юзер просил «размеры иконок одинаковые»).
          // Spinner крутится ТОЛЬКО при ручном рефреше, фоновый
          // полл не подсвечивается (тоже юзерское требование).
          RotatingRefreshBtn(
            spinning: widget.manualLoading,
            onTap: widget.onRefresh,
          ),
        ],
      ),
    );
  }
}

class _ActionsFilter extends StatelessWidget {
  final String filter;
  final Map<String, int> counts;
  final ValueChanged<String> onChanged;
  const _ActionsFilter({
    required this.filter,
    required this.counts,
    required this.onChanged,
  });
  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    const items = [
      ['all', 'Все'],
      ['running', 'Активные'],
      ['success', 'Успех'],
      ['fail', 'Ошибки'],
    ];
    final activeIdx =
        items.indexWhere((it) => it[0] == filter).clamp(0, items.length - 1);
    const double pad = 4;
    const double height = 36;
    // Раньше использовался BackdropFilter — но он пересчитывал блюр
    // на каждый кадр при скролле списка под шапкой (баг n3159: «лаги в
    // плашках»). Теперь — полупрозрачный фон без runtime-блюра.
    final glassBg =
        pal.cont.withValues(alpha: pal.isDark ? 0.55 : 0.62);
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Container(
      padding: const EdgeInsets.all(pad),
      decoration: BoxDecoration(
        color: glassBg,
        borderRadius: BorderRadius.circular(12),
      ),
      clipBehavior: Clip.hardEdge,
      child: LayoutBuilder(builder: (ctx, c) {
        final tabW = c.maxWidth / items.length;
        return SizedBox(
          height: height,
          child: Stack(
            clipBehavior: Clip.hardEdge,
            children: [
              // Скользящая «пилюля» под активным табом — анимация как в навбаре.
              AnimatedPositioned(
                duration: const Duration(milliseconds: 320),
                curve: const Cubic(.32, .72, .00, 1),
                left: activeIdx * tabW,
                top: 0,
                width: tabW,
                height: height,
                child: Container(
                  decoration: BoxDecoration(
                    color: pal.cont2,
                    borderRadius: BorderRadius.circular(9),
                  ),
                ),
              ),
              Row(
                children: [
                  for (var i = 0; i < items.length; i++)
                    Expanded(
                      child: _FilterBtn(
                        label: items[i][1],
                        count: counts[items[i][0]] ?? 0,
                        active: filter == items[i][0],
                        onTap: () => onChanged(items[i][0]),
                      ),
                    ),
                ],
              ),
            ],
          ),
        );
      }),
      ),
    );
  }
}

class _FilterBtn extends StatelessWidget {
  final String label;
  final int count;
  final bool active;
  final VoidCallback onTap;
  const _FilterBtn({
    required this.label,
    required this.count,
    required this.active,
    required this.onTap,
  });
  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: SizedBox.expand(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Flexible(
                child: AnimatedDefaultTextStyle(
                  duration: const Duration(milliseconds: 220),
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: active ? pal.text : pal.sub,
                  ),
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              const SizedBox(width: 5),
              AnimatedContainer(
                duration: const Duration(milliseconds: 220),
                padding: const EdgeInsets.symmetric(
                    horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: active ? AppColors.accent : pal.cont2,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '$count',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: active ? Colors.white : pal.sub,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RunCard extends StatefulWidget {
  final GhRun run;
  final VoidCallback onTap;
  final VoidCallback onRefresh;
  const _RunCard(
      {required this.run, required this.onTap, required this.onRefresh});
  @override
  State<_RunCard> createState() => _RunCardState();
}

class _RunCardState extends State<_RunCard> {
  bool _downloadingApk = false;
  double _dlProgress = 0;
  DownloadTask? _task;

  @override
  void initState() {
    super.initState();
    // Если для этого run-а уже идёт загрузка APK (например, мы выходили
    // в детали или другой таб и вернулись), сразу подхватим задачу из
    // глобального стейта и подпишемся на её прогресс — иначе кнопка
    // показывала бы «Скачать APK», хотя загрузка ещё бежит.
    _attachExistingTask();
  }

  void _attachExistingTask() {
    final apkId = AppState.I.runApkArtifactId[widget.run.id];
    if (apkId == null) return;
    final task = AppState.I.activeDownloads[apkId];
    if (task == null) return;
    _listenTask(task);
    _downloadingApk = task.busy;
    _dlProgress = task.progress;
  }

  void _listenTask(DownloadTask t) {
    _task?.removeListener(_onTask);
    _task = t;
    _task!.addListener(_onTask);
  }

  void _onTask() {
    if (!mounted) return;
    setState(() {
      _downloadingApk = _task?.busy ?? false;
      _dlProgress = _task?.progress ?? 0;
    });
  }

  @override
  void dispose() {
    _task?.removeListener(_onTask);
    super.dispose();
  }

  Future<void> _downloadApk(BuildContext context) async {
    final api = AppState.I.api;
    final repo = AppState.I.activeRepo;
    if (api == null || repo == null) return;
    setState(() {
      _downloadingApk = true;
      _dlProgress = 0;
    });
    try {
      final arts = await api.runArtifacts(repo.fullName, widget.run.id);
      if (arts.isEmpty) {
        if (mounted) setState(() => _downloadingApk = false);
        return;
      }
      final apk = arts.firstWhere(
          (a) => a.name.toLowerCase().contains('apk'),
          orElse: () => arts.first);
      if (!context.mounted) return;
      // Запоминаем артефакт глобально — следующий _RunCardState (после
      // ухода/возврата в этот экран) сможет мгновенно подхватить задачу.
      AppState.I.runApkArtifactId[widget.run.id] = apk.id;
      // Если задача уже идёт (например, начата с экрана деталей) — сразу
      // подписываемся на её прогресс, чтобы кнопка не висела на «0%».
      final existing = AppState.I.activeDownloads[apk.id];
      if (existing != null) {
        _listenTask(existing);
        if (mounted) {
          setState(() {
            _dlProgress = existing.progress;
          });
        }
      }
      // onProgress закрывает гэп между «task ещё нет» и «task появился внутри
      // downloadAndShareArtifact»: callback зовётся для КАЖДОГО апдейта,
      // поэтому процент на кнопке тикает с первого байта.
      await downloadAndShareArtifact(
        context,
        apk,
        onProgress: (p) {
          if (!mounted) return;
          setState(() {
            _dlProgress = p;
          });
        },
      );
    } catch (_) {
      // тихо.
    }
    // Загрузка завершилась (успешно или нет) — снимаем привязку, чтобы
    // на следующий вход экран не показывал «Загрузка 0%» по призраку.
    AppState.I.runApkArtifactId.remove(widget.run.id);
    if (mounted) setState(() {
      _downloadingApk = false;
      _dlProgress = 0;
    });
  }

  Future<void> _cancel(BuildContext context) async {
    final api = AppState.I.api;
    final repo = AppState.I.activeRepo;
    if (api == null || repo == null) return;
    try {
      await api.cancelRun(repo.fullName, widget.run.id);
    } catch (_) {
      // тихо.
    }
    widget.onRefresh();
  }

  Future<void> _rerun(BuildContext context) async {
    final api = AppState.I.api;
    final repo = AppState.I.activeRepo;
    if (api == null || repo == null) return;
    try {
      await api.rerunRun(repo.fullName, widget.run.id);
    } catch (_) {
      // тихо.
    }
    widget.onRefresh();
  }

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    final run = widget.run;
    final st = runStatusInfo(run);
    final running = run.status != 'completed';
    final success = run.status == 'completed' && run.conclusion == 'success';
    final failed = run.status == 'completed' &&
        run.conclusion.isNotEmpty &&
        run.conclusion != 'success';
    // Баг n6509: при реране рана createdAt НЕ обновляется, поэтому
    // расчёт длительности «сколько идёт» был относительно ПЕРВОГО старта
    // и мог выдавать вроде «6965 мин». Используем effectiveStartedAt —
    // run_started_at из GitHub API или createdAt в качестве фоллбэка.
    final startIso = run.effectiveStartedAt;
    final updatedIso =
        run.updatedAt.isNotEmpty ? run.updatedAt : run.effectiveStartedAt;
    final branchPart = run.headBranch.isEmpty ? '?' : run.headBranch;
    final stLabel = st.label.toLowerCase();
    // Meta-лейбл с «живым» временем. Раньше он был простым Text и
    // обновлялся за счёт большого setState() на весь экран каждую
    // секунду. Теперь ребилдится ТОЛЬКО эти две буквы времени.
    Widget metaText() => ValueListenableBuilder<int>(
          valueListenable: _liveSecondTick,
          builder: (_, __, ___) {
            final meta = running
                ? '$branchPart · ${_fmtElapsed(startIso)}'
                : '$branchPart · ${_timeAgo(updatedIso)} · $stLabel';
            return Text(meta,
                style: TextStyle(fontSize: 12, color: pal.sub),
                maxLines: 1,
                overflow: TextOverflow.ellipsis);
          },
        );
    final title = run.name.isEmpty
        ? (run.workflowName.isEmpty ? 'Workflow' : run.workflowName)
        : run.name;
    return LongPressMenu(
      onTap: widget.onTap,
      borderRadius: BorderRadius.circular(16),
      menuBuilder: () => [
        CtxMenuItem(
          icon: 'solar:eye-bold',
          label: 'Открыть',
          onTap: widget.onTap,
        ),
        if (running)
          CtxMenuItem(
            icon: 'solar:close-circle-bold',
            label: 'Отменить',
            danger: true,
            onTap: () => _cancel(context),
          )
        else
          CtxMenuItem(
            icon: 'solar:refresh-bold',
            label: 'Перезапустить',
            onTap: () => _rerun(context),
          ),
        if (success)
          CtxMenuItem(
            icon: 'solar:download-bold',
            label: 'Скачать APK',
            onTap: () => _downloadApk(context),
          ),
      ],
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: pal.cont,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              _StatusIcon(run: run, size: 32, iconSize: 18),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: pal.text,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 3),
                    metaText(),
                  ],
                ),
              ),
              Iconify('solar:alt-arrow-right-linear',
                  size: 18, color: pal.sub),
            ]),
            if (running) ...[
              const SizedBox(height: 10),
              RunProgressBar(progress: computeRunProgress(run)),
            ],
            if (success) ...[
              const SizedBox(height: 10),
              _MiniBtn(
                icon: _downloadingApk
                    ? 'solar:refresh-bold'
                    : 'solar:download-bold',
                label: _downloadingApk
                    ? 'Загрузка ${((_dlProgress * 100).toInt())}%'
                    : 'Скачать APK',
                onTap: _downloadingApk ? null : () => _downloadApk(context),
                progress: _downloadingApk ? _dlProgress : null,
              ),
            ],
            if (failed) ...[
              const SizedBox(height: 10),
              _MiniBtn(
                icon: 'solar:copy-bold',
                label: 'Копировать ошибку',
                onTap: widget.onTap,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _StatusIcon extends StatelessWidget {
  final GhRun run;
  final double size;
  final double iconSize;
  const _StatusIcon({
    required this.run,
    this.size = 32,
    this.iconSize = 18,
  });
  @override
  Widget build(BuildContext context) {
    final st = runStatusInfo(run);
    final running = run.status == 'in_progress';
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: st.color,
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: running
          ? _SpinIcon(icon: st.icon, size: iconSize, color: Colors.white)
          : Iconify(st.icon, size: iconSize, color: Colors.white),
    );
  }
}

class _SpinIcon extends StatefulWidget {
  final String icon;
  final double size;
  final Color color;
  const _SpinIcon(
      {required this.icon, required this.size, required this.color});
  @override
  State<_SpinIcon> createState() => _SpinIconState();
}

class _SpinIconState extends State<_SpinIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(seconds: 1))
    ..repeat();
  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (_, __) => Transform.rotate(
        angle: _c.value * 6.283,
        child: Iconify(widget.icon, size: widget.size, color: widget.color),
      ),
    );
  }
}

/// Единая формула прогресса для workflow-рана (баг n6663: в списке и в
/// деталях были разные значения — одно бралось от времени, другое от
/// done/total jobs). Совпадает с computeRunProgress() в HTML-эталоне.
///
/// Сочетает время (easeOutQuart-подобная кривая) и, если известны,
/// долю выполненных jobs. Берёт комбинированный максимум, зажимая
/// результат в [0.02, 0.95] — последние 5% оставляем на финиш.
double computeRunProgress(GhRun run,
    {int stepsDone = 0, int stepsTotal = 0}) {
  if (run.status == 'completed') {
    return run.conclusion == 'success' ? 1.0 : 0.0;
  }
  final iso = run.effectiveStartedAt;
  try {
    final dt = DateTime.parse(iso).toUtc();
    final elapsed =
        DateTime.now().toUtc().difference(dt).inSeconds.toDouble();
    const total = 300.0; // 5 минут по умолчанию (как в HTML)
    final tNorm = (elapsed / total).clamp(0.0, 1.4);
    final double timeFrac;
    if (tNorm < 1.0) {
      timeFrac = 1.0 - math.pow(1.0 - tNorm, 2.2).toDouble();
    } else {
      timeFrac = 0.92 + (tNorm - 1.0) * 0.07;
    }
    final stepFrac = stepsTotal > 0 ? stepsDone / stepsTotal : 0.0;
    final combined = stepFrac > 0
        ? math.max(
            timeFrac * 0.7 + stepFrac * 0.3,
            math.max(stepFrac, timeFrac * 0.85),
          )
        : timeFrac;
    return combined.clamp(0.02, 0.95);
  } catch (_) {
    return 0.3;
  }
}

/// Полоса прогресса активных ранов (сборка GitHub Actions). M3
/// Expressive linear-индикатор: волнистый активный сегмент со
/// скруглёнными концами + gap между активной частью и треком
/// (https://m3.material.io/components/progress-indicators/overview).
/// Используется тот же wavy-вариант, что и у заливки файлов на
/// экране Profile — юзер прямо просил «при сборке тоже полоса
/// прогресса в стиле M3, как при заливке файлов».
class RunProgressBar extends StatelessWidget {
  final double progress;
  const RunProgressBar({super.key, required this.progress});

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    return M3LinearProgress(
      progress: progress,
      activeColor: AppColors.accent,
      trackColor: pal.cont2,
      thickness: 6,
      // wavy: true (по умолчанию) — M3 Expressive «волна».
    );
  }
}

class _MiniBtn extends StatelessWidget {
  final String icon;
  final String label;
  final VoidCallback? onTap;
  final double? progress;
  const _MiniBtn(
      {required this.icon,
      required this.label,
      required this.onTap,
      this.progress});
  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    final hasProgress = progress != null && progress! > 0;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: double.infinity,
        height: 40,
        clipBehavior: Clip.hardEdge,
        decoration: BoxDecoration(
          color: pal.cont2,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Stack(
          children: [
            if (hasProgress)
              AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                curve: Curves.easeOut,
                width: double.infinity,
                alignment: Alignment.centerLeft,
                child: FractionallySizedBox(
                  widthFactor: progress!.clamp(0.0, 1.0),
                  child: Container(
                    decoration: BoxDecoration(
                      color: AppColors.accent.withValues(alpha: 0.25),
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
            Center(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Iconify(icon, size: 16, color: AppColors.accent),
                  const SizedBox(width: 8),
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: pal.text,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class RunStatusInfo {
  final String icon;
  final Color color;
  final String label;
  RunStatusInfo(this.icon, this.color, this.label);
}

RunStatusInfo runStatusInfo(GhRun run) {
  if (run.status == 'in_progress') {
    return RunStatusInfo(
        'solar:refresh-bold', AppColors.blue, 'IN PROGRESS');
  }
  if (run.status == 'queued' || run.status == 'pending') {
    return RunStatusInfo(
        'solar:clock-circle-bold', AppColors.orange, 'QUEUED');
  }
  if (run.conclusion == 'success') {
    return RunStatusInfo(
        'solar:check-circle-bold', AppColors.green, 'SUCCESS');
  }
  if (run.conclusion == 'failure') {
    return RunStatusInfo(
        'solar:close-circle-bold', AppColors.red, 'FAILED');
  }
  if (run.conclusion == 'cancelled') {
    return RunStatusInfo(
        'solar:forbidden-circle-bold', AppColors.dark, 'CANCELLED');
  }
  return RunStatusInfo(
      'solar:question-circle-bold', AppColors.dark,
      run.status.toUpperCase());
}

String _fmtElapsed(String iso) {
  try {
    final dt = DateTime.parse(iso);
    final diff = DateTime.now().toUtc().difference(dt.toUtc());
    final s = diff.inSeconds % 60;
    final m = diff.inMinutes;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  } catch (_) {
    return '00:00';
  }
}

String _timeAgo(String iso) {
  try {
    final dt = DateTime.parse(iso);
    final diff = DateTime.now().toUtc().difference(dt.toUtc());
    if (diff.inSeconds < 60) return '${diff.inSeconds}с назад';
    if (diff.inMinutes < 60) return '${diff.inMinutes}м назад';
    if (diff.inHours < 24) return '${diff.inHours}ч назад';
    return '${diff.inDays}д назад';
  } catch (_) {
    return '';
  }
}

/// [_FadeOnChangeText] — replacement for AnimatedSwitcher вокруг Text:
/// первый билд показывает текст моментально (без fade-in от opacity 0),
/// последующие смены строки плавно cross-fade'ятся за [duration]. Без
/// SizeTransition — горизонтальная ширина не схлопывается до 0.
///
/// Зачем это: AnimatedSwitcher по умолчанию анимирует и первый child.
/// На холодном входе на экран Actions заголовок «Идёт сборка» / «Actions»
/// выезжал из width=0, opacity=0 и пользователь видел только статус-точку
/// сначала, потом — резкое появление текста. Этот виджет первое
/// значение выводит без анимации, и только при последующих сменах
/// делает плавный fade.
class _FadeOnChangeText extends StatefulWidget {
  final String text;
  final TextStyle? style;
  final Duration duration;
  const _FadeOnChangeText({
    required this.text,
    this.style,
    this.duration = const Duration(milliseconds: 220),
  });

  @override
  State<_FadeOnChangeText> createState() => _FadeOnChangeTextState();
}

class _FadeOnChangeTextState extends State<_FadeOnChangeText>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late String _current;
  String? _previous;

  @override
  void initState() {
    super.initState();
    _current = widget.text;
    _ctrl = AnimationController(
      vsync: this,
      duration: widget.duration,
      value: 1.0,
    );
  }

  @override
  void didUpdateWidget(covariant _FadeOnChangeText old) {
    super.didUpdateWidget(old);
    if (old.duration != widget.duration) _ctrl.duration = widget.duration;
    if (old.text != widget.text) {
      _previous = _current;
      _current = widget.text;
      _ctrl.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, __) {
        final t = _ctrl.value;
        if (t >= 1.0 || _previous == null) {
          return Text(
            _current,
            style: widget.style,
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.fade,
          );
        }
        return Stack(
          alignment: AlignmentDirectional.centerStart,
          clipBehavior: Clip.none,
          children: [
            Opacity(
              opacity: 1 - t,
              child: Text(
                _previous!,
                style: widget.style,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.fade,
              ),
            ),
            Opacity(
              opacity: t,
              child: Text(
                _current,
                style: widget.style,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.fade,
              ),
            ),
          ],
        );
      },
    );
  }
}

