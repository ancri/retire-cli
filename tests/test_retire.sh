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
check "write names the modified file" "(one\.txt; baseline " "$out"
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
if touch -a -d '+3 days' "$R/sub/two.txt" 2>/dev/null || touch -a -t "$(date -v+3d +%Y%m%d%H%M 2>/dev/null || echo 203001010000)" "$R/sub/two.txt" 2>/dev/null; then
  out=$("$RETIRE" review 2>&1 || true)
  check "future read is flagged" "TOUCHED: read" "$out"
  check "read names the relative file path" "(sub/two\.txt; baseline " "$out"
  "$RETIRE" rebaseline tree >/dev/null
else
  printf '  skip touch -a unsupported here\n'
fi

# --- bare directory listing (dir_atime only) must not trigger TOUCHED -------
if touch -a -d '+3 days' "$R" "$R/sub" 2>/dev/null || touch -a -t "$(date -v+3d +%Y%m%d%H%M 2>/dev/null || echo 203001010000)" "$R" "$R/sub" 2>/dev/null; then
  # Sync ctime (bumped by touch -a) so only the future directory atimes differ from baseline.
  python3 -c '
import json, os, sys
p = os.path.join(os.environ["RETIRE_STATE"], "ledger.jsonl")
ct = max(os.lstat(sys.argv[1]).st_ctime, os.lstat(sys.argv[2]).st_ctime)
rows = [json.loads(ln) for ln in open(p) if ln.strip()]
for e in rows:
    if e["name"] == "tree" and e["status"] == "retired":
        e["baseline"]["ctime"] = max(e["baseline"]["ctime"], ct)
with open(p, "w") as fh:
    for e in rows:
        fh.write(json.dumps(e) + "\n")
' "$R" "$R/sub"
  out=$("$RETIRE" review 2>&1 || true)
  absent "dir-only atime bump is not flagged TOUCHED" "TOUCHED: read" "$out"
  check  "dir-only atime bump stays holding"          "holding"       "$out"
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
absent "restored entry is hidden from default list" "restored" "$("$RETIRE" list 2>&1)"
check "default list notes hidden historical entries" "historical; use --all" "$("$RETIRE" list 2>&1)"
check "restored entry shows in list --all" "restored" "$("$RETIRE" list --all 2>&1)"

# --- purge ------------------------------------------------------------------
"$RETIRE" put "$TMP/tree" --reason test >/dev/null
"$RETIRE" purge tree --yes >/dev/null && ok "purge --yes deletes a directory" || bad "purge failed on a directory"
[ ! -e "$R" ] && ok "retired directory is gone" || bad "retired directory still exists"
echo ccc > "$TMP/one.pkl"
"$RETIRE" put "$TMP/one.pkl" --reason test >/dev/null
"$RETIRE" purge one.pkl --yes >/dev/null && ok "purge --yes deletes a single file" || bad "purge failed on a single file"
[ -z "$(ls "$TMP" | grep '^one\.pkl')" ] && ok "retired file is gone" || bad "retired file still exists"
absent "purged entries are hidden from default list" "purged" "$("$RETIRE" list 2>&1)"
check "purged entries show in list --all" "purged" "$("$RETIRE" list --all 2>&1)"

# --- list filtering, sorting, formatting, and json --------------------------
mkdir -p "$TMP/pipe/item_due" "$TMP/pipe/a_very_long_directory_name_over_22_chars"
echo small > "$TMP/pipe/item_due/s.txt"
python3 -c 'import sys; open(sys.argv[1], "wb").write(b"x" * 1500000)' "$TMP/pipe/item_big.bin"
echo med > "$TMP/pipe/a_very_long_directory_name_over_22_chars/m.txt"
"$RETIRE" put "$TMP/pipe/item_big.bin" --reason "second due, largest entry" --review-in 30d >/dev/null
"$RETIRE" put "$TMP/pipe/a_very_long_directory_name_over_22_chars" \
  --reason "this is a deliberately long explanation that should truncate on a narrow terminal" \
  --review-in 90d >/dev/null
"$RETIRE" put "$TMP/pipe/item_due" --reason "already due right now" --review-in 0d >/dev/null

out=$("$RETIRE" list 2>&1)
check  "list shows active due entry as DUE"      "item_due.*DUE"       "$out"
check  "list shows future entry as holding"      "item_big\.bin.*holding" "$out"
check  "list human-formats megabyte sizes"       "1\.5M"               "$out"
absent "list omits purged entries by default"    "purged"              "$out"
absent "list omits HITS column when clean"       "HITS"                "$out"
order=$(printf '%s\n' "$out" | awk 'NR>1 {print $1}' | paste -sd, -)
[ "$order" = "item_due,item_big.bin,a_very_long_directory_name_over_22_chars" ] \
  && ok "list sorts by review date ascending" \
  || { bad "list default sort order"; printf '       got: %s\n' "$order"; }

