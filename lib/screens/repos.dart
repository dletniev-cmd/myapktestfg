import 'package:flutter/material.dart';

import '../api.dart';
import '../iconify.dart';
import '../navigation.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'repo_detail.dart';

class ReposScreen extends StatefulWidget {
  /// Если true — экран работает как селектор и закрывается на тапе по элементу.
  final bool picker;
  const ReposScreen({super.key, this.picker = false});
  @override
  State<ReposScreen> createState() => _ReposScreenState();
}

class _ReposScreenState extends State<ReposScreen> {
  final _q = TextEditingController();
  String _filter = 'all'; // all / public / private
  bool _refreshing = false;
  double _headerH = 0;

  // Срез AppState, на который ReposScreen реально реагирует. На любое
  // другое изменение (build-poller cachedRuns, прогресс активной
  // заливки и т.п.) мы НЕ ребилдим экран — раньше `_onState`
  // безусловно дёргал setState() на каждый `notifyListeners()`, и при
  // активной заливке файлов экран репозиториев перетряхивал ListView
  // каждые ~100мс. Это и вызывало «дёргания» при листании списка, когда
  // в фоне шла заливка или поллинг GitHub Actions.
  int _lastReposLen = -1;
  bool _lastReposLoading = false;
  String? _lastReposError;
  String? _lastActiveFull;

  @override
  void initState() {
    super.initState();
    _captureSnapshot();
    AppState.I.addListener(_onState);
    // Подписываемся на изменение поискового запроса, чтобы фильтрация
    // в build() реагировала на каждое нажатие клавиатуры.
    _q.addListener(_onQuery);
    if (AppState.I.repos.isEmpty && !AppState.I.reposLoading) {
      _refresh();
    }
  }

  @override
  void dispose() {
    _q.removeListener(_onQuery);
    _q.dispose();
    AppState.I.removeListener(_onState);
    super.dispose();
  }

  void _onQuery() {
    if (mounted) setState(() {});
  }

  void _captureSnapshot() {
    _lastReposLen = AppState.I.repos.length;
    _lastReposLoading = AppState.I.reposLoading;
    _lastReposError = AppState.I.reposError;
    _lastActiveFull = AppState.I.activeRepo?.fullName;
  }

  void _onState() {
    final newLen = AppState.I.repos.length;
    final newLoading = AppState.I.reposLoading;
    final newError = AppState.I.reposError;
    final newActive = AppState.I.activeRepo?.fullName;
    if (newLen != _lastReposLen ||
        newLoading != _lastReposLoading ||
        newError != _lastReposError ||
        newActive != _lastActiveFull) {
      _lastReposLen = newLen;
      _lastReposLoading = newLoading;
      _lastReposError = newError;
      _lastActiveFull = newActive;
      if (mounted) setState(() {});
    }
  }

