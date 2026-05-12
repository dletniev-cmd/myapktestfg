import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'notifications.dart';
import 'theme.dart';

/// Имя файла с сериализованными баг-репортами (см. `saveBugs`/`_loadBugs`).
const String _kBugsFileName = 'bugs.json';

/// Ключи для лёгкого кэша в SharedPreferences (профиль и список репо).
/// На старте приложения они подтягиваются мгновенно — пользователь видит
/// свою аватарку и список репозиториев ДО завершения сетевых запросов
/// (см. `AppState.load()` и shell._bootstrap).
const String kCachedUserKey = 'cached_user';
const String kCachedReposKey = 'cached_repos';

class BugStep {
  String text;
  BugStep(this.text);
  Map<String, dynamic> toJson() => {'t': text};
  factory BugStep.fromJson(Map<String, dynamic> j) =>
      BugStep((j['t'] ?? '').toString());
}

class BugItem {
  final String id;
  String type;
  String title;
  String description;
  List<BugStep> steps;
  List<String> labels;
  String kind;
  String priority;
  String status;
  int createdAtMs;
  List<Uint8List> shots;

  /// Pre-encoded base64 strings, parallel to [shots].
  /// Populated on load from JSON or when a shot is added via [preEncodeShot].
  final List<String?> base64Cache = [];

  BugItem({
    required this.id,
    this.type = 'bug',
    this.title = '',
    this.description = '',
    List<BugStep>? steps,
    List<String>? labels,
    this.kind = 'visual',
    this.priority = 'med',
    this.status = 'open',
    int? createdAtMs,
    List<Uint8List>? shots,
  })  : steps = steps ?? <BugStep>[],
        labels = labels ?? <String>[],
        createdAtMs = createdAtMs ?? DateTime.now().millisecondsSinceEpoch,
        shots = shots ?? <Uint8List>[];

  /// Encode shot at [index] in background isolate. Returns the encoded string.
  Future<String> preEncodeShot(int index) async {
    while (base64Cache.length <= index) base64Cache.add(null);
    final encoded = await compute(base64Encode, shots[index]);
    base64Cache[index] = encoded;
    return encoded;
  }

  /// Invalidate cache entry at [index] (e.g. after editing a shot).
  void invalidateCache(int index) {
    if (index < base64Cache.length) base64Cache[index] = null;
    _imageProviders.remove(index);
  }

  /// Stable [MemoryImage] instances keyed by shot index.
  /// Reusing the same provider lets Flutter's [ImageCache] recognize the image
  /// and avoid re-decoding on every build.
  final Map<int, MemoryImage> _imageProviders = {};
  MemoryImage imageProvider(int index) {
    return _imageProviders[index] ??= MemoryImage(shots[index]);
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type,
        'title': title,
        'description': description,
        'steps': steps.map((e) => e.toJson()).toList(),
        'labels': labels,
        'kind': kind,
        'priority': priority,
        'status': status,
        'createdAtMs': createdAtMs,
        'shots': shots.map(base64Encode).toList(),
      };

  /// Сырой снимок состояния (скриншоты остаются `Uint8List`) — отправляется
  /// в isolate через `compute()` для фонового кодирования и сериализации.
  /// Дешевле чем `toJson()`, потому что не делает base64Encode на UI-треде.
  Map<String, dynamic> toRaw() => {
        'id': id,
        'type': type,
        'title': title,
        'description': description,
        'steps': steps.map((e) => e.toJson()).toList(),
        'labels': labels,
        'kind': kind,
        'priority': priority,
        'status': status,
        'createdAtMs': createdAtMs,
        'shots': List<Uint8List>.from(shots),
      };

