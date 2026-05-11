import 'package:flutter/material.dart';
import '../theme.dart';

/// Метаданные категории/приоритета/статуса/типа в стиле HTML-эталона.

class KindMeta {
  final String label;
  final String sub;
  final String icon;
  final Color color;
  const KindMeta(this.label, this.sub, this.icon, this.color);
}

const Map<String, KindMeta> kKindMeta = {
  'visual': KindMeta('Визуальный', 'UI / стиль', 'solar:palette-bold', AppColors.purple),
  'func':   KindMeta('Функциональный', 'Логика', 'solar:settings-bold', AppColors.blue),
  'crash':  KindMeta('Краш', 'Падение', 'solar:bug-bold', AppColors.red),
  'perf':   KindMeta('Лаги', 'Тормоза', 'solar:bolt-bold', AppColors.teal),
  'ux':     KindMeta('UX', 'Удобство', 'solar:hand-stars-bold', AppColors.pink),
  'other':  KindMeta('Другое', 'Прочее', 'solar:question-circle-bold', AppColors.dark),
};

class PriMeta {
  final String label;
  final String icon;
  final Color color;
  const PriMeta(this.label, this.icon, this.color);
}

const Map<String, PriMeta> kPriMeta = {
  'low':  PriMeta('Низкий',  'solar:double-alt-arrow-down-bold', AppColors.green),
  'med':  PriMeta('Средний', 'solar:alt-arrow-right-bold',       AppColors.orange),
  'high': PriMeta('Высокий', 'solar:double-alt-arrow-up-bold',   AppColors.red),
};

class StatusMeta {
  final String label;
  final Color color;
  const StatusMeta(this.label, this.color);
}

const Map<String, StatusMeta> kStatusMeta = {
  'open': StatusMeta('Открыт', AppColors.orange),
  'prog': StatusMeta('В работе', AppColors.blue),
  'done': StatusMeta('Закрыт', AppColors.green),
};

class TypeMeta {
  final String label;
  final String icon;
  final Color color;
  const TypeMeta(this.label, this.icon, this.color);
}

const Map<String, TypeMeta> kTypeMeta = {
  'bug':  TypeMeta('Баг',         'solar:bug-bold',       AppColors.red),
  'sugg': TypeMeta('Предложение', 'solar:lightbulb-bold', AppColors.blue),
};

const List<String> kSuggestedLabels = [
  'android', 'ios', 'api', 'auth', 'ui', 'dark-mode', 'offline',
];

/// Максимум скриншотов на один баг-репорт.
///
/// Лимит нужен по двум причинам:
///   • Каждый снимок 12MP весит 2–5 MB. 15 кадров — это 30–75 MB байтов
///     в памяти + столько же base64-строки. Больше — реальный риск OOM
///     на бюджетных Android-устройствах.
///   • Сериализация base64Encode + запись файла на «Создать» занимает
///     порядка 0.5–1.5с на 15 фото — для спиннера в кнопке это
///     комфортное ожидание.
const int kMaxShotsPerBug = 15;

/// «только что», «5 мин назад», «3 ч назад», «2 д назад».
String timeAgo(int ms) {
  final s = ((DateTime.now().millisecondsSinceEpoch - ms) / 1000).round();
  if (s < 60) return 'только что';
  if (s < 3600) return '${(s / 60).floor()} мин назад';
  if (s < 86400) return '${(s / 3600).floor()} ч назад';
  return '${(s / 86400).floor()} д назад';
}

String pluralRu(int n, String one, String few, String many) {
  final m10 = n % 10;
  final m100 = n % 100;
  if (m10 == 1 && m100 != 11) return one;
  if (m10 >= 2 && m10 <= 4 && (m100 < 10 || m100 >= 20)) return few;
  return many;
}
