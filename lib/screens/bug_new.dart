import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';

import '../iconify.dart';
import '../navigation.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/photo_picker_sheet.dart';
import 'bug_constants.dart';
import 'bug_draw.dart';
import 'bug_meta.dart';

/// Короткий id вида `n1234` — 1-в-1 с HTML-эталоном.
String _genBugId() {
  final r = Random();
  return 'n${1000 + r.nextInt(9000)}';
}

/// Экран создания бага/предложения. Тип выбран в попапе на списке багов
/// (`bug` или `sugg`), здесь только заголовок/описание/шаги/скриншоты.
class BugNewScreen extends StatefulWidget {
  final String initialType; // 'bug' | 'sugg'
  const BugNewScreen({super.key, this.initialType = 'bug'});
  @override
  State<BugNewScreen> createState() => _BugNewScreenState();
}

class _BugNewScreenState extends State<BugNewScreen> {
  final _title = TextEditingController();
  final _desc = TextEditingController();
  late final List<TextEditingController> _stepCtrls;
  late final BugItem _draft;
  final Set<int> _encodingIndices = {};

  @override
  void initState() {
    super.initState();
    _draft = BugItem(
      id: _genBugId(),
      type: widget.initialType,
    );
    // Стартуем с одной пустой строки шага. Следующая пустая строка
    // появляется автоматически, как только в текущей последней
    // что-то вводят (см. _onStepChanged). Кнопки «Добавить шаг» больше
    // нет — она была лишней.
    _stepCtrls = [_makeStepCtrl()];
    AppState.I.addListener(_onState);
  }

  TextEditingController _makeStepCtrl() {
    final c = TextEditingController();
    c.addListener(_onStepChanged);
    return c;
  }

  @override
  void dispose() {
    _title.dispose();
    _desc.dispose();
    for (final c in _stepCtrls) {
      c.removeListener(_onStepChanged);
      c.dispose();
    }
    AppState.I.removeListener(_onState);
    super.dispose();
  }

  void _onState() => setState(() {});

  /// Слушатель текста каждого шага. Если в последней строке появился
  /// непустой текст — автоматически добавляем ещё одну пустую строку
  /// снизу. Если две последние строки пустые подряд — сворачиваем
  /// до одной (чтобы не плодить «хвосты» при удалении текста).
  void _onStepChanged() {
    if (!mounted) return;
    var changed = false;
    if (_stepCtrls.isNotEmpty && _stepCtrls.last.text.isNotEmpty) {
      _stepCtrls.add(_makeStepCtrl());
      changed = true;
    }
    while (_stepCtrls.length >= 2 &&
        _stepCtrls.last.text.isEmpty &&
        _stepCtrls[_stepCtrls.length - 2].text.isEmpty) {
      final removed = _stepCtrls.removeLast();
      removed.removeListener(_onStepChanged);
      removed.dispose();
      changed = true;
    }
    if (changed) setState(() {});
  }

  void _startEncoding(int index) {
    _encodingIndices.add(index);
    setState(() {});
    final startTime = DateTime.now();
    _draft.preEncodeShot(index).then((_) {
      if (!mounted) return;
      final elapsed = DateTime.now().difference(startTime);
      final remaining = const Duration(seconds: 2) - elapsed;
      if (remaining > Duration.zero) {
        Future.delayed(remaining, () {
          _encodingIndices.remove(index);
          if (mounted) setState(() {});
        });
      } else {
        _encodingIndices.remove(index);
        setState(() {});
      }
    });
  }

