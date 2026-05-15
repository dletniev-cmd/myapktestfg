import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../prefs.dart';
import '../theme.dart';
import '../widgets.dart';

/// Экран настроек, разбитый на разделы: «Оформление», «Чтение»,
/// «Распознавание», «Ключи», «О приложении».
///
/// Никакого ввода клавиатурой — все значения меняются слайдерами,
/// switch'ами и кнопками. API-ключ Groq добавляется одной кнопкой
/// «Вставить из буфера обмена» (по запросу пользователя).
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  double _fontSize = 26;
  double _lineHeight = 1.5;
  double _fallbackSpeed = 28;
  bool _autoScroll = true;
  String _backend = 'local'; // 'local' | 'groq'
  String _groqKey = '';
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    final fs = await Prefs.I.getFontSize();
    final lh = await Prefs.I.getLineHeight();
    final auto = await Prefs.I.getAutoScroll();
    final speed = await Prefs.I.getFallbackSpeed();
    final backend = await Prefs.I.getSpeechBackend();
    final key = await Prefs.I.getGroqApiKey();
    if (!mounted) return;
    setState(() {
      _fontSize = fs;
      _lineHeight = lh;
      _autoScroll = auto;
      _fallbackSpeed = speed;
      _backend = backend;
      _groqKey = key;
      _loaded = true;
    });
  }

  Future<void> _pasteKey() async {
    final data = await Clipboard.getData('text/plain');
    final raw = data?.text?.trim() ?? '';
    if (raw.isEmpty) {
      _snack('Буфер обмена пуст');
      return;
    }
    if (!_looksLikeGroqKey(raw)) {
      _snack('Не похоже на ключ Groq (ожидается `gsk_...`)');
      return;
    }
    await Prefs.I.setGroqApiKey(raw);
    if (!mounted) return;
    setState(() => _groqKey = raw);
    _snack('Ключ сохранён');
  }

  Future<void> _removeKey() async {
    await Prefs.I.clearGroqApiKey();
    if (!mounted) return;
    setState(() => _groqKey = '');
    _snack('Ключ удалён');
  }

  void _setBackend(String v) {
    setState(() => _backend = v);
    Prefs.I.setSpeechBackend(v);
  }

  bool _looksLikeGroqKey(String s) =>
      s.startsWith('gsk_') && s.length >= 20;

  void _snack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg, style: const TextStyle(color: AppColors.text)),
        backgroundColor: AppColors.cont,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final topInset = MediaQuery.of(context).padding.top;
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Stack(
        children: [
          Positioned.fill(
            child: _loaded
                ? ListView(
                    padding: EdgeInsets.fromLTRB(
                      16,
                      topInset + 70,
                      16,
                      32 + MediaQuery.of(context).padding.bottom,
                    ),
                    physics: const BouncingScrollPhysics(),
                    children: [
                      const _SectionHeader('Оформление'),
                      const SizedBox(height: 8),
                      CardBox(
                        padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
                        child: Column(
                          children: [
                            _SliderTile(
                              icon: Icons.format_size_rounded,
                              title: 'Размер шрифта',
                              value: _fontSize,
                              min: 16,
                              max: 44,
                              suffix: '${_fontSize.round()}',
                              onChanged: (v) {
                                setState(() => _fontSize = v);
                                Prefs.I.setFontSize(v);
                              },
                            ),
                            const HairlineDivider(indent: 0),
                            _SliderTile(
                              icon: Icons.format_line_spacing_rounded,
                              title: 'Межстрочный интервал',
                              value: _lineHeight,
                              min: 1.1,
                              max: 2.0,
                              suffix: _lineHeight.toStringAsFixed(2),
                              onChanged: (v) {
                                setState(() => _lineHeight = v);
                                Prefs.I.setLineHeight(v);
                              },
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 22),
                      const _SectionHeader('Чтение'),
                      const SizedBox(height: 8),
                      CardBox(
                        padding: EdgeInsets.zero,
                        child: Column(
                          children: [
                            SettingsTile(
                              icon: Icons.bolt_rounded,
                              iconBg: AppColors.accent,
                              title: 'Авто-прокрутка',
                              sub: _autoScroll
                                  ? 'Прокрутка идёт сама'
                                  : 'Прокрутка только вручную',
                              trailing: Switch.adaptive(
                                activeColor: AppColors.accent,
                                value: _autoScroll,
                                onChanged: (v) {
                                  setState(() => _autoScroll = v);
                                  Prefs.I.setAutoScroll(v);
                                },
                              ),
                            ),
                            const HairlineDivider(),
                            Padding(
                              padding: const EdgeInsets.fromLTRB(
                                  14, 6, 14, 8),
                              child: _SliderTile(
                                icon: Icons.speed_rounded,
                                title: 'Скорость без микрофона',
                                value: _fallbackSpeed,
                                min: 10,
                                max: 80,
                                suffix: '${_fallbackSpeed.round()} px/с',
                                onChanged: (v) {
                                  setState(() => _fallbackSpeed = v);
                                  Prefs.I.setFallbackSpeed(v);
                                },
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 22),
                      const _SectionHeader('Распознавание'),
                      const SizedBox(height: 8),
                      CardBox(
                        padding: EdgeInsets.zero,
                        child: Column(
                          children: [
                            SettingsTile(
                              icon: Icons.phone_android_rounded,
                              iconBg: AppColors.blue,
                              title: 'Локальное (системное)',
                              sub: 'Работает офлайн. Может прерываться.',
                              trailing: _backend == 'local'
                                  ? const Icon(Icons.check_rounded,
                                      color: AppColors.accent, size: 22)
                                  : const SizedBox(width: 22),
                              onTap: () => _setBackend('local'),
                            ),
                            const HairlineDivider(),
                            SettingsTile(
                              icon: Icons.bolt_outlined,
                              iconBg: AppColors.purple,
                              title: 'Groq Whisper (онлайн)',
                              sub: _groqKey.isEmpty
                                  ? 'Нужен ключ в разделе «Ключи».'
                                  : 'Готово к работе. Нужен интернет.',
                              trailing: _backend == 'groq'
                                  ? const Icon(Icons.check_rounded,
                                      color: AppColors.accent, size: 22)
                                  : const SizedBox(width: 22),
                              onTap: () {
                                if (_groqKey.isEmpty) {
                                  _snack('Сначала вставь ключ Groq');
                                  return;
                                }
                                _setBackend('groq');
                              },
                            ),
                            const HairlineDivider(),
                            const Padding(
                              padding: EdgeInsets.fromLTRB(14, 10, 14, 14),
                              child: Text(
                                'Язык распознавания — только русский. '
                                'Иностранные слова и числа всё равно '
                                'будут распознаваться.',
                                style: TextStyle(
                                  fontSize: 12.5,
                                  height: 1.4,
                                  color: AppColors.sub,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 22),
                      const _SectionHeader('Ключи'),
                      const SizedBox(height: 8),
                      CardBox(
                        padding: EdgeInsets.zero,
                        child: Column(
                          children: [
                            Padding(
                              padding: const EdgeInsets.fromLTRB(
                                  14, 14, 14, 6),
                              child: Row(
                                children: [
                                  Container(
                                    width: 32,
                                    height: 32,
                                    decoration: BoxDecoration(
                                      color: AppColors.purple,
                                      borderRadius:
                                          BorderRadius.circular(8),
                                    ),
                                    alignment: Alignment.center,
                                    child: const Icon(
                                      Icons.vpn_key_rounded,
                                      size: 18,
                                      color: Colors.white,
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  const Expanded(
                                    child: Text(
                                      'Ключ Groq API',
                                      style: TextStyle(
                                        fontSize: 15,
                                        fontWeight: FontWeight.w500,
                                        color: AppColors.text,
                                      ),
                                    ),
                                  ),
                                  if (_groqKey.isNotEmpty)
                                    Container(
                                      padding:
                                          const EdgeInsets.symmetric(
                                              horizontal: 8,
                                              vertical: 3),
                                      decoration: BoxDecoration(
                                        color: AppColors.green
                                            .withValues(alpha: 0.18),
                                        borderRadius:
                                            BorderRadius.circular(
                                                AppRadii.pill),
                                      ),
                                      child: const Text(
                                        'установлен',
                                        style: TextStyle(
                                          fontSize: 11,
                                          color: AppColors.green,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    )
                                  else
                                    Container(
                                      padding:
                                          const EdgeInsets.symmetric(
                                              horizontal: 8,
                                              vertical: 3),
                                      decoration: BoxDecoration(
                                        color: AppColors.cont2,
                                        borderRadius:
                                            BorderRadius.circular(
                                                AppRadii.pill),
                                      ),
                                      child: const Text(
                                        'не задан',
                                        style: TextStyle(
                                          fontSize: 11,
                                          color: AppColors.sub,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                            if (_groqKey.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.fromLTRB(
                                    14, 4, 14, 0),
                                child: Text(
                                  _maskKey(_groqKey),
                                  style: const TextStyle(
                                    fontSize: 13,
                                    color: AppColors.sub,
                                    fontFamily: 'monospace',
                                    fontFamilyFallback: ['Menlo', 'Courier'],
                                  ),
                                ),
                              ),
                            Padding(
                              padding: const EdgeInsets.fromLTRB(
                                  14, 12, 14, 14),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: PrimaryButton(
                                      label: _groqKey.isEmpty
                                          ? 'Вставить ключ'
                                          : 'Заменить ключ',
                                      icon: Icons.paste_rounded,
                                      onTap: _pasteKey,
                                      height: 46,
                                    ),
                                  ),
                                  if (_groqKey.isNotEmpty) ...[
                                    const SizedBox(width: 10),
                                    SizedBox(
                                      width: 46,
                                      child: PressScale(
                                        onTap: _removeKey,
                                        scale: 0.94,
                                        child: Container(
                                          height: 46,
                                          decoration: BoxDecoration(
                                            color: AppColors.red
                                                .withValues(
                                                    alpha: 0.18),
                                            borderRadius:
                                                BorderRadius.circular(
                                                    AppRadii.btn),
                                          ),
                                          alignment: Alignment.center,
                                          child: const Icon(
                                            Icons.delete_outline_rounded,
                                            color: AppColors.red,
                                            size: 22,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                            const HairlineDivider(),
                            const Padding(
                              padding:
                                  EdgeInsets.fromLTRB(14, 12, 14, 14),
                              child: Text(
                                'Скопируй ключ на сайте Groq '
                                '(console.groq.com → API Keys) и нажми '
                                '«Вставить ключ». Ключ хранится только '
                                'на устройстве — Суфлёр шлёт запросы '
                                'напрямую в Groq.',
                                style: TextStyle(
                                  fontSize: 12.5,
                                  height: 1.4,
                                  color: AppColors.sub,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 22),
                      const _SectionHeader('О приложении'),
                      const SizedBox(height: 8),
                      const CardBox(
                        padding: EdgeInsets.symmetric(
                            horizontal: 14, vertical: 12),
                        child: Text(
                          'Суфлёр — телепромптер с авто-прокруткой по '
                          'голосу. Поддерживает два движка распознавания: '
                          'локальный (офлайн, без интернета) и Groq '
                          'Whisper (онлайн, заметно быстрее и стабильнее). '
                          'Все настройки и тексты хранятся только '
                          'на устройстве.',
                          style: TextStyle(
                            fontSize: 13,
                            height: 1.45,
                            color: AppColors.sub,
                          ),
                        ),
                      ),
                    ],
                  )
                : const SizedBox.shrink(),
          ),
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            child: TopFadeHeader(
              title: 'Настройки',
              onBack: () => Navigator.of(context).maybePop(),
            ),
          ),
        ],
      ),
    );
  }

  String _maskKey(String key) {
    if (key.length <= 12) return key;
    final head = key.substring(0, 6);
    final tail = key.substring(key.length - 4);
    return '$head••••••••$tail';
  }
}

class _SectionHeader extends StatelessWidget {
  final String text;
  const _SectionHeader(this.text);
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
      child: Text(
        text.toUpperCase(),
        style: const TextStyle(
          fontSize: 12,
          color: AppColors.sub,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

class _SliderTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final double value;
  final double min;
  final double max;
  final String suffix;
  final ValueChanged<double> onChanged;
  const _SliderTile({
    required this.icon,
    required this.title,
    required this.value,
    required this.min,
    required this.max,
    required this.suffix,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: AppColors.sub),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 14,
                    color: AppColors.text,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              Text(
                suffix,
                style: const TextStyle(
                  fontSize: 13,
                  color: AppColors.sub,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
          SliderTheme(
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
        ],
      ),
    );
  }
}
