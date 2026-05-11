import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';

/// Глобальный сервис локальных уведомлений.
///
/// Раньше код инициализации FlutterLocalNotificationsPlugin был зашит прямо
/// в `actions_archive.dart` и работал только для скачивания артефактов. Эта
/// классовая обёртка централизует всё:
///
///   * Инициализация плагина один раз за процесс.
///   * Хранение пользовательских настроек (мастер-свитч + по типам).
///   * Удобные методы для каждого типа уведомлений (сборка, загрузка).
///
/// Все методы безопасно вызывать даже если разрешение POST_NOTIFICATIONS не
/// выдано — Android просто не покажет уведомление, ошибки наружу не
/// прокидываются.
class NotificationService extends ChangeNotifier {
  NotificationService._();
  static final NotificationService I = NotificationService._();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  bool _inited = false;

  // === Настройки (персистятся в SharedPreferences) ===
  /// Мастер-свитч: если выключен — ни одно уведомление не показывается.
  bool enabled = true;

  /// Уведомления о ходе/завершении сборки (GitHub Actions runs).
  bool buildEnabled = true;

  /// Уведомления о прогрессе/завершении скачивания артефактов.
  bool downloadEnabled = true;

  bool _settingsLoaded = false;

  /// Загружает сохранённые настройки из SharedPreferences. Идемпотентна.
  Future<void> loadSettings() async {
    if (_settingsLoaded) return;
    final p = await SharedPreferences.getInstance();
    enabled = p.getBool('notif_enabled') ?? true;
    buildEnabled = p.getBool('notif_build') ?? true;
    downloadEnabled = p.getBool('notif_download') ?? true;
    _settingsLoaded = true;
    notifyListeners();
  }

  Future<void> setEnabled(bool v) async {
    enabled = v;
    notifyListeners();
    final p = await SharedPreferences.getInstance();
    await p.setBool('notif_enabled', v);
    if (!v) {
      // При полном выключении гасим текущие баннеры — пользователь хочет
      // тишины, а не висящий progress.
      try {
        await _plugin.cancelAll();
      } catch (_) {}
    }
  }

  Future<void> setBuildEnabled(bool v) async {
    buildEnabled = v;
    notifyListeners();
    final p = await SharedPreferences.getInstance();
    await p.setBool('notif_build', v);
  }

  Future<void> setDownloadEnabled(bool v) async {
    downloadEnabled = v;
    notifyListeners();
    final p = await SharedPreferences.getInstance();
    await p.setBool('notif_download', v);
  }

  bool get effectiveBuild => enabled && buildEnabled;
  bool get effectiveDownload => enabled && downloadEnabled;

  /// Инициализация плагина + запрос разрешения POST_NOTIFICATIONS.
  /// Безопасно вызывать многократно — повторно не делает ничего.
  Future<void> ensureInit() async {
    if (_inited) return;
    _inited = true;
    try {
      const android = AndroidInitializationSettings('@mipmap/ic_launcher');
      await _plugin.initialize(const InitializationSettings(android: android));
      final androidImpl = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      try {
        await androidImpl?.requestNotificationsPermission();
      } catch (_) {
        // На некоторых старых Android просто нет такого API — игнорим.
      }
    } catch (_) {
      // Плагин на не-Android платформах может бросить — нам всё равно.
    }
  }

  // === Скачивания ===
  Future<void> showDownloadProgress({
    required int id,
    required String title,
    required int percent,
  }) async {
    if (!effectiveDownload) return;
    await ensureInit();
    try {
      await _plugin.show(
        id,
        title,
        '$percent%',
        NotificationDetails(
          android: AndroidNotificationDetails(
            'download',
            'Загрузки',
            channelDescription: 'Прогресс загрузки артефактов',
            importance: Importance.low,
            priority: Priority.low,
            showProgress: true,
            maxProgress: 100,
            progress: percent,
            ongoing: true,
            onlyAlertOnce: true,
            playSound: false,
            enableVibration: false,
          ),
        ),
      );
    } catch (_) {}
  }

