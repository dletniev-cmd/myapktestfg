import 'package:flutter_svg/flutter_svg.dart';

/// Список всех SVG-иконок (assets/icons/*.svg). Список захардкожен, чтобы
/// не парсить AssetManifest на каждом старте — это +50ms на холодный старт.
const List<String> kAllSvgIcons = [
  'mdi_github.svg',
  'solar_add-circle-bold.svg',
  'solar_add-circle-linear.svg',
  'solar_add-square-bold.svg',
  'solar_alt-arrow-down-linear.svg',
  'solar_alt-arrow-left-linear.svg',
  'solar_alt-arrow-right-bold.svg',
  'solar_alt-arrow-right-linear.svg',
  'solar_archive-bold.svg',
  'solar_arrow-right-bold.svg',
  'solar_arrow-right-up-bold.svg',
  'solar_bell-bold.svg',
  'solar_bell-off-bold.svg',
  'solar_bolt-bold.svg',
  'solar_branching-paths-up-bold.svg',
  'solar_bug-bold.svg',
  'solar_check-bold.svg',
  'solar_check-circle-bold.svg',
  'solar_clipboard-add-bold.svg',
  'solar_clock-circle-bold.svg',
  'solar_close-circle-bold.svg',
  'solar_close-circle-linear.svg',
  'solar_cloud-upload-bold.svg',
  'solar_code-bold.svg',
  'solar_code-square-bold.svg',
  'solar_copy-bold.svg',
  'solar_document-add-bold.svg',
  'solar_document-text-bold.svg',
  'solar_double-alt-arrow-down-bold.svg',
  'solar_double-alt-arrow-up-bold.svg',
  'solar_download-bold.svg',
  'solar_download-square-bold.svg',
  'solar_eye-bold.svg',
  'solar_flag-bold.svg',
  'solar_folder-bold.svg',
  'solar_folder-open-bold.svg',
  'solar_folder-with-files-bold.svg',
  'solar_forbidden-circle-bold.svg',
  'solar_forward-bold.svg',
  'solar_gallery-add-bold.svg',
  'solar_rocket-bold.svg',
  'solar_hand-stars-bold.svg',
  'solar_inbox-bold.svg',
  'solar_lightbulb-bold.svg',
  'solar_link-bold.svg',
  'solar_lock-keyhole-bold.svg',
  'solar_logout-2-bold.svg',
  'solar_menu-dots-bold.svg',
  'solar_moon-stars-bold.svg',
  'solar_palette-bold.svg',
  'solar_pen-bold.svg',
  'solar_play-circle-bold.svg',
  'solar_question-circle-bold.svg',
  'solar_refresh-bold.svg',
  'solar_refresh-linear.svg',
  'solar_settings-bold.svg',
  'solar_server-bold.svg',
  'solar_ssd-square-bold.svg',
  'solar_sort-vertical-linear.svg',
  'solar_star-bold.svg',
  'solar_stop-bold.svg',
  'solar_stop-circle-bold.svg',
  'solar_stopwatch-bold-duotone.svg',
  'solar_sun-2-bold.svg',
  'solar_trash-bin-2-bold.svg',
  'solar_trash-bin-trash-linear.svg',
  'solar_undo-left-round-bold.svg',
  'solar_upload-bold.svg',
  'solar_user-bold.svg',
  'solar_users-group-rounded-bold.svg',
];

/// Прогревает кэш всех SVG-иконок. Зовётся один раз из main(). Через
/// `SvgAssetLoader` парсит каждую иконку и кладёт результат в
/// `svg.cache`. Ключ кэша — путь к ассету, поэтому последующие
/// `SvgPicture.asset(...)` в [Iconify] берут картинку из кэша без
/// повторного парсинга SVG-XML — иконки рисуются мгновенно, без «лагов»
/// при скролле и push-переходах между экранами.
Future<void> precacheAllSvgs() async {
  await Future.wait(kAllSvgIcons.map((name) async {
    final path = 'assets/icons/$name';
    try {
      final loader = SvgAssetLoader(path);
      await svg.cache.putIfAbsent(
        loader.cacheKey(null),
        () => loader.loadBytes(null),
      );
    } catch (_) {}
  }));
}
