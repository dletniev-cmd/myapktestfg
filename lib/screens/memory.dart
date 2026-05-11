import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../state.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// Экран «Память» — донат-график с цветными сегментами по категориям
/// кэша + список с чек-боксами + кнопка очистки.
///
/// Сценарий входа:
/// 1. Сначала показывается чистый material-стиль спиннер (одиночная
///    дуга accent-цвета, вращается, минимум 2 секунды).
/// 2. После расчёта размеров и пройденной минимальной задержки —
///    спиннер уезжает, опускается на место **трек-кольцо** (серое
///    «пустое» кольцо), карточка-список появляется через
///    [AnimatedOpacity], и цветные сегменты «прорастают» из нулей до
///    своих долей через [_ringCtrl] с easeInOutCubic. Микро-сегменты
///    (sweep < _kSegmentFadeSweep) рисуются с понижающейся альфой,
///    чтобы не возникало визуальных «писюлек», появляющихся/исчезающих
///    резко.
///
/// На действиях:
/// - При тоггле чекбокса сегменты плавно растягиваются/съёживаются
///   (сетка гэпов стабильна — все «слоты», что были видимы или будут
///   видимы в этом tween, держат место, поэтому соседи не дёргаются).
/// - При очистке нет диалога подтверждения, ring плавно сворачивается
///   к нулю синхронно с тем, как меняются `bytes` категорий → 0.
class MemoryScreen extends StatefulWidget {
  const MemoryScreen({super.key});
  @override
  State<MemoryScreen> createState() => _MemoryScreenState();
}

class _CacheCategory {
  final String id;
  final String label;
  final Color color;
  int bytes;
  bool selected = true;
  final Future<void> Function() clear;
  _CacheCategory({
    required this.id,
    required this.label,
    required this.color,
    this.bytes = 0,
    required this.clear,
  });
}

// Размер донат-кольца (квадрат SizedBox + Size.square). Снижен с 188
// до 168 — кольцо компактнее. При этом относительная
// толщина (_kStrokeRatio) повышена с 0.16 до 0.20 — обводка
// визуально немного толще как в v75. Оба входят в painter.
const double _kDonutSize = 168.0;
const double _kStrokeRatio = 0.20;

const _kMinSpinnerMs = 2200;
// Длительность tween-морфа кольца. Поднята с 600 до 900 мс, чтобы
// смена долей сегментов выглядела плавно, а маленькие «писюльки»
// успевали мягко прорасти/рассосаться (см. fade в [_DonutPainter]).
const _kRingMorphMs = 900;
const _kFadeInMs = 360;
// Сегмент с sweep ниже этого порога рисуется с понижающейся альфой
// — это убирает резкие появления/исчезновения «точечек» при малых
// долях. Значение в радианах (≈ 6° дуги).
const double _kSegmentFadeSweep = 0.105;

