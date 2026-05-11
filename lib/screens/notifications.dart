import 'package:flutter/material.dart';

import '../notifications.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'other.dart' show ThemedSwitch;

/// Экран управления локальными уведомлениями приложения.
///
/// Содержит мастер-свитч и категориальные свитчи (сборка, загрузки).
/// Настройки персистятся через [NotificationService] в SharedPreferences
/// сразу при тапе, без отдельной кнопки «Сохранить» — как принято в
/// iOS/Android настройках.
class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key});

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  final NotificationService _notif = NotificationService.I;

  @override
  void initState() {
    super.initState();
    _notif.addListener(_onState);
    // На случай если экран открыли до того, как стейт успел подгрузиться
    // (например очень холодный старт) — догружаем настройки.
    // ignore: discarded_futures
    _notif.loadSettings();
    // Также вызываем init — если разрешение POST_NOTIFICATIONS ещё не было
    // запрошено, системный диалог появится здесь.
    // ignore: discarded_futures
    _notif.ensureInit();
  }

  @override
  void dispose() {
    _notif.removeListener(_onState);
    super.dispose();
  }

  void _onState() {
    if (mounted) setState(() {});
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
                    const SecTitle('Общие'),
                    TileGroup(children: [
                      Tile(
                        iconBg: _notif.enabled
                            ? AppColors.accent
                            : (pal.isDark
                                ? const Color(0xFF3A3A3F)
                                : const Color(0xFFB7B7BD)),
                        icon: _notif.enabled
                            ? 'solar:bell-bold'
                            : 'solar:bell-off-bold',
                        title: 'Уведомления',
                        sub: _notif.enabled ? 'Включены' : 'Отключены',
                        onTap: () => _notif.setEnabled(!_notif.enabled),
                        trailing: ThemedSwitch(active: _notif.enabled),
                      ),
                    ]),
                    _AnimatedReveal(
                      visible: _notif.enabled,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const SecTitle('Категории'),
                          TileGroup(children: [
                            _CategoryTile(
                              iconBg: AppColors.purple,
                              icon: 'solar:rocket-bold',
                              title: 'Сборка',
                              sub: 'Старт и завершение GitHub Actions',
                              active: _notif.buildEnabled,
                              onTap: () => _notif
                                  .setBuildEnabled(!_notif.buildEnabled),
                            ),
                            _CategoryTile(
                              iconBg: AppColors.green,
                              icon: 'solar:download-bold',
                              title: 'Загрузки',
                              sub:
                                  'Прогресс и завершение скачивания артефактов',
                              active: _notif.downloadEnabled,
                              onTap: () => _notif.setDownloadEnabled(
                                  !_notif.downloadEnabled),
                            ),
                          ]),
                          Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 4, vertical: 6),
                            child: Text(
                              'Уведомления показываются как обычные '
                              'системные баннеры Android. Их можно дополнительно '
                              'отключить в системных настройках приложения.',
                              style: TextStyle(
                                fontSize: 12.5,
                                color: pal.sub,
                                height: 1.35,
                              ),
                            ),
                          ),
                        ],
                      ),
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
            child: TopFadeHeader(title: 'Уведомления'),
          ),
        ],
      ),
    );
  }
}

/// Tile для категории уведомлений.
class _CategoryTile extends StatelessWidget {
  final Color iconBg;
  final String icon;
  final String title;
  final String sub;
  final bool active;
  final VoidCallback onTap;
  const _CategoryTile({
    required this.iconBg,
    required this.icon,
    required this.title,
    required this.sub,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    return Tile(
      iconBg: active
          ? iconBg
          : (pal.isDark
              ? const Color(0xFF3A3A3F)
              : const Color(0xFFB7B7BD)),
      icon: icon,
      title: title,
      sub: sub,
      onTap: onTap,
      trailing: ThemedSwitch(active: active),
    );
  }
}

/// Плавное «растворение» / появление [child] — чистый fade без
/// смещения по высоте. Когда `visible = false`, прозрачность
/// анимируется до 0 и тапы блокируются через [IgnorePointer].
/// Когда `visible = true` — обратный фейд к 1.0.
class _AnimatedReveal extends StatelessWidget {
  final bool visible;
  final Widget child;
  const _AnimatedReveal({required this.visible, required this.child});

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
      opacity: visible ? 1.0 : 0.0,
      child: IgnorePointer(
        ignoring: !visible,
        child: child,
      ),
    );
  }
}
