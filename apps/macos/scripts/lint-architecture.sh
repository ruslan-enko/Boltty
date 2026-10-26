#!/usr/bin/env bash
# scripts/lint-architecture.sh
#
#   ./scripts/lint-architecture.sh        (код 1 = межу порушено)
#
# МЕЖІ ВИВЕДЕНІ З АУДИТУ, НЕ З ПЛАНУ. Перша версія цього скрипта перевіряла
# каталоги Sources/BolttyCore, BolttyModel, BolttyUI, BolttyShell — межі
# майбутнього розбиття на SPM-пакети. План міграції це розбиття скасував:
# 51 670 рядків в одному таргеті, межі вже дотримані фактично.
# Тож усі перевірки пропускались, скрипт завжди виходив з кодом 1, і зеленим
# стати не міг у принципі.
#
# Тепер перевіряється те, що аудит знайшов і що AGENTS.md назвав інваріантами,
# які тримаються. Усі вони сьогодні чисті — саме тому вони коштують нуль
# і ловлять регрес, а не наявний борг.
#
# ─────────────────────────────────────────────────────────────────────────
# ПРИНЦИП: ПЕРЕВІРКА, ЯКА НЕ ЗМОГЛА ВИКОНАТИСЬ, НЕ РАХУЄТЬСЯ УСПІШНОЮ.
#
# Це не педантизм, це двічі оплачений урок. Каталоги, яких немає, давали
# зелений лінтер. Правило з обрізаним regex у lint-design.sh мовчки не ловило
# жодного з девʼяти літеральних кольорів, бо grep падав у /dev/null.
# Тому тут немає жодного тихого `skip`: якщо ціль перевірки не знайдена —
# це падіння з поясненням, а не пропуск.
# ─────────────────────────────────────────────────────────────────────────

set -uo pipefail
cd "$(dirname "$0")/.."

SRC="Sources/Boltty"
fail=0
ran=0

# Коментарі не рахуються: згадка `bypassPermissions` у поясненні, чому його
# тут НЕ використовують, не є порушенням. Це вже давало хибне падіння на
# `NSPanel` у коментарі.
#
# Межа методу: `//` всередині рядкового літерала (напр. "https://…") теж
# обрізається. Це втрата в бік пропуску, не хибного падіння, і на цій базі
# жодного такого місця немає.
code_only() {
  awk '
    { sub(/\/\/.*/, "") }
    /^[[:space:]]*\*/  { next }
    /^[[:space:]]*\/\*/ { next }
    { print FILENAME ":" FNR ":" $0 }
  ' "$@" 2>/dev/null
}

swift_files() {
  find "$@" -name '*.swift' -type f 2>/dev/null | sort
}

die_unverifiable() {
  echo ""
  echo "✗ ПЕРЕВІРКУ НЕМОЖЛИВО ВИКОНАТИ: $1"
  echo "  → $2"
  echo "  Нездійсненна перевірка не є успішною. Полагодьте лінтер або код."
  fail=1
}

report() {
  echo ""
  echo "✗ $1"
  echo "  → $2"
  printf '%s\n' "$3" | sed 's/^/    /'
  fail=1
}

echo "Architecture — інваріанти з AGENTS.md"

# ── 1 · UI не торкається машинерії процесів ───────────────────────────────
# Головна межа. Аудит: ланцюг Controller → Coordinator → Engine → Client,
# власність у AppDelegate.chat. У UI/ не має бути ані запуску процесу, ані
# згадки конкретного адаптера — інакше виконання почало переповзати у View.
ran=$((ran + 1))
if [[ ! -d "$SRC/UI" ]]; then
  die_unverifiable "немає каталогу $SRC/UI" "структуру змінено — перевірку треба переписати під нову"
else
  hits=$(code_only $(swift_files "$SRC/UI") \
    | grep -E 'Process\(|JSONLineProcess|ClaudeCodeClient|CodexClient|GrokClient|AntigravityClient|OpenCodeClient' \
    || true)
  [[ -n "$hits" ]] && report \
    "UI/ торкається машинерії процесів" \
    "Виконання не належить View. UI говорить зі стором і координатором, не з адаптерами." \
    "$hits"
fi

# ── 2 · Контролер панелі не володіє розмовами ─────────────────────────────
# Мʼякша, друга лінія до перевірки №1: власність лишається в AppDelegate.
ran=$((ran + 1))
CTRL="$SRC/UI/AgentPaletteController.swift"
if [[ ! -f "$CTRL" ]]; then
  die_unverifiable "немає $CTRL" "контролер перейменовано або перенесено — оновіть шлях у лінтері"
