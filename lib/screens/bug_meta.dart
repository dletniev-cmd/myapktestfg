import 'package:flutter/material.dart';
import '../iconify.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'bug_constants.dart';

/// Экран Параметров: Категория (2x3 grid), Приоритет (3 в ряд), Метки.
/// `isCreate=true` — мы пришли из BugNewScreen, кнопка «Создать» сохраняет
/// баг в список; `isCreate=false` — режим редактирования из BugDetailScreen,
/// кнопка «Готово» только сохраняет изменения.
class BugMetaScreen extends StatefulWidget {
  final BugItem bug;
  final bool isCreate;
  const BugMetaScreen({super.key, required this.bug, this.isCreate = false});
  @override
  State<BugMetaScreen> createState() => _BugMetaScreenState();
}

class _BugMetaScreenState extends State<BugMetaScreen> {
  void _confirm() {
    final b = widget.bug;
    final navigator = Navigator.of(context);
    final myRoute = ModalRoute.of(context);
    if (widget.isCreate) {
      AppState.I.bugs.insert(0, b);
      if (myRoute != null) {
        navigator.removeRouteBelow(myRoute);
      }
      navigator.pop(true);
    } else {
      navigator.pop();
    }
    // touch() ВЫЗЫВАЕМ СРАЗУ — список багов под нами начинает
    // перерисовываться параллельно со slide-back анимацией. Когда
    // экран докатывается до места — пользователь УЖЕ видит новый/
    // обновлённый баг в списке. Раньше тут было либо
    // Future.delayed(650мс), либо route.completed.then(...) — в обоих
    // случаях ощущалось как «лаг при создать», т.к. между концом
    // анимации и появлением бага в списке был провал.
    //
    // saveBugs() — асинхронный I/O + base64 в isolate (compute), не
    // блокирует UI; пускаем сразу, без await.
    AppState.I.touch();
    AppState.I.saveBugs();
  }

  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    final b = widget.bug;
    // Баг n7850 (тот же фикс что в bug_new.dart): держим контент в Padding
    // от viewInsets.bottom, а Scaffold не ресайзим — иначе при закрытии
    // клавиатуры экран дёргано «опускается».
    final viewInsetBottom = MediaQuery.of(context).viewInsets.bottom;
    return Scaffold(
      backgroundColor: pal.bg,
      resizeToAvoidBottomInset: false,
      body: Stack(
        children: [
          Positioned.fill(
            child: SingleChildScrollView(
              padding: EdgeInsets.only(
                top: MediaQuery.of(context).padding.top + kTopHeaderBarHeight,
                bottom: 32 + viewInsetBottom,
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
              const SecTitle('Категория',
                  padding: EdgeInsets.only(left: 4, bottom: 10)),
              _KindGrid(
                  selected: b.kind,
                  onPick: (k) => setState(() => b.kind = k)),
              const SizedBox(height: 18),

              const SecTitle('Приоритет',
                  padding: EdgeInsets.only(left: 4, bottom: 10)),
              _PriRow(
                  selected: b.priority,
                  onPick: (p) => setState(() => b.priority = p)),
              const SizedBox(height: 18),

              const SecTitle('Метки',
                  padding: EdgeInsets.only(left: 4, bottom: 10)),
              _LabelChips(
                bug: b,
                onChanged: () => setState(() {}),
              ),
              const SizedBox(height: 22),

              PushButton(
                label: widget.isCreate ? 'Создать' : 'Готово',
                icon: 'solar:check-circle-bold',
                onTap: _confirm,
              ),
                ],
              ),
            ),
          ),
          ),
          const Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: TopFadeHeader(title: 'Параметры'),
          ),
        ],
      ),
    );
  }
}

