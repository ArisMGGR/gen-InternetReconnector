# Decisions

Things a review will reasonably flag that were looked at and deliberately left
as they are. Each entry records the reasoning and, more usefully, the condition
under which it should be revisited. If a condition below now holds, the item is
live again and worth raising; if you disagree with the reasoning, argue with the
reasoning rather than reporting the item as undiscovered.

Entries are numbered once and never renumbered, because the scripts and the
suite cite them by number.

## D1 — polkit refuses `nmcli connection up` from cron, and this tool does not work around it

**What a review sees:** on several distributions every scheduled run logs `FAIL`
while `./reconnect.sh` by hand works, because
`org.freedesktop.NetworkManager.network-control` is granted only to a user with
an active local session and a cron job has none.

**Decision:** document it (README, "Notes & troubleshooting") and leave the
polkit rule to the user. The tool does not install a rules file under
`/etc/polkit-1/rules.d/`, does not escalate with `sudo`, and does not detect the
condition at install time.

**Reasoning:** the fix is a system-wide grant that widens what the user may do
to NetworkManager without a session. That is the user's call to make on a
machine they administer, not something an installer running as an ordinary
user should do — and it cannot do it without root anyway. Detecting it at
install time would need `pkcheck` and a way to simulate "no session", which is
more machinery than the note in the README, and a wrong guess in either
direction is worse than none.

**Revisit when:** NetworkManager or polkit grows a per-user, non-root way to
grant `network-control` for unattended use; or a distribution-independent check
exists that `install-cron.sh` could run without `pkcheck`.

## D2 — the shellcheck version in the workflow is not pinned

**What a review sees:** `.github/workflows/shellcheck.yml` uses whatever
`shellcheck` the runner image ships and only installs one if it is missing, so a
new release can turn the job red with no change to the scripts.

**Decision:** leave it unpinned; print the version in the log.

**Reasoning:** a new style-level rule is usually worth hearing about, and the
version in the log is what makes an unexplained red job explainable in seconds.
Pinning trades that for silence about new rules.

**Revisit when:** a release breaks the job in a way that is not worth acting on
and the fix would be a per-rule `disable` in every script — at that point pin
the version here and record the release that prompted it.

## D3 — the password is scrubbed out of `nmcli`'s errors by literal substring, nothing more

**What a review sees:** `remember_error()` in `reconnect.sh` replaces exact
occurrences of `$WIFI_PASSWORD` with `***` and otherwise passes `nmcli`'s stderr
through to a hand-run's stderr.

**Decision:** keep it a substring replacement.

**Reasoning:** the only place the password is handed to `nmcli` is as an
argument, and the only realistic leak is `nmcli` echoing an argument back
verbatim, which is what the replacement covers. A password echoed transformed
(URL-encoded, truncated, hex) would slip through, but no `nmcli` release does
that, and a filter broad enough to catch a transformed secret would also eat
the diagnostic the message exists to show. The scrubbed text goes to stderr
only — never to the log file, which records `FAIL` and nothing else.

**Revisit when:** any `nmcli` release prints a secret in a form other than the
argument as given; or the diagnostic starts being written anywhere other than a
hand-run's stderr.

## D4 — log pruning checks the shape of a name, not that it is a date

**What a review sees:** `prune_logs()` deletes any `NNNN-NN-NN.log` that sorts
before the cutoff. `2026-13-99.log` passes the shape test, sorts after every
real cutoff, and is never pruned.

**Decision:** leave it as a shape test.

**Reasoning:** the rule that matters is that nothing outside this project's
naming scheme is ever deleted, and the shape test guarantees that. An impossible
date erring towards *not* being deleted is the harmless direction. Real date
validation buys nothing for files the script itself never writes.

**Revisit when:** something in this tree starts writing date-shaped names that
are not dates, or a user reports the directory filling with them.

## D5 — without `flock` there is no overlap lock at all

**What a review sees:** `reconnect.sh` takes its lock only when `flock` is on
`PATH`. Where it is missing, two runs can overlap exactly as they did before the
lock existed.

