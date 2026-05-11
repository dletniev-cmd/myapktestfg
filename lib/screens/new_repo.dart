import 'package:flutter/material.dart';

import '../iconify.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'other.dart' show ThemedSwitch;

class NewRepoScreen extends StatefulWidget {
  const NewRepoScreen({super.key});
  @override
  State<NewRepoScreen> createState() => _NewRepoScreenState();
}

class _NewRepoScreenState extends State<NewRepoScreen> {
  final _name = TextEditingController();
  final _desc = TextEditingController();
  bool _private = false;
  bool _autoInit = true;
  bool _busy = false;
  // Сообщение последней ошибки `createRepo`. Раньше exception тихо
  // глотался — пользователь жмёт «создать», ничего не происходит, и
  // непонятно почему. Теперь показываем человекочитаемый текст под
  // кнопкой (тот же подход, что и для удаления — баг n5559).
  String? _createError;

  @override
  void dispose() {
    _name.dispose();
    _desc.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final api = AppState.I.api;
    if (api == null) return;
    final n = _name.text.trim();
    if (n.isEmpty) return;
    setState(() {
      _busy = true;
      _createError = null;
    });
    try {
      final repo = await api.createRepo(
        name: n,
        description: _desc.text.trim(),
        private: _private,
        autoInit: _autoInit,
        // .gitignore-шаблон больше не выбирается из UI — отдаём пустую строку,
        // и GitHub создаст репо без `gitignore_template`. Пользователь сам
        // зальёт нужный .gitignore при первом push'е.
        gitignore: '',
      );
      AppState.I.repos.insert(0, repo);
      await AppState.I.setActiveRepo(repo);
      AppState.I.touch();
      if (mounted) {
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (!mounted) return;
      var msg = e.toString();
      if (msg.startsWith('Exception: ')) msg = msg.substring(11);
      setState(() => _createError = msg);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    // То же лекарство от баг n7850: kb-инсет — в padding скролл-вью,
    // Scaffold не ресайзим.
    final viewInsetBottom = MediaQuery.of(context).viewInsets.bottom;
    return Scaffold(
      backgroundColor: pal.bg,
      resizeToAvoidBottomInset: false,
      body: Stack(
        children: [
          Positioned.fill(
            child: SingleChildScrollView(
              padding: EdgeInsets.only(
                top: MediaQuery.of(context).padding.top + kTopHeaderBarHeight,
                bottom: 32 + viewInsetBottom,
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const FormLabel('Название',
                        padding: EdgeInsets.only(bottom: 8, left: 4)),
                    FieldBox(controller: _name, hint: 'my-awesome-app'),
                    const FormLabel('Описание'),
                    FieldBox(
                      controller: _desc,
                      hint: 'Что это за проект',
                      minLines: 2,
                      maxLines: 4,
                    ),
                    const SizedBox(height: 18),
                    // Свитчи в едином сгруппированном контейнере с разделителем —
                    // тот же визуальный стиль, что и на экране "Уведомления"
                    // (TileGroup + Tile + ThemedSwitch). Никаких Material
                    // Switch.adaptive — целиком на нашем кастомном свитче,
                    // чтобы UI был однородным.
                    TileGroup(children: [
                      Tile(
                        iconBg: _private
                            ? AppColors.orange
                            : (pal.isDark
                                ? const Color(0xFF3A3A3F)
                                : const Color(0xFFB7B7BD)),
                        icon: 'solar:lock-keyhole-bold',
                        title: 'Приватный',
                        sub: 'Только владельцы видят репозиторий',
                        onTap: () => setState(() => _private = !_private),
                        trailing: ThemedSwitch(active: _private),
                      ),
                      Tile(
                        iconBg: _autoInit
                            ? AppColors.green
                            : (pal.isDark
                                ? const Color(0xFF3A3A3F)
                                : const Color(0xFFB7B7BD)),
                        icon: 'solar:document-add-bold',
                        title: 'Авто-инициализация',
                        sub: 'README + первый коммит',
                        onTap: () => setState(() => _autoInit = !_autoInit),
                        trailing: ThemedSwitch(active: _autoInit),
                      ),
                    ]),
                    if (_createError != null)
                      Container(
                        margin: const EdgeInsets.only(top: 18),
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
                                _createError!,
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
                    const SizedBox(height: 18),
                    PushButton(
                      label: _busy ? 'Создаём…' : 'Создать репозиторий',
                      icon: _busy ? null : 'solar:add-square-bold',
                      loading: _busy,
                      onTap: _busy ? null : _create,
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
            child: TopFadeHeader(title: 'Новый репо'),
          ),
        ],
      ),
    );
  }
}
