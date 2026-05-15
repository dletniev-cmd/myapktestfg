import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

/// Лёгкая обёртка вокруг `speech_to_text` со снимком текущего
/// распознанного текста и единым флагом «слушает».
///
/// Плагин на Android выдаёт `SpeechRecognizer` события с короткими
/// сессиями (обычно 10–30 секунд) — для непрерывного слушания мы
/// автоматически перезапускаем сессию из listener'а статуса. Это
/// типовая практика, рекомендованная авторами плагина.
class SpeechService {
  SpeechService._();
  static final SpeechService I = SpeechService._();

  final stt.SpeechToText _stt = stt.SpeechToText();
  bool _available = false;
  bool _initRequested = false;

  final ValueNotifier<bool> listening = ValueNotifier<bool>(false);

  /// Текущий снимок распознанного текста с начала текущей сессии
  /// автоскролла. Используется для матчинга с исходным текстом.
  final ValueNotifier<String> recognized = ValueNotifier<String>('');

  /// Локали распознавания. Берём системные, чтобы можно было показать
  /// пользователю в настройках.
  List<stt.LocaleName> _locales = const [];
  List<stt.LocaleName> get locales => _locales;

  String _localeId = 'ru_RU';
  bool _wantListening = false;
  bool _restarting = false;

  /// Колбэк об ошибке (например, отказ в разрешении). Сообщения
  /// прокидываются на UI как SnackBar.
  ValueChanged<String>? onError;

  Future<bool> init({String localeId = 'ru_RU'}) async {
    _localeId = localeId;
    if (_initRequested) return _available;
    _initRequested = true;
    try {
      _available = await _stt.initialize(
        onStatus: _onStatus,
        onError: (e) {
          onError?.call(e.errorMsg);
          if (e.permanent) {
            _wantListening = false;
            listening.value = false;
          }
        },
      );
      if (_available) {
        _locales = await _stt.locales();
      }
    } catch (e) {
      _available = false;
      onError?.call('Speech init failed: $e');
    }
    return _available;
  }

  bool get isAvailable => _available;

  Future<void> start({String? localeId}) async {
    if (!_available) {
      final ok = await init(localeId: localeId ?? _localeId);
      if (!ok) return;
    }
    _localeId = localeId ?? _localeId;
    _wantListening = true;
    recognized.value = '';
    await _startInternal();
  }

  Future<void> _startInternal() async {
    if (_stt.isListening) return;
    try {
      await _stt.listen(
        onResult: _onResult,
        listenFor: const Duration(minutes: 30),
        pauseFor: const Duration(seconds: 30),
        localeId: _localeId,
        listenOptions: stt.SpeechListenOptions(
          partialResults: true,
          // Continuous-режим: Android-движок не закрывает сессию между
          // паузами, что снижает «дёрганость» auto-scroll.
          listenMode: stt.ListenMode.dictation,
          cancelOnError: false,
          autoPunctuation: false,
        ),
      );
      listening.value = true;
    } catch (e) {
      onError?.call('Speech start failed: $e');
      listening.value = false;
    }
  }

  Future<void> stop() async {
    _wantListening = false;
    try {
      await _stt.stop();
    } catch (_) {}
    listening.value = false;
  }

  void _onResult(SpeechRecognitionResult r) {
    // Плагин может возвращать кумулятивный текст в рамках сессии — но
    // при рестарте сессии новый текст начинается с нуля. Мы конкатенируем
    // вручную: если предыдущая распознанная строка длиннее новой,
    // считаем что началась новая сессия — приклеиваем новый текст к
    // предыдущему накопленному.
    final newText = r.recognizedWords;
    final prev = recognized.value;
    if (newText.isEmpty) return;

    if (prev.isEmpty) {
      recognized.value = newText;
      return;
    }

    // Если новый текст начинается с того же префикса (внутри одной
    // сессии плагин даёт кумулятивный текст) — просто заменяем целиком.
    if (newText.length >= _lastSegmentLength(prev) &&
        prev.endsWith(_lastSegmentForCompare(prev)) &&
        newText.toLowerCase().startsWith(
              _lastSegmentForCompare(prev).toLowerCase().trim().isEmpty
                  ? ''
                  : '',
            )) {
      // Заглушка ветки — просто продолжаем общим путём.
    }

    // Считаем «новой сессией», если последний результат был final
    // (плагин закрывает сессию после final). Тогда приклеиваем через
    // пробел.
    if (_lastWasFinal) {
      recognized.value = '$prev $newText'.trim();
      _lastWasFinal = false;
    } else {
      // Внутри сессии — кумулятивный текст: заменяем «хвост».
      recognized.value =
          '${_priorBeforeLastSession(prev)}$newText'.trim();
    }

    if (r.finalResult) {
      _lastWasFinal = true;
      _sessionStart = recognized.value.length;
    }
  }

  bool _lastWasFinal = false;
  int _sessionStart = 0;

  String _priorBeforeLastSession(String prev) {
    if (_sessionStart <= 0 || _sessionStart > prev.length) return '';
    return '${prev.substring(0, _sessionStart)} ';
  }

  int _lastSegmentLength(String prev) =>
      prev.length - _sessionStart < 0 ? 0 : prev.length - _sessionStart;

  String _lastSegmentForCompare(String prev) =>
      _sessionStart >= 0 && _sessionStart <= prev.length
          ? prev.substring(_sessionStart)
          : prev;

  void _onStatus(String status) {
    final isStillListening = _stt.isListening;
    listening.value = isStillListening;
    // Авто-рестарт после "notListening" / "done", пока пользователь не
    // выключил микрофон сам.
    if (!isStillListening && _wantListening && !_restarting) {
      _restarting = true;
      Future.delayed(const Duration(milliseconds: 150), () async {
        _restarting = false;
        if (_wantListening) {
          _lastWasFinal = true;
          _sessionStart = recognized.value.length;
          await _startInternal();
        }
      });
    }
  }
}
