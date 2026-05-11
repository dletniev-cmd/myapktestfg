import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../state.dart';
import 'bug_constants.dart';

/// Top-level: собирает .zip из набора файлов. Запускается в isolate
/// через `compute()`, чтобы тяжёлая упаковка скриншотов в zip не
/// блокировала UI-тред на 1–4сек. Раньше `ZipEncoder().encode()`
/// крутился прямо на main isolate — пользователь жал «Скачать архив»
/// и видел заморозку анимаций кнопки и счётчика; теперь main isolate
/// продолжает рисовать кадры, а архив собирается параллельно.
Uint8List? _encodeArchiveBytes(List<Map<String, Object>> files) {
  final archive = Archive();
  for (final f in files) {
    final name = f['name'] as String;
    final raw = f['bytes'];
    final bytes =
        raw is Uint8List ? raw : Uint8List.fromList((raw as List).cast<int>());
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  }
  final out = ZipEncoder().encode(archive);
  return out == null ? null : Uint8List.fromList(out);
}

/// Нативный канал для сохранения в публичную папку Downloads (Android).
/// На iOS папки в обычном смысле нет — там фолбэком остаётся шаринг.
const MethodChannel _kDownloadsChannel =
    MethodChannel('github_pusher/downloads');

const Map<String, String> _kKindDir = {
  'visual': '01_visual',
  'func': '02_functional',
  'crash': '03_crash',
  'perf': '04_performance',
  'ux': '05_ux',
  'other': '99_other',
};

const Map<String, String> _kPriName = {
  'high': 'high',
  'med': 'medium',
  'low': 'low',
};

const Map<String, String> _kStatusName = {
  'open': 'open',
  'prog': 'in_progress',
  'done': 'done',
};

String _safeName(String s) {
  final cleaned = s
      .replaceAll(RegExp(r'[\\/:*?"<>|]+'), '_')
      .replaceAll(RegExp(r'\s+'), '_');
  if (cleaned.isEmpty) return 'untitled';
  return cleaned.length > 60 ? cleaned.substring(0, 60) : cleaned;
}

String _two(int n) => n.toString().padLeft(2, '0');

String _stamp(DateTime ts) {
  return '${ts.year}-${_two(ts.month)}-${_two(ts.day)}'
      '-${_two(ts.hour)}-${_two(ts.minute)}-${_two(ts.second)}';
}

/// Результат формирования архива. Вызывающий код использует это
/// для показа тоаста (с именем файла и кол-вом записей).
class ArchiveResult {
  final bool empty;
  final int count;
  final String? filename;
  const ArchiveResult({
    required this.empty,
    required this.count,
    required this.filename,
  });
}