class _KindGrid extends StatelessWidget {
  final String selected;
  final ValueChanged<String> onPick;
  const _KindGrid({required this.selected, required this.onPick});
  @override
  Widget build(BuildContext context) {
    final entries = kKindMeta.entries.toList();
    return Column(
      children: [
        for (var r = 0; r < (entries.length / 2).ceil(); r++)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(children: [
              for (var c = 0; c < 2; c++) ...[
                if (r * 2 + c < entries.length)
                  Expanded(
                    child: _KindCard(
                      k: entries[r * 2 + c].key,
                      meta: entries[r * 2 + c].value,
                      active: selected == entries[r * 2 + c].key,
                      onTap: () => onPick(entries[r * 2 + c].key),
                    ),
                  )
                else
                  const Expanded(child: SizedBox.shrink()),
                if (c == 0) const SizedBox(width: 10),
              ],
            ]),
          ),
      ],
    );
  }
}

class _KindCard extends StatelessWidget {
  final String k;
  final KindMeta meta;
  final bool active;
  final VoidCallback onTap;
  const _KindCard({
    required this.k,
    required this.meta,
    required this.active,
    required this.onTap,
  });
  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    return PressScale(
      onTap: onTap,
      scale: 0.97,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: pal.cont,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: active ? AppColors.accent : Colors.transparent,
            width: 1.5,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: meta.color,
                borderRadius: BorderRadius.circular(10),
              ),
              alignment: Alignment.center,
              child: Iconify(meta.icon, size: 18, color: Colors.white),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(meta.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: pal.text)),
                  const SizedBox(height: 1),
                  Text(meta.sub,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11, color: pal.sub)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PriRow extends StatelessWidget {
  final String selected;
  final ValueChanged<String> onPick;
  const _PriRow({required this.selected, required this.onPick});
  @override
  Widget build(BuildContext context) {
    // Раньше `kPriMeta.entries.toList()[i]` вызывался по 4 раза на каждой
    // итерации цикла — на каждый rebuild Параметров аллоцировались
    // лишние List<MapEntry>. Кэшируем один раз.
    final entries = kPriMeta.entries.toList();
    return Row(
      children: [
        for (var i = 0; i < entries.length; i++) ...[
          Expanded(
            child: _PriCard(
              k: entries[i].key,
              meta: entries[i].value,
              active: selected == entries[i].key,
              onTap: () => onPick(entries[i].key),
            ),
          ),
          if (i != entries.length - 1) const SizedBox(width: 10),
        ],
      ],
    );
  }
}

class _PriCard extends StatelessWidget {
  final String k;
  final PriMeta meta;
  final bool active;
  final VoidCallback onTap;
  const _PriCard({
    required this.k,
    required this.meta,
    required this.active,
    required this.onTap,
  });
  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    return PressScale(
      onTap: onTap,
      scale: 0.97,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
        decoration: BoxDecoration(
          color: pal.cont,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: active ? AppColors.accent : Colors.transparent,
            width: 1.5,
          ),
        ),
        child: Column(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: meta.color,
                borderRadius: BorderRadius.circular(99),
              ),
              alignment: Alignment.center,
              child: Iconify(meta.icon, size: 20, color: Colors.white),
            ),
            const SizedBox(height: 8),
            Text(meta.label,
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: pal.text)),
          ],
        ),
      ),
    );
  }
}

class _LabelChips extends StatelessWidget {
  final BugItem bug;
  final VoidCallback onChanged;
  const _LabelChips({required this.bug, required this.onChanged});
  @override
  Widget build(BuildContext context) {
    final pal = context.pal;
    final all = <String>{...kSuggestedLabels, ...bug.labels}.toList();
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final l in all)
          PressScale(
            scale: 0.95,
            onTap: () {
              if (bug.labels.contains(l)) {
                bug.labels.remove(l);
              } else {
                bug.labels.add(l);
              }
              onChanged();
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              decoration: BoxDecoration(
                color: bug.labels.contains(l)
                    ? AppColors.accent
                    : pal.cont,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(l,
                  style: TextStyle(
                    color: bug.labels.contains(l) ? Colors.white : pal.text,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  )),
            ),
          ),
      ],
    );
  }
}
