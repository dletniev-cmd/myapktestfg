import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api.dart';
import '../iconify.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'actions.dart';
import 'actions_archive.dart';

/// Экран детальной информации о ране — баг n3324: «сделай дизайн как в HTML».
/// Раньше тут был тонкий список Tile'ов. Теперь:
///   • шапка с кнопками Перезапустить / Открыть на GitHub / Скачать APK
///   • живой timeline по дочерним джобам (раскрывающиеся карточки)
///   • внутри джоба — список шагов с иконкой статуса, длительностью каждого
///     шага и таймером для активного
///   • если джоб завершён — можно развернуть и посмотреть полный текст логов
///   • прогресс-бар «прошло / расчётно осталось» сверху, как в HTML
///   • авто-обновление каждые 6с пока ран running
class RunDetailScreen extends StatefulWidget {
  final GhRun run;
  const RunDetailScreen({super.key, required this.run});
  @override
  State<RunDetailScreen> createState() => _RunDetailScreenState();
}

class _RunDetailScreenState extends State<RunDetailScreen> {
  bool _loading = true;
  late GhRun _run;
  List<GhJob> _jobs = [];
  List<GhArtifact> _arts = [];
  Timer? _refreshTimer;
  Timer? _tickTimer;
  bool _busyAction = false;

  @override
  void initState() {
    super.initState();
    _run = widget.run;
    _load();
    // Тикер для обновления текстов "5:23" (в реальном времени) при running.
    _tickTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (_run.status != 'completed') setState(() {});
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _tickTimer?.cancel();
    super.dispose();
  }

  void _scheduleAutoRefresh() {
    _refreshTimer?.cancel();
    if (_run.status == 'completed') return;
    _refreshTimer = Timer(const Duration(seconds: 6), () {
      if (!mounted) return;
      _load(silent: true);
    });
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent) setState(() => _loading = true);
    final api = AppState.I.api!;
    final repo = AppState.I.activeRepo!;
    try {
      final freshRun = await api.runByIdMaybe(repo.fullName, _run.id);
      _jobs = await api.runJobs(repo.fullName, _run.id);
      _arts = await api.runArtifacts(repo.fullName, _run.id);
      if (freshRun != null) _run = freshRun;
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
    _scheduleAutoRefresh();
  }

