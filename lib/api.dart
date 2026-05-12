import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

/// Считает git-blob SHA1 для байтов локально, в том же виде, как это
/// делает git/GitHub при сохранении файла как blob. Формула:
///   sha1("blob <length>\0" + bytes)
/// Используется в [GitHubApi.pushFiles] для сравнения с уже лежащим в
/// репо деревом — чтобы пушить только изменённые/новые файлы, а не
/// всё подряд (просьба пользователя).
String gitBlobSha1(Uint8List bytes) {
  final header = utf8.encode('blob ${bytes.length}\u0000');
  final full = Uint8List(header.length + bytes.length)
    ..setRange(0, header.length, header)
    ..setRange(header.length, header.length + bytes.length, bytes);
  return sha1.convert(full).toString();
}

class GhUser {
  final String login;
  final String name;
  final String avatarUrl;
  final int publicRepos;
  final int followers;
  GhUser({
    required this.login,
    required this.name,
    required this.avatarUrl,
    required this.publicRepos,
    required this.followers,
  });
  factory GhUser.fromJson(Map<String, dynamic> j) => GhUser(
        login: (j['login'] ?? '').toString(),
        name: (j['name'] ?? j['login'] ?? '').toString(),
        avatarUrl: (j['avatar_url'] ?? '').toString(),
        publicRepos: (j['public_repos'] ?? 0) as int,
        followers: (j['followers'] ?? 0) as int,
      );

  /// Сериализация для локального кэша (SharedPreferences). Имена ключей
  /// совпадают с GitHub API, чтобы fromJson работал и с кэшем, и с
  /// сырыми ответами.
  Map<String, dynamic> toJson() => {
        'login': login,
        'name': name,
        'avatar_url': avatarUrl,
        'public_repos': publicRepos,
        'followers': followers,
      };
}

class GhRepo {
  final int id;
  final String name;
  final String fullName;
  final String description;
  final bool private;
  final int stars;
  final int forks;
  final int issues;
  final String defaultBranch;
  final String language;
  final String htmlUrl;
  final String pushedAt;
  final List<String> topics;
  GhRepo({
    required this.id,
    required this.name,
    required this.fullName,
    required this.description,
    required this.private,
    required this.stars,
    required this.forks,
    required this.issues,
    required this.defaultBranch,
    required this.language,
    required this.htmlUrl,
    required this.pushedAt,
    required this.topics,
  });
  factory GhRepo.fromJson(Map<String, dynamic> j) => GhRepo(
        id: (j['id'] ?? 0) as int,
        name: (j['name'] ?? '').toString(),
        fullName: (j['full_name'] ?? '').toString(),
        description: (j['description'] ?? '').toString(),
        private: (j['private'] ?? false) as bool,
        stars: (j['stargazers_count'] ?? 0) as int,
        forks: (j['forks_count'] ?? 0) as int,
        issues: (j['open_issues_count'] ?? 0) as int,
        defaultBranch: (j['default_branch'] ?? 'main').toString(),
        language: (j['language'] ?? '').toString(),
        htmlUrl: (j['html_url'] ?? '').toString(),
        pushedAt: (j['pushed_at'] ?? '').toString(),
        topics: ((j['topics'] ?? const []) as List).map((e) => e.toString()).toList(),
      );

  /// Сериализация для локального кэша.
  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'full_name': fullName,
        'description': description,
        'private': private,
        'stargazers_count': stars,
        'forks_count': forks,
        'open_issues_count': issues,
        'default_branch': defaultBranch,
        'language': language,
        'html_url': htmlUrl,
        'pushed_at': pushedAt,
        'topics': topics,
      };
}

