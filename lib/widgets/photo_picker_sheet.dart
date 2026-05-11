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
Future<List<Uint8List>?> pickPhotosBottomSheet(
  BuildContext context, {
  int? maxSelectable,
}) {
  return showModalBottomSheet<List<Uint8List>>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.55),
    transitionAnimationController: AnimationController(
      vsync: Navigator.of(context),
      duration: const Duration(milliseconds: 380),
      reverseDuration: const Duration(milliseconds: 260),
    ),
    builder: (_) => _PhotoPickerSheet(maxSelectable: maxSelectable),
  );
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

  Future<void> _confirm() async {
    if (_selected.isEmpty || _busy) return;
    setState(() => _busy = true);
    // Загружаем оригинальные байты ВЫБРАННЫХ фото параллельно — ранее
    // цикл `for ... await a.originBytes` ждал каждую фотку по очереди,
    // и при выборе 5 крупных снимков подтверждение занимало 1.5–3сек,
    // в течение которых юзер видел крутящийся индикатор без прогресса.
    // PhotoManager умеет читать несколько ассетов одновременно, поэтому
    // `Future.wait` сокращает время в N раз (по числу выбранных фото).
    // Порядок гарантируется, потому что `Future.wait` сохраняет
    // соответствие индексов входному списку.
    final futures = _selected.map((a) => a.originBytes).toList();
    final results = await Future.wait(futures);
    final out = <Uint8List>[
      for (final b in results)
        if (b != null) b,
    ];
    if (!mounted) return;
    Navigator.of(context).pop(out);
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
      physics: const ClampingScrollPhysics(),
      cacheExtent: 400,
      addRepaintBoundaries: true,
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
    // Лёгкий стаггер по индексу ячейки: первые 12 ячеек тянут превью
    // через 25мс друг за другом (0/25/50/.../275мс). Дальше — все
    // через 300мс после открытия. Это размывает MethodChannel-нагрузку
    // на PhotoManager и убирает «волну лагов» сразу после того как
    // шит встал на место (когда GridView mass-mount'ит видимые ячейки).
    final delayMs = widget.gridIndex.clamp(0, 12) * 25;
    if (delayMs > 0) {
      await Future<void>.delayed(Duration(milliseconds: delayMs));
      if (!mounted) return;
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
    // RepaintBoundary — изолирует ячейку от ребилда соседей.
    return RepaintBoundary(
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedScale(
          duration: const Duration(milliseconds: 160),
          scale: selected ? 0.94 : 1.0,
          curve: Curves.easeOutCubic,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: Stack(
              fit: StackFit.expand,
              children: [
                // Плейсхолдер — лёгкий серый фон.
                Container(color: placeholderColor),
                // Картинка появляется ТОЛЬКО когда _ready=true (precache
                // завершён). До этого — placeholder. Fade-in делается
                // через TweenAnimationBuilder, который ВСЕГДА идёт от
                // 0 к 1 за 240мс (даже если image сразу из кеша) — так
                // пользователь видит плавное проявление, без резкого
                // «хлопка».
                if (_ready && _provider != null)
                  TweenAnimationBuilder<double>(
                    tween: Tween<double>(begin: 0.0, end: 1.0),
                    duration: const Duration(milliseconds: 240),
                    curve: Curves.easeOutCubic,
                    builder: (_, value, child) =>
                        Opacity(opacity: value, child: child),
                    child: Image(
                      image: _provider!,
                      fit: BoxFit.cover,
                      filterQuality: FilterQuality.medium,
                      gaplessPlayback: true,
                    ),
                  ),
                // Адаптивное затемнение выбранной фотки — плавный fade.
                IgnorePointer(
                  child: AnimatedOpacity(
                    duration: const Duration(milliseconds: 180),
                    curve: Curves.easeOutCubic,
                    opacity: selected ? 1.0 : 0.0,
                    child: Container(
                        color: Colors.black.withValues(alpha: dimOpacity)),
                  ),
                ),
                // Бейдж выбора — баг n7777: раньше на КАЖДОЙ фотке висела белая
                // обводка (выглядело грязно). Теперь — ничего до выбора,
                // а в выбранной появляется акцентный кружок с порядковым номером.
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