  Future<void> _rerun() async {
    if (_busyAction) return;
    setState(() => _busyAction = true);
    try {
      await AppState.I.api!.rerunRun(AppState.I.activeRepo!.fullName, _run.id);
      HapticFeedback.mediumImpact();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Запущен повторно')),
      );
      await Future.delayed(const Duration(seconds: 2));
      await _load(silent: true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось перезапустить: $e')),
      );
    } finally {
      if (mounted) setState(() => _busyAction = false);
    }
  }

  Future<void> _cancel() async {
    if (_busyAction) return;
    setState(() => _busyAction = true);
    try {
      await AppState.I.api!.cancelRun(AppState.I.activeRepo!.fullName, _run.id);
      HapticFeedback.mediumImpact();
      if (!mounted) return;
      // Раньше тут показывался SnackBar «Отмена отправлена» — юзер
      // просил убрать это «белое уведомление». Индикация теперь в
      // самой кнопке: вместо иконки «x» пока запрос летит в
      // GitHub и ран ещё не перешёл в cancelled — крутится
      // маленький спиннер (см. _ActionBtn.loading).
      await _load(silent: true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось отменить: $e')),
      );
    } finally {
      if (mounted) setState(() => _busyAction = false);
    }
  }

  String _formatBytes(int b) {
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
    return '${(b / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    final run = _run;
    final st = runStatusInfo(run);
    final running = run.status != 'completed';
    final success = run.status == 'completed' && run.conclusion == 'success';

    return Scaffold(
      backgroundColor: pal.bg,
      body: Stack(
        children: [
          Positioned.fill(
            child: SingleChildScrollView(
              physics: const ClampingScrollPhysics(),
              padding: EdgeInsets.only(
                top: MediaQuery.of(context).padding.top + kTopHeaderBarHeight,
                bottom: 32,
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Шапка: статус + название + ветка + время
                    _RunHero(run: run, st: st),
                    const SizedBox(height: 12),
                    if (running) ...[
                      _RunProgressBar(run: run, jobs: _jobs),
                      const SizedBox(height: 12),
                    ],
                    // Кнопки действий — параллельно как в HTML.
                    Row(children: [
                      Expanded(
                        child: _ActionBtn(
                          icon: running
                              ? 'solar:close-circle-bold'
                              : 'solar:refresh-bold',
                          label: running ? 'Отменить' : 'Перезапустить',
                          danger: running,
                          // Пока запрос отмены/перезапуска летит — вместо
                          // иконки в кнопке крутится маленький спиннер
                          // со скруглёнными концами. Это заменяет прежний
                          // SnackBar «Отмена отправлена» (юзер просил
                          // убрать белое уведомление).
                          loading: _busyAction,
                          onTap: _busyAction
                              ? null
                              : (running ? _cancel : _rerun),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _ActionBtn(
                          icon: 'solar:link-bold',
                          label: 'GitHub',
                          onTap: () => launchUrl(Uri.parse(run.htmlUrl)),
                        ),
                      ),
                    ]),
                    const SizedBox(height: 18),
                    // Артефакты — обычно один APK. Показываем сразу в шапке
                    // как «крупный» вариант, потому что это самое полезное
                    // действие по успешному рану.
                    if (success && _arts.isNotEmpty) ...[
                      const SecTitle('Артефакты'),
                      Column(
                        children: [
                          for (final a in _arts) ...[
                            _ArtifactCard(
                              artifact: a,
                              size: _formatBytes(a.sizeInBytes),
                            ),
                            const SizedBox(height: 8),
                          ],
                        ],
                      ),
                      const SizedBox(height: 6),
                    ],
                    // Джобы.
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const SecTitle('Задачи'),
                        if (_loading)
                          Padding(
                            padding: const EdgeInsets.only(right: 4, top: 16),
                            child: SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: pal.sub,
                                strokeCap: StrokeCap.round,
                              ),
                            ),
                          ),
                      ],
                    ),
                    if (!_loading && _jobs.isEmpty)
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: pal.cont,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        alignment: Alignment.center,
                        child: Text('Нет задач',
                            style: TextStyle(color: pal.sub, fontSize: 13)),
                      ),
                    for (final j in _jobs) ...[
                      _JobCard(
                        key: ValueKey('job-${j.id}'),
                        job: j,
                        runStatus: run.status,
                      ),
                      const SizedBox(height: 8),
                    ],
                  ],
                ),
              ),
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: TopFadeHeader(
              title: 'Run #${run.id}',
              trailing: [
                // Баг n7281: раньше при тапе иконка обновления красилась
                // в фиолетовый (accent) — выглядело как «зависла». Теперь
                // цвет не меняется, а иконка плавно крутится.
                RotatingRefreshBtn(
                  spinning: _loading,
                  onTap: _loading ? null : () => _load(),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Hero-блок: иконка статуса + workflow + ветка + длительность/таймер.
class _RunHero extends StatelessWidget {
  final GhRun run;
  final RunStatusInfo st;
  const _RunHero({required this.run, required this.st});
  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    final running = run.status != 'completed';
    final elapsed = _elapsedString(run.effectiveStartedAt,
        until: running
            ? DateTime.now()
            : (DateTime.tryParse(run.updatedAt)?.toLocal() ??
                DateTime.now()));
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: pal.cont,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _AnimatedStatusBadge(status: run.status, info: st, size: 48),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      run.workflowName.isEmpty
                          ? '#${run.id}'
                          : run.workflowName,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: pal.text,
                        height: 1.2,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Iconify('solar:branching-paths-up-bold',
                            size: 13, color: pal.sub),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            run.headBranch.isEmpty ? '?' : run.headBranch,
                            style: TextStyle(
                                fontSize: 12,
                                color: pal.sub,
                                fontWeight: FontWeight.w500),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Iconify('solar:bolt-bold',
                            size: 13, color: pal.sub),
                        const SizedBox(width: 4),
                        Text(run.event,
                            style: TextStyle(
                                fontSize: 12, color: pal.sub)),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (run.headCommit.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              run.headCommit,
              style: TextStyle(fontSize: 13, color: pal.text, height: 1.35),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          const SizedBox(height: 12),
          Row(children: [
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: st.color.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Iconify(st.icon, size: 12, color: st.color),
                  const SizedBox(width: 5),
                  Text(st.label,
                      style: TextStyle(
                        color: st.color,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.4,
                      )),
                ],
              ),
            ),
            const Spacer(),
            Iconify(
                running
                    ? 'solar:stopwatch-bold-duotone'
                    : 'solar:clock-circle-bold',
                size: 14,
                color: pal.sub),
            const SizedBox(width: 4),
            Text(elapsed,
                style: TextStyle(
                  color: pal.sub,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  fontFeatures: const [FontFeature.tabularFigures()],
                )),
          ]),
        ],
      ),
    );
  }
}

