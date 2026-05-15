import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../prefs.dart';
import '../theme.dart';
import '../widgets.dart';
import 'prompter.dart';
import 'settings.dart';

/// Главный экран: текстовое поле, в которое можно вставить/набрать
/// текст для чтения, и круглая FAB-кнопка «play» справа снизу.
///
/// Текст лежит «прямо на фоне», без карточки-контейнера — чтобы
/// при скролле плавно «уходил» под верхний градиент-фейд (см.
/// [TopFadeHeader]) и под нижнюю кнопку (см. [_BottomFade]).
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focus = FocusNode();
  // Счётчики для индикатора слов/символов — обновляются раз в ~200мс,
  // чтобы не дёргать rebuild на каждый keystroke и не закрывать
  // клавиатуру из-за лишних setState.
  final ValueNotifier<_TextStats> _stats =
      ValueNotifier<_TextStats>(_TextStats.empty);
  Timer? _saveDebounce;
  Timer? _statsDebounce;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    final text = await Prefs.I.getText();
    if (!mounted) return;
    _controller.text = text;
    _stats.value = _TextStats.of(text);
    setState(() => _loaded = true);
    _controller.addListener(_onChanged);
  }

  void _onChanged() {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 400), () {
      Prefs.I.setText(_controller.text);
    });
    _statsDebounce?.cancel();
    _statsDebounce = Timer(const Duration(milliseconds: 180), () {
      _stats.value = _TextStats.of(_controller.text);
    });
  }

  @override
  void dispose() {
    _saveDebounce?.cancel();
    _statsDebounce?.cancel();
    _controller.removeListener(_onChanged);
    _controller.dispose();
    _focus.dispose();
    _stats.dispose();
    super.dispose();
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData('text/plain');
    final text = data?.text;
    if (text == null || text.isEmpty) return;
    final c = _controller;
    final sel = c.selection;
    if (sel.isValid && !sel.isCollapsed) {
      c.text = c.text.replaceRange(sel.start, sel.end, text);
      c.selection =
          TextSelection.collapsed(offset: sel.start + text.length);
    } else if (sel.isValid) {
      final pos = sel.baseOffset;
      c.text = c.text.replaceRange(pos, pos, text);
      c.selection = TextSelection.collapsed(offset: pos + text.length);
    } else {
      c.text = text;
      c.selection = TextSelection.collapsed(offset: text.length);
    }
  }

  void _clear() {
    _controller.clear();
  }

  Future<void> _copy() async {
    if (_controller.text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: _controller.text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Скопировано',
            style: TextStyle(color: AppColors.text)),
        backgroundColor: AppColors.cont,
        duration: Duration(seconds: 1),
      ),
    );
  }

  void _openPrompter() {
    final text = _controller.text.trim();
    if (text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Сначала вставь или введи текст',
              style: TextStyle(color: AppColors.text)),
          backgroundColor: AppColors.cont,
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }
    FocusScope.of(context).unfocus();
    Navigator.of(context).push(
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 320),
        reverseTransitionDuration: const Duration(milliseconds: 260),
        pageBuilder: (_, __, ___) => PrompterScreen(text: text),
        transitionsBuilder: (_, anim, __, child) {
          final curved = CurvedAnimation(
            parent: anim,
            curve: Curves.easeOutCubic,
            reverseCurve: Curves.easeInCubic,
          );
          return FadeTransition(
            opacity: curved,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, 0.04),
                end: Offset.zero,
              ).animate(curved),
              child: child,
            ),
          );
        },
      ),
    );
  }

  void _openSettings() {
    FocusScope.of(context).unfocus();
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const SettingsScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final topInset = MediaQuery.of(context).padding.top;
    final bottomInset = MediaQuery.of(context).padding.bottom;

    return Scaffold(
      backgroundColor: AppColors.bg,
      resizeToAvoidBottomInset: true,
      body: Stack(
        children: [
          // Сам редактор — на всю высоту, без карточки.
          Positioned.fill(
            child: _loaded
                ? _buildEditor(topInset, bottomInset)
                : const SizedBox.shrink(),
          ),

          // Верхний градиент-фейд + заголовок.
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            child: TopFadeHeader(
              title: 'Суфлёр',
              trailing: [
                CircleIconChip(
                  icon: Icons.tune_rounded,
                  onTap: _openSettings,
                ),
              ],
            ),
          ),

          // Нижний градиент-фейд + плашка действий + FAB.
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _BottomBar(
              bottomInset: bottomInset,
              stats: _stats,
              onPaste: _pasteFromClipboard,
              onClear: _clear,
              onCopy: _copy,
              onStart: _openPrompter,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEditor(double topInset, double bottomInset) {
    // TextField сам по себе многострочный и работает внутри
    // SingleChildScrollView — этого достаточно для длинных текстов
    // и для того, чтобы они уезжали под градиент сверху и под
    // нижнюю плашку.
    return SingleChildScrollView(
      // `manual` нарочно — иначе свайп по тексту во время фокуса
      // дёргает клавиатуру (была баг-репорт).
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.manual,
      padding: EdgeInsets.fromLTRB(
        18,
        topInset + 72,
        18,
        bottomInset + 200,
      ),
      child: TextField(
        controller: _controller,
        focusNode: _focus,
        maxLines: null,
        minLines: 18,
        keyboardType: TextInputType.multiline,
        textCapitalization: TextCapitalization.sentences,
        cursorColor: AppColors.accent,
        cursorWidth: 2.0,
        style: const TextStyle(
          fontSize: 18,
          height: 1.45,
          color: AppColors.text,
          letterSpacing: -0.1,
        ),
        decoration: const InputDecoration(
          border: InputBorder.none,
          isCollapsed: true,
          contentPadding: EdgeInsets.zero,
          hintText:
              'Вставь или введи текст — Суфлёр подсветит слова и '
              'сам подскролит, пока ты читаешь вслух.',
          hintStyle: TextStyle(
            color: AppColors.sub,
            fontSize: 18,
            height: 1.45,
            letterSpacing: -0.1,
          ),
        ),
      ),
    );
  }
}

class _TextStats {
  final int words;
  final int chars;
  const _TextStats(this.words, this.chars);
  static const empty = _TextStats(0, 0);
  static _TextStats of(String s) {
    final w = s
        .split(RegExp(r'\s+'))
        .where((p) => p.trim().isNotEmpty)
        .length;
    return _TextStats(w, s.length);
  }
}

/// Нижняя плашка: градиент-фейд (под который уходит текст) + ряд
/// chip-кнопок «Вставить / Очистить / Копировать» + круглая FAB
/// справа.
class _BottomBar extends StatelessWidget {
  final double bottomInset;
  final ValueListenable<_TextStats> stats;
  final VoidCallback onPaste;
  final VoidCallback onClear;
  final VoidCallback onCopy;
  final VoidCallback onStart;
  const _BottomBar({
    required this.bottomInset,
    required this.stats,
    required this.onPaste,
    required this.onClear,
    required this.onCopy,
    required this.onStart,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
        padding: EdgeInsets.fromLTRB(
          16,
          22,
          16,
          12 + bottomInset,
        ),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [
              AppColors.bg,
              AppColors.bg.withValues(alpha: 0.94),
              AppColors.bg.withValues(alpha: 0.74),
              AppColors.bg.withValues(alpha: 0.42),
              AppColors.bg.withValues(alpha: 0.16),
              AppColors.bg.withValues(alpha: 0.0),
            ],
            stops: const [0.0, 0.30, 0.55, 0.75, 0.90, 1.0],
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  ValueListenableBuilder<_TextStats>(
                    valueListenable: stats,
                    builder: (_, s, __) => Padding(
                      padding: const EdgeInsets.only(left: 4, bottom: 8),
                      child: Text(
                        s.words == 0
                            ? 'Текст для чтения'
                            : '${s.words} сл. · ${s.chars} зн.',
                        style: const TextStyle(
                          fontSize: 12,
                          color: AppColors.sub,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ),
                  Row(
                    children: [
                      _ChipAction(
                        icon: Icons.paste_rounded,
                        label: 'Вставить',
                        onTap: onPaste,
                      ),
                      const SizedBox(width: 8),
                      _ChipAction(
                        icon: Icons.cleaning_services_rounded,
                        label: 'Очистить',
                        onTap: onClear,
                      ),
                      const SizedBox(width: 8),
                      _ChipAction(
                        icon: Icons.copy_rounded,
                        label: 'Копия',
                        onTap: onCopy,
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            _PlayFab(onTap: onStart),
          ],
        ),
    );
  }
}

class _ChipAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _ChipAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return PressScale(
      onTap: onTap,
      scale: 0.94,
      child: Container(
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: AppColors.cont,
          borderRadius: BorderRadius.circular(AppRadii.pill),
        ),
        alignment: Alignment.center,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: AppColors.text, size: 16),
            const SizedBox(width: 6),
            Text(
              label,
              style: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: AppColors.text,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PlayFab extends StatelessWidget {
  final VoidCallback onTap;
  const _PlayFab({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return PressScale(
      onTap: onTap,
      scale: 0.92,
      child: Container(
        width: 64,
        height: 64,
        decoration: BoxDecoration(
          color: AppColors.accent,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: AppColors.accent.withValues(alpha: 0.32),
              blurRadius: 16,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        alignment: Alignment.center,
        child: const Icon(
          Icons.play_arrow_rounded,
          color: Colors.white,
          size: 32,
        ),
      ),
    );
  }
}
