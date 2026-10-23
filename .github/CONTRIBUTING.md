# Contributing

Bug reports and pull requests are welcome. This is a small project — four
shell scripts and a test suite — so the process is deliberately light.

Security problems should **not** go through a public issue. See
[SECURITY.md](SECURITY.md).

## Getting set up

There is nothing to build and nothing to install. Clone the repository and copy
the example config:

```bash
git clone https://github.com/ArisMGGR/gen-InternetReconnector.git
cd gen-InternetReconnector
cp manual-setup/config.env.example config.env
chmod 600 config.env
```

Then edit `config.env` with a network you can actually connect to, and run
`./reconnect.sh` by hand. Every run appends one line to `logs/YYYY-MM-DD.log`
and prints the reason for a failure on stderr.

To work on the cron scripts without touching your real crontab at all, run the
test suite. It puts a file-backed `crontab` stub on `PATH`, so it exercises the
install, re-install and removal paths against a fake:

```bash
./tests/run-tests.sh -v
```

There is **no** environment variable that redirects `install-cron.sh` away from
your real crontab — `RECONNECT_LOG_DIR` only changes the log path written *onto*
the cron line, not where the line goes. If you want to see a real install, do it
deliberately and undo it afterwards:

```bash
RECONNECT_LOG_DIR=/tmp/ir-logs ./manual-setup/install-cron.sh   # writes your real crontab
crontab -l
./manual-setup/uninstall-cron.sh                   # removes it again
```

`./manual-setup/uninstall-cron.sh --dry-run` reports what *would* be removed and changes
nothing, so it is a report rather than an undo — run it without `--dry-run` to
actually take the job back out.

## Checks that run in CI

One workflow, [`shellcheck.yml`](workflows/shellcheck.yml), runs on every push
and pull request. It checks five things:

- `shellcheck --severity=style` over all five scripts, the suite included
- `bash -n` on each script (shellcheck does not catch every parse error)
- that all five scripts are executable
- that no script has CRLF line endings
- the test suite, `tests/run-tests.sh`

Please run both locally before opening a pull request. Note that the lint covers
the suite too — leaving it off is the easy way to be clean locally and red in CI:

```bash
shellcheck --shell=bash --severity=style reconnect.sh manual-setup/install-cron.sh manual-setup/uninstall-cron.sh auto-setup.sh tests/run-tests.sh
./tests/run-tests.sh
```

### What the tests cover, and what they do not