  factory BugItem.fromJson(Map<String, dynamic> j) {
    // Совместимость со старыми записями: feature/idea -> sugg, logic -> func,
    // closed -> done.
    String t = (j['type'] ?? 'bug').toString();
    if (t == 'feature' || t == 'idea') t = 'sugg';
    String k = (j['kind'] ?? 'visual').toString();
    if (k == 'logic') k = 'func';
    String s = (j['status'] ?? 'open').toString();
    if (s == 'closed') s = 'done';
    final rawShots = (j['shots'] ?? const []) as List;
    final item = BugItem(
      id: (j['id'] ?? '').toString(),
      type: t,
      title: (j['title'] ?? '').toString(),
      description: (j['description'] ?? '').toString(),
      steps: ((j['steps'] ?? const []) as List)
          .map((e) => BugStep.fromJson(e as Map<String, dynamic>))
          .toList(),
      labels: ((j['labels'] ?? const []) as List)
          .map((e) => e.toString())
          .toList(),
      kind: k,
      priority: (j['priority'] ?? 'med').toString(),
      status: s,
      createdAtMs:
          (j['createdAtMs'] ?? DateTime.now().millisecondsSinceEpoch) as int,
      shots: rawShots.map((e) => base64Decode(e.toString())).toList(),
    );
    // Populate cache from loaded base64 strings — no re-encoding needed.
    for (final e in rawShots) {
      item.base64Cache.add(e.toString());
    }
    return item;
  }
}

class DownloadTask extends ChangeNotifier {
  double progress = 0;
  bool busy = false;
  String name;
  DownloadTask(this.name);

  void update(double p) {
    progress = p;
    notifyListeners();
  }

  void start() {
    busy = true;
    progress = 0;
    notifyListeners();
  }

  void finish() {
    busy = false;
    progress = 0;
    notifyListeners();
  }
}

/// Активная фоновая push-задача. Создаётся при тапе «Запушить» в
/// `CommitScreen`, живёт в [AppState.activeUpload] и работает независимо
/// от того, на каком экране находится пользователь.
///
/// Подписчики:
/// - «Залить файлы» на профиле — рисует progress-бар + проценты на
///   action-карточке во время заливки и плавно его прячет, когда
///   задача завершилась.
/// - Аватарка в нижнем island-навбаре (`_NavAvatarBtn`) — рисует
///   круговой прогресс-ринг вокруг аватарки, чуть затемняя её, пока
///   задача в работе.
///
/// Состояние [UploadStatus.done]/[UploadStatus.error] держится 2-3
/// секунды после окончания заливки — это нужно для плавного fade-out
/// progress-ринга и сообщения «Готово!» (см. _autoCloseAfter).
enum UploadStatus { idle, running, done, error }

class UploadTask extends ChangeNotifier {
  /// Прогресс 0..1. Под него обёрнуты три события: ramp-up до 0.05 на
  /// получении ref ветки, основной диапазон 0.15-0.75 — загрузка
  /// blob'ов, и финальные шаги 0.78-1.0 — tree/commit/ref update.
  double progress = 0;
  String stage = '';
  UploadStatus status = UploadStatus.idle;
  String? errorMessage;
  String repoName = '';
  int filesCount = 0;

  Timer? _autoCloseTimer;

  void start({required String repoName, required int filesCount}) {
    _autoCloseTimer?.cancel();
    _autoCloseTimer = null;
    this.repoName = repoName;
    this.filesCount = filesCount;
    progress = 0;
    stage = 'Подготовка…';
    status = UploadStatus.running;
    errorMessage = null;
    notifyListeners();
  }

  void update(String stage, double progress) {
    this.stage = stage;
    this.progress = progress;
    notifyListeners();
  }