  Future<void> _pickFromGallery() async {
    // Перед открытием шита снимаем фокус — иначе IME мешает анимации
    // и системная клавиатура «прыгает» при возврате.
    FocusManager.instance.primaryFocus?.unfocus();
    final remaining = kMaxShotsPerBug - _draft.shots.length;
    // Безопасный guard: визуально кнопка _AddThumb уже disabled
    // при лимите и не имеет onTap, но подстрахуемся от расов.
    if (remaining <= 0) return;
    final picked =
        await pickPhotosBottomSheet(context, maxSelectable: remaining);
    if (picked == null || picked.isEmpty) return;
    if (!mounted) return;

    if (picked.length == 1) {
      // Один снимок — открываем редактор сразу, как и раньше.
      pushSlide(context, BugDrawScreen(bug: _draft, initial: picked.first))
          .then((_) {
        if (!mounted) return;
        // Encode any newly added shots from the draw screen.
        for (var i = 0; i < _draft.shots.length; i++) {
          if (i >= _draft.base64Cache.length ||
              _draft.base64Cache[i] == null) {
            _startEncoding(i);
          }
        }
        setState(() {});
      });
    } else {
      // Multi-select: тащим всё в скриншоты разом, без захода в редактор.
      final canAdd = kMaxShotsPerBug - _draft.shots.length;
      final toAdd =
          canAdd >= picked.length ? picked : picked.take(canAdd).toList();
      final startIndex = _draft.shots.length;
      setState(() => _draft.shots.addAll(toAdd));
      for (var i = startIndex; i < _draft.shots.length; i++) {
        _startEncoding(i);
      }
    }
  }

  void _removeStep(int i) {
    setState(() {
      final removed = _stepCtrls.removeAt(i);
      removed.removeListener(_onStepChanged);
      removed.dispose();
      if (_stepCtrls.isEmpty || _stepCtrls.last.text.isNotEmpty) {
        _stepCtrls.add(_makeStepCtrl());
      }
    });
  }