class _MemoryScreenState extends State<MemoryScreen>
    with TickerProviderStateMixin {
  bool _loading = true;
  bool _clearing = false;
  bool _showCard = false; // controls fade-in of the list card
  List<_CacheCategory> _items = [];

  late final AnimationController _spinCtrl;
  late final AnimationController _ringCtrl;

  // «from» / «to» доли сегментов. Во время _ringCtrl значение
  // интерполируется через [_curved] (easeInOutCubic).
  List<double> _ringFrom = [];
  List<double> _ringTo = [];
  // Маска «слот занят» — стабильна в течение одного tween. Если
  // segment либо начал, либо закончит с ненулевой долей — слот считается
  // занятым весь tween, и его «гэп» не схлопывается.
  List<bool> _ringUsed = [];
  int _totalFrom = 0;
  int _totalTo = 0;

  late Animation<double> _curved;

  @override
  void initState() {
    super.initState();
    _spinCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    )
      ..addListener(() {
        if (_loading && mounted) setState(() {});
      })
      ..repeat();
    _ringCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: _kRingMorphMs),
    );
    // easeInOutCubic даёт плавный старт и плавный финиш — без рывка
    // в начале и без резкого «защёлкивания» в конце. Раньше было
    // easeOutCubic — оно начинается слишком резко.
    _curved = CurvedAnimation(parent: _ringCtrl, curve: Curves.easeInOutCubic);
    _curved.addListener(() => setState(() {}));
    _build(initial: true);
  }

  @override
  void dispose() {
    _spinCtrl.dispose();
    _ringCtrl.dispose();
    super.dispose();
  }

  int _shown(_CacheCategory c) => c.selected ? c.bytes : 0;

  void _animateRing({bool fromZero = false}) {
    final newTotal = _items.fold<int>(0, (a, c) => a + _shown(c));
    final newFracs = _items.map((c) {
      if (newTotal == 0) return 0.0;
      return _shown(c) / newTotal;
    }).toList();
    final t = _curved.value;
    final List<double> snapshot;
    if (fromZero) {
      snapshot = List.filled(_items.length, 0.0);
    } else if (_ringFrom.length == _ringTo.length &&
        _ringFrom.length == _items.length) {
      snapshot = [
        for (var i = 0; i < _ringFrom.length; i++)
          _lerpD(_ringFrom[i], _ringTo[i], t),
      ];
    } else if (_ringTo.length == _items.length) {
      snapshot = List.of(_ringTo);
    } else {
      snapshot = List.filled(_items.length, 0.0);
    }
    _ringFrom = snapshot;
    _ringTo = newFracs;
    // «Слот занят» = в from или to есть ненулевая доля. Удерживаем
    // место под него на всё время tween, чтобы расчёт гэпов не плыл.
    _ringUsed = [
      for (var i = 0; i < _items.length; i++)
        (_ringFrom[i] > _kEpsilon) || (_ringTo[i] > _kEpsilon),
    ];
    if (fromZero) {
      _totalFrom = 0;
    } else {
      _totalFrom = (_totalFrom * (1 - t) + _totalTo * t).round();
    }
    _totalTo = newTotal;
    _ringCtrl.forward(from: 0);
  }

  Future<void> _build({bool initial = false, bool silent = false}) async {
    // silent=true — фон-пересчёт без показа спиннера (используется после
    // очистки, чтобы лейаут не дёргался и не было скачка скролла).
    if (!initial && !silent) setState(() => _loading = true);
    final started = DateTime.now();
    final s = AppState.I;

    // Категория «Профиль» убрана из списка Памяти: данные
    // профиля кэшируются внутренне и очищать их пользователю
    // несколько рискованно (вылетают аватары в шапке и т.п.).

    int reposBytes = 0;
    if (s.repos.isNotEmpty) {
      try {
        reposBytes = utf8
            .encode(jsonEncode(s.repos.map((r) => r.toJson()).toList()))
            .length;
      } catch (_) {}
    }

    int runsBytes = 0;
    final runs = s.cachedRuns;
    if (runs != null) {
      for (final r in runs) {
        runsBytes += r.name.length +
            r.status.length +
            r.conclusion.length +
            r.headBranch.length +
            r.headCommit.length +
            r.createdAt.length +
            r.updatedAt.length +
            r.runStartedAt.length +
            r.htmlUrl.length +
            r.event.length +
            r.workflowName.length +
            64;
      }
    }

    final bugsBytes = await s.bugsFileSize();
    final stagedBytes =
        s.stagedFiles.values.fold<int>(0, (acc, b) => acc + b.length);
    final apksBytes = await s.downloadedApksSize();

    // Минимальная длительность спиннера — 2.2 секунды для первого
    // показа, чтобы анимация была заметной.
    if (initial) {
      final elapsedMs = DateTime.now().difference(started).inMilliseconds;
      final waitMs = _kMinSpinnerMs - elapsedMs;
      if (waitMs > 0) {
        await Future<void>.delayed(Duration(milliseconds: waitMs));
      }
    }
    if (!mounted) return;

    final next = [
      _CacheCategory(
        id: 'repos',
        label: 'Репозитории',
        color: AppColors.purple,
        bytes: reposBytes,
        clear: AppState.I.clearReposCache,
      ),
      _CacheCategory(
        id: 'runs',
        label: 'Сборки',
        color: AppColors.orange,
        bytes: runsBytes,
        clear: AppState.I.clearRunsCache,
      ),
      _CacheCategory(
        id: 'bugs',
        label: 'Баг-репорты',
        color: AppColors.pink,
        bytes: bugsBytes,
        clear: AppState.I.clearBugsCache,
      ),
      _CacheCategory(
        id: 'staged',
        label: 'Файлы для коммита',
        color: AppColors.green,
        bytes: stagedBytes,
        clear: () async => AppState.I.clearStagedFiles(),
      ),
      _CacheCategory(
        id: 'apks',
        label: 'Скачанные APK',
        color: AppColors.yellow,
        bytes: apksBytes,
        clear: () async {
          await AppState.I.clearDownloadedApks();
        },
      ),
    ];
    for (final n in next) {
      final old = _items.where((p) => p.id == n.id).cast<_CacheCategory?>();
      if (old.isNotEmpty) n.selected = old.first!.selected;
    }
    setState(() {
      _items = next;
      _loading = false;
      _showCard = true;
    });
    _animateRing(fromZero: initial && !silent);
  }

  Future<void> _doClear() async {
    final toClear = _items.where((i) => i.selected && i.bytes > 0).toList();
    if (toClear.isEmpty) return;
    if (!mounted) return;
    setState(() => _clearing = true);
    // Вместо абруптного `bytes = 0` после await — обнуляем сначала
    // в локальной модели и сразу пускаем `_animateRing`, чтобы кольцо
    // плавно ушло в ноль одновременно с очисткой.
    for (final c in toClear) {
      c.bytes = 0;
    }
    _animateRing();
    for (final c in toClear) {
      try {
        await c.clear();
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() => _clearing = false);
    // ВАЖНО: при пост-clear пересчёте НЕ переключаем экран в режим
    // _loading=true. Иначе нижний поясняющий текст «Данные подтянутся…»
    // временно исчезает из дерева, высота скролл-контента уменьшается,
    // и ScrollView подтягивает viewport вверх — выглядит как «экран
    // резко прыгает наверх» после нажатия «Очистить» внизу.
    await _build(silent: true);
  }

  void _toggle(int i) {
    if (_items[i].bytes == 0) return;
    setState(() {
      _items[i].selected = !_items[i].selected;
    });
    _animateRing();
  }

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    final t = _curved.value;
    final animTotal =
        _loading ? 0 : (_totalFrom * (1 - t) + _totalTo * t).round();
    final selectedBytes = _items
        .where((c) => c.selected)
        .fold<int>(0, (acc, c) => acc + c.bytes);
    final hasAny = _items.any((c) => c.bytes > 0);

    return Scaffold(
      backgroundColor: pal.bg,
      body: Stack(
        children: [
          Positioned.fill(
            child: SingleChildScrollView(
              padding: EdgeInsets.only(
                top: MediaQuery.of(context).padding.top + kTopHeaderBarHeight,
                bottom: 32,
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SizedBox(height: 16),
                    Center(
                      child: SizedBox(
                        width: _kDonutSize,
                        height: _kDonutSize,
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            CustomPaint(
                              size: const Size.square(_kDonutSize),
                              painter: _DonutPainter(
                                loading: _loading,
                                spinT: _spinCtrl.value,
                                fromFracs: _ringFrom,
                                toFracs: _ringTo,
                                used: _ringUsed,
                                colors:
                                    _items.map((c) => c.color).toList(),
                                t: t,
                                trackColor: pal.isDark
                                    ? const Color(0xFF1C1C1E)
                                    : const Color(0xFFE0E0E5),
                                spinColor: pal.accent,
                              ),
                            ),
                            if (!_loading)
                              AnimatedOpacity(
                                duration: const Duration(
                                    milliseconds: _kFadeInMs),
                                opacity: _showCard ? 1.0 : 0.0,
                                // Оптическое выравнивание «число + единица» внутри
                                // кольца. baseline=alphabetic + жёсткий height для
                                // числа + нулевой верхний padding — число сидит
                                // ровно по центру, а «Б / КБ / МБ» под ним на 4пх.
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  crossAxisAlignment:
                                      CrossAxisAlignment.center,
                                  children: [
                                    Text(
                                      _fmtBytesNumber(animTotal),
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                        fontSize: 32,
                                        fontWeight: FontWeight.w600,
                                        color: pal.text,
                                        height: 1.0,
                                        // letterSpacing: -0.5 даёт плотный
                                        // «монетный» вид, как в iOS Storage.
                                        letterSpacing: -0.5,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      _fmtBytesUnit(animTotal),
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w500,
                                        color: pal.sub,
                                        height: 1.0,
                                        letterSpacing: 0.4,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 18),
                    Center(
                      child: Text(
                        'Использование памяти',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w600,
                          color: pal.text,
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 220),
                      child: Center(
                        key: ValueKey(_loading
                            ? 'loading'
                            : (hasAny ? 'data' : 'empty')),
                        child: Text(
                          _loading
                              ? 'Считаем размер кэша…'
                              : (hasAny
                                  ? 'Локальные данные приложения'
                                  : 'Локальный кэш пуст'),
                          style: TextStyle(
                            fontSize: 13,
                            color: pal.sub,
                            fontWeight: FontWeight.w400,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 22),
                    AnimatedOpacity(
                      duration:
                          const Duration(milliseconds: _kFadeInMs),
                      curve: Curves.easeOut,
                      opacity: _showCard ? 1.0 : 0.0,
                      child: AnimatedSlide(
                        duration:
                            const Duration(milliseconds: _kFadeInMs),
                        curve: Curves.easeOutCubic,
                        offset: _showCard
                            ? Offset.zero
                            : const Offset(0, 0.06),
                        child: IgnorePointer(
                          ignoring: !_showCard,
                          child: _Card(
                            child: Column(
                              children: [
                                for (var i = 0; i < _items.length; i++) ...[
                                  // Разделительные линии между категориями убраны —
                                  // ряды визуально разделены паддингом внутри _CategoryRow.
                                  _CategoryRow(
                                    item: _items[i],
                                    total: _items.fold<int>(
                                        0, (a, c) => a + c.bytes),
                                    onTap: _clearing
                                        ? null
                                        : () => _toggle(i),
                                  ),
                                ],
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                      12, 6, 12, 12),
                                  child: _ClearButton(
                                    bytes: selectedBytes,
                                    enabled:
                                        selectedBytes > 0 && !_clearing,
                                    loading: _clearing,
                                    onTap: _doClear,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                    // Пояснительный текст всегда в дереве (даже пока спиннеръ
                    // крутится) — это важно, чтобы высота скролл-контента
                    // не прыгала. При загрузке просто фейдим
                    // прозрачность в 0, а слот остаётся.
                    const SizedBox(height: 12),
                    AnimatedOpacity(
                      duration:
                          const Duration(milliseconds: _kFadeInMs),
                      opacity: (!_loading && _showCard) ? 1.0 : 0.0,
                      child: Text(
                        'Данные подтянутся заново при следующем '
                        'открытии соответствующего экрана. Токен '
                        'GitHub и настройки темы очистка не трогает.',
                        style: TextStyle(
                          fontSize: 13,
                          height: 1.4,
                          color: pal.sub,
                          fontWeight: FontWeight.w400,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: TopFadeHeader(title: 'Память'),
          ),
        ],
      ),
    );
  }
}

class _Card extends StatelessWidget {
  final Widget child;
  const _Card({required this.child});
  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    return Container(
      decoration: BoxDecoration(
        color: pal.cont,
        borderRadius: BorderRadius.circular(18),
      ),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }
}

const double _kEpsilon = 0.0008;

class _DonutPainter extends CustomPainter {
  final bool loading;
  final double spinT;
  final List<double> fromFracs;
  final List<double> toFracs;
  final List<bool> used;
  final List<Color> colors;
  final double t;
  final Color trackColor;
  final Color spinColor;
  _DonutPainter({
    required this.loading,
    required this.spinT,
    required this.fromFracs,
    required this.toFracs,
    required this.used,
    required this.colors,
    required this.t,
    required this.trackColor,
    required this.spinColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width, size.height) / 2 - 4;
    final stroke = radius * _kStrokeRatio;
    final ringRadius = radius - stroke / 2;
    final rect = Rect.fromCircle(center: center, radius: ringRadius);

    // Трек-кольцо (всегда).
    canvas.drawCircle(
      center,
      ringRadius,
      Paint()
        ..color = trackColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke,
    );

    if (loading) {
      // Material-like спиннер: одиночная дуга ровного цвета, ~75° sweep,
      // вращается вокруг центра. Никаких градиентов — это и давало
      // тот «полный полупрозрачный круг + кусок» на предыдущей сборке.
      final rotation = -math.pi / 2 + spinT * 2 * math.pi;
      const sweep = math.pi * 0.42; // ≈ 75°
      canvas.drawArc(
        rect,
        rotation,
        sweep,
        false,
        Paint()
          ..color = spinColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke
          ..strokeCap = StrokeCap.round,
      );
      return;
    }

    // Цветные сегменты с lerp from→to.
    final n = math.min(colors.length,
        math.min(fromFracs.length, toFracs.length));
    if (n == 0) return;

    // Стабильный список «занятых слотов» (не меняется в течение
    // одного tween → гэпы не дёргаются).
    final stableUsed = used.length == n
        ? used
        : [for (var i = 0; i < n; i++) toFracs[i] > _kEpsilon];

    final fracs = <double>[];
    for (var i = 0; i < n; i++) {
      fracs.add(_lerpD(fromFracs[i], toFracs[i], t));
    }
    final fracsSum =
        fracs.fold<double>(0, (a, b) => a + math.max(0, b));
    if (fracsSum <= 0.0001) return;

    final usedCount = stableUsed.where((u) => u).length;
    final gap = usedCount > 1 ? 0.045 : 0.0;
    final totalSweep = 2 * math.pi - gap * usedCount;
    double start = -math.pi / 2 + gap / 2;
    for (var i = 0; i < n; i++) {
      if (!stableUsed[i]) continue;
      // Раньше было f = fracs[i] / visibleSum (нормализация).
      // Баг: при growing-in из нуля, если видим лишь один сегмент,
      // в любой момент fracs[i] = весь visibleSum, из-за чего
      // f ≡ 1 и sweep мгновенно прыгал в полный круг при t > 0.
      // Теперь свип идёт напрямую от реальной доли (на t=1
      // сумма = 1, донат закрывается; во время «прорастания»
      // сумма < 1, донат «растёт» пропорционально — больше
      // нет резкого «скачка в полный круг» при единственном выбранном.
      final f = math.max(0.0, fracs[i]).clamp(0.0, 1.0);
      final sweep = totalSweep * f;
      if (sweep > 0) {
        // Плавный fade для микро-сегментов: когда sweep < _kSegmentFadeSweep,
        // альфа падает пропорционально — «писюльки» не появляются/не
        // исчезают резко, а мягко прорастают/рассасываются.
        final alpha = (sweep / _kSegmentFadeSweep).clamp(0.0, 1.0);
        // Для очень малых sweep отключаем round-cap, иначе
        // округлённые концы рисуют «точку» размером в ширину строки,
        // которая визуально всё равно выражена и воспринимается как
        // скачок, даже если альфа падает. Ниже _kEpsilon вообще не
        // рисуем — альфа там уже практически ноль.
        if (alpha > 0.005) {
          canvas.drawArc(
            rect,
            start,
            sweep,
            false,
            Paint()
              ..color = colors[i].withValues(alpha: alpha)
              ..style = PaintingStyle.stroke
              ..strokeWidth = stroke
              ..strokeCap = sweep < 0.012
                  ? StrokeCap.butt
                  : StrokeCap.round,
          );
        }
      }
      // Слот удерживает место (gap), даже если sweep сейчас 0 —
      // соседям не нужно «перепрыгивать».
      start += sweep + gap;
    }
  }

  @override
  bool shouldRepaint(covariant _DonutPainter old) =>
      old.t != t ||
      old.spinT != spinT ||
      old.loading != loading ||
      old.colors.length != colors.length ||
      old.toFracs.length != toFracs.length;
}

class _CategoryRow extends StatelessWidget {
  final _CacheCategory item;
  final int total;
  final VoidCallback? onTap;
  const _CategoryRow({
    required this.item,
    required this.total,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    final empty = item.bytes == 0;
    final percent =
        total > 0 ? (item.bytes / total * 100).clamp(0.0, 100.0) : 0.0;
    final percentStr = percent < 1 && percent > 0
        ? '<1%'
        : '${percent.toStringAsFixed(0)}%';
    // Раньше был InkWell — он даёт серый Material-ripple с прямыми
    // углами. На первой/последней строке рябь или выходы «за края
    // контейнера» были видны. Заменили на PressScale — в стиле
    // остального приложения, без серого фона.
    return PressScale(
      onTap: empty ? null : onTap,
      scale: 0.985,
      child: Opacity(
        opacity: empty ? 0.4 : 1.0,
        child: Padding(
          padding:
              const EdgeInsets.symmetric(vertical: 13, horizontal: 14),
          child: Row(
            children: [
              _Checkbox(
                active: item.selected && !empty,
                color: item.color,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        item.label,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w400,
                          color: pal.text,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (!empty) ...[
                      const SizedBox(width: 8),
                      Text(
                        percentStr,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w400,
                          color: pal.sub,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Text(
                empty ? 'пусто' : _fmtBytes(item.bytes),
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w400,
                  color: empty ? pal.sub : pal.accent,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Checkbox extends StatelessWidget {
  final bool active;
  final Color color;
  const _Checkbox({required this.active, required this.color});

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      width: 22,
      height: 22,
      decoration: BoxDecoration(
        color: active ? color : Colors.transparent,
        shape: BoxShape.circle,
        border: Border.all(
          color: active
              ? color
              : (pal.isDark
                  ? const Color(0xFF48484C)
                  : const Color(0xFFC7C7CC)),
          width: 1.8,
        ),
      ),
      alignment: Alignment.center,
      child: active
          ? const Icon(
              Icons.check_rounded,
              size: 14,
              color: Colors.white,
            )
          : const SizedBox.shrink(),
    );
  }
}

class _ClearButton extends StatelessWidget {
  final int bytes;
  final bool enabled;
  final bool loading;
  final VoidCallback onTap;
  const _ClearButton({
    required this.bytes,
    required this.enabled,
    required this.loading,
    required this.onTap,
  });
  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    final bg = enabled
        ? pal.accent
        : (pal.isDark
            ? const Color(0xFF2A2A2E)
            : const Color(0xFFD8D8DC));
    final fg = enabled ? Colors.white : pal.sub;
    return PressScale(
      onTap: enabled ? onTap : null,
      scale: 0.97,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        height: 46,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(23),
        ),
        child: loading
            ? SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                  color: fg,
                  strokeWidth: 2.4,
                  strokeCap: StrokeCap.round,
                ),
              )
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    bytes > 0 ? 'Очистить кэш' : 'Ничего не выбрано',
                    style: TextStyle(
                      color: fg,
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  if (bytes > 0) ...[
                    const SizedBox(width: 8),
                    Text(
                      _fmtBytes(bytes),
                      style: TextStyle(
                        color: fg.withValues(alpha: 0.85),
                        fontSize: 15,
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                  ],
                ],
              ),
      ),
    );
  }
}

double _lerpD(double a, double b, double t) => a + (b - a) * t;

String _fmtBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  double v = bytes.toDouble();
  int i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  final precision = (i == 0 || v >= 100) ? 0 : (v >= 10 ? 1 : 2);
  return '${v.toStringAsFixed(precision)} ${units[i]}';
}

String _fmtBytesNumber(int bytes) {
  if (bytes <= 0) return '0';
  double v = bytes.toDouble();
  int i = 0;
  while (v >= 1024 && i < 4) {
    v /= 1024;
    i++;
  }
  final precision = (i == 0 || v >= 100) ? 0 : 1;
  return v.toStringAsFixed(precision).replaceAll('.', ',');
}

String _fmtBytesUnit(int bytes) {
  if (bytes <= 0) return 'B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  double v = bytes.toDouble();
  int i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return units[i];
}
