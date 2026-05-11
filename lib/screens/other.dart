import 'package:flutter/material.dart';

import '../navigation.dart';
import '../notifications.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'appearance.dart';
import 'memory.dart';
import 'notifications.dart' as notif_screen;
import 'splash.dart';

class OtherScreen extends StatefulWidget {
  const OtherScreen({super.key});
  @override
  State<OtherScreen> createState() => _OtherScreenState();
}

class _OtherScreenState extends State<OtherScreen> {
  @override
  void initState() {
    super.initState();
    AppState.I.addListener(_onState);
    NotificationService.I.addListener(_onState);
  }

  @override
  void dispose() {
    AppState.I.removeListener(_onState);
    NotificationService.I.removeListener(_onState);
    super.dispose();
  }

  void _onState() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    final notif = NotificationService.I;
    final notifSub = !notif.enabled
        ? 'Выключены'
        : (notif.buildEnabled && notif.downloadEnabled
            ? 'Сборка и загрузки'
            : notif.buildEnabled
                ? 'Только сборка'
                : notif.downloadEnabled
                    ? 'Только загрузки'
                    : 'Без подсказок');
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
              const SecTitle('Настройки'),
              TileGroup(children: [
                Tile(
                  iconBg: AppColors.accent,
                  icon: 'solar:palette-bold',
                  title: 'Оформление',
                  sub: 'Тема и акцентный цвет',
                  onTap: () => pushSlide(context, const AppearanceScreen()),
                ),
                Tile(
                  iconBg: notif.enabled
                      ? AppColors.accent
                      : (pal.isDark
                          ? const Color(0xFF3A3A3F)
                          : const Color(0xFFB7B7BD)),
                  icon: notif.enabled
                      ? 'solar:bell-bold'
                      : 'solar:bell-off-bold',
                  title: 'Уведомления',
                  sub: notifSub,
                  onTap: () => pushSlide(
                    context,
                    const notif_screen.NotificationsScreen(),
                  ),
                ),
                Tile(
                  iconBg: AppColors.teal,
                  icon: 'solar:ssd-square-bold',
                  title: 'Память',
                  sub: 'Использование кэша',
                  onTap: () => pushSlide(context, const MemoryScreen()),
                ),
              ]),
              const SecTitle('Аккаунт'),
              TileGroup(children: [
                Tile(
                  iconBg: AppColors.red,
                  icon: 'solar:logout-2-bold',
                  title: 'Выйти',
                  sub: 'Сбросить токен',
                  titleColor: AppColors.red,
                  onTap: () async {
                    await AppState.I.logout();
                    if (!context.mounted) return;
                    Navigator.of(context).pushAndRemoveUntil(
                      SlideRoute(child: const SplashScreen()),
                      (_) => false,
                    );
                  },
                ),
              ]),
                ],
              ),
            ),
          ),
          ),
          const Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: TopFadeHeader(title: 'Другое'),
          ),
        ],
      ),
    );
  }
}

/// Компактный визуальный «свитч» — без собственных жест-распознавателей:
/// только рисует состояние, чтобы тап ВСЕГДА доходил до родительского
/// `Tile.onTap` или другой кликабельной обёртки.
class ThemedSwitch extends StatelessWidget {
  final bool active;
  const ThemedSwitch({super.key, required this.active});
  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    final trackOn = AppColors.accent;
    final trackOff = pal.isDark
        ? const Color(0xFF3A3A3F)
        : const Color(0xFFD8D8DC);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      width: 46,
      height: 28,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: active ? trackOn : trackOff,
        borderRadius: BorderRadius.circular(99),
      ),
      child: AnimatedAlign(
        alignment: active ? Alignment.centerRight : Alignment.centerLeft,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        child: Container(
          width: 22,
          height: 22,
          decoration: const BoxDecoration(
            color: Colors.white,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: Color(0x33000000),
                blurRadius: 4,
                offset: Offset(0, 1),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
