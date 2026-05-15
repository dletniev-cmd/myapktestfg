import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../prefs.dart';
import '../theme.dart';
import '../widgets.dart';
import 'prompter.dart';
import 'settings.dart';

/// Главный экран: текстовое поле, в которое можно вставить/набрать
/// текст для чтения, и кнопка «Начать».
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focus = FocusNode();
  Timer? _saveDebounce;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    final text = await Prefs.I.getText();
    if (!mounted) return;
    setState(() {
      _controller.text = text;
      _loaded = true;
    });
    _controller.addListener(_onChanged);
  }

  void _onChanged() {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 400), () {
      Prefs.I.setText(_controller.text);
    });
  }

  @override
  void dispose() {
    _saveDebounce?.cancel();
    _controller.removeListener(_onChanged);
    _controller.dispose();
    _focus.dispose();
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
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const SettingsScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final topInset = MediaQuery.of(context).padding.top;
    final bottomInset =
        MediaQuery.of(context).viewInsets.bottom +
            MediaQuery.of(context).padding.bottom;
    final wordCount = _controller.text
        .split(RegExp(r'\s+'))
        .where((w) => w.trim().isNotEmpty)
        .length;
    final charCount = _controller.text.length;

    return Scaffold(
      backgroundColor: AppColors.bg,
      resizeToAvoidBottomInset: true,
      body: Stack(
        children: [
          // Контент.
          Positioned.fill(
            child: Padding(
              padding: EdgeInsets.only(
                top: topInset + 68,
                bottom: bottomInset > 0 ? bottomInset + 96 : 96,
              ),
              child: _loaded
                  ? _buildBody(wordCount, charCount)
                  : const SizedBox.shrink(),
            ),
          ),

          // Шапка с градиентом-фейдом.
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            child: TopFadeHeader(
              title: 'Суфлёр',
              trailing: [
                _HeaderIconButton(
                  icon: Icons.tune_rounded,
                  onTap: _openSettings,
                ),
              ],
            ),
          ),

          // Нижний док с кнопкой «Начать».
          Positioned(
            left: 16,
            right: 16,
            bottom: 16 + MediaQuery.of(context).padding.bottom,
            child: PrimaryButton(
              label: 'Начать чтение',
              icon: Icons.play_arrow_rounded,
              onTap: _openPrompter,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(int wordCount, int charCount) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      keyboardDismissBehavior:
          ScrollViewKeyboardDismissBehavior.onDrag,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Карточка с действиями над текстом.
          CardBox(
            padding: const EdgeInsets.all(6),
            child: Row(
              children: [
                Expanded(
                  child: _ActionChip(
                    icon: Icons.paste_rounded,
                    label: 'Вставить',
                    onTap: _pasteFromClipboard,
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: _ActionChip(
                    icon: Icons.cleaning_services_rounded,
                    label: 'Очистить',
                    onTap: _clear,
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: _ActionChip(
                    icon: Icons.copy_rounded,
                    label: 'Копировать',
                    onTap: () async {
                      if (_controller.text.isEmpty) return;
                      await Clipboard.setData(
                          ClipboardData(text: _controller.text));
                      if (!mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Скопировано',
                              style: TextStyle(color: AppColors.text)),
                          backgroundColor: AppColors.cont,
                          duration: Duration(seconds: 1),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          // Большое текстовое поле.
          CardBox(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Text(
                      'Текст для чтения',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: AppColors.sub,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      '$wordCount сл. · $charCount зн.',
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.sub,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                TextField(
                  controller: _controller,
                  focusNode: _focus,
                  maxLines: null,
                  minLines: 14,
                  keyboardType: TextInputType.multiline,
                  textCapitalization: TextCapitalization.sentences,
                  cursorColor: AppColors.accent,
                  style: const TextStyle(
                    fontSize: 16,
                    height: 1.4,
                    color: AppColors.text,
                  ),
                  decoration: const InputDecoration(
                    border: InputBorder.none,
                    isCollapsed: true,
                    hintText:
                        'Вставь сюда текст, который хочешь прочитать. '
                        'Микрофон сам подсветит слова и плавно подскролит вниз.',
                    hintStyle: TextStyle(
                      color: AppColors.sub,
                      fontSize: 16,
                      height: 1.4,
                    ),
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          // Подсказка про микрофон.
          CardBox(
            color: AppColors.cont,
            padding: const EdgeInsets.symmetric(
                horizontal: 14, vertical: 12),
            child: Row(
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: AppColors.accent,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  alignment: Alignment.center,
                  child: const Icon(Icons.mic_rounded,
                      size: 19, color: Colors.white),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text(
                    'Включи микрофон во время чтения — текст будет '
                    'плавно прокручиваться сам.',
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.35,
                      color: AppColors.text,
                    ),
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

class _ActionChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _ActionChip({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return PressScale(
      onTap: onTap,
      scale: 0.96,
      child: Container(
        height: 56,
        decoration: BoxDecoration(
          color: AppColors.cont2,
          borderRadius: BorderRadius.circular(14),
        ),
        alignment: Alignment.center,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: AppColors.text, size: 19),
            const SizedBox(height: 3),
            Text(
              label,
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                color: AppColors.text,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HeaderIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _HeaderIconButton({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return PressScale(
      onTap: onTap,
      scale: 0.92,
      child: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          color: AppColors.cont,
          borderRadius: BorderRadius.circular(AppRadii.btn),
        ),
        alignment: Alignment.center,
        child: Icon(icon, color: AppColors.text, size: 19),
      ),
    );
  }
}