`tests/run-tests.sh` needs nothing but `bash`, `awk`, `sed`, `grep` and
coreutils — no NetworkManager, no cron, no root. It stubs both `nmcli` and
`crontab` with file- and environment-backed fakes (the `nmcli` stub reproduces
nmcli's terse escaping, which is what makes the connect paths testable at all)
and points the scripts at temporary directories, so it can cover the parts that
are pure text processing:

- the `config.env` parser (quoting, spacing, comments, CRLF, a UTF-8 BOM,
  unknown keys, duplicated keys, an empty key, and a `WIFI_SSID` or
  `WIFI_IFACE` of nothing but blanks)
- a config file that is unreadable, or that is a directory rather than a file —
  both used to reach `load_config`'s redirect and exit with no log line at all.
  The unreadable case self-skips on a filesystem that does not enforce the mode
- the terse-`nmcli` field unescaper
- the `RECONNECT_*` environment overrides `reconnect.sh` validates, and the
  preflight order that puts `date` ahead of the config read
- the 18-digit width rule the two scripts share, pinned on both sides.
  `reconnect.sh` bounds these settings with `test`, which refuses an
  out-of-range integer, and `install-cron.sh` with `$(( ))`, which wraps in
  silence — so the installer used to accept values the scheduled job then
  refused, which is a clean install followed by `FAIL` every interval. The
  boundary is pinned as well as the rule: 18 digits accepted and 19 refused, on
  each side. A 20-digit value is refused by any bound the rule might drift to,
  so testing only that one leaves a one-digit disagreement between the two
  scripts invisible
- the exit status each outcome produces — a systemd unit, a wrapper or a
  monitoring check keys off that rather than off the log, so it is part of the
  contract
- log pruning, including its refusal to touch files it did not write
- the overlap lock, and the `Skipped (already running)` line it produces (this
  one self-skips where `flock` is missing). The same block checks that `nmcli`
  does not inherit the lock descriptor, which a child outliving the run would
  otherwise hold indefinitely
- the two install-time `nmcli` warnings — missing outright, and present outside
  the `PATH` written onto the cron line — and `CRON_PATH` itself: honoured,
  carried across a re-install, and vetted like every other value that reaches
  the crontab
- crontab line classification: idempotent re-install, carry-over of `MINUTES`
  and the `RECONNECT_*` settings, preservation of unrelated entries, the
  handling of lines belonging to a different checkout, and lines a hand-edit
  left a trailing blank on or an indent in front of — the second of which used
  to throw the carried-over interval away in silence
- the trailing-slash normalisation in the install-time `nmcli` PATH check,
  without which it warned about a `PATH` that was already correct
- the vetting of values written onto the cron line — a single quote, a `%` and a
  line break are each refused, the last because no quoting survives it
- the overlap warning, which is worked out from the timeouts actually being
  installed rather than from the defaults, including its overflow guard — the
  18-digit width rule bounds each value and this figure multiplies two of them,
  so an unchecked product wrapped and the warning went silent for the very
  configuration furthest past the interval
- `reconnect.sh`'s refusal of any argument, which used to be accepted and
  ignored while the run went on to drive `nmcli`
- argument handling shared by all five scripts: that an *empty* argument is an
  argument rather than the absence of one — `install-cron.sh` matched it with a
  `'')` arm and installed the job, which is the surprise its argument policy
  exists to prevent. The four shipped scripts also quote the rejected value in
  the refusal, because unquoted an empty or blanks-only one produced a message
  naming nothing at all; `tests/run-tests.sh` is the exception and is not
  covered for it, since its own refusal prints the usage line and names no
  value. The quoting rule reaches further than the argument refusals — the
  numeric settings `reconnect.sh` and `install-cron.sh` validate are quoted too,
  and a blanks-only `MINUTES`, `RECONNECT_CONNECT_ATTEMPTS` and
  `RECONNECT_SCAN_WAIT_SECS` are each pinned. `tests/run-tests.sh` is covered
  for the arity half as one of the five: it read
  `${1:-}` and never `$#`, so `-v --bogus` ran the whole suite in silence while
  `--bogus` alone exited 2. Those assertions run the suite as a child under
  `IR_ARGV_PROBE`, which makes it report what its parser decided and stop — a
  child given arguments the parser wrongly accepts would otherwise run the suite
  and reach the same assertions itself, recursively, which is precisely what the
  regression under test produces. If you touch that parser, keep the guard
- that a precondition is never enforced on a path that does not use the thing it
  checks: the `MINUTES` setting and the `date` preflight do not block a removal,
  `chmod` does not block an install whose scripts are already executable, `cat`
  blocks neither an install nor an uninstall that never has to print usage,
  `rm` blocks neither an uninstall that has nothing to remove, nor a
  `--dry-run` that deletes nothing, nor a `--purge-logs` with nothing to purge —
  while a lone `logs/.lock` still brings that check back, since it is a purge
  target in its own right — `grep` blocks neither a removal with nothing to remove
  nor a first install — `install-cron.sh` no longer runs it at all, while
  `uninstall-cron.sh` still runs one, in `read_crontab()`, and still refuses
  without it — and `sleep` does not block an already-connected run.
  Each case is pinned on a `PATH` built for it, from which the preflighted tool
  under test is absent — some of those `PATH`s deliberately omit other commands
  too, such as the `rm` case's missing `crontab`, which is what makes it a run
  with nothing to remove — and the assertion names the missing command rather
  than resting on the exit status, so deleting one preflight cannot be masked by
  another still firing. An earlier version used one `PATH` missing two commands
  and asserted only on the exit status, which either check alone satisfied
- the crontab-safety guards — a failing `crontab -l`, a failing write, a failing
  `crontab -r` and a failing classifier must each refuse, say why, and leave the
  user's unrelated entries exactly as they were. The `crontab` stub takes
  `CRONTAB_FAIL`, `CRONTAB_FAIL_RC` and `CRONTAB_FAIL_MSG` to arrange this
- a crontab larger than the pipe buffer. This is a size rather than a shape, so
  it needs its own fixture: the helpers that answered "are there any entries?"
  and "is one of them ours?" were pipelines into a reader that stops at the
  first match, and past roughly 64 KiB the builtin `printf` feeding them was
  killed by `SIGPIPE`, which `set -o pipefail` then turned into the answer. An
  install replaced a 2,000-entry crontab with its own single line and reported
  success; a `--remove` reported "nothing to remove" over a job it left
  scheduled. Both directions are pinned, the second with our line at the front
  of the crontab, because that is where the early exit bites
- `uninstall-cron.sh`'s own behaviour: `--dry-run`, `--purge-logs` with its
  confirmation prompt and `--yes`, the refusal where there is no terminal to ask
  at (and the two different consequences it reports, depending on whether a job
  was removed first), the `logs/.lock` file as a purge target in its own right,
  reading the log directory back off the installed cron line, the post-condition
  check that catches a hand-edited line surviving `--remove`, the marker
  constant it shares with `install-cron.sh`, a job the user disabled by
  commenting it out, and an unrecognised argument being refused wherever it sits
  relative to `--help`
- that the log directory is taken off the cron line only when it is **absolute**.
  `install-cron.sh` refuses to write a relative one because cron runs the job
  from your home directory while `uninstall-cron.sh` resolves it against wherever
  you ran it from — and reading one back anyway applied that mismatch to a
  deletion, purging `YYYY-MM-DD.log` files out of whatever directory the caller
  happened to be standing in. The control is an absolute value still being
  honoured, without which the guard could be "stop reading the line" and every
  assertion would still pass
- `uninstall-cron.sh` on a machine with no `crontab` command at all, which is a
  run with nothing to remove rather than a failed removal
- `auto-setup.sh` end to end, driven by piping the answers in: the four
  `config.env` settings it writes and the interval it installs, an interface
  chosen by number off the offered list and one typed by hand, a skipped
  password, re-prompting on every bad answer, and a re-run keeping each current
  value — including the interval, which it leaves to `install-cron.sh` rather
  than defaulting to 5 and undoing the carry-over. Also that blanks inside an
  SSID or a password survive (`read` strips them without `IFS=`), that a
  password is never printed in the output (and, since a pipe cannot observe
  terminal echo, that the prompt is read with `-s`, pinned on the source rather
  than on behaviour), that settings `reconnect.sh` rejects stop
  the run before the crontab is touched, and that running out of input is a
  stated failure rather than consent. `read -p` shows its prompt only on a
  terminal, so nothing there asserts on prompt text — the observables are the
  file it writes, the crontab, the exit status and the unconditional output
- `auto-setup.sh`'s interface prompt held to the same 18-digit width rule as
  every other numeric input, so an over-wide answer is re-asked without bash's
  own `integer expected` reaching the screen, with a leading-zero answer still
  selecting from the list as the control; that it refuses a checkout missing
  `reconnect.sh` or `install-cron.sh` *before* the interview rather than after
  it, asserted on no `config.env` having been written; and that a `config.env`
  carrying a UTF-8 BOM re-runs without retyping anything, which `reconnect.sh`
  always tolerated and `existing_value()` did not
- both of `auto-setup.sh`'s numeric prompts pinned **at** the 18-digit boundary
  and not only past it, the same way the `reconnect.sh`/`install-cron.sh` pair
  is. A 23-digit answer is refused by any width rule the guard might drift to,
  so it says nothing about where the line is drawn: widening either constant
  from 18 to 19 left the whole suite green while the interface prompt leaked
  `[: 9999999999999999999: integer expected` and the interval prompt reported
  `got: '-8446744073709551617'`. The interval prompt pins both edges, since its
  width refusal and its range refusal are worded differently; the interface
  prompt can only pin the upper one, because both of its refusals print the
  same line
- the two values `auto-setup.sh` never asks for but hands on — `MINUTES` and
  `RECONNECT_LOG_DIR` — refused before the interview rather than by
  `install-cron.sh` at the end of it. `MINUTES` was passed through unexamined,
  so `MINUTES=7 ./auto-setup.sh` announced the interval, asked every question,
  took the Wi-Fi password and wrote `config.env` before failing on a value it
  had been given at the start. The typed answer and the environment value share
  `check_interval()` now, so the assertions pin that both refusals carry the
  same words, and each case asserts no `config.env` was written — exit 1 alone
  cannot tell "refused up front" from "refused at the end". The controls are a
  legal `MINUTES` still skipping the question, and a leading-zero one still
  being normalised
- the rest of what `auto-setup.sh` hands on without reading — the four numeric
  `RECONNECT_*` settings — and whether `config.env` can be written at all. Those
  were the half of the same rule left undone:
  `RECONNECT_CONNECT_ATTEMPTS=abc ./auto-setup.sh` asked every question and took
  the Wi-Fi password before `reconnect.sh` refused it at the verification run,
  and a `RECONNECT_CONFIG` in a directory that does not exist did the same before
  dying at the write. The numeric rules are `install-cron.sh`'s, so the
  assertions pin its wording rather than a second set written here. The first
  case is driven with a *complete* set of answers deliberately: given no stdin
  the run dies at the first prompt anyway, so "no `config.env` was written" would
  hold whether or not the refusal came first. Controls: zero for the two settings
  whose minimum is 0, a leading-zero attempts count reaching the cron line
  intact, and an ordinary writable config path still working
- that the advice printed when the verification run fails does not assert a cause
  the run cannot know. It used to say the reason "usually means one field is
  wrong", which is true only when `reconnect.sh` refused an *answer* — for a
  missing `nmcli`, `awk` or `date` it sent the reader back through the interview
  to correct a field that was never wrong. Pinned on the fixture where the old
  wording happened to be right, since that is where a revert would look harmless before it is announced
- the two path settings `auto-setup.sh` hands on — `RECONNECT_CONFIG` and
  `RECONNECT_LOG_DIR` — held to **both** of `install-cron.sh`'s rules before the
  interview rather than only to absoluteness. A single quote, a `%` or a line
  break in either is refused up front, with that script's own wording, where
  before the value was absolute, passed, and was refused only after every
  question had been asked and the Wi-Fi password read — and for
  `RECONNECT_CONFIG` the password had by then been written to a path that can
  never be installed. Each case asserts the interview never printed a word,
  because exit 1 is what both the up-front refusal and the refusal at the end
  produce. The control is a directory containing a space: that is quotable and
  `install-cron.sh` accepts it, so refusing it here would refuse a run that
  would have installed. A `config.env` that is writable but not readable is
  covered in the same block, since it is read twice — by `existing_value()` and
  by the `cp` that makes the `.bak` — before anything is written
- the other two values `install-cron.sh` vets with that same rule, which the
  block above did not reach: `CRON_PATH`, and the checkout's own install path.
  `CRON_PATH` is the reachable one — one deliberately-set variable, and the
  README tells you to set it when `nmcli` lives outside the six standard
  directories — and it took the whole interview and the Wi-Fi password before
  `install-cron.sh` refused it, under closing advice to re-run
  `./install-cron.sh` that fails identically. The install path needs
  `RECONNECT_CONFIG` pointed somewhere clean as well, because the default
  `config.env` sits beside the script and so carries the same character and is
  caught first; the fixture sets it, or the case would pass against a script
  that never looked at the install path at all. Controls: a legal `CRON_PATH`
  still reaching the cron line, and a checkout path containing a space, which is
  quotable. The quoted-directory case self-skips where the filesystem will not
  take such a name
- that the install path is vetted *before* the config path, not merely as well.
  With `RECONNECT_CONFIG` unset the config lives beside the script and inherits
  its quote, so both checks refuse a quoted checkout — but with the config check
  first the refusal named `RECONNECT_CONFIG`, a variable the user had never set,
  and following it earned a second refusal for the same root cause. Pinned with
  the right name present and the wrong one absent, since either order exits 1
  before the interview
- a `config.env` that is readable and writable in a directory that is not: the
  `.bak` is created beside it and needs the directory, so the three file checks
  let the run take the whole interview and die at the `cp`. The exception — an
  existing writable `.bak`, which needs no directory permission — is pinned as
  the control. Self-skips where the filesystem does not enforce a directory mode
- that the `.bak` gets mode 600 of its own rather than the mode it was copied
  from. A hand-made 644 config produced a 644 backup holding the same password
  while the new config was tightened to 600 and the run said nothing. Self-skips
  with the config-mode check, where the mode is not enforced
- `install-cron.sh`'s absolute-path refusal quoting the rejected value — the one
  refusal in that script left bare after the rest were quoted. A blanks-only
  `RECONNECT_CONFIG` or `RECONNECT_LOG_DIR` is not empty, so it reaches the
  check, and unquoted the message read `got:  .` — from the environment, and
  from a value already on the installed line, where every re-install refused it
  with nothing visible to correct
- that a precondition sits on the branch that uses the command and not merely on
  a branch above it. `uninstall-cron.sh` runs one `grep`, inside
  `read_crontab()`, and only when `crontab -l` *fails*; the check for it used to
  be gated on there being a `crontab` command at all, which is a wider path, so
  on a machine with a crontab and no `grep` every run was refused — `--dry-run`
  included — over a command none of them invoke. Both directions are pinned,
  because either alone passes with the gate at the wrong level
- that the ignore rules actually match the files this tool writes a password
  into. They are matched as globs rather than searched for as text: a
  `grep`-for-the-name check is satisfied by a comment or by a negation, and it
  stayed green while `wifi.env.bak` — the backup `auto-setup.sh` writes when
  `RECONNECT_CONFIG` names a config under any other name — was covered by no
  pattern at all
- a `grep` that is present and *fails*, which a `command -v` preflight cannot
  see. `uninstall-cron.sh`'s `our_cron_lines()` was three greps ending in
  `|| true`, so a failure was indistinguishable from "no line of ours" and the
  uninstall reported success over a job it had left running; it is a shell
  `case` now. The empty-crontab case with the same broken grep has the opposite
  right answer and is pinned separately — `read_crontab()` still needs grep to
  tell "no crontab yet" from a failed read, so it refuses rather than guessing
- which `nmcli` calls a connect actually makes, including when the password form
  is reached — the property `SECURITY.md` documents — and how the names reach
  `nmcli`. The SSID in the password form is passed with nothing in front of it:
  it carried a `--` for a while, meant as an end-of-options marker; `nmcli` has
  none there, so the `--` *was* the SSID, every real password connect failed,
  and the suite stayed green because its stub stripped the `--` itself
  ([DECISIONS.md](../tests/DECISIONS.md) D6). Pinned on an SSID beginning with
  `-`, the one input a `--` would be put back for. The profile lookup goes
  through `connection show id NAME`, so a profile named `--active` or `id` is
  found and brought up; the stub answers only that spelling
- that a day file `reconnect.sh` cannot append to produces its own `WARNING`
  and not bash's `Permission denied` ahead of it — the printf's redirections
  were ordered so that stderr was silenced only after the open had already
  failed out loud. Self-skips where modes are not enforced
- that `auto-setup.sh` judges its verification run by the log line it wrote and
  not by its exit status. `reconnect.sh` exits 0 when it steps aside because its
  overlap lock is held, so a re-run while the scheduled job was mid-run installed
  untested settings under "Settings work". Pinned with the lock held and a wrong
  password, with the lock-free run as the control; self-skips without `flock`.
  And that the outcome it judges by is *this run's*, reported through
  `IR_OUTCOME_FILE` rather than read off the day file, because "the last
  line" let a stale one in an unwritable file stand in for the
  outcome. Pinned with a stale `Wifi Good` in a file made unwritable during the
  run (refused as having written nothing; self-skips where modes are not
  enforced) and, as
  the control, a stale `FAIL` in a writable one that must be passed over
- that a `RECONNECT_LOG_DIR` which can never be created is refused before the
  interview: `reconnect.sh` treats one it cannot create as a warning rather than
  a failure, so the verification run passed over it and the installed job never
  wrote a line. An ancestor that is a file is pinned everywhere, an unwritable
  parent self-skips where modes are not enforced, and the control is a directory
  that does not exist yet under a writable parent, which must still install
- that `auto-setup.sh` takes the `RECONNECT_*` settings already on the installed
  cron line when the environment does not set them, the way `install-cron.sh`
  carries them across a re-install. It resolved them from the environment alone,
  so a plain re-run over a job installed with a custom `RECONNECT_CONFIG` wrote
  and verified `<checkout>/config.env`, printed "Settings work", and
  re-installed a job still reading the other file. Pinned on the config path,
  the log directory and a tuning value, with the environment still winning as
  the control, and the third copy of the marker constant held to the other two
- a mistyped password line containing `=` is reported without echoing the
  password; a `.lock` path that cannot be opened
  skips the lock instead of ending the run with no log line; a line of ours
  edited after the marker is reported on install and on `--remove`; another
  checkout whose path ends in this one's is neither adopted by `auto-setup.sh`
  nor purged by `uninstall-cron.sh`; the no-terminal purge refusal says a line
  is still installed when one is; and `auto-setup.sh` refuses a machine with no
  `crontab` before the interview, prints the carry-over notes under its header,
  names the installed interval at the interval prompt, and reports an unreadable
  day file in its own words
- a password typed straight after its setting name, with no separator, is not
  echoed either; the ignore-rule matcher honours `!` the way git does, so the
  `*.env.*` / `!*.env.example` pair is read correctly; `uninstall-cron.sh`
  refuses rather than reading the crontab as empty when it cannot create its
  temporary file; `auto-setup.sh` says when the verification run never tried
  the password it was just given; and the interval-prompt assertion is pinned
  on the prompt's own wording, not on text the installer also prints
- a `CRON_PATH` that reaches `nmcli` but not `bash` is warned about at install
  time, because the job could then never start; `auto-setup.sh` refuses a
  crontab that exists but cannot be read (cron.allow, cron.deny) before the
  interview rather than after it; and a checkout reached through a symlink is
  the same checkout to every script that reads the cron line, including a line
  an earlier version wrote through the symlink. The symlink case self-skips
  where `ln -s` does not make a real link
- the three crontab readers agreeing about a failed `crontab -l` whose stderr is
  a lone newline (refused by all three), and about BusyBox's
  "can't open '<user>': No such file or directory" (read as "no crontab yet",
  while the same message with another reason is still refused — matched on
  BusyBox's source, not run against a real BusyBox cron); `auto-setup.sh`
  refusing a machine without `mktemp`, `awk`, `rm` or `date` before the
  interview, and reporting an installed interval `install-cron.sh` would refuse
  rather than offering to keep it; and an exported `CDPATH` not breaking a script
  run by a bare relative path such as `bash manual-setup/install-cron.sh`
- `install-cron.sh` noting a `RECONNECT_CONFIG` that exists but is not a regular
  file or cannot be read, and not only one that is missing, since `reconnect.sh`
  refuses all three. The unreadable case self-skips where modes are not enforced
- `auto-setup.sh` judging its verification by the outcome that run itself
  reported (through `IR_OUTCOME_FILE`), so a line the scheduled job appends to
  the same day file meanwhile cannot stand in for it, in either direction; a
  target that is the second of two active Wi-Fi connections still counting as
  connected, with a pinned `WIFI_IFACE` still ignoring the other device; and
  `auto-setup.sh` refusing a re-run without `cp` before the interview
- `auto-setup.sh` putting the previous `config.env` back (or removing a new
  one) when its verification is refused while a job is installed, so that job
  keeps the settings it had, after a failed run and after a skipped one; a last
  answer with no newline after it being an answer rather than end of input; the
  interval prompt reporting a schedule that is not `*/N`, and a line edited
  after the marker, as intervals that cannot be kept; and
  `uninstall-cron.sh --dry-run` asking `install-cron.sh --remove-dry-run` what
  would be removed, so a line `--remove` will leave is reported as left
- a line of this checkout's with the path put in double quotes being reported
  by `install-cron.sh` as edited by hand, not as another checkout's line to be
  removed "from that copy"
- the suite clearing every setting the scripts read from the environment before
  it runs anything. It used to inherit them, so with `RECONNECT_CONFIG` and
  `RECONNECT_LOG_DIR` exported in your shell the cases that test the defaults
  wrote over your real config and purged your real logs. Its own knobs
  (`SCAN_WAIT`, `ATTEMPTS`, `NMCLI_WAIT`, `RETENTION`, `RACE_*`) are cleared
  with them, and the argument probe exits 3 rather than 0, so an exported
  `IR_ARGV_PROBE` cannot turn a run that tested nothing into a green one
- `auto-setup.sh` refusing, before the interview, a log directory it cannot
  write — the default `logs/` as well as a `RECONNECT_LOG_DIR` — and a day log
  it cannot append to, such as one an earlier `sudo ./reconnect.sh` left. Those
  used to surface only after every question and the password. The readback
  that catches what the check cannot foresee is pinned separately, with the
  day file made unwritable during the run
- `install-cron.sh` leaving the checkout's modes alone on an install it then
  refuses over a bad setting; the executable bits are set only once every value
  has been vetted. Self-skips where the filesystem does not drop the bit
- `auto-setup.sh` refusing when `install-cron.sh` fails after the test passed:
  it says whether the job already installed was left in place rather than
  claiming none is installed, and the `install-cron.sh` command it suggests
  carries the interval chosen at the prompt and any `RECONNECT_*` or
  `CRON_PATH` setting of this run. The assertions run that command as printed
  and check what it installs, with all seven of those settings set at once
- `auto-setup.sh` taking `-` on a re-run to clear a stored password or interface,
  since Enter keeps them; the typed-name and numbered-list interface prompts are
  both covered
- `install-cron.sh` noting a log directory the job could never create or write
  (and an unwritable day file), as it notes an unusable config. The unwritable
  cases self-skip where modes are not enforced
- a `flock` that is present but cannot lock — any exit status but 1, such as
  the 71 util-linux gives on a filesystem without lock support — treated like a
  missing `flock` rather than as another run holding the lock, so neither the
  job nor `auto-setup.sh`'s verification steps aside forever; a stub `flock`
  exiting 1 is the control that the conflict still skips

Anything that actually talks to `nmcli` is **not** covered and still has to be
verified by hand against a real NetworkManager. If you change connect
behaviour, say in the pull request what you ran and what the log lines were.

## Before reporting something as a problem

Some things a review will reasonably flag have already been looked at and
deliberately left as they are — an unpinned action, the polkit behaviour under
cron, the way the password is redacted out of nmcli's errors.
[DECISIONS.md](../tests/DECISIONS.md) records each one with its reasoning and, more
usefully, the condition under which it should be revisited.

Check there first. If a condition now holds, the item is live again and worth
raising. If you disagree with the reasoning itself, that is a fair thing to argue
— just argue with the reasoning rather than reporting it as undiscovered.

## House style

The existing code has a strong convention, and matching it matters more than
any individual preference here:

- `set -euo pipefail` at the top of every script — except `tests/run-tests.sh`,
  which deliberately omits `-e` (`set -uo pipefail`) so that one failing
  assertion is recorded and the rest of the suite still runs.
- Comments explain **why**, not what — and in particular they record the bug a
  piece of defensive code exists to prevent. Several blocks in `reconnect.sh`
  and `install-cron.sh` read as short post-mortems. Keep that: it is the main
  reason the scripts are maintainable.
- Every exit path in `reconnect.sh` writes exactly one log line. If you add a
  new one, it goes through `status()` or `die()`.
- Never put the Wi-Fi password in a log file or an error message, and never on a
  command line beyond the one place that already does: `connect_with_password()`
  in `reconnect.sh` hands it to `nmcli dev wifi connect` as an argument,
  because before a NetworkManager profile exists there is no other way to
  connect. [SECURITY.md](SECURITY.md) documents when that path runs (the first
  connect, and any attempt whose saved profile fails to come up). Do not add a
  second such path, and do not remove that one without something else that can
  make the first connect. `remember_error()` scrubs the password out of nmcli's
  output; parse errors print the line number and key, never the line.
- Prefer a stated failure over a silent one. Under cron, stderr goes to
  `/dev/null`, so anything not logged is invisible.
- `config.env` is parsed, never sourced. Do not "simplify" that.

Line endings are LF, enforced by [`.gitattributes`](../.gitattributes) and
checked in CI.

The five scripts must be committed with the execute bit set, because every
instruction in the README runs them directly (`./auto-setup.sh`,
`./reconnect.sh`, `./tests/run-tests.sh`). On Windows, `git init` writes
`core.filemode = false` and a plain `git add` then records them as `100644`
whatever mode the working tree shows — a fresh clone on Linux gets
"Permission denied" from the very first command. Stage the mode explicitly
and check it before pushing:

```bash
git add --chmod=+x reconnect.sh auto-setup.sh manual-setup/install-cron.sh manual-setup/uninstall-cron.sh tests/run-tests.sh
git ls-files -s -- '*.sh'    # every line must start with 100755
```

## Pull requests

Keep changes focused, explain the reasoning in the description, and update the
README when behaviour changes.

By contributing you agree that your work is licensed under the
[MIT License](../LICENSE), and you are expected to follow the
[Code of Conduct](CODE_OF_CONDUCT.md).
