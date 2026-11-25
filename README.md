# retire

Set paths aside for later deletion, with a ledger and a safety review.

You want to delete a directory. You are *fairly* sure nothing uses it. Deleting it
outright is irreversible; leaving it costs disk and accumulates doubt. `retire` gives
you the third option: move it aside, write down what you did and why, and re-check it
later before anything is actually removed.

```console
$ retire put /srv/old_cache --reason "superseded by parquet" --review-in 6m
retired /srv/old_cache -> /srv/old_cache.RETIRED.20260901 (2.5 GB, review after 2027-03-01)

$ retire review
old_cache [holding] 2.5 GB
```

Three months later, something read it:

```console
$ retire review
old_cache [INVESTIGATE] 2.5 GB
    - TOUCHED: read at 2026-12-02 04:15:10 (baseline 2026-09-01 12:25:51)
```

**Nothing here deletes anything except `purge`, which requires an explicit `--yes`.**
`review` never modifies, moves or deletes a retired path and never acts on its own
verdict; it writes only to its own ledger.

## Why the move is the point

The rename *is* the tripwire, and it is a better one than watching for reads. Once the
path is gone, anything that depended on it fails loudly with `ENOENT` instead of
silently reading stale data. Timestamp checks tell you something *touched* the tree;
the move tells you something *broke without it*, which is the question you actually
care about.

## Install

No dependencies beyond Python 3.7+ and a POSIX shell.

```sh
git clone https://github.com/ancri/retire-cli
cd retire-cli
make install            # installs to ~/.local (PREFIX= to change)
```

Then confirm the setup:

```console
$ retire doctor
retire 1.0.0
  platform        Linux 6.8.0-138-generic
  python          3.12.3 (/usr/bin/python3)
  config          ~/.config/retire/config.json   [absent, using defaults]
  notifier        notify-send
  grep            /usr/bin/grep
  search roots    none configured  [reference check reports UNVERIFIED]
  atime slack     0 h
  default review  90d
```

`make install` also installs the man page. If `man retire` does not resolve, add the
install prefix to `MANPATH` — common on macOS:

```sh
export MANPATH="$HOME/.local/share/man:$MANPATH"
```

## Commands

| Command | Does |
|---|---|
| `retire put <path>` | Rename aside as `<path>.RETIRED.YYYYMMDD` and record it |
| `retire adopt <path>` | Record something you already moved by hand |
| `retire list [--all\|--due] [--sort K] [--full]` | Show the active pipeline (sorted by review date; `--all` for full history, `--json` for scripts) |
| `retire review [name ...] [--due] [--notify]` | Read-only safety check (all active, `--due` only, or specific names) |
| `retire ack <name>` | Accept the current references as known |
| `retire rebaseline <name>... \| --all` | Reset the tripwire snapshot (and clear remembered hits) |
| `retire restore <name>` | Move it back |
| `retire purge <name> --yes` | Actually delete it |
| `retire doctor` | Report the local setup |

`retire`, `retire ?` and `retire help <command>` all print documentation.
Full reference: `man retire`.

## What review detects

| Signal | Catches |
|---|---|
| `TOUCHED` | Newer file `atime` (reads), or any `mtime` (writes) or `ctime` (rename, chmod, chown), with the relative path |
| `EARLIER` | A hit from a previous review, remembered until you `rebaseline` |
| `DRIFT` | Entry count or byte count changed — files added or deleted inside |
| `REFERENCED` | The name still appears in your configured source roots, outside retired paths |
| `UNVERIFIED` | The reference check could not run — reported, never passed off as clean |

An entry is `INVESTIGATE` if any of those fire, `SAFE TO PURGE` once the review date
passes cleanly, and `holding` otherwise.

### The observer problem

Walking a tree calls `readdir` on every directory, which updates that directory's
`atime`. A naive implementation reports its own traversal as an external read on every
run — which is exactly what `retire` 1.0.0 did.

