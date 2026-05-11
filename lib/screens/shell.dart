import 'dart:async';
import 'package:flutter/material.dart';

import '../iconify.dart';
import '../notifications.dart';
import '../state.dart';
import '../theme.dart';
import 'actions.dart';
import 'bugs.dart';
import 'profile.dart';

/// Корневой экран с нижней island-навигацией и табами.
class ShellScreen extends StatefulWidget {
  const ShellScreen({super.key});
  @override
  State<ShellScreen> createState() => _ShellScreenState();
}

class _ShellScreenState extends State<ShellScreen>
    with TickerProviderStateMixin {
  int _index = 2; // profile by default

  // IndexedStack-подход вместо AnimatedSwitcher: при смене таба мы НЕ
  // пере-создаём страницу заново — её State (включая позиции скролла,
  // незаписанные форм-поля, активные таймеры/листенеры) сохраняется.
  // Раньше AnimatedSwitcher по ключу KeyedSubtree(ValueKey(_index))
  // тупо выбрасывал предыдущую страницу из дерева, при возврате во
  // вкладку всё инициализировалось с нуля — поллер ранов, listener'ы
  // AppState, шапка со стики хедером и т.д. Это и был самый дорогой
  // лаг при смене таба, особенно когда возвращаешься на Profile/Bugs.
  late final List<Widget> _pages = const [
    ActionsScreen(),
    BugsScreen(),
    ProfileScreen(),
  ];

  // Отслеживаем, какие вкладки уже посетили — лениво монтируем
  // страницу при первом обращении (Actions/Bugs/Profile не нужны
  // пока пользователь сидит в одной вкладке).
  final Set<int> _visited = <int>{2};

  late final AnimationController _navAppear = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 280),
  );

  bool _navStarted = false;

  @override
  void initState() {
    super.initState();
    AppState.I.addListener(_onState);
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    final api = AppState.I.api;
    if (api == null) return;
    // Инициализируем локальные уведомления и запускаем фоновый поллер
    // GitHub Actions ранов — чтобы уведомления о событиях сборки
    // (queued / in_progress / success / failure) приходили вне зависимости
    // от того, на какой вкладке сейчас пользователь.
    // ignore: discarded_futures
    NotificationService.I.ensureInit();
    AppState.I.startBuildPoller();
    try {
      // Даже если в [user] уже лежит закэшированный профиль из
      // SharedPreferences (см. AppState.load), всё равно идём в API,
      // чтобы подтянуть актуальные счётчики/имя. Аватарка точно
      // прекэшируется, чтобы первый показ был без мигания.
      final hadCachedUser = AppState.I.user != null;
      final u = await api.me();
      AppState.I.user = u;
      if (mounted && u.avatarUrl.isNotEmpty) {
        try {
          await precacheImage(NetworkImage(u.avatarUrl), context);
        } catch (_) {}
      }
      // ignore: discarded_futures
      AppState.I.saveUser();
      if (!hadCachedUser) AppState.I.touch();
    } catch (_) {}
    try {
      // Если есть закэшированные репо — сразу показываем их (load() их
      // уже положил в state), а сетевой запрос идёт в фоне.
      final hadCachedRepos = AppState.I.repos.isNotEmpty;
      if (!hadCachedRepos) {
        AppState.I.reposLoading = true;
        AppState.I.touch();
      }
      AppState.I.repos = await api.myRepos();
      AppState.I.reposLoading = false;
      AppState.I.reposError = null;
      AppState.I.activeRepo ??=
          AppState.I.repos.isNotEmpty ? AppState.I.repos.first : null;
      // ignore: discarded_futures
      AppState.I.saveRepos();
      AppState.I.touch();
    } catch (e) {
      AppState.I.reposLoading = false;
      AppState.I.reposError = e.toString();
      AppState.I.touch();
    }
  }

  @override
  void dispose() {
    _navAppear.dispose();
    AppState.I.removeListener(_onState);
    super.dispose();
  }

  // Дёшево: shell перерисовывается только когда меняется аватарка
  // в островке (user) или индекс. Никаких else-зависимостей у нас
  // в build() от AppState нет.
  String? _lastAvatarUrl;
  String _lastLogin = '';
  void _onState() {
    final u = AppState.I.user;
    final newUrl = u?.avatarUrl;
    final newLogin = u?.login ?? '';
    if (newUrl != _lastAvatarUrl || newLogin != _lastLogin) {
      _lastAvatarUrl = newUrl;
      _lastLogin = newLogin;
      setState(() {});
    }
  }

  void _maybeStartNav() {
    if (_navStarted) return;
    _navStarted = true;
    // Пускаем появление навбара в следующем кадре после первого
    // лейаута — без этого он «вылетает» в момент старта приложения.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _navAppear.forward();
    });
  }

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    // Лениво создаём дерево вкладок: на cold-start монтируется только
    // активная вкладка (Profile по дефолту), остальные — при первом
    // переключении. Это убирает initState() Actions/Bugs со старта.
    final pages = [
      for (var i = 0; i < _pages.length; i++)
        if (_visited.contains(i))
          _pages[i]
        else
          const SizedBox.shrink(),
    ];
    return Scaffold(
      backgroundColor: pal.bg,
      extendBody: true,
      extendBodyBehindAppBar: true,
      resizeToAvoidBottomInset: true,
      body: Stack(
        children: [
          Positioned.fill(
            // IndexedStack сохраняет State каждой вкладки между
            // переключениями — никаких пере-создания экранов/контроллеров.
            // Все ListView'ы сохраняют scroll-offset, шапки не мигают,
            // фильтры не сбрасываются. Это даёт «мгновенный» переход
            // между табами без лагов от инициализации.
            child: IndexedStack(
              index: _index,
              sizing: StackFit.expand,
              children: pages,
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: SafeArea(
              top: false,
              child: Builder(builder: (ctx) {
                // Запускаем появление только после первого лейаута
                // — иначе на медленных устройствах навбар «вылетает» рывком.
                _maybeStartNav();
                return FadeTransition(
                  opacity: CurvedAnimation(
                    parent: _navAppear,
                    curve: Curves.easeOut,
                  ),
                  child: SlideTransition(
                    position: Tween<Offset>(
                      begin: const Offset(0, 0.35),
                      end: Offset.zero,
                    ).animate(CurvedAnimation(
                      parent: _navAppear,
                      curve: const Cubic(.32, .72, .00, 1),
                    )),
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 20),
                      child: Center(
                        // RepaintBoundary вокруг островка: при любом
                        // изменении в страницах под ним нам НЕ нужно
                        // перерисовывать сам островок (он стабильный,
                        // не зависит от контента). Раньше при скролле
                        // под навбаром Flutter перерисовывал всё
                        // содержимое навбара — это и было самым
                        // заметным «дрожанием» при переходах.
                        child: RepaintBoundary(
                          child: _IslandNav(
                            index: _index,
                            avatarUrl: _lastAvatarUrl,
                            login: _lastLogin,
                            onChanged: (i) {
                              if (_index == i) return;
                              _visited.add(i);
                              setState(() => _index = i);
                            },
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              }),
            ),
          ),
        ],
      ),
    );
  }
}

/// Компактный island-navbar 1:1 с HTML.
/// Размеры из CSS:
///  - .nav-btn: 52x44, radius 20
///  - .island-nav: padding 8 10, gap 4, radius 28
class _IslandNav extends StatefulWidget {
  final int index;
  final String? avatarUrl;
  final String login;
  final ValueChanged<int> onChanged;
  const _IslandNav({
    required this.index,
    required this.avatarUrl,
    required this.login,
    required this.onChanged,
  });

  @override
  State<_IslandNav> createState() => _IslandNavState();
}

class _IslandNavState extends State<_IslandNav>
    with SingleTickerProviderStateMixin {
  static const double _btnW = 52;
  static const double _btnH = 44;
  static const double _gap = 4;
  static const double _padH = 10;
  static const double _padV = 8;

  // squash-эффект на тапе: pill «сплющивается» по X на 12% и
  // возвращается в норму. Делаем через AnimationController + одну
  // подписку — это в разы дешевле чем TweenAnimationBuilder + Timer
  // (тот пере-создаёт Tween на каждый setState, и Timer.cancel
  // не отменяет уже посланный setState).
  late final AnimationController _squashCtl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 320),
  );

  @override
  void didUpdateWidget(covariant _IslandNav old) {
    super.didUpdateWidget(old);
    if (old.index != widget.index) {
      _squashCtl
        ..stop()
        ..value = 0
        ..forward();
    }
  }

  @override
  void dispose() {
    _squashCtl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    final pillX = widget.index * (_btnW + _gap);

    // Раньше тут был BackdropFilter(ImageFilter.blur(18,18)) — постоянный
    // runtime-блюр на навбаре, который ВСЕГДА виден поверх контента.
    // Это пересчитывалось каждый кадр, дорого по GPU и заметно тормозило
    // при любых анимациях: скролле, push-перехоadах между экранами,
    // дроп-капле клавиатуры. Заменили на сплошной полупрозрачный фон
    // (с чуть более высоким alpha — чтобы читалось так же чётко).
    // На glass-эффект внешне это влияет минимально: под навбаром
    // обычно либо контейнеры pal.cont, либо однородный фон pal.bg.
    final bg = pal.isDark
        ? const Color(0xF21C1C1E) // dark: ~0.95 alpha
        : const Color(0xF2FFFFFF); // light: ~0.95 alpha

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        boxShadow: [
          BoxShadow(
            color: pal.isDark
                ? const Color(0x73000000) // 0.45
                : const Color(0x24000000), // 0.14
            blurRadius: 32,
            offset: const Offset(0, 8),
          ),
          BoxShadow(
            color: pal.isDark
                ? const Color(0x40000000) // 0.25
                : const Color(0x14000000), // 0.08
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(28),
        child: Container(
          padding: const EdgeInsets.symmetric(
              horizontal: _padH, vertical: _padV),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(28),
          ),
          child: SizedBox(
            width: _btnW * 3 + _gap * 2,
            height: _btnH,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                // Перемещение pill'а — AnimatedPositioned с длительностью
                // 320ms (раньше 420ms — слишком долго на тапе).
                AnimatedPositioned(
                  duration: const Duration(milliseconds: 320),
                  curve: const Cubic(.32, .72, .00, 1),
                  left: pillX,
                  top: 0,
                  width: _btnW,
                  height: _btnH,
                  child: AnimatedBuilder(
                    animation: _squashCtl,
                    builder: (_, child) {
                      // squash 0->1: 0 → 1.12 → 1.0 (parabolic)
                      final t = _squashCtl.value;
                      final v = 1.0 + 0.12 * (1.0 - (2 * t - 1).abs());
                      return Transform.scale(
                          scaleX: v, scaleY: 1.0, child: child);
                    },
                    child: Container(
                      decoration: BoxDecoration(
                        color: AppColors.accent.withValues(alpha: .18),
                        borderRadius: BorderRadius.circular(20),
                      ),
                    ),
                  ),
                ),
                Row(
                  children: [
                    _NavBtn(
                      icon: 'solar:play-circle-bold',
                      active: widget.index == 0,
                      onTap: () => widget.onChanged(0),
                    ),
                    const SizedBox(width: _gap),
                    _NavBtn(
                      icon: 'solar:bug-bold',
                      active: widget.index == 1,
                      onTap: () => widget.onChanged(1),
                    ),
                    const SizedBox(width: _gap),
                    _NavAvatarBtn(
                      active: widget.index == 2,
                      avatarUrl: widget.avatarUrl,
                      login: widget.login,
                      onTap: () => widget.onChanged(2),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _NavBtn extends StatelessWidget {
  final String icon;
  final bool active;
  final VoidCallback onTap;
  const _NavBtn(
      {required this.icon, required this.active, required this.onTap});
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: 52,
        height: 44,
        child: Center(
          // AnimatedSwitcher вместо TweenAnimationBuilder<Color?>:
          // ColorTween на каждый rebuild создавала новый tween и
          // лопатила AnimationController. Тут — кросс-фейд между двумя
          // const-иконками (active/inactive), key-based. Виджет рисуется
          // как const, AnimatedSwitcher переключает только когда реально
          // меняется active. Сильно дешевле.
          child: _NavIcon(icon: icon, active: active),
        ),
      ),
    );
  }
}

class _NavIcon extends StatelessWidget {
  final String icon;
  final bool active;
  const _NavIcon({required this.icon, required this.active});

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 200),
      switchInCurve: Curves.easeOut,
      switchOutCurve: Curves.easeIn,
      child: Iconify(
        icon,
        key: ValueKey<bool>(active),
        size: 24,
        color: active ? AppColors.accent : pal.sub,
      ),
    );
  }
}

class _NavAvatarBtn extends StatelessWidget {
  final bool active;
  final String? avatarUrl;
  final String login;
  final VoidCallback onTap;
  const _NavAvatarBtn({
    required this.active,
    required this.avatarUrl,
    required this.login,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final hasUrl = avatarUrl != null && avatarUrl!.isNotEmpty;
    final letter = login.isNotEmpty ? login[0].toUpperCase() : '?';

    // Просьба пользователя: убрать progress-кольцо вокруг аватарки в
    // навбаре при заливке. Прогресс по-прежнему виден на карточке
    // «Залить файлы» на профиле — в навбаре аватарка теперь чистая
    // (28×28 без обводки) и не подписана на activeUpload — это убирает
    // лишние setState() в навбаре во время заливок.
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: 52,
        height: 44,
        child: Center(
          child: SizedBox(
            width: 28,
            height: 28,
            child: ClipOval(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // Подложка с градиентом и буквой — рисуется всегда,
                  // под картинкой, чтобы первый кадр не был «пустым».
                  Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [AppColors.accent, AppColors.pink],
                      ),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      letter,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -.3,
                      ),
                    ),
                  ),
                  if (hasUrl)
                    Image.network(
                      avatarUrl!,
                      key: ValueKey(avatarUrl),
                      fit: BoxFit.cover,
                      gaplessPlayback: true,
                      frameBuilder: (ctx, child, frame, wasSync) {
                        // Даже когда картинка уже в кэше — плавный fade,
                        // чтобы аватарка не вспыхивала резко на старте.
                        return AnimatedOpacity(
                          opacity: (wasSync || frame != null) ? 1 : 0,
                          duration: const Duration(milliseconds: 260),
                          curve: Curves.easeOut,
                          child: child,
                        );
                      },
                      errorBuilder: (_, __, ___) =>
                          const SizedBox.shrink(),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
