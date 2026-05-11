import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// Маппинг "solar:icon-name" -> файл в assets/icons/. На холодном старте
/// все SVG прогреваются в `svg.cache` через `SvgAssetLoader`
/// (см. [precacheAllSvgs]). Здесь мы рисуем через `SvgPicture.asset` —
/// тот же loader, тот же cacheKey, поэтому декодер берёт уже
/// расжатую картинку из кэша БЕЗ повторного парсинга SVG-XML.
///
/// История: раньше тут вызывали `SvgPicture.string(cached, ...)`
/// (где `cached` — строка из `kSvgStringCache`). У SvgStringLoader
/// cacheKey = содержимое строки, у SvgAssetLoader — путь, и `svg.cache`
/// прогревалось только для второго. То есть string-вариант мимо кэша
/// каждый раз парсил XML — это и был один из главных источников лагов
/// при скролле списка репозиториев и при открытии деталей репозитория
/// (там 5-8 иконок в первом кадре, каждая парсилась с нуля).
class Iconify extends StatelessWidget {
  final String icon;
  final double size;
  final Color? color;
  const Iconify(this.icon, {super.key, this.size = 24, this.color});

  String _assetPath() {
    final norm = icon.replaceAll(':', '_');
    return 'assets/icons/$norm.svg';
  }

  @override
  Widget build(BuildContext context) {
    final c = color ?? DefaultTextStyle.of(context).style.color ?? Colors.white;
    return SvgPicture.asset(
      _assetPath(),
      width: size,
      height: size,
      colorFilter: ColorFilter.mode(c, BlendMode.srcIn),
      placeholderBuilder: (_) => SizedBox(width: size, height: size),
    );
  }
}
