import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api.dart';
import '../iconify.dart';
import '../navigation.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'repo_tree.dart';
import 'upload.dart';

class RepoDetailScreen extends StatefulWidget {
  final GhRepo repo;
  const RepoDetailScreen({super.key, required this.repo});
  @override
  State<RepoDetailScreen> createState() => _RepoDetailScreenState();
}

class _RepoDetailScreenState extends State<RepoDetailScreen> {
  bool _deleting = false;
  // Текст последней ошибки удаления. Показываем красной плашкой в «Опасной
  // зоне», чтобы пользователь видел *почему* ничего не произошло, а не
  // тыкал в кнопку повторно (раньше exception тихо проглатывался — баг
  // n5559: «жмёшь удалить, подтверждаешь и ничего не происходит»).
  String? _deleteError;

  Future<void> _delete() async {
    final pal = context.pal;
    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => Container(
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 28),
        decoration: BoxDecoration(
          color: pal.bg,
          borderRadius: const BorderRadius.vertical(
              top: Radius.circular(28)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 38,
              height: 4,
              decoration: BoxDecoration(
                color: pal.cont2,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 18),
            Text('Удалить ${widget.repo.name}?',
                style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: pal.text)),
            const SizedBox(height: 8),
            Text('Действие необратимо.',
                style: TextStyle(fontSize: 14, color: pal.sub)),
            const SizedBox(height: 18),
            PushButton(
              label: 'Удалить навсегда',
              icon: 'solar:trash-bin-2-bold',
              color: AppColors.red,
              onTap: () => Navigator.of(context).pop(true),
            ),
            const SizedBox(height: 8),
            GhostButton(
              label: 'Отменить',
              onTap: () => Navigator.of(context).pop(false),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true) return;
    final api = AppState.I.api;
    if (api == null) return;
    setState(() {
      _deleting = true;
      _deleteError = null;
    });
    try {
      await api.deleteRepo(widget.repo.fullName);
      AppState.I.repos.removeWhere((r) => r.fullName == widget.repo.fullName);
      if (AppState.I.activeRepo?.fullName == widget.repo.fullName) {
        await AppState.I.setActiveRepo(null);
      }
      AppState.I.touch();
      if (mounted) {
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (!mounted) return;
      // Чистим префикс «Exception: » если он есть.
      var msg = e.toString();
      if (msg.startsWith('Exception: ')) msg = msg.substring(11);
      setState(() => _deleteError = msg);
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    final r = widget.repo;
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
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [AppColors.accent, AppColors.accent2],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 42,
                          height: 42,
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.18),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          alignment: Alignment.center,
                          child: Iconify(
                            r.private
                                ? 'solar:lock-keyhole-bold'
                                : 'solar:folder-bold',
                            size: 22,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(r.name,
                                  style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 20,
                                      fontWeight: FontWeight.w700)),
                              Text(r.fullName,
                                  style: TextStyle(
                                      color: Colors.white.withValues(alpha: 0.8),
                                      fontSize: 12)),
                            ],
                          ),
                        ),
                      ],
                    ),
                    if (r.description.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Text(r.description,
                          style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.92),
                              fontSize: 13,
                              height: 1.4)),
                    ],
                    const SizedBox(height: 14),
                    Row(children: [
                      _LightStat(icon: 'solar:star-bold', value: '${r.stars}'),
                      const SizedBox(width: 12),
                      _LightStat(
                          icon: 'solar:code-square-bold',
                          value: r.defaultBranch),
                      const SizedBox(width: 12),
                      _LightStat(
                          icon: 'solar:bug-bold',
                          value: '${r.issues}'),
                    ]),
                  ],
                ),
              ),
              const SecTitle('Действия'),
              TileGroup(children: [
                Tile(
                  iconBg: AppColors.purple,
                  icon: 'solar:upload-bold',
                  title: 'Залить файлы',
                  sub: 'ZIP → ${r.defaultBranch}',
                  onTap: () async {
                    await AppState.I.setActiveRepo(r);
                    if (!context.mounted) return;
                    pushSlide(context, const UploadScreen());
                  },
                ),
                Tile(
                  iconBg: AppColors.blue,
                  icon: 'solar:folder-open-bold',
                  title: 'Файловая структура',
                  sub: 'Дерево репозитория',
                  onTap: () => pushSlide(
                      context, RepoTreeScreen(repo: r)),
                ),
                Tile(
                  iconBg: AppColors.green,
                  icon: 'solar:link-bold',
                  title: 'Открыть на GitHub',
                  sub: r.htmlUrl,
                  onTap: () =>
                      launchUrl(Uri.parse(r.htmlUrl)),
                ),
                Tile(
                  iconBg: AppColors.dark,
                  icon: 'solar:copy-bold',
                  title: 'Скопировать ссылку',
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: r.htmlUrl));
                  },
                ),
              ]),
              const SecTitle('Опасная зона'),
              TileGroup(children: [
                Tile(
                  iconBg: AppColors.red,
                  icon: 'solar:trash-bin-2-bold',
                  title: _deleting ? 'Удаляем…' : 'Удалить репозиторий',
                  sub: 'Действие необратимо',
                  titleColor: AppColors.red,
                  onTap: _deleting ? null : _delete,
                ),
              ]),
              if (_deleteError != null)
                Container(
                  margin: const EdgeInsets.only(top: 0, bottom: 18),
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                  decoration: BoxDecoration(
                    color: AppColors.red.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: AppColors.red.withValues(alpha: 0.45),
                      width: 1,
                    ),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(top: 1),
                        child: Iconify(
                          'solar:info-circle-bold',
                          size: 18,
                          color: AppColors.red,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          _deleteError!,
                          style: TextStyle(
                            color: pal.text,
                            fontSize: 13,
                            height: 1.4,
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
            child: TopFadeHeader(title: 'Репозиторий'),
          ),
        ],
      ),
    );
  }
}

class _LightStat extends StatelessWidget {
  final String icon;
  final String value;
  const _LightStat({required this.icon, required this.value});
  @override
  Widget build(BuildContext context) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Iconify(icon, size: 14, color: Colors.white.withValues(alpha: 0.86)),
      const SizedBox(width: 4),
      Text(value,
          style: TextStyle(
              color: Colors.white.withValues(alpha: 0.92),
              fontSize: 12,
              fontWeight: FontWeight.w600)),
    ]);
  }
}