out_size=$("$RETIRE" list --sort size 2>&1)
first_size=$(printf '%s\n' "$out_size" | awk 'NR==2 {print $1}')
[ "$first_size" = "item_big.bin" ] \
  && ok "list --sort size puts largest first" \
  || { bad "list --sort size"; printf '       first was: %s\n' "$first_size"; }

out_due=$("$RETIRE" list --due 2>&1)
check  "list --due includes due entry"           "item_due"            "$out_due"
absent "list --due hides holding entries"        "item_big\.bin"       "$out_due"

out_all=$("$RETIRE" list --all 2>&1)
check  "list --all includes active entries"      "item_due"            "$out_all"
check  "list --all includes historical entries"  "purged"              "$out_all"

out_narrow=$(COLUMNS=80 "$RETIRE" list 2>&1)
check  "narrow terminal truncates long reason"   "\.\.\."              "$out_narrow"
out_full=$(COLUMNS=80 "$RETIRE" list --full 2>&1)
check  "list --full keeps untruncated reason"    "narrow terminal"     "$out_full"
check  "list --full includes retired path"       "path:.*item_due\.RETIRED" "$out_full"

out_json=$("$RETIRE" list --json 2>&1)
python3 -c '
import json, sys
rows = json.loads(sys.argv[1])
assert [r["name"] for r in rows] == ["item_due", "item_big.bin", "a_very_long_directory_name_over_22_chars"], rows
assert all(r["status"] == "retired" for r in rows)
' "$out_json" && ok "list --json outputs filtered sorted JSON array" || bad "list --json failed"

D_PATH=$(ls -d "$TMP"/pipe/item_due.RETIRED.*)
echo extra >> "$D_PATH/s.txt"
"$RETIRE" review item_due >/dev/null 2>&1 || true
check  "list shows HITS column when hits exist"  "HITS"                "$("$RETIRE" list 2>&1)"
check  "list --full prints remembered hit"       "hit ("               "$("$RETIRE" list --full 2>&1)"
"$RETIRE" rebaseline item_due >/dev/null
absent "rebaseline clears HITS column from list" "HITS"                "$("$RETIRE" list 2>&1)"

# --- review scoping (--due, explicit names) and single-pass multi-name grep -
"$RETIRE" purge item_due --yes >/dev/null
"$RETIRE" purge item_big.bin --yes >/dev/null
"$RETIRE" purge a_very_long_directory_name_over_22_chars --yes >/dev/null

mkdir -p "$TMP/roots/multi/foo" "$TMP/roots/multi/foo-bar" "$TMP/roots/multi/baz"
echo x > "$TMP/roots/multi/foo/f.txt"
echo y > "$TMP/roots/multi/foo-bar/fb.txt"
echo "foo inside retired tree" > "$TMP/roots/multi/foo-bar/hidden.py"
echo z > "$TMP/roots/multi/baz/b.txt"
"$RETIRE" put "$TMP/roots/multi/foo" --reason overlap1 --review-in 0d >/dev/null
"$RETIRE" put "$TMP/roots/multi/foo-bar" --reason overlap2 --review-in 30d >/dev/null
"$RETIRE" put "$TMP/roots/multi/baz" --reason clean --review-in 30d >/dev/null
echo "uses foo-bar here" > "$TMP/roots/multi/ref_both.py"
echo "uses foo alone"    > "$TMP/roots/multi/ref_foo.py"
echo "unrelated content" > "$TMP/roots/multi/other.py"
python3 -c '
import os, sys
p = os.path.join(os.fsencode(sys.argv[1]), b"nonutf8_\xff.py")
with open(p, "wb") as fh:
    fh.write(b"mentions baz\n")
' "$TMP/roots/multi"

out_multi=$("$RETIRE" review 2>&1 || true)
check  "multi-name review flags foo in 2 files"           "REFERENCED in 2 new file" "$out_multi"
check  "multi-name review flags foo-bar in 1 file"        "REFERENCED in 1 new file" "$out_multi"
check  "multi-name review catches non-UTF-8 file for baz" "baz \[INVESTIGATE\]"      "$out_multi"
absent "multi-name review has no UNVERIFIED on non-UTF-8" "UNVERIFIED"               "$out_multi"
absent "multi-name review ignores mention in retired tree" "hidden\.py"              "$out_multi"

