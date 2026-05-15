import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:record/record.dart';

import 'speech.dart';

/// Real-time speech-to-text через Groq Whisper API.
///
/// Идея: непрерывно записываем PCM 16-bit, 16 kHz, mono. Каждые
/// ~1.2 секунды отправляем «скользящее окно» последних N секунд аудио
/// в Whisper, получаем строку. Внутри одного «сегмента» (до commit'а)
/// каждая новая отправка перетирает «живой хвост» — пользователь видит
/// текст с минимальной задержкой.
///
/// Каждые ~7 секунд сегмент «коммитится»: текущий ответ Whisper
/// прибавляется к `_committedPrefix`, аудио-буфер очищается, начинается
/// новый сегмент. Это держит payload маленьким и не зависит от
/// долгих коннектов.
class WhisperGroqBackend implements SpeechBackend {
  WhisperGroqBackend._();
  static final WhisperGroqBackend I = WhisperGroqBackend._();

  static const int _sampleRate = 16000;
  static const int _bytesPerSample = 2; // 16-bit
  static const String _model = 'whisper-large-v3-turbo';
  static const String _apiUrl =
      'https://api.groq.com/openai/v1/audio/transcriptions';

  // Каждые столько мс отправляем «живой хвост».
  static const Duration _flushInterval = Duration(milliseconds: 1200);
  // Длина «коммит-окна» в байтах ≈ 7 секунд.
  int get _commitWindowBytes =>
      _sampleRate * _bytesPerSample * 7;

  final AudioRecorder _recorder = AudioRecorder();
  final ValueNotifier<String> _recognized = ValueNotifier<String>('');
  final ValueNotifier<bool> _listening = ValueNotifier<bool>(false);

  @override
  ValueListenable<String> get recognized => _recognized;
  @override
  ValueListenable<bool> get listening => _listening;

  String apiKey = '';
  String language = 'ru';

  bool _running = false;
  StreamSubscription<Uint8List>? _audioSub;
  final BytesBuilder _segmentBuffer = BytesBuilder(copy: false);
  String _committedPrefix = '';
  String _liveSegment = '';
  Timer? _flushTimer;
  // Защита от перекрытия запросов — если предыдущий не вернулся, новый
  // пропускаем (последний победит).
  bool _flushInFlight = false;
  ValueChanged<String>? _onError;
  @override
  set onError(ValueChanged<String>? cb) => _onError = cb;

