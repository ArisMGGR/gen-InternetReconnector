# InternetReconnector

[![shellcheck](https://github.com/ArisMGGR/gen-InternetReconnector/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/ArisMGGR/gen-InternetReconnector/actions/workflows/shellcheck.yml)

A small tool that keeps your Linux machine connected to a specific Wi-Fi
network. Every 5 minutes (via cron) it checks whether you are still on your
target network; if you are not, it reconnects automatically.

Built for Linux with [NetworkManager](https://networkmanager.dev/) (`nmcli`),
which ships on most desktop distributions (Ubuntu, Fedora, Debian, Mint, …).

## How it works

- **`auto-setup.sh`** — the quickest way in. Asks for your network settings,
  writes `config.env`, tests them by running `reconnect.sh` once, and installs
  the cron job if that test passes. Everything below can also be done by hand.
- **`reconnect.sh`** — reads the SSID of the active Wi-Fi connection with
  `nmcli`. If it already matches your target network, it does nothing. If it
  does not, it reconnects: it makes sure the Wi-Fi radio is on, rescans for
  nearby networks, and brings the connection up.
- **`manual-setup/install-cron.sh`** — installs a cron entry that runs
  `reconnect.sh` every 5 minutes. It is idempotent, so you can re-run it safely
  without creating duplicate jobs.
- **`manual-setup/uninstall-cron.sh`** — removes that cron entry again, and
  optionally the daily log files. Safe to run when nothing is installed.
- **`config.env`** — holds your SSID and password, at the checkout root next to
  `reconnect.sh` (copied from `manual-setup/config.env.example`). It is **not
  committed to git** (it is listed in `.gitignore`).

The two cron scripts and the example config live under `manual-setup/`; run
them from the checkout root as shown below. `reconnect.sh`, `auto-setup.sh`,
`config.env` and `logs/` stay at the root.

## Requirements

- Linux with NetworkManager (`nmcli`). No minimum version is claimed, and none
  is enforced. On an `nmcli` too old to report a saved profile's configured SSID
  (`nmcli -t -f 802-11-wireless.ssid connection show <name>`) the script falls
  back to reading the scan list, which still works — except for a hidden
  network, which never appears in a scan and would then look permanently
  disconnected. If you use `WIFI_HIDDEN="yes"` and see `Wifi Reconnected` on
  every single run, that is the lookup failing; check it by running the command
  above by hand.
- `cron` (for scheduled runs)
- `bash` 4.0 or newer for `reconnect.sh` and `auto-setup.sh` (macOS ships 3.2;
  see [Limitations](#limitations)). Both check the version up front and refuse
  with a stated reason rather than failing on an expansion later.
  `install-cron.sh` and `uninstall-cron.sh` avoid the bash 4 features the other
  two need, but they are only ever tested on bash 4 and newer, and there is
  little point running them without `reconnect.sh`.
- `awk`, `grep`, and coreutils for `date`, `sleep` and `mktemp` — all standard
  on a desktop install, but worth naming if you are running this in a minimal
  container. `reconnect.sh` refuses to start without `date`, `awk` or `nmcli`,
  and says which one is missing. `sleep` is only needed on a run that actually
  reconnects — it paces the scan wait and the gap between retries — so a run
  that finds you already connected does not ask for it. The test suite
  additionally needs `sed`.
- GNU `date` specifically, for log pruning only; everything else works without
  it (see [Limitations](#limitations))
- `flock` (from `util-linux`) is used if present, to stop two runs overlapping

## Setup

### The quick way

```bash
git clone https://github.com/ArisMGGR/gen-InternetReconnector.git
cd gen-InternetReconnector
./auto-setup.sh
```

`auto-setup.sh` asks for the network name, the password (optional — see below),
which Wi-Fi device to use (chosen from the ones `nmcli` reports, or left
automatic), whether the network is hidden, and how often to run. It then writes
`config.env` at mode `600`, runs `reconnect.sh` once to check the answers, and
installs the cron job only if that run succeeds — so a wrong password is caught
while you are still watching, rather than becoming a `FAIL` line every five
minutes with the reason going to `/dev/null`. "Succeeds" is judged by the log
line that run writes, not by its exit status alone: if a scheduled run is still
in progress the test steps aside (`Skipped (already running)`, which is not a
test), and if the run wrote no new line — the log directory could not be
created, or today's log file could not be written to — nothing was confirmed.
In both cases the job is not installed and the script says to re-run. Only a
line appended by that run counts; an older line already in the file does not.

Re-run it any time to change a setting: each current value is offered as the
default, the interval already installed is kept unless you give a new one, and
the previous `config.env` is saved as `config.env.bak` — at mode `600`, whatever
mode the original had, since it holds the same password. Any `RECONNECT_*`
setting already on the installed cron line — a custom config path or log
directory in particular — is used too when the environment does not set it, so
the file the re-run tests is the file the job reads; the script says which
values it took from the line.

Anything you set in the environment rather than type — `RECONNECT_CONFIG`,
`RECONNECT_LOG_DIR`, `CRON_PATH`, `MINUTES` and the numeric `RECONNECT_*` tuning
settings — is checked before the first question, against the same rules
`install-cron.sh` applies, and so are whether `config.env` can actually be read
and written (and, if it already exists, whether the backup can be written
beside it), whether the checkout's own path can be written onto a cron line,
and whether `crontab` is installed at all.
The checkout path is checked first, so a checkout under a directory that
cannot be installed from is refused as that rather than as a bad config path.
For the two path settings that means both rules the installer has: the path must
be absolute, and it must not contain a single quote, a `%` or a line break, none
of which can be written onto a cron line safely. `RECONNECT_LOG_DIR` must also
name a directory that exists or can be created, because `reconnect.sh` treats
one it cannot create as a warning rather than a failure and would otherwise run
every interval without logging anything. `CRON_PATH` and the checkout
path are held to the second of those rules — a `PATH` is a list of directories,
so the installer does not require it to be absolute either. A value that cannot
work is refused straight away rather than at the end of the interview, so a run
that is going to be refused over one of them does not ask for your Wi-Fi password
first.

What that cannot cover is a failure the settings do not predict — a missing
`nmcli`, for instance. Those still surface at the verification run, after the
questions; the message says which kind it is rather than assuming you mistyped
something.

It is a convenience, not a separate mode — it writes the same `config.env` and
calls the same `./manual-setup/install-cron.sh` as the manual steps below, so the two are
interchangeable. `auto-setup.sh` does not ask about the `RECONNECT_*` tuning
settings or `CRON_PATH` — set them in the environment and they are passed
through to `install-cron.sh` as they are, exactly as the manual route does it,
or use the manual route directly if you would rather see them on the command
you are running.

### The manual way

1. **Get the code.**

   ```bash
   git clone https://github.com/ArisMGGR/gen-InternetReconnector.git
   cd gen-InternetReconnector
   ```

2. **Configure your network.** Copy the example config and edit it:

   ```bash
   cp manual-setup/config.env.example config.env
   chmod 600 config.env        # keep the password readable only by you
   nano config.env             # set WIFI_SSID and WIFI_PASSWORD
   ```

   `WIFI_SSID` is required. `WIFI_PASSWORD` is only needed if NetworkManager
   does not already have a saved profile for the network — see
   [Security](#notes--troubleshooting) below.

   `config.env` is parsed, not run as a shell script, so `$`, backticks and
   backslashes in your password are taken literally and need no escaping.

3. **Test it once by hand:**

   ```bash
   ./reconnect.sh
   ```

   It writes one line to today's log file under `logs/`. See
   [Logs](#logs) below for the format.

   `reconnect.sh` takes no arguments — the network settings come from
   `config.env` and the tuning ones from the environment overrides below — and
   it refuses any it is given rather than ignoring them, so a mistyped
   invocation does not quietly reconnect your Wi-Fi instead.

4. **Install the cron job (runs every 5 minutes):**

   ```bash
   ./manual-setup/install-cron.sh
   ```

   Confirm it was added with `crontab -l`. To use a different interval:

   ```bash
   MINUTES=10 ./manual-setup/install-cron.sh
   ```

   `MINUTES` must divide 60 evenly (1, 2, 3, 4, 5, 6, 10, 12, 15, 20, 30).
   Cron restarts its count at the top of each hour, so a value like 7 would
   leave an uneven gap there rather than running every 7 minutes.

   To remove it later:

   ```bash
   ./manual-setup/uninstall-cron.sh
   ```

   That removes only the cron line belonging to this checkout; your other
   cron entries, your `config.env` and your logs are left alone. Add
   `--purge-logs` to delete the daily logs and the lock file as well: it asks
   first, or pass `--yes`; with no terminal to ask at it keeps the logs rather
   than guessing and exits 1, so a scripted uninstall needs `--yes`. The cron
   job is removed either way — only the logs are kept. Use `--dry-run` to see
   what it would remove without changing anything.
   `./manual-setup/install-cron.sh --remove` does the same cron removal and remains
   available.

## Configuration

All settings live in `config.env`:

| Variable        | Required | Description                                                                        |
| --------------- | -------- | ---------------------------------------------------------------------------------- |
| `WIFI_SSID`     | Yes      | The name of the Wi-Fi network to stay connected to.                                |
| `WIFI_PASSWORD` | Sometimes| The password for that network. Not needed once NetworkManager has a saved profile. |
| `WIFI_IFACE`    | No       | A specific Wi-Fi interface to use (e.g. `wlan0`). Leave empty to auto-pick.        |
| `WIFI_HIDDEN`   | No       | Set to `yes` if the network does not broadcast its SSID. Defaults to `no`.         |

The file is read as plain `KEY=VALUE` lines, not executed as a shell script:
values are taken literally, so `$`, backticks and backslashes in a password
need no escaping. Spaces around the `=` are ignored, so `WIFI_SSID = "MyNet"`
and `WIFI_SSID="MyNet"` mean the same thing; quote a value to preserve leading
or trailing spaces inside it. A `#` inside a value is part of the value; only a
whole line starting with `#` is a comment. An unrecognised setting is an error
rather than a silent no-op, and so is the same setting given twice: the file is
read top to bottom, so a forgotten second line would otherwise win in silence.
`WIFI_SSID` must contain at least one non-blank character, and so must
`WIFI_IFACE` when you set it — leave it empty to let NetworkManager pick the
device rather than setting it to spaces, which is rejected as the half-finished
edit it almost always is.

### Environment overrides

These are read from the environment rather than `config.env`. Most are for
testing or for tuning behaviour on a slow machine; `CRON_PATH` is not — on a
distribution that keeps `nmcli` outside the six standard directories it is what
makes the scheduled job work at all. All are optional.
They are deliberately environment-only: `config.env` cannot set them, so a
stray line in that file cannot change where the script reads or writes.

To apply them to the scheduled job, set them when you run the installer — it
writes them onto the cron line and keeps them there when you re-run it:

```bash
RECONNECT_SCAN_WAIT_SECS=5 RECONNECT_CONNECT_ATTEMPTS=2 ./manual-setup/install-cron.sh
```

| Variable                       | Default        | Description                                                        |
| ------------------------------ | -------------- | ------------------------------------------------------------------ |
| `RECONNECT_CONFIG`             | `<script dir>/config.env` | Path to the config file to read.                        |
| `RECONNECT_LOG_DIR`            | `<script dir>/logs`       | Directory the daily log files are written to.           |
| `RECONNECT_SCAN_WAIT_SECS`     | `15`           | How long to wait for the target SSID to appear after a rescan.     |
| `RECONNECT_CONNECT_ATTEMPTS`   | `3`            | How many times to attempt the connect before recording `FAIL`.     |
| `RECONNECT_NMCLI_WAIT_SECS`    | `20`           | Timeout applied to each individual `nmcli` connect call.           |
| `RECONNECT_LOG_RETENTION_DAYS` | `90`           | Delete daily logs older than this many days. `0` keeps them all.   |
| `MINUTES`                      | `5`            | (`install-cron.sh` and `auto-setup.sh`) Run interval in minutes; must divide 60. |
| `CRON_PATH`                    | the six standard system directories | (`install-cron.sh` and `auto-setup.sh`) The `PATH` written onto the cron line. |

`CRON_PATH` is the one to reach for if `nmcli` lives outside
`/usr/local/sbin`, `/usr/local/bin`, `/usr/sbin`, `/usr/bin`, `/sbin` or `/bin`
— NixOS, Guix and source builds all put it elsewhere. Cron gives the job that
`PATH` and nothing else, so the job would not find `nmcli` and would log `FAIL`
every interval while running `./reconnect.sh` by hand kept working.
`install-cron.sh` checks for this at install time and prints the exact command
to re-run, so you should not have to work it out yourself.

`RECONNECT_CONFIG` and `RECONNECT_LOG_DIR` must be absolute paths when you set
them for the installer, which refuses a relative one. Cron runs the job with
your home directory as its working directory rather than the checkout, so a
relative path would not point where it points when you type it — the job would
read a config file that is not there and log `FAIL` every interval.

For the same reason, `./manual-setup/uninstall-cron.sh --purge-logs` only takes the log
directory off the cron line when the value there is absolute. If a line has been
hand-edited to carry a relative one, it is reported and ignored rather than
resolved against wherever you happen to be standing — the cron job is still
removed, and the note tells you how to name the real directory if you want its
logs purged too.

`MINUTES` and `CRON_PATH` are carried across a re-install like the rest:
`./manual-setup/install-cron.sh` with neither set reuses the interval and the `PATH` already
on the installed cron line, and only falls back to the defaults when there is no
line to read them from.

A carried-over value cannot be cleared by passing an empty one — an empty
setting is indistinguishable from an unset one, so `RECONNECT_LOG_DIR=
./manual-setup/install-cron.sh` keeps whatever is already on the line. To get back to the
defaults, take the job out and put it back:

```bash
./manual-setup/install-cron.sh --remove
./manual-setup/install-cron.sh
```

That clears the interval and `CRON_PATH` along with everything else, so pass
`MINUTES` and `CRON_PATH` again if you had changed them. Forgetting `CRON_PATH`
on a machine where `nmcli` lives outside the six standard directories puts the
job straight back to not finding it — `FAIL` every interval, with the reason
going to `/dev/null`.

### Finding your Wi-Fi interface (optional)

Usually you can leave `WIFI_IFACE` empty and NetworkManager picks the right
device. If you have more than one Wi-Fi adapter and want to pin one, list them:

```bash
nmcli device status
```

then set e.g. `WIFI_IFACE="wlan0"` in `config.env`.

## Logs

Every run appends one line to a per-day file under `logs/`, named by date
(e.g. `logs/2026-08-06.log`). Each line is `[HH:MM:SS]` followed by the outcome:

| Line                          | Meaning                                                |
| ----------------------------- | ------------------------------------------------------ |
| `[14:05:00] Wifi Good`        | Already connected to the target network.               |
| `[14:10:01] Wifi Reconnected` | Was disconnected; reconnected successfully.            |
| `[14:15:02] FAIL`             | Could not connect (or a setup error, e.g. bad config). |
| `[14:20:00] Skipped (already running)` | The previous run had not finished; this one stepped aside. |

Every exit path writes exactly one of these lines, so a misconfigured install
shows up as `FAIL` rather than as silence. Run the script by hand to see the
reason on stderr — including the diagnostic `nmcli` itself gave for a failed
connect, with the password scrubbed out.

The `logs/` folder is tracked in git, but the daily `.log` files are gitignored
so your logs stay local. A small `logs/.lock` file is also kept there, which is
how a run detects that a previous one is still going; it is gitignored too, and
`./manual-setup/uninstall-cron.sh --purge-logs` removes it along with the daily logs.

Logs older than 90 days are deleted automatically on each run. Change that with
`RECONNECT_LOG_RETENTION_DAYS`, or set it to `0` to keep everything. Only files
named exactly `YYYY-MM-DD.log` are ever removed, so anything else you keep in
`logs/` is left alone.

## Limitations

- **It checks Wi-Fi association, not internet reachability.** The script
  verifies that you are connected to the target SSID — not that you actually
  have a working internet connection. If you are associated with the right
  network but the link is dead (captive portal, router up but no WAN, ISP
  outage), it logs `Wifi Good` and takes no action.
- **Log pruning needs GNU `date`.** Old logs are deleted by comparing dates,
  which uses `date -d`. On a system without it (BusyBox, macOS) pruning quietly
  does nothing and the logs simply accumulate — everything else still works.
- **A failing run can take longer than a 1- or 2-minute interval.** With the
  default timeouts a run that never manages to connect takes up to roughly
  140 seconds (scan wait, then three connect attempts). At the default 5-minute
  interval that is not a problem. Below about 3 minutes the next run starts
  before this one has finished; it then finds the lock held, exits without doing
  anything, and that interval is simply skipped rather than being handled twice.
  Lower `RECONNECT_SCAN_WAIT_SECS`, `RECONNECT_CONNECT_ATTEMPTS` or
  `RECONNECT_NMCLI_WAIT_SECS` if you need a shorter interval.
  `install-cron.sh` works the worst case out from the timeouts it is actually
  installing, not from the defaults, and warns you whenever it exceeds your
  interval — so raising those settings can trigger the warning at an interval
  that was fine before, and lowering them can silence it at one that was not.
- **A network or profile name that looks like an `nmcli` option is misread.**
  `nmcli` has no end-of-options marker where `reconnect.sh` passes the profile
  name (`connection show <name>`) and the SSID (`dev wifi connect <ssid>`), so a
  name that `nmcli` reads as one of its own flags there — `--active`,
  `--order`, `--ask`, `--show-secrets`, or a dashed prefix of one of those such
  as `-a` — cannot be passed literally. Any other name, including one that
  merely starts with `-`, goes through as written. (An earlier version put a
  `--` in front of both, which `nmcli` took as the name itself; see
  [DECISIONS.md](tests/DECISIONS.md) D6.)
- **The overlap lock needs `flock`.** It comes from `util-linux` and is present
  on ordinary Linux installs. Without it the lock is skipped and two runs at
  once are possible again, which only matters at intervals short enough for a
  run to outlast them.
- **Needs bash 4.0 or newer.** macOS ships bash 3.2 as `/bin/bash`, where
  `reconnect.sh` and `auto-setup.sh` stop with a clear message rather than
  running — `auto-setup.sh` before it asks you for anything, rather than after
  it has taken your password. `./auto-setup.sh --help` still works there, since
  printing usage needs none of the bash 4 features the interview does. A newer
  bash from Homebrew works, but `nmcli` does not exist on macOS anyway (see
  below).

## Notes & troubleshooting

- **Security:** your password lives only in `config.env` (mode `600`,
  gitignored). Once you have connected successfully, NetworkManager stores the
  network in its own connection profile — the same as connecting through the
  desktop UI — and the script then reconnects with `nmcli connection up`, which
  needs no password. If you would rather not store the password at all, connect
  to the network once through the desktop UI and leave `WIFI_PASSWORD` empty:
  the script finds the saved profile and uses it. See
  [SECURITY.md](.github/SECURITY.md) for the full picture, including the two
  cases where the password is passed on a command line — the first connect, and
  any attempt where bringing up the saved profile fails.
- **Cron environment:** cron runs with a minimal environment. The installer
  sets a sane `PATH` so `nmcli` is found, and installs the job under your own
  user rather than root.
- **If every scheduled run logs `FAIL` but running it by hand works:** this is
  almost always polkit. NetworkManager is a system service, and `nmcli
  connection up` is gated by the polkit action
  `org.freedesktop.NetworkManager.network-control`, which several distributions
  grant only to a user with an *active* local login session. A cron job has no
  such session, so the same command that succeeds in your desktop terminal can
  be refused from cron. Check with:

  ```bash
  pkcheck --action-id org.freedesktop.NetworkManager.network-control \
          --process $$ --allow-user-interaction; echo "exit=$?"
  ```

  If it is denied, grant your user the action explicitly by creating
  `/etc/polkit-1/rules.d/50-nm-reconnect.rules` (adjust the user name):

  ```javascript
  polkit.addRule(function (action, subject) {
      if (action.id == "org.freedesktop.NetworkManager.network-control" &&
          subject.user == "yourname") {
          return polkit.Result.YES;
      }
  });
  ```

  This widens what that user may do to NetworkManager without an active
  session; grant it only on a machine where that is acceptable.
- **Scan timing:** `nmcli`'s rescan is asynchronous, so a fresh scan may not
  list the target network for a few seconds. The script waits for the SSID to
  appear (up to `RECONNECT_SCAN_WAIT_SECS`, default 15) and retries the connect
  (`RECONNECT_CONNECT_ATTEMPTS`, default 3) before logging `FAIL`. This is what
  lets an unattended cron run reconnect on its own instead of failing on the
  first, too-early attempt.
- **Bounded runs:** each `nmcli` connect call is bounded by
  `RECONNECT_NMCLI_WAIT_SECS` (default 20), so a run has a predictable worst
  case of roughly 140 seconds rather than hanging indefinitely — the scan wait,
  then each attempt's two bounded `nmcli` calls, plus a 2-second pause between
  attempts. Raise any of those settings and the figure rises with them;
  `install-cron.sh` recalculates it and tells you when it no longer fits your
  interval. At the default 5-minute interval runs never overlap; see
  [Limitations](#limitations) for shorter intervals.
- **Hidden networks:** a hidden network never appears in a scan, so set
  `WIFI_HIDDEN="yes"` in `config.env`. The script then skips the scan wait and
  asks NetworkManager to connect to the hidden SSID directly.
- **Not on Linux / not using NetworkManager?** This relies on `nmcli`. On
  macOS or systems using `iwd`/`wpa_supplicant` directly, the connect command
  would need to be adapted — open an issue and it can be added.

## Contributing

There is a test suite, and it is safe to run anywhere: it stubs `nmcli` and
`crontab`, so it needs no NetworkManager, no cron, no root and no network, and
it cannot touch your real crontab, logs or Wi-Fi.

```bash
./tests/run-tests.sh
```

Bug reports and pull requests are welcome — see
[CONTRIBUTING.md](.github/CONTRIBUTING.md) for setup and the checks CI runs.
Security issues should go through [SECURITY.md](.github/SECURITY.md) rather
than a public issue. This project follows a
[Code of Conduct](.github/CODE_OF_CONDUCT.md).

[DECISIONS.md](tests/DECISIONS.md) records the known trade-offs — things a review will
reasonably flag that were considered and deliberately left alone, each with the
condition that would make it worth revisiting. Worth a look before reporting one
of them.

## License

Released under the [MIT License](LICENSE).
