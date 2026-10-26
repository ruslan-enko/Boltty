#!/usr/bin/env bash
# scripts/lint-design.sh
#
#   ./scripts/lint-design.sh                    перевірити (код 1 = нові порушення)
#   ./scripts/lint-design.sh --update-baseline  зафіксувати поточний борг
#
# ПРАВИЛА ПІД APPKIT. Перша версія цього скрипта шукала SwiftUI-модифікатори
# (.cornerRadius, .blur, .ultraThinMaterial) і на цій кодовій базі давала нуль збігів —
# бо UI майже цілком AppKit: 19 NSView проти 5 View. Лінтер був зелений і марний.
# Тепер правила ловлять те, що тут справді є: layer.cornerRadius із літералом,
# NSVisualEffectView, CIGaussianBlur, NSColor із компонент, systemFont(ofSize:).
# SwiftUI-правила лишені — вони спрацюють на новому коді.
#
# BASELINE. Старий борг записується у scripts/lint-baseline.txt і збірку не валить;
# падає тільки НОВЕ. Храповик: гірше стати не може, краще — поступово.

set -uo pipefail
cd "$(dirname "$0")/.."

BASELINE="scripts/lint-baseline.txt"
MODE="${1:-check}"

# --- Де шукати ------------------------------------------------------------
if [[ -d "Sources/Boltty" ]]; then
  SEARCH=(Sources/Boltty)           # наявний застосунок
elif [[ -d "Sources/BolttyUI" ]]; then
  SEARCH=(Sources/BolttyUI Sources/BolttyShell)
  [[ -d App ]] && SEARCH+=(App)
else
  SEARCH=(.)
fi

# Місця, яким ці значення належать за визначенням.
EXCLUDE='(^|/)(\.build|DerivedData|Tests|BolttyDesign|BolttyTypeface|MascotPalette|\.git)'

swift_files() {
  find "${SEARCH[@]}" -name '*.swift' -type f 2>/dev/null | grep -Ev "$EXCLUDE" | sort
}

# --- Правила: rule|regex|підказка ----------------------------------------
RULES=(
# AppKit — те, що реально є в цій базі
# `[0-9.]*[1-9]` — літерал, у якому є хоч одна ненульова цифра. `= 0` це не
# радіус із макета, а «без кута»: вимкнути власний кут шару, щоб силует
# малював хтось інший. Ловити його означало питати «звідки взялась ця
# двійка» там, де двійки немає.
'layer-radius|\.cornerRadius[[:space:]]*=[[:space:]]*[0-9.]*[1-9]|радіус літералом — Radius.* з BolttyDesign'
'nsvisualeffect|NSVisualEffectView|на macOS 26 це NSGlassEffectView / .glassEffect через BolttyDesign'
'cifilter-blur|CIFilter\(name:[[:space:]]*"CIGaussianBlur"|ручний блюр це не скло — системний матеріал'
'nscolor-components|NSColor\((srgbRed|red|calibratedRed|deviceRed|hue|white):|Palette.* — кольори в asset catalog'
'nsfont-size|NSFont\.systemFont\(ofSize:|BolttyTypeface / .boltty(_:) — інакше Dynamic Type ігнорується'

# SwiftUI — нуль збігів сьогодні, спрацюють на новому коді
# `\([^:]*\)` — без міток аргументів, бо модифікатор SwiftUI їх не має:
# `.cornerRadius(12)`. Наша власна `PromptChipCell.cornerRadius(forHeight:)`
# має мітку, і саме вона два роки стояла в baseline як борг, будучи
# звичайним викликом функції.
'cornerRadius|\.cornerRadius\([^:]*\)|ConcentricRectangle() або RoundedRectangle(cornerRadius:style: .continuous)'
'material|\.(ultraThin|thin|regular|thick|ultraThick)Material|.bolttySurface(...) — матеріал обирає BolttyDesign'
'blur|\.blur\(radius:|blur() це не скло — .glassEffect(...)'
'font-custom|\.font\(\.custom\(|.boltty(_:weight:) — SF Pro Rounded через design: .rounded'
'font-size|\.font\(\.system\(size:|фіксований кегль ігнорує Dynamic Type'
'hex|0x[0-9A-Fa-f]{6}|Palette.* (дані палітри — виняток, їм місце в BolttyDesign)'
)