  @override
  Future<void> start() async {
    if (_running) return;
    if (apiKey.isEmpty) {
      _onError?.call('Не задан ключ Groq API');
      return;
    }
    final hasPermission = await _recorder.hasPermission();
    if (!hasPermission) {
      _onError?.call('Нет разрешения на микрофон');
      return;
    }
    _running = true;
    _committedPrefix = '';
    _liveSegment = '';
    _segmentBuffer.clear();
    _recognized.value = '';
    try {
      final stream = await _recorder.startStream(const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: _sampleRate,
        numChannels: 1,
        bitRate: 256000,
        echoCancel: true,
        noiseSuppress: true,
        autoGain: false,
      ));
      _audioSub = stream.listen(_onAudio, onError: (Object e) {
        _onError?.call('Audio stream error: $e');
      });
      _flushTimer = Timer.periodic(_flushInterval, (_) => _flush());
      _listening.value = true;
    } catch (e) {
      _onError?.call('Не удалось запустить запись: $e');
      _running = false;
      _listening.value = false;
    }
  }

  @override
  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    _flushTimer?.cancel();
    _flushTimer = null;
    try {
      await _recorder.stop();
    } catch (_) {}
    await _audioSub?.cancel();
    _audioSub = null;
    _listening.value = false;
    // Финальный flush, чтобы не потерять последние ~1 сек.
    await _flush(forceCommit: true);
  }

  @override
  void clearRecognized() {
    _committedPrefix = '';
    _liveSegment = '';
    _segmentBuffer.clear();
    _recognized.value = '';
  }

  void _onAudio(Uint8List chunk) {
    if (!_running) return;
    _segmentBuffer.add(chunk);
  }

  Future<void> _flush({bool forceCommit = false}) async {
    if (_flushInFlight) return;
    if (_segmentBuffer.length < _sampleRate * _bytesPerSample ~/ 3) {
      // <~330 мс данных — нечего слать, тишина или старт.
      return;
    }
    _flushInFlight = true;
    try {
      final bytes = Uint8List.fromList(_segmentBuffer.toBytes());
      final wav = _wrapWav(bytes);
      final text = await _transcribe(wav);
      if (text == null) return;
      _liveSegment = text;
      _publish();
      // Если буфер «дорос» до коммит-окна или нас попросили — коммитим.
      final shouldCommit =
          forceCommit || _segmentBuffer.length >= _commitWindowBytes;
      if (shouldCommit) {
        if (_liveSegment.isNotEmpty) {
          _committedPrefix = _committedPrefix.isEmpty
              ? _liveSegment
              : '$_committedPrefix $_liveSegment'.trim();
        }
        _liveSegment = '';
        _segmentBuffer.clear();
        _publish();
      }
    } catch (e) {
      _onError?.call('Ошибка распознавания: $e');
    } finally {
      _flushInFlight = false;
    }
  }

  void _publish() {
    final combined = _liveSegment.isEmpty
        ? _committedPrefix
        : (_committedPrefix.isEmpty
            ? _liveSegment
            : '$_committedPrefix $_liveSegment').trim();
    if (combined != _recognized.value) {
      _recognized.value = combined;
    }
  }

  Future<String?> _transcribe(Uint8List wav) async {
    try {
      final req = http.MultipartRequest('POST', Uri.parse(_apiUrl))
        ..headers['Authorization'] = 'Bearer $apiKey'
        ..fields['model'] = _model
        ..fields['language'] = language
        ..fields['response_format'] = 'text'
        ..fields['temperature'] = '0'
        ..files.add(http.MultipartFile.fromBytes(
          'file',
          wav,
          filename: 'audio.wav',
        ));
      final streamed = await req.send().timeout(
        const Duration(seconds: 8),
        onTimeout: () => http.StreamedResponse(
          const Stream<List<int>>.empty(),
          408,
        ),
      );
      final res = await http.Response.fromStream(streamed);
      if (res.statusCode == 200) {
        return res.body.trim();
      }
      _onError?.call('Groq ${res.statusCode}: ${res.body}');
      return null;
    } catch (e) {
      _onError?.call('Groq error: $e');
      return null;
    }
  }

  /// Оборачивает PCM 16-bit / 16 kHz / mono в WAV-контейнер.
  Uint8List _wrapWav(Uint8List pcm) {
    final dataLen = pcm.length;
    final fileLen = 36 + dataLen;
    const byteRate = _sampleRate * _bytesPerSample;
    final out = BytesBuilder()
      ..add(ascii('RIFF'))
      ..add(_u32(fileLen))
      ..add(ascii('WAVE'))
      ..add(ascii('fmt '))
      ..add(_u32(16))
      ..add(_u16(1)) // PCM
      ..add(_u16(1)) // mono
      ..add(_u32(_sampleRate))
      ..add(_u32(byteRate))
      ..add(_u16(_bytesPerSample)) // block align
      ..add(_u16(16)) // bits per sample
      ..add(ascii('data'))
      ..add(_u32(dataLen))
      ..add(pcm);
    return out.toBytes();
  }

  static List<int> ascii(String s) => s.codeUnits;
  static Uint8List _u32(int v) {
    final b = ByteData(4)..setUint32(0, v, Endian.little);
    return b.buffer.asUint8List();
  }

  static Uint8List _u16(int v) {
    final b = ByteData(2)..setUint16(0, v, Endian.little);
    return b.buffer.asUint8List();
  }
}
