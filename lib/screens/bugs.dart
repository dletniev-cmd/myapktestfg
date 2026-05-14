import 'package:flutter/material.dart';
import '../widgets/m3_loading.dart';

import '../iconify.dart';
import '../navigation.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/long_press_menu.dart';
import 'bug_archive.dart';
import 'bug_constants.dart';
import 'bug_detail.dart';
import 'bug_new.dart';

class BugsScreen extends StatefulWidget {
  const BugsScreen({super.key});
  @override
  State<BugsScreen> createState() => _BugsScreenState();
}

class _BugsScreenState extends State<BugsScreen> {
  // all/bug/sugg/open/prog/done/high
  String _filter = 'all';
  // new/old/pri/title
  String _sort = 'new';

  /// id'шники багов, которые ПРЯМО СЕЙЧАС схлопываются после нажатия
  /// «Удалить». Пока id здесь — карточка ещё в `AppState.I.bugs`, но
  /// мы рендерим её как `SizedBox.shrink()` обёрнутый в AnimatedSize +
  /// AnimatedOpacity → высота плавно идёт с актуальной до 0, opacity
  /// уходит в 0. Остальные карточки сдвигаются вверх благодаря тому,
  /// что схлопывающаяся карточка сидит в том же ListView и резиновая.
  /// После завершения анимации id выкидывается из множества И из
  /// AppState — на тот момент карточка уже невидима, скачка нет.
  final Set<String> _deletingIds = {};

  static const List<({String k, String l})> _sortModes = [
    (k: 'new',   l: 'Новые'),
    (k: 'old',   l: 'Старые'),
    (k: 'pri',   l: 'По приоритету'),
    (k: 'title', l: 'По алфавиту'),
  ];

  String _sortLabel() => _sortModes.firstWhere((m) => m.k == _sort).l;

  void _cycleSort() {
    final i = _sortModes.indexWhere((m) => m.k == _sort);
    setState(() => _sort = _sortModes[(i + 1) % _sortModes.length].k);
  }

  /// Анимированное удаление: помечаем id как удаляющийся (карточка
  /// плавно схлопывается + остальные едут вверх), а потом, когда
  /// анимация завершилась, реально выкидываем баг из AppState.
  void _deleteBugAnimated(String id) {
    if (_deletingIds.contains(id)) return;
    setState(() => _deletingIds.add(id));
    Future.delayed(const Duration(milliseconds: 280), () {
      if (!mounted) return;
      AppState.I.bugs.removeWhere((e) => e.id == id);
      AppState.I.saveBugs();
      // Снимаем флаг и триггерим финальный rebuild — карточка к этому
      // моменту уже схлопнута до нуля, так что визуально ничего не
      // прыгнет.
      setState(() => _deletingIds.remove(id));
      AppState.I.touch();
    });
  }

  // Сигнатура списка багов, на которую BugsScreen реально реагирует.
  // Без этого `_onState` дёргал setState() на КАЖДЫЙ notifyListeners()
  // (фоновой build-poller, прогресс заливки, изменение темы и т.п.) —
  // отсюда «лаги при прокрутке» багов, когда в фоне что-то крутилось.
  int _lastBugsSig = 0;

  int _computeBugsSig() {
    final l = AppState.I.bugs;
    // Дешёвая сигнатура: длина и сумма по id-shape багов. Этого хватает
    // чтобы заметить добавление/удаление/смену статуса/приоритета.
    var sig = l.length * 1315423911;
    for (final b in l) {
      sig ^= b.id.hashCode;
      sig ^= b.status.hashCode * 31;
      sig ^= b.priority.hashCode * 17;
      sig ^= b.kind.hashCode * 7;
      sig ^= b.title.hashCode * 3;
    }
    return sig;
  }

  @override
  void initState() {
    super.initState();
    _lastBugsSig = _computeBugsSig();
    AppState.I.addListener(_onState);
  }

