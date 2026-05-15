# Суфлёр

Мобильный телепромптер на Flutter с автоматической прокруткой по голосу.

## Возможности

- Вставка/набор любого текста и сохранение его между запусками.
- Чтение в полноэкранном режиме с подсветкой уже прочитанной части
  текста и текущего слова.
- Авто-прокрутка по микрофону: приложение слушает голос через
  системное распознавание речи и удерживает текущее слово примерно
  на трети экрана — плавно, без лагов.
- Fallback-режим: если микрофон выключен, прокрутка идёт с заданной
  скоростью (px/с).
- Прозрачный статусбар с мягким градиентом-фейдом и контейнеры в
  стиле iOS-настроек.
- Настройка размера шрифта, межстрочного интервала, локали
  распознавания и скорости.

## Стек

- **Flutter** 3.27 (Dart 3.6, Material 3)
- **speech_to_text** — нативное распознавание речи (Android `SpeechRecognizer`, iOS `SFSpeechRecognizer`).
- **permission_handler** — runtime-разрешения на микрофон.
- **shared_preferences** — локальное хранение текста и настроек.

## Сборка APK

CI собирает release-APK на каждый push/PR в `main`/`master` через
GitHub Actions (`.github/workflows/build.yml`). Готовый APK скачивается
из секции **Actions → Artifacts** (`suflyor-release-apk`).

Локально:

```bash
flutter pub get
flutter build apk --release
# результат: build/app/outputs/flutter-apk/app-release.apk
```

## Подпись релиза (опционально)

CI поддерживает релизную подпись, если в репозитории заданы секреты:

| Secret              | Описание                                              |
| ------------------- | ----------------------------------------------------- |
| `KEYSTORE_BASE64`   | `keytool`-keystore в base64 (`base64 keystore.jks`).  |
| `KEYSTORE_PASSWORD` | Пароль от keystore.                                   |
| `KEY_ALIAS`         | Алиас ключа (по умолчанию `upload`).                  |
| `KEY_PASSWORD`      | Пароль ключа (по умолчанию = `KEYSTORE_PASSWORD`).    |

Если секреты не заданы — APK подписан debug-ключом (этого достаточно
для ручной установки в CI-превью).

## Структура

```
lib/
├── main.dart                # Edge-to-edge + тема, точка входа
├── theme.dart               # Палитра, токены, top-fade градиент
├── widgets.dart             # TopFadeHeader, CardBox, кнопки, тайлы
├── prefs.dart               # SharedPreferences-обёртка
├── speech.dart              # SpeechService (speech_to_text)
└── screens/
    ├── home.dart            # Главный экран — текст + кнопка «Начать»
    ├── prompter.dart        # Чтение: подсветка + авто-скролл
    └── settings.dart        # Настройки шрифта/скорости/локали
```

## Запуск

```bash
flutter pub get
flutter run -d <device>
```