/// Прогресс рана — «X / Y задач выполнено» + та же градиентная полоса
/// прогресса, что и в списке Actions (баг n6663: раньше прогресс в списке
/// и в деталях считался по разным формулам и не совпадал; теперь обе
/// полосы берут значение из общей [computeRunProgress] и выглядят
/// одинаково — со скруглёнными краями и градиентом).
class _RunProgressBar extends StatelessWidget {
  final GhRun run;
  final List<GhJob> jobs;
  const _RunProgressBar({required this.run, required this.jobs});
  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    final total = jobs.length;
    final done = jobs.where((j) => j.status == 'completed').length;
    final progress = computeRunProgress(run,
        stepsDone: done, stepsTotal: total);
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      decoration: BoxDecoration(
        color: pal.cont,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Text('Прогресс',
                style: TextStyle(
                    color: pal.sub,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.4)),
            const Spacer(),
            Text(total == 0 ? '...' : '$done / $total',
                style: TextStyle(
                    color: pal.text,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    fontFeatures: const [FontFeature.tabularFigures()])),
          ]),
          const SizedBox(height: 8),
          RunProgressBar(progress: progress),
        ],
      ),
    );
  }
}

/// Анимированный бэдж статуса — «вращается» когда running, цельный — когда
/// completed. Соответствует .status-icon из HTML.
class _AnimatedStatusBadge extends StatelessWidget {
  final String status;
  final RunStatusInfo info;
  final double size;
  const _AnimatedStatusBadge(
      {required this.status, required this.info, this.size = 36});
  @override
  Widget build(BuildContext context) {
    final running = status != 'completed';
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: info.color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(size * 0.30),
      ),
      alignment: Alignment.center,
      child: running
          ? _SpinningIcon(icon: info.icon, color: info.color, size: size * 0.55)
          : Iconify(info.icon, size: size * 0.55, color: info.color),
    );
  }
}

class _SpinningIcon extends StatefulWidget {
  final String icon;
  final Color color;
  final double size;
  const _SpinningIcon(
      {required this.icon, required this.color, required this.size});
  @override
  State<_SpinningIcon> createState() => _SpinningIconState();
}

class _SpinningIconState extends State<_SpinningIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(seconds: 2))
        ..repeat();
  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RotationTransition(
      turns: _c,
      child:
          Iconify(widget.icon, size: widget.size, color: widget.color),
    );
  }
}