  /// Завершает задачу успешно. Через 2.5 сек статус сбросится в idle и
  /// progress-ринг исчезнет; до этого UI показывает «Готово!» зелёной
  /// галочкой / полным кольцом.
  ///
  /// Параметры [uploaded] и [unchanged] нужны чтобы карточка
  /// «Залить файлы» показала корректное сообщение в трёх случаях:
  ///   • что-то реально залилось → «Залито в <repo>» (как раньше);
  ///   • часть файлов совпала с тем, что уже в репо → «Залито N из M»;
  ///   • все файлы уже актуальны, коммит не создавался →
  ///     «Без изменений» (no-op пуш).
  void finishSuccess({int uploaded = 0, int unchanged = 0}) {
    progress = 1.0;
    if (uploaded == 0 && unchanged > 0) {
      stage = 'Без изменений';
    } else if (unchanged > 0) {
      stage = 'Залито $uploaded из ${uploaded + unchanged}';
    } else {
      stage = 'Готово!';
    }
    lastUploaded = uploaded;
    lastUnchanged = unchanged;
    status = UploadStatus.done;
    notifyListeners();
    _scheduleReset(const Duration(milliseconds: 2500));
  }

  /// Сколько файлов реально залилось в последний завершившийся пуш.
  /// Используется UI карточки заливки для подписи «Залито N из M».
  int lastUploaded = 0;
  int lastUnchanged = 0;

  void finishError(String message) {
    status = UploadStatus.error;
    errorMessage = message;
    notifyListeners();
    _scheduleReset(const Duration(seconds: 4));
  }

  void _scheduleReset(Duration delay) {
    _autoCloseTimer?.cancel();
    _autoCloseTimer = Timer(delay, () {
      status = UploadStatus.idle;
      progress = 0;
      stage = '';
      errorMessage = null;
      lastUploaded = 0;
      lastUnchanged = 0;
      notifyListeners();
    });
  }

  void cancelReset() {
    _autoCloseTimer?.cancel();
    _autoCloseTimer = null;
  }
}

/// Глобальный неизменяемый sentinel-фабричный класс состояния.
class AppState extends ChangeNotifier {
  AppState._();
  static final AppState I = AppState._();

  String? token;
  GhUser? user;
  List<GhRepo> repos = [];
  GhRepo? activeRepo;
  bool reposLoading = false;
  String? reposError;

  // upload state
  Map<String, Uint8List> stagedFiles = {};
  String stagedZipName = '';
  Set<String> existingPaths = {};

  // commit
  String commitMessage = '';

  // bugs
  List<BugItem> bugs = [];

  // cached workflow runs (survive tab switches)
  List<GhRun>? cachedRuns;
  String? cachedRunsRepo;

  // global download state (survives navigation between screens)
  final Map<int, DownloadTask> activeDownloads = {};

  /// Глобальная фоновая push-задача. Поскольку в один момент пользователь
  /// заливает только в один репозиторий (стейдж файлов общий), достаточно
  /// одного UploadTask на всё приложение.
  final UploadTask activeUpload = UploadTask();

  // Связь run.id -> artifact.id активной/недавней загрузки APK. Нужна, чтобы
  // карточка рана на экране Actions при пере-создании (например, после
  // навигации в детали и обратно) могла мгновенно подхватить уже идущую
  // загрузку из [activeDownloads], не дожидаясь повторного запроса
  // runArtifacts.
  final Map<int, int> runApkArtifactId = {};

  // theme
  bool isDark = true;
  int accentColorValue = AppColors.defaultAccent.value;

  /// Снимок статусов рaнов, сделанный последним фоновым опросом.
  /// Ключ — id рана, значение — `'$status|$conclusion'`. Используется
  /// [BuildRunsTracker] для детекта переходов состояний.
  final Map<int, String> _runStatusSnapshot = {};
  Timer? _buildPollTimer;
  bool _buildPollInFlight = false;
  bool _runStatusPrimed = false;

