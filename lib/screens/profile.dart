import 'package:flutter/material.dart';

import '../iconify.dart';
import '../navigation.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'new_repo.dart';
import 'other.dart';
import 'repos.dart';
import 'upload.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});
  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  bool _themeAnimating = false;

  @override
  void initState() {
    super.initState();
    AppState.I.addListener(_onState);
  }

  @override
  void dispose() {
    AppState.I.removeListener(_onState);
    super.dispose();
  }

  void _onState() => setState(() {});

  Future<void> _toggleTheme() async {
    if (_themeAnimating) return;
    setState(() => _themeAnimating = true);
    AppState.I.isDark = !AppState.I.isDark;
    await AppState.I.saveTheme();
    AppState.I.touch();
    await Future.delayed(const Duration(milliseconds: 220));
    if (mounted) setState(() => _themeAnimating = false);
  }

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    final user = AppState.I.user;
    final repos = AppState.I.repos;

    // HTML показывает в звёздочках то же число публичных репо (см. оригинал).
    final stars = user?.publicRepos ?? 0;

    return Stack(
      children: [
        Positioned.fill(
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(
              18,
              MediaQuery.of(context).padding.top + 8,
              18,
              120,
            ),
            physics: const BouncingScrollPhysics(),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // header
                Padding(
                  padding: const EdgeInsets.only(bottom: 18, top: 4),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Профиль',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -.4,
                      ),
                    ),
                  ),
                  PressScale(
                    onTap: _toggleTheme,
                    scale: 0.88,
                    // Чистая иконка sun/moon без подложки и обводки —
                    // юзер просил «сама по себе». Хит-зона остаётся
                    // 36×36, чтобы тап был удобный.
                    child: SizedBox(
                      width: 36,
                      height: 36,
                      child: Center(
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 220),
                          transitionBuilder: (child, anim) => RotationTransition(
                            turns: Tween<double>(begin: 0.25, end: 0.0)
                                .animate(anim),
                            child: ScaleTransition(scale: anim, child: child),
                          ),
                          child: Iconify(
                            pal.isDark
                                ? 'solar:moon-stars-bold'
                                : 'solar:sun-2-bold',
                            key: ValueKey(pal.isDark),
                            size: 22,
                            color: AppColors.accent,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // author card
            AuthorCard(
              name: user?.name.isNotEmpty == true
                  ? user!.name
                  : (user?.login ?? '—'),
              sub: '@${user?.login ?? '—'}',
              avatar: (user?.login.isNotEmpty == true)
                  ? user!.login[0].toUpperCase()
                  : '?',
              avatarUrl: user?.avatarUrl,
              stats: [
                StatPill(
                  icon: 'solar:folder-with-files-bold',
                  value: '${user?.publicRepos ?? '—'}',
                  label: 'репо',
                ),
                StatPill(
                    icon: 'solar:star-bold', value: '$stars'),
                StatPill(
                  icon: 'solar:users-group-rounded-bold',
                  value: '${user?.followers ?? '—'}',
                ),
              ],
            ),

            const SecTitle('Действия',
                padding: EdgeInsets.only(left: 4, bottom: 10)),
            Row(
              children: [
                Expanded(
                  // Карточка «Залить файлы» сама подписана на
                  // AppState.I.activeUpload — пока заливка идёт, она
                  // показывает stage + проценты + узкий прогресс-бар
                  // снизу (баг n6178). После завершения плавно
                  // возвращается к обычному виду.
                  child: _UploadCard(
                    onTap: () => pushSlide(context, const UploadScreen()),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _BigCard(
                    icon: 'solar:add-square-bold',
                    bg: AppColors.green,
                    title: 'Новый репо',
                    sub: 'Создать с нуля',
                    onTap: () => pushSlide(context, const NewRepoScreen()),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 22),

            const SecTitle('Инструменты'),
            TileGroup(children: [
              Tile(
                iconBg: AppColors.orange,
                icon: 'solar:folder-bold',
                title: 'Мои репозитории',
                sub: '${repos.length} репозиториев',
                onTap: () => pushSlide(context, const ReposScreen()),
              ),
            ]),

            const SecTitle('Аккаунт', padding: EdgeInsets.only(left: 4, top: 4, bottom: 10)),
            TileGroup(children: [
              Tile(
                iconBg: AppColors.dark,
                icon: 'solar:menu-dots-bold',
                title: 'Другое',
                sub: 'Настройки и аккаунт',
                onTap: () => pushSlide(context, const OtherScreen()),
              ),
            ]),
              ],
            ),
          ),
        ),
        const Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: TopFadeOverlay(),
        ),
      ],
    );
  }
}

