import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

/// Unified interface для разных движков распознавания речи. Реализации:
/// * [LocalSpeechBackend] — обёртка над `speech_to_text` (системный
///   SpeechRecognizer на Android, SFSpeechRecognizer на iOS). Работает
///   offline, но имеет лимит на сессию и склонен «зависать».
/// * `WhisperGroqBackend` — потоковая запись звука + Groq Whisper API
///   (см. `whisper.dart`). Стабильнее и быстрее, но требует интернет
///   и API-ключ.
abstract class SpeechBackend {
  /// Текущий «накопленный» текст распознавания с момента старта.
  /// При паузе/рестарте сессии бэкенд сам докатывает новые слова в
  /// этот же стрим (с пробелом-разделителем) — потребителю не нужно
  /// думать про сессии.
  ValueListenable<String> get recognized;

  /// True пока движок реально слушает микрофон.
  ValueListenable<bool> get listening;

  /// Старт прослушивания. Идемпотентен.
  Future<void> start();

  /// Останавливает прослушивание и сбрасывает текущий накопленный
  /// текст (следующий [start] начнёт с нуля).
  Future<void> stop();

  /// Очистить накопленный текст без остановки — нужен на «reset» в UI.
  void clearRecognized();

  /// Колбэк ошибок для отображения в UI (SnackBar).
  set onError(ValueChanged<String>? cb);
}

/// Локальный движок: системное распознавание речи через `speech_to_text`.
///
/// Главные особенности:
/// * Android-движок закрывает сессию каждые ~10–30 сек или после паузы;
///   мы автоматически перезапускаем listen() из status-листенера.
/// * Между перезапусками склеиваем «накопленный» текст руками — плагин
///   при новой сессии начинает с пустой строки.
class LocalSpeechBackend implements SpeechBackend {
  LocalSpeechBackend._();
  static final LocalSpeechBackend I = LocalSpeechBackend._();

  final stt.SpeechToText _stt = stt.SpeechToText();
  final ValueNotifier<String> _recognized = ValueNotifier<String>('');
  final ValueNotifier<bool> _listening = ValueNotifier<bool>(false);

  @override
  ValueListenable<String> get recognized => _recognized;
  @override
  ValueListenable<bool> get listening => _listening;

  String localeId = 'ru_RU';

  bool _available = false;
  bool _initRequested = false;
  bool _wantListening = false;
  bool _restartScheduled = false;
  // Накопленный текст ПРЕДЫДУЩИХ сессий (без текущей). Каждая новая
  // partial из текущей сессии просто заменяет «хвост» — итог собирается
  // как `_committedPrefix + currentSession`.
  String _committedPrefix = '';
  List<stt.LocaleName> _locales = const [];
  List<stt.LocaleName> get locales => _locales;
  ValueChanged<String>? _onError;
  @override
  set onError(ValueChanged<String>? cb) => _onError = cb;

  Future<bool> ensureInit() async {
    if (_initRequested) return _available;
    _initRequested = true;
    try {
      _available = await _stt.initialize(
        onStatus: _onStatus,
        onError: (e) {
          _onError?.call(e.errorMsg);
          if (e.permanent) {
            _wantListening = false;
            _listening.value = false;
          }
        },
      );
      if (_available) {
        _locales = await _stt.locales();
      }
    } catch (e) {
      _available = false;
      _onError?.call('Speech init failed: $e');
    }
    return _available;
  }

  @override
  Future<void> start() async {
    if (!_available) {
      final ok = await ensureInit();
      if (!ok) return;
    }
    _wantListening = true;
    _committedPrefix = '';
    _recognized.value = '';
    await _startSession();
  }

  Future<void> _startSession() async {
    if (_stt.isListening) return;
    try {
      await _stt.listen(
        onResult: _onResult,
        listenFor: const Duration(minutes: 30),
        pauseFor: const Duration(seconds: 30),
        localeId: localeId,
        listenOptions: stt.SpeechListenOptions(
          partialResults: true,
          listenMode: stt.ListenMode.dictation,
          cancelOnError: false,
          autoPunctuation: false,
        ),
      );
      _listening.value = true;
    } catch (e) {
      _onError?.call('Speech start failed: $e');
      _listening.value = false;
    }
  }

  @override
  Future<void> stop() async {
    _wantListening = false;
    try {
      await _stt.stop();
    } catch (_) {}
    _listening.value = false;
  }

  @override
  void clearRecognized() {
    _committedPrefix = '';
    _recognized.value = '';
  }

  void _onResult(SpeechRecognitionResult r) {
    final session = r.recognizedWords;
    final full = _committedPrefix.isEmpty
        ? session
        : '$_committedPrefix $session'.trim();
    if (full != _recognized.value) {
      _recognized.value = full;
    }
    if (r.finalResult && session.isNotEmpty) {
      _committedPrefix = full;
    }
  }

  void _onStatus(String status) {
    final stillListening = _stt.isListening;
    _listening.value = stillListening;
    if (!stillListening && _wantListening && !_restartScheduled) {
      _restartScheduled = true;
      Future.delayed(const Duration(milliseconds: 120), () async {
        _restartScheduled = false;
        if (_wantListening) {
          await _startSession();
        }
      });
    }
  }
}