  GhApi? get api => token == null ? null : GhApi(token!);

  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    token = p.getString('gh_token');
    isDark = p.getBool('is_dark') ?? true;
    accentColorValue = p.getInt('accent_color') ?? AppColors.defaultAccent.value;
    AppColors.setAccent(Color(accentColorValue));
    await NotificationService.I.loadSettings();
    // Подтягиваем кэшированный профиль (аватарка/имя/счётчики) и список
    // репо. Это даёт мгновенный «тёплый» старт без ожидания GitHub API —
    // данные потом обновятся фоном из shell._bootstrap.
    final cu = p.getString(kCachedUserKey);
    if (cu != null && cu.isNotEmpty) {
      try {
        user = GhUser.fromJson(jsonDecode(cu) as Map<String, dynamic>);
      } catch (_) {}
    }
    final cr = p.getString(kCachedReposKey);
    if (cr != null && cr.isNotEmpty) {
      try {
        final list = jsonDecode(cr) as List;
        repos = list
            .map((e) => GhRepo.fromJson(e as Map<String, dynamic>))
            .toList();
      } catch (_) {}
    }
    final activeFull = p.getString('active_repo_full');
    if (activeFull != null && repos.isNotEmpty) {
      try {
        activeRepo = repos.firstWhere((r) => r.fullName == activeFull);
      } catch (_) {}
    }
    await _loadBugs(p);
    notifyListeners();
  }

  /// Сохраняет [user] в SharedPreferences — лёгкий JSON в несколько
  /// сотен байт. Вызывается из bootstrap после успешного `api.me()`.
  Future<void> saveUser() async {
    final u = user;
    if (u == null) return;
    final p = await SharedPreferences.getInstance();
    await p.setString(kCachedUserKey, jsonEncode(u.toJson()));
  }

  /// Сохраняет [repos] в SharedPreferences. На активных аккаунтах
  /// — это несколько килобайт; перебить ничего не должно.
  Future<void> saveRepos() async {
    final p = await SharedPreferences.getInstance();
    final list = repos.map((r) => r.toJson()).toList();
    await p.setString(kCachedReposKey, jsonEncode(list));
  }

  // ===================== Cache clearing =====================
  // Используется экраном «Память» (lib/screens/memory.dart). Каждый метод
  // занулят соответствующий кэш — в памяти и/или на диске — и
  // notifyListeners() даёт всем экранам перерисоваться. Token и
  // настройки темы НЕ трогаем — это не «кэш».

  Future<void> clearProfileCache() async {
    user = null;
    final p = await SharedPreferences.getInstance();
    await p.remove(kCachedUserKey);
    // Заодно сбрасываем Flutter ImageCache — аватарка хранится там.
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    notifyListeners();
  }

  Future<void> clearReposCache() async {
    repos = [];
    activeRepo = null;
    cachedRuns = null;
    cachedRunsRepo = null;
    final p = await SharedPreferences.getInstance();
    await p.remove(kCachedReposKey);
    await p.remove('active_repo_full');
    notifyListeners();
  }

  Future<void> clearRunsCache() async {
    cachedRuns = null;
    cachedRunsRepo = null;
    _runStatusSnapshot.clear();
    _runStatusPrimed = false;
    notifyListeners();
  }

  Future<void> clearBugsCache() async {
    bugs = [];
    try {
      final f = await _bugsFile();
      if (f != null && await f.exists()) await f.delete();
    } catch (_) {}
    final p = await SharedPreferences.getInstance();
    await p.remove('bugs');
    notifyListeners();
  }

  void clearStagedFiles() {
    stagedFiles = {};
    stagedZipName = '';
    existingPaths = {};
    commitMessage = '';
    notifyListeners();
  }

  /// Удаляет временные APK-архивы, скачанные через Actions → «Скачать APK».
  /// Возвращает суммарный размер удалённых файлов (в байтах).
  Future<int> clearDownloadedApks() async {
    int total = 0;
    try {
      final dir = await getTemporaryDirectory();
      if (await dir.exists()) {
        await for (final entity in dir.list()) {
          if (entity is! File) continue;
          final name = entity.path.split('/').last.toLowerCase();
          // Артефакты GitHub приходят как .zip; внутри обычно лежит APK.
          if (!name.endsWith('.zip') && !name.endsWith('.apk')) continue;
          try {
            total += await entity.length();
            await entity.delete();
          } catch (_) {}
        }
      }
    } catch (_) {}
    return total;
  }

  /// Размер временных APK/zip файлов. Используется экраном «Память».
  Future<int> downloadedApksSize() async {
    int total = 0;
    try {
      final dir = await getTemporaryDirectory();
      if (await dir.exists()) {
        await for (final entity in dir.list()) {
          if (entity is! File) continue;
          final name = entity.path.split('/').last.toLowerCase();
          if (!name.endsWith('.zip') && !name.endsWith('.apk')) continue;
          try {
            total += await entity.length();
          } catch (_) {}
        }
      }
    } catch (_) {}
    return total;
  }

  /// Размер файла bugs.json на диске — основная масса баг-репортов
  /// (включая base64-кодированные скриншоты).
  Future<int> bugsFileSize() async {
    try {
      final f = await _bugsFile();
      if (f != null && await f.exists()) return await f.length();
    } catch (_) {}
    return 0;
  }

  /// Загружает баг-репорты сначала из файла (`bugs.json` в
  /// `application support directory`), а если файла нет — из старого
  /// `SharedPreferences` ключа `'bugs'` (легаси).
  ///
  /// Старая схема хранила всё в SharedPreferences. На бaгах с десятком
  /// скринов JSON-строка достигала 50–100 MB, и `setString()` на
  /// MethodChannel блокировал UI на сотни миллисекунд. Файловое API
  /// (dart:io File) пишет напрямую без Binder IPC и в разы быстрее.
  Future<void> _loadBugs(SharedPreferences p) async {
    String? raw;
    try {
      final file = await _bugsFile();
      if (file != null && await file.exists()) {
        raw = await file.readAsString();
      }
    } catch (_) {
      // Игнорим — упадём на легаси-фоллбэк ниже.
    }
    raw ??= p.getString('bugs');
    if (raw == null || raw.isEmpty) return;
    try {
      final list = jsonDecode(raw) as List;
      bugs = list
          .map((e) => BugItem.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return;
    }
    // Если данные пришли из легаси SharedPreferences — мигрируем в файл
    // и чистим SP, чтобы следующий запуск был быстрым.
    final fromLegacy = p.getString('bugs') != null;
    if (fromLegacy) {
      try {
        await _writeBugsFile();
        await p.remove('bugs');
      } catch (_) {}
    }
  }

  Future<File?> _bugsFile() async {
    try {
      final dir = await getApplicationSupportDirectory();
      return File('${dir.path}/$_kBugsFileName');
    } catch (_) {
      return null;
    }
  }

  Future<void> saveToken(String t) async {
    token = t;
    final p = await SharedPreferences.getInstance();
    await p.setString('gh_token', t);
    notifyListeners();
  }

  /// Запрашивает у системы разрешение на чтение медиа-файлов (галереи).
  /// Делаем это лениво — только когда пользователь явно тапнул свитч
  /// «Доступ к галерее» на экране разрешений, а не сразу при заходе.
  ///
  /// Возвращает `true`, если разрешение выдано (или уже было). Если
  /// пользователь откажет — фотопикер при следующем открытии всё равно
  /// заново попросит, так что отказ здесь не блокирует приложение.
  Future<bool> requestGalleryPermission() async {
    try {
      final ps =
          await PhotoManager.requestPermissionExtend();
      return ps.hasAccess;
    } catch (_) {
      return false;
    }
  }

  Future<void> saveTheme() async {
    final p = await SharedPreferences.getInstance();
    await p.setBool('is_dark', isDark);
  }

  Future<void> setAccentColor(Color c) async {
    accentColorValue = c.value;
    AppColors.setAccent(c);
    notifyListeners();
    final p = await SharedPreferences.getInstance();
    await p.setInt('accent_color', c.value);
  }

  Future<void> setActiveRepo(GhRepo? r) async {
    activeRepo = r;
    final p = await SharedPreferences.getInstance();
    if (r == null) {
      await p.remove('active_repo_full');
    } else {
      await p.setString('active_repo_full', r.fullName);
    }
    notifyListeners();
  }

  Future<void> saveBugs() async {
    await _writeBugsFile();
  }

  /// Сериализует все баг-репорты в JSON и пишет в файл.
  ///
  /// Раньше использовалось `compute()` + `SharedPreferences.setString()`.
  /// Оба варианта на больших объёмах (15 скринов × 5 MB = 75 MB байтов)
  /// упирались в IPC-копирование:
  ///   • `compute()` копирует входной аргумент через SendPort на UI-треде,
  ///     блокируя его на сотни миллисекунд.
  ///   • `SharedPreferences.setString()` пишет через MethodChannel,
  ///     данные идут через Binder IPC — тоже блокировка.
  ///
  /// Текущая схема:
  ///   1. Кодируем base64 поштучно прямо на UI-треде, но между скринами
  ///      делаем `await Future.delayed(Duration.zero)` — это отдаёт
  ///      управление event-loop'у, Flutter успевает рисовать кадры,
  ///      ticker'ы (CircularProgressIndicator в кнопке «Создать»)
  ///      продолжают анимироваться без замираний.
  ///   2. Пишем файл через `dart:io File.writeAsString()` — асинхронный
  ///      I/O без Binder IPC, на порядки быстрее `SharedPreferences`.
  Future<void> _writeBugsFile() async {
    final file = await _bugsFile();
    if (file == null) {
      // Fallback: build string for SharedPreferences.
      final list = <Map<String, dynamic>>[];
      for (final bug in bugs) {
        final m = bug.toRaw();
        final shotsRaw = (m['shots'] as List).cast<Uint8List>();
        m['shots'] = [
          for (var si = 0; si < shotsRaw.length; si++)
            (si < bug.base64Cache.length && bug.base64Cache[si] != null)
                ? bug.base64Cache[si]!
                : base64Encode(shotsRaw[si]),
        ];
        list.add(m);
      }
      final p = await SharedPreferences.getInstance();
      await p.setString('bugs', jsonEncode(list));
      return;
    }
    // Stream-write: avoid building the entire JSON string in memory.
    final sink = file.openWrite();
    sink.write('[');
    for (var i = 0; i < bugs.length; i++) {
      if (i > 0) sink.write(',');
      final bug = bugs[i];
      // Serialize non-shot fields.
      final m = <String, dynamic>{
        'id': bug.id,
        'type': bug.type,
        'title': bug.title,
        'description': bug.description,
        'steps': bug.steps.map((e) => e.toJson()).toList(),
        'labels': bug.labels,
        'kind': bug.kind,
        'priority': bug.priority,
        'status': bug.status,
        'createdAtMs': bug.createdAtMs,
      };
      // Write JSON without shots, then inject shots array manually.
      final jsonStr = jsonEncode(m);
      // Insert shots array before the closing '}'.
      sink.write(jsonStr.substring(0, jsonStr.length - 1));
      sink.write(',"shots":[');
      for (var si = 0; si < bug.shots.length; si++) {
        if (si > 0) sink.write(',');
        final cached =
            si < bug.base64Cache.length ? bug.base64Cache[si] : null;
        sink.write('"');
        sink.write(cached ?? base64Encode(bug.shots[si]));
        sink.write('"');
        await Future<void>.delayed(Duration.zero);
      }
      sink.write(']}');
      await Future<void>.delayed(Duration.zero);
    }
    sink.write(']');
    await sink.flush();
    await sink.close();
  }

  Future<void> logout() async {
    token = null;
    user = null;
    activeRepo = null;
    repos = [];
    cachedRuns = null;
    cachedRunsRepo = null;
    stopBuildPoller();
    final p = await SharedPreferences.getInstance();
    await p.remove('gh_token');
    await p.remove('active_repo_full');
    // Чистим закэшированный профиль и список репо — иначе при следующем
    // логине другого пользователя на долю секунды видны чужие данные.
    await p.remove(kCachedUserKey);
    await p.remove(kCachedReposKey);
    notifyListeners();
  }

  void touch() => notifyListeners();

  // ===================== Build runs tracker =====================
  //
  // Фоновый поллер GitHub Actions runs текущего репозитория. Работает
  // независимо от того, открыта вкладка "Actions" или нет — поэтому
  // уведомление о завершении сборки приходит даже когда пользователь
  // на экране багов или профиля.
  //
  // Источник правды о runs — `cachedRuns`. Если экран Actions сам
  // обновил кэш — мы это увидим через [observeRuns] и тоже сравним
  // со снимком.

  /// Запускает периодический опрос GitHub Actions с интервалом [interval].
  /// Безопасно вызывать многократно — старый таймер будет погашен.
  void startBuildPoller(
      {Duration interval = const Duration(seconds: 15)}) {
    _buildPollTimer?.cancel();
    _buildPollTimer = Timer.periodic(interval, (_) => _pollBuildsOnce());
    // Первый тик — сразу, чтобы быстро запромптить снимок и не ждать 15 сек.
    _pollBuildsOnce();
  }

  void stopBuildPoller() {
    _buildPollTimer?.cancel();
    _buildPollTimer = null;
    _runStatusSnapshot.clear();
    _runStatusPrimed = false;
  }

  Future<void> _pollBuildsOnce() async {
    if (_buildPollInFlight) return;
    final a = api;
    final repo = activeRepo;
    if (a == null || repo == null) return;
    _buildPollInFlight = true;
    try {
      final runs = await a.workflowRuns(repo.fullName, perPage: 20);
      observeRuns(runs, repoFullName: repo.fullName);
      cachedRuns = runs;
      cachedRunsRepo = repo.fullName;
      notifyListeners();
    } catch (_) {
      // Сеть может моргать — не паникуем.
    } finally {
      _buildPollInFlight = false;
    }
  }

  /// Принимает свежий список ranов (например, из Actions-экрана) и
  /// сравнивает со снимком. Шлёт уведомления при переходах:
  ///   * новый ран в not-completed → "идёт сборка"
  ///   * был not-completed, стал completed → "успех/провал/..."
  void observeRuns(List<GhRun> runs, {required String repoFullName}) {
    // Если переключили репо — снимок старого нерелевантен.
    if (cachedRunsRepo != null && cachedRunsRepo != repoFullName) {
      _runStatusSnapshot.clear();
      _runStatusPrimed = false;
    }
    final notif = NotificationService.I;
    final newSnapshot = <int, String>{};
    for (final r in runs) {
      newSnapshot[r.id] = '${r.status}|${r.conclusion}';
    }
    // Первый вызов — только запоминаем снимок, ничего не уведомляем,
    // иначе при первом запуске покажем кучу старых уведомлений.
    if (!_runStatusPrimed) {
      _runStatusSnapshot
        ..clear()
        ..addAll(newSnapshot);
      _runStatusPrimed = true;
      return;
    }
    if (notif.effectiveBuild) {
      for (final r in runs) {
        final prev = _runStatusSnapshot[r.id];
        final isCompleted = r.status == 'completed';
        if (prev == null) {
          // Совсем новый ран. Если он ещё не завершён — показать
          // "идёт сборка". Завершённый сразу не уведомляем — он мог
          // быть давно (просто не входил в предыдущую страницу).
          if (!isCompleted) {
            // ignore: discarded_futures
            notif.showBuildRunning(r);
          }
        } else {
          final wasCompleted = prev.startsWith('completed|');
          if (!wasCompleted && isCompleted) {
            // ignore: discarded_futures
            notif.showBuildFinished(r);
          } else if (!wasCompleted && !isCompleted) {
            // Был in_progress/queued — апдейтим текст ongoing-баннера
            // (на случай смены workflow_name или branch). Дёшево и
            // не показывает звук (onlyAlertOnce).
            // ignore: discarded_futures
            notif.showBuildRunning(r);
          }
        }
      }
    }
    _runStatusSnapshot
      ..clear()
      ..addAll(newSnapshot);
  }
}