"$RETIRE" ack baz >/dev/null
out_baz=$("$RETIRE" review baz 2>&1 || true)
check  "multi-name non-UTF-8 ref acks cleanly"            "baz \[holding\]"          "$out_baz"

out_one=$("$RETIRE" review foo 2>&1 || true)
check  "review <name> checks named entry"                 "^foo \[INVESTIGATE\]"     "$out_one"
absent "review <name> skips other entries"                "foo-bar \["               "$out_one"
absent "review <name> still skips untargeted retired trees" "hidden\.py"             "$out_one"

out_rdue=$("$RETIRE" review --due 2>&1 || true)
check  "review --due checks due entries"                  "^foo \["                  "$out_rdue"
absent "review --due skips holding entries"               "baz \["                   "$out_rdue"

out_comb=$("$RETIRE" review --due foo 2>&1) && bad "review --due with name should fail" \
                                            || check "review --due + name rejected" "cannot combine" "$out_comb"
out_bad=$("$RETIRE" review no_such_entry 2>&1) && bad "review unknown name should fail" \
                                               || check "review unknown name rejected" "no active entry" "$out_bad"

"$RETIRE" purge foo --yes >/dev/null
"$RETIRE" purge foo-bar --yes >/dev/null
"$RETIRE" purge baz --yes >/dev/null
check "review --due with no active entries is quiet" "nothing retired" "$("$RETIRE" review --due 2>&1)"
rm -rf "$TMP/pipe" "$TMP/roots/multi"

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

# --- real file read is caught immediately (no 36h blind spot) ----------------
mkdir -p "$TMP/readtest"
echo "important data" > "$TMP/readtest/data.txt"
if touch -a -d '3 days ago' "$TMP/readtest/data.txt" "$TMP/readtest" 2>/dev/null &&
   before=$(stat -c %X "$TMP/readtest/data.txt" 2>/dev/null); then
  "$RETIRE" put "$TMP/readtest" --reason test --review-in 0d >/dev/null
  RR=$(ls -d "$TMP"/readtest.RETIRED.*)
  "$RETIRE" review >/dev/null 2>&1 || true            # advances dir scanned_at
  cat "$RR/data.txt" >/dev/null
  after=$(stat -c %X "$RR/data.txt" 2>/dev/null)
  if [ "$after" != "$before" ]; then
    out=$("$RETIRE" review 2>&1 || true)
    check  "immediate real file read is flagged TOUCHED" "TOUCHED: read" "$out"
    absent "real read is not declared SAFE TO PURGE"     "SAFE TO PURGE" "$out"
    out2=$("$RETIRE" review 2>&1 || true)
    check  "repeat review still flags the file read"     "INVESTIGATE"   "$out2"
  else
    printf '  skip  filesystem did not update file atime on read\n'
  fi
  "$RETIRE" purge readtest --yes >/dev/null
else
  printf '  skip  touch -a or stat -c unsupported here\n'
fi

# --- reference check fails closed on grep errors, unreadable/missing roots ---
mkdir -p "$TMP/failclosed"
"$RETIRE" put "$TMP/failclosed" --reason test --review-in 0d >/dev/null

mkdir -p "$TMP/fakebin_err"
cat > "$TMP/fakebin_err/grep" <<'EOF'
#!/bin/sh
echo "grep: unrecognized option" >&2
exit 2
EOF
chmod 755 "$TMP/fakebin_err/grep"
out=$(PATH="$TMP/fakebin_err:$PATH" "$RETIRE" review 2>&1 || true)
check  "failing grep (exit 2) reports UNVERIFIED"     "UNVERIFIED"    "$out"
absent "failing grep is never SAFE TO PURGE"          "SAFE TO PURGE" "$out"
out=$(PATH="$TMP/fakebin_err:$PATH" "$RETIRE" ack failclosed 2>&1) \
  && bad "ack with failing grep should exit non-zero" \
  || check "ack refuses when grep fails" "nothing acked" "$out"

out=$(RETIRE_SEARCH_ROOTS="$TMP/roots:$TMP/does-not-exist" "$RETIRE" review 2>&1 || true)
check  "partial missing search_roots reports UNVERIFIED" "UNVERIFIED"    "$out"
absent "partial missing search_roots is not SAFE TO PURGE" "SAFE TO PURGE" "$out"