**Decision:** degrade to no lock rather than refuse to run or emulate a lock.

**Reasoning:** `flock` comes with `util-linux` and is present on every ordinary
Linux install. The alternatives — a lock directory with `mkdir`, or a pid file —
each need stale-lock recovery that is easy to get wrong, and getting it wrong
means every later run steps aside forever, which is worse than an occasional
overlap. `install-cron.sh` still warns about intervals shorter than the worst
case, and the README lists the limitation.

**Revisit when:** a supported platform ships without `flock`; or an overlap is
reported that the interval warning did not predict.

## D6 — the profile name and the SSID are passed to `nmcli` bare, with no `--`

**What a review sees:** `profile_ssid()` runs `nmcli ... connection show NAME`
and `connect_with_password()` runs `nmcli ... dev wifi connect SSID`, and a name
that `nmcli` reads as one of its own options in that position (`--active`,
`--order`, `--ask`, `--show-secrets`, or a dashed prefix of one of those such
as `-a`) is misread.

**Decision:** pass both bare, and document the names that cannot be used
(README, "Limitations").

**Reasoning:** `nmcli` has no end-of-options marker in either position. Its
argument walker (`next_arg()` in `src/nmcli/utils.c`) consumes only what
`nmc_arg_is_option()` recognises, and a bare `--` is not that, so
`connection show -- NAME` looked up a profile literally called `--` and
`dev wifi connect -- SSID` took `--` as the SSID and refused the real one as an
extra argument. Checked against NetworkManager 1.10.6 through `main`; the only
`--` `nmcli` understands anywhere is `connection add`'s option/property
separator. An earlier version put a `--` in front of both, every real lookup
and every real password connect failed, and the suite stayed green because its
stub stripped the `--` itself. The stub no longer strips anything, and the
suite pins the bare shape on an SSID beginning with `-`. `connection up id
NAME` is different: `id` marks the next argument as its value, so that path
takes any name.

**Revisit when:** `nmcli` grows a `--` (or an `id`-style selector) for
`connection show` or `dev wifi connect`. Then it can be put back — on that
release and later only, which means a version check.

## D7 — `uninstall-cron.sh` recognises our cron line more loosely than `install-cron.sh` does

**What a review sees:** `install-cron.sh`'s `ours()` claims a line only when it
is not a comment, ends with the marker, and names this checkout's
`reconnect.sh` as a shell word; `uninstall-cron.sh`'s `our_cron_lines()` skips
comments and then accepts the marker anywhere on the line, with the path quoted
or as a whole word. The two can disagree about a hand-edited line.

The path used to be a bare substring too, and that was looser than this
decision needs: it also matched another checkout whose absolute path merely
ends in this one's (`/home/u/ir` inside `/mnt/backup/home/u/ir`), so the
uninstaller reported that job as its own and `--purge-logs` read the other
job's log directory off it and deleted its logs. The path rule is now exactly
the one `install-cron.sh` applies (plus the double-quoted spelling), which
keeps every line `--remove` would delete in the report. `auto-setup.sh` reads
settings back off the line with the same rule.

**Decision:** keep the two rules different, with the strict one deciding what
is deleted and the loose one deciding what is reported.

**Reasoning:** deletion must never claim a line it did not write, so the
installer's test is strict. Reporting has the opposite risk: an uninstall that
says "nothing found" over a job still running every interval is the failure the
uninstaller exists to prevent, so its test is loose. The one case where the
looseness shows is a line edited past what the installer recognises: the
uninstaller reports it, `--remove` correctly leaves it, the post-condition check
then says the job is still installed and exits 1 with instructions to remove it
by hand. That is the right outcome, and the suite pins it. Both scripts, and
`auto-setup.sh` when it reads settings back off the line, treat a commented-out
line as not ours, because that is the one place a disagreement would produce a
false "still installed".

**Revisit when:** a line the installer would remove is one the uninstaller
fails to report — that is the direction the looseness must never fail in; or if
the uninstaller ever grows a deletion of its own, at which point it must use the
installer's rule.