  void _next() {
    _draft.title = _title.text.trim();
    _draft.description = _desc.text.trim();
    _draft.steps
      ..clear()
      ..addAll(
        _stepCtrls
            .map((c) => c.text.trim())
            .where((t) => t.isNotEmpty)
            .map((t) => BugStep(t)),
      );
    // Без заголовка переход на следующий шаг невозможен — но без тоста:
    // пользователь видит, что кнопка «не сработала», и сам поправит.
    if (_draft.title.isEmpty) return;
    // BugMetaScreen в режиме isCreate=true сам делает Navigator.popUntil,
    // который схлопывает И meta, И этот экран за один кадр (одна слайд-
    // анимация назад к списку багов). Раньше тут была вторая Navigator.pop()
    // в `.then((created))` — из-за этого пользователь видел ДВЕ плавных
    // анимации подряд по 520мс каждая (~1с суммарно) и жаловался на
    // «кучу переходов». Если мета вернула не true (юзер просто свайпнул
    // назад) — обновляем форму, чтобы поля категории/приоритета были
    // актуальными.
    pushSlide(context, BugMetaScreen(bug: _draft, isCreate: true))
        .then((created) {
      if (created != true && mounted) {
        setState(() {});
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    final isBug = _draft.type == 'bug';
    final headerTitle = isBug ? 'Новый баг' : 'Новое предложение';
    // Внутренние блоки формы оборачиваем в горизонтальный паддинг 18,
    // а список скриншотов — пускаем edge-to-edge (с внутренним паддингом
    // в самом ListView), чтобы миниатюры могли уезжать за края экрана.
    Widget pad(Widget child) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18),
          child: child,
        );

    final topInset = MediaQuery.of(context).padding.top;
    // Баг n7850: при resize=true Scaffold пересчитывал лейаут на каждый
    // тик IME-анимации; если пользователь успел проскроллить вниз к
    // кнопкам — закрытие клавиатуры скачкообразно «опускало» весь экран.
    // Делаем kb-инсет частью padding'а скролл-вью: размер контента и его
    // viewport не меняются, экран плавно дорастает снизу под анимацию IME.
    final viewInsetBottom = MediaQuery.of(context).viewInsets.bottom;
    return Scaffold(
      backgroundColor: pal.bg,
      resizeToAvoidBottomInset: false,
      body: Stack(
        children: [
          // Edge-to-edge скроллящийся контент. Уходит под прозрачную шапку.
          Positioned.fill(
            child: SingleChildScrollView(
              padding: EdgeInsets.only(
                top: topInset + kTopHeaderBarHeight,
                bottom: 32 + viewInsetBottom,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
              pad(const FormLabel('Заголовок',
                  padding: EdgeInsets.only(top: 4, bottom: 8, left: 4))),
              pad(FieldBox(
                controller: _title,
                hint: isBug
                    ? 'Например: Crash при открытии профиля'
                    : 'Например: Добавить тёмную тему',
              )),
              pad(const FormLabel('Описание')),
              pad(FieldBox(
                controller: _desc,
                hint: 'Опишите подробно что произошло',
                minLines: 3,
                maxLines: 8,
              )),
              pad(const FormLabel('Шаги воспроизведения')),
              pad(Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < _stepCtrls.length; i++)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: _StepItem(
                        index: i + 1,
                        controller: _stepCtrls[i],
                        // Крестик прячем на последнем (всегда пустом)
                        // шаге и когда строка одна — нечего удалять.
                        onRemove: (_stepCtrls.length == 1 ||
                                i == _stepCtrls.length - 1)
                            ? null
                            : () => _removeStep(i),
                      ),
                    ),
                ],
              )),
              const SizedBox(height: 4),
              pad(const FormLabel('Скриншоты')),
              SizedBox(
                height: 110,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  physics: const BouncingScrollPhysics(),
                  // Внутренние отступы 18px по краям ListView дают первому
                  // и последнему элементу правильный визуальный ритм с
                  // остальной формой, при этом сам список занимает полную
                  // ширину экрана и может прокручиваться за края.
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                  children: [
                    for (var i = 0; i < _draft.shots.length; i++) ...[
                      _ShotThumb(
                        bytes: _draft.shots[i],
                        encoding: _encodingIndices.contains(i),
                        onTap: () {
                          FocusManager.instance.primaryFocus?.unfocus();
                          pushSlide(
                              context,
                              BugDrawScreen(
                                  bug: _draft,
                                  initial: _draft.shots[i],
                                  index: i)).then((_) {
                            if (!mounted) return;
                            _draft.invalidateCache(i);
                            _startEncoding(i);
                            setState(() {});
                          });
                        },
                        onRemove: () => setState(() {
                          _draft.shots.removeAt(i);
                          if (i < _draft.base64Cache.length) {
                            _draft.base64Cache.removeAt(i);
                          }
                          _encodingIndices.remove(i);
                          final updated = <int>{};
                          for (final idx in _encodingIndices) {
                            updated.add(idx > i ? idx - 1 : idx);
                          }
                          _encodingIndices
                            ..clear()
                            ..addAll(updated);
                        }),
                      ),
                      const SizedBox(width: 8),
                    ],
                    // Кнопка «Добавить» — неактивная, если уже набрано
                    // kMaxShotsPerBug скринов. Сначала был SnackBar, но он
                    // выглядел чужеродно — заменили на визуальный disabled.
                    _AddThumb(
                      onTap: _draft.shots.length >= kMaxShotsPerBug
                          ? null
                          : _pickFromGallery,
                      disabled: _draft.shots.length >= kMaxShotsPerBug,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 22),
              pad(Row(children: [
                Expanded(
                  child: GhostButton(
                    label: 'Отмена',
                    onTap: () => Navigator.of(context).maybePop(),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: PushButton(
                    label: 'Далее',
                    icon: 'solar:arrow-right-bold',
                    onTap: _next,
                  ),
                ),
              ])),
                ],
              ),
            ),
          ),
          // Прозрачная шапка с плавным градиентом — контент скроллится под ней.
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: TopFadeHeader(title: headerTitle),
          ),
        ],
      ),
    );
  }
}

