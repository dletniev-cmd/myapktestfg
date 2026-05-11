import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';

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
  String? _error;
  List<GhRun> _runs = [];
  String _filter = 'all';
  Timer? _autoRefresh;
  int _refreshSpinCounter = 0;
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

  Future<void> _refresh() async {
    final api = AppState.I.api;
    final repo = AppState.I.activeRepo;
    if (api == null || repo == null) return;
    setState(() {
      _loading = true;
      _refreshSpinCounter++;
    });
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
      setState(() {
        _runs = runs;
        _loading = false;
        _error = null;
      });
      AppState.I.cachedRuns = runs;
      AppState.I.cachedRunsRepo = repo.fullName;
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
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
    final lastUpdated = _runs.isEmpty
        ? null
        : (_runs.first.updatedAt.isNotEmpty
            ? _runs.first.updatedAt
            : _runs.first.createdAt);
    final liveStatus = _error != null
        ? _LiveStatus.error
        : (_loading
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
                lastUpdatedIso: lastUpdated,
                spinCounter: _refreshSpinCounter,
                loading: _loading,
                onRefresh: _loading ? null : _refresh,
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
            child: CircularProgressIndicator(
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
  final String? lastUpdatedIso;
  final int spinCounter;
  final bool loading;
  final VoidCallback? onRefresh;
  const _LiveHead({
    required this.status,
    required this.running,
    required this.lastUpdatedIso,
    required this.spinCounter,
    required this.loading,
    required this.onRefresh,
  });
  @override
  State<_LiveHead> createState() => _LiveHeadState();
}

class _LiveHeadState extends State<_LiveHead>
    with TickerProviderStateMixin {
  late final AnimationController _dotCtrl =
      AnimationController(vsync: this, duration: const Duration(seconds: 2))
        ..repeat(reverse: true);
  late final AnimationController _spinCtrl = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 900));

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
    if (widget.spinCounter != old.spinCounter) {
      _spinCtrl.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _dotCtrl.dispose();
    _spinCtrl.dispose();
    super.dispose();
  }

  Color _statusColor(AppPalette pal) {
    switch (widget.status) {
      case _LiveStatus.live:
        return const Color(0xFF5DD07A);
      case _LiveStatus.working:
        // \u00abОбновление…\u00bb — цвет берётся из акцента темы.
        return pal.accent;
      case _LiveStatus.error:
        return const Color(0xFFFF6B6B);
      case _LiveStatus.idle:
        return pal.sub;
    }
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

  String _statusText() {
    switch (widget.status) {
      case _LiveStatus.live:
        return 'В реальном времени';
      case _LiveStatus.working:
        return widget.loading ? 'Обновление…' : 'Подключение…';
      case _LiveStatus.error:
        return 'Ошибка';
      case _LiveStatus.idle:
        return 'Ожидание';
    }
  }

  String _agoText() {
    if (widget.lastUpdatedIso == null) return '';
    try {
      final dt = DateTime.parse(widget.lastUpdatedIso!);
      final diff = DateTime.now().toUtc().difference(dt.toUtc());
      if (diff.inSeconds < 60) return '${diff.inSeconds}с назад';
      if (diff.inMinutes < 60) return '${diff.inMinutes}м назад';
      if (diff.inHours < 24) return '${diff.inHours}ч назад';
      return '${diff.inDays}д назад';
    } catch (_) {
      return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    final stColor = _statusColor(pal);
    final dotC = _dotColor();
    final pulse = widget.status == _LiveStatus.live ||
        widget.status == _LiveStatus.working;
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
                Text(
                  'Actions',
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -.4,
                    color: pal.text,
                    height: 1.15,
                  ),
                ),
                const SizedBox(height: 6),
                AnimatedDefaultTextStyle(
                  duration: const Duration(milliseconds: 320),
                  style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w500,
                      color: stColor),
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
                    Flexible(
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 280),
                        switchInCurve: Curves.easeOutCubic,
                        switchOutCurve: Curves.easeInCubic,
                        transitionBuilder: (child, anim) {
                          return FadeTransition(
                            opacity: anim,
                            child: SizeTransition(
                              sizeFactor: anim,
                              axis: Axis.horizontal,
                              axisAlignment: -1,
                              child: child,
                            ),
                          );
                        },
                        layoutBuilder:
                            (currentChild, previousChildren) => Stack(
                          alignment: Alignment.centerLeft,
                          children: [
                            ...previousChildren,
                            if (currentChild != null) currentChild,
                          ],
                        ),
                        // Лейбл «X сек назад» обновляется только за счёт
                        // _liveSecondTick, никакого setState на родителе.
                        child: ValueListenableBuilder<int>(
                          valueListenable: _liveSecondTick,
                          builder: (_, __, ___) {
                            final ago = _agoText();
                            final t = _composeText(
                                running: widget.running, ago: ago);
                            return Text(
                              t,
                              key: ValueKey(t),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            );
                          },
                        ),
                      ),
                    ),
                  ]),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          GestureDetector(
            onTap: widget.onRefresh,
            child: Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: pal.cont,
                borderRadius: BorderRadius.circular(12),
              ),
              alignment: Alignment.center,
              child: AnimatedBuilder(
                animation: _spinCtrl,
                builder: (_, __) => Transform.rotate(
                  angle: _spinCtrl.value * 6.283,
                  child: Iconify('solar:refresh-bold',
                      size: 18, color: pal.text),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _composeText({required int running, required String ago}) {
    final base = _statusText();
    final parts = <String>[base];
    if (widget.status == _LiveStatus.live && running > 0) {
      parts.add('$running активных');
    }
    if (ago.isNotEmpty &&
        (widget.status == _LiveStatus.live ||
            widget.status == _LiveStatus.idle)) {
      parts.add(ago);
    }
    return parts.join(' · ');
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

/// Градиентная полоса прогресса для активных ранов. Общий вид из
/// HTML: высота 6px, розово-фиолетовый градиент, лёгкий shimmer поверх.
/// Прогресс обязательно в диапазоне [0, 1] — передаётся явно, чтобы
/// вызывающий код в разных экранах брал его из одного источника.
class RunProgressBar extends StatefulWidget {
  final double progress;
  const RunProgressBar({super.key, required this.progress});
  @override
  State<RunProgressBar> createState() => _RunProgressBarState();
}

class _RunProgressBarState extends State<RunProgressBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _shimmer = AnimationController(
      vsync: this, duration: const Duration(seconds: 2))
    ..repeat();

  @override
  void dispose() {
    _shimmer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    final p = widget.progress.clamp(0.0, 1.0);
    return Container(
      height: 6,
      decoration: BoxDecoration(
        color: pal.cont2,
        borderRadius: BorderRadius.circular(6),
      ),
      clipBehavior: Clip.antiAlias,
      child: LayoutBuilder(builder: (_, c) {
        return Stack(
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 1000),
              curve: const Cubic(.25, .46, .45, .94),
              width: c.maxWidth * p,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [AppColors.accent, AppColors.pink],
                ),
                borderRadius: BorderRadius.circular(6),
              ),
            ),
            Positioned.fill(
              child: AnimatedBuilder(
                animation: _shimmer,
                builder: (_, __) => CustomPaint(
                  painter: _ShimmerPainter(_shimmer.value),
                ),
              ),
            ),
          ],
        );
      }),
    );
  }
}

class _ShimmerPainter extends CustomPainter {
  final double t;
  _ShimmerPainter(this.t);
  @override
  void paint(Canvas canvas, Size size) {
    final left = -size.width + (size.width * 2) * t;
    final paint = Paint()
      ..shader = LinearGradient(colors: [
        Colors.transparent,
        Colors.white.withValues(alpha: .3),
        Colors.transparent,
      ]).createShader(Rect.fromLTWH(left, 0, size.width, size.height));
    canvas.drawRect(
        Rect.fromLTWH(0, 0, size.width, size.height), paint);
  }

  @override
  bool shouldRepaint(covariant _ShimmerPainter old) => old.t != t;
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
