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
RETIRE_CONFIG="$TMP/config.json"         # absent unless a test writes it: never the user's own
export RETIRE_STATE RETIRE_SEARCH_ROOTS RETIRE_CONFIG

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
check(){ # check <desc> <pattern> <output>
  if printf '%s' "$3" | grep -q "$2"; then ok "$1"; else
    bad "$1"; printf '       expected /%s/ in:\n%s\n' "$2" "$3"; fi
}
absent(){ # absent <desc> <pattern> <output>
  if printf '%s' "$3" | grep -q "$2"; then
    bad "$1"; printf '       did not expect /%s/ in:\n%s\n' "$2" "$3"; else ok "$1"; fi
}
link_atime_moves(){ # does resolving a symlink update the link's own atime on this filesystem?
  rm -rf "$TMP/probe"; mkdir "$TMP/probe" && ln -s . "$TMP/probe/l" &&
  touch -h -a -d '3 days ago' "$TMP/probe/l" 2>/dev/null &&
  a=$(stat -c %X "$TMP/probe/l" 2>/dev/null) && ls "$TMP/probe/l/" >/dev/null &&
  b=$(stat -c %X "$TMP/probe/l") && rm -rf "$TMP/probe" && [ "$a" != "$b" ]
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

# --- put must refuse a duplicate name before it moves anything ---------------
# Entries are named after the basename, so a second directory called "tree" collides.
# The refusal has to come before the rename: an unrecorded rename is a lost path.
mkdir -p "$TMP/other/tree"
out=$("$RETIRE" put "$TMP/other/tree" --reason dup 2>&1) && bad "duplicate name should exit non-zero" \
                                                          || check "duplicate name is refused" "already an active ledger entry" "$out"
[ -d "$TMP/other/tree" ] && ok "refused path is left in place" || bad "refused path was moved"
[ -z "$(ls "$TMP/other" | grep RETIRED)" ] && ok "no unrecorded .RETIRED left behind" \
                                            || bad "duplicate put left an unrecorded rename"

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

# --- review must not follow symlinks inside a tree ---------------------------
# os.walk classifies entries with is_dir(), which resolves symlinks, and resolving a
# link updates the link's own atime. The scan then read that atime back with lstat, so
# a tree holding a symlink reported a read at its own scan in every weekly review.
# atime_slack_hours 0 stands in for the week between two reviews.
ln -s sub "$R/link"
"$RETIRE" rebaseline tree >/dev/null
if touch -h -a -d '3 days ago' "$R/link" 2>/dev/null && link_atime_moves; then
  printf '{"atime_slack_hours": 0}\n' > "$RETIRE_CONFIG"
  out=$("$RETIRE" review 2>&1 || true)
  rm -f "$RETIRE_CONFIG"
  absent "review does not follow a symlink in the tree" "TOUCHED: read" "$out"
else
  printf '  skip  resolving a symlink does not update its atime here\n'
fi
rm "$R/link"
"$RETIRE" rebaseline tree >/dev/null

# --- detection: references --------------------------------------------------
echo "this mentions tree by name" > "$TMP/roots/code.py"
check "new reference is flagged" "REFERENCED" "$("$RETIRE" review 2>&1 || true)"
"$RETIRE" ack tree >/dev/null
check "ack silences it" "holding" "$("$RETIRE" review 2>&1 || true)"

# --- the reference check must stay out of retired paths ----------------------
# grep -r over a search root lists every directory below it and reads every file it
# includes, retired trees too. Each entry scanned after the first grep reported that
# grep as a read, and ack did the same to every tree under a root.
mkdir -p "$TMP/roots/proj/alpha/a" "$TMP/roots/proj/beta/b"
echo "alpha notes" > "$TMP/roots/proj/alpha/a/notes.txt"
echo "beta notes" > "$TMP/roots/proj/beta/b/notes.txt"
"$RETIRE" put "$TMP/roots/proj/alpha" --reason test >/dev/null
"$RETIRE" put "$TMP/roots/proj/beta" --reason test >/dev/null
A=$(ls -d "$TMP"/roots/proj/alpha.RETIRED.*)
B=$(ls -d "$TMP"/roots/proj/beta.RETIRED.*)
if find "$A" "$B" -exec touch -a -d '3 days ago' {} + 2>/dev/null &&
   before=$(stat -c %X "$A/a/notes.txt" "$B/b/notes.txt" 2>/dev/null); then
  printf '{"atime_slack_hours": 0}\n' > "$RETIRE_CONFIG"
  out=$("$RETIRE" review 2>&1 || true)
  rm -f "$RETIRE_CONFIG"
  absent "review does not report its own reference check as a read" "TOUCHED: read" "$out"
  [ "$(stat -c %X "$A/a/notes.txt" "$B/b/notes.txt")" = "$before" ] \
    && ok "review's grep reads nothing inside retired trees" || bad "review's grep read inside a retired tree"
  "$RETIRE" ack alpha >/dev/null
  [ "$(stat -c %X "$A/a/notes.txt" "$B/b/notes.txt")" = "$before" ] \
    && ok "ack's grep reads nothing inside retired trees" || bad "ack's grep read inside a retired tree"
else
  printf '  skip  touch -a or stat -c unsupported here\n'
fi

# Everything else is still searched: next to and below the retired paths, and a live
# directory that merely shares a retired path's name, which grep --exclude-dir (base
# names only) would wrongly skip. Like grep -r, no symlink below a root is followed.
O="$TMP/roots/other/$(basename "$A")"
mkdir -p "$TMP/roots/proj/deep/x" "$TMP/roots/proj/node_modules" "$O" "$TMP/outside"
for f in "$TMP/roots/proj/use.py" "$TMP/roots/proj/deep/x/use.py" "$O/use.py" "$A/a/mention.py" \
         "$TMP/roots/proj/node_modules/x.js" "$TMP/roots/proj/data.bin" "$TMP/outside/use.py"; do
  echo "uses beta" > "$f"
done
ln -s "$TMP/outside" "$TMP/roots/proj/dirlink"
ln -s "$TMP/outside/use.py" "$TMP/roots/proj/filelink.py"
out=$("$RETIRE" ack beta 2>&1)
check  "reference check finds exactly the 3 live mentions"  "acknowledged 3 reference"  "$out"
check  "  next to the retired paths"                        "roots/proj/use.py"         "$out"
check  "  below a directory handed to grep whole"           "roots/proj/deep/x/use.py"  "$out"
check  "  in a live directory sharing a retired path's name" "roots/other/alpha.RETIRED" "$out"
absent "  but not inside another retired tree"              "mention.py"                "$out"
absent "  nor in an excluded directory"                     "node_modules"              "$out"
absent "  nor in a file type outside includes"              "data.bin"                  "$out"
absent "  nor behind a symlink"                             "proj/[a-z]*link"           "$out"
"$RETIRE" purge alpha --yes >/dev/null
"$RETIRE" purge beta --yes >/dev/null
rm -rf "$TMP/roots/proj" "$TMP/roots/other" "$TMP/outside"

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

# --- purge ------------------------------------------------------------------
"$RETIRE" put "$TMP/tree" --reason test >/dev/null
"$RETIRE" purge tree --yes >/dev/null && ok "purge --yes deletes a directory" || bad "purge failed on a directory"
[ ! -e "$R" ] && ok "retired directory is gone" || bad "retired directory still exists"
echo ccc > "$TMP/one.pkl"
"$RETIRE" put "$TMP/one.pkl" --reason test >/dev/null
"$RETIRE" purge one.pkl --yes >/dev/null && ok "purge --yes deletes a single file" || bad "purge failed on a single file"
[ -z "$(ls "$TMP" | grep '^one\.pkl')" ] && ok "retired file is gone" || bad "retired file still exists"
check "purged entries show in list" "purged" "$("$RETIRE" list 2>&1)"

# --- put rolls the rename back when the ledger cannot be written --------------
# Root ignores directory permissions, so this check only means something for a normal user.
if [ "$(id -u)" -ne 0 ]; then
  mkdir -p "$TMP/rollme"
  chmod 555 "$RETIRE_STATE"
  out=$("$RETIRE" put "$TMP/rollme" --reason test 2>&1) && bad "put with an unwritable ledger should exit non-zero" \
                                                        || check "unwritable ledger is reported" "could not record" "$out"
  chmod 755 "$RETIRE_STATE"
  [ -d "$TMP/rollme" ] && ok "rename was rolled back" || bad "path left renamed without a ledger entry"
  [ -z "$(ls "$TMP" | grep '^rollme\.RETIRED')" ] && ok "no .RETIRED copy remains" || bad ".RETIRED copy remains"
else
  printf '  skip  running as root: directory permissions are not enforced\n'
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
