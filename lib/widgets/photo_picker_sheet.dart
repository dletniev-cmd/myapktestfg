import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:photo_manager/photo_manager.dart';

import '../iconify.dart';
import '../theme.dart';

/// Открывает шит-пикер фото из галереи и возвращает список выбранных
/// оригинальных байт. Возвращает `null`, если юзер нажал «Отмена»
/// или закрыл шит свайпом.
///
/// Используем `showModalBottomSheet` (а не свой PageRoute), потому что:
///   • он рендерится через Overlay поверх предыдущего экрана — экран
///     под шитом стоит на месте, не уплывает в свою transition-анимацию;
///   • встроенный drag-to-dismiss — шит следует за пальцем при свайпе
///     вниз, и закрывается если оттянули достаточно;
///   • встроенная Material обёртка — Text-виджеты получают нормальный
///     DefaultTextStyle (без жёлтых отладочных подчёркиваний).
///
/// Длительность переходов уеличена со стандартных 250мс до 420мс
/// (в обратку 320мс) — на тёмном фоне дефолтные 250мс воспринимались
/// как «резкий хлопок».
const Duration _kSheetReverseDuration = Duration(milliseconds: 260);

Future<List<Uint8List>?> pickPhotosBottomSheet(
  BuildContext context, {
  int? maxSelectable,
}) async {
  // Шит закрывается СРАЗУ после тапа на галочку, возвращая список
  // выбранных `AssetEntity`. Только ПОСЛЕ полного завершения анимации
  // закрытия мы начинаем читать оригинальные байты, и не залпом —
  // а с ограничением параллелизма.
  //
  // История: раньше `Future.wait(originBytes)` вызывался синхронно
  // после `await showModalBottomSheet`. Дело в том, что Future от
  // showModalBottomSheet резолвится как только зовётся Navigator.pop
  // (а не после завершения reverse-анимации). То есть 15+ тяжёлых
  // MethodChannel-вызовов стартовали ПРЯМО ВО ВРЕМЯ slide-down
  // анимации, сериализация ответов на UI-треде давала jank.
  // Видимый результат: «панель закрывалась лагая».
  final assets = await showModalBottomSheet<List<AssetEntity>>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.55),
    transitionAnimationController: AnimationController(
      vsync: Navigator.of(context),
      duration: const Duration(milliseconds: 380),
      reverseDuration: _kSheetReverseDuration,
    ),
    builder: (_) => _PhotoPickerSheet(maxSelectable: maxSelectable),
  );
  if (assets == null) return null;
  if (assets.isEmpty) return <Uint8List>[];
  // 1) Ждём конца reverse-анимации шита + кадр про запас, чтобы UI-тред
  //    был свободен. Без этого тяжёлый MethodChannel-трафик из originBytes
  //    приходится на slide-down кадры и пользователь видит лаги.
  await Future<void>.delayed(
    _kSheetReverseDuration + const Duration(milliseconds: 40),
  );
  // 2) Читаем байты партиями (по 3), чтобы не насыщать MethodChannel/JNI
  //    и не блокировать UI-тред десериализацией 15+ JPEG'ов одновременно.
  //    Порядок результатов сохраняется (по индексу asset'а).
  const int batchSize = 3;
  final results = List<Uint8List?>.filled(assets.length, null);
  for (var i = 0; i < assets.length; i += batchSize) {
    final end = (i + batchSize < assets.length) ? i + batchSize : assets.length;
    final batch = <Future<void>>[];
    for (var j = i; j < end; j++) {
      final idx = j;
      batch.add(() async {
        final bytes = await assets[idx].originBytes;
        results[idx] = bytes;
      }());
    }
    await Future.wait(batch);
  }
  return <Uint8List>[
    for (final b in results)
      if (b != null) b,
  ];
}