/// Создаёт zip-архив всех АКТИВНЫХ багов (open + in-progress) в формате
/// 1-в-1 с HTML-эталоном:
/// `bugs/<kind_dir>/<priority>__<title>__<id>/{bug.json, bug.md, ...}`
/// и сохраняет в папку Downloads на Android. Закрытые баги НЕ включаются.
///
/// Раньше функция сама показывала ScaffoldMessenger.showSnackBar — был
/// баг: снэкбар резко «выпрыгивал» снизу и не был стилизован. Теперь
/// функция возвращает [ArchiveResult], а вызывающий (`bugs.dart`)
/// показывает результат через анимацию самой кнопки скачивания
/// (зеленеющее кольцо + кросс-фейд иконки на галочку).
Future<ArchiveResult> downloadBugsArchive(BuildContext context) async {
  // Исключаем «закрытые» (status == 'done') — в архив попадают только
  // активные баги. Раньше экспортировались все подряд — это был баг.
  final list =
      AppState.I.bugs.where((b) => b.status != 'done').toList();
  final repoFull = AppState.I.activeRepo?.fullName ?? 'repo';
  if (list.isEmpty) {
    return const ArchiveResult(empty: true, count: 0, filename: null);
  }

  final ts = DateTime.now();
  final tsIso = ts.toUtc().toIso8601String();

  // Список файлов, которые поедут в isolate для сборки .zip.
  // Каждая запись — {name, bytes}; bytes — Uint8List (sendable между
  // изолятами).
  final files = <Map<String, Object>>[];
  void addFile(String name, List<int> bytes) {
    files.add({
      'name': name,
      'bytes':
          bytes is Uint8List ? bytes : Uint8List.fromList(bytes),
    });
  }

  // index.json
  final index = {
    'generated_at': tsIso,
    'repo': repoFull,
    'total': list.length,
    'bugs': [
      for (final b in list)
        {
          'id': b.id,
          'type': b.type,
          'kind': b.kind,
          'priority': b.priority,
          'status': b.status,
          'title': b.title,
          'created': b.createdAtMs,
          'labels': b.labels,
          'shots_count': b.shots.length,
        }
    ],
  };
  final indexBytes =
      utf8.encode(const JsonEncoder.withIndent('  ').convert(index));
  addFile('index.json', indexBytes);

  // README.md
  final byKind = <String, List<BugItem>>{};
  for (final b in list) {
    byKind.putIfAbsent(b.kind, () => []).add(b);
  }
  final md = StringBuffer()
    ..writeln('# Архив багов — $repoFull')
    ..writeln('Сгенерировано: ${_humanDate(ts)}')
    ..writeln('Всего: ${list.length}')
    ..writeln();
  final kinds = byKind.keys.toList()..sort();
  for (final k in kinds) {
    final items = byKind[k]!;
    md.writeln('## $k (${items.length})');
    for (final b in items) {
      md.writeln(
          '- [${_kPriName[b.priority] ?? b.priority}] **${b.title.isEmpty ? '—' : b.title}** — `#${b.id}`');
    }
    md.writeln();
  }
  final readmeBytes = utf8.encode(md.toString());
  addFile('README.md', readmeBytes);

  // По одной папке на баг.
  for (final b in list) {
    final kindDir = _kKindDir[b.kind] ?? _kKindDir['other']!;
    final priName = _kPriName[b.priority] ?? 'medium';
    final folder =
        'bugs/$kindDir/${priName}__${_safeName(b.title)}__${b.id}';

    final bugJson = {
      'id': b.id,
      'type': b.type,
      'kind': b.kind,
      'priority': b.priority,
      'status': b.status,
      'title': b.title,
      'desc': b.description,
      'steps': b.steps.map((s) => s.text).toList(),
      'labels': b.labels,
      'repo': repoFull,
      'created': b.createdAtMs,
      'created_iso':
          DateTime.fromMillisecondsSinceEpoch(b.createdAtMs).toUtc().toIso8601String(),
    };
    final bugJsonBytes = utf8
        .encode(const JsonEncoder.withIndent('  ').convert(bugJson));
    addFile('$folder/bug.json', bugJsonBytes);

    final kindLabel = kKindMeta[b.kind]?.label ?? b.kind;
    final priLabel = kPriMeta[b.priority]?.label ?? b.priority;
    final statusLabel = kStatusMeta[b.status]?.label ?? b.status;

    final bm = StringBuffer()
      ..writeln('# ${b.title.isEmpty ? '(без названия)' : b.title}')
      ..writeln()
      ..writeln('**ID:** `${b.id}`  ')
      ..writeln('**Тип:** ${b.type == 'bug' ? 'Баг' : 'Идея'}  ')
      ..writeln('**Категория:** ${b.kind} ($kindLabel)  ')
      ..writeln('**Приоритет:** ${_kPriName[b.priority] ?? 'medium'} ($priLabel)  ')
      ..writeln('**Статус:** ${_kStatusName[b.status] ?? 'open'} ($statusLabel)  ')
      ..writeln('**Создан:** ${_humanDate(DateTime.fromMillisecondsSinceEpoch(b.createdAtMs))}  ');
    if (b.labels.isNotEmpty) {
      bm.writeln('**Метки:** ${b.labels.join(', ')}  ');
    }
    bm.writeln();
    bm.writeln('## Описание');
    bm.writeln(b.description.isEmpty ? '—' : b.description);
    if (b.steps.isNotEmpty) {
      bm.writeln();
      bm.writeln('## Шаги воспроизведения');
      for (var i = 0; i < b.steps.length; i++) {
        bm.writeln('${i + 1}. ${b.steps[i].text}');
      }
    }
    if (b.shots.isNotEmpty) {
      bm.writeln();
      bm.writeln('## Скриншоты');
      for (var i = 0; i < b.shots.length; i++) {
        bm.writeln('![shot ${i + 1}](screenshots/shot_${_two(i + 1)}.png)');
      }
    }
    final bmBytes = utf8.encode(bm.toString());
    addFile('$folder/bug.md', bmBytes);

    if (b.labels.isNotEmpty) {
      final lbBytes = utf8.encode(b.labels.join('\n'));
      addFile('$folder/labels.txt', lbBytes);
    }
    final descBytes = utf8.encode(b.description);
    addFile('$folder/description.txt', descBytes);

    for (var i = 0; i < b.shots.length; i++) {
      final shotBytes = b.shots[i];
      addFile('$folder/screenshots/shot_${_two(i + 1)}.png', shotBytes);
    }
  }

  // Тяжёлая упаковка — в фоновом изоляте через `compute()`. UI-тред
  // продолжает рисовать кадры (анимация ринга на кнопке скачивания).
  final zipBytes = await compute(_encodeArchiveBytes, files);
  if (zipBytes == null) {
    return ArchiveResult(empty: false, count: list.length, filename: null);
  }

  final dir = await getTemporaryDirectory();
  final fname =
      'bugs_${_safeName(repoFull.replaceAll('/', '-'))}_${_stamp(ts)}.zip';
  final f = File('${dir.path}/$fname');
  await f.writeAsBytes(zipBytes);

  // На Android — кладём в публичную папку Downloads через MediaStore
  // (без share-панели). На iOS и всё остальное — фолбэком шаринг. Toast
  // показывает вызывающий код (`bugs.dart`) по возвращённому [ArchiveResult].
  if (Platform.isAndroid) {
    try {
      await _kDownloadsChannel.invokeMethod<String>('saveToDownloads', {
        'filename': fname,
        'mime': 'application/zip',
        'srcPath': f.path,
      });
      return ArchiveResult(
        empty: false,
        count: list.length,
        filename: fname,
      );
    } on PlatformException catch (_) {
      // Если нативный канал недоступен (старая сборка без MainActivity
      // патча) — не фейлимся, падаем в старый флоу через share.
    } on MissingPluginException catch (_) {
      // Аналогично — фолбэк на share.
    }
  }

  await Share.shareXFiles([XFile(f.path)], text: fname);
  return ArchiveResult(
    empty: false,
    count: list.length,
    filename: fname,
  );
}

String _humanDate(DateTime ts) {
  final d = ts.toLocal();
  return '${_two(d.day)}.${_two(d.month)}.${d.year}, '
      '${_two(d.hour)}:${_two(d.minute)}:${_two(d.second)}';
}
