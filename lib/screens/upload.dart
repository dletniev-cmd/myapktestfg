import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../iconify.dart';
import '../navigation.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'commit.dart';
import 'files.dart';
import 'repo_tree.dart';
import 'repos.dart';

class UploadScreen extends StatefulWidget {
  const UploadScreen({super.key});
  @override
  State<UploadScreen> createState() => _UploadScreenState();
}

class _UploadScreenState extends State<UploadScreen> {
  bool _picking = false;
  String _zipName = '';
  // Сообщение об ошибке при распаковке/выборе ZIP. Покажем плашкой
  // под кнопкой выбора — раньше всё глоталось try/catch'ем и
  // пользователь не понимал, почему «ничего не происходит».
  String? _pickError;

  @override
  void initState() {
    super.initState();
    AppState.I.addListener(_onState);
    _zipName = AppState.I.stagedZipName;
  }

  @override
  void dispose() {
    AppState.I.removeListener(_onState);
    super.dispose();
  }

  void _onState() => setState(() {});

  Future<void> _pickZip() async {
    if (_picking) return;
    setState(() {
      _picking = true;
      _pickError = null;
    });
    try {
      final res = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['zip'],
        withData: true,
      );
      if (res == null || res.files.isEmpty) {
        setState(() => _picking = false);
        return;
      }
      final f = res.files.first;
      final bytes = f.bytes;
      if (bytes == null) {
        setState(() {
          _picking = false;
          _pickError =
              'Не удалось прочитать файл. Попробуйте другой ZIP или путь.';
        });
        return;
      }
      final archive = ZipDecoder().decodeBytes(bytes);
      final files = <String, Uint8List>{};
      for (final entry in archive) {
        if (!entry.isFile) continue;
        var name = entry.name;
        // strip top folder if archive has a single root dir
        files[name] = Uint8List.fromList(entry.content as List<int>);
      }
      if (files.isEmpty) {
        setState(() {
          _picking = false;
          _pickError = 'В архиве нет файлов.';
        });
        return;
      }
      // strip common single root prefix if any
      _stripCommonRoot(files);
      AppState.I.stagedFiles = files;
      AppState.I.stagedZipName = f.name;
      AppState.I.touch();
      setState(() {
        _zipName = f.name;
        _picking = false;
      });
    } catch (e) {
      // Самые частые ошибки тут — это битый/недозагруженный ZIP
      // («Could not find End of Central Directory Record»). Покажем
      // короткое человечное описание; полный текст всё-равно прячется
      // в стек-трейсе.
      setState(() {
        _picking = false;
        _pickError = 'Не удалось разобрать ZIP. Проверьте, что архив целый.';
      });
    }
  }

  void _stripCommonRoot(Map<String, Uint8List> files) {
    if (files.isEmpty) return;
    final roots = <String>{};
    for (final k in files.keys) {
      final i = k.indexOf('/');
      if (i <= 0) return;
      roots.add(k.substring(0, i));
    }
    if (roots.length != 1) return;
    final root = '${roots.first}/';
    final updated = <String, Uint8List>{};
    for (final e in files.entries) {
      updated[e.key.substring(root.length)] = e.value;
    }
    files
      ..clear()
      ..addAll(updated);
  }

  String _formatBytes(int b) {
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
    return '${(b / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    final repo = AppState.I.activeRepo;
    final files = AppState.I.stagedFiles;
    final hasFiles = files.isNotEmpty;
    final totalSize = files.values.fold<int>(0, (s, b) => s + b.length);

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
              // repo pick
              PressScale(
                onTap: () => pushSlide(context, const ReposScreen(picker: true)),
                scale: 0.99,
                child: Container(
                  padding: const EdgeInsets.all(16),
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: pal.cont,
                    borderRadius: BorderRadius.circular(22),
                  ),
                  child: Row(
                    children: [
                      Iconify('solar:folder-with-files-bold',
                          size: 24, color: AppColors.accent),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Репозиторий',
                                style: TextStyle(
                                    fontSize: 12, color: pal.sub)),
                            const SizedBox(height: 2),
                            Text(
                              repo?.name ?? '— выберите —',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                                color: pal.text,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                      Iconify('solar:alt-arrow-down-linear',
                          size: 18, color: pal.sub),
                    ],
                  ),
                ),
              ),
              if (repo != null)
                _MapBtn(
                  onTap: () =>
                      pushSlide(context, RepoTreeScreen(repo: repo)),
                ),
              // drop zone / picker
              PressScale(
                onTap: _picking ? null : _pickZip,
                scale: 0.99,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 20, vertical: 36),
                  decoration: BoxDecoration(
                    color: pal.cont,
                    borderRadius: BorderRadius.circular(22),
                    border: Border.all(
                      color: hasFiles
                          ? AppColors.accent.withValues(alpha: 0.3)
                          : Colors.transparent,
                      width: 2,
                    ),
                  ),
                  child: Column(
                    children: [
                      if (_picking)
                        SizedBox(
                          width: 48,
                          height: 48,
                          child: CircularProgressIndicator(
                              strokeWidth: 3,
                              color: AppColors.accent,
                              strokeCap: StrokeCap.round),
                        )
                      else
                        Iconify(
                          hasFiles
                              ? 'solar:check-circle-bold'
                              : 'solar:cloud-upload-bold',
                          size: 48,
                          color: AppColors.accent,
                        ),
                      const SizedBox(height: 10),
                      Text(
                        hasFiles
                            ? 'Файлы готовы'
                            : 'Выберите ZIP-архив проекта',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: pal.text,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        hasFiles
                            ? _zipName
                            : 'или нажмите, чтобы выбрать',
                        style: TextStyle(fontSize: 13, color: pal.sub),
                      ),
                    ],
                  ),
                ),
              ),
              if (_pickError != null)
                Container(
                  margin: const EdgeInsets.only(top: 12),
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
                          _pickError!,
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
              const SizedBox(height: 12),
              if (hasFiles)
                PressScale(
                  onTap: () => pushSlide(context, const FilesScreen()),
                  scale: 0.99,
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                    decoration: BoxDecoration(
                      color: pal.cont,
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 42,
                          height: 42,
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: [
                                AppColors.accent,
                                AppColors.accent2
                              ],
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                            ),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          alignment: Alignment.center,
                          child: const Iconify('solar:document-text-bold',
                              size: 22, color: Colors.white),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              RichText(
                                text: TextSpan(
                                  style: TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w600,
                                    color: pal.text,
                                  ),
                                  children: [
                                    TextSpan(text: '${files.length} файлов '),
                                    TextSpan(
                                      text: '· ${_formatBytes(totalSize)}',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: pal.sub,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                _zipName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontSize: 12, color: pal.sub),
                              ),
                            ],
                          ),
                        ),
                        Iconify('solar:alt-arrow-right-linear',
                            size: 20, color: pal.sub),
                      ],
                    ),
                  ),
                ),
              const SizedBox(height: 16),
              PushButton(
                label: 'Далее',
                icon: 'solar:arrow-right-bold',
                onTap: (hasFiles && repo != null)
                    ? () => pushSlide(context, const CommitScreen())
                    : null,
                color: (hasFiles && repo != null)
                    ? AppColors.accent
                    : AppColors.accent.withValues(alpha: 0.5),
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
            child: TopFadeHeader(title: 'Залить файлы'),
          ),
        ],
      ),
    );
  }
}

class _MapBtn extends StatelessWidget {
  final VoidCallback onTap;
  const _MapBtn({required this.onTap});
  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: PressScale(
        onTap: onTap,
        scale: 0.99,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: pal.cont,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            children: [
              Iconify('solar:folder-open-bold',
                  size: 20, color: AppColors.accent),
              const SizedBox(width: 10),
              Text('Карта репозитория',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: pal.text,
                  )),
              const Spacer(),
              Iconify('solar:alt-arrow-right-linear',
                  size: 18, color: pal.sub),
            ],
          ),
        ),
      ),
    );
  }
}