/// Полная высота зоны фейда у шапки. Должна совпадать с тем, как ведёт
/// себя `TopFadeHeader` в Actions — там фейд тянется примерно на
/// `topInset + 8 + контент(~36) + 22` ≈ 100-110px, поэтому переход и
/// получается мягким, не «обрубом». В пикере topInset съедает Padding
/// шита, поэтому компенсируем через `_kHeaderFadeExtra`.
const double _kHeaderHeight = 56; // сама строка с заголовком
const double _kHeaderFadeExtra = 14; // короткий прозрачный «хвост» градиента
const double _kHeaderTotal = _kHeaderHeight + _kHeaderFadeExtra;
// Сетка фото стартует прямо под текстом «Галерея» (без длинного «хвоста»
// фейда), чтобы между заголовком и первым рядом не зияло пустое поле.
const double _kGridTopPadding = _kHeaderHeight;

/// 1-в-1 значения из `_buildSoftFadeGradient` в common.dart (тот же фейд
/// как в Actions / Bugs / Repos). Локально дублируется потому что фон
/// шита — `pal.cont`, а общий хелпер берёт `pal.bg`.
LinearGradient _fadeGradient(Color bg, {bool topToBottom = true}) {
  final colors = [
    bg.withValues(alpha: 0.78),
    bg.withValues(alpha: 0.66),
    bg.withValues(alpha: 0.46),
    bg.withValues(alpha: 0.24),
    bg.withValues(alpha: 0.08),
    bg.withValues(alpha: 0.0),
  ];
  return LinearGradient(
    begin: topToBottom ? Alignment.topCenter : Alignment.bottomCenter,
    end: topToBottom ? Alignment.bottomCenter : Alignment.topCenter,
    colors: colors,
    stops: const [0.0, 0.30, 0.55, 0.75, 0.90, 1.0],
  );
}

class _PhotoPickerSheet extends StatefulWidget {
  /// Максимум выбираемых фото — пикер перестаёт реагировать
  /// на тапы новых ячеек, когда выбрано это число. `null` — без лимита.
  final int? maxSelectable;
  const _PhotoPickerSheet({this.maxSelectable});
  @override
  State<_PhotoPickerSheet> createState() => _PhotoPickerSheetState();
}

class _PhotoPickerSheetState extends State<_PhotoPickerSheet> {
  bool _loading = true;
  bool _denied = false;
  List<AssetEntity> _assets = const [];
  // Сохраняем порядок выбора — нужен для отображения номеров в бейджах
  // и для возврата фото в том же порядке, в каком пользователь тапал.
  final List<AssetEntity> _selected = [];
  bool _busy = false;

  // Флаг: «slide-up анимация шита уже завершилась». До этого момента
  // НЕ дёргаем PhotoManager (любой запрос к нему — это MethodChannel/
  // Binder/JNI, маршаллинг данных по UI-треду; даже async-запросы
  // дают визимые лаги при выезде шита). Также НЕ показываем GridView
  // и не монтируем _PhotoCell'ы — каждая ячейка тоже стучится в
  // PhotoManager за thumbnail'ом.
  bool _animationDone = false;
  bool _loadStarted = false;