# Поля розділені `|`, але regex сам містить `|` — альтернації. Тому ім'я
# береться до ПЕРШОГО роздільника, підказка після ОСТАННЬОГО, а regex — усе між.
# Наївне `${rest%%|*}` різало regex посеред альтернації: `nscolor-components`
# ставав `NSColor\((srgbRed`, grep падав з `mismatched (`, stderr ішов у
# /dev/null, і правило мовчки не ловило жодного з 9 літеральних кольорів.
rule_name()  { printf '%s' "${1%%|*}"; }
rule_hint()  { printf '%s' "${1##*|}"; }
rule_regex() { local h="${1##*|}"; local r="${1#*|}"; printf '%s' "${r%"|$h"}"; }

# Regex, який не компілюється, — це правило, якого немає. Мовчазно зелене
# правило гірше за відсутнє, тому лінтер відмовляється працювати.
validate_rules() {
  local bad=0 name regex
  for entry in "${RULES[@]}"; do
    name=$(rule_name "$entry"); regex=$(rule_regex "$entry")
    printf '' | grep -E "$regex" >/dev/null 2>&1
    if (( $? > 1 )); then
      echo "✗ [$name] regex не компілюється: $regex" >&2
      bad=1
    fi
  done
  if (( bad )); then
    echo "" >&2
    echo "Лінтер зупинено. Правило, що не компілюється, мовчки пропускає все." >&2
    exit 2
  fi
}

collect() {
  local files; files=$(swift_files)
  [[ -z "$files" ]] && return 0
  for entry in "${RULES[@]}"; do
    local rule regex
    rule=$(rule_name "$entry"); regex=$(rule_regex "$entry")
    echo "$files" | while read -r f; do
      # Коментарі не рахуються: згадка в поясненні — не порушення.
      if grep -E "$regex" "$f" 2>/dev/null | grep -qvE '^\s*(//|\*|/\*)'; then
        echo "$f:$rule"
      fi
    done
  done
}

hint_for() {
  for entry in "${RULES[@]}"; do
    [[ "$(rule_name "$entry")" == "$1" ]] && { rule_hint "$entry"; echo; return; }
  done
}

validate_rules
CURRENT=$(collect | sort -u)

if [[ "$MODE" == "--update-baseline" ]]; then
  mkdir -p scripts
  printf '%s\n' "$CURRENT" | grep -v '^$' > "$BASELINE"
  echo "Записано $(grep -c . "$BASELINE" 2>/dev/null || echo 0) рядків у $BASELINE"
  echo "Комітьте його. Він має тільки зменшуватись."
  exit 0
fi

if [[ -f "$BASELINE" ]]; then
  NEW=$(comm -13 <(sort -u "$BASELINE") <(printf '%s\n' "$CURRENT" | grep -v '^$'))
  FIXED=$(comm -23 <(sort -u "$BASELINE") <(printf '%s\n' "$CURRENT" | grep -v '^$'))
else
  NEW=$(printf '%s\n' "$CURRENT" | grep -v '^$')
  FIXED=""
fi

if [[ -n "$FIXED" ]]; then
  echo "✓ Виправлено з минулого разу:"
  echo "$FIXED" | sed 's/^/    /'
  echo "  → --update-baseline, щоб борг не повернувся"
  echo ""
fi

if [[ -z "$NEW" ]]; then
  if [[ -f "$BASELINE" ]]; then
    left=$(grep -c . "$BASELINE" 2>/dev/null || echo 0)
    echo "✓ Нових порушень немає. У baseline лишилось: $left"
    [[ "$left" == "0" ]] && echo "  → baseline порожній, видаліть $BASELINE"
  else
    echo "✓ Design contract clean"
  fi
  exit 0
fi

echo "✗ Нові порушення дизайн-контракту:"
echo ""
printf '%s\n' "$NEW" | while IFS=: read -r file rule; do
  echo "  $file"
  echo "    [$rule] $(hint_for "$rule")"
done
echo ""
echo "Правила — AGENTS.md, *Design contract (AppKit)*. Якщо це борг у чужому файлі — --update-baseline,"
echo "але не для коду, який ви щойно написали."
exit 1