So `review` only checks `atime` on non-directories (files and symlinks), never on bare
directory listings (`readdir`). Regular files are only inspected with `lstat`, so `review`
never bumps their `atime` and compares them directly against the retirement baseline,
reporting the relative path of the touched file. Directory listings from `find`, `du`,
`rg`, desktop indexers, or `review` itself no longer trigger false `TOUCHED` alarms;
writes, additions, deletions, renames, and permission changes inside directories are still
caught by `mtime`, `ctime`, and `DRIFT`. Hits are recorded in the ledger and re-reported
as `EARLIER` until `rebaseline` clears them.

Two more of review's own reads were reported as external ones until 1.2.0:

- **The reference check.** `grep -r` over a search root lists every directory below it
  and reads every file it includes, retired trees too, so each entry checked after the
  first grep reported that grep as a read. Review now scans every tree before it runs
  any reference check, and the check never enters a retired path: `retire` lists the
  directories leading down to each retired path itself and hands grep their other
  children. (`--exclude-dir` matches base names, so it would also skip a live directory
  that shares a retired path's name.) A mention inside a retired tree therefore no
  longer counts as a reference.
- **Symlinks.** Resolving a symlink updates the link's own `atime`, and the scan used to
  resolve every link it met (`os.walk` does, to classify entries). It now never follows
  one.

**Upgrading from 1.1.x:** hits that an earlier review made itself stay remembered as
`EARLIER`. Their times fall inside review runs (for the weekly cron, Mondays just after
10:00). Once an entry's remembered hits are all of that kind, clear them with
`retire rebaseline <name>`.

**It cannot tell you *who* touched something.** Timestamps carry no attribution. If you
need that, put an audit watch on the path instead:

```sh
sudo auditctl -w /srv/old_cache.RETIRED.20260901 -p rwa -k retire
sudo ausearch -k retire
```

## Configuration

Optional. Every key has a default. `~/.config/retire/config.json`:

```json
{
  "search_roots": ["/home/me/src", "/srv/analysis"],
  "atime_slack_hours": 0,
  "default_review_in": "6m"
}
```

`search_roots` is empty by default, so `review` reports `UNVERIFIED` until you point it
at the trees that could plausibly mention a retired path. That is deliberate: a tool
that silently reports "no references" because it searched nowhere is worse than one
that admits it did not look.

Environment overrides: `RETIRE_STATE`, `RETIRE_CONFIG`, `RETIRE_SEARCH_ROOTS`.

## Scheduling

Weekly review, silent unless something needs attention.

**Linux** (`contrib/retire.cron`):

```cron
0 10 * * 1 ~/.local/bin/retire review --notify >> ~/.local/share/retire/review.log 2>&1
```

**macOS** — launchd rather than cron, since cron is deprecated there and gated behind
Full Disk Access:

```sh
cp contrib/com.github.ancri.retire.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.github.ancri.retire.plist
```

## Platform support

| Platform | Status |
|---|---|
| Linux | Full. `notify-send`; `DISPLAY`/`DBUS_SESSION_BUS_ADDRESS` filled in for cron |
| macOS | Full. `terminal-notifier` if present, else `osascript`; schedule with launchd |
| Other POSIX | Review runs and logs; only the desktop popup is lost |
| Windows | Not supported |

On APFS, access times behave differently from a Linux `relatime` mount, so the `atime`
signal is less predictable. `mtime`, `ctime` and the count checks are unaffected.

## Caveats

- **Short names are noisy.** `REFERENCED` matches the name as a whole word, literally.
  A two-character name will match unrelated prose. Read the list once, then `ack` it.
- **Scanners that read file contents can still cause false positives.** Bare directory
  listings (`find`, `du`, `ls`) are ignored, but tools that open files (backups, antivirus,
  or search tools sniffing header bytes) still bump file `atime`. Each `TOUCHED` line
  includes the relative path to help tell real reads from scanner noise.
- **`noatime` mounts record no reads at all**, leaving `mtime`, `ctime` and the counts.
- **Cross-filesystem moves are not atomic.** `put` uses `os.rename`, which fails across
  filesystems rather than silently copying 2 GB.
- **Names are basenames.** An entry is named after the last component of its path, and
  two active entries cannot share a name: `put` refuses a second `cache` before moving
  anything. Move such directories into one uniquely named directory and retire that.

## Tests

```sh
make test
```

Exercises the full lifecycle and each detection signal against a scratch ledger.

## License

MIT