class _ActionBtn extends StatelessWidget {
  final String icon;
  final String label;
  final VoidCallback? onTap;
  final bool danger;
  /// Пока true — вместо иконки показываем круговой спиннер (16x16,
  /// со скруглёнными концами), а кнопка переходит в неактивный
  /// вид (onTap игнорится, текст выблякивает). Это заменяет SnackBar
  /// «Отмена отправлена» и даёт визуальный фидбэк прямо в кнопке.
  final bool loading;
  const _ActionBtn({
    required this.icon,
    required this.label,
    this.onTap,
    this.danger = false,
    this.loading = false,
  });
  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    final fg = danger ? pal.red : pal.text;
    return PressScale(
      onTap: loading ? null : onTap,
      scale: 0.97,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        decoration: BoxDecoration(
          color: pal.cont,
          borderRadius: BorderRadius.circular(18),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Слот фиксированного размера (16x16): либо иконка, либо
            // спиннер. Кросс-фейд получается плавным без рывка рядомстоящего текста.
            SizedBox(
              width: 16,
              height: 16,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 220),
                child: loading
                    ? SizedBox(
                        key: const ValueKey('spin'),
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: fg,
                          strokeCap: StrokeCap.round,
                        ),
                      )
                    : Iconify(
                        icon,
                        key: ValueKey('icon-$icon'),
                        size: 16,
                        color: fg,
                      ),
              ),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(label,
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: fg,
                      height: 1.0),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
            ),
          ],
        ),
      ),
    );
  }
}

/// Карточка артефакта — один клик на всю карточку = скачать.
class _ArtifactCard extends StatefulWidget {
  final GhArtifact artifact;
  final String size;
  const _ArtifactCard({required this.artifact, required this.size});
  @override
  State<_ArtifactCard> createState() => _ArtifactCardState();
}

class _ArtifactCardState extends State<_ArtifactCard> {
  DownloadTask? _task;

  @override
  void initState() {
    super.initState();
    _task = AppState.I.activeDownloads[widget.artifact.id];
    _task?.addListener(_onTask);
  }

  @override
  void dispose() {
    _task?.removeListener(_onTask);
    super.dispose();
  }

  void _onTask() {
    if (mounted) setState(() {});
  }

  Future<void> _download() async {
    final existing = AppState.I.activeDownloads[widget.artifact.id];
    if (existing != null && existing.busy) return;
    // onProgress — страховка от случаев, когда task создаётся ВНУТРИ
    // downloadAndShareArtifact (после нашего initState/lookup) и виджет
    // не успевает «поймать» его через _checkTask. Через callback
    // setState срабатывает на каждый процент.
    await downloadAndShareArtifact(
      context,
      widget.artifact,
      onProgress: (_) {
        if (mounted) setState(() {});
      },
    );
  }

  @override
  void didUpdateWidget(covariant _ArtifactCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    final newTask = AppState.I.activeDownloads[widget.artifact.id];
    if (newTask != _task) {
      _task?.removeListener(_onTask);
      _task = newTask;
      _task?.addListener(_onTask);
    }
  }

  void _checkTask() {
    final newTask = AppState.I.activeDownloads[widget.artifact.id];
    if (newTask != _task) {
      _task?.removeListener(_onTask);
      _task = newTask;
      _task?.addListener(_onTask);
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    _checkTask();
    final pal = context.pal;
    final a = widget.artifact;
    final disabled = a.expired;
    final busy = _task?.busy ?? false;
    final progress = _task?.progress ?? 0.0;
    return PressScale(
      onTap: disabled || busy ? null : _download,
      scale: 0.99,
      child: Container(
        clipBehavior: Clip.hardEdge,
        decoration: BoxDecoration(
          color: pal.cont,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Stack(
          children: [
            if (busy && progress > 0)
              Positioned.fill(
                child: FractionallySizedBox(
                  alignment: Alignment.centerLeft,
                  widthFactor: progress.clamp(0.0, 1.0),
                  child: Container(
                    decoration: BoxDecoration(
                      color: AppColors.purple.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(20),
                    ),
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              child: Row(children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: AppColors.purple,
                    borderRadius: BorderRadius.circular(13),
                  ),
                  alignment: Alignment.center,
                  child: busy
                      ? SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            value: progress > 0 ? progress : null,
                            strokeWidth: 2.5,
                            strokeCap: StrokeCap.round,
                            color: Colors.white,
                          ),
                        )
                      : Iconify(
                          'solar:download-bold',
                          size: 20,
                          color: Colors.white,
                        ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(a.name,
                          style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: pal.text),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                      const SizedBox(height: 2),
                      Text(
                          busy
                              ? 'Загрузка ${((progress * 100).toInt())}% · ${widget.size}'
                              : '${widget.size}${a.expired ? ' · истёк' : ''}',
                          style: TextStyle(fontSize: 12, color: pal.sub)),
                    ],
                  ),
                ),
                Iconify('solar:alt-arrow-right-linear',
                    size: 18, color: pal.sub),
              ]),
            ),
          ],
        ),
      ),
    );
  }
}