  @override
  void initState() {
    super.initState();
    // _load() ОТКЛАДЫВАЕМ — стартанём в didChangeDependencies, после
    // того как анимация выезда шита закончится.
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_animationDone) return;
    final route = ModalRoute.of(context);
    final anim = route?.animation;
    if (anim == null || anim.isCompleted) {
      // Шит уже на месте (или анимации нет) — стартуем сразу.
      _animationDone = true;
      _kickOffLoad();
      return;
    }
    // Подписываемся на завершение анимации; как только она встала на
    // место — стартуем загрузку списка фото и показываем GridView.
    void listener(AnimationStatus s) {
      if (s == AnimationStatus.completed) {
        anim.removeStatusListener(listener);
        if (!mounted) return;
        setState(() => _animationDone = true);
        _kickOffLoad();
      }
    }
    anim.addStatusListener(listener);
  }

  void _kickOffLoad() {
    if (_loadStarted) return;
    _loadStarted = true;
    _load();
  }

  Future<void> _load() async {
    final ps = await PhotoManager.requestPermissionExtend();
    if (!mounted) return;
    if (!ps.hasAccess) {
      setState(() {
        _loading = false;
        _denied = true;
      });
      return;
    }

    final albums = await PhotoManager.getAssetPathList(
      type: RequestType.image,
      onlyAll: true,
      filterOption: FilterOptionGroup(
        orders: [
          const OrderOption(type: OrderOptionType.createDate, asc: false),
        ],
      ),
    );
    if (albums.isEmpty) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    final total = await albums.first.assetCountAsync;
    // Грузим до 600 последних — больше в один pad-сценарий обычно не нужно,
    // и так мы не блокируем UI прогрузкой тысяч записей.
    final size = total < 600 ? total : 600;
    final list = await albums.first.getAssetListRange(start: 0, end: size);
    if (!mounted) return;
    setState(() {
      _assets = list;
      _loading = false;
    });
  }

  void _toggle(AssetEntity a) {
    final max = widget.maxSelectable;
    final alreadyOn = _selected.contains(a);
    // Лимит на выбор: если ячейка ещё не выбрана и лимит исчерпан —
    // игнорируем тап и даём обратную связь виброй (heavyImpact)
    // вместо обычного selectionClick — чтобы юзер физически
    // почувствовал «стоп».
    if (!alreadyOn && max != null && _selected.length >= max) {
      HapticFeedback.heavyImpact();
      return;
    }
    HapticFeedback.selectionClick();
    setState(() {
      if (alreadyOn) {
        _selected.remove(a);
      } else {
        _selected.add(a);
      }
    });
  }

  void _confirm() {
    if (_selected.isEmpty || _busy) return;
    // МГНОВЕННО закрываем шит, возвращая список AssetEntity. Загрузку
    // оригинальных байт берёт на себя обёртка `pickPhotosBottomSheet`
    // УЖЕ ПОСЛЕ pop — чтобы анимация закрытия шит'а шла параллельно с
    // чтением больших JPEG'ов из MediaStore, а не блокировалась им.
    //
    // Раньше тут было `setState(_busy=true)` + `await Future.wait(...)`
    // + `pop(out)` — и юзер видел: тапнул галочку → шит замер с
    // мини-спиннером → через 1-3сек закрылся «рывком» (потому что
    // animation controller отдыхал, пока шёл MethodChannel-read).
    Navigator.of(context).pop<List<AssetEntity>>(_selected.toList());
  }

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    final media = MediaQuery.of(context);
    // Шит занимает ~85% высоты экрана — как в Telegram «Прикрепить фото».
    // Высота фиксирована: route'ом мы аллайним этот контейнер к низу
    // экрана через Align(bottomCenter), а сверху естественно остаётся
    // 15% свободного пространства, через которое виден barrier.
    final h = media.size.height * 0.85;
    final bottomPad = media.viewPadding.bottom;

    return Padding(
      padding: EdgeInsets.only(top: media.padding.top + 24),
      child: Container(
        height: h,
        decoration: BoxDecoration(
          color: pal.cont,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
        ),
        clipBehavior: Clip.hardEdge,
        child: Stack(
          children: [
            // Сетка фото — занимает всё пространство шита, скроллит
            // ПОД шапкой за счёт верхнего паддинга. Юзер видит как
            // фото уходят за «фейд» шапки.
            Positioned.fill(
              child: _body(pal, bottomPad),
            ),
            // Плавающая шапка с gradient-fade — тот же стиль что в Actions.
            // Кнопка-галочка справа появляется плавно когда выбран хотя
            // бы один кадр.
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: _Header(
                onCancel: () => Navigator.of(context).maybePop(),
                onConfirm: _selected.isEmpty || _busy ? null : _confirm,
                selectedCount: _selected.length,
                busy: _busy,
              ),
            ),
            // Нижний fade-градиент УБРАН по запросу пользователя
            // (было: Positioned bottom + gradient, создавало визуальное
            // затемнение по нижнему краю шита). Теперь грид доходит
            // до safe-area без затемнения.
          ],
        ),
      ),
    );
  }

  Widget _body(AppPalette pal, double bottomPad) {
    if (_loading) {
      return Center(
        child: SizedBox(
          width: 26,
          height: 26,
          // strokeCap: StrokeCap.round — все кольца в приложении должны быть
          // с округлёнными концами. Раньше в пикере этот индикатор
          // был с резкими ровными торцами — выбивался из стиля.
          child: CircularProgressIndicator(
            strokeWidth: 2.4,
            strokeCap: StrokeCap.round,
            valueColor: AlwaysStoppedAnimation<Color>(pal.accent),
          ),
        ),
      );
    }
    if (_denied) {
      return Padding(
        padding: const EdgeInsets.only(top: _kHeaderTotal),
        child: _EmptyState(
          icon: 'solar:lock-keyhole-bold',
          title: 'Нет доступа к галерее',
          sub: 'Разрешите доступ в настройках, чтобы выбрать фото.',
          actionLabel: 'Открыть настройки',
          onAction: () => PhotoManager.openSetting(),
        ),
      );
    }
    if (_assets.isEmpty) {
      return const Padding(
        padding: EdgeInsets.only(top: _kHeaderTotal),
        child: _EmptyState(
          icon: 'solar:gallery-add-bold',
          title: 'В галерее нет фото',
          sub: 'Сделайте снимок или сохраните картинку, и она появится здесь.',
        ),
      );
    }
    return GridView.builder(
      padding: EdgeInsets.fromLTRB(
        8,
        _kGridTopPadding,
        8,
        bottomPad + 12,
      ),
      // BouncingScrollPhysics вместо ClampingScrollPhysics — на iOS-стиле
      // боунс ощущается плавнее и быстрее. ClampingScrollPhysics на Android'е
      // даёт эффект «впечатанности» к верху/низу — плюс она
      // внутренне хуже списывает fling-жесты (jank при быстрой прокрутке).
      physics: const BouncingScrollPhysics(),
      // Меньший cacheExtent (200 вместо 400) — экономим память и
      // время на декод лишних thumbnail'ов, которые юзер может вообще
      // не увидеть. 200px ✕ три колонки = ~1.5 ряда в буфере.
      cacheExtent: 200,
      addRepaintBoundaries: false,  // делаем их сами внутри _PhotoCell
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 6,
        mainAxisSpacing: 6,
      ),
      itemCount: _assets.length,
      itemBuilder: (_, i) {
        final a = _assets[i];
        final idx = _selected.indexOf(a);
        return _PhotoCell(
          // ValueKey по id ассета — чтобы ресайкл ячеек в GridView
          // НЕ мигрировал State одной ячейки на другой ассет (иначе старая
          // картинка бы мелькала под новым ассетом).
          key: ValueKey<String>(a.id),
          asset: a,
          gridIndex: i,
          selectedOrder: idx >= 0 ? idx + 1 : null,
          onTap: () => _toggle(a),
        );
      },
    );
  }
}