  @override
  void dispose() {
    AppState.I.removeListener(_onState);
    super.dispose();
  }

  void _onState() {
    final sig = _computeBugsSig();
    if (sig != _lastBugsSig) {
      _lastBugsSig = sig;
      if (mounted) setState(() {});
    }
  }

  void _openAddPop() {
    final pal = context.pal;
    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'add-pop',
      // Без затемнения фона — только прозрачный barrier для закрытия по тапу.
      barrierColor: Colors.transparent,
      // Раньше длительность была 160мс с easeOutCubic — на быстрых
      // устройствах меню «выпрыгивало» чуть резко (особенно с правого
      // верхнего угла). 240мс + изинг с лёгкой пружиной даёт более
      // мягкое и приятное появление, без overshooting.
      transitionDuration: const Duration(milliseconds: 240),
      pageBuilder: (_, __, ___) => const SizedBox.shrink(),
      transitionBuilder: (ctx, anim, _, __) {
        final scaleCurve =
            CurvedAnimation(parent: anim, curve: const Cubic(.2, .85, .25, 1));
        final opacityCurve =
            CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
        return Stack(
          children: [
            Positioned(
              top: MediaQuery.of(ctx).padding.top + 56,
              right: 12,
              child: ScaleTransition(
                scale: Tween<double>(begin: 0.86, end: 1.0).animate(scaleCurve),
                alignment: Alignment.topRight,
                child: FadeTransition(
                  opacity: opacityCurve,
                  child: Container(
                    width: 220,
                    decoration: BoxDecoration(
                      color: pal.cont,
                      borderRadius: BorderRadius.circular(14),
                      // «Конченую» жёсткую тень (black 30% / blur 22) убрали
                      // по просьбе пользователя. Оставили совсем лёгкий ambient-
                      // shadow (4% / blur 10), чтобы попап не «прилипал» как
                      // наклейка в светлой теме и была явная граница.
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: pal.isDark ? 0.0 : 0.04),
                          blurRadius: 10,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    clipBehavior: Clip.antiAlias,
                    // Material нужен чтобы Text получал DefaultTextStyle/
                    // TextDirection из ThemeData — без него Flutter в debug
                    // подчёркивает текст жёлтыми «волнами», а в release
                    // тоже остаются артефакты.
                    child: Material(
                      color: Colors.transparent,
                      child: Column(
                        children: [
                          _AddPopItem(
                            icon: 'solar:bug-bold',
                            color: AppColors.red,
                            title: 'Баг',
                            sub: 'Что-то работает не так',
                            onTap: () {
                              Navigator.of(ctx).pop();
                              pushSlide(context,
                                  const BugNewScreen(initialType: 'bug'));
                            },
                          ),
                          _AddPopItem(
                            icon: 'solar:lightbulb-bold',
                            color: AppColors.blue,
                            title: 'Предложение',
                            sub: 'Идея улучшения',
                            onTap: () {
                              Navigator.of(ctx).pop();
                              pushSlide(context,
                                  const BugNewScreen(initialType: 'sugg'));
                            },
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  /// Фаза кнопки скачивания. Переходы между фазами рендерятся
  /// плавно внутри _RingArchiveBtn — иконка и спиннер кросс-фейдятся,
  /// цвет спиннера плавно твинится между акцентом и зелёным.
  ArchiveBtnPhase _archivePhase = ArchiveBtnPhase.idle;
  double _headerH = 0;

  /// Скачивание архива багов с живой анимацией кнопки. Поведение,
  /// которое прямо просил юзер:
  ///   1. tap → phase = loading: иконка ИСЧЕЗАЕТ, на её месте появляется
  ///      спиннер акцентного цвета.
  ///   2. Работа + гарантия минимум 700мс (чтобы юзер увидел кручение
  ///      акцентного спиннера до того, как он позеленеет; иначе zip
  ///      собирается за ~50мс и фаза loading «промигивает»).
  ///   3a. Пусто или ошибка → плавный возврат в idle (спиннер гаснет,
  ///      иконка плавно проявляется).
  ///   3b. Успех → phase = success: ТОТ ЖЕ спиннер продолжает крутиться,
  ///      но его цвет плавно тwinится с акцента на зелёный (НИКАКОЙ
  ///      галочки — юзер прямо просил без неё). Зелёный спиннер крутится
  ///      ровно 2 секунды, а потом — плавный возврат в idle (спиннер
  ///      гаснет, иконка снова появляется).
  Future<void> _runArchive() async {
    if (_archivePhase != ArchiveBtnPhase.idle) return;
    setState(() => _archivePhase = ArchiveBtnPhase.loading);
    final startedAt = DateTime.now();
    ArchiveResult? res;
    Object? error;
    try {
      res = await downloadBugsArchive(context);
    } catch (e) {
      error = e;
    }
    final elapsed = DateTime.now().difference(startedAt);
    // Минимум 700мс на loading — чтобы пользователь успел увидеть, как
    // крутится акцентный спиннер ДО того, как он позеленеет. Иначе
    // зип собирается за ~50мс и переход loading→success происходит
    // моментально, без визуального смысла.
    const minDuration = Duration(milliseconds: 700);
    if (elapsed < minDuration) {
      await Future.delayed(minDuration - elapsed);
    }
    if (!mounted) return;

    final isSuccess =
        error == null && res != null && !res.empty;
    if (!isSuccess) {
      // Пусто/ошибка — плавный возврат в idle (спиннер гаснет,
      // иконка плавно проявляется).
      setState(() => _archivePhase = ArchiveBtnPhase.idle);
      return;
    }
    // Успех: тот же спиннер продолжает крутиться, но его цвет плавно
    // твинится с акцента на зелёный. «Крутится ещё 2 секунды зелёным»
    // — это юзерское требование (см. doc-комментарий выше). Никакой
    // галочки/чека на этом этапе нет, чтобы не пугать.
    setState(() => _archivePhase = ArchiveBtnPhase.success);
    await Future.delayed(const Duration(milliseconds: 2000));
    if (!mounted) return;
    setState(() => _archivePhase = ArchiveBtnPhase.idle);
  }

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    final activeRepo = AppState.I.activeRepo?.fullName;

    var bugs = AppState.I.bugs.toList();
    bugs = bugs.where((b) {
      if (_filter == 'bug' && b.type != 'bug') return false;
      if (_filter == 'sugg' && b.type != 'sugg') return false;
      if (['open', 'prog', 'done'].contains(_filter) &&
          b.status != _filter) return false;
      if (_filter == 'high' && b.priority != 'high') return false;
      return true;
    }).toList();
    const pr = {'high': 3, 'med': 2, 'low': 1};
    bugs.sort((a, b) {
      switch (_sort) {
        case 'old':
          return a.createdAtMs.compareTo(b.createdAtMs);
        case 'pri':
          return (pr[b.priority] ?? 0).compareTo(pr[a.priority] ?? 0);
        case 'title':
          return a.title.toLowerCase().compareTo(b.title.toLowerCase());
        case 'new':
        default:
          return b.createdAtMs.compareTo(a.createdAtMs);
      }
    });

    final topPad = _headerH > 0
        ? _headerH
        : MediaQuery.of(context).padding.top + 150;

    return Stack(
      children: [
        Positioned.fill(
          child: bugs.isEmpty
              ? ListView(
                  physics: const BouncingScrollPhysics(),
                  padding: EdgeInsets.fromLTRB(18, topPad, 18, 120),
                  children: [_BugsEmpty()],
                )
              : ListView(
                  // Не .builder — багов обычно <100, а ListView с явными
                  // children-ключами reconciliация делает идеально и
                  // никогда не «прыгает» при удалении: каждая карточка
                  // имеет свой ValueKey(bug.id), AnimatedSize-состояние
                  // привязано к карточке (а не к индексу в списке), так
                  // что анимация удаления + сдвига остальных идёт ровно
                  // одним проходом.
                  physics: const BouncingScrollPhysics(),
                  // Юзер (баг n7787): «когда тыкаешь на кнопку фильтра
                  // сортировки то при нажатии карточки чото прыгают».
                  // Причина — раньше у последней карточки `isLast=true`
                  // делал bottom padding = 0, у всех остальных = 10.
                  // При смене сортировки роль «последней» переходила к
                  // другому ID, у пары карточек bottom padding менялся
                  // 0↔10, AnimatedSize плавно проигрывал высоту — это и
                  // выглядело как «прыжок». Чиним так: bottom padding у
                  // ВСЕХ карточек одинаков (10), а финальный отступ
                  // списка переезжает в `padding` ListView (тогда никакой
                  // карточке не нужно знать «последняя ли она»).
                  padding: EdgeInsets.fromLTRB(18, topPad, 18, 110),
                  children: [
                    for (var i = 0; i < bugs.length; i++)
                      _BugListEntry(
                        // Ключ — id бага. Когда из списка пропадает
                        // элемент, Flutter сопоставляет оставшиеся
                        // карточки по ключам и не дёргает их state.
                        key: ValueKey('bug_${bugs[i].id}'),
                        bug: bugs[i],
                        deleting: _deletingIds.contains(bugs[i].id),
                        onTap: () => pushSlide(
                          context,
                          BugDetailScreen(id: bugs[i].id),
                        ),
                        onDelete: () => _deleteBugAnimated(bugs[i].id),
                      ),
                  ],
                ),
        ),
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: StickyTabHeader(
            // top=1 (а не 8) намеренно: в Actions внутри _LiveHead
            // под заголовком есть статус-строка («обновлено 2с
            // назад»), и Column с двумя строчками выходит выше 36px
            // (высота кнопки рефреша), поэтому Row(center) ставит
            // заголовок «Идёт сборка» практически в самый верх
            // StickyTabHeader-блока. У нас же тут только один заголовок
            // «Баги» — Row(center) бы вытянул его на (36-22)/2 = 7px
            // вниз. Подрезаем верхний паддинг StickyTabHeader на эти
            // 7px, чтобы базовая линия «Баги» совпала с «Идёт сборка»
            // на экране Actions. Юзер прямо просил: «надо сделать
            // одинаково на ровне с Actions!!!».
            padding: const EdgeInsets.fromLTRB(0, 1, 0, 12),
            onHeightChanged: (h) {
              if ((h - _headerH).abs() > 0.5) {
                setState(() => _headerH = h);
              }
            },
            children: [
              // Title row. Внутренний `top: 4` синхронизирован с
              // Profile и Actions (там тоже +4 поверх 8 у самого
              // StickyTabHeader/scroll) — чтобы заголовок «Баги»
              // стоял на той же Y-координате, что «Профиль» и
              // «Actions». Юзер жаловался: «заголовки в разделах
              // баги, профиль, actions почему-то везде на разной
              // высоте как будто».
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 4, 18, 12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          const Text('Баги',
                              style: TextStyle(
                                fontSize: 22,
                                fontWeight: FontWeight.w700,
                                letterSpacing: -.4,
                                height: 1.15,
                              )),
                          if (activeRepo != null) ...[
                            const SizedBox(width: 10),
                            Expanded(
                              child: Padding(
                                padding: const EdgeInsets.only(bottom: 3),
                                child: Text(
                                  activeRepo,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: pal.sub,
                                    fontWeight: FontWeight.w400,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    // Размеры кнопок в заголовке унифицированы:
                    // 36×36 бокс, 22 иконка — те же, что у
                    // RotatingRefreshBtn на Actions и у переключателя
                    // темы на Profile. Раньше «+» был 38/28, _RingArchiveBtn
                    // 38/22 — отсюда разнобой иконок между экранами.
                    _RingArchiveBtn(
                      phase: _archivePhase,
                      onTap: _runArchive,
                    ),
                    const SizedBox(width: 2),
                    IconBtn(
                      icon: 'solar:add-circle-bold',
                      iconSize: 22,
                      size: 36,
                      color: AppColors.accent,
                      onTap: _openAddPop,
                    ),
                  ],
                ),
              ),
              // Filter chips — edge-to-edge.
              SizedBox(
                height: 36,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  physics: const BouncingScrollPhysics(),
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                  children: [
                    _FfChip(
                        label: 'Все',
                        active: _filter == 'all',
                        onTap: () => setState(() => _filter = 'all')),
                    const SizedBox(width: 8),
                    _FfChip(
                        label: 'Баги',
                        icon: 'solar:bug-bold',
                        active: _filter == 'bug',
                        onTap: () => setState(() => _filter = 'bug')),
                    const SizedBox(width: 8),
                    _FfChip(
                        label: 'Идеи',
                        icon: 'solar:lightbulb-bold',
                        active: _filter == 'sugg',
                        onTap: () => setState(() => _filter = 'sugg')),
                    const SizedBox(width: 8),
                    _FfChip(
                        label: 'Открытые',
                        active: _filter == 'open',
                        onTap: () => setState(() => _filter = 'open')),
                    const SizedBox(width: 8),
                    _FfChip(
                        label: 'В работе',
                        active: _filter == 'prog',
                        onTap: () => setState(() => _filter = 'prog')),
                    const SizedBox(width: 8),
                    _FfChip(
                        label: 'Закрытые',
                        active: _filter == 'done',
                        onTap: () => setState(() => _filter = 'done')),
                    const SizedBox(width: 8),
                    _FfChip(
                        label: 'Высокий',
                        active: _filter == 'high',
                        onTap: () => setState(() => _filter = 'high')),
                  ],
                ),
              ),
              // Sort + count row
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${bugs.length} ${pluralRu(bugs.length, "запись", "записи", "записей")}',
                        style: TextStyle(
                            fontSize: 13,
                            color: pal.sub,
                            fontWeight: FontWeight.w500),
                      ),
                    ),
                    BlurredChip(
                      onTap: _cycleSort,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 7),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Text(_sortLabel(),
                              style: TextStyle(
                                  color: pal.text,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w500,
                                  height: 1.0)),
                          const SizedBox(width: 6),
                          Iconify('solar:sort-vertical-linear',
                              size: 15, color: pal.sub),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Фазы кнопки скачивания архива.
enum ArchiveBtnPhase { idle, loading, success }

/// Круглая кнопка скачивания архива багов с тремя фазами:
///   - idle:    видна ТОЛЬКО иконка скачивания. Спиннера нет.
///   - loading: иконка полностью исчезает (opacity 0), на её месте
///              крутится спиннер акцентного цвета.
///   - success: ТОТ ЖЕ спиннер продолжает крутиться (никаких галочек
///              и чек-иконок — юзер явно просил без них), но его цвет
///              плавно твинится с акцента на зелёный. Получается:
///              «крутится ещё 2 секунды зелёным», как и просил юзер.
///
/// Переходы плавные:
///   * иконка ⇄ спиннер — через AnimatedOpacity (один кросс-фейд);
///   * акцент → зелёный — через TweenAnimationBuilder<Color>, который
///     при пересборке (фаза сменилась) плавно интерполирует цвет.
///
/// Историческая справка: раньше тут был ещё слой «завершённого»
/// зелёного кольца + иконка-чек в AnimatedSwitcher. Юзер жаловался:
/// «иконка остаётся и под ней появляется анимация, ещё эта зелёная
/// галочка…» — поэтому всё это убрано в пользу одного спиннера,
/// который меняет цвет.
class _RingArchiveBtn extends StatelessWidget {
  final ArchiveBtnPhase phase;
  final VoidCallback onTap;
  const _RingArchiveBtn({required this.phase, required this.onTap});

  static const Duration _fadeDur = Duration(milliseconds: 320);
  static const Duration _colorDur = Duration(milliseconds: 420);

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    final isIdle = phase == ArchiveBtnPhase.idle;
    final isSuccess = phase == ArchiveBtnPhase.success;
    // Целевой цвет спиннера: в success — зелёный, иначе (loading и
    // idle, где спиннер всё равно невидим) — акцентный. Переход
    // loading→success плавно интерполируется через TweenAnimationBuilder.
    final spinnerColor =
        isSuccess ? AppColors.green : AppColors.accent;
    return PressScale(
      onTap: isIdle ? onTap : null,
      scale: 0.92,
      // 36×36 — тот же бокс, что у IconBtn/RotatingRefreshBtn на других
      // экранах. Внутренний спиннер 30×30 и иконка 22 — визуальный
      // «прицел» вокруг иконки.
      child: SizedBox(
        width: 36,
        height: 36,
        child: Stack(
          alignment: Alignment.center,
          children: [
            // Спиннер — виден в loading И success. При переходе
            // loading→success свой opacity не меняет (1.0 в обеих
            // фазах), но цвет плавно твинится с акцента на зелёный.
            // При переходе success→idle (или loading→idle) — гаснет.
            AnimatedOpacity(
              duration: _fadeDur,
              curve: Curves.easeOutCubic,
              opacity: isIdle ? 0.0 : 1.0,
              child: SizedBox(
                width: 30,
                height: 30,
                child: TweenAnimationBuilder<Color?>(
                  duration: _colorDur,
                  curve: Curves.easeInOutCubic,
                  tween: ColorTween(end: spinnerColor),
                  builder: (ctx, color, _) => M3LoadingIndicator(
                    strokeWidth: 2.5,
                    strokeCap: StrokeCap.round,
                    color: color ?? spinnerColor,
                    backgroundColor: pal.cont2,
                  ),
                ),
              ),
            ),
            // Иконка «solar:download-square-bold». Видна ТОЛЬКО в idle —
            // в loading/success полностью скрыта (opacity 0). Юзер
            // жаловался: «иконка остаётся и под ней появляется
            // анимация» — теперь иконка плавно ИСЧЕЗАЕТ одновременно
            // с появлением спиннера.
            AnimatedOpacity(
              duration: _fadeDur,
              curve: Curves.easeOutCubic,
              opacity: isIdle ? 1.0 : 0.0,
              child: Iconify(
                'solar:download-square-bold',
                size: 22,
                color: pal.text,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AddPopItem extends StatelessWidget {
  final String icon;
  final Color color;
  final String title;
  final String sub;
  final VoidCallback onTap;
  const _AddPopItem({
    required this.icon,
    required this.color,
    required this.title,
    required this.sub,
    required this.onTap,
  });
  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    // Без InkWell/Material splash — чистый тап, как в HTML.
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        child: Row(
          children: [
            Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(9),
              ),
              alignment: Alignment.center,
              child: Iconify(icon, size: 17, color: Colors.white),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(title,
                      style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: pal.text)),
                  const SizedBox(height: 1),
                  Text(sub,
                      style: TextStyle(fontSize: 11, color: pal.sub)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FfChip extends StatelessWidget {
  final String label;
  final String? icon;
  final bool active;
  final VoidCallback onTap;
  const _FfChip(
      {required this.label,
      required this.active,
      required this.onTap,
      this.icon});
  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    // Блюр-чип баг n1447: сами плашки фильтрации «стеклянные» — фон
    // под ними размывается, а не фон всей шапки. Текст сильно
    // выровнен вертикально (height: 1.0) — раньше выглядел «криво» (баг n1738).
    return BlurredChip(
      onTap: onTap,
      active: active,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (icon != null) ...[
            Iconify(icon!,
                size: 15,
                color: active ? Colors.white : pal.text),
            const SizedBox(width: 6),
          ],
          Text(label,
              style: TextStyle(
                color: active ? Colors.white : pal.text,
                fontSize: 13,
                fontWeight: FontWeight.w500,
                height: 1.0,
              )),
        ],
      ),
    );
  }
}

class _BugsEmpty extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Iconify('solar:inbox-bold',
              size: 56, color: pal.sub.withValues(alpha: 0.5)),
          const SizedBox(height: 12),
          Text('Пока пусто',
              style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                  color: pal.text)),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              'Нажмите «+» чтобы добавить баг или предложение',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: pal.sub, height: 1.5),
            ),
          ),
        ],
      ),
    );
  }
}

// Расширенная палитра миниатюр (раньше было 7 цветов — фидбэк «расширь»).
// Цвета подобраны так, чтобы соседние карточки в списке не сливались
// и каждый имел отчётливо разный hue.
final List<Color> _kThumbColors = [
  AppColors.accent,
  AppColors.red,
  AppColors.orange,
  AppColors.yellow,
  AppColors.lime,
  AppColors.green,
  AppColors.teal,
  AppColors.cyan,
  AppColors.blue,
  AppColors.indigo,
  AppColors.purple,
  AppColors.magenta,
  AppColors.pink,
  AppColors.rose,
];

/// Цвет миниатюры карточки бага — детерминированный по id+времени создания.
/// 1-в-1 с HTML: одна и та же запись всегда получает один и тот же цвет.
/// Используется как в списке (`_BugCard`), так и на экране деталей
/// (`BugDetailScreen`) — раньше детали использовали `type.color` (всегда
/// красный для бага), из-за чего миниатюра в списке и в открытой карточке
/// отличались по цвету.
Color bugThumbColor(BugItem b) {
  final seed = '${b.id}|${b.createdAtMs}';
  // FNV-1a 32-bit — хорошо перемешивает биты.
  int h = 0x811C9DC5;
  for (var i = 0; i < seed.length; i++) {
    h ^= seed.codeUnitAt(i);
    h = (h * 0x01000193) & 0xFFFFFFFF;
  }
  return _kThumbColors[h % _kThumbColors.length];
}

/// Один элемент списка багов — карточка + bottom-gap + анимация
/// схлопывания при удалении. Ключ ставится снаружи (по bug.id), за счёт
/// чего AnimatedSize-state привязан к конкретному багу: при удалении
/// одной карточки остальные не «прыгают», а просто плавно сдвигаются
/// вверх.
class _BugListEntry extends StatelessWidget {
  final BugItem bug;
  final bool deleting;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  const _BugListEntry({
    super.key,
    required this.bug,
    required this.deleting,
    required this.onTap,
    required this.onDelete,
  });
  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: AnimatedSize(
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeInOutCubic,
        alignment: Alignment.topCenter,
        child: AnimatedOpacity(
          opacity: deleting ? 0.0 : 1.0,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
          child: deleting
              ? const SizedBox(width: double.infinity)
              // Постоянный bottom padding у всех карточек (включая
              // последнюю) — см. комментарий выше про баг n7787. Если
              // ставить 0 для последней, при смене сортировки карточки
              // визуально прыгают на 10px.
              : Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: _BugCard(
                    bug: bug,
                    onTap: onTap,
                    onDelete: onDelete,
                  ),
                ),
        ),
      ),
    );
  }
}

class _BugCard extends StatelessWidget {
  final BugItem bug;
  final VoidCallback onTap;
  /// Если задан — вызывается вместо обычного `removeWhere/touch` при
  /// нажатии на пункт «Удалить» в long-press меню. Нужен, чтобы экран
  /// мог сначала проиграть анимацию схлопывания карточки и только
  /// потом убрать её из state'а (см. _BugsScreenState._deletingIds).
  final VoidCallback? onDelete;
  const _BugCard({
    required this.bug,
    required this.onTap,
    this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    final kind = kKindMeta[bug.kind] ?? kKindMeta['other']!;
    final pri = kPriMeta[bug.priority] ?? kPriMeta['med']!;
    final st = kStatusMeta[bug.status] ?? kStatusMeta['open']!;
    final isBug = bug.type == 'bug';
    final thumbBg = bugThumbColor(bug);

    return LongPressMenu(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      menuBuilder: () => [
        CtxMenuItem(
            icon: 'solar:eye-bold', label: 'Открыть', onTap: onTap),
        CtxMenuItem(
          icon: bug.status == 'done'
              ? 'solar:refresh-linear'
              : 'solar:check-circle-bold',
          label: bug.status == 'done' ? 'Открыть снова' : 'Закрыть',
          onTap: () {
            bug.status = bug.status == 'done' ? 'open' : 'done';
            AppState.I.saveBugs();
            AppState.I.touch();
          },
        ),
        CtxMenuItem(
          icon: 'solar:trash-bin-2-bold',
          label: 'Удалить',
          danger: true,
          onTap: () {
            // Если родитель задал onDelete — он сам анимирует удаление
            // (схлопывание карточки + сдвиг остальных). Иначе fallback
            // на старое поведение (мгновенное удаление).
            if (onDelete != null) {
              onDelete!();
            } else {
              AppState.I.bugs.removeWhere((e) => e.id == bug.id);
              AppState.I.saveBugs();
              AppState.I.touch();
            }
          },
        ),
      ],
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
        decoration: BoxDecoration(
          color: pal.cont,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _BcThumb(
                  imageProvider: bug.shots.isNotEmpty
                      ? bug.imageProvider(0)
                      : null,
                  bg: thumbBg,
                  icon: isBug ? 'solar:bug-bold' : 'solar:lightbulb-bold',
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        bug.title.isEmpty ? '(без названия)' : bug.title,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: pal.text,
                          height: 1.25,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Text('#${bug.id.substring(bug.id.length - 4)}',
                              style: TextStyle(
                                  fontSize: 11.5, color: pal.sub)),
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
                                  fontSize: 11.5, color: pal.sub)),
                        ],
                      ),
                      if (bug.description.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text(bug.description,
                            style: TextStyle(
                                fontSize: 12.5,
                                color: pal.sub,
                                height: 1.4),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                _BcTag(label: st.label, color: st.color),
                _BcTag(
                    label: pri.label,
                    color: pri.color,
                    icon: 'solar:flag-bold'),
                _BcTag(
                    label: kind.label,
                    color: kind.color,
                    icon: kind.icon),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _BcThumb extends StatelessWidget {
  final ImageProvider? imageProvider;
  final Color bg;
  final String icon;
  const _BcThumb(
      {required this.imageProvider, required this.bg, required this.icon});
  @override
  Widget build(BuildContext context) {
    if (imageProvider != null) {
      final cachePx = (56 * MediaQuery.of(context).devicePixelRatio).round();
      return ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: Image(
            image: ResizeImage(imageProvider!, width: cachePx),
            width: 56,
            height: 56,
            fit: BoxFit.cover,
            gaplessPlayback: true),
      );
    }
    return Container(
      width: 56,
      height: 56,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(14),
      ),
      alignment: Alignment.center,
      child: Iconify(icon, size: 28, color: Colors.white),
    );
  }
}

class _BcTag extends StatelessWidget {
  final String label;
  final Color color;
  final String? icon;
  const _BcTag({required this.label, required this.color, this.icon});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Iconify(icon!, size: 12, color: color),
            const SizedBox(width: 4),
          ],
          Text(
            label.toUpperCase(),
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.w700,
              fontSize: 10,
              letterSpacing: .3,
            ),
          ),
        ],
      ),
    );
  }
}