  Future<void> _refresh() async {
    final api = AppState.I.api;
    if (api == null) return;
    setState(() => _refreshing = true);
    try {
      AppState.I.repos = await api.myRepos();
    } catch (e) {
      AppState.I.reposError = e.toString();
    } finally {
      AppState.I.touch();
      if (mounted) setState(() => _refreshing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    final query = _q.text.trim().toLowerCase();
    var list = AppState.I.repos;
    list = list.where((r) {
      if (_filter == 'public' && r.private) return false;
      if (_filter == 'private' && !r.private) return false;
      if (query.isEmpty) return true;
      return r.name.toLowerCase().contains(query) ||
          r.description.toLowerCase().contains(query);
    }).toList();

    final topPad = _headerH > 0
        ? _headerH
        : MediaQuery.of(context).padding.top + 180;

    return Scaffold(
      backgroundColor: pal.bg,
      body: Stack(
        children: [
          Positioned.fill(
            // Баг n7281 (часть 2): после очистки кэша список репо
            // обнуляется, и пользователь возвращается на экран — список
            // пуст и непонятно что идёт загрузка. Раньше спиннер
            // показывался только пока установлен глобальный
            // `reposLoading` (из shell.dart на первом бутстрапе) — после
            // повторного `_refresh()` он уже не вставал. Теперь
            // показываем то же скруглённое кольцо (как в Actions), пока
            // идёт ЛЮБАЯ загрузка списка — и глобальная, и локальная.
            child: (AppState.I.reposLoading || _refreshing) && list.isEmpty
                ? Padding(
                    padding: EdgeInsets.only(top: topPad),
                    child: Center(
                      child: SizedBox(
                        width: 36,
                        height: 36,
                        child: CircularProgressIndicator(
                          strokeWidth: 3,
                          color: AppColors.accent,
                          strokeCap: StrokeCap.round,
                        ),
                      ),
                    ),
                  )
                : ListView.separated(
                    physics: const BouncingScrollPhysics(),
                    padding: EdgeInsets.fromLTRB(18, topPad, 18, 32),
                    itemCount: list.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (_, i) {
                      final r = list[i];
                      final isActive =
                          AppState.I.activeRepo?.fullName == r.fullName;
                      return _RepoTile(
                        repo: r,
                        selected: isActive,
                        onTap: () async {
                          if (widget.picker) {
                            await AppState.I.setActiveRepo(r);
                            if (!context.mounted) return;
                            Navigator.of(context).pop();
                          } else {
                            pushSlide(
                                context, RepoDetailScreen(repo: r));
                          }
                        },
                        onSelectTap: () async {
                          // Баг n1738 / n2833: в разделе «Репозитории» и
                          // «Мои репозитории» любой репо можно отметить
                          // галочкой — это делает его активным во всём приложении.
                          await AppState.I.setActiveRepo(r);
                          if (!context.mounted) return;
                          if (widget.picker) {
                            Navigator.of(context).pop();
                          } else {
                            setState(() {});
                          }
                        },
                      );
                    },
                  ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: StickyTabHeader(
              padding: const EdgeInsets.fromLTRB(0, 8, 0, 14),
              onHeightChanged: (h) {
                if ((h - _headerH).abs() > 0.5) {
                  setState(() => _headerH = h);
                }
              },
              children: [
                // Title row: back + title + refresh
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 0, 18, 14),
                  child: Row(
                    children: [
                      IconBtn(
                        icon: 'solar:alt-arrow-left-linear',
                        iconSize: 20,
                        size: 36,
                        onTap: () => Navigator.of(context).maybePop(),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          widget.picker ? 'Выбор репо' : 'Репозитории',
                          style: const TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -.4,
                            height: 1.15,
                          ),
                        ),
                      ),
                      // Баг n7281: раньше при тапе иконка обновления
                      // красилась в фиолетовый (accent) — выглядело как
                      // «зависла». Теперь цвет не меняется, а иконка
                      // плавно крутится, пока идёт запрос.
                      RotatingRefreshBtn(
                        spinning: _refreshing,
                        onTap: _refreshing ? null : _refresh,
                      ),
                    ],
                  ),
                ),
                // Search field
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 0, 18, 12),
                  child: FieldBox(
                    controller: _q,
                    hint: 'Поиск по названию',
                  ),
                ),
                // Filter chips
                SizedBox(
                  height: 38,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    physics: const BouncingScrollPhysics(),
                    padding: const EdgeInsets.symmetric(horizontal: 18),
                    children: [
                      CtChip(
                        label: 'Все · ${AppState.I.repos.length}',
                        active: _filter == 'all',
                        onTap: () => setState(() => _filter = 'all'),
                      ),
                      const SizedBox(width: 8),
                      CtChip(
                        label: 'Публичные',
                        active: _filter == 'public',
                        onTap: () => setState(() => _filter = 'public'),
                      ),
                      const SizedBox(width: 8),
                      CtChip(
                        label: 'Приватные',
                        active: _filter == 'private',
                        onTap: () => setState(() => _filter = 'private'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _RepoTile extends StatelessWidget {
  final GhRepo repo;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onSelectTap;
  const _RepoTile({
    required this.repo,
    required this.onTap,
    required this.onSelectTap,
    this.selected = false,
  });

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    // RepaintBoundary вокруг тайла: при скролле списка соседние тайлы
    // не должны пере-рисовываться (их пиксели уже в кэше layer'а).
    // ListView и так оборачивает items в RepaintBoundary через
    // addRepaintBoundaries: true (дефолт), но явный bound тут не мешает
    // и стабилизирует поведение при ребилдах родителя.
    return RepaintBoundary(
      child: PressScale(
      onTap: onTap,
      scale: 0.99,
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
        decoration: BoxDecoration(
          color: pal.cont,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: repo.private
                        ? AppColors.orange
                        : AppColors.accent,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  alignment: Alignment.center,
                  child: Iconify(
                    repo.private
                        ? 'solar:lock-keyhole-bold'
                        : 'solar:folder-bold',
                    size: 19,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(repo.name,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: pal.text,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                      const SizedBox(height: 2),
                      Text(repo.fullName,
                          style: TextStyle(
                            fontSize: 12,
                            color: pal.sub,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                    ],
                  ),
                ),
                _SelectCircle(
                  selected: selected,
                  onTap: onSelectTap,
                ),
              ],
            ),
            if (repo.description.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                repo.description,
                style: TextStyle(fontSize: 13, color: pal.sub, height: 1.35),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
            const SizedBox(height: 10),
            Row(children: [
              if (repo.language.isNotEmpty)
                // Баг n1964: цвет язычковой плашки берётся из текущей
                // палитры (pal.accent), а не из фиксированного purple —
                // теперь плашка подстраивается под выбранную тему/акцент.
                _Pill(text: repo.language, color: pal.accent),
              if (repo.language.isNotEmpty) const SizedBox(width: 6),
              StatPill(icon: 'solar:star-bold', value: '${repo.stars}'),
              const SizedBox(width: 12),
              StatPill(
                  icon: 'solar:code-bold', value: repo.defaultBranch),
            ]),
          ],
        ),
      ),
      ),
    );
  }
}

/// Кружок-чекбокс в карточке репо — «этот репо активный» (баг n1738/n2833).
class _SelectCircle extends StatelessWidget {
  final bool selected;
  final VoidCallback onTap;
  const _SelectCircle({required this.selected, required this.onTap});
  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    return PressScale(
      onTap: onTap,
      scale: 0.92,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        width: 26,
        height: 26,
        decoration: BoxDecoration(
          color: selected ? AppColors.accent : Colors.transparent,
          shape: BoxShape.circle,
          border: selected
              ? null
              : Border.all(
                  color: pal.sub.withValues(alpha: 0.45),
                  width: 1.5,
                ),
        ),
        alignment: Alignment.center,
        child: selected
            ? const Icon(Icons.check_rounded,
                size: 18, color: Colors.white)
            : null,
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  final String text;
  final Color color;
  const _Pill({required this.text, required this.color});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
