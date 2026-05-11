import 'package:flutter/material.dart';

/// Маркер: маршрут не хочет, чтобы экран под ним «уезжал» вбок при пуше.
/// Используется для оверлеев (например, просмотр скриншотов) — нижний
/// экран должен оставаться на месте, иначе при закрытии получаем
/// неприятный «slide back» сбоку.
mixin NoSlideOnPush {}

/// Кастомный slide-переход между экранами.
///
/// История:
///   - 520ms / S-кривая — лагало (баг n3837).
///   - 320ms / Cubic(.2,0,0,1) + AnimatedBuilder для скруглённых углов —
///     уже лучше, но AnimatedBuilder каждый кадр пере-рендерил обёртку
///     даже когда maxRadius=0 (фича отключена).
///   - 260ms / Cubic(.05,.7,.1,1), без параллакса — снаппи, но визуально
///     суховато.
///   - 320ms emphasized-decelerate + iOS-style параллакс — пользователь
///     пожаловался, что переходы «как пружины», возврат «то медленно то
///     быстро», в целом «ужас». Параллакс + асимметричные кривые
///     (decelerate forward, accelerate back) действительно создают
///     ощущение неравномерной скорости.
///   - **Сейчас:** простой симметричный slide на Curves.easeOutCubic
///     (одинаковая кривая в обе стороны, без параллакса и fade).
///     Длительность 280ms — заметно мягче «снаппи» 260ms, но не
///     «тягуче». Поведение почти как у системного PageView — плавно,
///     предсказуемо, симметрично.
class SlideRoute<T> extends PageRouteBuilder<T> {
  final Widget child;
  final bool back;
  SlideRoute({required this.child, this.back = false})
      : super(
          opaque: true,
          transitionDuration: const Duration(milliseconds: 280),
          reverseTransitionDuration: const Duration(milliseconds: 280),
          pageBuilder: (_, __, ___) => child,
          transitionsBuilder: (ctx, anim, secondAnim, child) {
            // Curves.easeOutCubic — гладкая кривая с плавным замедлением,
            // без «прыжков». Симметричная forward/back, поэтому возврат
            // ощущается так же, как и пуш.
            final inAnim =
                CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
            final dx = back ? -1.0 : 1.0;
            final inOffset = Tween<Offset>(
              begin: Offset(dx, 0),
              end: Offset.zero,
            ).animate(inAnim);
            return SlideTransition(position: inOffset, child: child);
          },
        );

  /// Экран НЕ должен уезжать в сторону, когда поверх него открывается
  /// модалка-оверлей (фуллскрин просмотр скрина и т.п.). Иначе при её
  /// закрытии родительский экран будет «возвращаться сбоку».
  @override
  bool canTransitionTo(TransitionRoute<dynamic> nextRoute) {
    if (nextRoute is NoSlideOnPush) return false;
    return super.canTransitionTo(nextRoute);
  }
}

Future<T?> pushSlide<T>(BuildContext context, Widget page) {
  // Снимаем фокус с активного поля ввода ДО пуша — иначе
  // системная клавиатура может остаться открытой во время slide-
  // анимации, а при возврате (свайп назад / Navigator.pop) она
  // резко выскакивает обратно и портит переход. Делается централизованно
  // тут, чтобы все push'ы через pushSlide работали единообразно.
  FocusManager.instance.primaryFocus?.unfocus();
  return Navigator.of(context).push<T>(SlideRoute<T>(child: page));
}