class _StepItem extends StatelessWidget {
  final int index;
  final TextEditingController controller;
  final VoidCallback? onRemove;
  const _StepItem(
      {required this.index, required this.controller, this.onRemove});
  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    return Container(
      decoration: BoxDecoration(
        color: pal.cont,
        borderRadius: BorderRadius.circular(14),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      child: Row(
        children: [
          Container(
            width: 26,
            height: 26,
            decoration: BoxDecoration(
              color: AppColors.accent,
              borderRadius: BorderRadius.circular(99),
            ),
            alignment: Alignment.center,
            child: Text('$index',
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w700)),
          ),
          const SizedBox(width: 10),
          Expanded(
            // Многострочный ввод: текст переносится на новую строку,
            // а не уезжает за рамку контейнера.
            child: TextField(
              controller: controller,
              style: TextStyle(color: pal.text, fontSize: 14, height: 1.35),
              keyboardType: TextInputType.multiline,
              textInputAction: TextInputAction.newline,
              minLines: 1,
              maxLines: null,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                hintText: 'Шаг $index',
                hintStyle: TextStyle(color: pal.sub, height: 1.35),
                isDense: true,
                contentPadding:
                    const EdgeInsets.symmetric(vertical: 10),
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
              ),
            ),
          ),
          if (onRemove != null)
            IconBtn(
              icon: 'solar:close-circle-linear',
              iconSize: 18,
              size: 32,
              color: pal.sub,
              onTap: onRemove,
            ),
        ],
      ),
    );
  }
}

class _ShotThumb extends StatefulWidget {
  final Uint8List bytes;
  final bool encoding;
  final VoidCallback onTap;
  final VoidCallback onRemove;
  const _ShotThumb({
    required this.bytes,
    required this.encoding,
    required this.onTap,
    required this.onRemove,
  });
  @override
  State<_ShotThumb> createState() => _ShotThumbState();
}

class _ShotThumbState extends State<_ShotThumb> {
  double _spinnerOpacity = 0.0;

  @override
  void initState() {
    super.initState();
    if (widget.encoding) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _spinnerOpacity = 1.0);
      });
    }
  }

  @override
  void didUpdateWidget(_ShotThumb old) {
    super.didUpdateWidget(old);
    if (widget.encoding && !old.encoding) {
      setState(() => _spinnerOpacity = 1.0);
    } else if (!widget.encoding && old.encoding) {
      setState(() => _spinnerOpacity = 0.0);
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      child: SizedBox(
        width: 110,
        height: 110,
        child: Stack(children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Image.memory(widget.bytes,
                width: 110,
                height: 110,
                fit: BoxFit.cover,
                cacheWidth: (110 * MediaQuery.of(context).devicePixelRatio).round(),
                filterQuality: FilterQuality.medium,
                gaplessPlayback: true),
          ),
          AnimatedOpacity(
            opacity: _spinnerOpacity,
            duration: const Duration(milliseconds: 350),
            child: Container(
              width: 110,
              height: 110,
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.35),
                borderRadius: BorderRadius.circular(12),
              ),
              alignment: Alignment.center,
              child: SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(
                  strokeWidth: 2.4,
                  strokeCap: StrokeCap.round,
                  valueColor:
                      const AlwaysStoppedAnimation<Color>(Colors.white),
                ),
              ),
            ),
          ),
          Positioned(
            top: 4,
            right: 4,
            child: GestureDetector(
              onTap: widget.onRemove,
              child: Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.6),
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: const Iconify('solar:close-circle-bold',
                    size: 14, color: Colors.white),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

class _AddThumb extends StatelessWidget {
  final VoidCallback? onTap;
  /// `true` — кнопка визуально отключена (полупрозрачная, без
  /// реакции на тап). Используется когда достигнут kMaxShotsPerBug.
  final bool disabled;
  const _AddThumb({required this.onTap, this.disabled = false});
  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    final accent = disabled
        ? AppColors.accent.withValues(alpha: 0.32)
        : AppColors.accent;
    return Opacity(
      opacity: disabled ? 0.55 : 1.0,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 110,
          height: 110,
          decoration: BoxDecoration(
            // Без обводки — пользователь просил убрать рамку у плитки
            // «Добавить» фото. Карточка теперь визуально совпадает с
            // фоном миниатюр скриншотов рядом.
            color: pal.cont,
            borderRadius: BorderRadius.circular(12),
          ),
          alignment: Alignment.center,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Iconify('solar:gallery-add-bold', size: 26, color: accent),
              const SizedBox(height: 4),
              Text('Добавить',
                  style: TextStyle(
                      color: accent,
                      fontSize: 12,
                      fontWeight: FontWeight.w600)),
            ],
          ),
        ),
      ),
    );
  }
}
