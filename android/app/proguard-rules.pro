# ProGuard / R8 rules для GitHub Pusher.
#
# Flutter Gradle Plugin сам добавляет правила для своих классов
# (через flutter-proguard-rules.pro в getDefaultProguardFile), но
# для плагинов и нашего MainActivity нужны явные правила, иначе
# R8 удалит native-методы / классы, которые дёргает Dart через
# method channel, и приложение упадёт на запуске release-сборки.

# Сам Flutter — не трогать.
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.embedding.** { *; }
-dontwarn io.flutter.embedding.**

# MainActivity и его MethodChannel-обработчики (saveToDownloads).
-keep class com.devin.github_pusher.** { *; }

# flutter_local_notifications — сериализация/десериализация notification
# payload идёт через рефлексию.
-keep class com.dexterous.** { *; }
-dontwarn com.dexterous.**

# AndroidX core/Window/SystemUI — используется для edge-to-edge режима.
-keep class androidx.core.view.WindowInsetsControllerCompat { *; }

# Шифрование/HTTPS — на всякий случай.
-dontwarn javax.annotation.**

# Не предупреждать о Play Core (его нет в проекте, но R8 на новых
# AGP иногда жалуется на ссылки в зависимостях).
-dontwarn com.google.android.play.core.**
