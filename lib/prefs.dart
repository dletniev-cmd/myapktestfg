import 'package:shared_preferences/shared_preferences.dart';

/// Простое хранилище настроек/последнего текста — без сторонних state
/// менеджеров, чтобы не тащить лишние зависимости.
class Prefs {
  Prefs._();
  static final Prefs I = Prefs._();

  static const _kText = 'suflyor.text';
  static const _kFontSize = 'suflyor.fontSize';
  static const _kLineHeight = 'suflyor.lineHeight';
  static const _kLocaleId = 'suflyor.localeId';
  static const _kAutoScroll = 'suflyor.autoScroll';
  static const _kFallbackSpeed = 'suflyor.fallbackSpeed';
  static const _kSpeechBackend = 'suflyor.speechBackend';
  static const _kGroqApiKey = 'suflyor.groqApiKey';

  SharedPreferences? _prefs;

  Future<SharedPreferences> _p() async {
    return _prefs ??= await SharedPreferences.getInstance();
  }

  Future<String> getText() async => (await _p()).getString(_kText) ?? '';
  Future<void> setText(String v) async => (await _p()).setString(_kText, v);

  Future<double> getFontSize() async =>
      (await _p()).getDouble(_kFontSize) ?? 26.0;
  Future<void> setFontSize(double v) async =>
      (await _p()).setDouble(_kFontSize, v);

  Future<double> getLineHeight() async =>
      (await _p()).getDouble(_kLineHeight) ?? 1.5;
  Future<void> setLineHeight(double v) async =>
      (await _p()).setDouble(_kLineHeight, v);

  Future<String> getLocaleId() async =>
      (await _p()).getString(_kLocaleId) ?? 'ru_RU';
  Future<void> setLocaleId(String v) async =>
      (await _p()).setString(_kLocaleId, v);

  Future<bool> getAutoScroll() async =>
      (await _p()).getBool(_kAutoScroll) ?? true;
  Future<void> setAutoScroll(bool v) async =>
      (await _p()).setBool(_kAutoScroll, v);

  // Скорость fallback-скролла (когда микрофон выключен) — пикселей/сек.
  Future<double> getFallbackSpeed() async =>
      (await _p()).getDouble(_kFallbackSpeed) ?? 28.0;
  Future<void> setFallbackSpeed(double v) async =>
      (await _p()).setDouble(_kFallbackSpeed, v);

  /// Бэкенд распознавания: `'local'` (default) или `'groq'`.
  Future<String> getSpeechBackend() async =>
      (await _p()).getString(_kSpeechBackend) ?? 'local';
  Future<void> setSpeechBackend(String v) async =>
      (await _p()).setString(_kSpeechBackend, v);

  /// API-ключ Groq, хранится локально в SharedPreferences. Никуда
  /// больше не уходит — вызовы делает само устройство пользователя.
  Future<String> getGroqApiKey() async =>
      (await _p()).getString(_kGroqApiKey) ?? '';
  Future<void> setGroqApiKey(String v) async =>
      (await _p()).setString(_kGroqApiKey, v);
  Future<void> clearGroqApiKey() async =>
      (await _p()).remove(_kGroqApiKey);
}