class GhRun {
  final int id;
  final String name;
  final String status;
  final String conclusion;
  final String headBranch;
  final String headCommit;
  final String createdAt;
  final String updatedAt;
  /// Когда реально стартовала ПОСЛЕДНЯЯ попытка рана. При
  /// реране (`re-run`) `created_at` НЕ обновляется, а вот это
  /// поле — обновляется. Именно это поле используется в UI для
  /// расчёта длительности «сколько идёт» / «сколько шла» — иначе
  /// после рерана показывалось «6965 минут» от первоначального старта
  /// (баг n6509). Пустая строка — поля нет в ответе (следует
  /// фоллбэчиться на createdAt).
  final String runStartedAt;
  final String htmlUrl;
  final String event;
  final String workflowName;
  const GhRun({
    required this.id,
    required this.name,
    required this.status,
    required this.conclusion,
    required this.headBranch,
    required this.headCommit,
    required this.createdAt,
    required this.updatedAt,
    required this.runStartedAt,
    required this.htmlUrl,
    required this.event,
    required this.workflowName,
  });
  factory GhRun.fromJson(Map<String, dynamic> j) => GhRun(
        id: (j['id'] ?? 0) as int,
        name: (j['display_title'] ?? j['name'] ?? '').toString(),
        status: (j['status'] ?? '').toString(),
        conclusion: (j['conclusion'] ?? '').toString(),
        headBranch: (j['head_branch'] ?? '').toString(),
        headCommit: ((j['head_commit'] ?? const {}) as Map)['message']?.toString() ?? '',
        createdAt: (j['created_at'] ?? '').toString(),
        updatedAt: (j['updated_at'] ?? '').toString(),
        runStartedAt: (j['run_started_at'] ?? '').toString(),
        htmlUrl: (j['html_url'] ?? '').toString(),
        event: (j['event'] ?? '').toString(),
        workflowName: (j['name'] ?? '').toString(),
      );

  /// Безопасное «начало» рана для расчёта длительности — берёт свежее
  /// время старта (с учётом реранов), или createdAt в качестве фоллбэка.
  String get effectiveStartedAt =>
      runStartedAt.isNotEmpty ? runStartedAt : createdAt;
}

class GhArtifact {
  final int id;
  final String name;
  final int sizeInBytes;
  final String archiveDownloadUrl;
  final bool expired;
  GhArtifact({
    required this.id,
    required this.name,
    required this.sizeInBytes,
    required this.archiveDownloadUrl,
    required this.expired,
  });
  factory GhArtifact.fromJson(Map<String, dynamic> j) => GhArtifact(
        id: (j['id'] ?? 0) as int,
        name: (j['name'] ?? '').toString(),
        sizeInBytes: (j['size_in_bytes'] ?? 0) as int,
        archiveDownloadUrl: (j['archive_download_url'] ?? '').toString(),
        expired: (j['expired'] ?? false) as bool,
      );
}

class GhTreeEntry {
  final String path;
  final String type;
  final int size;
  final String sha;
  GhTreeEntry({required this.path, required this.type, required this.size, required this.sha});
  factory GhTreeEntry.fromJson(Map<String, dynamic> j) => GhTreeEntry(
        path: (j['path'] ?? '').toString(),
        type: (j['type'] ?? '').toString(),
        size: (j['size'] ?? 0) as int,
        sha: (j['sha'] ?? '').toString(),
      );
}

