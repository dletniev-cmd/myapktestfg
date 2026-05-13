import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../api.dart';
import '../iconify.dart';
import '../notifications.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/common.dart';

class ActionsArchiveScreen extends StatefulWidget {
  const ActionsArchiveScreen({super.key});
  @override
  State<ActionsArchiveScreen> createState() => _ActionsArchiveScreenState();
}

class _ActionsArchiveScreenState extends State<ActionsArchiveScreen> {
  bool _loading = true;
  List<_ArtItem> _items = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final api = AppState.I.api!;
    final repo = AppState.I.activeRepo;
    if (repo == null) {
      setState(() => _loading = false);
      return;
    }
    try {
      final runs = await api.workflowRuns(repo.fullName, perPage: 30);
      final out = <_ArtItem>[];
      for (final run in runs) {
        if (run.conclusion != 'success') continue;
        final arts = await api.runArtifacts(repo.fullName, run.id);
        for (final a in arts) {
          if (a.expired) continue;
          out.add(_ArtItem(run: run, art: a));
        }
      }
      _items = out;
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  String _fmt(int b) {
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
    return '${(b / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    return Scaffold(
      backgroundColor: pal.bg,
      body: Stack(
        children: [
          Positioned.fill(
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                18,
                MediaQuery.of(context).padding.top + kTopHeaderBarHeight,
                18,
                0,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
              Expanded(
                child: _loading
                    ? Center(
                        child: CircularProgressIndicator(
                            color: AppColors.accent,
                            strokeCap: StrokeCap.round))
                    : _items.isEmpty
                        ? Center(
                            child: Text('Нет артефактов',
                                style: TextStyle(
                                    color: pal.sub, fontSize: 14)))
                        : ListView.separated(
                            physics: const BouncingScrollPhysics(),
                            padding: const EdgeInsets.only(bottom: 32),
                            itemCount: _items.length,
                            separatorBuilder: (_, __) =>
                                const SizedBox(height: 8),
                            itemBuilder: (_, i) {
                              final item = _items[i];
                              return PressScale(
                                onTap: () => downloadAndShareArtifact(
                                    context, item.art),
                                child: Container(
                                  padding: const EdgeInsets.all(14),
                                  decoration: BoxDecoration(
                                    color: pal.cont,
                                    borderRadius:
                                        BorderRadius.circular(16),
                                  ),
                                  child: Row(children: [
                                    Container(
                                      width: 40,
                                      height: 40,
                                      decoration: BoxDecoration(
                                        gradient: const LinearGradient(
                                          colors: [
                                            AppColors.purple,
                                            AppColors.pink
                                          ],
                                        ),
                                        borderRadius:
                                            BorderRadius.circular(12),
                                      ),
                                      alignment: Alignment.center,
                                      child: const Iconify(
                                          'solar:archive-bold',
                                          size: 22,
                                          color: Colors.white),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(item.art.name,
                                              style: TextStyle(
                                                fontSize: 14,
                                                fontWeight:
                                                    FontWeight.w600,
                                                color: pal.text,
                                              ),
                                              maxLines: 1,
                                              overflow:
                                                  TextOverflow.ellipsis),
                                          const SizedBox(height: 2),
                                          Text(
                                              '#${item.run.id} · ${_fmt(item.art.sizeInBytes)}',
                                              style: TextStyle(
                                                  fontSize: 12,
                                                  color: pal.sub)),
                                        ],
                                      ),
                                    ),
                                    Iconify('solar:download-bold',
                                        size: 22,
                                        color: AppColors.accent),
                                  ]),
                                ),
                              );
                            },
                          ),
              ),
                ],
              ),
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: TopFadeHeader(
              title: 'Архив',
              trailing: [
                IconBtn(
                  icon: 'solar:refresh-linear',
                  iconSize: 22,
                  size: 36,
                  onTap: _load,
                  color: _loading ? AppColors.accent : null,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ArtItem {
  final GhRun run;
  final GhArtifact art;
  _ArtItem({required this.run, required this.art});
}

Future<void> downloadAndShareArtifact(
  BuildContext context,
  GhArtifact a, {
  void Function(double progress)? onProgress,
}) async {
  final api = AppState.I.api!;
  final notifId = a.id.hashCode & 0x7FFFFFFF;

  await NotificationService.I.ensureInit();

  final task = AppState.I.activeDownloads.putIfAbsent(
    a.id,
    () => DownloadTask(a.name),
  );
  if (task.busy) return;
  task.start();

  int lastPct = -1;
  try {
    final bytes = await api.downloadUrlWithProgress(
      a.archiveDownloadUrl,
      onProgress: (p) {
        task.update(p);
        onProgress?.call(p);
        final pct = (p * 100).toInt();
        if (pct != lastPct && pct % 5 == 0) {
          lastPct = pct;
          // ignore: discarded_futures
          NotificationService.I.showDownloadProgress(
            id: notifId,
            title: 'Загрузка ${a.name}',
            percent: pct,
          );
        }
      },
      expectedBytes: a.sizeInBytes,
    );
    final dir = await getTemporaryDirectory();
    final f = File('${dir.path}/${a.name}.zip');
    await f.writeAsBytes(bytes);

    await NotificationService.I.showDownloadDone(
      id: notifId,
      title: '${a.name} загружен',
    );

    await Share.shareXFiles([XFile(f.path)], text: a.name);
  } catch (_) {
    await NotificationService.I.cancel(notifId);
  } finally {
    task.finish();
    AppState.I.activeDownloads.remove(a.id);
  }
}
