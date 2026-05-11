import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api.dart';
import '../iconify.dart';
import '../navigation.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'shell.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});
  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  bool _loading = false;
  String _error = '';
  bool _success = false;

  Future<void> _pasteToken() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final data = await Clipboard.getData('text/plain');
      final raw = (data?.text ?? '').trim();
      if (raw.isEmpty) {
        setState(() {
          _loading = false;
          _error = 'Буфер обмена пуст';
        });
        return;
      }
      // быстрая валидация: ghp_, gho_, ghs_, ghu_, ghr_, github_pat_
      final ok = RegExp(r'^(ghp|gho|ghs|ghu|ghr)_|^github_pat_').hasMatch(raw);
      if (!ok) {
        setState(() {
          _loading = false;
          _error = 'Это не похоже на токен (ghp_… / github_pat_…)';
        });
        return;
      }
      final api = GhApi(raw);
      final user = await api.me();
      await AppState.I.saveToken(raw);
      AppState.I.user = user;
      // Сохраняем профиль в SharedPreferences сразу, чтобы при холодном
      // запуске пользователь видел аватарку и счётчики мгновенно.
      // ignore: discarded_futures
      AppState.I.saveUser();
      AppState.I.touch();
      if (!mounted) return;
      setState(() {
        _success = true;
        _loading = false;
      });
      await Future.delayed(const Duration(milliseconds: 600));
      if (!mounted) return;
      Navigator.of(context).pushAndRemoveUntil(
        SlideRoute(child: const ShellScreen()),
        (_) => false,
      );
    } catch (e) {
      setState(() {
        _loading = false;
        _error = 'Не удалось войти: ${e.toString().replaceAll('Exception: ', '')}';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    return Scaffold(
      backgroundColor: pal.bg,
      body: SafeArea(
        child: Stack(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    SizedBox(
                      width: 180,
                      height: 180,
                      child: Center(
                        child: Iconify('mdi:github',
                            size: 170, color: pal.text),
                      ),
                    ),
                    const SizedBox(height: 28),
                    Text(
                      'GitHub Pusher',
                      style: TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -.5,
                        color: pal.text,
                      ),
                    ),
                    const SizedBox(height: 12),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 280),
                      child: Text(
                        'Заливай файлы, отслеживай Actions и скачивай APK прямо с телефона.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 15,
                          color: pal.sub,
                          height: 1.5,
                        ),
                      ),
                    ),
                    const SizedBox(height: 28),
                    PressScale(
                      onTap: _loading ? null : _pasteToken,
                      scale: 0.96,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 28, vertical: 16),
                        decoration: BoxDecoration(
                          color: _success
                              ? AppColors.green
                              : AppColors.accent,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (_loading)
                              const SizedBox(
                                width: 22,
                                height: 22,
                                child: CircularProgressIndicator(
                                    color: Colors.white,
                                    strokeWidth: 2.4,
                                    strokeCap: StrokeCap.round),
                              )
                            else
                              Iconify(
                                _success
                                    ? 'solar:check-circle-bold'
                                    : 'solar:clipboard-add-bold',
                                size: 22,
                                color: Colors.white,
                              ),
                            const SizedBox(width: 10),
                            Text(
                              _success
                                  ? 'Готово'
                                  : (_loading ? 'Проверяем…' : 'Вставить ключ'),
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    PressScale(
                      onTap: () => launchUrl(
                        Uri.parse(
                            'https://github.com/settings/tokens/new?scopes=repo,delete_repo,workflow&description=GitHub%20Pusher'),
                        mode: LaunchMode.externalApplication,
                      ),
                      scale: 0.97,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Iconify('solar:link-bold',
                              size: 16, color: AppColors.accent),
                          const SizedBox(width: 6),
                          Text(
                            'Получить токен на GitHub',
                            style: TextStyle(
                              color: AppColors.accent,
                              fontSize: 14,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),
                    SizedBox(
                      height: 22,
                      child: Text(
                        _error,
                        style: const TextStyle(
                            color: AppColors.red, fontSize: 13),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 16,
              child: Center(
                child: Text(
                  'v 1.1 · Ваш токен хранится только на устройстве',
                  style: TextStyle(color: pal.sub, fontSize: 12),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
