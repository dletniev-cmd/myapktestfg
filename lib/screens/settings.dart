import 'package:flutter/material.dart';

import '../prefs.dart';
import '../speech.dart';
import '../theme.dart';
import '../widgets.dart';

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
  String _localeId = 'ru_RU';
  bool _loaded = false;
  List<_LocaleOption> _locales = const [
    _LocaleOption(id: 'ru_RU', label: 'Русский (Россия)'),
    _LocaleOption(id: 'en_US', label: 'English (US)'),
  ];

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
    final loc = await Prefs.I.getLocaleId();
    // Подтягиваем список локалей из STT, если он уже инициализирован.
    if (SpeechService.I.locales.isNotEmpty) {
      _locales = SpeechService.I.locales
          .map((l) => _LocaleOption(id: l.localeId, label: l.name))
          .toList();
    }
    if (!mounted) return;
    setState(() {
      _fontSize = fs;
      _lineHeight = lh;
      _autoScroll = auto;
      _fallbackSpeed = speed;
      _localeId = loc;
      _loaded = true;
    });
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
                ? SingleChildScrollView(
                    padding: EdgeInsets.fromLTRB(
                      16,
                      topInset + 70,
                      16,
                      32 + MediaQuery.of(context).padding.bottom,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _section('Отображение'),
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
                        _section('Чтение'),
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
                                padding:
                                    const EdgeInsets.fromLTRB(14, 6, 14, 8),
                                child: _SliderTile(
                                  icon: Icons.speed_rounded,
                                  title: 'Скорость без микрофона',
                                  value: _fallbackSpeed,
                                  min: 10,
                                  max: 80,
                                  suffix:
                                      '${_fallbackSpeed.round()} px/с',
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
                        _section('Распознавание речи'),
                        const SizedBox(height: 8),
                        CardBox(
                          padding: EdgeInsets.zero,
                          child: Column(
                            children: [
                              for (final loc in _locales) ...[
                                SettingsTile(
                                  icon: Icons.translate_rounded,
                                  iconBg: AppColors.blue,
                                  title: loc.label,
                                  sub: loc.id,
                                  trailing: _localeId == loc.id
                                      ? const Icon(
                                          Icons.check_rounded,
                                          color: AppColors.accent,
                                          size: 22,
                                        )
                                      : const SizedBox.shrink(),
                                  onTap: () {
                                    setState(() => _localeId = loc.id);
                                    Prefs.I.setLocaleId(loc.id);
                                  },
                                ),
                                if (loc != _locales.last)
                                  const HairlineDivider(),
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(height: 22),
                        _section('О приложении'),
                        const SizedBox(height: 8),
                        const CardBox(
                          padding: EdgeInsets.symmetric(
                              horizontal: 14, vertical: 12),
                          child: Text(
                            'Суфлёр — оффлайн-телепромптер, который '
                            'слушает твой голос через системное распознавание '
                            'речи и плавно прокручивает текст на ту скорость, '
                            'с которой ты читаешь. Без интернета и без '
                            'регистрации.',
                            style: TextStyle(
                              fontSize: 13,
                              height: 1.45,
                              color: AppColors.sub,
                            ),
                          ),
                        ),
                      ],
                    ),
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

  Widget _section(String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
      child: Text(
        text.toUpperCase(),
        style: const TextStyle(
          fontSize: 12,
          color: AppColors.sub,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}

class _LocaleOption {
  final String id;
  final String label;
  const _LocaleOption({required this.id, required this.label});
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
