#!/bin/zsh
set -euo pipefail

# Runs the test suites that cover what changed, and nothing else.
#   ./scripts/test.sh              # suites covering the working tree's changes
#   ./scripts/test.sh --since main # ... covering everything since a ref
#   ./scripts/test.sh -n           # print the selection, run nothing
#   ./scripts/test.sh --for Sources/Boltty/UI/AgentPaletteView.swift
#   ./scripts/test.sh --all        # the whole bundle, the end-of-task sweep
#   ./scripts/test.sh BolttyAIPreviewCardTests ...   # named suites

root=${0:a:h:h}
cd "$root"

tests_dir="Tests/BolttyTests"
dry_run=0
mode=worktree
since_ref=""
named_suites=()
explicit_files=()

while (( $# )); do
  case "$1" in
    --all) mode=all; shift ;;
    -n|--dry-run|--list) dry_run=1; shift ;;
    --since) mode=since; since_ref="${2:-}"; shift 2 ;;
    --for) explicit_files+=("${2:-}"); mode=files; shift 2 ;;
    -h|--help) sed -n '4,10p' "$0" | sed 's|^# \{0,1\}||'; exit 0 ;;
    -*) print -u2 "unknown flag: $1"; exit 2 ;;
    *) named_suites+=("$1"); shift ;;
  esac
done

changed=()
if (( ${#named_suites} == 0 )) && [[ $mode != all ]]; then
  if [[ $mode == files ]]; then
    changed=($explicit_files)
  elif [[ $mode == since ]]; then
    [[ -n $since_ref ]] || { print -u2 "--since needs a ref"; exit 2 }
    changed=("${(@f)$(git diff --name-only "$since_ref"...HEAD; git status --porcelain | cut -c4-)}")
  else
    changed=("${(@f)$(git status --porcelain | cut -c4- | sed 's/.* -> //')}")
  fi
  changed=(${(u)changed})
  changed=(${changed:#})
fi

swift_files=()
for f in $changed; do
  local_path=${f#apps/macos/}
  [[ $local_path == Sources/*.swift || $local_path == Tests/*.swift ]] || continue
  [[ -f $local_path ]] && swift_files+=("$local_path")
done

suites=()

# grep exits 1 when it finds nothing, which under `set -e` would end the run.
collect_suites_in() {  # file -> the XCTestCase classes it declares
  grep -Eo '^[[:space:]]*(final )?class [A-Za-z0-9_]+[[:space:]]*:[[:space:]]*XCTestCase' "$1" 2>/dev/null \
    | awk '{ for (i = 1; i <= NF; i++) if ($i == "class") { gsub(/:.*/, "", $(i+1)); print $(i+1) } }' \
    || true
}

if (( ${#named_suites} )); then
  # `xcodebuild` exits 0 when `-only-testing` matches nothing.
  known=()
  for f in $tests_dir/*.swift(N); do known+=("${(@f)$(collect_suites_in "$f")}") done
  for s in $named_suites; do
    (( ${known[(I)$s]} )) || { print -u2 "no such suite: $s"; exit 2 }
  done
  suites=($named_suites)
elif [[ $mode == all ]]; then
  suites=()
else
  symbols=()
  for f in $swift_files; do
    [[ $f == Tests/BolttyUITests/* ]] && continue
    if [[ $f == Tests/* ]]; then
      suites+=("${(@f)$(collect_suites_in "$f")}")
      continue
    fi
    symbols+=("${f:t:r}")
    symbols+=("${(@f)$(grep -Eo '^[[:space:]]*(public |private |internal |fileprivate |final |@MainActor )*(class|struct|enum|actor|protocol|extension) [A-Za-z0-9_]+' "$f" \
      | awk '{ print $NF }' || true)}")
  done
  symbols=(${(u)symbols})
  symbols=(${symbols:#})

  matched_files=()
  for symbol in $symbols; do
    (( ${#symbol} >= 4 )) || continue          # `Key`, `URL`: too common to mean anything
    matched_files+=("${(@f)$(grep -lw -- "$symbol" $tests_dir/*.swift 2>/dev/null || true)}")
  done
  matched_files=(${(u)matched_files})
  matched_files=(${matched_files:#})

  all_test_files=($tests_dir/*.swift(N))
  if (( ${#matched_files} * 3 >= ${#all_test_files} * 2 )); then
    print "selection reached ${#matched_files}/${#all_test_files} test files — running the whole bundle"
    suites=()
  else
    for f in $matched_files; do suites+=("${(@f)$(collect_suites_in "$f")}"); done
  fi
fi

suites=(${(u)suites})
suites=(${suites:#})

if (( ${#swift_files} == 0 )) && (( ${#named_suites} == 0 )) && [[ $mode != all ]]; then
  print "no Swift changed — nothing to test"
  exit 0
fi

only=()
for s in $suites; do only+=("-only-testing:BolttyTests/$s") done
(( ${#only} )) || only=("-only-testing:BolttyTests")

print "suites: ${suites:-<the whole bundle>}"
(( dry_run )) && exit 0

# `pipestatus` is read before anything else: `|| true` would overwrite it.
set +e
xcodebuild -scheme Boltty -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath .derivedData -testLanguage en -testRegion US "${only[@]}" test \
  | grep -E "error:|warning: .*(never used|unused)|Test Case .* failed|Executed [0-9]+ test|\*\* TEST"
# Not `status`: zsh reserves that name.
run_status=${pipestatus[1]}
set -e
exit $run_status