class GhJob {
  final int id;
  final String name;
  final String status;
  final String conclusion;
  final String startedAt;
  final String completedAt;
  final List<GhStep> steps;
  GhJob({
    required this.id,
    required this.name,
    required this.status,
    required this.conclusion,
    required this.startedAt,
    required this.completedAt,
    this.steps = const [],
  });
  factory GhJob.fromJson(Map<String, dynamic> j) => GhJob(
        id: (j['id'] ?? 0) as int,
        name: (j['name'] ?? '').toString(),
        status: (j['status'] ?? '').toString(),
        conclusion: (j['conclusion'] ?? '').toString(),
        startedAt: (j['started_at'] ?? '').toString(),
        completedAt: (j['completed_at'] ?? '').toString(),
        steps: ((j['steps'] ?? const []) as List)
            .map((e) => GhStep.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

/// Один шаг внутри джоба (Set up Job, Checkout, сборка, и т.д.). Из этого
/// рисуется индикатор прогресса и «живая» лента шагов в run_detail (баг n3324).
class GhStep {
  final String name;
  final String status; // queued | in_progress | completed
  final String conclusion; // success | failure | skipped | cancelled
  final int number;
  final String startedAt;
  final String completedAt;
  GhStep({
    required this.name,
    required this.status,
    required this.conclusion,
    required this.number,
    required this.startedAt,
    required this.completedAt,
  });
  factory GhStep.fromJson(Map<String, dynamic> j) => GhStep(
        name: (j['name'] ?? '').toString(),
        status: (j['status'] ?? '').toString(),
        conclusion: (j['conclusion'] ?? '').toString(),
        number: (j['number'] ?? 0) as int,
        startedAt: (j['started_at'] ?? '').toString(),
        completedAt: (j['completed_at'] ?? '').toString(),
      );
}

class GhApi {
  final String token;
  GhApi(this.token);

  Map<String, String> get _headers => {
        'Authorization': 'Bearer $token',
        'Accept': 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
      };

  Uri _u(String path, [Map<String, String>? q]) =>
      Uri.https('api.github.com', path, q);

  Future<GhUser> me() async {
    final r = await http.get(_u('/user'), headers: _headers);
    if (r.statusCode != 200) throw Exception('Auth: ${r.statusCode}');
    return GhUser.fromJson(jsonDecode(r.body) as Map<String, dynamic>);
  }

  Future<List<GhRepo>> myRepos() async {
    final all = <GhRepo>[];
    for (var page = 1; page < 8; page++) {
      final r = await http.get(
          _u('/user/repos', {
            'per_page': '100',
            'page': '$page',
            'sort': 'pushed',
            'affiliation': 'owner',
          }),
          headers: _headers);
      if (r.statusCode != 200) break;
      final list = jsonDecode(r.body) as List;
      if (list.isEmpty) break;
      all.addAll(list.map((e) => GhRepo.fromJson(e as Map<String, dynamic>)));
      if (list.length < 100) break;
    }
    return all;
  }

  Future<GhRepo> getRepo(String fullName) async {
    final r = await http.get(_u('/repos/$fullName'), headers: _headers);
    if (r.statusCode != 200) throw Exception('Repo: ${r.statusCode}');
    return GhRepo.fromJson(jsonDecode(r.body) as Map<String, dynamic>);
  }

  Future<GhRepo> createRepo({
    required String name,
    String description = '',
    bool private = false,
    bool autoInit = true,
    String gitignore = 'Dart',
    String? license,
  }) async {
    final body = <String, dynamic>{
      'name': name,
      'description': description,
      'private': private,
      'auto_init': autoInit,
      if (gitignore.isNotEmpty) 'gitignore_template': gitignore,
      if (license != null) 'license_template': license,
    };
    final r = await http.post(
      _u('/user/repos'),
      headers: {..._headers, 'Content-Type': 'application/json'},
      body: jsonEncode(body),
    );
    if (r.statusCode != 201) {
      // GitHub возвращает 422 для пары специфических случаев — имя занято,
      // некорректное имя, превышены лимиты. Достаём `message`/`errors[0]`
      // из ответа, чтобы показать пользователю человечный текст вместо
      // голого «Create: 422». Если парсинг не удался — fallback на код.
      String human;
      try {
        final j = jsonDecode(r.body) as Map<String, dynamic>;
        final errs = j['errors'];
        if (errs is List && errs.isNotEmpty) {
          final e0 = errs.first as Map<String, dynamic>;
          final msg = e0['message'] ?? e0['code'];
          human = msg?.toString() ?? (j['message']?.toString() ?? '');
        } else {
          human = (j['message'] ?? '').toString();
        }
      } catch (_) {
        human = '';
      }
      if (r.statusCode == 422 && human.isNotEmpty) {
        // «name already exists on this account» → «Имя занято». Чистим
        // самые частые сообщения GitHub.
        if (human.toLowerCase().contains('already exists')) {
          throw Exception('Репозиторий с таким именем уже есть.');
        }
        throw Exception('Не удалось создать: $human');
      }
      if (r.statusCode == 401 || r.statusCode == 403) {
        throw Exception(
          'Нет прав на создание репо. Проверьте scope `repo` у токена.',
        );
      }
      throw Exception('Не удалось создать (HTTP ${r.statusCode}).');
    }
    return GhRepo.fromJson(jsonDecode(r.body) as Map<String, dynamic>);
  }

  Future<void> deleteRepo(String fullName) async {
    final r = await http.delete(_u('/repos/$fullName'), headers: _headers);
    if (r.statusCode == 204) return;
    // 403 «Must have admin rights to Repository.» возникает, когда у токена
    // нет scope `delete_repo`. У классических PAT это отдельный чекбокс,
    // у fine-grained — отдельное право «Administration: Read and write».
    // Если просто бросить «Delete: 403», пользователь не понимает, почему
    // и что чинить — поэтому форматируем человеческий текст.
    if (r.statusCode == 403) {
      throw Exception(
        'Нет прав на удаление. У токена должен быть scope delete_repo '
        '(classic PAT) или права Administration: read & write '
        '(fine-grained). Перевыпустите токен на github.com/settings/tokens '
        'с этими правами и зайдите заново.',
      );
    }
    if (r.statusCode == 404) {
      throw Exception('Репозиторий не найден или нет доступа (404).');
    }
    throw Exception('Не удалось удалить (HTTP ${r.statusCode}).');
  }

  Future<List<GhTreeEntry>> repoTree(String fullName, String branch) async {
    final ref = await http.get(
        _u('/repos/$fullName/git/refs/heads/$branch'),
        headers: _headers);
    if (ref.statusCode != 200) return [];
    final sha = ((jsonDecode(ref.body) as Map)['object'] as Map)['sha'] as String;
    final tree = await http.get(
        _u('/repos/$fullName/git/trees/$sha', {'recursive': '1'}),
        headers: _headers);
    if (tree.statusCode != 200) return [];
    final list = (jsonDecode(tree.body) as Map)['tree'] as List;
    return list.map((e) => GhTreeEntry.fromJson(e as Map<String, dynamic>)).toList();
  }

  /// Один ран по id (нужен в run_detail для авто-обновления статуса).
  /// Возвращает null если ран удалён или был 5xx — вызывающий код просто
  /// не перезапишет своих данных.
  Future<GhRun?> runByIdMaybe(String fullName, int runId) async {
    final r = await http.get(
      _u('/repos/$fullName/actions/runs/$runId'),
      headers: _headers,
    );
    if (r.statusCode != 200) return null;
    return GhRun.fromJson(jsonDecode(r.body) as Map<String, dynamic>);
  }

  Future<List<GhRun>> workflowRuns(String fullName, {int perPage = 30}) async {
    final r = await http.get(
        _u('/repos/$fullName/actions/runs', {'per_page': '$perPage'}),
        headers: _headers);
    if (r.statusCode != 200) return [];
    final list = ((jsonDecode(r.body) as Map)['workflow_runs'] as List? ?? const []);
    return list.map((e) => GhRun.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<void> cancelRun(String fullName, int runId) async {
    final r = await http.post(
        _u('/repos/$fullName/actions/runs/$runId/cancel'),
        headers: _headers);
    if (r.statusCode != 202 && r.statusCode != 200) {
      throw Exception('Cancel: ${r.statusCode}');
    }
  }

  Future<void> rerunRun(String fullName, int runId) async {
    final r = await http.post(
        _u('/repos/$fullName/actions/runs/$runId/rerun'),
        headers: _headers);
    if (r.statusCode != 201 && r.statusCode != 200) {
      throw Exception('Rerun: ${r.statusCode}');
    }
  }

  Future<List<GhJob>> runJobs(String fullName, int runId) async {
    final r = await http.get(_u('/repos/$fullName/actions/runs/$runId/jobs'), headers: _headers);
    if (r.statusCode != 200) return [];
    final list = ((jsonDecode(r.body) as Map)['jobs'] as List? ?? const []);
    return list.map((e) => GhJob.fromJson(e as Map<String, dynamic>)).toList();
  }

  /// Сырые логи одного джоба (баг n3324). Работает только после завершения
  /// джоба (GitHub не отдаёт стриминг-логи для running джобов в публичном API).
  /// Для running джобов ондпоинт возвращает 404 — это ожидаемо и обрабатывается.
  ///
  /// GitHub отвечает 302 redirect на временный S3-URL. package:http
  /// бы следовал редиректу автоматически, НО с теми же Authorization-хедерами
  /// — а S3 откажет «чужому» Bearer’у. Поэтому следуем вручную через
  /// http.Request с followRedirects=false.
  Future<String> jobLogs(String fullName, int jobId) async {
    final req = http.Request(
        'GET', _u('/repos/$fullName/actions/jobs/$jobId/logs'))
      ..followRedirects = false
      ..headers.addAll(_headers);
    final streamed = await req.send();
    if (streamed.statusCode == 302 || streamed.statusCode == 301) {
      final loc = streamed.headers['location'];
      if (loc == null) return '';
      final r2 = await http.get(Uri.parse(loc));
      if (r2.statusCode != 200) return '';
      return r2.body;
    }
    if (streamed.statusCode != 200) return '';
    return streamed.stream.bytesToString();
  }

  Future<List<GhArtifact>> runArtifacts(String fullName, int runId) async {
    final r = await http.get(_u('/repos/$fullName/actions/runs/$runId/artifacts'), headers: _headers);
    if (r.statusCode != 200) return [];
    final list = ((jsonDecode(r.body) as Map)['artifacts'] as List? ?? const []);
    return list.map((e) => GhArtifact.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<Uint8List> downloadUrl(String url) async {
    final r = await http.get(Uri.parse(url), headers: _headers);
    if (r.statusCode != 200) throw Exception('Download: ${r.statusCode}');
    return r.bodyBytes;
  }

  Future<Uint8List> downloadUrlWithProgress(
    String url, {
    void Function(double progress)? onProgress,
    int expectedBytes = 0,
  }) async {
    final client = http.Client();
    try {
      final req = http.Request('GET', Uri.parse(url));
      req.headers.addAll(_headers);
      req.followRedirects = true;
      req.maxRedirects = 10;
      final streamed = await client.send(req);
      if (streamed.statusCode != 200) {
        throw Exception('Download: ${streamed.statusCode}');
      }
      final total = (streamed.contentLength != null && streamed.contentLength! > 0)
          ? streamed.contentLength!
          : expectedBytes;
      final chunks = <List<int>>[];
      int received = 0;
      await for (final chunk in streamed.stream) {
        chunks.add(chunk);
        received += chunk.length;
        if (total > 0) {
          onProgress?.call((received / total).clamp(0.0, 1.0));
        }
      }
      final bytes = Uint8List(received);
      int offset = 0;
      for (final chunk in chunks) {
        bytes.setRange(offset, offset + chunk.length, chunk);
        offset += chunk.length;
      }
      return bytes;
    } finally {
      client.close();
    }
  }

  /// Push files: создаёт blobs, tree, commit и обновляет ref.
  ///
  /// ВАЖНО: пушит ТОЛЬКО изменённые или новые файлы, а не всё подряд.
  /// До отправки blob'ов сравниваем локально рассчитанный git-blob SHA1
  /// каждого файла со SHA в текущем дереве репозитория. Если содержимое
  /// совпадает один-в-один — файл пропускается. Это убирает кучу
  /// ненужных HTTP-запросов и «лишние» коммиты, в которых ничего не
  /// поменялось.
  ///
  /// Возвращает [PushResult] с количеством реально загруженных файлов
  /// и числом пропущенных (без изменений). Если все файлы совпадают с
  /// текущим состоянием репо, коммит не создаётся, ref не обновляется
  /// — это «no-op» пуш.
  Future<PushResult> pushFiles({
    required String fullName,
    required String branch,
    required Map<String, Uint8List> files,
    required String message,
    void Function(String stage, double progress)? onProgress,
  }) async {
    onProgress?.call('Получаем ref ветки', 0.04);
    final ref = await http.get(
        _u('/repos/$fullName/git/refs/heads/$branch'),
        headers: _headers);
    String parent;
    if (ref.statusCode == 200) {
      parent = ((jsonDecode(ref.body) as Map)['object'] as Map)['sha'] as String;
    } else {
      throw Exception('Branch ref: ${ref.statusCode}');
    }

    onProgress?.call('Читаем дерево', 0.08);
    final commit = await http.get(_u('/repos/$fullName/git/commits/$parent'), headers: _headers);
    final treeSha = ((jsonDecode(commit.body) as Map)['tree'] as Map)['sha'] as String;

    // Тянем дерево рекурсивно — нужно знать SHA каждого файла, чтобы
    // сравнить с локально рассчитанным и понять, что реально менялось.
    onProgress?.call('Сверяемся с репо', 0.12);
    final remoteShaByPath = <String, String>{};
    final treeResp = await http.get(
      _u('/repos/$fullName/git/trees/$treeSha?recursive=1'),
      headers: _headers,
    );
    if (treeResp.statusCode == 200) {
      final body = jsonDecode(treeResp.body) as Map;
      final tree = (body['tree'] as List?) ?? const [];
      for (final node in tree) {
        if (node is! Map) continue;
        if ((node['type'] ?? '') != 'blob') continue;
        final path = (node['path'] ?? '').toString();
        final sha = (node['sha'] ?? '').toString();
        if (path.isEmpty || sha.isEmpty) continue;
        remoteShaByPath[path] = sha;
      }
    }
    // Если API вернул truncated=true (репо огромное), просто
    // подгружаем то, что вернулось — на ненайденные файлы упадём на
    // полную загрузку blob'а, это безопасный fallback.

    // Фильтруем: оставляем только новые/изменённые файлы.
    final changed = <String, Uint8List>{};
    final unchanged = <String, String>{}; // path -> существующий sha
    for (final e in files.entries) {
      final localSha = gitBlobSha1(e.value);
      final remoteSha = remoteShaByPath[e.key];
      if (remoteSha != null && remoteSha == localSha) {
        unchanged[e.key] = remoteSha;
      } else {
        changed[e.key] = e.value;
      }
    }

    if (changed.isEmpty) {
      // Нечего пушить: содержимое всех файлов уже один-в-один в репо.
      // Возвращаем no-op результат, коммит не делаем, ref не двигаем.
      onProgress?.call('Все файлы уже актуальны', 1.0);
      return PushResult(
        uploadedCount: 0,
        unchangedCount: unchanged.length,
        commitSha: null,
      );
    }

    final blobs = <Map<String, dynamic>>[];
    var i = 0;
    for (final entry in changed.entries) {
      i++;
      onProgress?.call(
          'Загружаем ${entry.key}', 0.15 + 0.6 * (i / changed.length));
      final body = jsonEncode({
        'content': base64Encode(entry.value),
        'encoding': 'base64',
      });
      final br = await http.post(
        _u('/repos/$fullName/git/blobs'),
        headers: {..._headers, 'Content-Type': 'application/json'},
        body: body,
      );
      if (br.statusCode != 201) {
        throw Exception('Blob ${entry.key}: ${br.statusCode}');
      }
      final sha = (jsonDecode(br.body) as Map)['sha'] as String;
      blobs.add({
        'path': entry.key,
        'mode': '100644',
        'type': 'blob',
        'sha': sha,
      });
    }

    onProgress?.call('Создаём дерево', 0.78);
    final tr = await http.post(
      _u('/repos/$fullName/git/trees'),
      headers: {..._headers, 'Content-Type': 'application/json'},
      body: jsonEncode({'base_tree': treeSha, 'tree': blobs}),
    );
    if (tr.statusCode != 201) {
      throw Exception('Tree: ${tr.statusCode} ${tr.body}');
    }
    final newTree = (jsonDecode(tr.body) as Map)['sha'] as String;

    onProgress?.call('Создаём коммит', 0.86);
    final cr = await http.post(
      _u('/repos/$fullName/git/commits'),
      headers: {..._headers, 'Content-Type': 'application/json'},
      body: jsonEncode({
        'message': message,
        'tree': newTree,
        'parents': [parent],
      }),
    );
    if (cr.statusCode != 201) {
      throw Exception('Commit: ${cr.statusCode} ${cr.body}');
    }
    final newCommit = (jsonDecode(cr.body) as Map)['sha'] as String;

    onProgress?.call('Обновляем ветку', 0.95);
    final ur = await http.patch(
      _u('/repos/$fullName/git/refs/heads/$branch'),
      headers: {..._headers, 'Content-Type': 'application/json'},
      body: jsonEncode({'sha': newCommit, 'force': false}),
    );
    if (ur.statusCode != 200) {
      throw Exception('Update ref: ${ur.statusCode}');
    }
    onProgress?.call('Готово', 1.0);

    return PushResult(
      uploadedCount: changed.length,
      unchangedCount: unchanged.length,
      commitSha: newCommit,
    );
  }
}

/// Результат вызова [GitHubApi.pushFiles]. Используется UI чтобы
/// показать, реально ли что-то заехало в репо, или коммит был
/// пропущен потому что все файлы и так совпадали.
class PushResult {
  /// Сколько blob'ов было реально создано (== число изменённых/новых
  /// файлов в этом пуше).
  final int uploadedCount;

  /// Сколько файлов в пуше совпадало с тем, что уже лежит в репо
  /// (их blob не создавался, время и трафик не тратились).
  final int unchangedCount;

  /// SHA нового коммита, либо null если пуш оказался no-op
  /// (все файлы уже были актуальны).
  final String? commitSha;

  const PushResult({
    required this.uploadedCount,
    required this.unchangedCount,
    required this.commitSha,
  });

  bool get noOp => uploadedCount == 0 && commitSha == null;
}