elif ! grep -qE 'weak var conversations' "$CTRL"; then
  report "AgentPaletteController більше не тримає conversations як weak" \
    "Панель позичає доступ до розмов, не володіє ними. Власник — AppDelegate.chat." \
    "$CTRL"
fi

# ── 3 · hide() тільки прибирає вікно ──────────────────────────────────────
# НАЙКРИХКІША ПЕРЕВІРКА ЗІ СПИСКУ: вона розбирає тіло функції.
# Перейменують hide() або розібʼють на дві — і вона мовчки позеленіє.
# Саме тому «не знайшов hide()» тут є ПАДІННЯМ, а не пропуском.
ran=$((ran + 1))
decl=$(grep -Hn 'func hide()' "$CTRL" | head -1 || true)
if [[ -z "$decl" ]]; then
  die_unverifiable "не знайдено жодного 'func hide()' у $SRC" \
    "Інваріант «приховування панелі не чіпає процеси» більше нічим не перевіряється. Якщо метод перейменували — оновіть лінтер разом із ним."
else
  hf="${decl%%:*}"; rest="${decl#*:}"; hl="${rest%%:*}"
  body=$(awk -v start="$hl" '
    NR < start { next }
    { sub(/\/\/.*/, "")
      o = gsub(/\{/, "{"); c = gsub(/\}/, "}")
      depth += o - c
      print
      if (o > 0) seen = 1
      if (seen && depth <= 0) exit }' "$hf")
  if [[ -z "$body" ]]; then
    die_unverifiable "тіло hide() у $hf:$hl не розібралось" "змінилось форматування — полагодьте розбір"
  else
    kill=$(printf '%s' "$body" | grep -nE '\bterminate\(|\bshutdown\(|\bcloseInput\(|requestStopForAll|prepareForTermination' || true)
    [[ -n "$kill" ]] && report \
      "hide() завершує процеси ($hf:$hl)" \
      "Приховування панелі ≠ скасування задачі. Єдиний шлях завершення — applicationShouldTerminate." \
      "$kill"
    if ! printf '%s' "$body" | grep -q 'orderOut'; then
      die_unverifiable "hide() у $hf:$hl більше не робить orderOut" \
        "Перевірка спирається на те, що вікно прибирається саме так. Спосіб змінився — перевірку теж треба змінити."
    fi
  fi
fi

# ── 4 · SwiftUI-стан живе тільки в Settings ───────────────────────────────
# Перевіряється МІСЦЕ, не кількість. Число застаріє тієї миті, коли Settings
# обросте ще одним полем, і тиск буде «просто підніми межу». Справжній
# інваріант не кількісний: SwiftUI-стан припустимий лише під UI/Settings/.
ran=$((ran + 1))
WRAP='@State|@StateObject|@ObservedObject|@EnvironmentObject'
if [[ ! -d "$SRC" ]]; then
  die_unverifiable "немає каталогу $SRC" "структуру змінено"
else
  all=$(code_only $(swift_files "$SRC") | grep -E "$WRAP" || true)
  stray=$(printf '%s' "$all" | grep -v "^$SRC/UI/Settings/" | grep -E "$WRAP" || true)
  total=$(printf '%s' "$all" | grep -cE "$WRAP" || true)
  [[ -n "$stray" ]] && report \
    "SwiftUI-стан поза UI/Settings/" \
    "Істина про виконання живе у сторі (Conversation.lastKnownState), не в обгортці view." \
    "$stray"
  echo "  ℹ SwiftUI-обгорток стану: $total, усі в UI/Settings/"
fi

# ── 5 · Символи оболонки не розповзаються ─────────────────────────────────
# Кожен символ має рівно один дім. CGEventTap — тільки ModifierHotkeyMonitor:
# глобальний хоткей зроблено через Carbon, без дозволів, а tap слухає лише
# обраний людиною ⌥⌘ (з Input Monitoring).
ran=$((ran + 1))
confine() {
  local sym="$1" home="$2" why="$3"
  local hits
  hits=$(code_only $(swift_files "$SRC") | grep -E "\b$sym\b" | grep -v "^$home:" || true)
  [[ -n "$hits" ]] && report "$sym поза $home" "$why" "$hits"
  if [[ -n "$home" && "$home" != "—" && ! -f "$home" ]]; then
    die_unverifiable "дім для $sym ($home) не існує" "файл перенесено — оновіть лінтер"
  fi
}
confine NSPanel             "$SRC/UI/KeyablePanel.swift"            "Панель — один тип, не розсип NSPanel по view."
confine NSStatusItem        "$SRC/UI/StatusBarController.swift"     "Menu bar живе в одному контролері."
confine RegisterEventHotKey "$SRC/Services/GlobalHotkeyService.swift" "Глобальний хоткей реєструється в одному місці."
# Виняток: ⌥⌘ без клавіші Carbon не тримає, тож його
# слухає listen-only tap — лише в цьому файлі, лише коли людина сама обрала
# такий хоткей і дала Input Monitoring. Ніде більше.
tap_home="$SRC/Services/ModifierHotkeyMonitor.swift"
[[ -f "$tap_home" ]] || die_unverifiable "дім для CGEventTap ($tap_home) не існує" "файл перенесено — оновіть лінтер"
cget=$(code_only $(swift_files "$SRC") | grep -E '\bCGEventTap|\btapCreate\b' | grep -v "^$tap_home:" || true)
[[ -n "$cget" ]] && report "CGEventTap поза $tap_home" \
  "Хоткей зроблено через Carbon RegisterEventHotKey саме щоб не просити дозволів; tap — тільки для обраного ⌥⌘." "$cget"

# ── 6 · Resume тільки за збереженим id ────────────────────────────────────
# Аудит: нуль входжень. AGENTS.md вимагає resume за збереженим session
# reference. Лінтер тримає цей нуль.
ran=$((ran + 1))
hits=$(code_only $(swift_files "$SRC") | grep -E '"--last"|"--continue"' || true)
[[ -n "$hits" ]] && report "resume навздогад" \
  "Тільки --resume <збережений id>. --last бере чужу сесію, яку ніхто не вибирав." "$hits"

# ── 7 · Жодного повного bypass дозволів ───────────────────────────────────
# Claude Code дістає acceptEdits. Аудит: bypassPermissions зустрічається рівно
# один раз і саме в коментарі, який пояснює, чому його не використовують.
#
# `--dangerously-skip-permissions` — рівно в одному місці:
# AntigravityClient, і тільки поруч зі шлюзом
# (`AntigravityPermissionGate`). У print mode `agy` не вміє питати, а
# PreToolUse-хук може заборонити, але не дозволити — тож дозволяє все `agy`,
# а вирішує кожен виклик Boltty через хук. Будь-де ще прапор — порушення.
ran=$((ran + 1))
GATED="$SRC/Chat/Antigravity/AntigravityClient.swift"
hits=$(code_only $(swift_files "$SRC" | grep -v "^$GATED$") \
  | grep -E '\bbypassPermissions\b|--dangerously-skip-permissions' || true)
if [[ -f "$GATED" ]] && grep -q -- '--dangerously-skip-permissions' "$GATED" \
   && ! grep -q 'AntigravityPermissionGate' "$GATED"; then
  hits+=$'\n'"$GATED: прапор без шлюзу"
fi
[[ -n "$hits" ]] && report "повний bypass дозволів" \
  "acceptEdits — не те саме. Auto-approve дозволений тільки до рівня редагувань." "$hits"

# ── 8 · Інтерполяція в оболонку — тільки в одному відомому місці ──────────
# Пункт G плану міграції: `sh -lc "command -v \(program)"`. Сьогодні безпечно —
# імʼя з конфігу. Лінтер не дає цьому шаблону розійтись, поки його не приберуть.
# OpenCode шукається тим самим `JSONLineProcess.locate`, що й решта.
ran=$((ran + 1))
ALLOWED="$SRC/Chat/Agent/JSONLineProcess.swift"
hits=$(code_only $(swift_files "$SRC") | grep -E '"-lc"|"-c"' | grep -vE "^($ALLOWED):" || true)
[[ -n "$hits" ]] && report "новий виклик оболонки" \
  "Промпти йдуть у stdin, не в sh. Один відомий виклик — пошук бінарника, і він на обліку." "$hits"

# ── Підсумок ──────────────────────────────────────────────────────────────
echo ""
if (( ran == 0 )); then
  echo "✗ Жодної перевірки не виконано. Це не «чисто», це зламаний лінтер."
  exit 1
fi
if (( fail == 0 )); then
  echo "✓ Architecture clean ($ran перевірок)"
else
  echo "Інваріанти описані в AGENTS.md, *Invariants the audit measured*"
fi
exit $fail