/// Разворачиваемая карточка джоба. Внутри — список шагов, и КАЖДЫЙ
/// шаг сам разворачивается в свой кусок логов (как в HTML v5.7).
/// Логи ленивая загрузка: при первом раскрытии шага запрашиваем общий
/// текст job-лога и кэшируем его. Дальше шаги парсятся локально.
class _JobCard extends StatefulWidget {
  final GhJob job;
  final String runStatus;
  const _JobCard({super.key, required this.job, required this.runStatus});
  @override
  State<_JobCard> createState() => _JobCardState();
}

class _JobCardState extends State<_JobCard> {
  bool _expanded = false;

  _StepStatusInfo _statusOf(String status, String conclusion) {
    if (status == 'in_progress' || status == 'queued') {
      return const _StepStatusInfo(
          color: AppColors.blue,
          icon: 'solar:play-circle-bold',
          label: 'идёт');
    }
    if (status == 'completed') {
      if (conclusion == 'success') {
        return const _StepStatusInfo(
            color: AppColors.green,
            icon: 'solar:check-circle-bold',
            label: 'ок');
      }
      if (conclusion == 'failure') {
        return const _StepStatusInfo(
            color: AppColors.red,
            icon: 'solar:close-circle-bold',
            label: 'упал');
      }
      if (conclusion == 'cancelled') {
        return const _StepStatusInfo(
            color: AppColors.dark,
            icon: 'solar:stop-circle-bold',
            label: 'отменён');
      }
      if (conclusion == 'skipped') {
        return const _StepStatusInfo(
            color: AppColors.dark,
            icon: 'solar:forward-bold',
            label: 'пропущен');
      }
    }
    return const _StepStatusInfo(
        color: AppColors.dark,
        icon: 'solar:question-circle-bold',
        label: '...');
  }

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    final job = widget.job;
    final st = _statusOf(job.status, job.conclusion);
    final running = job.status != 'completed';
    final elapsed = _elapsedString(job.startedAt,
        until: running
            ? DateTime.now()
            : (DateTime.tryParse(job.completedAt)?.toLocal() ??
                DateTime.now()));

    final stepsTotal = job.steps.length;
    final stepsDone = job.steps.where((s) => s.status == 'completed').length;

