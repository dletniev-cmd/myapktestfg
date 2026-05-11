import 'package:flutter/material.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'other.dart' show ThemedSwitch;

/// 12 акцентных цветов — 2 строки по 6. Это «комфортная» палитра:
/// все цвета имеют примерно одинаковую перцептивную яркость
/// (HSL S≈50–55%, L≈62–65%), поэтому хорошо смотрятся вместе и
/// читаются и на тёмном, и на светлом фоне. Без неоново-кислотных
/// и резких оттенков (нет «громкого» красного / насыщенного жёлтого).
/// Хождение по цветовому кругу: лаванда → барвинок → синий → циан →
/// бирюза → шалфей → олива → золото → персик → коралл → роза → орхидея.
const List<Color> kAccentOptions = [
  Color(0xFF9885E2), // лаванда (default)
  Color(0xFF7C8FE5), // барвинок (periwinkle)
  Color(0xFF5F9DDA), // мягкий синий
  Color(0xFF52B5CC), // циан
  Color(0xFF4DBFB0), // бирюза
  Color(0xFF5EBE82), // шалфей (sage)
  Color(0xFFA5C26B), // олива
  Color(0xFFDBC062), // золотистый
  Color(0xFFE0A472), // персик
  Color(0xFFDB857F), // коралл (мягкий тёплый красный)
  Color(0xFFDB87A8), // роза
  Color(0xFFC386CC), // орхидея
];

class AppearanceScreen extends StatefulWidget {
  const AppearanceScreen({super.key});
  @override
  State<AppearanceScreen> createState() => _AppearanceScreenState();
}

class _AppearanceScreenState extends State<AppearanceScreen> {
  @override
  void initState() {
    super.initState();
    AppState.I.addListener(_onState);
  }

  @override
  void dispose() {
    AppState.I.removeListener(_onState);
    super.dispose();
  }

  void _onState() {
    if (mounted) setState(() {});
  }

  void _toggleTheme() {
    AppState.I.isDark = !AppState.I.isDark;
    AppState.I.touch();
    AppState.I.saveTheme();
  }

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
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
                    const SecTitle('Тема'),
                    TileGroup(children: [
                      Tile(
                        iconBg: pal.isDark ? AppColors.dark : AppColors.orange,
                        icon: pal.isDark
                            ? 'solar:moon-stars-bold'
                            : 'solar:sun-2-bold',
                        title: 'Тёмная тема',
                        sub: pal.isDark ? 'Включена' : 'Выключена',
                        onTap: _toggleTheme,
                        trailing: ThemedSwitch(active: pal.isDark),
                      ),
                    ]),
                    const SecTitle('Акцентный цвет'),
                    _AccentPicker(
                      selected: AppColors.accent,
                      onChanged: (c) => AppState.I.setAccentColor(c),
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
            child: TopFadeHeader(title: 'Оформление'),
          ),
        ],
      ),
    );
  }
}

/// Грид акцентных кружков 2×6. Поддерживает:
///   • тап по кружку — выбор
///   • ведение пальца (pan/drag) — переключение без отрыва
///
/// Активный кружок визуально «сжимается» внутри обводки того же цвета
/// (масштаб inner circle ≈ 0.72), при этом размер ячейки не меняется.
class _AccentPicker extends StatefulWidget {
  final Color selected;
  final ValueChanged<Color> onChanged;
  const _AccentPicker({required this.selected, required this.onChanged});

  @override
  State<_AccentPicker> createState() => _AccentPickerState();
}

class _AccentPickerState extends State<_AccentPicker> {
  /// Ключи для каждого кружка — используются для hit-test при свайпе.
  final List<GlobalKey> _keys =
      List.generate(kAccentOptions.length, (_) => GlobalKey());

  void _hitTest(Offset globalPos) {
    for (var i = 0; i < kAccentOptions.length; i++) {
      final ctx = _keys[i].currentContext;
      if (ctx == null) continue;
      final box = ctx.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) continue;
      final local = box.globalToLocal(globalPos);
      if (box.paintBounds.contains(local)) {
        if (kAccentOptions[i].value != widget.selected.value) {
          widget.onChanged(kAccentOptions[i]);
        }
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    return GestureDetector(
      onPanUpdate: (d) => _hitTest(d.globalPosition),
      onPanDown: (d) => _hitTest(d.globalPosition),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
        decoration: BoxDecoration(
          color: pal.cont,
          borderRadius: BorderRadius.circular(18),
        ),
        child: Wrap(
          alignment: WrapAlignment.center,
          spacing: 10,
          runSpacing: 14,
          children: [
            for (var i = 0; i < kAccentOptions.length; i++)
              _ColorDot(
                key: _keys[i],
                color: kAccentOptions[i],
                selected: kAccentOptions[i].value == widget.selected.value,
                onTap: () => widget.onChanged(kAccentOptions[i]),
              ),
          ],
        ),
      ),
    );
  }
}

/// Один цветной кружок. При `selected=true`:
///   • Появляется кольцо (border) цветом кружка — рисуется ВНУТРИ
///     фиксированной 36×36 области (Stack.expand), поэтому внешний
///     размер не меняется.
///   • Внутренний fill плавно усаживается (padding 0 → 6) — между
///     кольцом и заливкой появляется зазор.
class _ColorDot extends StatelessWidget {
  final Color color;
  final bool selected;
  final VoidCallback onTap;
  const _ColorDot({
    super.key,
    required this.color,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    const double size = 36;
    const double ringW = 2.5;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: size,
        height: size,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // \u041a\u043e\u043b\u044c\u0446\u043e \u2014 \u043e\u0431\u0432\u043e\u0434\u043a\u0430 \u0440\u0438\u0441\u0443\u0435\u0442\u0441\u044f \u0432\u043d\u0443\u0442\u0440\u0438 36\u00d736 (strokeAlignInside),
            // \u043f\u043e\u044d\u0442\u043e\u043c\u0443 \u0432\u0438\u0437\u0443\u0430\u043b\u044c\u043d\u044b\u0439 \u0440\u0430\u0437\u043c\u0435\u0440 \u043a\u0440\u0443\u0436\u043a\u0430 \u043d\u0435 \u0440\u0430\u0441\u0442\u0451\u0442 \u043f\u0440\u0438 \u0432\u044b\u0431\u043e\u0440\u0435.
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOutCubic,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: selected ? color : Colors.transparent,
                  width: ringW,
                  strokeAlign: BorderSide.strokeAlignInside,
                ),
              ),
            ),
            // \u0412\u043d\u0443\u0442\u0440\u0435\u043d\u043d\u0438\u0439 \u0444\u0438\u043b\u043b \u2014 \u0443\u0441\u0430\u0436\u0438\u0432\u0430\u0435\u0442\u0441\u044f \u0432\u043d\u0443\u0442\u0440\u044c \u043f\u0440\u0438 \u0432\u044b\u0431\u043e\u0440\u0435 \u0447\u0435\u0440\u0435\u0437 padding.
            AnimatedPadding(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOutCubic,
              padding: EdgeInsets.all(selected ? 6 : 0),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: color,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
