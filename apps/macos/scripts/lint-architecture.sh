#!/usr/bin/env bash
#   ./scripts/lint-architecture.sh        (код 1 = межу порушено)

set -uo pipefail
cd "$(dirname "$0")/.."

SRC="Sources/Boltty"
fail=0
ran=0

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

ran=$((ran + 1))
CTRL="$SRC/UI/AgentPaletteController.swift"
if [[ ! -f "$CTRL" ]]; then
  die_unverifiable "немає $CTRL" "контролер перейменовано або перенесено — оновіть шлях у лінтері"
elif ! grep -qE 'weak var conversations' "$CTRL"; then
  report "AgentPaletteController більше не тримає conversations як weak" \
    "Панель позичає доступ до розмов, не володіє ними. Власник — AppDelegate.chat." \
    "$CTRL"
fi

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
    if [[ "$body" != *orderOut* ]]; then
      die_unverifiable "hide() у $hf:$hl більше не робить orderOut" \
        "Перевірка спирається на те, що вікно прибирається саме так. Спосіб змінився — перевірку теж треба змінити."
    fi
  fi
fi

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
tap_home="$SRC/Services/ModifierHotkeyMonitor.swift"
[[ -f "$tap_home" ]] || die_unverifiable "дім для CGEventTap ($tap_home) не існує" "файл перенесено — оновіть лінтер"
cget=$(code_only $(swift_files "$SRC") | grep -E '\bCGEventTap|\btapCreate\b' | grep -v "^$tap_home:" || true)
[[ -n "$cget" ]] && report "CGEventTap поза $tap_home" \
  "Хоткей зроблено через Carbon RegisterEventHotKey саме щоб не просити дозволів; tap — тільки для обраного ⌥⌘." "$cget"

ran=$((ran + 1))
hits=$(code_only $(swift_files "$SRC") | grep -E '"--last"|"--continue"' || true)
[[ -n "$hits" ]] && report "resume навздогад" \
  "Тільки --resume <збережений id>. --last бере чужу сесію, яку ніхто не вибирав." "$hits"

ran=$((ran + 1))
AGY="$SRC/Chat/Antigravity/AntigravityClient.swift"
MODES="$SRC/Chat/Agent/AgentCapabilities.swift|$SRC/Chat/ClaudeCode/ClaudeCodeClient.swift|$AGY"
hits=$(code_only $(swift_files "$SRC" | grep -v -E "^($MODES)$") \
  | grep -E '\bbypassPermissions\b|--dangerously-skip-permissions' || true)
[[ -n "$hits" ]] && report "повний bypass дозволів" \
  "Усе без питань — лише режим, який людина вибрала в чаті: таблиця PermissionMode і адаптер, що її застосовує." "$hits"

ran=$((ran + 1))
ALLOWED="$SRC/Chat/Agent/JSONLineProcess.swift|$SRC/Services/AgentInstaller.swift"
hits=$(code_only $(swift_files "$SRC") | grep -E '"-lc"|"(ba|z)?sh",[[:space:]]*"-c"|/bin/(ba|z)?sh"' | grep -vE "^($ALLOWED):" || true)
[[ -n "$hits" ]] && report "новий виклик оболонки" \
  "Промпти йдуть у stdin, не в sh. Відомих два: пошук бінарника і встановлювач агента, скрипт якого йде в stdin." "$hits"

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
