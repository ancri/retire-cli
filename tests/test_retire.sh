#!/bin/sh
# Exercises the full lifecycle and every detection signal against a scratch ledger.
# Touches nothing outside its own temp directory.
set -eu

HERE=$(cd "$(dirname "$0")/.." && pwd)
RETIRE="$HERE/retire"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

RETIRE_STATE="$TMP/state"
RETIRE_SEARCH_ROOTS="$TMP/roots"
export RETIRE_STATE RETIRE_SEARCH_ROOTS

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
check(){ # check <desc> <pattern> <output>
  if printf '%s' "$3" | grep -q "$2"; then ok "$1"; else
    bad "$1"; printf '       expected /%s/ in:\n%s\n' "$2" "$3"; fi
}

mkdir -p "$TMP/roots" "$TMP/tree/sub"
echo aaa > "$TMP/tree/one.txt"
echo bbb > "$TMP/tree/sub/two.txt"

echo "retire test suite"

# --- help and metadata ------------------------------------------------------
check "bare invocation prints usage"  "usage: retire" "$("$RETIRE" 2>&1)"
check "'?' prints usage"              "usage: retire" "$("$RETIRE" '?' 2>&1)"
check "'help put' is command help"    "usage: retire put" "$("$RETIRE" help put 2>&1)"
check "--version reports a version"   "retire [0-9]" "$("$RETIRE" --version 2>&1)"
out=$("$RETIRE" bogus 2>&1) && bad "unknown command should exit non-zero" \
                            || check "unknown command errors" "unknown command" "$out"
check "doctor reports platform"       "platform" "$("$RETIRE" doctor 2>&1)"

# --- put and baseline -------------------------------------------------------
check "put reports the rename" "RETIRED" "$("$RETIRE" put "$TMP/tree" --reason test --review-in 30d 2>&1)"
R=$(ls -d "$TMP"/tree.RETIRED.* 2>/dev/null || true)
[ -d "$R" ] && ok "retired directory exists" || bad "retired directory missing"
[ ! -e "$TMP/tree" ] && ok "original path is gone" || bad "original path still present"
check "list shows the entry" "tree" "$("$RETIRE" list 2>&1)"
check "clean review holds"   "holding" "$("$RETIRE" review 2>&1)"

# --- detection: write -------------------------------------------------------
echo more >> "$R/one.txt"
out=$("$RETIRE" review 2>&1 || true)
check "write is flagged TOUCHED" "TOUCHED: contents modified" "$out"
check "write is flagged DRIFT"   "DRIFT: total bytes"         "$out"
"$RETIRE" rebaseline tree >/dev/null

# --- detection: add ---------------------------------------------------------
echo new > "$R/three.txt"
check "added file changes entry count" "DRIFT: entry count" "$("$RETIRE" review 2>&1 || true)"
"$RETIRE" rebaseline tree >/dev/null

# --- detection: delete ------------------------------------------------------
rm "$R/three.txt"
check "deleted file changes entry count" "DRIFT: entry count" "$("$RETIRE" review 2>&1 || true)"
"$RETIRE" rebaseline tree >/dev/null

# --- detection: read (simulated, past the slack window) ---------------------
if touch -a -d '+3 days' "$R/one.txt" 2>/dev/null || touch -a -t "$(date -v+3d +%Y%m%d%H%M 2>/dev/null || echo 203001010000)" "$R/one.txt" 2>/dev/null; then
  check "future read is flagged" "TOUCHED: read" "$("$RETIRE" review 2>&1 || true)"
  "$RETIRE" rebaseline tree >/dev/null
else
  printf '  skip touch -a unsupported here\n'
fi

# --- review must not trip over its own traversal -----------------------------
# os.walk calls readdir on every directory, which updates that directory's atime.
# Without an explicit floor, review reports its own scan as an external read.
# Age every entry, files included: a freshly created file's atime would otherwise
# dominate the tree max and mask the effect entirely.
if find "$R" -exec touch -a -d '3 days ago' {} + 2>/dev/null; then
  "$RETIRE" rebaseline tree >/dev/null              # this walk bumps dir atimes
  out=$("$RETIRE" review 2>&1 || true)
  if printf '%s' "$out" | grep -q "TOUCHED: read"; then
    bad "review reported its own walk as a read"; printf '%s\n' "$out"
  else ok "review does not report its own walk"; fi
  check "and stays quiet on a repeat run" "holding" "$("$RETIRE" review 2>&1 || true)"
else
  printf '  skip  touch -a unsupported here\n'
fi

# --- detection: references --------------------------------------------------
echo "this mentions tree by name" > "$TMP/roots/code.py"
check "new reference is flagged" "REFERENCED" "$("$RETIRE" review 2>&1 || true)"
"$RETIRE" ack tree >/dev/null
check "ack silences it" "holding" "$("$RETIRE" review 2>&1 || true)"

# --- detection: unverified --------------------------------------------------
check "no roots reports UNVERIFIED" "UNVERIFIED" \
  "$(RETIRE_SEARCH_ROOTS=/nonexistent-xyz "$RETIRE" review 2>&1 || true)"

# --- purge safety -----------------------------------------------------------
out=$("$RETIRE" purge tree 2>&1) && bad "purge without --yes should exit non-zero" \
                                 || check "purge refuses without --yes" "Re-run with --yes" "$out"
[ -d "$R" ] && ok "purge without --yes left the tree alone" || bad "tree was deleted"

# --- restore ----------------------------------------------------------------
"$RETIRE" restore tree >/dev/null
[ -d "$TMP/tree" ] && ok "restore put it back" || bad "restore failed"
check "restored entry shows in list" "restored" "$("$RETIRE" list 2>&1)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