if [ "$(id -u)" -ne 0 ]; then
  mkdir -p "$TMP/uroot/sub"
  echo "uses failclosed" > "$TMP/uroot/sub/ref.py"
  chmod 000 "$TMP/uroot"
  out=$(RETIRE_SEARCH_ROOTS="$TMP/uroot" "$RETIRE" review 2>&1 || true)
  chmod 755 "$TMP/uroot"
  check  "unreadable search root reports UNVERIFIED"    "UNVERIFIED"    "$out"
  absent "unreadable search root is not SAFE TO PURGE"  "SAFE TO PURGE" "$out"

  mkdir -p "$TMP/eroot/sub/nested"
  echo "uses nested" > "$TMP/eroot/sub/ref.py"
  "$RETIRE" put "$TMP/eroot/sub/nested" --reason test --review-in 0d >/dev/null
  chmod 111 "$TMP/eroot/sub"
  out=$(RETIRE_SEARCH_ROOTS="$TMP/eroot" "$RETIRE" review 2>&1 || true)
  chmod 755 "$TMP/eroot/sub"
  check  "unreadable ancestor during expand reports UNVERIFIED" "UNVERIFIED"    "$out"
  absent "unreadable ancestor is not SAFE TO PURGE"             "SAFE TO PURGE" "$out"
  "$RETIRE" purge nested --yes >/dev/null
else
  printf '  skip  running as root: unreadable root permissions not enforced\n'
fi
"$RETIRE" purge failclosed --yes >/dev/null

# --- put and adopt refuse "" and "/" instead of targeting cwd ----------------
mkdir -p "$TMP/cwdguard/live"
out=$(cd "$TMP/cwdguard/live" && "$RETIRE" put / 2>&1) \
  && bad "put / should exit non-zero" \
  || check "put / is refused" "filesystem root" "$out"
[ -d "$TMP/cwdguard/live" ] && ok "put / left cwd untouched" || bad "put / renamed cwd"

out=$(cd "$TMP/cwdguard/live" && "$RETIRE" put "" 2>&1) \
  && bad "put empty path should exit non-zero" \
  || check "put empty path is refused" "invalid path" "$out"
[ -d "$TMP/cwdguard/live" ] && ok "put empty path left cwd untouched" || bad "put empty path renamed cwd"

out=$(cd "$TMP/cwdguard/live" && "$RETIRE" adopt / 2>&1) \
  && bad "adopt / should exit non-zero" \
  || check "adopt / is refused" "filesystem root" "$out"
out=$(cd "$TMP/cwdguard/live" && "$RETIRE" adopt "" 2>&1) \
  && bad "adopt empty path should exit non-zero" \
  || check "adopt empty path is refused" "invalid path" "$out"

# --- concurrent review must not clobber a concurrent put ---------------------
mkdir -p "$TMP/fakebin_slow"
cat > "$TMP/fakebin_slow/grep" <<'EOF'
#!/bin/sh
sleep 1
exit 1
EOF
chmod 755 "$TMP/fakebin_slow/grep"
mkdir -p "$TMP/conc1" "$TMP/conc2"
"$RETIRE" put "$TMP/conc1" --reason test >/dev/null
PATH="$TMP/fakebin_slow:$PATH" "$RETIRE" review >/dev/null 2>&1 &
rev_pid=$!
sleep 0.2
"$RETIRE" put "$TMP/conc2" --reason test >/dev/null
wait "$rev_pid" || true
out=$("$RETIRE" list 2>&1)
check "concurrent put survives review's save" "conc2" "$out"
"$RETIRE" purge conc1 --yes >/dev/null
"$RETIRE" purge conc2 --yes >/dev/null

