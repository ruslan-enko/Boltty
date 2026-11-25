#!/usr/bin/env bash
#   ./scripts/lint-design.sh                    перевірити (код 1 = нові порушення)
#   ./scripts/lint-design.sh --update-baseline  зафіксувати поточний борг

set -uo pipefail
cd "$(dirname "$0")/.."

BASELINE="scripts/lint-baseline.txt"
MODE="${1:-check}"

if [[ -d "Sources/Boltty" ]]; then
  SEARCH=(Sources/Boltty)           # наявний застосунок
elif [[ -d "Sources/BolttyUI" ]]; then
  SEARCH=(Sources/BolttyUI Sources/BolttyShell)
  [[ -d App ]] && SEARCH+=(App)
else
  SEARCH=(.)
fi

EXCLUDE='(^|/)(\.build|DerivedData|Tests|BolttyDesign|BolttyBrand|BolttyTypeface|MascotPalette|\.git)'

swift_files() {
  find "${SEARCH[@]}" -name '*.swift' -type f 2>/dev/null | grep -Ev "$EXCLUDE" | sort
}

RULES=(
'layer-radius|\.cornerRadius[[:space:]]*=[[:space:]]*[0-9.]*[1-9]|радіус літералом — Radius.* з BolttyDesign'
'nsvisualeffect|NSVisualEffectView|на macOS 26 це NSGlassEffectView / .glassEffect через BolttyDesign'
'cifilter-blur|CIFilter\(name:[[:space:]]*"CIGaussianBlur"|ручний блюр це не скло — системний матеріал'
'nscolor-components|NSColor\((srgbRed|red|calibratedRed|deviceRed|hue|white):|Palette.* — кольори в asset catalog'
'nsfont-size|NSFont\.systemFont\(ofSize:|BolttyTypeface / .boltty(_:) — інакше Dynamic Type ігнорується'

'cornerRadius|\.cornerRadius\([^:]*\)|ConcentricRectangle() або RoundedRectangle(cornerRadius:style: .continuous)'
'material|\.(ultraThin|thin|regular|thick|ultraThick)Material|.bolttySurface(...) — матеріал обирає BolttyDesign'
'blur|\.blur\(radius:|blur() це не скло — .glassEffect(...)'
'font-custom|\.font\(\.custom\(|.boltty(_:weight:) — SF Pro Rounded через design: .rounded'
'font-size|\.font\(\.system\(size:|фіксований кегль ігнорує Dynamic Type'
'hex|0x[0-9A-Fa-f]{6}|Palette.* (дані палітри — виняток, їм місце в BolttyDesign)'
)

# The regex holds `|` too: the name ends at the first one, the hint starts after the last.
rule_name()  { printf '%s' "${1%%|*}"; }
rule_hint()  { printf '%s' "${1##*|}"; }
rule_regex() { local h="${1##*|}"; local r="${1#*|}"; printf '%s' "${r%"|$h"}"; }

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
