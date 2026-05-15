import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import '../prefs.dart';
import '../speech.dart';
import '../theme.dart';
import '../widgets.dart';

/// Экран чтения — основной «телепромптерный» вид.
///
/// Особенности:
/// * Текст рендерится одним [RichText] поверх [SingleChildScrollView],
///   подсветка собирается как два [TextSpan]'а (уже прочитанный кусок —
///   приглушённый, текущий — акцентный, оставшийся — обычный).
/// * Auto-scroll вычисляется через [TextPainter], которому скармливается
///   ровно тот же стиль и ширина, что и видимому тексту. Это даёт
///   точные y-координаты конкретного символа без хаков с GlobalKey'ями.
/// * При включённом микрофоне позиция чтения двигается по последним
///   распознанным словам, используя жадный матчер в окрестности
///   текущей позиции. При выключённом — плавный fallback-скролл с
///   заданной скоростью.
class PrompterScreen extends StatefulWidget {
  final String text;
  const PrompterScreen({super.key, required this.text});

  @override
  State<PrompterScreen> createState() => _PrompterScreenState();
}

class _PrompterScreenState extends State<PrompterScreen>
    with SingleTickerProviderStateMixin {
  // Текст исходника и его словарная декомпозиция.
  late final String _text;
  late final List<_Word> _words;

  // Текущий «прочитанный» индекс слова (exclusive — слово с этим
  // индексом ещё не прочитано). Через ValueNotifier чтобы перестраивать
  // только RichText, а не весь экран.
  final ValueNotifier<int> _readUpTo = ValueNotifier<int>(0);

  // Управление прокруткой.
  final ScrollController _scroll = ScrollController();
  Ticker? _fallbackTicker;
  DateTime? _fallbackLastTick;

  // Настройки чтения.
  double _fontSize = 26.0;
  double _lineHeight = 1.5;
  bool _autoScrollEnabled = true;
  double _fallbackSpeed = 28.0;
  String _localeId = 'ru_RU';
  bool _settingsLoaded = false;

  // Состояние UI.
  bool _controlsVisible = true;
  Timer? _hideControlsTimer;

  // Кешируем painter для расчёта y-координат подсветки.
  TextPainter? _measurePainter;
  double _measureWidth = 0;

  // Подписки и таймеры.
  Timer? _scrollDebounce;

  @override
  void initState() {
    super.initState();
    _text = widget.text;
    _words = _tokenize(_text);
    _loadSettings();
    SpeechService.I.recognized.addListener(_onRecognized);
    SpeechService.I.listening.addListener(_onListeningChanged);
    SpeechService.I.onError = (msg) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(msg,
              style: const TextStyle(color: AppColors.text)),
          backgroundColor: AppColors.cont,
          duration: const Duration(seconds: 2),
        ),
      );
    };
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _scheduleAutoHide();
  }

  Future<void> _loadSettings() async {
    final fs = await Prefs.I.getFontSize();
    final lh = await Prefs.I.getLineHeight();
    final auto = await Prefs.I.getAutoScroll();
    final speed = await Prefs.I.getFallbackSpeed();
    final loc = await Prefs.I.getLocaleId();
    if (!mounted) return;
    setState(() {
      _fontSize = fs;
      _lineHeight = lh;
      _autoScrollEnabled = auto;
      _fallbackSpeed = speed;
      _localeId = loc;
      _settingsLoaded = true;
      _measurePainter = null;
    });
  }

  @override
  void dispose() {
    SpeechService.I.recognized.removeListener(_onRecognized);
    SpeechService.I.listening.removeListener(_onListeningChanged);
    SpeechService.I.onError = null;
    SpeechService.I.stop();
    _fallbackTicker?.dispose();
    _scroll.dispose();
    _hideControlsTimer?.cancel();
    _scrollDebounce?.cancel();
    _readUpTo.dispose();
    super.dispose();
  }

  // ──────────────────────── Tokenization ────────────────────────

  List<_Word> _tokenize(String text) {
    final out = <_Word>[];
    // Регекс ловит «слово» — последовательность букв/цифр (включая
    // юникод). Знаки препинания и пробелы пропускаем.
    final re = RegExp(r"[\p{L}\p{M}\p{N}'’\-]+", unicode: true);
    for (final m in re.allMatches(text)) {
      out.add(_Word(
        start: m.start,
        end: m.end,
        normalized: _normalize(m.group(0)!),
      ));
    }
    return out;
  }

  static String _normalize(String w) {
    final lower = w.toLowerCase();
    // ё → е, чтобы разница «ё/е» не мешала матчингу — типичная
    // проблема Android STT, который часто возвращает «е» вместо «ё».
    return lower.replaceAll('ё', 'е');
  }

  // ──────────────────────── Recognition matching ────────────────────────

  String _prevRecognized = '';

  void _onRecognized() {
    final fresh = SpeechService.I.recognized.value;
    if (fresh == _prevRecognized) return;
    final added = fresh.length >= _prevRecognized.length &&
            fresh.startsWith(_prevRecognized)
        ? fresh.substring(_prevRecognized.length)
        : fresh; // если префикс «съехал» — всё равно матчим всё новое
    _prevRecognized = fresh;
    _advanceByRecognized(added);
  }

  void _advanceByRecognized(String chunk) {
    final tokens = RegExp(r"[\p{L}\p{M}\p{N}'’\-]+", unicode: true)
        .allMatches(chunk)
        .map((m) => _normalize(m.group(0)!))
        .toList(growable: false);
    if (tokens.isEmpty) return;

    var pos = _readUpTo.value;
    final maxIdx = _words.length;

    // Жадный поиск каждого распознанного слова в окне впереди текущей
    // позиции. Это устойчиво к тому, что STT может проглатывать
    // короткие предлоги/союзы.
    const lookAhead = 12;
    for (final t in tokens) {
      if (t.isEmpty) continue;
      final hi = math.min(pos + lookAhead, maxIdx);
      var matched = -1;
      for (var i = pos; i < hi; i++) {
        if (_wordMatches(_words[i].normalized, t)) {
          matched = i;
          break;
        }
      }
      if (matched >= 0) {
        pos = matched + 1;
      }
    }

    if (pos != _readUpTo.value) {
      _readUpTo.value = pos;
      _animateToCurrent();
    }
  }

  /// Сравнение слов с минимальной устойчивостью к окончаниям/опечаткам.
  bool _wordMatches(String a, String b) {
    if (a == b) return true;
    if (a.isEmpty || b.isEmpty) return false;
    // Префиксное совпадение (минимум 4 символа) — частый случай, когда
    // STT обрезает окончание или возвращает другую форму слова.
    final minLen = math.min(a.length, b.length);
    if (minLen >= 4) {
      var same = 0;
      for (var i = 0; i < minLen; i++) {
        if (a.codeUnitAt(i) == b.codeUnitAt(i)) {
          same++;
        } else {
          break;
        }
      }
      if (same >= 4 && same >= (math.min(a.length, b.length) * 0.7)) {
        return true;
      }
    }
    // Левенштейн до 1 для коротких слов (3-5 символов) — спасает
    // от типичных ошибок распознавания типа «привет→превет».
    if ((a.length <= 6 && b.length <= 6) &&
        (a.length - b.length).abs() <= 1) {
      if (_levenshtein(a, b) <= 1) return true;
    }
    return false;
  }

  int _levenshtein(String a, String b) {
    final m = a.length, n = b.length;
    if (m == 0) return n;
    if (n == 0) return m;
    final prev = List<int>.filled(n + 1, 0);
    final curr = List<int>.filled(n + 1, 0);
    for (var j = 0; j <= n; j++) {
      prev[j] = j;
    }
    for (var i = 1; i <= m; i++) {
      curr[0] = i;
      for (var j = 1; j <= n; j++) {
        final cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
        curr[j] = math.min(
          math.min(curr[j - 1] + 1, prev[j] + 1),
          prev[j - 1] + cost,
        );
      }
      for (var j = 0; j <= n; j++) {
        prev[j] = curr[j];
      }
    }
    return prev[n];
  }

  // ──────────────────────── Smooth scrolling ────────────────────────

  void _animateToCurrent() {
    _scrollDebounce?.cancel();
    _scrollDebounce = Timer(const Duration(milliseconds: 30), () {
      if (!mounted || !_scroll.hasClients) return;
      final target = _targetScrollOffset();
      final maxOff = _scroll.position.maxScrollExtent;
      final clamped = target.clamp(0.0, maxOff);
      if ((clamped - _scroll.offset).abs() < 1.5) return;
      _scroll.animateTo(
        clamped,
        duration: const Duration(milliseconds: 360),
        curve: Curves.easeOutCubic,
      );
    });
  }

  double _targetScrollOffset() {
    if (_measurePainter == null || _measureWidth <= 0) return 0;
    final readIdx = _readUpTo.value;
    final charOffset = readIdx >= _words.length
        ? _text.length
        : _words[readIdx].start;
    final caret = _measurePainter!
        .getOffsetForCaret(TextPosition(offset: charOffset), Rect.zero);
    // Удерживаем текущее слово примерно на трети высоты — комфортнее
    // читать, чем «вверх упёрто».
    final h = MediaQuery.of(context).size.height;
    final focusLine = h * 0.34;
    return caret.dy - focusLine;
  }

  // Fallback автоскролл — плавное движение с фиксированной скоростью,
  // если микрофон выключен.
  void _ensureFallbackTicker() {
    final shouldRun =
        !SpeechService.I.listening.value && _autoScrollEnabled;
    if (shouldRun) {
      if (_fallbackTicker == null) {
        _fallbackLastTick = DateTime.now();
        _fallbackTicker = createTicker(_onFallbackTick)..start();
      }
    } else {
      _fallbackTicker?.stop();
      _fallbackTicker?.dispose();
      _fallbackTicker = null;
      _fallbackLastTick = null;
    }
  }

  void _onFallbackTick(Duration _) {
    if (!_scroll.hasClients) return;
    final now = DateTime.now();
    final dt = _fallbackLastTick == null
        ? const Duration(milliseconds: 16)
        : now.difference(_fallbackLastTick!);
    _fallbackLastTick = now;
    final maxOff = _scroll.position.maxScrollExtent;
    if (maxOff <= 0) return;
    final delta = _fallbackSpeed * dt.inMilliseconds / 1000.0;
    final next = (_scroll.offset + delta).clamp(0.0, maxOff);
    _scroll.jumpTo(next);
  }

  void _onListeningChanged() {
    if (!mounted) return;
    setState(() {}); // обновить лейбл кнопки
    _ensureFallbackTicker();
  }

  // ──────────────────────── Mic toggle ────────────────────────

  Future<void> _toggleMic() async {
    if (SpeechService.I.listening.value) {
      await SpeechService.I.stop();
      _ensureFallbackTicker();
      _scheduleAutoHide();
      return;
    }
    // Запрос разрешения.
    final granted = await _ensureMicPermission();
    if (!granted) return;
    _prevRecognized = '';
    await SpeechService.I.start(localeId: _localeId);
    _ensureFallbackTicker();
    _scheduleAutoHide();
  }

  Future<bool> _ensureMicPermission() async {
    final mic = await Permission.microphone.request();
    if (!mic.isGranted) {
      if (!mounted) return false;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Нужно разрешение на микрофон',
              style: TextStyle(color: AppColors.text)),
          backgroundColor: AppColors.cont,
          duration: Duration(seconds: 2),
        ),
      );
      return false;
    }
    // На Android 12+ может потребоваться отдельное разрешение на
    // распознавание речи — плагин обрабатывает это сам в initialize().
    return true;
  }

  // ──────────────────────── Controls auto-hide ────────────────────────

  void _scheduleAutoHide() {
    _hideControlsTimer?.cancel();
    if (!_controlsVisible) return;
    _hideControlsTimer = Timer(const Duration(seconds: 4), () {
      if (!mounted) return;
      // Прячем только если идёт чтение (микрофон или fallback скролл) —
      // иначе нечего прятать.
      if (SpeechService.I.listening.value || _fallbackTicker != null) {
        setState(() => _controlsVisible = false);
      } else {
        _scheduleAutoHide();
      }
    });
  }

  void _toggleControls() {
    setState(() => _controlsVisible = !_controlsVisible);
    if (_controlsVisible) _scheduleAutoHide();
  }

  // ──────────────────────── Reset ────────────────────────

  void _reset() {
    _readUpTo.value = 0;
    _prevRecognized = '';
    SpeechService.I.recognized.value = '';
    if (_scroll.hasClients) {
      _scroll.animateTo(
        0,
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
      );
    }
  }

  // ──────────────────────── Build ────────────────────────

  @override
  Widget build(BuildContext context) {
    if (!_settingsLoaded) {
      return const Scaffold(
        backgroundColor: AppColors.bg,
        body: SizedBox.shrink(),
      );
    }
    final topInset = MediaQuery.of(context).padding.top;
    final bottomInset = MediaQuery.of(context).padding.bottom;
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Stack(
        children: [
          // Текст на полный экран.
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _toggleControls,
              child: LayoutBuilder(
                builder: (context, c) {
                  final maxW = c.maxWidth - 36; // 18+18 padding
                  _ensureMeasurePainter(maxW);
                  return SingleChildScrollView(
                    controller: _scroll,
                    physics: const ClampingScrollPhysics(),
                    padding: EdgeInsets.fromLTRB(
                      18,
                      topInset + 80,
                      18,
                      bottomInset + 140 + MediaQuery.of(context).size.height * 0.4,
                    ),
                    child: ValueListenableBuilder<int>(
                      valueListenable: _readUpTo,
                      builder: (_, readIdx, __) => RichText(
                        text: _buildSpan(readIdx),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),

          // Верхний градиент с back-кнопкой и индикатором.
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            child: IgnorePointer(
              ignoring: !_controlsVisible,
              child: AnimatedOpacity(
                opacity: _controlsVisible ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 200),
                child: TopFadeHeader(
                  title: 'Чтение',
                  onBack: () => Navigator.of(context).maybePop(),
                  trailing: [
                    _ProgressBadge(
                      readUpTo: _readUpTo,
                      total: _words.length,
                    ),
                  ],
                ),
              ),
            ),
          ),

          // Нижний градиент-док с контролами.
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: IgnorePointer(
              ignoring: !_controlsVisible,
              child: AnimatedOpacity(
                opacity: _controlsVisible ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 200),
                child: _BottomDock(
                  listening: SpeechService.I.listening,
                  onToggleMic: _toggleMic,
                  onReset: _reset,
                  fontSize: _fontSize,
                  onFontSize: (v) {
                    setState(() {
                      _fontSize = v;
                      _measurePainter = null;
                    });
                    Prefs.I.setFontSize(v);
                  },
                  speed: _fallbackSpeed,
                  onSpeed: (v) {
                    setState(() => _fallbackSpeed = v);
                    Prefs.I.setFallbackSpeed(v);
                  },
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  TextSpan _buildSpan(int readIdx) {
    final baseStyle = TextStyle(
      fontSize: _fontSize,
      height: _lineHeight,
      letterSpacing: -0.1,
      color: AppColors.text,
    );
    final dimStyle = baseStyle.copyWith(
      color: AppColors.sub.withValues(alpha: 0.65),
    );
    final accentStyle = baseStyle.copyWith(
      color: AppColors.accent,
      fontWeight: FontWeight.w600,
    );

    if (_words.isEmpty) {
      return TextSpan(text: _text, style: baseStyle);
    }

    final children = <TextSpan>[];
    final clampedRead = readIdx.clamp(0, _words.length);

    // Уже прочитанные слова: до начала текущего «активного» слова.
    final readEnd = clampedRead == 0 ? 0 : _words[clampedRead - 1].end;
    if (readEnd > 0) {
      children.add(TextSpan(
        text: _text.substring(0, readEnd),
        style: dimStyle,
      ));
    }

    // Активное слово — следующее, которое предстоит прочитать.
    if (clampedRead < _words.length) {
      final w = _words[clampedRead];
      if (w.start > readEnd) {
        children.add(TextSpan(
          text: _text.substring(readEnd, w.start),
          style: dimStyle,
        ));
      }
      children.add(TextSpan(
        text: _text.substring(w.start, w.end),
        style: accentStyle,
      ));
      if (w.end < _text.length) {
        children.add(TextSpan(
          text: _text.substring(w.end),
          style: baseStyle,
        ));
      }
    } else {
      // Всё прочитано.
      if (readEnd < _text.length) {
        children.add(TextSpan(
          text: _text.substring(readEnd),
          style: dimStyle,
        ));
      }
    }

    return TextSpan(children: children, style: baseStyle);
  }

  void _ensureMeasurePainter(double maxWidth) {
    if (_measurePainter != null &&
        (maxWidth - _measureWidth).abs() < 0.5) {
      return;
    }
    _measureWidth = maxWidth;
    _measurePainter = TextPainter(
      text: TextSpan(
        text: _text,
        style: TextStyle(
          fontSize: _fontSize,
          height: _lineHeight,
          letterSpacing: -0.1,
          color: AppColors.text,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: maxWidth);
  }
}

class _Word {
  final int start;
  final int end;
  final String normalized;
  const _Word({
    required this.start,
    required this.end,
    required this.normalized,
  });
}

class _ProgressBadge extends StatelessWidget {
  final ValueListenable<int> readUpTo;
  final int total;
  const _ProgressBadge({required this.readUpTo, required this.total});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: readUpTo,
      builder: (_, v, __) {
        final pct = total == 0 ? 0 : ((v / total) * 100).round();
        return Container(
          padding:
              const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: AppColors.cont,
            borderRadius: BorderRadius.circular(AppRadii.pill),
          ),
          child: Text(
            '$pct%',
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: AppColors.text,
            ),
          ),
        );
      },
    );
  }
}

class _BottomDock extends StatelessWidget {
  final ValueListenable<bool> listening;
  final VoidCallback onToggleMic;
  final VoidCallback onReset;
  final double fontSize;
  final ValueChanged<double> onFontSize;
  final double speed;
  final ValueChanged<double> onSpeed;

  const _BottomDock({
    required this.listening,
    required this.onToggleMic,
    required this.onReset,
    required this.fontSize,
    required this.onFontSize,
    required this.speed,
    required this.onSpeed,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.fromLTRB(
        16,
        18,
        16,
        16 + MediaQuery.of(context).padding.bottom,
      ),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [
            AppColors.bg.withValues(alpha: 0.96),
            AppColors.bg.withValues(alpha: 0.80),
            AppColors.bg.withValues(alpha: 0.50),
            AppColors.bg.withValues(alpha: 0.0),
          ],
          stops: const [0.0, 0.45, 0.80, 1.0],
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Слайдеры размера шрифта и скорости.
          Container(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
            decoration: BoxDecoration(
              color: AppColors.cont,
              borderRadius: BorderRadius.circular(18),
            ),
            child: Column(
              children: [
                _SliderRow(
                  icon: Icons.format_size_rounded,
                  label: 'Размер',
                  value: fontSize,
                  min: 16,
                  max: 44,
                  onChanged: onFontSize,
                  suffix: '${fontSize.round()}',
                ),
                const SizedBox(height: 8),
                _SliderRow(
                  icon: Icons.speed_rounded,
                  label: 'Скорость',
                  value: speed,
                  min: 10,
                  max: 80,
                  onChanged: onSpeed,
                  suffix: '${speed.round()} px/с',
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          // Кнопки управления.
          Row(
            children: [
              SizedBox(
                width: 56,
                child: PressScale(
                  onTap: onReset,
                  scale: 0.94,
                  child: Container(
                    height: 56,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: AppColors.cont,
                      borderRadius:
                          BorderRadius.circular(AppRadii.btn),
                    ),
                    child: const Icon(Icons.restart_alt_rounded,
                        size: 22, color: AppColors.text),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: ValueListenableBuilder<bool>(
                  valueListenable: listening,
                  builder: (_, on, __) => PrimaryButton(
                    onTap: onToggleMic,
                    label: on ? 'Стоп' : 'Микрофон',
                    icon: on ? Icons.stop_rounded : Icons.mic_rounded,
                    color: on ? AppColors.red : AppColors.accent,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SliderRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final double value;
  final double min;
  final double max;
  final ValueChanged<double> onChanged;
  final String suffix;
  const _SliderRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    required this.suffix,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 18, color: AppColors.sub),
        const SizedBox(width: 8),
        SizedBox(
          width: 70,
          child: Text(
            label,
            style: const TextStyle(
              fontSize: 13,
              color: AppColors.text,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
        Expanded(
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              activeTrackColor: AppColors.accent,
              inactiveTrackColor: AppColors.cont2,
              thumbColor: AppColors.accent,
              overlayColor: AppColors.accent.withValues(alpha: 0.18),
              thumbShape:
                  const RoundSliderThumbShape(enabledThumbRadius: 9),
              overlayShape:
                  const RoundSliderOverlayShape(overlayRadius: 18),
            ),
            child: Slider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              onChanged: onChanged,
            ),
          ),
        ),
        SizedBox(
          width: 58,
          child: Text(
            suffix,
            textAlign: TextAlign.right,
            style: const TextStyle(
              fontSize: 12,
              color: AppColors.sub,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ],
    );
  }
}