    return RepaintBoundary(
      child: Container(
      decoration: BoxDecoration(
        color: pal.cont,
        borderRadius: BorderRadius.circular(20),
      ),
      clipBehavior: Clip.hardEdge,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PressScale(
            onTap: () {
              HapticFeedback.selectionClick();
              setState(() => _expanded = !_expanded);
            },
            scale: 0.99,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              child: Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: st.color.withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    alignment: Alignment.center,
                    child: running
                        ? _SpinningIcon(
                            icon: st.icon, color: st.color, size: 18)
                        : Iconify(st.icon, size: 18, color: st.color),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(job.name,
                            style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: pal.text),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis),
                        const SizedBox(height: 3),
                        Text(
                          stepsTotal == 0
                              ? st.label
                              : '$stepsDone/$stepsTotal · $elapsed',
                          style: TextStyle(
                              fontSize: 12,
                              color: pal.sub,
                              fontFeatures: const [
                                FontFeature.tabularFigures()
                              ]),
                        ),
                      ],
                    ),
                  ),
                  AnimatedRotation(
                    turns: _expanded ? 0.5 : 0,
                    duration: const Duration(milliseconds: 220),
                    curve: Curves.easeOutCubic,
                    child: Iconify('solar:alt-arrow-down-linear',
                        size: 18, color: pal.sub),
                  ),
                ],
              ),
            ),
          ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(0, 0, 0, 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    height: 1,
                    color: pal.sub.withValues(alpha: 0.10),
                    margin: const EdgeInsets.symmetric(
                        horizontal: 14),
                  ),
                  if (job.steps.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(14),
                      child: Text('Шаги недоступны',
                          style: TextStyle(
                              color: pal.sub, fontSize: 12)),
                    )
                  else
                    for (var idx = 0;
                        idx < job.steps.length;
                        idx++)
                      _StepTile(
                        step: job.steps[idx],
                        isLast: idx == job.steps.length - 1,
                        statusInfo: _statusOf(
                            job.steps[idx].status,
                            job.steps[idx].conclusion),
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

class _StepStatusInfo {
  final Color color;
  final String icon;
  final String label;
  const _StepStatusInfo(
      {required this.color, required this.icon, required this.label});
}

/// Один шаг джоба — плоская строка: иконка статуса + название + время.
/// Без раскрытия логов (дизайн как в HTML).
class _StepTile extends StatelessWidget {
  final GhStep step;
  final _StepStatusInfo statusInfo;
  final bool isLast;
  const _StepTile({
    required this.step,
    required this.statusInfo,
    required this.isLast,
  });

  String _stepDuration() {
    final running = step.status == 'in_progress';
    if (step.status == 'completed' &&
        step.startedAt.isNotEmpty &&
        step.completedAt.isNotEmpty) {
      final s = DateTime.tryParse(step.startedAt);
      final e = DateTime.tryParse(step.completedAt);
      if (s != null && e != null) return _formatDur(e.difference(s));
    } else if (running && step.startedAt.isNotEmpty) {
      final s = DateTime.tryParse(step.startedAt);
      if (s != null) {
        return _formatDur(DateTime.now().toUtc().difference(s.toUtc()));
      }
    }
    return '';
  }

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    final running = step.status == 'in_progress';
    final dur = _stepDuration();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 11, 14, 11),
          child: Row(
            children: [
              SizedBox(
                width: 22,
                height: 22,
                child: running
                    ? _SpinningIcon(
                        icon: statusInfo.icon,
                        color: statusInfo.color,
                        size: 18)
                    : Iconify(statusInfo.icon,
                        size: 18, color: statusInfo.color),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(step.name,
                    style: TextStyle(
                      fontSize: 13,
                      color: pal.text,
                      fontWeight:
                          running ? FontWeight.w600 : FontWeight.w500,
                      height: 1.3,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis),
              ),
              if (dur.isNotEmpty) ...[
                const SizedBox(width: 8),
                Text(dur,
                    style: TextStyle(
                        fontSize: 11.5,
                        color: pal.sub,
                        fontFeatures: const [FontFeature.tabularFigures()])),
              ],
            ],
          ),
        ),
        if (!isLast)
          Container(
            height: 1,
            color: pal.sub.withValues(alpha: 0.06),
            margin: const EdgeInsets.symmetric(horizontal: 14),
          ),
      ],
    );
  }
}

String _elapsedString(String startIso, {required DateTime until}) {
  if (startIso.isEmpty) return '';
  final start = DateTime.tryParse(startIso);
  if (start == null) return '';
  final dur = until.toUtc().difference(start.toUtc());
  if (dur.isNegative) return '0с';
  return _formatDur(dur);
}

String _formatDur(Duration d) {
  if (d.isNegative) return '0с';
  final s = d.inSeconds;
  if (s < 60) return '${s}с';
  final m = d.inMinutes;
  if (m < 60) return '${m}м ${s - m * 60}с';
  final h = d.inHours;
  return '${h}ч ${m - h * 60}м';
}