# --- config default_review_in is honored -------------------------------------
printf '{"default_review_in": "6m"}\n' > "$RETIRE_CONFIG"
mkdir -p "$TMP/cfgspan"
"$RETIRE" put "$TMP/cfgspan" --reason test >/dev/null
rm -f "$RETIRE_CONFIG"
days=$(python3 -c '
import json, os
from datetime import date
with open(os.path.join(os.environ["RETIRE_STATE"], "ledger.jsonl")) as fh:
    entries = [json.loads(ln) for ln in fh if ln.strip()]
e = [x for x in entries if x["name"] == "cfgspan" and x["status"] == "retired"][-1]
print((date.fromisoformat(e["review_after"]) - date.fromisoformat(e["retired_on"])).days)
')
[ "$days" = "180" ] && ok "default_review_in 6m produces 180d horizon" \
                  || bad "default_review_in 6m expected 180d, got $days"
"$RETIRE" purge cfgspan --yes >/dev/null

# --- broken symlinks: lexists in put, adopt, restore -------------------------
ln -s "$TMP/no_such_target" "$TMP/broken_put"
"$RETIRE" put "$TMP/broken_put" --reason test >/dev/null \
  && ok "put accepts a broken symlink" || bad "put rejected a broken symlink"
"$RETIRE" purge broken_put --yes >/dev/null

echo "orig" > "$TMP/symfile"
"$RETIRE" put "$TMP/symfile" --reason test >/dev/null
ln -s "$TMP/no_such_target" "$TMP/symfile"
out=$("$RETIRE" restore symfile 2>&1) \
  && bad "restore over broken symlink should fail" \
  || check "restore refuses occupied broken symlink" "original path is occupied" "$out"
[ -L "$TMP/symfile" ] && ok "broken symlink at original_path was preserved" \
                      || bad "broken symlink at original_path was overwritten"
rm "$TMP/symfile"
"$RETIRE" restore symfile >/dev/null
today=$(date +%Y%m%d)
ln -s "$TMP/no_such_target" "$TMP/symfile.RETIRED.$today"
out=$("$RETIRE" put "$TMP/symfile" --reason test 2>&1) \
  && bad "put over broken symlink dst should fail" \
  || check "put refuses existing broken symlink target" "target already exists" "$out"
[ -L "$TMP/symfile.RETIRED.$today" ] && ok "broken symlink at dst was preserved" \
                                     || bad "broken symlink at dst was overwritten"
rm "$TMP/symfile.RETIRED.$today" "$TMP/symfile"

# --- bad config types are warned and ignored safely --------------------------
printf '{"search_roots": "/nonexistent", "includes": "*.py", "atime_slack_hours": -5, "default_review_in": "bogus"}\n' > "$RETIRE_CONFIG"
mkdir -p "$TMP/badcfg"
out=$("$RETIRE" put "$TMP/badcfg" --reason test 2>&1)
check "bad config warns on stderr" "ignoring bad config" "$out"
out=$(env -u RETIRE_SEARCH_ROOTS "$RETIRE" review 2>&1 || true)
rm -f "$RETIRE_CONFIG"
check "string search_roots falls back to UNVERIFIED instead of grepping /" "UNVERIFIED" "$out"
"$RETIRE" purge badcfg --yes >/dev/null

# --- non-UTF-8 filenames in search_roots do not crash review or ack ----------
mkdir -p "$TMP/utf8root" "$TMP/utf8target"
python3 -c '
import os, sys
p = os.path.join(os.fsencode(sys.argv[1]), b"bad\xffname.py")
with open(p, "wb") as fh:
    fh.write(b"mentions utf8target\n")
' "$TMP/utf8root"
"$RETIRE" put "$TMP/utf8target" --reason test >/dev/null
out=$(RETIRE_SEARCH_ROOTS="$TMP/utf8root" "$RETIRE" review 2>&1 || true)
check  "non-UTF-8 filename in search_roots is reported REFERENCED" "REFERENCED"        "$out"
absent "non-UTF-8 filename does not raise UnicodeDecodeError"      "UnicodeDecodeError" "$out"
RETIRE_SEARCH_ROOTS="$TMP/utf8root" "$RETIRE" ack utf8target >/dev/null \
  && ok "ack handles non-UTF-8 filename cleanly" || bad "ack crashed on non-UTF-8 filename"
"$RETIRE" purge utf8target --yes >/dev/null

# --- missing path checks in rebaseline, restore, purge -----------------------
mkdir -p "$TMP/misstest"
echo "payload" > "$TMP/misstest/f.txt"
"$RETIRE" put "$TMP/misstest" --reason test >/dev/null
RM=$(ls -d "$TMP"/misstest.RETIRED.*)
rm -rf "$RM"
out=$("$RETIRE" rebaseline misstest 2>&1) \
  && bad "rebaseline on missing path should exit non-zero" \
  || check "rebaseline refuses missing path" "retired path is missing" "$out"
bytes=$(python3 -c '
import json, os
with open(os.path.join(os.environ["RETIRE_STATE"], "ledger.jsonl")) as fh:
    entries = [json.loads(ln) for ln in fh if ln.strip()]
e = [x for x in entries if x["name"] == "misstest" and x["status"] == "retired"][-1]
print(e["bytes"])
')
[ "$bytes" -gt 0 ] && ok "failed rebaseline preserved recorded bytes" \
                   || bad "rebaseline zeroed bytes of missing path"
out=$("$RETIRE" restore misstest 2>&1) \
  && bad "restore on missing path should exit non-zero" \
  || check "restore reports missing path cleanly" "retired path is missing" "$out"
out=$("$RETIRE" purge misstest --yes 2>&1) \
  && bad "purge on missing path should exit non-zero" \
  || check "purge reports missing path cleanly" "retired path is missing" "$out"

# --- notify logs failures and handles leading-dash entry names ---------------
mkdir -p "$TMP/fakebin_notify" "$TMP/-dashdir"
cat > "$TMP/fakebin_notify/notify-send" <<EOF
#!/bin/sh
printf '%s\n' "\$@" > "$TMP/notify_args.txt"
echo "Cannot connect to D-Bus" >&2
exit 1
EOF
cat > "$TMP/fakebin_notify/terminal-notifier" <<EOF
#!/bin/sh
printf '%s\n' "\$@" > "$TMP/notify_args.txt"
echo "Notification Center unavailable" >&2
exit 1
EOF
chmod 755 "$TMP/fakebin_notify/notify-send" "$TMP/fakebin_notify/terminal-notifier"
"$RETIRE" put "$TMP/-dashdir" --reason test --review-in 0d >/dev/null
PATH="$TMP/fakebin_notify:$PATH" "$RETIRE" review --notify >/dev/null 2>&1 || true
log_content=$(cat "$RETIRE_STATE/review.log")
check "failed notifier is logged in review.log" "notification failed" "$log_content"
if [ "$(uname -s)" = "Linux" ]; then
  check "notify-send receives -- before title/body" "^--$" "$(cat "$TMP/notify_args.txt")"
fi
"$RETIRE" purge --yes -- -dashdir >/dev/null

# --- legacy baseline ignores dir-only atime; SIGINT persists scanned_at ------
mkdir -p "$TMP/dirnoise"
echo "payload" > "$TMP/dirnoise/data.txt"
"$RETIRE" put "$TMP/dirnoise" --reason test >/dev/null
DN=$(ls -d "$TMP"/dirnoise.RETIRED.*)
if touch -a -d '+3 days' "$DN" 2>/dev/null || touch -a -t "$(date -v+3d +%Y%m%d%H%M 2>/dev/null || echo 203001010000)" "$DN" 2>/dev/null; then
  # Strip file_atime/dir_atime to simulate a pre-1.2.1 legacy ledger baseline, and sync
  # ctime so only the future dir atime differs from baseline.
  python3 -c '
import json, os, sys
p = os.path.join(os.environ["RETIRE_STATE"], "ledger.jsonl")
dn_ct = os.lstat(sys.argv[1]).st_ctime
rows = [json.loads(ln) for ln in open(p) if ln.strip()]
for e in rows:
    if e["name"] == "dirnoise" and e["status"] == "retired":
        e["baseline"].pop("file_atime", None)
        e["baseline"].pop("dir_atime", None)
        e["baseline"]["ctime"] = max(e["baseline"]["ctime"], dn_ct)
        e["baseline"]["scanned_at"] = 1000.0
with open(p, "w") as fh:
    for e in rows:
        fh.write(json.dumps(e) + "\n")
' "$DN"
  out=$("$RETIRE" review dirnoise 2>&1 || true)
  absent "legacy baseline ignores dir-only atime bump" "TOUCHED: read" "$out"
  check  "legacy baseline stays holding on dir walk"   "dirnoise \[holding\]" "$out"
else
  printf '  skip touch -a unsupported here\n'
fi

# Reset scanned_at, run review against a slow grep, interrupt with SIGINT, and
# verify scanned_at was still persisted for already-walked trees.
python3 -c '
import json, os
p = os.path.join(os.environ["RETIRE_STATE"], "ledger.jsonl")
rows = [json.loads(ln) for ln in open(p) if ln.strip()]
for e in rows:
    if e["name"] == "dirnoise" and e["status"] == "retired":
        e["baseline"]["scanned_at"] = 1000.0
with open(p, "w") as fh:
    for e in rows:
        fh.write(json.dumps(e) + "\n")
'
mkdir -p "$TMP/fakebin_int"
cat > "$TMP/fakebin_int/grep" <<'EOF'
#!/bin/sh
exec sleep 10
EOF
chmod 755 "$TMP/fakebin_int/grep"
# Spawn via Python so SIGINT is not ignored (POSIX sh sets SIG_IGN on `&` jobs).
python3 -c '
import json, os, signal, subprocess, sys, time
env = dict(os.environ)
env["PATH"] = sys.argv[2] + ":" + env.get("PATH", "")
p = subprocess.Popen([sys.argv[1], "review", "dirnoise"],
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=env)
time.sleep(0.3)
p.send_signal(signal.SIGINT)
rc = p.wait(timeout=5)
assert rc != 0, "expected non-zero exit on SIGINT, got %r" % rc
with open(os.path.join(os.environ["RETIRE_STATE"], "ledger.jsonl")) as fh:
    rows = [json.loads(ln) for ln in fh if ln.strip()]
e = [x for x in rows if x["name"] == "dirnoise" and x["status"] == "retired"][-1]
assert e["baseline"]["scanned_at"] > 1000, e["baseline"]
' "$RETIRE" "$TMP/fakebin_int" \
  && ok "interrupted review aborts and persists scanned_at" \
  || bad "interrupted review failed to abort or persist scanned_at"

# --- multi-name rebaseline and rebaseline --all ------------------------------
mkdir -p "$TMP/rb1" "$TMP/rb2"
echo a > "$TMP/rb1/a.txt"
echo b > "$TMP/rb2/b.txt"
"$RETIRE" put "$TMP/rb1" --reason test >/dev/null
"$RETIRE" put "$TMP/rb2" --reason test >/dev/null
RB1=$(ls -d "$TMP"/rb1.RETIRED.*)
RB2=$(ls -d "$TMP"/rb2.RETIRED.*)
echo more >> "$RB1/a.txt"
echo more >> "$RB2/b.txt"
"$RETIRE" review rb1 rb2 >/dev/null 2>&1 || true

out=$("$RETIRE" rebaseline rb1 rb2 2>&1)
check "multi-name rebaseline updates first entry"  "rebaselined 'rb1'" "$out"
check "multi-name rebaseline updates second entry" "rebaselined 'rb2'" "$out"
check "multi-name rebaseline clears hits"          "holding"           "$("$RETIRE" review rb1 2>&1 || true)"

# rebaseline --all updates existing entries and warns/skips the missing misstest
out=$("$RETIRE" rebaseline --all 2>&1) && bad "rebaseline --all should exit non-zero when a path is missing" \
                                       || check "rebaseline --all skips missing path with warning" "skipping missing path" "$out"
check "rebaseline --all still rebaselines valid entries" "rebaselined 'dirnoise'" "$out"

out=$("$RETIRE" rebaseline 2>&1) && bad "rebaseline with no args should fail" \
                                 || check "rebaseline with no args errors" "specify one or more" "$out"
out=$("$RETIRE" rebaseline --all rb1 2>&1) && bad "rebaseline --all with names should fail" \
                                           || check "rebaseline --all + names rejected" "cannot combine" "$out"

"$RETIRE" purge dirnoise --yes >/dev/null
"$RETIRE" purge rb1 --yes >/dev/null
"$RETIRE" purge rb2 --yes >/dev/null

# --- unreadable subdirectory inside retired tree reports UNVERIFIED ----------
if [ "$(id -u)" -ne 0 ]; then
  mkdir -p "$TMP/unreadable_tree/priv"
  echo "secret" > "$TMP/unreadable_tree/priv/data.txt"
  chmod 000 "$TMP/unreadable_tree/priv"
  "$RETIRE" put "$TMP/unreadable_tree" --reason test --review-in 0d >/dev/null
  UT=$(ls -d "$TMP"/unreadable_tree.RETIRED.*)
  out=$("$RETIRE" review unreadable_tree 2>&1 || true)
  chmod 755 "$UT/priv"
  check  "unreadable subdir inside retired tree flags UNVERIFIED" "UNVERIFIED"    "$out"
  absent "unreadable subdir inside retired tree is not SAFE TO PURGE" "SAFE TO PURGE" "$out"
  "$RETIRE" purge unreadable_tree --yes >/dev/null
else
  printf '  skip  running as root: unreadable subdir permissions not enforced\n'
fi

# --- put refuses retiring RETIRE_STATE or an ancestor directory --------------
mkdir -p "$TMP/stateparent/mystate" "$TMP/stateparent/keepme"
out=$(RETIRE_STATE="$TMP/stateparent/mystate" "$RETIRE" put "$TMP/stateparent/mystate" 2>&1) \
  && bad "put on RETIRE_STATE should fail" \
  || check "put on RETIRE_STATE is refused" "retire state directory" "$out"
out=$(RETIRE_STATE="$TMP/stateparent/mystate" "$RETIRE" put "$TMP/stateparent" 2>&1) \
  && bad "put on ancestor of RETIRE_STATE should fail" \
  || check "put on ancestor of RETIRE_STATE is refused" "retire state directory" "$out"
[ -d "$TMP/stateparent/mystate" ] && ok "RETIRE_STATE stayed in place" || bad "RETIRE_STATE was moved"

# --- adopt rejects empty, traversal, and newline names -----------------------
mkdir -p "$TMP/.RETIRED.20261125" "$TMP/badadopt.RETIRED.20261125" "$TMP/inplace_dir"
out=$("$RETIRE" adopt "$TMP/.RETIRED.20261125" 2>&1) \
  && bad "adopt producing empty name should fail" \
  || check "adopt rejects empty inferred name" "invalid entry name" "$out"
out=$("$RETIRE" adopt "$TMP/badadopt.RETIRED.20261125" --name "" 2>&1) \
  && bad "adopt with --name '' should fail" \
  || check "adopt rejects explicit empty --name" "invalid entry name" "$out"
out=$("$RETIRE" adopt "$TMP/badadopt.RETIRED.20261125" --name "../escape" 2>&1) \
  && bad "adopt with path traversal --name should fail" \
  || check "adopt rejects traversal --name" "invalid entry name" "$out"
out=$("$RETIRE" adopt "$TMP/badadopt.RETIRED.20261125" --name "/tmp/abs" 2>&1) \
  && bad "adopt with absolute --name should fail" \
  || check "adopt rejects absolute --name" "invalid entry name" "$out"
nl_name=$(printf 'bad\nname')
out=$("$RETIRE" adopt "$TMP/badadopt.RETIRED.20261125" --name "$nl_name" 2>&1) \
  && bad "adopt with newline in --name should fail" \
  || check "adopt rejects newline in --name" "invalid entry name" "$out"
"$RETIRE" adopt "$TMP/inplace_dir" --reason test >/dev/null
out=$("$RETIRE" restore inplace_dir 2>&1) \
  && bad "restore of in-place adopted entry should fail" \
  || check "restore explains in-place adopt clearly" "adopted in place" "$out"
"$RETIRE" purge inplace_dir --yes >/dev/null

# --- UTF-8 config, ack, and log work cleanly under non-UTF-8 POSIX locale ----
mkdir -p "$TMP/posix_root/café" "$TMP/posix_entry"
printf 'uses posix_entry\n' > "$TMP/posix_root/café/résumé.py"
printf '{"search_roots": ["%s"]}\n' "$TMP/posix_root/café" > "$TMP/posix_cfg.json"
RETIRE_STATE="$TMP/posix_state" RETIRE_CONFIG="$TMP/posix_cfg.json" \
  "$RETIRE" put "$TMP/posix_entry" --reason test >/dev/null
RETIRE_STATE="$TMP/posix_state" RETIRE_CONFIG="$TMP/posix_cfg.json" \
  env -u RETIRE_SEARCH_ROOTS "$RETIRE" ack posix_entry >/dev/null
out=$(LC_ALL=POSIX LANG=POSIX PYTHONCOERCECLOCALE=0 PYTHONUTF8=0 \
  RETIRE_STATE="$TMP/posix_state" RETIRE_CONFIG="$TMP/posix_cfg.json" \
  env -u RETIRE_SEARCH_ROOTS "$RETIRE" review posix_entry 2>&1 || true)
check  "POSIX locale review matches UTF-8 config and acked_refs" "posix_entry \[holding\]" "$out"
absent "POSIX locale does not ignore UTF-8 config"               "ignoring bad config"     "$out"
absent "POSIX locale does not raise UnicodeEncodeError"          "UnicodeEncodeError"      "$out"

# --- _grep_refs_many deduplicates Stage 2 errors and stops cleanly -----------
mkdir -p "$TMP/dedup_root" "$TMP/dd1" "$TMP/dd2" "$TMP/dd3"
printf 'dd1 dd2 dd3\n' > "$TMP/dedup_root/hit.py"
"$RETIRE" put "$TMP/dd1" --reason test >/dev/null
"$RETIRE" put "$TMP/dd2" --reason test >/dev/null
"$RETIRE" put "$TMP/dd3" --reason test >/dev/null
mkdir -p "$TMP/fakebin_s2"
cat > "$TMP/fakebin_s2/grep" <<EOF
#!/bin/sh
case "\$1" in
  -rlFw) echo "$TMP/dedup_root/hit.py"; exit 0;;
  *) echo "grep: stage2boom" >&2; exit 2;;
esac
EOF
chmod 755 "$TMP/fakebin_s2/grep"
out=$(PATH="$TMP/fakebin_s2:$PATH" RETIRE_SEARCH_ROOTS="$TMP/dedup_root" \
  "$RETIRE" review dd1 dd2 dd3 2>&1 || true)
check  "Stage 2 grep error reports UNVERIFIED"        "grep failed (grep: stage2boom)" "$out"
absent "Stage 2 grep error is not duplicated per name" "stage2boom); grep failed"      "$out"
"$RETIRE" purge dd1 --yes >/dev/null
"$RETIRE" purge dd2 --yes >/dev/null
"$RETIRE" purge dd3 --yes >/dev/null

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
