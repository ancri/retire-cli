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
`review` is read-only by design: it reports a verdict and never acts on it.

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
  atime slack     36 h
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
| `retire list` | Show the ledger |
| `retire review [--notify]` | Read-only safety check |
| `retire ack <name>` | Accept the current references as known |
| `retire rebaseline <name>` | Reset the tripwire snapshot |
| `retire restore <name>` | Move it back |
| `retire purge <name> --yes` | Actually delete it |
| `retire doctor` | Report the local setup |

`retire`, `retire ?` and `retire help <command>` all print documentation.
Full reference: `man retire`.

## What review detects

| Signal | Catches |
|---|---|
| `TOUCHED` | Newer `atime` (reads), `mtime` (writes), or `ctime` (rename, chmod, chown) |
| `DRIFT` | Entry count or byte count changed — files added or deleted inside |
| `REFERENCED` | The name still appears in your configured source roots |
| `UNVERIFIED` | The reference check could not run — reported, never passed off as clean |

An entry is `INVESTIGATE` if any of those fire, `SAFE TO PURGE` once the review date
passes cleanly, and `holding` otherwise.

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
  "atime_slack_hours": 36,
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
- **Scanners cause false positives.** Backup and indexing tools walk the tree and bump
  `atime`. A directory listing counts as a read. This is deliberately conservative.
- **`noatime` mounts record no reads at all**, leaving `mtime`, `ctime` and the counts.
- **Cross-filesystem moves are not atomic.** `put` uses `os.rename`, which fails across
  filesystems rather than silently copying 2 GB.

## Tests

```sh
make test
```

Exercises the full lifecycle and each detection signal against a scratch ledger.

## License

MIT