class _BigCard extends StatelessWidget {
  final String icon;
  final Color bg;
  final String title;
  final String sub;
  final VoidCallback? onTap;
  const _BigCard({
    required this.icon,
    required this.bg,
    required this.title,
    required this.sub,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    return PressScale(
      onTap: onTap,
      scale: 0.97,
      child: Container(
        height: 132,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: pal.cont,
          borderRadius: BorderRadius.circular(18),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              height: 40,
              child: Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: bg,
                  borderRadius: BorderRadius.circular(11),
                ),
                alignment: Alignment.center,
                child: Iconify(icon, size: 22, color: Colors.white),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              title,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                letterSpacing: -.2,
                color: pal.text,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 2),
            // Одна строка с эллипсисом — раньше maxLines: 2 позволял
            // подзаголовку «Заливка в <длинноеИмяРепо>» переноситься
            // на вторую строку, и эта вторая строка накладывалась на
            // прогресс-бар внизу карточки (баг n5442). Сжимаем до одной
            // строки — длинные названия аккуратно усекаются «...».
            Text(
              sub,
              style: TextStyle(
                fontSize: 12,
                color: pal.sub,
                height: 1.35,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}

/// Карточка «Залить файлы». Если есть активная заливка
/// ([AppState.activeUpload]), показывает stage + % + узкий progress-bar
/// внизу карточки. Иначе — обычный заголовок/подпись. Все смены
/// состояния обёрнуты в AnimatedSwitcher / AnimatedSize, чтобы переход
/// был плавным (баг n6178).
class _UploadCard extends StatefulWidget {
  final VoidCallback? onTap;
  const _UploadCard({this.onTap});
  @override
  State<_UploadCard> createState() => _UploadCardState();
}

class _UploadCardState extends State<_UploadCard> {
  @override
  void initState() {
    super.initState();
    AppState.I.activeUpload.addListener(_onTask);
  }

  @override
  void dispose() {
    AppState.I.activeUpload.removeListener(_onTask);
    super.dispose();
  }

  void _onTask() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    final task = AppState.I.activeUpload;
    final running = task.status == UploadStatus.running;
    final done = task.status == UploadStatus.done;
    final err = task.status == UploadStatus.error;
    final showProgress = running || done || err;

    final bg = err ? AppColors.red : AppColors.purple;
    final icon = err
        ? 'solar:close-circle-bold'
        : done
            ? 'solar:check-circle-bold'
            : 'solar:upload-bold';

    // На завершении ловим «no-op» (все файлы совпадали с репо) —
    // pushFiles в этом случае возвращает PushResult с uploadedCount==0.
    // Карточка показывает «Без изменений» и в title, и в sub, иначе
    // пользователь увидит «Готово!» и подумает, что что-то залилось.
    final noopDone =
        done && task.lastUploaded == 0 && task.lastUnchanged > 0;
    final title = running
        ? '${(task.progress * 100).round()}%'
        : done
            ? (noopDone ? 'Без изменений' : 'Готово!')
            : err
                ? 'Ошибка'
                : 'Залить файлы';
    // Стабильный ключ для AnimatedSwitcher: меняется ТОЛЬКО на смене
    // стадии (running → done → idle), а не на каждом изменении %.
    // Раньше ValueKey(title) переключался каждые 1% (47%→48%→…) и
    // AnimatedSwitcher запускал свой 220мс fade на каждый процент —
    // отсюда «странный сдвиг текста, который вечно дёргается». Теперь
    // во время заливки % обновляется простым setState текста, а
    // настоящая cross-fade анимация играется только когда меняется
    // стадия (например 99%→Готово!).
    final stage = running
        ? 'running'
        : done
            ? (noopDone ? 'done_noop' : 'done')
            : err
                ? 'error'
                : 'idle';

    // Сабтитл: ОДНА короткая строка без имени файла — иначе текст
    // прыгает каждые пол секунды, что неприятно. Сам процесс показывает
    // прогресс-бар, статус-кода в сабтитле достаточно.
    String doneSub() {
      if (noopDone) {
        return 'Файлы уже актуальны в ${_shortRepo(task.repoName)}';
      }
      if (task.lastUnchanged > 0) {
        final total = task.lastUploaded + task.lastUnchanged;
        return 'Залито ${task.lastUploaded} из $total в ${_shortRepo(task.repoName)}';
      }
      return 'Залито в ${_shortRepo(task.repoName)}';
    }
    final sub = running
        ? 'Заливка в ${_shortRepo(task.repoName)}'
        : done
            ? doneSub()
            : err
                ? (task.errorMessage ?? 'Заливка не удалась')
                : 'Push в существующий репо';

    return PressScale(
      onTap: widget.onTap,
      scale: 0.97,
      // Раньше тут был AnimatedContainer(duration: 280мс) для самой
      // карточки. При смене темы `pal.cont` менялся мгновенно, но
      // AnimatedContainer плавно интерполировал старый цвет в новый
      // 280мс — из-за этого карточка «отставала» от остального UI
      // (баг прямо просил юзер). Меняем внешнюю карточку на обычный
      // Container: цвет фона применяется в тот же кадр, что и у всех
      // соседей. Внутренний 40×40 квадрат остаётся AnimatedContainer,
      // т.к. там анимируется stage-цвет (purple → green → red) при
      // смене статуса заливки — это не связано с темой.
      child: Container(
        height: 132,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: pal.cont,
          borderRadius: BorderRadius.circular(18),
        ),
        child: Stack(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  height: 40,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 280),
                    curve: Curves.easeOut,
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: bg,
                      borderRadius: BorderRadius.circular(11),
                    ),
                    alignment: Alignment.center,
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 220),
                      transitionBuilder: (child, anim) => ScaleTransition(
                        scale: anim,
                        child: FadeTransition(opacity: anim, child: child),
                      ),
                      child: Iconify(
                        icon,
                        key: ValueKey(icon),
                        size: 22,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 220),
                  // По умолчанию AnimatedSwitcher центрирует детей в
                  // Stack'е (Alignment.center). Колонка карточки
                  // выровнена по `CrossAxisAlignment.stretch` слева,
                  // и из-за центровки текст «прыгал» влево-вправо при
                  // смене стадии. layoutBuilder с Alignment.centerLeft
                  // прижимает оба фрейма (старый/новый) к левому краю —
                  // текст плавно проявляется, не «сдвигается».
                  layoutBuilder: (currentChild, previousChildren) => Stack(
                    alignment: Alignment.centerLeft,
                    children: <Widget>[
                      ...previousChildren,
                      if (currentChild != null) currentChild,
                    ],
                  ),
                  child: Text(
                    title,
                    // Ключ — стадия, а не сам текст. При обновлении %
                    // во время заливки стадия остаётся 'running',
                    // AnimatedSwitcher НЕ запускает свою cross-fade —
                    // текст просто перерисовывается. Это убирает
                    // постоянный «дёрганый» сдвиг во время заливки.
                    key: ValueKey('title_$stage'),
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      letterSpacing: -.2,
                      color: pal.text,
                      // Tabular figures — все цифры одинаковой ширины.
                      // Иначе «47%»→«48%»→«49%» имеют чуть разную
                      // ширину (1, 7, 8, 9 — пропорциональные глифы),
                      // и при каждом обновлении % видно микро-сдвиг.
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(height: 2),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 220),
                  // Тот же фикс центровки, что и для title — иначе
                  // сабтитл при смене стадии «уезжает» к центру
                  // карточки, хотя должен быть слева.
                  layoutBuilder: (currentChild, previousChildren) => Stack(
                    alignment: Alignment.centerLeft,
                    children: <Widget>[
                      ...previousChildren,
                      if (currentChild != null) currentChild,
                    ],
                  ),
                  // Одна строка с эллипсисом. Раньше maxLines: 2
                  // позволял «Заливка в myapktestfg» переноситься на
                  // 2-ю строку, и эта строка накладывалась на полосу
                  // прогресса (баг n5442). Длинные имена репо теперь
                  // обрезаются «...» — выглядит аккуратно и не лезет на
                  // прогресс-бар.
                  child: Text(
                    sub,
                    // Ключ — стадия. Раньше ValueKey(sub) дёргал
                    // анимацию при любом изменении строки, включая
                    // случаи когда `_shortRepo` оставался тем же, но
                    // менялся прогресс. Теперь анимируется только при
                    // смене стадии.
                    key: ValueKey('sub_$stage'),
                    style: TextStyle(
                      fontSize: 12,
                      color: pal.sub,
                      height: 1.35,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            // Прогресс-бар внизу карточки. AnimatedOpacity плавно
            // появляется/исчезает по статусу задачи. Заполненная часть
            // нарисована вручную (FractionallySizedBox + Container),
            // чтобы у движущегося акцентного «штриха» были скруглены ОБА
            // края, а не только внешний прямоугольник контейнера, как у
            // дефолтного LinearProgressIndicator (юзер просил
            // скруглённые края у самой движущейся полосы).
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 280),
                opacity: showProgress ? 1.0 : 0.0,
                child: SizedBox(
                  height: 6,
                  child: TweenAnimationBuilder<double>(
                    duration: const Duration(milliseconds: 240),
                    curve: Curves.easeOut,
                    tween: Tween<double>(
                      begin: 0,
                      end: task.progress.clamp(0.0, 1.0),
                    ),
                    builder: (_, value, __) {
                      return Stack(
                        children: [
                          // Фон (трек)
                          Container(
                            decoration: BoxDecoration(
                              color: pal.cont2,
                              borderRadius: BorderRadius.circular(3),
                            ),
                          ),
                          // Заполненная акцентная часть — со скруглёнными
                          // краями с обеих сторон.
                          FractionallySizedBox(
                            widthFactor: value.clamp(0.0, 1.0),
                            heightFactor: 1,
                            child: Container(
                              decoration: BoxDecoration(
                                color: err
                                    ? AppColors.red
                                    : AppColors.accent,
                                borderRadius: BorderRadius.circular(3),
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _shortRepo(String full) {
    if (full.isEmpty) return '';
    final i = full.indexOf('/');
    return i == -1 ? full : full.substring(i + 1);
  }
}
