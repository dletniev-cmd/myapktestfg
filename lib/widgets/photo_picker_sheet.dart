import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:photo_manager/photo_manager.dart';
import 'm3_loading.dart';

import '../iconify.dart';
import '../theme.dart';

/// Глобальный семафор-«гейт» для запросов миниатюр у PhotoManager.
/// PhotoManager.thumbnailDataWithSize — это MethodChannel→JNI→Android
/// SDK→DownsampleStrategy + декод JPEG в нативе. Тяжёлый MethodChannel-
/// трафик блокирует UI-тред. Юзер (баг n2823): «лаги при прокрутке в
/// панели выбор фото».
///
/// Без ограничения параллелизма при быстром скролле GridView монтирует
/// десяток новых _PhotoCell'ов одновременно, каждый стартует запрос
/// миниатюры — JNI/Binder заваливается, UI-тред получает jank-кадры.
///
/// Гейт держит максимум `_kMaxConcurrentThumbnails` запросов в полёте,
/// остальные кооперативно встают в очередь и стартуют по мере
/// освобождения слотов. Конкретно 3 — на типичном Android-flagship
/// этого хватает чтобы держать конвейер сытым, но не топить UI-тред.
const int _kMaxConcurrentThumbnails = 3;

class _ThumbGate {
  static int _active = 0;
  static final Queue<Completer<void>> _q = Queue<Completer<void>>();

  static Future<void> acquire() async {
    if (_active < _kMaxConcurrentThumbnails) {
      _active++;
      return;
    }
    final c = Completer<void>();
    _q.add(c);
    return c.future;
  }

  static void release() {
    if (_q.isNotEmpty) {
      _q.removeFirst().complete();
    } else {
      _active--;
      if (_active < 0) _active = 0;
    }
  }
}

/// Процесс-вайд кеш сырых байт миниатюр (300×300 JPEG) на время
/// жизни одного открытого шита пикера. Чистится в диспоузе _PhotoPickerSheet.
///
/// Мотивация: в GridView ячейки без keep-alive диспозятся при
/// выходе из viewport. При возврате скроллом назад ячейка монтируется
/// заново и прежде была вынуждена снова идти в PhotoManager.thumbnailDataWithSize
/// по MethodChannel/JNI/binder, хотя этот же ассет уже был загружен милли-
/// секунды назад. С кешем re-mount берёт байты сразу (синхронно) — ни
/// MethodChannel ни декода не требуется: `MemoryImage` от того же
/// `Uint8List` имеет тот же cache key в Flutter ImageCache, растровый
/// результат подхватывается из кеша. Скролл становится плавным.
///
/// Предел: 600 ассетов × ~30 КБ (300×300 JPEG) ≈ ~18 МБ пиково —
/// это верхний предел при полностью прокрученной галерее. Освобож-
/// даем в dispose шита — между открытиями кеш не висит в памяти.
class _ThumbBytesCache {
  static final Map<String, Uint8List> _data = <String, Uint8List>{};

  static Uint8List? get(String assetId) => _data[assetId];
  static void put(String assetId, Uint8List bytes) {
    _data[assetId] = bytes;
  }