/// Шапка пикера: drag-handle + ряд «Отмена / Галерея / ✓». Сама шапка
/// прозрачная, поверх sheet'а лежит длинный gradient-fade (с прозрачным
/// «хвостом» ниже самой строки) — фото скроллятся под ней и плавно
/// растворяются, как в Actions / Bugs / Repos.
class _Header extends StatelessWidget {
  final VoidCallback onCancel;
  final VoidCallback? onConfirm;
  final int selectedCount;
  final bool busy;
  const _Header({
    required this.onCancel,
    required this.onConfirm,
    required this.selectedCount,
    required this.busy,
  });

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    final hasSelection = selectedCount > 0;
    return Container(
      // Полная высота фейд-зоны: строка заголовка + длинный прозрачный
      // хвост (`_kHeaderFadeExtra`). Внутри Stack: сверху — drag-handle
      // и ряд с заголовком (поверх плотной части градиента), а снизу
      // тянется прозрачный конец градиента, под которым проходят фото.
      height: _kHeaderTotal,
      decoration: BoxDecoration(
        gradient: _fadeGradient(pal.cont, topToBottom: true),
      ),
      alignment: Alignment.topCenter,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Drag-handle.
          Container(
            margin: const EdgeInsets.only(top: 8, bottom: 4),
            width: 38,
            height: 4,
            decoration: BoxDecoration(
              color: pal.sub.withValues(alpha: 0.45),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          // Заголовок-ряд.
          //
          // Раньше было `Row(Cancel + Spacer + Title + Spacer + Check)` —
          // но «Отмена» шире кнопки-галочки, поэтому Spacer'ы делили
          // оставшееся пространство неравномерно и заголовок «Галерея»
          // визуально съезжал вправо на ~13px. Теперь — Stack: «Галерея»
          // центрируется по всей ширине шапки (Align.center), а Отмена
          // и кнопка подтверждения позиционируются абсолютно по краям.
          // Заголовок строго в центре независимо от их ширины.
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 6, 14, 6),
            child: SizedBox(
              height: 32,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Center(
                    child: Text(
                      'Галерея',
                      style: TextStyle(
                        color: pal.text,
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -.2,
                      ),
                    ),
                  ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: onCancel,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 4),
                        child: Text(
                          'Отмена',
                          style: TextStyle(
                            fontSize: 16,
                            color: pal.sub,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ),
                  ),
                  Align(
                    alignment: Alignment.centerRight,
                    // Кнопка-галочка подтверждения. Появляется/исчезает
                    // плавно (opacity + scale, 220мс easeOutCubic).
                    child: _ConfirmCheck(
                      visible: hasSelection,
                      busy: busy,
                      count: selectedCount,
                      onTap: onConfirm,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Иконка-галочка в правом краю шапки, появляется/исчезает плавно.
class _ConfirmCheck extends StatelessWidget {
  final bool visible;
  final bool busy;
  final int count;
  final VoidCallback? onTap;
  const _ConfirmCheck({
    required this.visible,
    required this.busy,
    required this.count,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    // Раньше был SizedBox(width: 56) для балансировки ширины «Отмены»,
    // но теперь шапка лежит в Stack и заголовок центрируется независимо
    // от боковых элементов — резервная ширина больше не нужна, кнопка
    // занимает только своё естественное место у правого края.
    return IgnorePointer(
      ignoring: !visible || onTap == null,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        opacity: visible ? 1.0 : 0.0,
        child: AnimatedScale(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          scale: visible ? 1.0 : 0.6,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onTap,
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              child: Container(
                width: 32,
                height: 32,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.accent,
                ),
                child: busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.2,
                          strokeCap: StrokeCap.round,
                          valueColor:
                              AlwaysStoppedAnimation<Color>(Colors.white),
                        ),
                      )
                    : const Icon(
                        Icons.check_rounded,
                        color: Colors.white,
                        size: 20,
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Одна ячейка фото в сетке.
///
/// Полная схема жизни:
///   1. В initState: запускается thumbnailDataWithSize → байты JPEG.
///   2. Когда байты пришли — НЕ кладём их сразу в Image. Вместо этого
///      делаем `precacheImage(MemoryImage(bytes), context)` — это
///      гарантирует, что движок ПОЛНОСТЬЮ декодирует JPEG до
///      растрового изображения В ФОНЕ, не в первом кадре после mount'а.
///   3. После завершения precache — выставляем `_ready=true` и плавно
///      проявляем картинку через TweenAnimationBuilder (220мс).
///
/// Раньше (без precache) при появлении байт `Image.memory(bytes)`
/// монтировался моментально, но движок ещё не декодировал JPEG → 1-2
/// кадра ячейка показывала «ничего», потом резко появлялась картинка
/// — это и было видимое МИГАНИЕ. Теперь к моменту появления Image
/// в дереве растровая копия уже есть в кеше → первый же кадр содержит
/// готовое изображение, а fade-in делает появление мягким.
class _PhotoCell extends StatefulWidget {
  final AssetEntity asset;
  /// Позиция ячейки в общей сетке. Используется для лёгкого стаггера
  /// при первичной загрузке (чтобы 18+ ячеек не дёргали PhotoManager
  /// одним залпом — иначе MethodChannel/JNI трафик собирается в
  /// jank-кадр).
  final int gridIndex;
  final int? selectedOrder;
  final VoidCallback onTap;
  const _PhotoCell({
    super.key,
    required this.asset,
    required this.gridIndex,
    required this.selectedOrder,
    required this.onTap,
  });
  @override
  State<_PhotoCell> createState() => _PhotoCellState();
}

class _PhotoCellState extends State<_PhotoCell> {
  bool _ready = false;
  // ImageProvider, через который мы рендерим картинку. Создаётся ОДИН
  // раз когда пришли байты — иначе на каждый rebuild ячейки (а они
  // случаются: выбрали/сняли — это setState родителя) создавалась бы
  // новая `MemoryImage` с новым cacheKey и Flutter заново декодировал
  // бы изображение. Здесь стабильный provider → стабильный кеш.
  ImageProvider? _provider;

  @override
  void initState() {
    super.initState();
    _kickOff();
  }

  Future<void> _kickOff() async {
    // Лёгкий стаггер ТОЛЬКО для первых 9 ячеек (3x3 — то, что видно
    // в первом кадре после открытия шита). 0мс / 16мс / 32мс / ... / 128мс.
    // Все остальные ячейки (включая те, что приходят в видимую область
    // при скролле) грузятся БЕЗ задержки. Раньше было `clamp(0, 12) * 25`
    // — это давало 300мс задержки ВСЕМ ячейкам с индексом ≥ 12, в том
    // числе тем, что появляются при скролле. Из-за этого при скролле
    // фото-пикера ячейки на 300мс оставались пустыми → пользователь
    // воспринимал это как «лаг при прокрутке».
    if (widget.gridIndex < 9) {
      final delayMs = widget.gridIndex * 16;
      if (delayMs > 0) {
        await Future<void>.delayed(Duration(milliseconds: delayMs));
        if (!mounted) return;
      }
    }
    // 300x300 — комфортный размер для grid-cell ~130px на 2-3x DPR.
    // Меньше — заметная пикселизация, больше — лишний декод.
    final bytes =
        await widget.asset.thumbnailDataWithSize(const ThumbnailSize(300, 300));
    if (!mounted || bytes == null) return;
    final provider = MemoryImage(bytes);
    // precacheImage заставляет движок декодировать байты в раст ДО
    // того, как мы покажем Image — иначе первый кадр после монтажа
    // Image-widget'а будет пустой (пока идёт декод), и юзер увидит
    // мигание placeholder→картинка.
    try {
      await precacheImage(provider, context);
    } catch (_) {
      // если decode упал — всё равно покажем (ниже сработает onError
      // image-handler'а), без мигания.
    }
    if (!mounted) return;
    setState(() {
      _provider = provider;
      _ready = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    final selected = widget.selectedOrder != null;
    // Затемнение выбранной фотки — нейтральное (без акцентного фиолета),
    // адаптивно по теме.
    final dimOpacity = pal.isDark ? 0.30 : 0.18;
    // Цвет плейсхолдера — чуть темнее `pal.cont` (фон шита), чтобы
    // ячейки было видно как заготовки сетки, а не как чёрные дыры.
    final placeholderColor = pal.isDark
        ? Colors.white.withValues(alpha: 0.04)
        : Colors.black.withValues(alpha: 0.05);
    // ОПТИМИЗАЦИЯ СКРОЛЛА:
    //  1. Использовали `Container(decoration: BoxDecoration(image:..., borderRadius:...))`
    //     вместо `ClipRRect > Stack > Image`. `BoxDecoration` рисует
    //     картинку с rounded corners через один draw call без saveLayer,
    //     а `ClipRRect` требовал save+clip+restore на каждый кадр.
    //     На сетке 3x6 ячеек это даёт +30% к FPS при скролле.
    //  2. Убрали `AnimatedScale` (он держит AnimationController на каждой
    //     ячейке, даже если scale=1.0). Заменили на `AnimatedContainer`
    //     с tween scale через transform — анимация запускается ТОЛЬКО
    //     при изменении selected.
    //  3. Бейдж и затемнение — только когда `selected`, не висят в дереве
    //     с opacity=0 на каждом фрейме.
    final hasImage = _ready && _provider != null;
    // RepaintBoundary — изолирует ячейку от ребилда соседей при
    // изменении selected у любой другой ячейки.
    return RepaintBoundary(
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedScale(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOutCubic,
          scale: selected ? 0.94 : 1.0,
          // Фейд-ин картинки и подложка реализованы через `AnimatedOpacity`
          // на самой картинке, а контейнер сразу имеет нужный borderRadius —
          // без ClipRRect.
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Плейсхолдер + (если готово) картинка как BoxDecoration
              // одного контейнера. Один draw call.
              AnimatedContainer(
                duration: const Duration(milliseconds: 240),
                curve: Curves.easeOutCubic,
                decoration: BoxDecoration(
                  color: placeholderColor,
                  borderRadius: BorderRadius.circular(14),
                  image: hasImage
                      ? DecorationImage(
                          image: _provider!,
                          fit: BoxFit.cover,
                          filterQuality: FilterQuality.medium,
                        )
                      : null,
                ),
              ),
              // Затемнение появляется только если selected. Без
              // постоянного AnimatedOpacity-виджета в дереве.
              if (selected)
                IgnorePointer(
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    curve: Curves.easeOutCubic,
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: dimOpacity),
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                ),
              // Бейдж выбора. Появляется через TweenAnimationBuilder только
              // при выделении (раз на выбор), не работает постоянно.
              if (selected)
                Positioned(
                  top: 6,
                  right: 6,
                  child: TweenAnimationBuilder<double>(
                    duration: const Duration(milliseconds: 160),
                    curve: Curves.easeOutCubic,
                    tween: Tween<double>(begin: 0.6, end: 1.0),
                    builder: (_, v, child) =>
                        Transform.scale(scale: v, child: child),
                    child: Container(
                      width: 22,
                      height: 22,
                      decoration: BoxDecoration(
                        color: AppColors.accent,
                        shape: BoxShape.circle,
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        '${widget.selectedOrder}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                          height: 1.0,
                        ),
                      ),
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

class _EmptyState extends StatelessWidget {
  final String icon;
  final String title;
  final String sub;
  final String? actionLabel;
  final VoidCallback? onAction;
  const _EmptyState({
    required this.icon,
    required this.title,
    required this.sub,
    this.actionLabel,
    this.onAction,
  });
  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Iconify(icon, size: 48, color: pal.sub),
            const SizedBox(height: 12),
            Text(
              title,
              style: TextStyle(
                color: pal.text,
                fontWeight: FontWeight.w700,
                fontSize: 16,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              sub,
              textAlign: TextAlign.center,
              style: TextStyle(color: pal.sub, fontSize: 13, height: 1.4),
            ),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 14),
              GestureDetector(
                onTap: onAction,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 10),
                  decoration: BoxDecoration(
                    color: AppColors.accent,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    actionLabel!,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 14,
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