  Future<void> showDownloadDone({
    required int id,
    required String title,
  }) async {
    if (!effectiveDownload) return;
    await ensureInit();
    try {
      await _plugin.cancel(id);
      await _plugin.show(
        id,
        title,
        'Готово',
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'download_done',
            'Загрузки завершены',
            channelDescription: 'Уведомление о завершении загрузки',
            importance: Importance.defaultImportance,
            priority: Priority.defaultPriority,
          ),
        ),
      );
    } catch (_) {}
  }

  Future<void> cancel(int id) async {
    try {
      await _plugin.cancel(id);
    } catch (_) {}
  }

  // === Сборка / GitHub Actions ===

  /// ID уведомлений билдов вычисляется детерминированно из id рана —
  /// чтобы при апдейте статуса (queued → in_progress → completed) баннер
  /// заменялся, а не плодил дубликаты.
  int _buildNotifId(int runId, {String suffix = ''}) {
    return ('build:$runId:$suffix').hashCode & 0x7FFFFFFF;
  }

  /// Лёгкий ongoing-баннер: «сборка идёт».
  Future<void> showBuildRunning(GhRun run) async {
    if (!effectiveBuild) return;
    await ensureInit();
    final id = _buildNotifId(run.id, suffix: 'running');
    final title = run.name.isNotEmpty ? run.name : 'Сборка';
    final sub = _runSubtitle(run);
    try {
      await _plugin.show(
        id,
        '$title — идёт сборка',
        sub,
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'build_running',
            'Сборка идёт',
            channelDescription:
                'Уведомления о запущенных GitHub Actions сборках',
            importance: Importance.low,
            priority: Priority.low,
            showProgress: true,
            indeterminate: true,
            ongoing: true,
            onlyAlertOnce: true,
            playSound: false,
            enableVibration: false,
          ),
        ),
      );
    } catch (_) {}
  }

  /// Финальный баннер: success / failure / cancelled и т.д.
  Future<void> showBuildFinished(GhRun run) async {
    if (!effectiveBuild) return;
    await ensureInit();
    final runningId = _buildNotifId(run.id, suffix: 'running');
    // Сначала гасим ongoing-баннер «идёт сборка», чтобы не оставалось двух.
    try {
      await _plugin.cancel(runningId);
    } catch (_) {}
    final doneId = _buildNotifId(run.id, suffix: 'done');
    final isSuccess = run.conclusion == 'success';
    final label = _conclusionLabel(run.conclusion);
    final title = run.name.isNotEmpty ? run.name : 'Сборка';
    final sub = _runSubtitle(run);
    try {
      await _plugin.show(
        doneId,
        '$title — $label',
        sub,
        NotificationDetails(
          android: AndroidNotificationDetails(
            isSuccess ? 'build_success' : 'build_failed',
            isSuccess ? 'Сборка успешна' : 'Сборка завершена',
            channelDescription:
                'Уведомления о завершении GitHub Actions сборок',
            importance: Importance.defaultImportance,
            priority: Priority.defaultPriority,
          ),
        ),
      );
    } catch (_) {}
  }

  String _conclusionLabel(String c) {
    switch (c) {
      case 'success':
        return 'успех';
      case 'failure':
        return 'провал';
      case 'cancelled':
        return 'отменена';
      case 'timed_out':
        return 'таймаут';
      case 'skipped':
        return 'пропущена';
      case 'neutral':
        return 'без вердикта';
      case 'action_required':
        return 'нужно действие';
      case 'stale':
        return 'устарела';
      default:
        return c.isEmpty ? 'завершена' : c;
    }
  }

  String _runSubtitle(GhRun run) {
    final parts = <String>[];
    if (run.headBranch.isNotEmpty) parts.add(run.headBranch);
    if (run.workflowName.isNotEmpty && run.workflowName != run.name) {
      parts.add(run.workflowName);
    }
    return parts.join(' · ');
  }
}
