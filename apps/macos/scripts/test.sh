#!/bin/zsh
set -euo pipefail

# Runs the test suites that cover what changed, and nothing else.
#
# The full bundle is 863 tests. Almost none of them can be moved by a given
# edit, and running them all after each one spends a minute to learn what ten
# seconds already said. `xcodebuild` has always been able to run a subset
# (`-only-testing:`); what it cannot do is work out *which* subset. This does.
#
# **The mapping is derived, not written down.** A table of "file -> suite"
# would be wrong within a week: files get renamed, suites get split, and a
# stale table is worse than none because it quietly runs the wrong tests. So
# the link is made the way a reader would make it — by name. For each changed
# source file it takes the types declared in it, then asks which test files
# mention any of them. Rename a type and the link follows the rename; add a
# suite and it is found the first time it names what it tests.
#
# It over-selects rather than under-selects. A type named in six test files
# runs six suites, which is the safe direction to be wrong in: the cost is
# seconds, and the cost of the other direction is a green run that proved
# nothing. When the selection reaches most of the bundle it stops pretending
# and runs the bundle.
#
#   ./scripts/test.sh              # suites covering the working tree's changes
#   ./scripts/test.sh --since main # ... covering everything since a ref
#   ./scripts/test.sh -n           # print the selection, run nothing
#   ./scripts/test.sh --for Sources/Boltty/UI/AgentPaletteView.swift
#   ./scripts/test.sh --all        # the whole bundle, the end-of-task sweep
#   ./scripts/test.sh BolttyAIPreviewCardTests ...   # named suites
#
# UI tests are not selected: they drive the menu bar and need a logged-in
# session, so they stay an explicit choice (see README).

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
    -h|--help) sed -n '3,30p' "$0" | sed 's|^# \{0,1\}||'; exit 0 ;;
    -*) print -u2 "unknown flag: $1"; exit 2 ;;
    *) named_suites+=("$1"); shift ;;
  esac
done

# --- what changed ------------------------------------------------------------
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

# --- which suites cover them -------------------------------------------------
suites=()

# A file that declares no `XCTestCase` is a helper, not a suite, and grep says
# so by exiting 1 — which under `set -e` would end the run. Both lookups below
# swallow that: "found nothing" is an answer here, not a failure.
collect_suites_in() {  # file -> the XCTestCase classes it declares
  grep -Eo '^[[:space:]]*(final )?class [A-Za-z0-9_]+[[:space:]]*:[[:space:]]*XCTestCase' "$1" 2>/dev/null \
    | awk '{ for (i = 1; i <= NF; i++) if ($i == "class") { gsub(/:.*/, "", $(i+1)); print $(i+1) } }' \
    || true
}

if (( ${#named_suites} )); then
  # **A misspelled suite name must not read as a pass.** `xcodebuild` exits 0
  # when `-only-testing` matches nothing at all — it runs zero tests and calls
  # that success — so a typo here would be the quietest possible green run.
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
    # UI tests drive the real mouse and keyboard, so they are never picked
    # automatically — only by name, when someone asks for screenshots.
    [[ $f == Tests/BolttyUITests/* ]] && continue
    if [[ $f == Tests/* ]]; then
      # A changed test file tests itself: no lookup, just run it.
      suites+=("${(@f)$(collect_suites_in "$f")}")
      continue
    fi
    # The types the file declares, plus its own name — files that are all
    # `extension` carry the subject in the filename and nowhere else.
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

  # Most of the bundle selected is the bundle: stop paying for the arguments.
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

# `set +e` around the pipeline, and `pipestatus` read before anything else
# runs: with `set -e` a failing run would abort here, and a trailing `|| true`
# would overwrite `pipestatus` with its own. Both were true of the first draft,
# which reported every failing run as a pass.
set +e
xcodebuild -scheme Boltty -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath .derivedData "${only[@]}" test \
  | grep -E "error:|warning: .*(never used|unused)|Test Case .* failed|Executed [0-9]+ test|\*\* TEST"
# Not `status`: zsh reserves that name (it is `$?`), and assigning to it fails
# silently enough that this script reported a failing run as a pass.
run_status=${pipestatus[1]}
set -e
exit $run_status