  static void clear() => _data.clear();
}

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
  //
  // Хранится как ValueNotifier (а не как поле + setState), чтобы тап
  // по любой ячейке НЕ дёргал setState родителя — иначе itemBuilder
  // GridView перестраивает все видимые _PhotoCell'ы (а это 18+ ячеек
  // на средний экран), даже если у них selection не менялся. Это и
  // давало главный визимый jank при выборе во время скролла.
  //
  // Теперь:
  //   • _toggle делает _selected.value = newList — одна аллокация.
  //   • Ячейки слушают _selected через ValueListenableBuilder и
  //     перестраивают ТОЛЬКО chrome (бейдж/затемнение/scale), сама
  //     картинка из дерева не уходит и не пересоздаётся.
  //   • Шапка слушает _selected через ValueListenableBuilder, чтобы
  //     показывать/скрывать кнопку-галочку без ребилда сетки.
  final ValueNotifier<List<AssetEntity>> _selected =
      ValueNotifier<List<AssetEntity>>(const <AssetEntity>[]);
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

  @override
  void dispose() {
    _selected.dispose();
    // Освобождаем байты миниатюр между открытиями пикера. Кеш
    // ливёт только пока шит открыт; при повторном открытии
    // галерея могла измениться, поэтому лучше стартовать с чистого.
    _ThumbBytesCache.clear();
    super.dispose();
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
    final cur = _selected.value;
    final alreadyOn = cur.contains(a);
    // Лимит на выбор: если ячейка ещё не выбрана и лимит исчерпан —
    // игнорируем тап и даём обратную связь виброй (heavyImpact)
    // вместо обычного selectionClick — чтобы юзер физически
    // почувствовал «стоп».
    if (!alreadyOn && max != null && cur.length >= max) {
      HapticFeedback.heavyImpact();
      return;
    }
    HapticFeedback.selectionClick();
    // Иммутабельный апдейт: создаём новый список, чтобы
    // ValueNotifier.value != old и слушатели гарантированно
    // получили нотификацию (List реализует == через identity по
    // умолчанию, но писать на .value тот же List было бы
    // концептуально странно). Цена аллокации ничтожна — даже при
    // 60 fps толкания это десятки байт в секунду.
    final next = List<AssetEntity>.of(cur);
    if (alreadyOn) {
      next.remove(a);
    } else {
      next.add(a);
    }
    _selected.value = next;
  }

  void _confirm() {
    final cur = _selected.value;
    if (cur.isEmpty || _busy) return;
    // МГНОВЕННО закрываем шит, возвращая список AssetEntity. Загрузку
    // оригинальных байт берёт на себя обёртка `pickPhotosBottomSheet`
    // УЖЕ ПОСЛЕ pop — чтобы анимация закрытия шит'а шла параллельно с
    // чтением больших JPEG'ов из MediaStore, а не блокировалась им.
    //
    // Раньше тут было `setState(_busy=true)` + `await Future.wait(...)`
    // + `pop(out)` — и юзер видел: тапнул галочку → шит замер с
    // мини-спиннером → через 1-3сек закрылся «рывком» (потому что
    // animation controller отдыхал, пока шёл MethodChannel-read).
    Navigator.of(context).pop<List<AssetEntity>>(List<AssetEntity>.of(cur));
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
            //
            // RepaintBoundary изолирует шапку от repaint'ов скроллящейся
            // сетки под ней. Шапка статична (drag-handle + текст +
            // фейд-градиент) — её слой композитор может закешировать и
            // не перерисовывать на каждый кадр прокрутки.
            //
            // ValueListenableBuilder подписывается на _selected и
            // ребилдит ТОЛЬКО шапку (а не весь _body) когда меняется
            // счётчик/видимость кнопки.
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: RepaintBoundary(
                child: ValueListenableBuilder<List<AssetEntity>>(
                  valueListenable: _selected,
                  builder: (_, sel, __) => _Header(
                    onCancel: () => Navigator.of(context).maybePop(),
                    onConfirm: sel.isEmpty || _busy ? null : _confirm,
                    selectedCount: sel.length,
                    busy: _busy,
                  ),
                ),
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
          child: M3LoadingIndicator(
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
    // RepaintBoundary вокруг GridView изолирует слой скролла фото от
    // шапки/системного UI. Без него любой repaint в дереве выше (например,
    // обновление статус-бара или AnimatedOpacity шапки) триггерит
    // полную перерисовку сетки.
    return RepaintBoundary(
      child: GridView.builder(
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
        // Большой cacheExtent (1200) держит в дереве ~6 рядов выше и ниже
        // viewport'а. Это критично: при cacheExtent=200 (как было)
        // ячейка ушедшая за экран на 200px моментально диспоузилась —
        // и при скролле обратно её приходилось монтировать заново,
        // снова дёргать PhotoManager.thumbnailDataWithSize, ждать
        // декода. На fling'е это и было «лагает прокрутка»: новые
        // ряды появляются пустыми и медленно заливаются картинками.
        // С 1200 практически вся типичная сессия пользователя
        // (просмотреть ~10-20 рядов) удерживается в памяти и
        // прокрутка туда-обратно идёт без подгрузок.
        cacheExtent: 1200,
        // Дефолт (true) — GridView сам оборачивает каждую ячейку в
        // RepaintBoundary, изолируя её paint от соседей. Это ровно то
        // что нам нужно при скролле — рисуем только новые ячейки в
        // viewport, не перерисовываем старые.
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          crossAxisSpacing: 6,
          mainAxisSpacing: 6,
        ),
        itemCount: _assets.length,
        itemBuilder: (_, i) {
          final a = _assets[i];
          return _PhotoCell(
            // ValueKey по id ассета — чтобы ресайкл ячеек в GridView
            // НЕ мигрировал State одной ячейки на другой ассет (иначе старая
            // картинка бы мелькала под новым ассетом).
            key: ValueKey<String>(a.id),
            asset: a,
            gridIndex: i,
            selected: _selected,
            onTap: () => _toggle(a),
          );
        },
      ),
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
                        child: M3LoadingIndicator(
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
  /// Общий на весь пикер нотифайер выбранных ассетов. Ячейка
  /// сама вычисляет своё состояние из этого списка (contains/indexOf)
  /// внутри ValueListenableBuilder — без ребилда всего GridView.
  final ValueListenable<List<AssetEntity>> selected;
  final VoidCallback onTap;
  const _PhotoCell({
    super.key,
    required this.asset,
    required this.gridIndex,
    required this.selected,
    required this.onTap,
  });
  @override
  State<_PhotoCell> createState() => _PhotoCellState();
}

class _PhotoCellState extends State<_PhotoCell> {
  bool _ready = false;
  // ImageProvider, через который мы рендерим картинку. Создаётся ОДИН
  // раз когда пришли байты — иначе на каждый rebuild ячейки
  // создавалась бы новая `MemoryImage` с новым cacheKey и Flutter
  // заново декодировал бы изображение. Здесь стабильный
  // provider → стабильный кеш.
  ImageProvider? _provider;

  @override
  void initState() {
    super.initState();
    _kickOff();
  }

  Future<void> _kickOff() async {
    // БЫСТРЫЙ ПУТЬ: байты уже в процесс-вайд кеше текущей сессии
    // шита — ячейка была показана раньше, ушла из viewport (диспоуз),
    // вернулась обратно (re-mount). Не идём в PhotoManager вторично —
    // отдаём те же байты. Растровый результат `MemoryImage(bytes)` под-
    // хватит Flutter ImageCache (тот же cache key — тот же Uint8List).
    final cachedBytes = _ThumbBytesCache.get(widget.asset.id);
    if (cachedBytes != null) {
      _provider = MemoryImage(cachedBytes);
      _ready = true;
      // Мы в initState→_kickOff() до первого билда. setState здесь
      // не нужен — первый build() увидит эти поля.
      return;
    }
    // Лёгкий стаггер ТОЛЬКО для первых 9 ячеек (3x3 — то, что видно
    // в первом кадре после открытия шита). 0мс / 16мс / 32мс / ... / 128мс.
    // Все остальные ячейки (включая те, что приходят в видимую область
    // при скролле) грузятся БЕЗ задержки.
    if (widget.gridIndex < 9) {
      final delayMs = widget.gridIndex * 16;
      if (delayMs > 0) {
        await Future<void>.delayed(Duration(milliseconds: delayMs));
        if (!mounted) return;
      }
    }
    // _ThumbGate: ограничиваем параллелизм запросов миниатюр. Без
    // этого при быстрой прокрутке десятки _PhotoCell стартуют
    // thumbnailDataWithSize одновременно — это бьёт по UI-треду.
    await _ThumbGate.acquire();
    Uint8List? bytes;
    try {
      if (!mounted) return;
      // Повторный cache-check ПОСЛЕ acquire: пока мы ждали слот в гейте,
      // другая ячейка могла уже загрузить байты этого ассета.
      final cachedAfterWait = _ThumbBytesCache.get(widget.asset.id);
      if (cachedAfterWait != null) {
        bytes = cachedAfterWait;
      } else {
        // 300x300 — комфортный размер для grid-cell ~130px на 2-3x DPR.
        bytes = await widget.asset
            .thumbnailDataWithSize(const ThumbnailSize(300, 300));
        if (bytes != null) {
          _ThumbBytesCache.put(widget.asset.id, bytes);
        }
      }
    } finally {
      _ThumbGate.release();
    }
    if (!mounted || bytes == null) return;
    final provider = MemoryImage(bytes);
    // Раньше здесь был «блокирующий» await precacheImage ПЕРЕД
    // setState — идея была «декодировать в кеш до показа, чтобы не было
    // мигания placeholder→картинка». Но это добавляло лишние 50–200мс
    // до первого показа каждой ячейки. На быстром скролле видимый
    // эффект: новые ячейки долго были пустыми — юзер воспринимал это
    // как «лаг при прокрутке».
    //
    // Теперь: сразу выставляем provider и включаем _ready. Flutter
    // сам декодирует байты в растр (в растер-изоляте Skia, вне UI-
    // треда) и растр попадёт в ImageCache по ключу (bytes.identityHash,
    // scale). Следующие показы того же ImageProvider будут
    // синхронны из кеша — без мигания. Для первого показа
    // спрячем пустой кадр плейсхолдер-цветом ячейки + frameBuilder
    // в самом Image (см. build()): новый кадр плавно фейдит внутри
    // Image при появлении растра. На быстром скролле это на порядок
    // лучше precacheImage, потому что декод и build идут параллельно.
    setState(() {
      _provider = provider;
      _ready = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    // Цвет плейсхолдера — чуть темнее `pal.cont` (фон шита), чтобы
    // ячейки было видно как заготовки сетки, а не как чёрные дыры.
    final placeholderColor = pal.isDark
        ? Colors.white.withValues(alpha: 0.04)
        : Colors.black.withValues(alpha: 0.05);
    // Затемнение выбранной фотки — нейтральное, адаптивно по теме.
    final dimOpacity = pal.isDark ? 0.30 : 0.18;
    final hasImage = _ready && _provider != null;
    final provider = _provider;

    // Строим статичную «картинку» фона ячейки ОДИН раз и передаём
    // её как `child` в ValueListenableBuilder ниже. Что это даёт:
    //   • Когда юзер выбирает другую фотку в сетке — _selected.value
    //     обновляется, все ValueListenableBuilder'ы в ячейках
    //     вызывают builder, НО `child` (самое изображение + decoration)
    //     НЕ перестраивается — это и есть ключевой выигрыш.
    //   • Image-widget в дереве не переподписывается на ImageStream —
    //     нет временных пустых кадров, нет лишних декодов.
    final imageLayer = hasImage
        ? Image(
            image: provider!,
            fit: BoxFit.cover,
            filterQuality: FilterQuality.medium,
            gaplessPlayback: true,
            // frameBuilder — плавное появление картинки в первый раз
            // (~120мс fade-in). При повторных монтажах (растр уже
            // в ImageCache) кадр приходит синхронно и фейд пропускается.
            frameBuilder: (ctx, child, frame, wasSync) {
              if (wasSync || frame != null && frame > 0) return child;
              return AnimatedOpacity(
                opacity: frame == null ? 0 : 1,
                duration: const Duration(milliseconds: 120),
                child: child,
              );
            },
          )
        : null;

    // Один виджет рисует и подложку (placeholderColor) и картинку
    // с borderRadius — без ClipRRect, в один проход канваса.
    // ClipRRect вокруг Image был бы дороже (canvas.clipRRect на
    // каждый кадр), а здесь Skia просто обрезает path-fill
    // прямоугольника с закругленными углами.
    final imageBox = ClipRRect(
      borderRadius: BorderRadius.circular(14),
      // hardEdge — не делаем saveLayer ради anti-aliased углов;
      // на фото этого не видно (фото само уже «пёстрое»), а выигрыш
      // в paint-бюджете заметный при быстром скролле.
      clipBehavior: Clip.hardEdge,
      child: Container(
        color: placeholderColor,
        child: imageLayer ?? const SizedBox.expand(),
      ),
    );

    // RepaintBoundary — изолирует ячейку от репейнтов соседей.
    // GridView с addRepaintBoundaries:true (дефолт) уже добавляет их,
    // но явный боундари внутри тоже не мешает — страхует от
    // случаев, когда GridView не добавляет (например в sliver-версиях).
    return RepaintBoundary(
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        // Подписываемся на _selected ТОЛЬКО в верхнем слое (scale +
        // бейдж + затемнение). Картинка (imageBox) передаётся как
        // const-child и не перестраивается при изменении выделения.
        child: ValueListenableBuilder<List<AssetEntity>>(
          valueListenable: widget.selected,
          child: imageBox,
          builder: (_, sel, child) {
            final idx = sel.indexOf(widget.asset);
            final selected = idx >= 0;
            final order = selected ? idx + 1 : null;
            return AnimatedScale(
              duration: const Duration(milliseconds: 160),
              curve: Curves.easeOutCubic,
              scale: selected ? 0.94 : 1.0,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  child!, // картинка из выше — статична.
                  if (selected)
                    IgnorePointer(
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: dimOpacity),
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                    ),
                  if (selected)
                    Positioned(
                      top: 6,
                      right: 6,
                      child: TweenAnimationBuilder<double>(
                        duration: const Duration(milliseconds: 160),
                        curve: Curves.easeOutCubic,
                        tween: Tween<double>(begin: 0.6, end: 1.0),
                        builder: (_, v, b) =>
                            Transform.scale(scale: v, child: b),
                        child: Container(
                          width: 22,
                          height: 22,
                          decoration: BoxDecoration(
                            color: AppColors.accent,
                            shape: BoxShape.circle,
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            '$order',
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
            );
          },
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
