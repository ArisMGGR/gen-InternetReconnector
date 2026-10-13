#!/usr/bin/env bash
#
# tests/run-tests.sh
#
# Test suite for InternetReconnector.
#
# Needs nothing but bash 4+, awk, sed, grep and coreutils. No NetworkManager,
# no cron, no root, no network. `nmcli` and `crontab` are replaced by stubs on
# PATH, the settings the scripts read from the environment are cleared first,
# and the scripts are pointed at temporary config and log directories, so a run
# here cannot touch the machine's real crontab, config, logs or Wi-Fi.
#
# What is covered is the text processing -- the parts that are pure logic and so
# can regress silently:
#
#   * the config.env parser (quoting, spacing, comments, CRLF, BOM, unknown,
#     duplicated and empty keys, and the blanks-only values that are refused)
#   * the config file itself being unreadable or not a regular file, both of
#     which used to reach load_config's redirect and exit with no log line at all
#   * the terse-nmcli field unescaper (SSIDs containing ':' and '\')
#   * the RECONNECT_* environment overrides reconnect.sh validates, and the
#     preflight order that puts `date` ahead of the config read
#   * the 18-digit width rule the two scripts share, pinned on both sides:
#     reconnect.sh bounds these settings with `test` and install-cron.sh with
#     `$(( ))`, which wraps in silence, so the installer used to accept values the
#     scheduled job refused. Pinned at the boundary as well as past it -- 18
#     digits accepted and 19 refused, on each side -- because a 20-digit value is
#     refused by any bound the rule might drift to and so says nothing about
#     where the two scripts draw the line
#   * the exit status each outcome produces, which anything driving this from a
#     script keys off rather than the log
#   * log pruning, and its refusal to delete files it did not write
#   * the overlap lock, and the "Skipped (already running)" line it produces
#   * which crontab lines install-cron.sh claims as its own, including ones a
#     hand-edit left a trailing blank on or an indent in front of -- the second
#     of which used to throw the interval away in silence
#   * the trailing-slash normalisation in the install-time nmcli PATH check,
#     without which it warned about a PATH that was already correct
#   * the vetting of values written onto the cron line, and in particular the
#     line break that quoting gives no protection against
#   * the overlap warning, which is computed from the timeouts being installed
#   * the two install-time nmcli warnings -- missing outright, and present but
#     off the PATH written onto the cron line -- and CRON_PATH itself: honoured,
#     carried across a re-install, and vetted like every other value
#   * the crontab-safety guards: what happens when reading or writing the
#     crontab fails, or when the classifier does
#   * a crontab larger than the pipe buffer, which is a size and not a shape and
#     so needs a fixture of its own. The helpers answering "are there any
#     entries?" and "is one of them ours?" were pipelines into a reader that
#     stops at the first match, and past ~64 KiB the builtin printf feeding them
#     died of SIGPIPE and pipefail turned that into the answer -- so an install
#     replaced a 2,000-entry crontab with one line and reported success, and a
#     --remove reported "nothing to remove" over a job it left running. Both
#     directions are pinned, with our line at the front for the second because
#     that is where the early exit bites
#   * that a precondition is never enforced on a path that does not use the
#     thing it checks: the MINUTES setting and the date preflight do not block a
#     removal, chmod does not block an install whose scripts are already
#     executable, cat blocks neither an install nor an uninstall that never
#     prints usage, `rm` blocks neither an uninstall with nothing to remove nor
#     a --dry-run that deletes nothing, `grep` blocks neither a removal with
#     nothing to remove nor a first install (install-cron.sh no longer runs it
#     at all; uninstall-cron.sh still runs one, in read_crontab(), and still
#     refuses without it), and `sleep` does not block an already-connected run.
#     Each is pinned on its own PATH so
#     that deleting one preflight cannot be masked by another still firing, and
#     each has a control showing the check still fires where the command really
#     is used
#   * the overflow guard on the worst-case overlap figure, which the 18-digit
#     width rule does not reach: it bounds each value, and the calculation
#     multiplies two of them
#   * reconnect.sh's refusal of any argument, which used to be accepted and
#     ignored while the run went on to drive nmcli
#   * argument handling shared by all five scripts: an *empty* argument is an
#     argument, not the absence of one -- install-cron.sh matched it with a `'')`
#     arm and installed the job, which is the surprise its argument policy exists
#     to prevent. In the four shipped scripts the rejected value is also quoted
#     in the refusal, because unquoted an empty or blanks-only one produced a
#     message naming nothing at all; this file is the exception and deliberately
#     not covered for it, since its refusal prints the usage line and names no
#     value. That quoting rule is pinned more widely than the argument refusals:
#     the numeric settings reconnect.sh and install-cron.sh validate are quoted
#     too, and a blanks-only one of each is asserted here
#     This file's own parser is covered here too: it read `${1:-}` and never
#     `$#`, so `-v --bogus` ran the whole suite in silence while `--bogus` alone
#     exited 2. Those assertions run this file as a child under IR_ARGV_PROBE,
#     which reports the parser's decision and stops -- without it a child given
#     arguments the parser wrongly accepts would run the suite and reach the same
#     assertions itself, recursively, which is exactly what the regression under
#     test produces
#   * `rm` blocking neither a purge that has nothing to purge nor a dry run,
#     while a lone lock file still brings the check back. The gate had been
#     widened twice and the same defect turned up one flag further along each
#     time, because a condition written before the log scan cannot know whether
#     there is anything to delete
#   * a `grep` that is present and *fails*, which the preflight above cannot
#     see. our_cron_lines() was three greps ending in `|| true`, so a failure
#     came back empty -- indistinguishable from "no line of ours" -- and the
#     uninstall then printed "No cron job found", never called
#     `install-cron.sh --remove`, and exited 0 over a job still running. It is
#     a shell `case` now. The empty-crontab case with the same broken grep is
#     asserted separately and has the opposite right answer: read_crontab()
#     still needs grep to tell "no crontab yet" from a failed read, so it
#     refuses rather than guessing
#   * uninstall-cron.sh's own behaviour: --dry-run, --purge-logs with its
#     confirmation prompt and --yes, the refusal where there is no terminal to
#     ask at, the lock file as a purge target in its own right, reading the log
#     directory back off the installed cron line, the post-condition check that
#     catches a hand-edited line surviving --remove, the marker constant it
#     shares with install-cron.sh, a job the user disabled by commenting it out,
#     and an unrecognised argument being refused wherever it sits relative to
#     --help
#   * that the log directory is taken off the cron line only when it is absolute.
#     install-cron.sh refuses to write a relative one because cron runs the job
#     from the user's home directory, while this script resolves it against
#     wherever it was run from -- and reading one back anyway applied that
#     mismatch to a deletion, purging YYYY-MM-DD.log files out of whatever
#     directory the caller happened to be standing in. The control is an
#     absolute value still being honoured, without which the guard could be
#     "stop reading the line" and every assertion would still pass
#   * uninstall-cron.sh with no crontab command at all, which is a run with
#     nothing to remove rather than a failed removal
#   * auto-setup.sh end to end, driven by piping the answers in: the four
#     config.env settings it writes and the interval it installs, an interface
#     chosen by number off the offered list and one typed by hand, a skipped
#     password, re-prompting on every bad answer, and a re-run keeping each
#     current value -- including the interval, which it must leave to
#     install-cron.sh rather than defaulting to 5 and undoing the carry-over.
#     Also that blanks inside an SSID or a password survive (`read` strips them
#     without `IFS=`), that a password is never printed in the output (and that
#     its prompt is read with -s -- pinned on the source, because a pipe cannot
#     observe terminal echo),
#     that a configuration reconnect.sh rejects stops before the crontab is
#     touched, and that running out of input is a stated failure rather than
#     consent. `read -p` shows its prompt only on a terminal, so none of this
#     asserts on prompt text -- the observables are the file, the crontab, the
#     exit status and the unconditional `echo` lines
#   * auto-setup.sh's two numeric prompts held to the same 18-digit width rule
#     as everything else: an over-wide interface number is re-asked without
#     bash's own "integer expected" reaching the screen, with a leading-zero
#     answer still selecting from the list as the control. The interval prompt
#     had that rule from the start and the interface prompt did not. Both are
#     now pinned at the boundary and not only past it, for the reason the
#     reconnect.sh/install-cron.sh pair above is: a 23-digit answer is refused
#     by any width rule the guard might drift to, and widening either constant
#     from 18 to 19 left this whole suite green while the interface prompt
#     leaked `[: 9999999999999999999: integer expected` and the interval prompt
#     reported `got: '-8446744073709551617'`, a negative nobody typed. The
#     interval prompt pins both edges, because its width refusal and its range
#     refusal word themselves differently; the interface prompt can only pin
#     the upper one, since both of its refusals print the same line
#   * the two values auto-setup.sh does not ask for but passes on -- MINUTES and
#     RECONNECT_LOG_DIR -- refused before the interview rather than by
#     install-cron.sh at the end of it. MINUTES went through unexamined, so
#     `MINUTES=7 ./auto-setup.sh` asked every question, took the password and
#     wrote config.env before failing on a value it had been given at the start.
#     Both paths share check_interval() now, so the refusals are asserted to
#     carry the same words as the prompt's, and each case asserts no config.env
#     was written -- exit 1 alone cannot tell "refused up front" from "refused
#     at the end". The controls are a legal MINUTES still skipping the question
#     and a leading-zero one still normalising
#   * the rest of what auto-setup.sh hands on without reading: the four numeric
#     RECONNECT_* settings, and whether config.env can be written at all. Those
#     were the half of the same rule left undone --
#     `RECONNECT_CONNECT_ATTEMPTS=abc ./auto-setup.sh` still asked every
#     question and took the password before reconnect.sh refused it at the
#     verification run, and a RECONNECT_CONFIG in a directory that does not
#     exist did the same before dying at the `: >` that creates the file. The
#     numeric rules are install-cron.sh's, so the assertions pin its wording
#     rather than a second one written here. The first case is driven with a
#     complete set of answers on purpose: with no stdin the run dies at the
#     first prompt anyway, so "no config.env was written" holds for the wrong
#     reason and measured against the regression it did. Controls: zero for the
#     two settings whose minimum is 0, a leading-zero attempts count still
#     reaching the cron line intact, and an ordinary writable config path still
#     working
#   * that the advice printed when the verification run fails does not assert a
#     cause the run cannot know. It used to say the reason "usually means one
#     field is wrong", which is false for a missing nmcli, awk or date -- it
#     sent the reader back through the interview to fix a field that was never
#     wrong. Pinned on the fixture where the old wording happened to be right,
#     since that is where a revert would otherwise look harmless
#   * auto-setup.sh refusing a checkout that is missing reconnect.sh or
#     install-cron.sh *before* the interview rather than after it. Each case
#     asserts no config.env was written, which is what separates "refused
#     before asking" from "refused at the end" -- the second is what both used
#     to do, and for reconnect.sh the end was a message blaming the settings
#     for a missing script
#   * the two path settings auto-setup.sh hands on -- RECONNECT_CONFIG and
#     RECONNECT_LOG_DIR -- held to *both* of install-cron.sh's rules before the
#     interview, not just to absoluteness. A single quote, a '%' or a line break
#     in either is refused up front with that script's own wording, where before
#     the value was absolute, passed, and was refused only after every question
#     had been asked and the Wi-Fi password read -- and for RECONNECT_CONFIG the
#     password had by then been written to a path that can never be installed.
#     Each case asserts the interview never printed a word, because exit 1 is
#     what both the up-front refusal and the refusal at the end produce; the
#     control is a directory containing a space, which is quotable and which
#     install-cron.sh accepts, so refusing it here would refuse a run that would
#     have installed
#   * the other two values install-cron.sh vets with that same rule, which the
#     block above did not reach: CRON_PATH, and this checkout's own install
#     path. Both were refused only at the end -- CRON_PATH is the reachable one,
#     needing a single deliberately-set variable, and it took the whole
#     interview and the Wi-Fi password before install-cron.sh refused it, under
#     advice to "run ./install-cron.sh" that fails identically. The install path
#     needs RECONNECT_CONFIG pointed somewhere clean as well, because otherwise
#     the default $SCRIPT_DIR/config.env carries the same character and is
#     caught first -- so the fixture does exactly that, or the case would pass
#     against a script that never looked at the install path. Controls: a legal
#     CRON_PATH still reaching the line, and a checkout path containing a space,
#     which is quotable and which install-cron.sh accepts. The quoted-directory
#     case self-skips where the filesystem will not take such a name
#   * that the install path is vetted *before* the config path, and not merely
#     as well. With RECONNECT_CONFIG unset the config lives beside the script
#     and inherits its quote, so both checks refuse a quoted checkout -- but
#     with the config check first the refusal named "RECONNECT_CONFIG", a
#     variable the user had never set, and following it earned a second refusal
#     for the same root cause. Pinned with the right name present and the wrong
#     one absent, because either order exits 1 before the interview
#   * a config.env that is writable but not readable, which -w alone let through:
#     it is read twice before anything is written, by existing_value() and by the
#     `cp` that makes the .bak. Self-skips where the filesystem does not enforce
#     the mode
#   * a config.env that is readable and writable in a directory that is not,
#     which the three file checks let through: the .bak is created beside it and
#     needs the directory, so the run took the whole interview and died at the
#     `cp`. The exception is pinned too -- an existing writable .bak needs no
#     directory permission and must still be accepted. Self-skips where the
#     filesystem does not enforce a directory mode
#   * that the .bak gets mode 600 of its own rather than the mode it was copied
#     from: a hand-made 644 config produced a 644 backup holding the same
#     password while the new config was tightened and the run said nothing.
#     Self-skips with the config mode test, where the mode is not enforced
#   * install-cron.sh's absolute-path refusal quoting the rejected value, the one
#     refusal in that script left bare after the rest were quoted: a blanks-only
#     RECONNECT_CONFIG or RECONNECT_LOG_DIR is not empty, so it reaches the
#     check, and unquoted the message read `got:  .` -- from the environment,
#     and from a value already on the installed line, where every re-install
#     refused it with nothing visible to correct
#   * `grep` blocking neither an uninstall over a readable crontab nor a
#     --dry-run. uninstall-cron.sh runs one grep, in read_crontab(), and only
#     when `crontab -l` *fails*; the preflight for it used to sit on "is there a
#     crontab command", which is a wider path, so on a machine with a crontab
#     and no grep every run was refused over a command it never invoked. Both
#     directions are pinned, since either alone passes with the gate at the
#     wrong level
#   * that the ignore rules really match the files this tool writes a password
#     into, matched as globs rather than searched for as text -- including the
#     backup of a config kept under a name other than config.env, which
#     auto-setup.sh writes and which no pattern covered
#   * a config.env carrying a UTF-8 BOM being re-run without retyping anything.
#     reconnect.sh strips it on line 1 and existing_value() did not, so the
#     first key came back mangled and no default was offered for it; the
#     fixture presses Enter at every prompt, so the default is the only thing
#     that can carry the run
#   * which nmcli calls a connect makes, including when the password form is
#     reached -- the property SECURITY.md documents -- and how names reach
#     nmcli. The SSID in the password form is passed with nothing in front of
#     it: it carried a `--` for a while, meant as an end-of-options marker;
#     nmcli has none there, so `--` *was* the SSID and every real password
#     connect failed while the stub, which stripped the `--` itself, kept the
#     suite green. Pinned on an SSID beginning with `-`, the input a `--` would
#     be put back for, and the stub no longer strips anything. The profile
#     lookup goes through `connection show id NAME`, which the stub alone
#     answers, so profiles named `--active` and `id` are found and brought up
#   * a flock that is present but cannot lock (any status but 1) treated like a
#     missing flock rather than as another run holding the lock
#   * that a day file reconnect.sh cannot append to produces its WARNING and
#     not bash's own "Permission denied" ahead of it: the printf's redirections
#     were ordered `>> file 2>/dev/null`, which silences stderr only after the
#     open has already failed out loud. Self-skips where modes are not enforced
#   * that auto-setup.sh judges its verification run by the log line it wrote
#     and not by its exit status. reconnect.sh exits 0 when it steps aside
#     because its overlap lock is held, so a re-run while the scheduled job was
#     mid-run installed untested settings under "Settings work". Pinned with the
#     lock held and a wrong password, with the lock-free run as the control,
#     and self-skipping without flock like the overlap section. And that the
#     outcome it judges by is *this run's*, reported through IR_OUTCOME_FILE
#     rather than read off the day file, because "the last line" let a stale
#     one in an unwritable file stand in for the outcome. Pinned
#     with a stale "Wifi Good" in a file made unwritable during the run (refused as having
#     written nothing; self-skips where modes are not enforced) and, as the
#     control, a stale FAIL in a writable one that must be passed over
#   * that a RECONNECT_LOG_DIR which can never be created is refused before the
#     interview. reconnect.sh treats one it cannot create as a warning rather
#     than a failure, so the verification run passed over it and the job it
#     installed never wrote a line. An ancestor that is a file is pinned on
#     every filesystem; an unwritable parent self-skips where modes are not
#     enforced; the control is a directory that does not exist yet under a
#     writable parent, which reconnect.sh creates and which must still install
#   * that auto-setup.sh takes the RECONNECT_* settings already on the installed
#     cron line when the environment does not set them, the way install-cron.sh
#     carries them. It resolved them from the environment alone, so a plain
#     re-run over a job installed with a custom RECONNECT_CONFIG wrote and
#     verified <checkout>/config.env, said "Settings work", and re-installed a
#     job still reading the other file. Pinned on the config path, the log
#     directory and a tuning value, with the environment still winning as the
#     control, and the third copy of the marker held to the other two
#   * a mistyped password line containing '=' is reported without echoing the
#     password; a `.lock` path that cannot be
#     opened skips the lock instead of ending the run unlogged; a line of ours
#     edited after the marker is reported on install and on --remove; another
#     checkout whose path ends in this one's is neither adopted by auto-setup.sh
#     nor purged by uninstall-cron.sh; the no-terminal purge refusal says a line
#     is still installed when one is; auto-setup.sh refuses a machine with no
#     crontab before the interview, prints the carry-over notes under its
#     header (and still ahead of a refusal), names the installed interval at the
#     interval prompt, and reports an unreadable day file in its own words
#   * a password glued to its setting name with no separator is not echoed
#     either; the ignore-rule matcher honours `!` the way git does;
#     uninstall-cron.sh refuses rather than reading the crontab as empty when it
#     cannot create its temporary file; auto-setup.sh says when the verification
#     run never tried the password it was just given; and the interval-prompt
#     assertion is pinned on the prompt's own wording
#   * a CRON_PATH that reaches nmcli but not bash is warned about at install
#     time, since the job could then never start; auto-setup.sh refuses a
#     crontab that exists but cannot be read before the interview, not after it;
#     and a checkout reached through a symlink is the same checkout to all three
#     cron-line readers (this one self-skips where no symlink can be made)
#   * the three crontab readers agreeing on a failed read whose stderr is a
#     lone newline, and on BusyBox's "can't open '<user>': No such file or
#     directory" as "no crontab yet" (with another reason still refused);
#     auto-setup.sh refusing a machine without mktemp, awk, rm or date before
#     the interview, and reporting an installed interval install-cron.sh would
#     refuse instead of offering to keep it; and an exported CDPATH not
#     breaking a script run by a bare relative path
#   * install-cron.sh noting a RECONNECT_CONFIG that exists but is not a
#     regular file or cannot be read, not only one that is missing, since
#     reconnect.sh refuses all three (the unreadable case self-skips where
#     modes are not enforced)
#   * auto-setup.sh judging its verification by the outcome that run itself
#     reported, so a line the scheduled job appends to the same day file
#     meanwhile -- its "Wifi Good" ahead of a skipped verification, or its
#     "Skipped" ahead of one that connected -- cannot stand in for it; a target
#     that is the second of two active Wi-Fi connections still counting as
#     connected; and auto-setup.sh refusing a re-run without `cp` before the
#     interview
#   * auto-setup.sh putting the previous config back (or removing a new one)
#     when its verification is refused while a job is installed, so the job
#     keeps what it read -- after a failed run and after a skipped one; a last
#     answer with no newline after it being taken as an answer, not end of
#     input; the interval prompt reporting as unkeepable a schedule that is not
#     `*/N` and a line edited after the marker; and uninstall-cron.sh --dry-run
#     predicting removal through install-cron.sh --remove-dry-run, so a line
#     --remove will leave is reported as left
#   * a line of this checkout's with the path put in double quotes being
#     reported by install-cron.sh as edited by hand, not as another checkout's
#     line to be removed "from that copy"
#   * this file clearing every setting the scripts read from the environment
#     before it runs anything, so a RECONNECT_CONFIG or RECONNECT_LOG_DIR the
#     caller exported can no longer send a fixture's writes, or a purge, at the
#     caller's real config and logs -- and its own knobs (SCAN_WAIT, ATTEMPTS,
#     NMCLI_WAIT, RETENTION, RACE_*) with them; and an argument probe exiting 3
#     rather than 0, so an exported IR_ARGV_PROBE cannot pass for a green run
#     that tested nothing
#   * auto-setup.sh refusing before the interview a log directory -- the
#     default one too -- or a day log that the verification run could not write
#   * install-cron.sh setting no executable bit on a run it then refuses
#   * auto-setup.sh, when install-cron.sh fails after the test passed, saying
#     whether a job was already installed, and giving a by-hand install command
#     that carries the interval and settings this run chose -- followed
#     literally, it installs what the run would have; pinned with all seven
#     settings it carries set at once, not only the three the other cases use
#   * auto-setup.sh taking '-' on a re-run to clear a stored password or
#     interface, which Enter (keep) could not, at both interface prompts
#   * install-cron.sh noting a log directory the job could never create or
#     write, and an unwritable day file, as it notes an unusable config
#
# This list is checked against the `section` headings below when either changes:
# it had fallen three sections behind, and a coverage list that quietly
# understates the suite invites the same test being written twice.
#
# What is NOT covered is anything that depends on a real NetworkManager: whether
# nmcli actually associates, polkit behaviour under cron, driver quirks. Those
# still have to be checked by hand.
#
# Usage:
#   ./tests/run-tests.sh          # run everything
#   ./tests/run-tests.sh -v       # also print each passing assertion

# Deliberately no `set -e`: a failing assertion should be recorded and the rest
# of the suite should still run. Failures are counted and reported at the end,
# and the exit status is what CI keys off.
set -uo pipefail

# For the reason written out in reconnect.sh: an exported CDPATH makes the `cd`
# that resolves SUITE_DIR print into its own substitution when this file is run
# as `bash tests/run-tests.sh`.
unset CDPATH

# Every setting the scripts under test read from the environment is cleared
# before anything runs, so the only values they see are the ones a fixture sets.
#
# None of these used to be cleared, and the scripts read every one of them. Most
# fixtures pass their own RECONNECT_CONFIG and RECONNECT_LOG_DIR, but many of the
# auto-setup.sh and uninstall-cron.sh cases deliberately do not -- they test the
# defaults -- so a value exported in the caller's shell reached them instead.
# Measured with RECONNECT_CONFIG and RECONNECT_LOG_DIR exported at a real config
# and log directory: auto-setup.sh wrote the fixtures' answers over that config,
# so the original password survived in neither it nor its .bak, and
# `uninstall-cron.sh --purge-logs --yes`, where an explicit RECONNECT_LOG_DIR
# wins over the cron line, deleted the real daily logs. The suite then reported
# 66 failures, after the damage was done. The README says this file is safe to
# run anywhere and cannot touch your real logs, and that was false for anyone
# who keeps those two exported so that `./reconnect.sh` by hand finds their
# config.
#
# MINUTES and CRON_PATH change what is installed, IR_OUTCOME_FILE is written to
# by every reconnect.sh run, and the stub knobs below change what the stubs do or
# where they write, so a stray export of any of them would turn assertions red
# for a reason that has nothing to do with the code. The list is also what
# IR_ARGV_PROBE reports on below, which is how the suite pins this block.
#
# This file's own knobs are on the list for the same reason. run_reconnect()
# reads SCAN_WAIT, ATTEMPTS, NMCLI_WAIT and RETENTION with `${X:-default}` and
# hands them to reconnect.sh as the RECONNECT_* settings, so they are those
# settings by another name -- and generic ones. They were not cleared, so
# `RETENTION=abc` in the caller's shell turned 57 assertions red; the RACE_*
# names feed the two race stand-ins the same way. IR_ARGV_PROBE cannot be on the
# list, because it is how a child is told to probe; what stops an exported one
# passing for a green run is the probe's own exit status, below.
SUITE_ENV_CLEARED="RECONNECT_CONFIG RECONNECT_LOG_DIR RECONNECT_LOG_RETENTION_DAYS
RECONNECT_SCAN_WAIT_SECS RECONNECT_CONNECT_ATTEMPTS RECONNECT_NMCLI_WAIT_SECS
MINUTES CRON_PATH IR_OUTCOME_FILE
SCAN_WAIT ATTEMPTS NMCLI_WAIT RETENTION RACE_LOG_DIR RACE_REAL_NMCLI RACE_CHMOD_LOG
CRONTAB_FILE CRONTAB_FAIL CRONTAB_FAIL_RC CRONTAB_FAIL_MSG CRONTAB_FAIL_SKIP
NM_ACTIVE_PROFILE NM_PROFILES NM_DEVICES NM_SCAN NM_CONNECT_RC NM_CONNECT_MSG
NM_ARGS_LOG NM_FD_PROBE"
# A whitespace-separated list of literal variable names, so the word splitting is
# the point; none of them can contain a space or a glob character.
# shellcheck disable=SC2086
unset $SUITE_ENV_CLEARED

# The arity check comes first, and the count is what decides whether there is an
# argument at all -- both for the reason install-cron.sh's parser states, and
# because this file had the defect that parser was changed to remove.
#
# It inspected `${1:-}` and nothing else, so an unrecognised argument was refused
# when it was first and ignored in silence when it was not:
# `./tests/run-tests.sh --bogus` exited 2, while `./tests/run-tests.sh -v --bogus`
# ran the whole suite, exited 0 and never mentioned `--bogus`. That is the wrong
# way round for the same reason it was in install-cron.sh, and this file is
# linted and run in CI like the four it tests, so it is held to the same rule.
#
# `${1:-}` also collapsed "no argument" and "an empty argument" into one empty
# string, which the `'')` arm then accepted. Testing `$#` separates them, so
# `./tests/run-tests.sh ""` is refused here exactly as it now is by
# install-cron.sh.
#
# Both refusals exit before mktemp, the stubs and the first assertion, so a suite
# invoked wrongly does no work at all.
VERBOSE=0
[ "$#" -le 1 ] || { echo "usage: run-tests.sh [-v]" >&2; exit 2; }
if [ "$#" -eq 1 ]; then
    case "$1" in
        -v | --verbose) VERBOSE=1 ;;
        *) echo "usage: run-tests.sh [-v]" >&2; exit 2 ;;
    esac
fi

# A nested run must never execute the suite.
#
# The assertions in "the suite's own arguments" further down invoke this file as
# a child to pin the parser above, and the case they exist for is the one where
# that parser is *wrong*. Without this, reverting the arity check made the child
# accept `-v --bogus`, run the whole suite, and reach the same assertions itself
# -- spawning a child of its own, and so on. That is measured rather than
# imagined: it produced a chain of seventy-odd nested runs that had to be killed
# by hand, and the mutation it was supposed to be caught by never finished.
#
# So a child states what the parser decided and stops here, still ahead of
# mktemp, the stubs and the first fixture. That is also what makes the
# *accepting* cases assertable at all -- they could not be exercised before,
# because accepting meant running -- so the section below now has the controls
# without which its refusals would pass just as well against a parser that
# refused everything.
#
# The second line it prints names any of SUITE_ENV_CLEARED still set at this
# point, which is how "the suite's own environment" further down checks that the
# block above really clears what the caller exported.
#
# It exits 3, not 0, and says on stderr that no test ran. It used to exit 0, so
# with IR_ARGV_PROBE exported in the caller's shell `./tests/run-tests.sh`
# printed two probe lines, ran no assertion at all, and reported success -- a
# green suite that had tested nothing, which anything keying off the exit status
# would take at its word. 3 is neither the suite's "failed" (1) nor its "cannot
# run" (2), so the accepting cases below can still tell an accepted probe from a
# refusal.
if [ -n "${IR_ARGV_PROBE:-}" ]; then
    printf 'argv-probe: accepted, VERBOSE=%s\n' "$VERBOSE"
    probe_leaked=""
    # shellcheck disable=SC2086
    for probe_var in $SUITE_ENV_CLEARED; do
        [ -z "${!probe_var+set}" ] || probe_leaked="$probe_leaked $probe_var"
    done
    printf 'env-probe: still set:%s\n' "${probe_leaked:- none}"
    echo "IR_ARGV_PROBE is set: argument probe only, no tests were run" >&2
    exit 3
fi

# Split with parameter expansion rather than `dirname`, matching the four
# scripts under test. Here the reason is specific to this file: this line runs
# before the prerequisite loop below, so a `dirname` used here could never be
# covered by it -- and the loop's whole purpose is that a missing tool is
# reported as "cannot run" rather than as a wall of failing assertions. `*/*`
# fails for a bare name (`bash run-tests.sh`), which means the current
# directory; the empty result is a script sitting directly in `/`.
suite_src="${BASH_SOURCE[0]}"
case "$suite_src" in
    */*)
        suite_dir="${suite_src%/*}"
        [ -n "$suite_dir" ] || suite_dir=/
        ;;
    *) suite_dir=. ;;
esac
SUITE_DIR="$(cd "$suite_dir" && pwd)"
REPO_DIR="$(cd "$SUITE_DIR/.." && pwd)"

RECONNECT="$REPO_DIR/reconnect.sh"
INSTALL="$REPO_DIR/manual-setup/install-cron.sh"
UNINSTALL="$REPO_DIR/manual-setup/uninstall-cron.sh"
AUTOSETUP="$REPO_DIR/auto-setup.sh"

for f in "$RECONNECT" "$INSTALL" "$UNINSTALL" "$AUTOSETUP"; do
    [ -f "$f" ] || { echo "cannot find $f" >&2; exit 2; }
done

if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ]; then
    echo "these tests need bash 4.0 or newer; this is bash ${BASH_VERSION:-unknown}" >&2
    exit 2
fi

# The header above names what this suite needs; only the bash version was ever
# actually checked. A missing `sed` in particular surfaced as an assertion
# failure inside the nmcli stub -- a red suite blaming the code under test for a
# prerequisite that was never installed. Exit 2, the same "cannot run" status
# the checks above use, so it is never mistaken for a test failure.
#
# The list covers every external command this file runs, not just the five it
# started with. `tail` is the one that most deserved adding: run_reconnect()
# reads back the log line every outcome assertion is made against with
# `tail -n 1`, so without it RC_LOG comes back empty and dozens of assertions
# fail at once, each of them apparently about reconnect.sh. That is exactly the
# failure `sed` was added for, in the place it does the most damage. `cp`,
# `touch`, `chmod`, `mkdir`, `cat`, `rm` and `head` build the fixtures.
#
# `env`, `mv` and `dirname` were missing from the list while that sentence
# already claimed to be complete, which is worse than a short list: it invites
# the next reader to audit the suite against a claim rather than against the
# file. `env` is the expensive one -- every `run_install env VAR=x ...` call goes
# through it, so without it all of them fail at once with status 127, each
# assertion apparently blaming the script under test, which is precisely the
# `tail` failure again and at a larger scale. Without `mv` the two hand-edited
# crontab fixtures are never built and the assertions after them quietly measure
# the wrong thing. `dirname` is only reached in the `cat`-preflight block far
# below; SUITE_DIR above no longer uses it, because a check here cannot cover a
# line that runs before it.
#
# Keep this list in step with the file. A grep for the commands actually invoked
# is the check; the sentence above is not.
for tool in awk sed grep mktemp date cat mkdir chmod touch cp rm tail head env mv dirname ls; do
    command -v "$tool" >/dev/null 2>&1 \
        || { echo "these tests need $tool on PATH" >&2; exit 2; }
done

TMP="$(mktemp -d)" || { echo "mktemp failed" >&2; exit 2; }
trap 'rm -rf "$TMP"' EXIT
# The physical spelling of it. The scripts under test resolve their own
# directory with `pwd -P`, so the path a cron line names is the physical one --
# and where the temporary directory sits behind a symlink (/tmp on some
# systems, /var on macOS) every assertion comparing a line against "$co/..."
# would compare two spellings of one directory.
TMP="$(cd "$TMP" && pwd -P)" || { echo "cannot resolve $TMP" >&2; exit 2; }

PASS=0
FAIL=0

# --- Assertions --------------------------------------------------------------

ok() {
    PASS=$((PASS + 1))
    [ "$VERBOSE" -eq 1 ] && printf '  ok   %s\n' "$1"
    return 0
}

no() {
    FAIL=$((FAIL + 1))
    printf '  FAIL %s\n' "$1"
    shift
    printf '       %s\n' "$@"
    return 0
}

# assert_eq <description> <expected> <actual>
assert_eq() {
    if [ "$2" = "$3" ]; then
        ok "$1"
    else
        no "$1" "expected: [$2]" "actual:   [$3]"
    fi
}

# assert_contains <description> <needle> <haystack>
assert_contains() {
    case "$3" in
        *"$2"*) ok "$1" ;;
        *) no "$1" "expected to contain: [$2]" "actual:              [$3]" ;;
    esac
}

# assert_not_contains <description> <needle> <haystack>
assert_not_contains() {
    case "$3" in
        *"$2"*) no "$1" "expected NOT to contain: [$2]" "actual:                  [$3]" ;;
        *) ok "$1" ;;
    esac
}

# assert_exists <description> <path>
assert_exists() {
    if [ -e "$2" ]; then
        ok "$1"
    else
        no "$1" "expected to exist: $2"
    fi
}

# assert_missing <description> <path>
assert_missing() {
    if [ -e "$2" ]; then
        no "$1" "expected to be gone: $2"
    else
        ok "$1"
    fi
}

section() {
    printf '\n%s\n' "$1"
}

# --- Stubs -------------------------------------------------------------------
# Both stubs are generated here rather than shipped as files, so the suite stays
# one file and there is no chance of a stray executable called `nmcli` being
# left somewhere a real run could find it.

STUB_BIN="$TMP/bin"
mkdir -p "$STUB_BIN"

# crontab(1), backed by the file named in $CRONTAB_FILE. Mirrors the three
# behaviours the scripts rely on: -l prints (and exits 1 with "no crontab for
# ..." when empty), - reads a new one from stdin, -r removes it.
#
# It can also be told to fail, which is what makes the crontab-safety guards
# testable at all. Without that the stub always succeeded, so the paths that
# exist specifically to refuse rather than risk a user's unrelated cron entries
# were the only substantial part of the code with no coverage -- exactly the
# wrong way round, since they are the lines whose regression destroys data.
#
#   CRONTAB_FAIL       which operation fails: "l" (read), "w" (write via -),
#                      "r" (remove via -r), or "all"
#   CRONTAB_FAIL_RC    the exit status it fails with (default 1)
#   CRONTAB_FAIL_MSG   what it prints on stderr when it fails, followed by a
#                      newline. Unset means a default message; set to empty it
#                      prints the newline alone, which is the stderr the three
#                      scripts' "is there anything on stderr?" tests must agree on
#   CRONTAB_FAIL_SKIP  how many matching calls succeed before the failure
#                      starts (default 0: fail from the first one). Without it
#                      the stub could only fail *every* read, which is the one
#                      shape uninstall-cron.sh's post-removal check is not
#                      sensitive to -- the first read dies correctly and the
#                      check is never reached. The count is kept in a file
#                      beside the crontab, because each call is a new process.
cat > "$STUB_BIN/crontab" <<'STUB'
#!/usr/bin/env bash
f="${CRONTAB_FILE:?CRONTAB_FILE not set}"

fail_for() {
    case "${CRONTAB_FAIL:-}" in
        all | "$1") ;;
        *) return 1 ;;
    esac
    local skip="${CRONTAB_FAIL_SKIP:-0}" seen
    [ "$skip" -gt 0 ] || return 0
    seen=$(( $(cat "$f.skipped" 2>/dev/null || echo 0) + 1 ))
    printf '%s\n' "$seen" > "$f.skipped"
    [ "$seen" -gt "$skip" ]
}

refuse() {
    printf '%s\n' "${CRONTAB_FAIL_MSG-crontab: stub failure}" >&2
    exit "${CRONTAB_FAIL_RC:-1}"
}

case "${1:-}" in
    -l)
        fail_for l && refuse
        if [ -s "$f" ]; then cat "$f"; else echo "no crontab for tester" >&2; exit 1; fi
        ;;
    -r)
        fail_for r && refuse
        rm -f "$f"
        ;;
    -)
        # Drain stdin either way, so a refusing write still behaves like the
        # real thing to whatever is piping into it.
        if fail_for w; then cat > /dev/null; refuse; fi
        cat > "$f"
        ;;
    *)  echo "stub crontab: unsupported argument: ${1:-}" >&2; exit 2 ;;
esac
STUB

# nmcli(1). Behaviour is driven entirely by the environment:
#
#   NM_ACTIVE_PROFILE  name of the currently active Wi-Fi profile ("" = none).
#                      Several lines mean several active connections, each
#                      "name" (on wlan0) or "name|device"; the scan-list query
#                      only understands the single-name form
#   NM_PROFILES        saved profiles, one "name|ssid" per line
#   NM_DEVICES         devices, one "name|type" per line, for the `device` query
#                      auto-setup.sh uses to offer an interface list. Unset means
#                      nmcli reports none, which is the fallback that script has
#                      to keep working on a machine whose adapter is not up
#   NM_SCAN            SSIDs visible to a scan, one per line
#   NM_CONNECT_RC      exit status for a connect attempt (0 = success)
#   NM_CONNECT_MSG     what a failed connect prints
#   NM_ARGS_LOG        file every invocation's arguments are appended to
#   NM_FD_PROBE        file a line is appended to if descriptor 9 -- the one
#                      reconnect.sh holds its flock on -- is open here. It must
#                      never be: a child that inherited it would hold the lock
#                      for as long as it lived, and every later run would step
#                      aside with "Skipped (already running)" and no reason
#
# Output is written in nmcli's terse form, including its escaping of ':' and
# '\' inside a field, so the unescaper in reconnect.sh is exercised for real.
cat > "$STUB_BIN/nmcli" <<'STUB'
#!/usr/bin/env bash
[ -n "${NM_ARGS_LOG:-}" ] && printf '%s\n' "$*" >> "$NM_ARGS_LOG"

# `: >&9` runs nothing and writes nothing, so an open descriptor 9 is detected
# without putting anything into the lock file. The redirections are in this
# order because they are applied left to right: with `>&9` first, its own "Bad
# file descriptor" complaint is written before stderr has been silenced, and the
# expected case -- a descriptor correctly closed -- prints an alarming line into
# the captured output of a passing test.
if [ -n "${NM_FD_PROBE:-}" ]; then
    if : 2>/dev/null >&9; then printf 'inherited\n' >> "$NM_FD_PROBE"; fi
fi

esc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/:/\\:/g'; }

# Drop a leading "-w N", which the connect calls pass.
if [ "${1:-}" = "-w" ]; then shift 2; fi

args="$*"

# Drop a trailing "list ifname <dev>", which the scan calls pass when
# WIFI_IFACE is set. This stub models a single device, so scoping the scan is a
# no-op for the fixtures; what the tests assert on is that the argument is
# passed at all, which they read out of NM_ARGS_LOG above.
args="${args% list ifname *}"

profiles() { printf '%s' "${NM_PROFILES:-}"; }

case "$args" in
    "-t -f NAME,TYPE,DEVICE connection show --active")
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            case "$line" in
                *'|'*) dev="${line#*|}"; line="${line%%|*}" ;;
                *) dev=wlan0 ;;
            esac
            printf '%s:802-11-wireless:%s\n' "$(esc "$line")" "$dev"
        done <<< "${NM_ACTIVE_PROFILE:-}"
        ;;
    "-t -f 802-11-wireless.ssid connection show id "*)
        want="${args#-t -f 802-11-wireless.ssid connection show id }"
        # The name is matched exactly as reconnect.sh sends it after the `id`
        # selector, which is the one spelling real nmcli takes literally for
        # any name. A bare name falls to the `*)` arm below and finds nothing,
        # so a lookup that lost its `id` fails here as a name like `--active`
        # would fail against nmcli. This stub used to strip a `-- ` instead,
        # under a comment claiming real nmcli consumes it -- it does not, here
        # or in `dev wifi connect`, and that strip kept the whole suite green
        # while every real profile lookup and password connect failed
        # (DECISIONS.md D6). A stub can pin the argv the script builds; it
        # cannot vouch for nmcli's parser, so it must not be more forgiving
        # than nmcli is.
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            name="${line%%|*}"; ssid="${line#*|}"
            if [ "$name" = "$want" ]; then
                printf '802-11-wireless.ssid:%s\n' "$(esc "$ssid")"
                exit 0
            fi
        done <<< "$(profiles)"
        exit 0
        ;;
    "-t -f DEVICE,TYPE device")
        while IFS= read -r dev; do
            [ -n "$dev" ] || continue
            printf '%s:%s\n' "$(esc "${dev%%|*}")" "${dev#*|}"
        done <<< "${NM_DEVICES:-}"
        ;;
    "-t -f NAME,TYPE connection show")
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            printf '%s:802-11-wireless\n' "$(esc "${line%%|*}")"
        done <<< "$(profiles)"
        ;;
    "-t -f ACTIVE,SSID dev wifi")
        while IFS= read -r ssid; do
            [ -n "$ssid" ] || continue
            if [ "$ssid" = "${NM_ACTIVE_PROFILE:-}" ]; then
                printf 'yes:%s\n' "$(esc "$ssid")"
            else
                printf 'no:%s\n' "$(esc "$ssid")"
            fi
        done <<< "${NM_SCAN:-}"
        ;;
    "-t -f SSID dev wifi")
        while IFS= read -r ssid; do
            [ -n "$ssid" ] || continue
            printf '%s\n' "$(esc "$ssid")"
        done <<< "${NM_SCAN:-}"
        ;;
    "radio wifi on" | "dev wifi rescan"*)
        exit 0
        ;;
    "connection up id "* | "dev wifi connect "*)
        rc="${NM_CONNECT_RC:-0}"
        if [ "$rc" -ne 0 ]; then
            printf '%s\n' "${NM_CONNECT_MSG:-Error: Connection activation failed.}" >&2
        fi
        exit "$rc"
        ;;
    *)
        exit 0
        ;;
esac
STUB

chmod +x "$STUB_BIN/crontab" "$STUB_BIN/nmcli"
PATH="$STUB_BIN:$PATH"
export PATH

# --- Helpers -----------------------------------------------------------------

# Fresh, isolated working area for one case. Echoes its path.
#
# mktemp rather than a counter: this runs inside a command substitution, so a
# counter incremented here would be incremented in a subshell and every case
# would land in the same directory -- sharing one log file and one crontab, and
# reading each other's results.
new_case() {
    local d
    d="$(mktemp -d "$TMP/case-XXXXXX")" || return 1
    mkdir -p "$d/logs"
    printf '%s' "$d"
}

# grep -c over a crontab that may not exist: `crontab -r` deletes the file, and
# "no crontab at all" has to read as zero matching lines, not as an error.
cron_count() {
    [ -f "$CRONTAB_FILE" ] || { printf '0'; return 0; }
    printf '%s' "$(grep -c "$1" "$CRONTAB_FILE")"
}

cron_text() {
    [ -f "$CRONTAB_FILE" ] || return 0
    cat "$CRONTAB_FILE"
}

# run_reconnect <case dir> -- runs reconnect.sh against that case's config and
# log directory. Stdout and stderr are captured into RC_OUT; the exit status
# into RC_STATUS; the day's log line into RC_LOG.
RC_OUT=""
RC_STATUS=0
RC_LOG=""
run_reconnect() {
    local dir="$1" before after
    # Anything after the case directory is handed to reconnect.sh as an
    # argument. Almost every call passes none, which is the ordinary case; the
    # argument-refusal block is what the forwarding is for.
    shift
    # The day is read on both sides of the run. Reading it only afterwards named
    # a file the script may never have written to: a run that starts at 23:59:59
    # logs to yesterday's file, the lookup found nothing, RC_LOG came back empty
    # and every assertion in that case failed for a reason that had nothing to do
    # with the code. Taking it only beforehand has the same bug in the other
    # direction, so both are tried.
    before="$(date '+%Y-%m-%d')"
    RC_OUT="$(
        RECONNECT_CONFIG="$dir/config.env" \
        RECONNECT_LOG_DIR="$dir/logs" \
        RECONNECT_SCAN_WAIT_SECS="${SCAN_WAIT:-0}" \
        RECONNECT_CONNECT_ATTEMPTS="${ATTEMPTS:-1}" \
        RECONNECT_NMCLI_WAIT_SECS="${NMCLI_WAIT:-1}" \
        RECONNECT_LOG_RETENTION_DAYS="${RETENTION:-90}" \
        bash "$RECONNECT" "$@" 2>&1
    )"
    RC_STATUS=$?
    after="$(date '+%Y-%m-%d')"
    # The last line only: a case that runs the script more than once appends,
    # and it is the outcome of *this* run that is being asserted on.
    RC_LOG="$(tail -n 1 "$dir/logs/$after.log" 2>/dev/null)"
    if [ -z "$RC_LOG" ] && [ "$before" != "$after" ]; then
        RC_LOG="$(tail -n 1 "$dir/logs/$before.log" 2>/dev/null)"
    fi
    # Only the outcome matters to the assertions, not the timestamp.
    RC_LOG="${RC_LOG#\[*\] }"
}

# =============================================================================
section "config.env parsing"
# =============================================================================

export NM_ACTIVE_PROFILE="" NM_PROFILES="" NM_SCAN="" NM_CONNECT_RC=0
unset NM_ARGS_LOG

d="$(new_case)"; printf 'WIFI_SSID="MyNet"\n' > "$d/config.env"
NM_ACTIVE_PROFILE="MyNet" NM_PROFILES="MyNet|MyNet" run_reconnect "$d"
assert_eq "plain quoted value is read" "Wifi Good" "$RC_LOG"

d="$(new_case)"; printf 'WIFI_SSID = "MyNet"\n' > "$d/config.env"
NM_ACTIVE_PROFILE="MyNet" NM_PROFILES="MyNet|MyNet" run_reconnect "$d"
assert_eq "spaces around '=' are ignored" "Wifi Good" "$RC_LOG"

d="$(new_case)"; printf 'WIFI_SSID="MyNet" \n' > "$d/config.env"
NM_ACTIVE_PROFILE="MyNet" NM_PROFILES="MyNet|MyNet" run_reconnect "$d"
assert_eq "trailing blank after a quoted value is trimmed" "Wifi Good" "$RC_LOG"

d="$(new_case)"; printf 'WIFI_SSID=My Net\n' > "$d/config.env"
NM_ACTIVE_PROFILE="My Net" NM_PROFILES="My Net|My Net" run_reconnect "$d"
assert_eq "unquoted value keeps internal spaces" "Wifi Good" "$RC_LOG"

d="$(new_case)"; printf 'WIFI_SSID="pad "\n' > "$d/config.env"
NM_ACTIVE_PROFILE="pad " NM_PROFILES="pad |pad " run_reconnect "$d"
assert_eq "quotes preserve a trailing space inside the value" "Wifi Good" "$RC_LOG"

d="$(new_case)"; printf 'WIFI_SSID=Net#1\n' > "$d/config.env"
NM_ACTIVE_PROFILE="Net#1" NM_PROFILES="Net#1|Net#1" run_reconnect "$d"
assert_eq "'#' inside a value is part of the value" "Wifi Good" "$RC_LOG"

d="$(new_case)"; printf '# a comment\n\nWIFI_SSID="MyNet"\n' > "$d/config.env"
NM_ACTIVE_PROFILE="MyNet" NM_PROFILES="MyNet|MyNet" run_reconnect "$d"
assert_eq "whole-line comments and blank lines are skipped" "Wifi Good" "$RC_LOG"

d="$(new_case)"; printf 'WIFI_SSID="MyNet"\r\nWIFI_HIDDEN="no"\r\n' > "$d/config.env"
NM_ACTIVE_PROFILE="MyNet" NM_PROFILES="MyNet|MyNet" run_reconnect "$d"
assert_eq "CRLF line endings are tolerated" "Wifi Good" "$RC_LOG"

# CRLF tolerance lives in config_value()'s blank trim and nowhere else: `[:space:]`
# includes the carriage return, so it goes with any other trailing blank, and a CR
# cannot reach a key because the key is everything left of the first '='.
# load_config() used to carry a separate `line="${line%$'\r'}"` labelled "tolerate
# CRLF files"; deleting it changed the outcome of none of twelve CRLF fixtures and
# left the whole suite green, so it was a line that could only mislead whoever next
# narrowed the trim. An *unquoted* value is what pins the trim: on the quoted case
# above the closing quote would hide a surviving CR inside the value.
d="$(new_case)"; printf 'WIFI_SSID=MyNet\r\n' > "$d/config.env"
NM_ACTIVE_PROFILE="MyNet" NM_PROFILES="MyNet|MyNet" run_reconnect "$d"
assert_eq "an unquoted value on a CRLF line loses its carriage return" \
    "Wifi Good" "$RC_LOG"

# A UTF-8 byte-order mark is the CRLF problem's invisible cousin: it sits in
# front of the first key, and an editor that writes one turned a perfectly
# correct config into "unknown setting 'WIFI_SSID'" -- a message naming a
# setting that looks exactly right, differing by three bytes a terminal does not
# draw. Rejecting unknown keys exists to make a typo obvious, not to invent one.
d="$(new_case)"; printf '\xef\xbb\xbfWIFI_SSID="MyNet"\n' > "$d/config.env"
NM_ACTIVE_PROFILE="MyNet" NM_PROFILES="MyNet|MyNet" run_reconnect "$d"
assert_eq "a UTF-8 BOM before the first key is tolerated" "Wifi Good" "$RC_LOG"

d="$(new_case)"; printf '\xef\xbb\xbf# a comment\nWIFI_SSID="MyNet"\n' > "$d/config.env"
NM_ACTIVE_PROFILE="MyNet" NM_PROFILES="MyNet|MyNet" run_reconnect "$d"
assert_eq "a BOM in front of a comment line is tolerated too" "Wifi Good" "$RC_LOG"

# ... but only on the first line, which is the only line that can carry one.
# Those bytes anywhere else are part of a key and must still be reported, or the
# strip has quietly become a filter that hides a difference the user can see.
d="$(new_case)"; printf 'WIFI_SSID="MyNet"\n\xef\xbb\xbfWIFI_HIDDEN="no"\n' > "$d/config.env"
run_reconnect "$d"
assert_eq "a BOM on a later line is not stripped" "FAIL" "$RC_LOG"
assert_contains "and is reported as the unknown key it is" "unknown setting" "$RC_OUT"

d="$(new_case)"; printf 'export WIFI_SSID="MyNet"\n' > "$d/config.env"
NM_ACTIVE_PROFILE="MyNet" NM_PROFILES="MyNet|MyNet" run_reconnect "$d"
assert_eq "a leading 'export ' is stripped" "Wifi Good" "$RC_LOG"

# The prefix used to be matched as exactly one space, so any other blank stayed
# glued to the front of the key and produced an error naming a setting that
# looks correct: "unknown setting ' WIFI_SSID'", differing by one invisible
# space. A parser whose job is to make typos obvious must not invent one.
d="$(new_case)"; printf 'export  WIFI_SSID="MyNet"\n' > "$d/config.env"
NM_ACTIVE_PROFILE="MyNet" NM_PROFILES="MyNet|MyNet" run_reconnect "$d"
assert_eq "'export' followed by extra spaces is stripped" "Wifi Good" "$RC_LOG"

d="$(new_case)"; printf 'export\tWIFI_SSID="MyNet"\n' > "$d/config.env"
NM_ACTIVE_PROFILE="MyNet" NM_PROFILES="MyNet|MyNet" run_reconnect "$d"
assert_eq "'export' followed by a tab is stripped" "Wifi Good" "$RC_LOG"

# ... but the blank is what makes it a prefix. A key that merely begins with
# those six letters is an ordinary unknown key, not an export.
d="$(new_case)"; printf 'exported="MyNet"\n' > "$d/config.env"
run_reconnect "$d"
assert_eq "a key beginning 'export' is not mistaken for the prefix" "FAIL" "$RC_LOG"
assert_contains "and is reported as the unknown setting it is" \
    "unknown setting 'exported'" "$RC_OUT"

d="$(new_case)"; printf 'WIFI_SSID="MyNet"\nWIFI_TYPO="x"\n' > "$d/config.env"
run_reconnect "$d"
assert_eq "an unknown key fails the run" "FAIL" "$RC_LOG"
assert_contains "an unknown key is named in the error" "unknown setting 'WIFI_TYPO'" "$RC_OUT"

# An empty key is the value that collides with the duplicate check's own
# accumulator: `seen` starts empty, so `" $seen "` is two blanks, and with an empty
# $key the pattern `*" $key "*` is the same two blanks. Without the `[ -n "$key" ]`
# guard the *first* `=value` line in a file was reported as "'' is set more than
# once" -- a claim that contradicts itself, and one that displaced the accurate
# "unknown setting ''", sending the reader hunting for a duplicate that is not
# there. Deleting that guard left the whole suite green, so this is what notices.
d="$(new_case)"; printf '=x\n' > "$d/config.env"
run_reconnect "$d"
assert_eq "a line with an empty key fails the run" "FAIL" "$RC_LOG"
assert_contains "and is reported as the unknown setting it is" \
    "unknown setting ''" "$RC_OUT"
assert_not_contains "rather than as a duplicate of itself" \
    "set more than once" "$RC_OUT"

# The password-safety property: a line missing its '=' is most likely a
# mistyped password line, so the error must not echo it back.
d="$(new_case)"; printf 'WIFI_SSID="MyNet"\nWIFI_PASSWORD "hunter2"\n' > "$d/config.env"
run_reconnect "$d"
assert_eq "a line with no '=' fails the run" "FAIL" "$RC_LOG"
assert_contains "the bad line's number is reported" "line 2" "$RC_OUT"
assert_not_contains "the bad line's content is never echoed" "hunter2" "$RC_OUT"

# The same mistyped line when the password itself contains '=' -- a base64-style
# one ending in `==` is the usual shape. It has an '=', so it never reaches the
# missing-'=' arm above: everything left of the first '=' became the "key", and
# the unknown-setting error printed `unknown setting 'WIFI_PASSWORD "s3cr3tB64/Q'`,
# nearly the whole password. A key that is not a plain setting name is now
# reported by line number alone.
d="$(new_case)"; printf 'WIFI_SSID="MyNet"\nWIFI_PASSWORD "s3cr3tB64/Q=="\n' > "$d/config.env"
NM_ACTIVE_PROFILE="MyNet" NM_PROFILES="MyNet|MyNet" run_reconnect "$d"
assert_eq "a mistyped password line containing '=' fails the run" "FAIL" "$RC_LOG"
assert_contains "and is still reported as an unknown setting on its line" \
    "line 2: unknown setting" "$RC_OUT"
assert_not_contains "without echoing any of the password" "s3cr3tB64" "$RC_OUT"

d="$(new_case)"; printf 'WIFI_SSID="MyNet"\nWIFI_PASSWORD: "Xk9pQ7=="\n' > "$d/config.env"
NM_ACTIVE_PROFILE="MyNet" NM_PROFILES="MyNet|MyNet" run_reconnect "$d"
assert_not_contains "nor with a ':' typed for the '='" "Xk9pQ7" "$RC_OUT"

# The control: a key that *is* a plain name is still shown, since that is what
# makes a typo like WIFI_TYPO obvious (pinned further down as well).
d="$(new_case)"; printf 'WIFI_SSID="MyNet"\nWIFI_PASWORD="x=y"\n' > "$d/config.env"
NM_ACTIVE_PROFILE="MyNet" NM_PROFILES="MyNet|MyNet" run_reconnect "$d"
assert_contains "a misspelt setting name is still named" \
    "unknown setting 'WIFI_PASWORD'" "$RC_OUT"

# The same password with no separator at all. Everything up to its first '=' is
# letters, digits and `_`, so it passed the "is this a setting name?" test above
# and was printed whole: `unknown setting 'WIFI_PASSWORDs3cr3tB64Q'`. A key that
# begins with a setting name and runs on past it is reported by line number now,
# in either case, and with an `_` between the two as well.
d="$(new_case)"; printf 'WIFI_SSID="MyNet"\nWIFI_PASSWORDs3cr3tB64Q==\n' > "$d/config.env"
NM_ACTIVE_PROFILE="MyNet" NM_PROFILES="MyNet|MyNet" run_reconnect "$d"
assert_eq "a password glued to its setting name fails the run" "FAIL" "$RC_LOG"
assert_contains "and is reported as an unknown setting on its line" \
    "line 2: unknown setting" "$RC_OUT"
assert_not_contains "without echoing the password" "s3cr3tB64Q" "$RC_OUT"

d="$(new_case)"; printf 'WIFI_SSID="MyNet"\nWIFI_PASSWORD_hunter2=x\n' > "$d/config.env"
NM_ACTIVE_PROFILE="MyNet" NM_PROFILES="MyNet|MyNet" run_reconnect "$d"
assert_not_contains "nor with an '_' between the name and the password" "hunter2" "$RC_OUT"

d="$(new_case)"; printf 'WIFI_SSID="MyNet"\nwifi_passwordhunter2=\n' > "$d/config.env"
NM_ACTIVE_PROFILE="MyNet" NM_PROFILES="MyNet|MyNet" run_reconnect "$d"
assert_not_contains "nor with the setting name typed in lower case" "hunter2" "$RC_OUT"

# The control: an exact name in the wrong case is a visible typo with nothing
# after it, and must still be named rather than swallowed by the prefix rule.
d="$(new_case)"; printf 'wifi_ssid="MyNet"\n' > "$d/config.env"
run_reconnect "$d"
assert_contains "a setting name in the wrong case is still named" \
    "unknown setting 'wifi_ssid'" "$RC_OUT"

# A key set twice used to be accepted in silence, with the last line winning --
# so a file that plainly reads WIFI_SSID="Home" connected to whatever a
# forgotten line further down said. That is the same silent-wrong-value outcome
# rejecting unknown keys exists to prevent.
d="$(new_case)"; printf 'WIFI_SSID="Home"\nWIFI_SSID="Other"\n' > "$d/config.env"
NM_ACTIVE_PROFILE="Home" NM_PROFILES="Home|Home" run_reconnect "$d"
assert_eq "a key set twice fails the run" "FAIL" "$RC_LOG"
assert_contains "the duplicated key is named" "'WIFI_SSID' is set more than once" "$RC_OUT"
assert_contains "and the offending line number is given" "line 2" "$RC_OUT"

# ... and the duplicate most worth catching is a second password line, so the
# error must name the key and nothing else. Same property the missing-'=' error
# has, for the same reason.
d="$(new_case)"
printf 'WIFI_SSID="MyNet"\nWIFI_PASSWORD="one"\nWIFI_PASSWORD="hunter2"\n' > "$d/config.env"
run_reconnect "$d"
assert_eq "a duplicated password line fails the run" "FAIL" "$RC_LOG"
assert_contains "the duplicated key is named" "'WIFI_PASSWORD' is set more than once" "$RC_OUT"
assert_not_contains "and neither value is echoed back" "hunter2" "$RC_OUT"

# Different keys are of course fine -- the check must not fire on a name that
# merely appears inside another one.
d="$(new_case)"
printf 'WIFI_SSID="MyNet"\nWIFI_HIDDEN="no"\nWIFI_IFACE=""\nWIFI_PASSWORD="x"\n' > "$d/config.env"
NM_ACTIVE_PROFILE="MyNet" NM_PROFILES="MyNet|MyNet" run_reconnect "$d"
assert_eq "four distinct keys are all accepted" "Wifi Good" "$RC_LOG"

# A value of nothing but blanks survived the "is it empty?" check and then
# failed at the connect as `could not connect to    :` -- a runtime error
# standing in for a config error, naming nothing a reader can see.
d="$(new_case)"; printf 'WIFI_SSID="   "\n' > "$d/config.env"
run_reconnect "$d"
assert_eq "a blanks-only WIFI_SSID fails the run" "FAIL" "$RC_LOG"
assert_contains "and is reported as a config error" "blanks only" "$RC_OUT"
assert_not_contains "rather than as a failed connect" "could not connect" "$RC_OUT"

# The quoting that preserves a real space inside a value must still work: this
# rejects blanks-only, not blanks.
d="$(new_case)"; printf 'WIFI_SSID=" pad "\n' > "$d/config.env"
NM_ACTIVE_PROFILE=" pad " NM_PROFILES=" pad | pad " run_reconnect "$d"
assert_eq "an SSID padded with spaces is still accepted" "Wifi Good" "$RC_LOG"

# The same guard on WIFI_IFACE, which had none. A blanks-only value is not empty,
# so it passed every check and reached nmcli as `ifname "   "` on the scan, the
# rescan and the connect -- and the run then failed with nmcli's own device
# error, a runtime failure standing in for a config error and naming neither the
# setting nor anything a reader can see.
#
# The fixture is deliberately one that would otherwise *succeed*: a saved
# profile for the target SSID. Without it the run recorded FAIL either way --
# there was nothing to connect to -- so the outcome assertion could not tell the
# guard from its absence. And the argv assertion reads NM_ARGS_LOG rather than
# RC_OUT, because that is where the device name would show up; asserting on the
# script's own output meant asserting on a stream the word `ifname` never
# reaches, so it held whether or not the guard was there. Two of the three
# assertions here used to be inert, which is a test block reporting coverage the
# suite did not have.
d="$(new_case)"; printf 'WIFI_SSID="MyNet"\nWIFI_IFACE="  "\n' > "$d/config.env"
: > "$d/nmcli-args"
NM_ACTIVE_PROFILE="MyNet" NM_PROFILES="MyNet|MyNet" NM_SCAN="MyNet" \
    NM_ARGS_LOG="$d/nmcli-args" run_reconnect "$d"
assert_eq "a blanks-only WIFI_IFACE fails the run" "FAIL" "$RC_LOG"
assert_contains "and is reported as a config error naming the setting" \
    "WIFI_IFACE is set to blanks only" "$RC_OUT"
assert_not_contains "rather than reaching nmcli as a device name" \
    "ifname" "$(cat "$d/nmcli-args")"

# Empty is the ordinary "let NetworkManager pick" case and must stay legal --
# this rejects blanks, not the absence of a value.
d="$(new_case)"; printf 'WIFI_SSID="MyNet"\nWIFI_IFACE=""\n' > "$d/config.env"
NM_ACTIVE_PROFILE="MyNet" NM_PROFILES="MyNet|MyNet" run_reconnect "$d"
assert_eq "an empty WIFI_IFACE is still accepted" "Wifi Good" "$RC_LOG"

d="$(new_case)"; printf 'WIFI_PASSWORD="x"\n' > "$d/config.env"
run_reconnect "$d"
assert_eq "a missing WIFI_SSID fails the run" "FAIL" "$RC_LOG"
assert_contains "the missing WIFI_SSID is named" "WIFI_SSID must be set" "$RC_OUT"

d="$(new_case)"
run_reconnect "$d"
assert_eq "a missing config file fails the run" "FAIL" "$RC_LOG"
assert_contains "the missing config is named" "Config file not found" "$RC_OUT"

# Checking -f alone was not enough. A config that exists but cannot be read passed
# it and then failed at load_config's redirect, which `set -e` turns into an exit
# with no log line and, under cron, no output either -- the one silent failure
# everything else here is arranged to avoid. This is reachable in ordinary use:
# setup tells you to chmod 600 the file, so a job installed under a different user
# than the file's owner lands right here. Deleting the check left the suite green.
#
# Skipped where the filesystem does not enforce the mode -- Cygwin, some mounted
# volumes, or a run as root -- because there the fixture is simply not unreadable
# and the assertion would be about the platform rather than about the code.
d="$(new_case)"; printf 'WIFI_SSID="MyNet"\n' > "$d/config.env"
chmod 000 "$d/config.env" 2>/dev/null
if [ -r "$d/config.env" ]; then
    printf '  skip unreadable-config test: this filesystem does not enforce the mode\n'
else
    run_reconnect "$d"
    assert_eq "an unreadable config fails the run" "FAIL" "$RC_LOG"
    assert_contains "and says so rather than exiting silently" \
        "is not readable by user" "$RC_OUT"
fi
chmod 600 "$d/config.env" 2>/dev/null

# The same distinction one step earlier: a directory passes both -e and -r, so
# without the -f check it reached that same redirect and died the same silent way.
d="$(new_case)"; mkdir -p "$d/config.env"
run_reconnect "$d"
assert_eq "a config path that is a directory fails the run" "FAIL" "$RC_LOG"
assert_contains "and is reported as not a regular file" \
    "is not a regular file" "$RC_OUT"

d="$(new_case)"; printf 'WIFI_SSID="MyNet"\nWIFI_HIDDEN="maybe"\n' > "$d/config.env"
run_reconnect "$d"
assert_eq "an invalid WIFI_HIDDEN fails the run" "FAIL" "$RC_LOG"
assert_contains "and the rejected value is shown back" "got: 'maybe'" "$RC_OUT"

# The value is quoted in that message because unquoted it produced
# `must be yes or no; got:   ` for a blanks-only setting -- a message whose
# subject is invisible, which is the failure shape the blanks-only WIFI_SSID
# check exists to eliminate. Quoting is enough here: the message already names
# the setting and both legal spellings.
d="$(new_case)"; printf 'WIFI_SSID="MyNet"\nWIFI_HIDDEN="  "\n' > "$d/config.env"
run_reconnect "$d"
assert_eq "a blanks-only WIFI_HIDDEN fails the run" "FAIL" "$RC_LOG"
assert_contains "and the blanks are visible in the message" "got: '  '" "$RC_OUT"

for v in yes YES true 1; do
    d="$(new_case)"; printf 'WIFI_SSID="MyNet"\nWIFI_HIDDEN="%s"\n' "$v" > "$d/config.env"
    NM_ACTIVE_PROFILE="MyNet" NM_PROFILES="MyNet|MyNet" run_reconnect "$d"
    assert_eq "WIFI_HIDDEN=$v is accepted" "Wifi Good" "$RC_LOG"
done

# =============================================================================
section "terse nmcli output: escaped fields"
# =============================================================================

d="$(new_case)"; printf 'WIFI_SSID="Cafe: Wifi"\n' > "$d/config.env"
NM_ACTIVE_PROFILE="Cafe: Wifi" NM_PROFILES="Cafe: Wifi|Cafe: Wifi" run_reconnect "$d"
assert_eq "an SSID containing ':' is unescaped correctly" "Wifi Good" "$RC_LOG"

d="$(new_case)"; printf 'WIFI_SSID="back\\slash"\n' > "$d/config.env"
NM_ACTIVE_PROFILE='back\slash' NM_PROFILES='back\slash|back\slash' run_reconnect "$d"
assert_eq "an SSID containing a backslash is unescaped correctly" "Wifi Good" "$RC_LOG"

d="$(new_case)"; printf 'WIFI_SSID="odd\\:name"\n' > "$d/config.env"
NM_ACTIVE_PROFILE='odd\:name' NM_PROFILES='odd\:name|odd\:name' run_reconnect "$d"
assert_eq "an SSID containing the sequence '\\:' is unescaped correctly" "Wifi Good" "$RC_LOG"

# =============================================================================
section "connecting"
# =============================================================================

# A saved profile exists, so the password must never reach nmcli's arguments.
d="$(new_case)"
printf 'WIFI_SSID="MyNet"\nWIFI_PASSWORD="hunter2"\n' > "$d/config.env"
: > "$d/nmcli-args"
NM_ACTIVE_PROFILE="Other" NM_PROFILES="MyNet|MyNet" NM_SCAN="MyNet" \
    NM_ARGS_LOG="$d/nmcli-args" run_reconnect "$d"
assert_eq "a saved profile reconnects" "Wifi Reconnected" "$RC_LOG"
assert_contains "the saved profile is brought up by name" "connection up id MyNet" "$(cat "$d/nmcli-args")"
assert_not_contains "the password never reaches nmcli's arguments" "hunter2" "$(cat "$d/nmcli-args")"

# A renamed profile: NetworkManager calls it "MyNet 1" but it is configured for
# the target SSID, so it must still be found by SSID rather than by name.
d="$(new_case)"
printf 'WIFI_SSID="MyNet"\nWIFI_PASSWORD="hunter2"\n' > "$d/config.env"
: > "$d/nmcli-args"
NM_ACTIVE_PROFILE="Other" NM_PROFILES="MyNet 1|MyNet" NM_SCAN="MyNet" \
    NM_ARGS_LOG="$d/nmcli-args" run_reconnect "$d"
assert_eq "a renamed profile is matched on its SSID" "Wifi Reconnected" "$RC_LOG"
assert_contains "the renamed profile is used" "connection up id MyNet 1" "$(cat "$d/nmcli-args")"
assert_not_contains "the password is still kept off the arguments" "hunter2" "$(cat "$d/nmcli-args")"

# No saved profile: the password form is the documented fallback.
d="$(new_case)"
printf 'WIFI_SSID="MyNet"\nWIFI_PASSWORD="hunter2"\n' > "$d/config.env"
: > "$d/nmcli-args"
NM_ACTIVE_PROFILE="Other" NM_PROFILES="" NM_SCAN="MyNet" \
    NM_ARGS_LOG="$d/nmcli-args" run_reconnect "$d"
assert_eq "with no saved profile the password form connects" "Wifi Reconnected" "$RC_LOG"
assert_contains "the password form is used" "dev wifi connect MyNet password hunter2" "$(cat "$d/nmcli-args")"

# Neither a profile nor a password: this must be a stated failure.
d="$(new_case)"; printf 'WIFI_SSID="MyNet"\n' > "$d/config.env"
NM_ACTIVE_PROFILE="Other" NM_PROFILES="" NM_SCAN="MyNet" run_reconnect "$d"
assert_eq "no profile and no password fails" "FAIL" "$RC_LOG"
assert_contains "the reason explains both options" "no saved NetworkManager profile" "$RC_OUT"

# A failing connect must scrub the password out of nmcli's own diagnostic.
d="$(new_case)"
printf 'WIFI_SSID="MyNet"\nWIFI_PASSWORD="hunter2"\n' > "$d/config.env"
NM_ACTIVE_PROFILE="Other" NM_PROFILES="" NM_SCAN="MyNet" \
    NM_CONNECT_RC=1 NM_CONNECT_MSG="Error: password 'hunter2' was rejected." \
    run_reconnect "$d"
assert_eq "a failing connect records FAIL" "FAIL" "$RC_LOG"
assert_contains "nmcli's reason is surfaced" "was rejected" "$RC_OUT"
assert_not_contains "the password is scrubbed from the reason" "hunter2" "$RC_OUT"

# SECURITY.md documents two cases where the password reaches a command line: the
# first connect, and any attempt where bringing up the saved profile fails. The
# second half used to be undocumented, and it is the one that recurs -- under the
# polkit condition DECISIONS.md D1 describes, `connection up` fails on every
# scheduled run. Asserted here so the documented behaviour and the real behaviour
# cannot drift apart again.
d="$(new_case)"
printf 'WIFI_SSID="MyNet"\nWIFI_PASSWORD="hunter2"\n' > "$d/config.env"
: > "$d/nmcli-args"
NM_ACTIVE_PROFILE="Other" NM_PROFILES="MyNet|MyNet" NM_SCAN="MyNet" \
    NM_CONNECT_RC=1 NM_ARGS_LOG="$d/nmcli-args" run_reconnect "$d"
assert_eq "a saved profile that will not come up records FAIL" "FAIL" "$RC_LOG"
assert_contains "the saved profile is still tried first" \
    "connection up id MyNet" "$(cat "$d/nmcli-args")"
assert_contains "and the password form is then attempted, as SECURITY.md says" \
    "dev wifi connect MyNet password hunter2" "$(cat "$d/nmcli-args")"

# The documented way out of that: with no password there is nothing to fall back
# to, so the password can never reach an argv however often the profile fails.
d="$(new_case)"
printf 'WIFI_SSID="MyNet"\n' > "$d/config.env"
: > "$d/nmcli-args"
NM_ACTIVE_PROFILE="Other" NM_PROFILES="MyNet|MyNet" NM_SCAN="MyNet" \
    NM_CONNECT_RC=1 NM_ARGS_LOG="$d/nmcli-args" run_reconnect "$d"
assert_eq "with no password a failing profile just records FAIL" "FAIL" "$RC_LOG"
assert_not_contains "and no password form is ever attempted" \
    "dev wifi connect" "$(cat "$d/nmcli-args")"

# The SSID in the password form is a bare positional: it is passed with nothing
# in front of it. It used to carry a `--`, meant as an end-of-options marker so
# that a network called `-t` would be read as a name; nmcli has no such marker
# there, so the `--` *was* the SSID and every real password connect failed
# (DECISIONS.md D6). This pins the bare shape, on an SSID beginning with `-`
# deliberately: that is the one input a well-meant `--` would be reintroduced
# for, and it must still go through bare.
#
# The profile lookup is not a bare positional any more: it names the profile
# after `connection show`'s `id` selector, the same way `connection up id`
# does, and nmcli takes whatever follows `id` literally. A `--` there would
# become the name itself, so it is pinned absent too.
d="$(new_case)"
printf 'WIFI_SSID="-t"\nWIFI_PASSWORD="pw"\n' > "$d/config.env"
: > "$d/nmcli-args"
NM_ACTIVE_PROFILE="Other" NM_PROFILES="" NM_SCAN="-t" \
    NM_ARGS_LOG="$d/nmcli-args" run_reconnect "$d"
assert_eq "an SSID that looks like an option is still passed through" "Wifi Reconnected" "$RC_LOG"
assert_contains "the SSID goes to the password form bare, with no marker in front of it" \
    "dev wifi connect -t password pw" "$(cat "$d/nmcli-args")"
assert_not_contains "and never behind a '--' nmcli would take as the SSID" \
    "dev wifi connect --" "$(cat "$d/nmcli-args")"
assert_contains "the profile lookup names the profile after the id selector" \
    "802-11-wireless.ssid connection show id -t" "$(cat "$d/nmcli-args")"
assert_not_contains "and never behind a '--' nmcli would take as the name" \
    "802-11-wireless.ssid connection show id --" "$(cat "$d/nmcli-args")"

# Saved profiles whose names nmcli would read as part of its own syntax if they
# came bare: `--active` is one of `connection show`'s options, and `id` is one
# of its selector words. Passed bare, neither was ever found -- `--active` was
# taken as the option and `id` as a selector still wanting its argument -- so
# every reconnect fell through to the password form. After `id` both are looked
# up as names. The stub answers only the `id` spelling, so these fail if the
# selector is dropped; the password is set, so a lookup that failed would show
# as `dev wifi connect` in the argv rather than as a FAIL alone.
for odd_profile in --active id; do
    d="$(new_case)"
    printf 'WIFI_SSID="MyNet"\nWIFI_PASSWORD="hunter2"\n' > "$d/config.env"
    : > "$d/nmcli-args"
    NM_ACTIVE_PROFILE="Other" NM_PROFILES="$odd_profile|MyNet" NM_SCAN="MyNet" \
        NM_ARGS_LOG="$d/nmcli-args" run_reconnect "$d"
    assert_eq "a saved profile named '$odd_profile' reconnects" "Wifi Reconnected" "$RC_LOG"
    assert_contains "and is looked up by name after the id selector" \
        "802-11-wireless.ssid connection show id $odd_profile" "$(cat "$d/nmcli-args")"
    assert_contains "and brought up as that profile" \
        "connection up id $odd_profile" "$(cat "$d/nmcli-args")"
    assert_not_contains "without falling back to the password form" \
        "dev wifi connect" "$(cat "$d/nmcli-args")"
done

# A hidden network is never in the scan list; it must connect anyway.
d="$(new_case)"
printf 'WIFI_SSID="Ghost"\nWIFI_PASSWORD="pw"\nWIFI_HIDDEN="yes"\n' > "$d/config.env"
: > "$d/nmcli-args"
NM_ACTIVE_PROFILE="Other" NM_PROFILES="" NM_SCAN="" \
    NM_ARGS_LOG="$d/nmcli-args" run_reconnect "$d"
assert_eq "a hidden network connects without appearing in a scan" "Wifi Reconnected" "$RC_LOG"
assert_contains "the hidden flag is passed through" "hidden yes" "$(cat "$d/nmcli-args")"

# With WIFI_IFACE set, the scan lookups must be scoped to that device. `dev wifi`
# lists access points across every adapter, so on a two-adapter machine the
# unscoped form could report an SSID that is active on the other one and make
# the run log "Wifi Good" without the pinned interface being connected.
#
# SCAN_WAIT is raised to 1 so the scan-wait loop runs at all and target_visible
# is actually called; the target is in the scan list, so it breaks on the first
# poll and costs nothing.
d="$(new_case)"
printf 'WIFI_SSID="MyNet"\nWIFI_PASSWORD="pw"\nWIFI_IFACE="wlan9"\n' > "$d/config.env"
: > "$d/nmcli-args"
NM_ACTIVE_PROFILE="Other" NM_PROFILES="MyNet|MyNet" NM_SCAN="MyNet" \
    SCAN_WAIT=1 NM_ARGS_LOG="$d/nmcli-args" run_reconnect "$d"
assert_contains "WIFI_IFACE scopes the active-SSID scan lookup" \
    "-t -f ACTIVE,SSID dev wifi list ifname wlan9" "$(cat "$d/nmcli-args")"
assert_contains "WIFI_IFACE scopes the target-visible scan lookup" \
    "-t -f SSID dev wifi list ifname wlan9" "$(cat "$d/nmcli-args")"

# Two Wi-Fi connections up at once, with WIFI_IFACE left empty -- the README's
# default. Only the first active profile used to be read, so a target listed
# second was never seen: the run logged "Wifi Reconnected" and ran `connection
# up` on a connection that was already up, which re-activates it, every
# interval. The assertion on the argv is the one that matters; the log line
# alone would not show the needless re-activation's cost.
d="$(new_case)"
printf 'WIFI_SSID="MyNet"\nWIFI_PASSWORD="pw"\n' > "$d/config.env"
: > "$d/nmcli-args"
NM_ACTIVE_PROFILE=$'Other|wlan1\nMyNet|wlan0' NM_PROFILES=$'Other|OtherNet\nMyNet|MyNet' \
    NM_SCAN=$'OtherNet\nMyNet' NM_ARGS_LOG="$d/nmcli-args" run_reconnect "$d"
assert_eq "a target active second among two Wi-Fi connections is Wifi Good" \
    "Wifi Good" "$RC_LOG"
assert_not_contains "and the connection that is already up is not brought up again" \
    "connection up" "$(cat "$d/nmcli-args")"

# The controls: with only the other connection up the run must still
# reconnect, and a pinned WIFI_IFACE must still ignore a target that is active
# on a different device -- or the fix would be "any Wi-Fi anywhere will do".
d="$(new_case)"
printf 'WIFI_SSID="MyNet"\nWIFI_PASSWORD="pw"\n' > "$d/config.env"
NM_ACTIVE_PROFILE='Other|wlan1' NM_PROFILES=$'Other|OtherNet\nMyNet|MyNet' \
    NM_SCAN=$'OtherNet\nMyNet' run_reconnect "$d"
assert_eq "with only another network up the run still reconnects" \
    "Wifi Reconnected" "$RC_LOG"
d="$(new_case)"
printf 'WIFI_SSID="MyNet"\nWIFI_PASSWORD="pw"\nWIFI_IFACE="wlan1"\n' > "$d/config.env"
NM_ACTIVE_PROFILE=$'Other|wlan1\nMyNet|wlan0' NM_PROFILES=$'Other|OtherNet\nMyNet|MyNet' \
    NM_SCAN=$'OtherNet\nMyNet' run_reconnect "$d"
assert_eq "and a pinned interface still ignores the target on another device" \
    "Wifi Reconnected" "$RC_LOG"

# =============================================================================
section "environment override validation"
# =============================================================================

d="$(new_case)"; printf 'WIFI_SSID="MyNet"\n' > "$d/config.env"
SCAN_WAIT="abc" run_reconnect "$d"
assert_eq "a non-numeric scan wait fails the run" "FAIL" "$RC_LOG"
assert_contains "the offending setting is named" "RECONNECT_SCAN_WAIT_SECS" "$RC_OUT"

d="$(new_case)"; printf 'WIFI_SSID="MyNet"\n' > "$d/config.env"
ATTEMPTS="0" run_reconnect "$d"
assert_eq "zero connect attempts fails the run" "FAIL" "$RC_LOG"

# reconnect.sh refuses four numeric overrides, and only the two above were ever
# given a value it rejects: NMCLI_WAIT was only ever passed 1 and RETENTION only
# 30 and 0, all valid, so two of the four `die` calls were never entered at all.
# A regression that dropped either would have left the suite green -- and the
# failure it produces is the one those checks exist to prevent, a job that logs
# FAIL every interval with the reason going to /dev/null under cron.
#
# Each fixture is one that would otherwise connect: an active profile for the
# target SSID, so the run logs "Wifi Good" the moment the validation stops
# refusing. Without that the run recorded FAIL either way -- there was nothing
# to connect to -- and the outcome assertion could not tell the check from its
# absence, which is the inert-assertion shape the WIFI_IFACE block above was
# just corrected for.
d="$(new_case)"; printf 'WIFI_SSID="MyNet"\n' > "$d/config.env"
NM_ACTIVE_PROFILE="MyNet" NM_PROFILES="MyNet|MyNet" NMCLI_WAIT="abc" run_reconnect "$d"
assert_eq "a non-numeric nmcli wait fails the run" "FAIL" "$RC_LOG"
assert_contains "the offending setting is named" "RECONNECT_NMCLI_WAIT_SECS" "$RC_OUT"

# The bound here is >= 1, not >= 0: a zero timeout would mean "give up
# immediately", which is not a timeout at all.
d="$(new_case)"; printf 'WIFI_SSID="MyNet"\n' > "$d/config.env"
NM_ACTIVE_PROFILE="MyNet" NM_PROFILES="MyNet|MyNet" NMCLI_WAIT="0" run_reconnect "$d"
assert_eq "a zero nmcli wait fails the run" "FAIL" "$RC_LOG"
assert_contains "and says a whole number >= 1 is wanted" "whole number >= 1" "$RC_OUT"

d="$(new_case)"; printf 'WIFI_SSID="MyNet"\n' > "$d/config.env"
NM_ACTIVE_PROFILE="MyNet" NM_PROFILES="MyNet|MyNet" RETENTION="abc" run_reconnect "$d"
assert_eq "a non-numeric log retention fails the run" "FAIL" "$RC_LOG"
assert_contains "that setting is named too" "RECONNECT_LOG_RETENTION_DAYS" "$RC_OUT"

# Digits alone were not enough. Bash integers are intmax_t, and the two ways of
# going past that fail differently and both badly: `test -ge` refuses with a bare
# "integer expected" on stderr, while `$(( ))` -- which install-cron.sh uses to
# bound these same settings -- wraps in silence. So a 20-digit value was refused
# here and *accepted* there, and the installer reported a clean install for a job
# that then logged FAIL every interval with the reason going to /dev/null. The two
# scripts now apply the same 18-digit rule; this pins reconnect.sh's half and the
# install-cron.sh section pins the other, because a rule enforced on one side of a
# pair is the same defect in a new place.
d="$(new_case)"; printf 'WIFI_SSID="MyNet"\n' > "$d/config.env"
NM_ACTIVE_PROFILE="MyNet" NM_PROFILES="MyNet|MyNet" \
    ATTEMPTS=99999999999999999999 run_reconnect "$d"
assert_eq "an over-wide connect-attempts value fails the run" "FAIL" "$RC_LOG"
assert_contains "and is refused by name, with the width stated" \
    "RECONNECT_CONNECT_ATTEMPTS must be a whole number >= 1, at most 18 digits" "$RC_OUT"
assert_not_contains "rather than leaking bash's own diagnostic" \
    "integer expected" "$RC_OUT"

# The retention path is separate and was worse: prune_logs() is reached from
# status(), which is reached from die(), so it sees values that never went through
# the validation. An over-wide one made its `-gt` print "integer expected" on
# stderr on every single run while pruning was silently off.
d="$(new_case)"; printf 'WIFI_SSID="MyNet"\n' > "$d/config.env"
NM_ACTIVE_PROFILE="MyNet" NM_PROFILES="MyNet|MyNet" \
    RETENTION=99999999999999999999 run_reconnect "$d"
assert_eq "an over-wide log retention fails the run" "FAIL" "$RC_LOG"
assert_not_contains "and prune_logs does not print a bash diagnostic either" \
    "integer expected" "$RC_OUT"

# The width is measured after leading zeros are stripped, so a perfectly legal
# value that happens to be spelled with a long run of them is not refused. Without
# this the guard would reject values reconnect.sh has always accepted, which is the
# opposite half of the same disagreement.
d="$(new_case)"; printf 'WIFI_SSID="MyNet"\n' > "$d/config.env"
NM_ACTIVE_PROFILE="MyNet" NM_PROFILES="MyNet|MyNet" \
    ATTEMPTS=0000000000000000000003 run_reconnect "$d"
assert_eq "leading zeros do not make a value too wide" "Wifi Good" "$RC_LOG"

# The bound itself, which everything above leaves unpinned. A 20-digit value is
# refused by *any* width rule the two scripts might drift to -- 19 digits, 25,
# 40 -- so those assertions establish that a rule exists and say nothing about
# where it draws the line. That is a check at the wrong level of abstraction for
# a rule whose whole purpose is that the two scripts draw the line in the same
# place: widening install-cron.sh's fits_in_integer() from 18 to 19 left this
# entire suite green, while RECONNECT_NMCLI_WAIT_SECS=9000000000000000000 --
# nineteen digits and still inside intmax_t, so `$(( ))` accepts it and only the
# width rule can refuse it -- installed cleanly onto the cron line and was then
# refused by reconnect.sh. A clean install followed by FAIL every interval with
# the reason going to /dev/null, which is the one outcome the shared rule exists
# to prevent, reintroduced by a one-digit drift nothing here would have noticed.
#
# So both edges are pinned, on both sides of the pair: 18 digits accepted, 19
# refused. This is reconnect.sh's half; the install-cron.sh section pins the
# other, because a boundary held on one side of a pair is not a shared rule.
d="$(new_case)"; printf 'WIFI_SSID="MyNet"\n' > "$d/config.env"
NM_ACTIVE_PROFILE="MyNet" NM_PROFILES="MyNet|MyNet" \
    ATTEMPTS=999999999999999999 run_reconnect "$d"
assert_eq "an 18-digit value is accepted, so the bound is not below 18" \
    "Wifi Good" "$RC_LOG"

d="$(new_case)"; printf 'WIFI_SSID="MyNet"\n' > "$d/config.env"
NM_ACTIVE_PROFILE="MyNet" NM_PROFILES="MyNet|MyNet" \
    ATTEMPTS=9000000000000000000 run_reconnect "$d"
assert_eq "a 19-digit value is refused, so the bound is not above 18" \
    "FAIL" "$RC_LOG"
assert_contains "and is refused by the width rule, not by the range check" \
    "at most 18 digits" "$RC_OUT"
assert_not_contains "with no bash diagnostic leaking out" \
    "integer expected" "$RC_OUT"

# The rejected value is quoted, the way WIFI_HIDDEN's is and for the same reason
# written out there: a blanks-only setting otherwise produced `... at most 18
# digits; got: ` with nothing after it, a refusal whose subject is invisible.
# These four arrive from the environment, so `RECONNECT_SCAN_WAIT_SECS="$n"` with
# $n blank is how it happens, and under cron the message goes to /dev/null -- a
# hand-run is the only place anyone ever sees it, which is exactly when it has to
# be readable. install-cron.sh's half is pinned in its own section, because a
# message rule held on one side of the pair is the same gap in a new place.
#
# The fixture would otherwise connect -- an active profile for the target SSID --
# so the run logs "Wifi Good" the moment the validation stops refusing, and the
# outcome assertion can tell the check from its absence.
d="$(new_case)"; printf 'WIFI_SSID="MyNet"\n' > "$d/config.env"
NM_ACTIVE_PROFILE="MyNet" NM_PROFILES="MyNet|MyNet" SCAN_WAIT="  " run_reconnect "$d"
assert_eq "a blanks-only scan wait fails the run" "FAIL" "$RC_LOG"
assert_contains "and the quotes make the blanks visible" \
    "RECONNECT_SCAN_WAIT_SECS must be a non-negative whole number of seconds, at most 18 digits; got: '  '" \
    "$RC_OUT"

# A tab rather than spaces on this one. It is the worse spelling: unquoted it
# printed as alignment, so the refusal did not even look truncated.
#
# An *empty* value is deliberately not asserted anywhere here, because it cannot
# reach the validation: reconnect.sh reads these with `${RECONNECT_*:-default}`,
# which substitutes the default for an empty value as well as for an unset one,
# so `RECONNECT_CONNECT_ATTEMPTS=` is the default 3 rather than a rejected empty
# string. Blanks-only is the reachable case, and it is the one that was invisible.
d="$(new_case)"; printf 'WIFI_SSID="MyNet"\n' > "$d/config.env"
NM_ACTIVE_PROFILE="MyNet" NM_PROFILES="MyNet|MyNet" \
    ATTEMPTS="$(printf '\t')" run_reconnect "$d"
assert_eq "a tab connect-attempts value fails the run" "FAIL" "$RC_LOG"
assert_contains "and is visible between quotes rather than printing as alignment" \
    "$(printf "got: '\t'")" "$RC_OUT"

# The control: a value that is visible on its own must still read the same way,
# so the quotes are added to the message rather than replacing what it said.
d="$(new_case)"; printf 'WIFI_SSID="MyNet"\n' > "$d/config.env"
NM_ACTIVE_PROFILE="MyNet" NM_PROFILES="MyNet|MyNet" RETENTION="abc" run_reconnect "$d"
assert_contains "an ordinary bad value is quoted too, not left bare" \
    "got: 'abc'" "$RC_OUT"

# `date` is preflighted ahead of everything else, not beside the nmcli and awk
# checks further down. Sitting there it did not cover the die() calls that fire
# during config loading, so on a machine with no date a bad config key still
# produced the exact failure the check exists to prevent: `[] FAIL` written into
# a file named literally `.log`, which neither prune_logs() nor
# `uninstall-cron.sh --purge-logs` will ever clean up, because neither touches
# anything outside YYYY-MM-DD.log. The config below is deliberately broken too,
# so the assertion is about which error wins rather than about there being one.
#
# PATH is rebuilt from wrappers that exec the real binary by absolute path, which
# is the only way to take `date` off PATH without also losing the `mkdir` that
# status() calls before the run can record anything.
#
# `dirname` used to be in that sentence and in the loop below, on the grounds
# that reconnect.sh reaches it first. It does not, and has not since SCRIPT_DIR
# was rewritten to split with parameter expansion -- the only `dirname` this
# whole project runs is the one in the `cat`-preflight block far below, which the
# prerequisite list already says. A wrapper for a command nothing under test
# invokes is not harmless in a fixture whose entire point is which commands are
# absent, so it is gone rather than merely explained.
real_bash="$(command -v bash)"
nodate="$(new_case)/nodate"
mkdir -p "$nodate"
nodate_ok=1
# Straight-line rather than the `for` the other fixtures use, because there is
# only one command left to wrap and shellcheck says so at --severity=style
# (SC2043), which CI runs.
real_mkdir="$(command -v mkdir || true)"
if [ -z "$real_mkdir" ]; then
    nodate_ok=0
else
    printf '#!%s\nexec %s "$@"\n' "$real_bash" "$real_mkdir" > "$nodate/mkdir"
    chmod +x "$nodate/mkdir"
fi
if [ -z "$real_bash" ] || [ "$nodate_ok" -ne 1 ]; then
    printf '  skip date-preflight test: could not build a PATH without date\n'
else
    d="$(new_case)"
    printf 'WIFI_SSID="MyNet"\nBOGUS=1\n' > "$d/config.env"
    nodate_out="$(RECONNECT_CONFIG="$d/config.env" RECONNECT_LOG_DIR="$d/logs" \
        PATH="$nodate" "$real_bash" "$RECONNECT" 2>&1)"
    assert_contains "a missing date is reported" "date not found" "$nodate_out"
    assert_not_contains "and is reported before the config is read at all" \
        "unknown setting" "$nodate_out"
fi

# `sleep` is preflighted inside the reconnect path, not beside the nmcli and awk
# checks. Sitting there it fired on every run, including the already-connected
# one that exits before anything calls sleep -- so a machine correctly on the
# target network logged FAIL and exited 1 instead of "Wifi Good" and 0. That is
# the steady-state path and the one a monitoring check keys off, refused over a
# command it does not run.
#
# The two cases are asserted separately, on the log line rather than only on the
# exit status: a run that reaches the scan wait must still refuse, or the fix
# would have deleted the check instead of moving it.
nosleep="$TMP/no-sleep"
nosleep_ok=1
[ -n "$real_bash" ] || nosleep_ok=0
if [ "$nosleep_ok" -eq 1 ]; then
    mkdir -p "$nosleep"
    # `sed` is on this list because the nmcli stub's escaper uses it, not
    # because reconnect.sh does. Leaving it off made the stub emit nothing, so
    # the run found no active SSID, took the reconnect path and died on the very
    # check this block is meant to prove it skips -- a red assertion blaming the
    # code under test for a missing prerequisite, which is the trap the header
    # of this file describes.
    # `dirname` is deliberately not here, for the reason the nodate fixture
    # above records: reconnect.sh does not run one.
    for tool in bash mkdir date awk touch rm id sed; do
        real_tool="$(command -v "$tool" || true)"
        if [ -z "$real_tool" ]; then
            nosleep_ok=0
            continue
        fi
        printf '#!%s\nexec %s "$@"\n' "$real_bash" "$real_tool" > "$nosleep/$tool"
        chmod +x "$nosleep/$tool"
    done
    cp "$STUB_BIN/nmcli" "$nosleep/nmcli" 2>/dev/null || nosleep_ok=0
fi

if [ "$nosleep_ok" -ne 1 ]; then
    printf '  skip sleep-preflight tests: could not build a PATH without sleep\n'
else
    # Already connected: sleep is never reached, so the run must succeed.
    d="$(new_case)"; printf 'WIFI_SSID="MyNet"\n' > "$d/config.env"
    nosleep_out="$(NM_ACTIVE_PROFILE="MyNet" NM_PROFILES="MyNet|MyNet" \
        RECONNECT_CONFIG="$d/config.env" RECONNECT_LOG_DIR="$d/logs" \
        PATH="$nosleep" "$real_bash" "$RECONNECT" 2>&1)"
    nosleep_status=$?
    nosleep_log="$(tail -n 1 "$d/logs/$(date '+%Y-%m-%d').log" 2>/dev/null)"
    assert_eq "an already-connected run does not need sleep" \
        "0" "$nosleep_status"
    assert_eq "and logs Wifi Good rather than FAIL" \
        "Wifi Good" "${nosleep_log#\[*\] }"
    assert_not_contains "and says nothing about sleep" "sleep not found" "$nosleep_out"

    # Not connected, with a scan wait to serve: sleep is reachable, so the run
    # must still refuse and say so.
    d="$(new_case)"; printf 'WIFI_SSID="MyNet"\n' > "$d/config.env"
    nosleep_out="$(NM_ACTIVE_PROFILE="Other" NM_PROFILES="" NM_SCAN="" \
        RECONNECT_CONFIG="$d/config.env" RECONNECT_LOG_DIR="$d/logs" \
        RECONNECT_SCAN_WAIT_SECS=5 RECONNECT_CONNECT_ATTEMPTS=1 \
        PATH="$nosleep" "$real_bash" "$RECONNECT" 2>&1)"
    assert_contains "a run that reaches the scan wait still refuses without sleep" \
        "sleep not found" "$nosleep_out"

    # ... and a run configured so that neither call site is reachable does not
    # need it either: a hidden network skips the scan wait, and one attempt
    # leaves no gap to pace.
    d="$(new_case)"
    printf 'WIFI_SSID="MyNet"\nWIFI_PASSWORD="pw"\nWIFI_HIDDEN="yes"\n' > "$d/config.env"
    nosleep_out="$(NM_ACTIVE_PROFILE="Other" NM_PROFILES="" NM_SCAN="" \
        RECONNECT_CONFIG="$d/config.env" RECONNECT_LOG_DIR="$d/logs" \
        RECONNECT_SCAN_WAIT_SECS=15 RECONNECT_CONNECT_ATTEMPTS=1 \
        PATH="$nosleep" "$real_bash" "$RECONNECT" 2>&1)"
    nosleep_status=$?
    assert_eq "a hidden network with one attempt connects without sleep" \
        "0" "$nosleep_status"
    assert_not_contains "and does not mention sleep either" \
        "sleep not found" "$nosleep_out"
fi

# =============================================================================
section "reconnect.sh arguments"
# =============================================================================
# It takes none, and it used to accept anything and ignore it without a word:
# `./reconnect.sh --help` printed no help, it read the config, called nmcli and
# attempted a live connect. install-cron.sh and uninstall-cron.sh both refuse an
# unrecognised argument -- "silently installing the job in response to e.g.
# --help would be a nasty surprise" -- and driving the radio in response to one
# is the same surprise in the script that actually does it.
#
# The fixture is deliberately one that would otherwise *succeed*: an active
# profile for the target SSID, so the run logs "Wifi Good" the moment the check
# stops refusing. Without that it recorded FAIL either way and the assertion
# could not tell the check from its absence.
d="$(new_case)"; printf 'WIFI_SSID="MyNet"\n' > "$d/config.env"
: > "$d/nmcli-args"
NM_ACTIVE_PROFILE="MyNet" NM_PROFILES="MyNet|MyNet" NM_ARGS_LOG="$d/nmcli-args" \
    run_reconnect "$d" --help
assert_eq "an argument is refused" "1" "$RC_STATUS"
assert_contains "and the refusal names it" "takes no arguments; got: '--help'" "$RC_OUT"
assert_eq "and the refusal is logged like any other setup error" "FAIL" "$RC_LOG"
assert_eq "and no nmcli call is made" "" "$(cat "$d/nmcli-args")"

# Refused through die(), so this path still appends exactly one line -- the rule
# every other exit in that script keeps. A usage exit that logged nothing would
# have been the first exception to it, which is why there is no --help of its
# own and the message carries the guidance instead.
assert_contains "and the message says where the settings actually live" \
    "RECONNECT_* environment variables" "$RC_OUT"

d="$(new_case)"; printf 'WIFI_SSID="MyNet"\n' > "$d/config.env"
NM_ACTIVE_PROFILE="MyNet" NM_PROFILES="MyNet|MyNet" run_reconnect "$d" -x extra
assert_eq "any argument at all is refused, not just a flag" "1" "$RC_STATUS"
assert_contains "and the first one is the one reported" "got: '-x'" "$RC_OUT"

# An *empty* argument is still an argument. This script tests `$#`, so it always
# saw one -- but the refusal interpolated it unquoted and came out as
# `got: . There is nothing to pass`, a message whose subject is invisible. That
# is the shape the WIFI_HIDDEN check was quoted to eliminate, and it is how
# `./reconnect.sh "$flag"` reads when $flag is unset. The assertion is on the
# quotes rather than on the refusal, because the refusal was never the part that
# was broken here.
d="$(new_case)"; printf 'WIFI_SSID="MyNet"\n' > "$d/config.env"
NM_ACTIVE_PROFILE="MyNet" NM_PROFILES="MyNet|MyNet" run_reconnect "$d" ""
assert_eq "an empty argument is refused too" "1" "$RC_STATUS"
assert_contains "and the quotes make the empty value visible" "got: ''" "$RC_OUT"
assert_eq "and it is logged like any other setup error" "FAIL" "$RC_LOG"

# The same for a blanks-only one, which unquoted looked like a sentence that had
# simply stopped.
d="$(new_case)"; printf 'WIFI_SSID="MyNet"\n' > "$d/config.env"
NM_ACTIVE_PROFILE="MyNet" NM_PROFILES="MyNet|MyNet" run_reconnect "$d" "  "
assert_contains "a blanks-only argument is shown between quotes" "got: '  '" "$RC_OUT"

# The control: no arguments is still the ordinary case and must be untouched.
d="$(new_case)"; printf 'WIFI_SSID="MyNet"\n' > "$d/config.env"
NM_ACTIVE_PROFILE="MyNet" NM_PROFILES="MyNet|MyNet" run_reconnect "$d"
assert_eq "a run with no arguments is unaffected" "Wifi Good" "$RC_LOG"
assert_eq "and exits 0" "0" "$RC_STATUS"

# =============================================================================
section "the suite's own arguments"
# =============================================================================
# This file is linted and run in CI alongside the four scripts it tests, so its
# argument handling is held to the same rule -- and it had the exact defect
# install-cron.sh was changed to remove. It inspected `${1:-}` and never `$#`, so
# an unrecognised argument was refused when it came first and ignored in silence
# when it did not: `--bogus` exited 2, `-v --bogus` ran the whole suite and
# exited 0. `${1:-}` also made an empty argument indistinguishable from none.
#
# Every child here carries IR_ARGV_PROBE, which makes it print what its parser
# decided and stop before it builds anything -- see the guard at the top of this
# file for why that is not optional. The probe line is the observable: present
# means the arguments were accepted, absent with status 2 means they were
# refused. Asserting on the status alone would not do, because a parser that
# refused *everything* would satisfy all four refusals below; the two controls at
# the end are what separate the two.
SUITE="$SUITE_DIR/run-tests.sh"
probe_suite() {
    suite_out="$(IR_ARGV_PROBE=1 bash "$SUITE" "$@" 2>&1)"
    suite_status=$?
}

probe_suite -v --bogus
assert_eq "a stray argument after -v is refused rather than ignored" "2" "$suite_status"
assert_contains "and the usage line says what is accepted" "usage: run-tests.sh" "$suite_out"
assert_not_contains "and the arguments are not accepted" "argv-probe: accepted" "$suite_out"

probe_suite --bogus
assert_eq "an unknown argument on its own is still refused" "2" "$suite_status"

probe_suite ""
assert_eq "an empty argument is refused, not read as no argument" "2" "$suite_status"
assert_contains "and says what is accepted" "usage: run-tests.sh" "$suite_out"
assert_not_contains "and is not accepted" "argv-probe: accepted" "$suite_out"

probe_suite -v extra
assert_eq "a second argument is refused even when both are plausible" "2" "$suite_status"

# The controls. Without these every assertion above would pass against a parser
# that rejected its own documented flag, which is the other way this can break.
#
# An accepted probe exits 3, not 0: a probe runs no test, and an exported
# IR_ARGV_PROBE used to turn a plain `./tests/run-tests.sh` into exit 0 with
# nothing tested. The status is asserted exactly, so a probe that went back to
# reporting success would fail here.
probe_suite -v
assert_eq "-v on its own is still accepted, with the probe's own status" "3" "$suite_status"
assert_contains "and still turns verbose on" "argv-probe: accepted, VERBOSE=1" "$suite_out"

probe_suite
assert_eq "and no argument at all is still accepted" "3" "$suite_status"
assert_contains "with verbose left off" "argv-probe: accepted, VERBOSE=0" "$suite_out"
assert_contains "and the probe says no test was run" "no tests were run" "$suite_out"

# =============================================================================
section "the suite's own environment"
# =============================================================================
# The settings the scripts under test read from the environment are cleared at
# the top of this file. They used to be inherited, and the cases that test the
# defaults then ran on whatever the caller had exported: with RECONNECT_CONFIG
# and RECONNECT_LOG_DIR exported, a run wrote fixture answers over the real
# config and purged the real daily logs.
#
# A child is given every name on the list, and IR_ARGV_PROBE makes it report
# which ones are still set once the clearing block has run, then stop before it
# builds anything. A full nested run cannot be the observable: it would reach
# this section again and recurse, which is why IR_ARGV_PROBE exists.
leak_env=()
# shellcheck disable=SC2086
for leak_var in $SUITE_ENV_CLEARED; do
    leak_env+=("$leak_var=$TMP/leaked-$leak_var")
done
probe_suite_env_out="$(env "${leak_env[@]}" IR_ARGV_PROBE=1 bash "$SUITE" 2>&1)"
assert_eq "an exported setting does not survive into the suite" \
    "env-probe: still set: none" \
    "$(printf '%s\n' "$probe_suite_env_out" | grep '^env-probe:')"

# The controls. The check above would pass just as well against an empty list,
# so the list must name the two settings that send writes and deletions outside
# the suite's temporary directory.
assert_contains "and the list names RECONNECT_CONFIG" "RECONNECT_CONFIG" "$SUITE_ENV_CLEARED"
assert_contains "and RECONNECT_LOG_DIR" "RECONNECT_LOG_DIR" "$SUITE_ENV_CLEARED"
# ... and this file's own knobs. The probe above exports only what is on the
# list, so a knob dropped from it would pass that check untested; these names
# are what run_reconnect() and the race stand-ins read with no fixture setting
# them, and `RETENTION=abc` exported in the caller's shell turned 57 assertions
# red before they were cleared. Matched as whole words, so RETENTION cannot be
# satisfied by RECONNECT_LOG_RETENTION_DAYS.
for own_knob in SCAN_WAIT ATTEMPTS NMCLI_WAIT RETENTION \
    RACE_LOG_DIR RACE_REAL_NMCLI RACE_CHMOD_LOG; do
    case " ${SUITE_ENV_CLEARED//$'\n'/ } " in
        *" $own_knob "*) ok "and the list names the suite's own $own_knob" ;;
        *) no "and the list names the suite's own $own_knob" "missing from SUITE_ENV_CLEARED" ;;
    esac
done

# =============================================================================
section "exit status"
# =============================================================================
# Anything driving this from a script -- a systemd unit, a wrapper, a monitoring
# check -- keys off the exit status rather than the log, so it is part of the
# contract and not an implementation detail.

d="$(new_case)"; printf 'WIFI_SSID="MyNet"\n' > "$d/config.env"
NM_ACTIVE_PROFILE="MyNet" NM_PROFILES="MyNet|MyNet" run_reconnect "$d"
assert_eq "already connected exits 0" "0" "$RC_STATUS"

d="$(new_case)"
printf 'WIFI_SSID="MyNet"\nWIFI_PASSWORD="pw"\n' > "$d/config.env"
NM_ACTIVE_PROFILE="Other" NM_PROFILES="MyNet|MyNet" NM_SCAN="MyNet" run_reconnect "$d"
assert_eq "a successful reconnect exits 0" "0" "$RC_STATUS"

d="$(new_case)"
printf 'WIFI_SSID="MyNet"\nWIFI_PASSWORD="pw"\n' > "$d/config.env"
NM_ACTIVE_PROFILE="Other" NM_PROFILES="" NM_SCAN="MyNet" NM_CONNECT_RC=1 run_reconnect "$d"
assert_eq "a failed connect exits 1" "1" "$RC_STATUS"

d="$(new_case)"
run_reconnect "$d"
assert_eq "a setup error exits 1" "1" "$RC_STATUS"

# A day file the run cannot append to. status() treats that as a warning and
# carries on, which is documented -- but the printf's redirections were in the
# order `>> file 2>/dev/null`, and bash applies them left to right, so the
# failed open was reported by bash itself (`reconnect.sh: line NNN: ...:
# Permission denied`) before stderr had been silenced, ahead of the WARNING
# that states the reason. auto-setup.sh's config write and this suite's nmcli
# stub already order theirs the other way for exactly that reason.
#
# Self-skips where the filesystem does not enforce the mode, like the
# unreadable-config case: there the fixture is simply writable.
d="$(new_case)"; printf 'WIFI_SSID="MyNet"\n' > "$d/config.env"
today_log="$d/logs/$(date '+%Y-%m-%d').log"
printf '[00:00:00] Wifi Good\n' > "$today_log"
chmod 444 "$today_log" 2>/dev/null
if [ -w "$today_log" ]; then
    printf '  skip unwritable-log-file test: this filesystem does not enforce the mode\n'
else
    NM_ACTIVE_PROFILE="MyNet" NM_PROFILES="MyNet|MyNet" run_reconnect "$d"
    assert_eq "a day file that cannot be appended to does not fail the run" "0" "$RC_STATUS"
    assert_contains "and the run says why nothing was recorded" \
        "WARNING: cannot write to log directory" "$RC_OUT"
    assert_not_contains "without bash's own redirect diagnostic getting there first" \
        "Permission denied" "$RC_OUT"
    assert_not_contains "or naming a line number nobody asked about" \
        "reconnect.sh: line" "$RC_OUT"
fi
chmod 644 "$today_log" 2>/dev/null

# =============================================================================
section "one run at a time"
# =============================================================================
# "Skipped (already running)" is one of the four documented outcomes and was the
# only one with no coverage at all. It is worth having: reading a day's log back
# relies on every run appending exactly one line, so a run that stepped aside
# silently would be indistinguishable from cron never having fired -- the more
# alarming of the two explanations, and the reason the skip is logged rather
# than exited quietly.

if ! command -v flock >/dev/null 2>&1; then
    printf '  skip overlap tests: this system has no flock\n'
else
    d="$(new_case)"
    printf 'WIFI_SSID="MyNet"\n' > "$d/config.env"
    touch "$d/logs/.lock"

    # Hold the lock the way a still-running instance would. reconnect.sh opens
    # its own descriptor on the same file, which is a separate open file
    # description, so its flock contends with this one exactly as a second cron
    # run's would.
    exec 8>>"$d/logs/.lock"
    if flock -n 8; then
        NM_ACTIVE_PROFILE="MyNet" NM_PROFILES="MyNet|MyNet" run_reconnect "$d"
        assert_eq "an overlapping run logs that it stepped aside" \
            "Skipped (already running)" "$RC_LOG"
        assert_eq "an overlapping run exits 0 rather than failing" "0" "$RC_STATUS"
        exec 8>&-

        # With the lock released the same fixture connects normally. Without
        # this the assertions above would still pass if the run had failed for
        # some unrelated reason and never reached the lock at all.
        NM_ACTIVE_PROFILE="MyNet" NM_PROFILES="MyNet|MyNet" run_reconnect "$d"
        assert_eq "the next run proceeds once the lock is free" "Wifi Good" "$RC_LOG"

        # The lock descriptor must not reach nmcli. An open descriptor is
        # inherited by every child unless it is closed for that child, so a
        # process that outlived the run would go on holding the lock -- and
        # every run after it would log "Skipped (already running)" for as long
        # as that lasted, with nothing saying why. reconnect.sh puts `9>&-` on
        # each nmcli call through run_nmcli(); this is what would notice if a
        # call were ever added that bypassed it.
        : > "$d/fd-probe"
        NM_ACTIVE_PROFILE="MyNet" NM_PROFILES="MyNet|MyNet" \
            NM_FD_PROBE="$d/fd-probe" run_reconnect "$d"
        assert_eq "the run still succeeds with the probe in place" "Wifi Good" "$RC_LOG"
        assert_eq "nmcli does not inherit the lock descriptor" "" "$(cat "$d/fd-probe")"
    else
        exec 8>&-
        printf '  skip overlap tests: could not take the lock\n'
    fi
fi

# A lock path that cannot be opened is treated like a missing flock: the lock is
# skipped and the run still records its one line. `touch` succeeds on a
# directory, so a `.lock` that was one got past the guard and `exec 9>>` failed
# under `set -e` -- exit 1, "Is a directory", and no log line at all.
#
# The failure is at the `exec`, before flock is ever invoked, so a stub flock
# that always grants the lock is enough to reach it and lets this run on every
# host, including the ones the overlap tests above skip on.
fakeflock_bin="$TMP/fake-flock"
mkdir -p "$fakeflock_bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$fakeflock_bin/flock"
chmod +x "$fakeflock_bin/flock"
d="$(new_case)"; printf 'WIFI_SSID="MyNet"\n' > "$d/config.env"
mkdir -p "$d/logs/.lock"
PATH="$fakeflock_bin:$PATH" NM_ACTIVE_PROFILE="MyNet" NM_PROFILES="MyNet|MyNet" \
    run_reconnect "$d"
assert_eq "a lock path that is a directory does not end the run" "0" "$RC_STATUS"
assert_eq "and the run still logs its outcome" "Wifi Good" "$RC_LOG"
assert_not_contains "with no bash redirect diagnostic" "Is a directory" "$RC_OUT"

# The control: the same stub with an ordinary lock path takes the lock path
# normally, so the case above is not passing because the lock block is dead.
d="$(new_case)"; printf 'WIFI_SSID="MyNet"\n' > "$d/config.env"
PATH="$fakeflock_bin:$PATH" NM_ACTIVE_PROFILE="MyNet" NM_PROFILES="MyNet|MyNet" \
    run_reconnect "$d"
assert_eq "an ordinary lock path still works with flock present" "Wifi Good" "$RC_LOG"
assert_exists "and the lock file is created" "$d/logs/.lock"

# A flock that is present but cannot take the lock. util-linux flock exits 1
# only for a conflict; a filesystem with no lock support (ENOLCK, an NFS mount
# without lockd) gives 71, and other errors 65. Any non-zero status used to be
# read as "another run holds it", so every run on such a filesystem logged
# "Skipped (already running)", exited 0 and never consulted nmcli. The stand-in
# prints what flock prints there and exits 71, and the fixture is one that would
# be "Wifi Good", so the outcome line separates the two readings.
errflock_bin="$TMP/err-flock"
mkdir -p "$errflock_bin"
printf '#!/usr/bin/env bash\necho "flock: 9: No locks available" >&2\nexit 71\n' \
    > "$errflock_bin/flock"
chmod +x "$errflock_bin/flock"
d="$(new_case)"; printf 'WIFI_SSID="MyNet"\n' > "$d/config.env"
: > "$d/nmcli-args"
PATH="$errflock_bin:$PATH" NM_ACTIVE_PROFILE="MyNet" NM_PROFILES="MyNet|MyNet" \
    NM_ARGS_LOG="$d/nmcli-args" run_reconnect "$d"
assert_eq "a flock that cannot lock does not make the run step aside" "Wifi Good" "$RC_LOG"
assert_eq "and the run exits 0 on its real outcome" "0" "$RC_STATUS"
assert_contains "and says it went on without the lock" \
    "running without the overlap lock" "$RC_OUT"
assert_not_contains "rather than claiming another run is in progress" \
    "still in progress" "$RC_OUT"
assert_contains "and nmcli is actually consulted" \
    "connection show --active" "$(cat "$d/nmcli-args")"

# The control: exit 1 is the conflict status and must still step aside, or the
# case above would pass against a script that had stopped honouring the lock.
# A stub, so this runs where the real-flock overlap tests above self-skip.
conflictflock_bin="$TMP/conflict-flock"
mkdir -p "$conflictflock_bin"
printf '#!/usr/bin/env bash\nexit 1\n' > "$conflictflock_bin/flock"
chmod +x "$conflictflock_bin/flock"
d="$(new_case)"; printf 'WIFI_SSID="MyNet"\n' > "$d/config.env"
: > "$d/nmcli-args"
PATH="$conflictflock_bin:$PATH" NM_ACTIVE_PROFILE="MyNet" NM_PROFILES="MyNet|MyNet" \
    NM_ARGS_LOG="$d/nmcli-args" run_reconnect "$d"
assert_eq "a flock conflict still steps aside" "Skipped (already running)" "$RC_LOG"
assert_eq "and touches no nmcli" "" "$(cat "$d/nmcli-args")"
assert_not_contains "and is not reported as a lock that could not be taken" \
    "running without the overlap lock" "$RC_OUT"

# =============================================================================
section "log pruning"
# =============================================================================

d="$(new_case)"
printf 'WIFI_SSID="MyNet"\n' > "$d/config.env"
old="$(date -d '400 days ago' '+%Y-%m-%d' 2>/dev/null)"
if [ -z "$old" ]; then
    printf '  skip pruning tests: this system has no GNU date -d\n'
else
    recent="$(date -d '2 days ago' '+%Y-%m-%d')"
    # `0000-archive.log` is the fixture that makes the name check load-bearing:
    # it sorts *before* any real cutoff, so it would be deleted by the date
    # comparison alone and only the "is this name a date?" test saves it. Without
    # it the suite passed even with that test removed, because every other
    # non-dated fixture happened to sort after the cutoff anyway.
    touch "$d/logs/$old.log" "$d/logs/$recent.log" \
          "$d/logs/notes.log" "$d/logs/keepme.txt" \
          "$d/logs/0000-archive.log" "$d/logs/2026-13-99.log"
    NM_ACTIVE_PROFILE="MyNet" NM_PROFILES="MyNet|MyNet" RETENTION=30 run_reconnect "$d"
    assert_missing "a log older than the retention window is deleted" "$d/logs/$old.log"
    assert_exists "a log inside the retention window is kept" "$d/logs/$recent.log"
    assert_exists "a .log file that is not a date is never touched" "$d/logs/notes.log"
    assert_exists "a non-dated .log sorting before the cutoff is still never touched" "$d/logs/0000-archive.log"
    assert_exists "a non-log file is never touched" "$d/logs/keepme.txt"
    # Documents the known limitation: the filter checks the shape of the name,
    # not that it is a real date, and an impossible date sorts after any cutoff.
    assert_exists "a date-shaped but impossible name is left alone (known limitation)" "$d/logs/2026-13-99.log"

    # Retention 0 means "keep everything".
    d="$(new_case)"
    printf 'WIFI_SSID="MyNet"\n' > "$d/config.env"
    touch "$d/logs/$old.log"
    NM_ACTIVE_PROFILE="MyNet" NM_PROFILES="MyNet|MyNet" RETENTION=0 run_reconnect "$d"
    assert_exists "retention 0 keeps every log" "$d/logs/$old.log"
fi

# =============================================================================
section "install-cron.sh"
# =============================================================================

# Each case gets its own checkout copy, so "belongs to this checkout" is a
# meaningful distinction and the paths differ between them.
#
# The copy reproduces the real layout, not a flat directory: reconnect.sh and
# auto-setup.sh at the root, the two cron scripts and config.env.example under
# manual-setup/. The scripts resolve each other by that shape -- the cron scripts
# find reconnect.sh one level up, auto-setup.sh finds the installer one level
# down -- so a flat copy would install a cron line pointing at a reconnect.sh
# that does not exist and every path assertion would measure the wrong thing.
# The helper below builds the same shape for the "other checkout" fixtures.
copy_checkout_into() {
    local dir="$1"
    mkdir -p "$dir/manual-setup"
    cp "$RECONNECT" "$AUTOSETUP" "$dir/"
    cp "$INSTALL" "$UNINSTALL" "$dir/manual-setup/"
    # config.env.example goes in too: auto-setup.sh names it in the message it
    # prints when there is no input left, and a checkout without it would make
    # that message point at a file that is not there.
    cp "$REPO_DIR/manual-setup/config.env.example" "$dir/manual-setup/" 2>/dev/null || true
    chmod +x "$dir"/*.sh "$dir/manual-setup"/*.sh
}
new_checkout() {
    local d="$1"
    copy_checkout_into "$d/co"
    printf '%s' "$d/co"
}

CRON_OUT=""
CRON_STATUS=0
run_install() {
    CRON_OUT="$("$@" 2>&1)"
    CRON_STATUS=$?
}

d="$(new_case)"; co="$(new_checkout "$d")"
export CRONTAB_FILE="$d/crontab.txt"
: > "$CRONTAB_FILE"

run_install bash "$co/manual-setup/install-cron.sh"
assert_eq "a fresh install succeeds" "0" "$CRON_STATUS"
assert_contains "the default interval is every 5 minutes" "*/5 * * * *" "$(cron_text)"
assert_eq "exactly one job is installed" "1" "$(cron_count 'InternetReconnector$')"

run_install bash "$co/manual-setup/install-cron.sh"
assert_eq "re-installing does not duplicate the job" "1" "$(cron_count 'InternetReconnector$')"

run_install env MINUTES=10 bash "$co/manual-setup/install-cron.sh"
assert_contains "MINUTES=10 is honoured" "*/10 * * * *" "$(cron_text)"

run_install bash "$co/manual-setup/install-cron.sh"
assert_contains "a plain re-install keeps the chosen interval" "*/10 * * * *" "$(cron_text)"

run_install env RECONNECT_SCAN_WAIT_SECS=5 bash "$co/manual-setup/install-cron.sh"
assert_contains "a RECONNECT_* setting is written onto the line" "RECONNECT_SCAN_WAIT_SECS='5'" "$(cron_text)"

run_install bash "$co/manual-setup/install-cron.sh"
assert_contains "the setting survives a plain re-install" "RECONNECT_SCAN_WAIT_SECS='5'" "$(cron_text)"
assert_contains "and so does the interval" "*/10 * * * *" "$(cron_text)"

run_install env MINUTES=7 bash "$co/manual-setup/install-cron.sh"
assert_eq "an interval that does not divide 60 is rejected" "1" "$CRON_STATUS"
assert_contains "the rejection explains why" "divide 60 evenly" "$CRON_OUT"

# A leading zero used to make bash read the value as octal: `08` is not valid
# octal, `$((60 % n))` failed, and because a failed expansion in a `case` word
# does not trip `set -e` the interval was installed unchecked and the script
# exited 0. It must be rejected like any other value that does not divide 60.
before="$(cron_text)"
run_install env MINUTES=08 bash "$co/manual-setup/install-cron.sh"
assert_eq "MINUTES=08 is rejected, not installed as octal" "1" "$CRON_STATUS"
assert_contains "MINUTES=08 is rejected for the stated reason" "divide 60 evenly" "$CRON_OUT"
assert_not_contains "no bash arithmetic error leaks out" "value too great for base" "$CRON_OUT"
assert_eq "MINUTES=08 changed nothing" "$before" "$(cron_text)"

# A leading zero on a value that *is* valid is normalised, so the crontab never
# carries `*/05`.
run_install env MINUTES=05 bash "$co/manual-setup/install-cron.sh"
assert_eq "MINUTES=05 is accepted" "0" "$CRON_STATUS"
assert_contains "MINUTES=05 is written as */5" "*/5 * * * *" "$(cron_text)"
assert_not_contains "and not as */05" "*/05" "$(cron_text)"

# Every RECONNECT_* value is single-quoted onto the cron line. Quoting only the
# ones containing a space left the rest to be split and interpreted by the shell
# cron runs the line with -- `/tmp/a;reboot` became a second cron command.
run_install env RECONNECT_LOG_DIR='/tmp/a;reboot' bash "$co/manual-setup/install-cron.sh"
assert_eq "a value with a shell metacharacter is accepted" "0" "$CRON_STATUS"
assert_contains "and is single-quoted onto the line" "RECONNECT_LOG_DIR='/tmp/a;reboot'" "$(cron_text)"
assert_not_contains "so it cannot become a second command" "RECONNECT_LOG_DIR=/tmp/a;reboot " "$(cron_text)"
assert_contains "the script still runs on that line" "reconnect.sh'" "$(cron_text)"

# ... and the value survives the round trip back off the installed line.
run_install bash "$co/manual-setup/install-cron.sh"
assert_contains "a quoted value is read back and rewritten intact" \
    "RECONNECT_LOG_DIR='/tmp/a;reboot'" "$(cron_text)"

# A single quote and a '%' still cannot be expressed at all, and are refused.
run_install env RECONNECT_LOG_DIR="/tmp/it's" bash "$co/manual-setup/install-cron.sh"
assert_eq "a value containing a single quote is refused" "1" "$CRON_STATUS"
run_install env RECONNECT_LOG_DIR='/tmp/100%' bash "$co/manual-setup/install-cron.sh"
assert_eq "a value containing '%' is refused" "1" "$CRON_STATUS"

# Put the case back on a plain interval and no overrides for what follows.
run_install bash "$co/manual-setup/install-cron.sh" --remove
: > "$CRONTAB_FILE"

# reconnect.sh rejects these values itself, but under cron its reason goes to
# /dev/null -- so a value it will reject has to be caught here, at the one moment
# somebody is looking. Otherwise the installer reports success and every run
# afterwards logs FAIL, explaining itself to nobody.
run_install env RECONNECT_CONNECT_ATTEMPTS=abc bash "$co/manual-setup/install-cron.sh"
assert_eq "a non-numeric RECONNECT_* value is rejected" "1" "$CRON_STATUS"
assert_contains "and the setting is named" "RECONNECT_CONNECT_ATTEMPTS" "$CRON_OUT"
assert_eq "and nothing is installed" "0" "$(cron_count 'InternetReconnector$')"

run_install env RECONNECT_CONNECT_ATTEMPTS=0 bash "$co/manual-setup/install-cron.sh"
assert_eq "zero connect attempts is rejected" "1" "$CRON_STATUS"

run_install env RECONNECT_SCAN_WAIT_SECS=-5 bash "$co/manual-setup/install-cron.sh"
assert_eq "a negative wait is rejected" "1" "$CRON_STATUS"

# Zero is a legitimate scan wait -- the bound is >= 0 here, not >= 1, and it
# must match what reconnect.sh accepts rather than being tightened by accident.
run_install env RECONNECT_SCAN_WAIT_SECS=0 bash "$co/manual-setup/install-cron.sh"
assert_eq "zero scan wait is accepted" "0" "$CRON_STATUS"
assert_contains "and is written onto the line" "RECONNECT_SCAN_WAIT_SECS='0'" "$(cron_text)"

# The other two numeric settings, which had no coverage on either side. The
# rules here deliberately mirror reconnect.sh's, so each bound is pinned on both
# sides of the pair -- a bound tightened or loosened here and not there would
# mean the installer accepting a value the scheduled job then refuses, which is
# precisely the silent-FAIL-every-interval outcome validating here exists to
# prevent.
#
# Each case pins the validation message rather than the setting name alone, and
# checks the crontab is untouched. A non-numeric nmcli wait would otherwise
# "pass" for the wrong reason if validate_setting stopped covering it: the value
# reaches the worst-case arithmetic at the end of the script, `10#abc` aborts
# under `set -e`, and the run exits 1 having already written the job out. Exit 1
# on its own cannot tell a refusal from a crash after the damage is done.
before="$(cron_text)"
run_install env RECONNECT_NMCLI_WAIT_SECS=abc bash "$co/manual-setup/install-cron.sh"
assert_eq "a non-numeric nmcli wait is rejected" "1" "$CRON_STATUS"
assert_contains "and is refused by name, not by a later arithmetic error" \
    "RECONNECT_NMCLI_WAIT_SECS must be" "$CRON_OUT"
assert_eq "and the crontab is left as it was" "$before" "$(cron_text)"

run_install env RECONNECT_NMCLI_WAIT_SECS=0 bash "$co/manual-setup/install-cron.sh"
assert_eq "a zero nmcli wait is rejected here too" "1" "$CRON_STATUS"
assert_eq "and still changes nothing" "$before" "$(cron_text)"

run_install env RECONNECT_LOG_RETENTION_DAYS=abc bash "$co/manual-setup/install-cron.sh"
assert_eq "a non-numeric log retention is rejected" "1" "$CRON_STATUS"
assert_contains "and that setting is refused by name too" \
    "RECONNECT_LOG_RETENTION_DAYS must be" "$CRON_OUT"
assert_eq "and it changes nothing either" "$before" "$(cron_text)"

# Zero is legitimate for retention -- it is the documented "keep every log"
# setting -- so the bound is >= 0 here, exactly as it is for the scan wait.
run_install env RECONNECT_LOG_RETENTION_DAYS=0 bash "$co/manual-setup/install-cron.sh"
assert_eq "zero log retention is accepted, since 0 disables pruning" "0" "$CRON_STATUS"
assert_contains "and is written onto the line" "RECONNECT_LOG_RETENTION_DAYS='0'" "$(cron_text)"

# A path setting is not a number and must not be checked as one.
run_install env RECONNECT_LOG_DIR="$d/logs" bash "$co/manual-setup/install-cron.sh"
assert_eq "a path setting is not treated as a number" "0" "$CRON_STATUS"

# The other half of the pair rule. Every numeric bound here is
# `[ "$((10#$value))" -ge N ]`, and bash arithmetic wraps in silence past
# intmax_t: 10#99999999999999999999 is 7766279631452241919, comfortably >= 1. So
# this value passed validation here and was written onto the cron line, while
# reconnect.sh's `test`-based bound refused it outright -- a clean install
# followed by FAIL every interval with the reason going to /dev/null, which is
# the exact outcome validating here exists to prevent, produced by the validation
# itself. Checking the two bounds agree is the point; checking only that some
# refusal happened would not have caught it, because none did.
before="$(cron_text)"
run_install env RECONNECT_CONNECT_ATTEMPTS=99999999999999999999 bash "$co/manual-setup/install-cron.sh"
assert_eq "an over-wide RECONNECT_* value is rejected here too" "1" "$CRON_STATUS"
assert_contains "and is refused by name, with the width stated" \
    "RECONNECT_CONNECT_ATTEMPTS must be a whole number >= 1, at most 18 digits" "$CRON_OUT"
assert_eq "and the crontab is left as it was" "$before" "$(cron_text)"

# Leading zeros are stripped before the width is measured on both sides, so a
# legal value spelled with a long run of them still installs -- and reconnect.sh
# still accepts what reaches the line.
run_install env RECONNECT_LOG_RETENTION_DAYS=0000000000000000000030 bash "$co/manual-setup/install-cron.sh"
assert_eq "leading zeros do not make a value too wide" "0" "$CRON_STATUS"
assert_contains "and the value reaches the line intact" \
    "RECONNECT_LOG_RETENTION_DAYS='0000000000000000000030'" "$(cron_text)"

# This script's half of the boundary; see the matching block in the environment
# override section for why the 20-digit case above is not enough. The value here
# is the one that actually matters: nineteen digits and still inside intmax_t, so
# the `[ "$((10#$value))" -ge "$min" ]` bound below accepts it on its own and
# fits_in_integer() is the only thing that can refuse it. With this script's copy
# widened to 19 it installed cleanly here and was refused by reconnect.sh, and
# the whole suite stayed green.
before="$(cron_text)"
run_install env RECONNECT_CONNECT_ATTEMPTS=9000000000000000000 bash "$co/manual-setup/install-cron.sh"
assert_eq "a 19-digit value is rejected here too, so the bound is not above 18" \
    "1" "$CRON_STATUS"
assert_contains "and by the width rule rather than by the range check" \
    "at most 18 digits" "$CRON_OUT"
assert_eq "and the crontab is left as it was" "$before" "$(cron_text)"

# The other edge, and it is not symmetry for its own sake: a bound tightened here
# and not in reconnect.sh is the same disagreement pointing the other way -- the
# installer refusing a value the scheduled job would have run perfectly well.
run_install env RECONNECT_CONNECT_ATTEMPTS=999999999999999999 bash "$co/manual-setup/install-cron.sh"
assert_eq "an 18-digit value still installs, so the bound is not below 18" \
    "0" "$CRON_STATUS"
assert_contains "and reaches the line intact" \
    "RECONNECT_CONNECT_ATTEMPTS='999999999999999999'" "$(cron_text)"

# Cleared rather than left: RECONNECT_* values are carried across a re-install, so
# an 18-digit attempts count would otherwise ride onto every line the cases below
# install and change what they are measuring.
run_install bash "$co/manual-setup/install-cron.sh" --remove
: > "$CRONTAB_FILE"

# The width test runs *before* the base-10 normalisation, so the value echoed back
# is the one that was typed. Normalising first reported
# "must be between 1 and 59; got: 7766279631452241919" -- a number appearing
# nowhere in the user's command, which is the message shape the blanks-only and
# WIFI_HIDDEN checks in reconnect.sh exist to eliminate.
run_install env MINUTES=99999999999999999999 bash "$co/manual-setup/install-cron.sh"
assert_eq "an over-wide MINUTES is rejected" "1" "$CRON_STATUS"
assert_contains "and echoes back what was actually typed" \
    "got: '99999999999999999999'" "$CRON_OUT"
assert_not_contains "not what bash arithmetic turned it into" \
    "7766279631452241919" "$CRON_OUT"

# The blanks-only spelling of the same setting, which is what the quotes above
# are for. `MINUTES="$n" ./install-cron.sh` with $n blank is how it arrives, and
# unquoted it produced `must be a whole number of minutes; got: ` -- a refusal
# naming nothing, the message shape reconnect.sh's WIFI_HIDDEN check was quoted
# to eliminate and which had been left in place at every numeric validation in
# both scripts. A tab is asserted separately because it is the worse of the two:
# it prints as alignment, so the message does not even look truncated.
before="$(cron_text)"
run_install env MINUTES="  " bash "$co/manual-setup/install-cron.sh"
assert_eq "a blanks-only MINUTES is rejected" "1" "$CRON_STATUS"
assert_contains "and the quotes make the blanks visible" "got: '  '" "$CRON_OUT"
assert_eq "and nothing is installed by it" "$before" "$(cron_text)"

run_install env MINUTES="$(printf '\t')" bash "$co/manual-setup/install-cron.sh"
assert_eq "a tab MINUTES is rejected too" "1" "$CRON_STATUS"
assert_contains "and is visible between quotes rather than printing as alignment" \
    "$(printf "got: '\t'")" "$CRON_OUT"

# The same rule at the other validation in this script. validate_setting() takes
# its value from the environment or from the installed cron line, and $3 names
# which -- but neither reading helps when the value itself is invisible.
run_install env RECONNECT_CONNECT_ATTEMPTS="  " bash "$co/manual-setup/install-cron.sh"
assert_eq "a blanks-only RECONNECT_* value is rejected" "1" "$CRON_STATUS"
assert_contains "and is quoted in the refusal too" \
    "RECONNECT_CONNECT_ATTEMPTS must be a whole number >= 1; got: '  '" "$CRON_OUT"
assert_eq "and it installs nothing either" "$before" "$(cron_text)"

# A value carried off the installed line is validated too, not trusted: the line
# has been sitting in a file the user can edit, and it is about to be written
# back. Same reasoning as re-validating the interval.
printf "*/5 * * * * PATH=/usr/bin RECONNECT_CONNECT_ATTEMPTS='nope' '%s' >/dev/null 2>&1 # InternetReconnector\n" \
    "$co/reconnect.sh" > "$CRONTAB_FILE"
run_install bash "$co/manual-setup/install-cron.sh"
assert_eq "a bad value already on the line is rejected too" "1" "$CRON_STATUS"
assert_contains "and is reported as coming from the line" \
    "installed cron line" "$CRON_OUT"

: > "$CRONTAB_FILE"
run_install bash "$co/manual-setup/install-cron.sh"

# --remove-dry-run prints the lines --remove would delete and nothing else, and
# writes nothing. uninstall-cron.sh --dry-run builds its prediction on it, so the
# output is asserted exactly: here the crontab is our one line.
before="$(cron_text)"
run_install bash "$co/manual-setup/install-cron.sh" --remove-dry-run
assert_eq "--remove-dry-run succeeds" "0" "$CRON_STATUS"
assert_eq "and prints exactly the line --remove would delete" "$before" "$CRON_OUT"
assert_eq "and changes nothing" "$before" "$(cron_text)"

run_install bash "$co/manual-setup/install-cron.sh" --help extra
assert_eq "--help with a stray argument is rejected" "1" "$CRON_STATUS"
assert_contains "the rejection says what was wrong" "too many arguments" "$CRON_OUT"

run_install bash "$co/manual-setup/install-cron.sh" --bogus
assert_eq "an unknown argument is rejected" "1" "$CRON_STATUS"
assert_contains "and is named, between quotes" "unknown argument: '--bogus'" "$CRON_OUT"

# An empty argument used to match the parser's `'')` arm -- `"${1:-}"` collapses
# "no argument" and "an empty argument" into the same empty string -- so
# `./install-cron.sh ""` installed the cron job and exited 0. That is the
# "silently installing the job in response to an argument" surprise the script's
# own comment gives as the reason its argument policy exists, arriving through
# the one spelling the policy could not see, and `./install-cron.sh "$mode"` with
# $mode unset is how a wrapper produces it. The other two scripts refuse the
# same input, so this was also the one argument the three disagreed about.
#
# The fixture starts from a *cleared* crontab and asserts nothing was installed,
# because exit 1 alone would not tell a refusal from a run that installed and
# then failed for some other reason.
before="$(cron_text)"
run_install bash "$co/manual-setup/install-cron.sh" ""
assert_eq "an empty argument is refused, not read as no argument" "1" "$CRON_STATUS"
assert_contains "and the quotes make the empty value visible" \
    "unknown argument: ''" "$CRON_OUT"
assert_eq "and no job is installed by it" "$before" "$(cron_text)"

# ... while a run with genuinely no argument still installs. Without this the
# assertions above would also pass if the parser had started refusing everything.
run_install bash "$co/manual-setup/install-cron.sh"
assert_eq "a run with no argument at all still installs" "0" "$CRON_STATUS"
assert_eq "and the job is there" "1" "$(cron_count 'InternetReconnector$')"

# A line break is the one character quoting gives no protection against: a
# crontab record ends at a newline whatever quotes it sits inside. Unchecked,
# RECONNECT_LOG_DIR=$'/tmp/ir\n*/1 * * * * some-command' was written out inside
# single quotes and produced three crontab lines -- a truncated assignment cron
# cannot parse, and the rest of the value standing on its own as a schedule cron
# will happily run -- while the installer exited 0 reporting success and its own
# job had stopped working.
d="$(new_case)"; co="$(new_checkout "$d")"
export CRONTAB_FILE="$d/crontab.txt"
printf '0 3 * * * /usr/bin/backup.sh\n' > "$CRONTAB_FILE"
before="$(cron_text)"

run_install env RECONNECT_LOG_DIR=$'/tmp/ir\n*/1 * * * * /usr/bin/id' bash "$co/manual-setup/install-cron.sh"
assert_eq "a value containing a newline is refused" "1" "$CRON_STATUS"
assert_contains "the refusal names the setting and the reason" \
    "RECONNECT_LOG_DIR contains a line break" "$CRON_OUT"
assert_eq "nothing is installed" "0" "$(cron_count 'InternetReconnector')"
assert_eq "and the user's unrelated entry is byte-for-byte unchanged" "$before" "$(cron_text)"

run_install env RECONNECT_CONFIG=$'/tmp/a\r/tmp/b' bash "$co/manual-setup/install-cron.sh"
assert_eq "a value containing a carriage return is refused too" "1" "$CRON_STATUS"
assert_eq "and still installs nothing" "0" "$(cron_count 'InternetReconnector')"

# Cron runs the job from the user's home directory, so a relative path in one of
# the two path settings means one thing where it is typed and another where the
# job runs. Worse, it walked straight past the "there is no config file yet"
# warning, which resolves the path against the installer's own directory: from
# inside the checkout `RECONNECT_CONFIG=config.env` found the file, said nothing,
# and installed a job that reads $HOME/config.env and logs FAIL every interval
# with the reason going to /dev/null -- the exact failure that warning exists to
# catch.
d="$(new_case)"; co="$(new_checkout "$d")"
export CRONTAB_FILE="$d/crontab.txt"
: > "$CRONTAB_FILE"
printf 'WIFI_SSID="MyNet"\n' > "$co/config.env"

run_install env RECONNECT_CONFIG=config.env bash "$co/manual-setup/install-cron.sh"
assert_eq "a relative RECONNECT_CONFIG is refused" "1" "$CRON_STATUS"
assert_contains "the refusal says an absolute path is needed" \
    "RECONNECT_CONFIG must be an absolute path" "$CRON_OUT"
assert_contains "and says why cron makes the difference" "home directory" "$CRON_OUT"
assert_eq "and nothing is installed" "0" "$(cron_count 'InternetReconnector')"

run_install env RECONNECT_LOG_DIR=mylogs bash "$co/manual-setup/install-cron.sh"
assert_eq "a relative RECONNECT_LOG_DIR is refused too" "1" "$CRON_STATUS"
assert_eq "and still installs nothing" "0" "$(cron_count 'InternetReconnector')"

# A blanks-only path is not empty, so it is not skipped as unset; it reaches
# this same refusal, and unquoted the refusal read `must be an absolute path;
# got:  . Cron runs ...` -- a message naming nothing, the shape every other
# refusal in the script had already been quoted to eliminate. This was the one
# left bare. `RECONNECT_CONFIG=" " ./install-cron.sh` is how it arrives; the
# tab spelling is the worse one, because it prints as alignment.
run_install env RECONNECT_CONFIG=" " bash "$co/manual-setup/install-cron.sh"
assert_eq "a blanks-only RECONNECT_CONFIG is refused" "1" "$CRON_STATUS"
assert_contains "and the quotes make the blanks visible" \
    "RECONNECT_CONFIG must be an absolute path; got: ' '" "$CRON_OUT"
assert_eq "and nothing is installed by it" "0" "$(cron_count 'InternetReconnector')"

run_install env RECONNECT_LOG_DIR="$(printf '\t')" bash "$co/manual-setup/install-cron.sh"
assert_eq "a tab RECONNECT_LOG_DIR is refused too" "1" "$CRON_STATUS"
assert_contains "and is visible between quotes rather than printing as alignment" \
    "$(printf "must be an absolute path; got: '\t'")" "$CRON_OUT"

run_install env RECONNECT_LOG_DIR="$d/logs" bash "$co/manual-setup/install-cron.sh"
assert_eq "an absolute path is still accepted" "0" "$CRON_STATUS"
assert_contains "and is written onto the line" "RECONNECT_LOG_DIR='$d/logs'" "$(cron_text)"

# A relative value that reached the line before this check existed is refused on
# the next re-install rather than written back out, and is named as coming from
# the line -- the same treatment a bad numeric value already gets, and for the
# same reason: the line has been sitting in a file the user can edit.
printf "*/5 * * * * PATH=/usr/bin RECONNECT_LOG_DIR='mylogs' '%s' >/dev/null 2>&1 # InternetReconnector\n" \
    "$co/reconnect.sh" > "$CRONTAB_FILE"
edited="$(cron_text)"
run_install bash "$co/manual-setup/install-cron.sh"
assert_eq "a relative value already on the line is refused too" "1" "$CRON_STATUS"
assert_contains "and is reported as coming from the line" "installed cron line" "$CRON_OUT"
assert_eq "and the line is left exactly as it was" "$edited" "$(cron_text)"

# The blanks-only spelling off the line, which is the one with nothing visible
# to correct: every re-install refused it and, unquoted, showed nothing.
printf "*/5 * * * * PATH=/usr/bin RECONNECT_LOG_DIR=' ' '%s' >/dev/null 2>&1 # InternetReconnector\n" \
    "$co/reconnect.sh" > "$CRONTAB_FILE"
edited="$(cron_text)"
run_install bash "$co/manual-setup/install-cron.sh"
assert_eq "a blanks-only value already on the line is refused" "1" "$CRON_STATUS"
assert_contains "and the quotes show what is on the line" \
    "on the installed cron line must be an absolute path; got: ' '" "$CRON_OUT"
assert_eq "and that line is left as it was too" "$edited" "$(cron_text)"

# The "no config file yet" note checked existence and nothing else, while
# reconnect.sh also refuses a config that is not a regular file or cannot be
# read -- the same FAIL every interval with the reason going to /dev/null. A
# RECONNECT_CONFIG naming the directory instead of the file installed with exit
# 0 and not a word. It is a note, not a refusal, as the missing-file one is, so
# the assertions are on the note and on the job still being installed.
d="$(new_case)"; co="$(new_checkout "$d")"
export CRONTAB_FILE="$d/crontab.txt"; : > "$CRONTAB_FILE"
mkdir -p "$d/etc-ir"
run_install env RECONNECT_CONFIG="$d/etc-ir" bash "$co/manual-setup/install-cron.sh"
assert_eq "a config path that is a directory still installs" "0" "$CRON_STATUS"
assert_contains "but says every run will fail on it" \
    "$d/etc-ir is not a regular file" "$CRON_OUT"
assert_not_contains "rather than calling it missing" \
    "there is no config file at" "$CRON_OUT"
assert_eq "and the job is installed" "1" "$(cron_count 'InternetReconnector$')"

# Unreadable by the user the job runs as. Self-skips where the filesystem does
# not enforce the mode, like the unreadable-config case in the reconnect.sh
# section.
: > "$CRONTAB_FILE"
printf 'WIFI_SSID="MyNet"\n' > "$d/unreadable.env"
chmod 000 "$d/unreadable.env" 2>/dev/null
if [ -r "$d/unreadable.env" ]; then
    printf '  skip unreadable-config install note test: this filesystem does not enforce the mode\n'
else
    run_install env RECONNECT_CONFIG="$d/unreadable.env" bash "$co/manual-setup/install-cron.sh"
    assert_eq "an unreadable config path still installs" "0" "$CRON_STATUS"
    assert_contains "but says it cannot be read" \
        "$d/unreadable.env cannot be read by you" "$CRON_OUT"
fi
chmod 600 "$d/unreadable.env" 2>/dev/null

# The controls: a missing config still gets its own note, and a readable regular
# one gets none of the three.
: > "$CRONTAB_FILE"
run_install env RECONNECT_CONFIG="$d/missing.env" bash "$co/manual-setup/install-cron.sh"
assert_contains "a missing config still gets the missing-file note" \
    "there is no config file at $d/missing.env" "$CRON_OUT"
: > "$CRONTAB_FILE"
run_install env RECONNECT_CONFIG="$d/unreadable.env" bash "$co/manual-setup/install-cron.sh"
assert_not_contains "and a readable config file gets no config note" \
    "NOTE: $d/unreadable.env" "$CRON_OUT"
assert_not_contains "nor the missing-file one" "there is no config file" "$CRON_OUT"

# The log directory gets the same treatment. reconnect.sh creates it on demand,
# but one it can never create or write is only a warning there, and under cron
# the warning goes to /dev/null -- so this script installed, with exit 0 and
# "Logs go to:" naming that directory, a job that never wrote a line. A note, as
# for the config, so the assertions are on the note and on the job being there.
# The ancestor-that-is-a-file case runs on every filesystem; the unwritable
# directory and the unwritable day file self-skip where modes are not enforced.
: > "$CRONTAB_FILE"
printf 'not a directory\n' > "$d/afile"
run_install env RECONNECT_LOG_DIR="$d/afile/logs" bash "$co/manual-setup/install-cron.sh"
assert_eq "a log directory under a file still installs" "0" "$CRON_STATUS"
assert_eq "and the job is there" "1" "$(cron_count 'InternetReconnector$')"
assert_contains "but says the job cannot log there" \
    "NOTE: the job cannot log to $d/afile/logs" "$CRON_OUT"
assert_contains "naming what is in the way" "$d/afile exists and is not a directory" "$CRON_OUT"

mkdir -p "$d/ro-logs"
chmod 555 "$d/ro-logs" 2>/dev/null
if [ -w "$d/ro-logs" ]; then
    printf '  skip unwritable-log-dir install note test: this filesystem does not enforce the mode\n'
else
    : > "$CRONTAB_FILE"
    run_install env RECONNECT_LOG_DIR="$d/ro-logs" bash "$co/manual-setup/install-cron.sh"
    assert_contains "an existing log directory that cannot be written is noted" \
        "$d/ro-logs is not writable" "$CRON_OUT"
fi
chmod 755 "$d/ro-logs" 2>/dev/null

mkdir -p "$d/day-logs"
day_log="$d/day-logs/$(date '+%Y-%m-%d').log"
: > "$day_log"
chmod 444 "$day_log" 2>/dev/null
if [ -w "$day_log" ]; then
    printf '  skip unwritable-day-log install note test: this filesystem does not enforce the mode\n'
else
    : > "$CRONTAB_FILE"
    run_install env RECONNECT_LOG_DIR="$d/day-logs" bash "$co/manual-setup/install-cron.sh"
    assert_contains "and so is today's log file when it cannot be appended to" \
        "today's log file $day_log cannot be written to" "$CRON_OUT"
fi
chmod 644 "$day_log" 2>/dev/null

# The control: a directory that does not exist yet under a writable parent is
# what reconnect.sh creates on demand, so it gets no note -- or the note would
# be "the directory must exist", which is not the rule.
: > "$CRONTAB_FILE"
run_install env RECONNECT_LOG_DIR="$d/fresh-logs" bash "$co/manual-setup/install-cron.sh"
assert_eq "a log directory that does not exist yet installs" "0" "$CRON_STATUS"
assert_not_contains "with no log note" "cannot log to" "$CRON_OUT"

# One trailing blank after the marker used to hide the line from ours(),
# our_line() and foreign_lines() all at once, so a re-install neither replaced it
# nor warned about it -- it appended a second job, and the two then ran alongside
# each other every interval. That is the opposite of the idempotence the README
# promises, and it was completely silent.
d="$(new_case)"; co="$(new_checkout "$d")"
export CRONTAB_FILE="$d/crontab.txt"
: > "$CRONTAB_FILE"
run_install bash "$co/manual-setup/install-cron.sh"
sed 's/\(# InternetReconnector\)$/\1 /' "$CRONTAB_FILE" > "$CRONTAB_FILE.edited"
mv "$CRONTAB_FILE.edited" "$CRONTAB_FILE"
assert_eq "the fixture really does carry a trailing blank" \
    "1" "$(grep -c 'InternetReconnector $' "$CRONTAB_FILE")"

run_install bash "$co/manual-setup/install-cron.sh"
assert_eq "a re-install over a trailing blank succeeds" "0" "$CRON_STATUS"
assert_eq "and does not duplicate the job" "1" "$(cron_count 'InternetReconnector')"
assert_not_contains "the line is claimed, not treated as another checkout's" \
    "different copy of" "$CRON_OUT"

# Same fixture, but removed rather than re-installed.
sed 's/\(# InternetReconnector\)$/\1 /' "$CRONTAB_FILE" > "$CRONTAB_FILE.edited"
mv "$CRONTAB_FILE.edited" "$CRONTAB_FILE"
run_install bash "$co/manual-setup/install-cron.sh" --remove
assert_eq "--remove recognises a line with a trailing blank" \
    "0" "$(cron_count 'InternetReconnector')"

# Text added *after* the marker. That line is deliberately not claimed -- a
# command of the user's own can mention the marker mid-line, and deletion must
# never take a line it cannot be sure it wrote -- but it used to be neither ours
# nor foreign, so a re-install appended a second job beside it without a word and
# the two ran every interval. It is reported now, on install and on --remove.
d="$(new_case)"; co="$(new_checkout "$d")"
export CRONTAB_FILE="$d/crontab.txt"
: > "$CRONTAB_FILE"
run_install bash "$co/manual-setup/install-cron.sh"
printf '%s # my note\n' "$(cron_text)" > "$CRONTAB_FILE"
edited="$(cron_text)"

run_install bash "$co/manual-setup/install-cron.sh"
assert_eq "a re-install over a line edited after the marker still succeeds" \
    "0" "$CRON_STATUS"
assert_contains "and says a line of this checkout's was left alone" \
    "were edited by hand" "$CRON_OUT"
assert_contains "and that the script now runs from both" \
    "now runs from both" "$CRON_OUT"
assert_contains "and the edited line is still there, untouched" "$edited" "$(cron_text)"

run_install bash "$co/manual-setup/install-cron.sh" --remove
assert_contains "--remove reports the edited line it leaves" \
    "were edited by hand" "$CRON_OUT"
assert_contains "and says it still runs" "It still runs" "$CRON_OUT"
assert_eq "while the job it wrote is removed and the edited line kept" \
    "$edited" "$(cron_text)"

# The control: an ordinary re-install says nothing of the kind.
: > "$CRONTAB_FILE"
run_install bash "$co/manual-setup/install-cron.sh"
run_install bash "$co/manual-setup/install-cron.sh"
assert_not_contains "a plain re-install reports no edited line" \
    "were edited by hand" "$CRON_OUT"

# The path put in double quotes by hand, the one spelling of this checkout's
# line that ours() does not accept and uninstall-cron.sh and auto-setup.sh do.
# install-cron.sh used to class it as another checkout's: the note called it "a
# different copy of reconnect.sh" and said to run --remove "from that copy",
# which is this copy and cannot remove it. It is reported as an edited line of
# this checkout's now, on install and on --remove, and still never claimed.
d="$(new_case)"; co="$(new_checkout "$d")"
export CRONTAB_FILE="$d/crontab.txt"
printf "*/10 * * * * PATH='/usr/bin' \"%s/reconnect.sh\" >/dev/null 2>&1 # InternetReconnector\n" \
    "$co" > "$CRONTAB_FILE"
dq_line="$(cron_text)"
run_install bash "$co/manual-setup/install-cron.sh"
assert_eq "a re-install over a double-quoted line of ours still succeeds" "0" "$CRON_STATUS"
assert_not_contains "and does not call this checkout's own line another copy's" \
    "different copy of" "$CRON_OUT"
assert_contains "but reports it as edited by hand" "were edited by hand" "$CRON_OUT"
assert_contains "and that the script now runs from both" "now runs from both" "$CRON_OUT"
assert_contains "and the double-quoted line is still there, untouched" "$dq_line" "$(cron_text)"

run_install bash "$co/manual-setup/install-cron.sh" --remove
assert_contains "--remove reports the double-quoted line it leaves" \
    "were edited by hand" "$CRON_OUT"
assert_not_contains "rather than sending you to remove it from another copy" \
    "from that copy" "$CRON_OUT"
assert_eq "and keeps it, as the only line left" "$dq_line" "$(cron_text)"

# The same tolerance at the other end of the line, which is a separate code path.
# marked() has always ignored leading blanks and previous_value() is not anchored
# to the front of the line either, so PATH and every RECONNECT_* value carried
# across a hand-indented line untouched -- previous_minutes() was the one test that
# did not, and the interval was therefore the single setting one stray leading
# space threw away. It reset to 5 in silence, on the re-install the README calls
# idempotent, which is precisely the surprise carrying the interval over exists to
# prevent. Deleting that strip left the whole suite green.
d="$(new_case)"; co="$(new_checkout "$d")"
export CRONTAB_FILE="$d/crontab.txt"
: > "$CRONTAB_FILE"
run_install env MINUTES=10 bash "$co/manual-setup/install-cron.sh"
assert_contains "the fixture starts on a 10-minute interval" "*/10 * * * *" "$(cron_text)"
printf ' %s\n' "$(cron_text)" > "$CRONTAB_FILE"
assert_eq "the fixture really does carry a leading blank" \
    "1" "$(grep -c '^ \*/10' "$CRONTAB_FILE")"

run_install bash "$co/manual-setup/install-cron.sh"
assert_eq "a re-install over an indented line succeeds" "0" "$CRON_STATUS"
assert_contains "and keeps the interval rather than resetting it to 5" \
    "*/10 * * * *" "$(cron_text)"
assert_eq "and does not duplicate the job" "1" "$(cron_count 'InternetReconnector')"

# The overlap warning is computed from the timeouts actually being installed.
# Hardcoding the ~140s the defaults produce was wrong in both directions, and the
# direction that mattered was staying silent: raising the timeouts gives a worst
# case well past the interval with no warning at all.
d="$(new_case)"; co="$(new_checkout "$d")"
export CRONTAB_FILE="$d/crontab.txt"

: > "$CRONTAB_FILE"
run_install env MINUTES=5 bash "$co/manual-setup/install-cron.sh"
assert_not_contains "the defaults at 5 minutes do not warn" \
    "a failing run can take" "$CRON_OUT"

# 15 + 3*2*20 + 2*2 = 139, which pins the formula rather than a round number.
: > "$CRONTAB_FILE"
run_install env MINUTES=1 bash "$co/manual-setup/install-cron.sh"
assert_contains "the defaults at 1 minute do warn" "a failing run can take" "$CRON_OUT"
assert_contains "and quote the default worst case" "~139s" "$CRON_OUT"

# 15 + 5*2*60 + 4*2 = 623, longer than the default 5-minute interval.
: > "$CRONTAB_FILE"
run_install env MINUTES=5 RECONNECT_NMCLI_WAIT_SECS=60 RECONNECT_CONNECT_ATTEMPTS=5 \
    bash "$co/manual-setup/install-cron.sh"
assert_contains "raised timeouts warn even at the default interval" "~623s" "$CRON_OUT"

# 0 + 1*2*1 + 0 = 2, comfortably inside a 1-minute interval.
: > "$CRONTAB_FILE"
run_install env MINUTES=1 RECONNECT_SCAN_WAIT_SECS=0 RECONNECT_CONNECT_ATTEMPTS=1 \
    RECONNECT_NMCLI_WAIT_SECS=1 bash "$co/manual-setup/install-cron.sh"
assert_not_contains "lowered timeouts do not warn at a 1-minute interval" \
    "a failing run can take" "$CRON_OUT"

# The width rule does not reach this calculation, and the calculation is where
# it mattered most. fits_in_integer() bounds each *value* at 18 digits, which is
# what bash can compare and count with -- but the worst case multiplies two of
# them, and a product passes intmax_t long before either operand does. Written
# as one unchecked expression, 5 attempts at an 18-digit nmcli wait came out as
# -8446744073709551603, the comparison was false, and the install printed no
# warning at all: silence for the configuration whose worst case is furthest
# past the interval there is. Every step is checked for overflow now.
#
# Both halves are asserted. The warning must fire, and it must not quote the
# wrapped figure as a number of seconds -- reporting "~5392445620511834125s" is
# the same defect wearing a plausible number, and a reader would take it for a
# real total the installed timeouts had produced.
: > "$CRONTAB_FILE"
run_install env MINUTES=1 RECONNECT_CONNECT_ATTEMPTS=5 \
    RECONNECT_NMCLI_WAIT_SECS=999999999999999999 bash "$co/manual-setup/install-cron.sh"
assert_eq "an overflowing worst case still installs" "0" "$CRON_STATUS"
assert_contains "and warns rather than going silent" "a failing run can take" "$CRON_OUT"
assert_contains "and says the figure will not fit rather than quoting one" \
    "longer than a 64-bit count of seconds" "$CRON_OUT"
assert_not_contains "with no wrapped negative in the message" "-8446744073709551603" "$CRON_OUT"
assert_not_contains "and no wrapped positive either" "5392445620511834125" "$CRON_OUT"

# The same values with both operands at 18 digits, which wrapped positive rather
# than negative and so warned all along -- with a number the timeouts cannot
# produce. This is the half that looked like it was working.
: > "$CRONTAB_FILE"
run_install env MINUTES=1 RECONNECT_CONNECT_ATTEMPTS=999999999999999999 \
    RECONNECT_NMCLI_WAIT_SECS=999999999999999999 bash "$co/manual-setup/install-cron.sh"
assert_contains "a positive wrap is reported as an overflow too" \
    "longer than a 64-bit count of seconds" "$CRON_OUT"
assert_not_contains "not as the figure bash wrapped to" "5392445620511834125" "$CRON_OUT"

# The control. A worst case that fits must still be quoted as a figure, or the
# assertions above would pass with the calculation replaced by the overflow
# branch outright. 15 + 3*2*20 + 2*2 = 139 again.
: > "$CRONTAB_FILE"
run_install env MINUTES=1 bash "$co/manual-setup/install-cron.sh"
assert_contains "a worst case that fits is still quoted in seconds" "~139s" "$CRON_OUT"
assert_not_contains "and is not reported as an overflow" \
    "longer than a 64-bit count of seconds" "$CRON_OUT"

# MINUTES is an install-time setting. Validating it on a removal refused to take
# a job back out over a value the removal never reads: an exported MINUTES=7 made
# --remove exit 1 and leave the job installed, and uninstall-cron.sh -- which
# shells out to the installer and passes its environment along -- failed the same
# way, reporting only that the removal had failed.
d="$(new_case)"; co="$(new_checkout "$d")"
export CRONTAB_FILE="$d/crontab.txt"
: > "$CRONTAB_FILE"

run_install bash "$co/manual-setup/install-cron.sh"
run_install env MINUTES=7 bash "$co/manual-setup/install-cron.sh" --remove
assert_eq "an invalid MINUTES does not block --remove" "0" "$CRON_STATUS"
assert_eq "and the job is actually gone" "0" "$(cron_count 'InternetReconnector')"

run_install bash "$co/manual-setup/install-cron.sh"
run_install env MINUTES=7 bash "$co/manual-setup/uninstall-cron.sh"
assert_eq "an invalid MINUTES does not block uninstall-cron.sh" "0" "$CRON_STATUS"
assert_eq "and that job is gone too" "0" "$(cron_count 'InternetReconnector')"

# Still rejected where it is actually used.
run_install env MINUTES=7 bash "$co/manual-setup/install-cron.sh"
assert_eq "an invalid MINUTES still blocks an install" "1" "$CRON_STATUS"
assert_contains "and still explains why" "divide 60 evenly" "$CRON_OUT"

# The same rule, applied to preflights rather than to a setting. `chmod` and
# `date` are install-only -- the first is used by the executable-bit loop, the
# second by the closing summary's example filename -- and `--remove` reaches
# neither. Checked unconditionally they refused to take a job back out over a
# tool the removal never touches, and because uninstall-cron.sh shells out to
# `install-cron.sh --remove` the whole uninstall failed with "the crontab was
# left as it was" and the job stayed scheduled. An uninstall must not be blocked
# by an install-time requirement, whichever form it takes.
#
# Three PATHs, not one. An earlier version of this block used a single PATH
# missing both commands and asserted only that the install exited 1 -- which
# either check on its own satisfies, so deleting `chmod`'s preflight left the
# suite green and deleting `date`'s left it green too. The property is
# per-command and the assertion was on the aggregate, which is a check at the
# wrong level of abstraction: it passed whether or not the thing it named was
# there. Each command now gets a PATH missing only itself, and the assertion is
# on the message naming that command rather than on the exit status.
#
# PATH is rebuilt from wrappers that exec the real binary by absolute path --
# the same trick the date-preflight and missing-nmcli tests use.
noinstall_ok=1
[ -n "$real_bash" ] || noinstall_ok=0
# $1 is the directory to build; every remaining argument is a tool to leave out.
build_path_without() {
    local dir="$1" tool real_tool skip excluded
    shift
    mkdir -p "$dir"
    for tool in bash cat rm mktemp grep awk chmod date; do
        skip=0
        for excluded in "$@"; do
            [ "$tool" != "$excluded" ] || skip=1
        done
        [ "$skip" -eq 0 ] || continue
        real_tool="$(command -v "$tool" || true)"
        [ -n "$real_tool" ] || return 1
        printf '#!%s\nexec %s "$@"\n' "$real_bash" "$real_tool" > "$dir/$tool"
        chmod +x "$dir/$tool"
    done
    cp "$STUB_BIN/crontab" "$dir/crontab" 2>/dev/null || return 1
    return 0
}

noinstall_bin="$TMP/no-install-only"
nochmod_bin="$TMP/no-chmod-only"
nodate_bin="$TMP/no-date-only"
if [ "$noinstall_ok" -eq 1 ]; then
    build_path_without "$noinstall_bin" chmod date || noinstall_ok=0
    build_path_without "$nochmod_bin" chmod || noinstall_ok=0
    build_path_without "$nodate_bin" date || noinstall_ok=0
fi

if [ "$noinstall_ok" -ne 1 ]; then
    printf '  skip install-only preflight test: could not build a PATH without chmod and date\n'
else
    d="$(new_case)"; co="$(new_checkout "$d")"
    export CRONTAB_FILE="$d/crontab.txt"
    : > "$CRONTAB_FILE"

    run_install bash "$co/manual-setup/install-cron.sh"
    assert_eq "the job is installed to begin with" "1" "$(cron_count 'InternetReconnector$')"

    run_install env PATH="$noinstall_bin" bash "$co/manual-setup/install-cron.sh" --remove
    assert_eq "a missing install-only tool does not block --remove" "0" "$CRON_STATUS"
    assert_eq "and the job is actually gone" "0" "$(cron_count 'InternetReconnector$')"

    # Re-asserted rather than assumed. Without this the two assertions below
    # would pass vacuously if the install had silently stopped working: an
    # uninstall with nothing to remove also exits 0 and also leaves no job.
    run_install bash "$co/manual-setup/install-cron.sh"
    assert_eq "the job is installed again for the uninstall case" \
        "1" "$(cron_count 'InternetReconnector$')"

    run_install env PATH="$noinstall_bin" bash "$co/manual-setup/uninstall-cron.sh"
    assert_eq "nor does it block uninstall-cron.sh" "0" "$CRON_STATUS"
    assert_eq "and that job is gone too" "0" "$(cron_count 'InternetReconnector$')"
    assert_not_contains "with no claim that the removal failed" \
        "--remove failed" "$CRON_OUT"

    # Install-only was not a narrow enough gate for `chmod`. The loop that sets
    # the executable bit runs `chmod` only for a script that is missing it, and
    # a checkout with its committed modes intact has none -- so on a machine
    # without `chmod` this refused an install that was never going to call it.
    # `new_checkout` chmods every script it copies, so this fixture is exactly
    # that ordinary case.
    : > "$CRONTAB_FILE"
    run_install env PATH="$nochmod_bin" bash "$co/manual-setup/install-cron.sh"
    assert_eq "an install whose scripts are already executable does not need chmod" \
        "0" "$CRON_STATUS"
    assert_eq "and the job is installed" "1" "$(cron_count 'InternetReconnector$')"
    assert_not_contains "with nothing said about chmod" "chmod not found" "$CRON_OUT"

    # Still required where it is actually used, so the gate narrows the check
    # rather than deleting it. One script has its bit taken away, which is what
    # a zip download or a filesystem with no execute bit leaves behind, and the
    # refusal must name both the command and the script it was wanted for.
    #
    # Skipped where the filesystem does not drop the bit -- Cygwin, some mounted
    # volumes, or a run as root -- because there the fixture is simply still
    # executable and the assertion would be about the platform rather than about
    # the code. Same reason the unreadable-config test self-skips.
    chmod -x "$co/manual-setup/uninstall-cron.sh" 2>/dev/null
    if [ -x "$co/manual-setup/uninstall-cron.sh" ]; then
        printf '  skip chmod-required test: this filesystem does not drop the execute bit\n'
        chmod +x "$co/manual-setup/uninstall-cron.sh" 2>/dev/null
    else
        # An install refused over a bad value must not have touched the
        # checkout first. The loop used to sit ahead of the RECONNECT_* and
        # CRON_PATH vetting, so this refusal arrived with the bit already set
        # -- a write to the user's checkout on a run that was about to abort,
        # which the loop's own comment says must not happen.
        : > "$CRONTAB_FILE"
        run_install env RECONNECT_CONNECT_ATTEMPTS=abc bash "$co/manual-setup/install-cron.sh"
        assert_eq "an install refused over a bad setting fails" "1" "$CRON_STATUS"
        if [ -x "$co/manual-setup/uninstall-cron.sh" ]; then
            no "and leaves the checkout's modes alone" "uninstall-cron.sh was made executable"
        else
            ok "and leaves the checkout's modes alone"
        fi
        assert_eq "and installs nothing" "0" "$(cron_count 'InternetReconnector$')"

        : > "$CRONTAB_FILE"
        run_install env PATH="$nochmod_bin" bash "$co/manual-setup/install-cron.sh"
        assert_eq "an install that must set a bit is still refused without chmod" \
            "1" "$CRON_STATUS"
        assert_contains "and says which command is missing" "chmod not found" "$CRON_OUT"
        assert_contains "and which script wanted it" \
            "uninstall-cron.sh is not executable" "$CRON_OUT"
        assert_eq "and installs nothing" "0" "$(cron_count 'InternetReconnector$')"

        # The control: with a real chmod on PATH the same fixture installs and
        # the bit is actually set. Without this the assertions above would also
        # pass if the loop had stopped running altogether.
        run_install bash "$co/manual-setup/install-cron.sh"
        assert_eq "the same install succeeds where chmod exists" "0" "$CRON_STATUS"
        if [ -x "$co/manual-setup/uninstall-cron.sh" ]; then
            ok "and the executable bit was actually restored"
        else
            no "and the executable bit was actually restored" "still not executable"
        fi
    fi

    : > "$CRONTAB_FILE"
    run_install env PATH="$nodate_bin" bash "$co/manual-setup/install-cron.sh"
    assert_eq "an install without date is still refused" "1" "$CRON_STATUS"
    assert_contains "and names date rather than chmod" "date not found" "$CRON_OUT"
    assert_eq "and installs nothing either" "0" "$(cron_count 'InternetReconnector$')"

    # `cat` was preflighted on every run and is used on neither of the two paths
    # an ordinary run takes: usage() reaches it (so --help, and an argument
    # error) and so does the line that passes crontab's diagnostic on after a
    # *failed* read. A plain install and a plain uninstall call it nowhere, and
    # both used to exit 1 with "cat not found" on a machine without it.
    #
    # The crontab stub is itself written in terms of `cat`, so it gets a wrapper
    # that puts a real one back on PATH for its own process only. That leaves
    # install-cron.sh running with no `cat` of its own, which is the condition
    # under test, while the fake crontab still works.
    nocat_bin="$TMP/no-cat-only"
    nocat_ok=1
    build_path_without "$nocat_bin" cat || nocat_ok=0
    real_cat="$(command -v cat || true)"
    if [ "$nocat_ok" -eq 1 ] && [ -n "$real_cat" ]; then
        # $PATH and $@ belong to the wrapper being written, not to this shell,
        # so the format string is single-quoted on purpose.
        # shellcheck disable=SC2016
        printf '#!%s\nPATH="%s:$PATH"\nexec %s "$@"\n' \
            "$real_bash" "$(dirname "$real_cat")" "$STUB_BIN/crontab" \
            > "$nocat_bin/crontab"
        chmod +x "$nocat_bin/crontab"
    else
        nocat_ok=0
    fi

    if [ "$nocat_ok" -ne 1 ]; then
        printf '  skip cat-preflight tests: could not build a PATH without cat\n'
    else
        d="$(new_case)"; co="$(new_checkout "$d")"
        export CRONTAB_FILE="$d/crontab.txt"
        : > "$CRONTAB_FILE"

        run_install env PATH="$nocat_bin" bash "$co/manual-setup/install-cron.sh"
        assert_eq "a plain install does not need cat" "0" "$CRON_STATUS"
        assert_eq "and the job is installed" "1" "$(cron_count 'InternetReconnector$')"
        assert_not_contains "with nothing said about cat" "cat not found" "$CRON_OUT"

        run_install env PATH="$nocat_bin" bash "$co/manual-setup/uninstall-cron.sh"
        assert_eq "a plain uninstall does not need cat either" "0" "$CRON_STATUS"
        assert_eq "and the job is gone" "0" "$(cron_count 'InternetReconnector$')"
        assert_not_contains "and still says nothing about cat" "cat not found" "$CRON_OUT"

        # Still required where it is used. usage() is a `cat` heredoc, and the
        # check has to sit ahead of that heredoc rather than after it: under
        # `set -e` a failed `cat` aborts before the `exit 0`, so --help would
        # print an empty screen and exit 1 saying nothing at all.
        run_install env PATH="$nocat_bin" bash "$co/manual-setup/install-cron.sh" --help
        assert_eq "--help without cat is refused rather than printing nothing" \
            "1" "$CRON_STATUS"
        assert_contains "and says which command is missing" "cat not found" "$CRON_OUT"

        run_install env PATH="$nocat_bin" bash "$co/manual-setup/uninstall-cron.sh" --help
        assert_eq "the same holds for uninstall-cron.sh --help" "1" "$CRON_STATUS"
        assert_contains "and it names cat too" "cat not found" "$CRON_OUT"

        # The control: with cat on PATH --help works and prints the usage text.
        run_install bash "$co/manual-setup/install-cron.sh" --help
        assert_eq "--help succeeds where cat exists" "0" "$CRON_STATUS"
        assert_contains "and prints the usage block" "Usage: install-cron.sh" "$CRON_OUT"
    fi

    # install-cron.sh no longer runs `grep` anywhere, so a missing one must not
    # stop it. It used to be preflighted on every run, and the path that shows
    # why that was wrong is `--remove` over a crontab holding no line of ours:
    # it reads with `crontab -l`, classifies with awk and writes nothing, so it
    # never reached a grep -- yet it exited 1 with "grep not found" where the
    # answer is "nothing to remove" and exit 0. A script driving the uninstall
    # could not tell that from a failed removal, which is the same distinction
    # uninstall-cron.sh's conditional mktemp, grep and rm checks preserve.
    #
    # The fresh-install case is here because it is the one that made a `command
    # -v grep` guard the wrong fix rather than a smaller one: an empty crontab
    # makes `crontab -l` fail with "no crontab for ...", which is the ordinary
    # empty case and used to be recognised with `grep -qi 'no crontab'`. With no
    # grep there is no way to tell that from a real read failure, so a guard
    # would have had to choose between refusing every first install and treating
    # a failed read as an empty crontab. Matching it with a `case` removes the
    # choice, and this asserts that the empty case is still recognised.
    nogrep_bin="$TMP/no-grep-only"
    if ! build_path_without "$nogrep_bin" grep; then
        printf '  skip grep-preflight tests: could not build a PATH without grep\n'
    else
        d="$(new_case)"; co="$(new_checkout "$d")"
        export CRONTAB_FILE="$d/crontab.txt"
        : > "$CRONTAB_FILE"

        run_install env PATH="$nogrep_bin" bash "$co/manual-setup/install-cron.sh" --remove
        assert_eq "a removal with nothing to remove does not need grep" \
            "0" "$CRON_STATUS"
        assert_contains "and reports what it found, not a missing tool" \
            "nothing to remove" "$CRON_OUT"
        assert_not_contains "rather than refusing over grep" "grep not found" "$CRON_OUT"

        run_install env PATH="$nogrep_bin" bash "$co/manual-setup/install-cron.sh"
        assert_eq "a first install onto an empty crontab does not need grep either" \
            "0" "$CRON_STATUS"
        assert_eq "and the job is installed" "1" "$(cron_count 'InternetReconnector$')"
        assert_not_contains "with the empty crontab not mistaken for a read failure" \
            "Refusing to continue" "$CRON_OUT"

        # ... and a real read failure is still refused without grep, so dropping
        # the command did not turn the guard that protects the user's entries
        # into something that always says "empty".
        printf '0 3 * * * /usr/bin/backup.sh\n' > "$CRONTAB_FILE"
        before="$(cron_text)"
        run_install env PATH="$nogrep_bin" CRONTAB_FAIL=l CRONTAB_FAIL_RC=1 \
            CRONTAB_FAIL_MSG="crontab: permission denied" bash "$co/manual-setup/install-cron.sh"
        assert_eq "an unreadable crontab is still refused without grep" "1" "$CRON_STATUS"
        assert_contains "and still says it refused rather than continuing" \
            "Refusing to continue" "$CRON_OUT"
        assert_eq "and the user's entries are untouched" "$before" "$(cron_text)"

        # uninstall-cron.sh still runs one grep, in read_crontab(), and still
        # refuses without it -- but only on the runs that reach it, which is the
        # half that was wrong. That grep runs only when `crontab -l` *fails*, so
        # a readable crontab never reaches one; gating the check on "is there a
        # crontab command" instead refused every run on a machine with a crontab
        # and no grep, over a command those runs never invoke. Both directions
        # are pinned, because either alone passes with the gate at the wrong
        # level: the refusal alone would pass with the check back up front, and
        # the successes alone would pass with the check deleted outright.
        #
        # The crontab here still holds the unrelated entry from the block above,
        # so `crontab -l` succeeds and grep is genuinely never called.
        assert_contains "the fixture's crontab is readable and not empty" \
            "backup.sh" "$(cron_text)"
        run_install env PATH="$nogrep_bin" bash "$co/manual-setup/uninstall-cron.sh"
        assert_eq "a readable crontab needs no grep in uninstall-cron.sh either" \
            "0" "$CRON_STATUS"
        assert_contains "and it reports what it found" "No cron job found" "$CRON_OUT"
        assert_not_contains "rather than refusing over grep" "grep not found" "$CRON_OUT"
        assert_eq "and the user's entry is untouched" "$before" "$(cron_text)"

        # ... and neither does --dry-run, which changes nothing at all. This is
        # the spelling that makes the point hardest to argue with: refusing to
        # *describe* what would be removed, over a command no part of the
        # description runs.
        run_install env PATH="$nogrep_bin" bash "$co/manual-setup/uninstall-cron.sh" --dry-run
        assert_eq "nor does --dry-run" "0" "$CRON_STATUS"
        assert_contains "and it still reports" "No cron job to remove" "$CRON_OUT"
        assert_not_contains "with nothing said about grep" "grep not found" "$CRON_OUT"

        # Still required on the branch that does use it, so the gate was
        # narrowed rather than deleted. An empty crontab makes `crontab -l` exit
        # 1 with "no crontab for ..." on stderr, and grep is the only thing that
        # tells that from a read this script must refuse to guess at.
        : > "$CRONTAB_FILE"
        run_install env PATH="$nogrep_bin" bash "$co/manual-setup/uninstall-cron.sh"
        assert_eq "uninstall-cron.sh still needs grep where it uses it" \
            "1" "$CRON_STATUS"
        assert_contains "and says which command is missing" "grep not found" "$CRON_OUT"
        assert_contains "and says nothing was changed, because nothing was" \
            "Nothing was changed" "$CRON_OUT"

        # A grep that is *present* and fails, which is a different thing from a
        # missing one and was much worse. our_cron_lines() was three greps
        # ending in `|| true`, so a failure came back empty -- indistinguishable
        # from "no line of ours". Everything below it is driven by that result,
        # so uninstall-cron.sh printed "No cron job found", never called
        # `install-cron.sh --remove` at all, signed off with "Verify with:
        # crontab -l" and exited 0 while the job sat in the crontab still
        # running every interval. That is the one outcome the script's header
        # says it is arranged to make impossible, and the preflight above cannot
        # see it: the command is there.
        #
        # Measured before the fix: with this same stub the job survived and the
        # run exited 0. our_cron_lines() is a shell `case` now and runs no grep,
        # which is why the removal below goes through.
        #
        # The assertions are on the crontab and on the report, not on the exit
        # status: exit 0 was exactly what the broken version produced.
        badgrep_bin="$TMP/bad-grep"
        if ! build_path_without "$badgrep_bin" grep; then
            printf '  skip failing-grep test: could not build a PATH for it\n'
        else
            printf '#!%s\nexit 2\n' "$real_bash" > "$badgrep_bin/grep"
            chmod +x "$badgrep_bin/grep"

            d="$(new_case)"; co="$(new_checkout "$d")"
            export CRONTAB_FILE="$d/crontab.txt"
            : > "$CRONTAB_FILE"
            run_install bash "$co/manual-setup/install-cron.sh"
            assert_eq "the job is installed to begin with" \
                "1" "$(cron_count 'InternetReconnector$')"

            run_install env PATH="$badgrep_bin" bash "$co/manual-setup/uninstall-cron.sh"
            assert_eq "a grep that fails does not make the job invisible" \
                "0" "$(cron_count 'InternetReconnector$')"
            assert_contains "and the removal is reported rather than 'nothing found'" \
                "Found the cron job" "$CRON_OUT"
            assert_not_contains "with no claim that there was nothing to remove" \
                "No cron job found" "$CRON_OUT"

            # The control: the same PATH with a working grep must behave
            # identically, or the assertions above would pass for a version that
            # had simply stopped consulting the crontab.
            d="$(new_case)"; co="$(new_checkout "$d")"
            export CRONTAB_FILE="$d/crontab.txt"
            : > "$CRONTAB_FILE"
            run_install bash "$co/manual-setup/install-cron.sh"
            run_install bash "$co/manual-setup/uninstall-cron.sh"
            assert_eq "and a working grep removes it the same way" \
                "0" "$(cron_count 'InternetReconnector$')"
            assert_contains "reporting it the same way too" "Found the cron job" "$CRON_OUT"

            # An *empty* crontab with the same broken grep is a different case
            # and a different right answer. `crontab -l` exits 1 for both "no
            # crontab yet" and a real read failure, and read_crontab() tells
            # them apart with the one grep still left in this script -- so with
            # that grep failing there is genuinely no way to know which it was.
            # It refuses, which is the safe direction and the same choice
            # install-cron.sh's mentions_no_crontab() comment reasons through:
            # treating a failed read as an empty crontab is the destructive
            # answer. Pinned so that "our_cron_lines() no longer needs grep" is
            # never mistaken for "this script no longer needs grep at all".
            : > "$CRONTAB_FILE"
            run_install env PATH="$badgrep_bin" bash "$co/manual-setup/uninstall-cron.sh"
            assert_eq "an empty crontab with a broken grep is refused, not guessed at" \
                "1" "$CRON_STATUS"
            assert_contains "and says it could not read the crontab" \
                "could not read the current crontab" "$CRON_OUT"
            assert_contains "and that nothing was changed" "Nothing was changed" "$CRON_OUT"

            # The control for that one: with a working grep the same empty
            # crontab is the ordinary "nothing to remove" case and exits 0.
            run_install bash "$co/manual-setup/uninstall-cron.sh"
            assert_eq "while a working grep reads the same empty crontab fine" \
                "0" "$CRON_STATUS"
            assert_contains "and reports nothing to remove" "No cron job found" "$CRON_OUT"

            # A commented-out job stays invisible, which is the one thing
            # our_cron_lines() must be strict about -- install-cron.sh's
            # classifier ignores comments, so claiming one here would make the
            # post-condition check declare a job "still installed" that --remove
            # was right to leave alone. The rewrite kept that rule and this is
            # what holds it.
            : > "$CRONTAB_FILE"
            run_install bash "$co/manual-setup/install-cron.sh"
            disabled_line="#$(cron_text)"
            printf '%s\n' "$disabled_line" > "$CRONTAB_FILE"
            run_install env PATH="$badgrep_bin" bash "$co/manual-setup/uninstall-cron.sh"
            assert_eq "a commented-out job is still not claimed" "0" "$CRON_STATUS"
            assert_contains "and is reported as nothing to remove" \
                "No cron job found" "$CRON_OUT"
            assert_eq "and the line is left exactly as it was" \
                "$disabled_line" "$(cron_text)"
        fi
    fi
fi

# The user's own entries -- including a comment that merely mentions the
# marker text -- must survive an install and a removal untouched.
d="$(new_case)"; co="$(new_checkout "$d")"
export CRONTAB_FILE="$d/crontab.txt"
{
    echo "# my own note about InternetReconnector"
    echo "0 3 * * * /usr/bin/backup.sh"
} > "$CRONTAB_FILE"

run_install bash "$co/manual-setup/install-cron.sh"
assert_contains "an unrelated cron entry survives an install" "/usr/bin/backup.sh" "$(cron_text)"

run_install bash "$co/manual-setup/install-cron.sh" --remove
assert_contains "an unrelated cron entry survives a removal" "/usr/bin/backup.sh" "$(cron_text)"
assert_contains "a comment mentioning the marker survives" "my own note" "$(cron_text)"
assert_eq "our line is gone after --remove" "0" "$(cron_count "$co/reconnect.sh")"

# A second checkout's line carries the same marker but a different path. It must
# be reported and left alone, not silently adopted or deleted.
d="$(new_case)"; co="$(new_checkout "$d")"
copy_checkout_into "$d/other"
export CRONTAB_FILE="$d/crontab.txt"
: > "$CRONTAB_FILE"

run_install bash "$d/other/manual-setup/install-cron.sh"
run_install bash "$co/manual-setup/install-cron.sh"
assert_eq "two checkouts install two separate jobs" "2" "$(cron_count 'InternetReconnector$')"
assert_contains "the other checkout's line is reported" "different copy of" "$CRON_OUT"

run_install bash "$co/manual-setup/install-cron.sh" --remove
assert_eq "removing one checkout leaves the other's job" "1" "$(cron_count 'InternetReconnector$')"
assert_contains "the surviving line belongs to the other checkout" "$d/other/reconnect.sh" "$(cron_text)"

# Two other checkouts, so warn_about_foreign() has more than one line to report.
# It used to print them with `printf '        %s\n' "$foreign"`, and printf
# reuses its format once per *argument* -- a multi-line string being one
# argument. So the first line came out indented under "so they were left
# untouched:" and the second flush against the left margin, where it reads as
# the start of a new sentence rather than as a second cron line. One checkout
# could never show it, which is why the fixture needs three.
d="$(new_case)"; co="$(new_checkout "$d")"
mkdir -p "$d/other" "$d/third"
copy_checkout_into "$d/other"
copy_checkout_into "$d/third"
export CRONTAB_FILE="$d/crontab.txt"
: > "$CRONTAB_FILE"

run_install bash "$d/other/manual-setup/install-cron.sh"
run_install bash "$d/third/manual-setup/install-cron.sh"
run_install bash "$co/manual-setup/install-cron.sh"
assert_eq "three checkouts install three jobs" "3" "$(cron_count 'InternetReconnector$')"
assert_contains "and the other two are reported" "different copy of" "$CRON_OUT"
assert_eq "both foreign lines are indented under the note" \
    "2" "$(printf '%s\n' "$CRON_OUT" | grep -c '^        \*/5' || true)"
assert_eq "and neither is left flush against the margin" \
    "0" "$(printf '%s\n' "$CRON_OUT" | grep -c '^\*/5' || true)"

# One checkout reached two ways, through its real path and through a symlink.
# The scripts resolved themselves with a plain `pwd`, which keeps the spelling
# they were reached by, so the line named whichever one the installer was run
# through. A re-install through the other spelling then failed ours()' path
# test, called this checkout's own line "a different copy", and appended a
# second job. The physical path is written now, and the spelling a run arrives
# by is still accepted when reading, so a line an earlier version wrote through
# the symlink is replaced rather than duplicated.
#
# `ln` is not on the prerequisite list, for the reason `timeout` is not: one
# case needs it, and some hosts' `ln -s` copies instead of linking. Self-skips
# where the result is not a symlink.
d="$(new_case)"
copy_checkout_into "$d/real"
if ! ln -s "$d/real" "$d/link" 2>/dev/null || [ ! -L "$d/link" ]; then
    printf '  skip symlinked-checkout test: this system did not make a symbolic link\n'
else
    export CRONTAB_FILE="$d/crontab.txt"
    : > "$CRONTAB_FILE"
    run_install bash "$d/real/manual-setup/install-cron.sh"
    run_install bash "$d/link/manual-setup/install-cron.sh"
    assert_eq "a re-install through a symlink does not add a second job" \
        "1" "$(cron_count 'InternetReconnector$')"
    assert_not_contains "nor calls the checkout's own line another copy's" \
        "different copy of" "$CRON_OUT"
    assert_contains "and the line names the physical path" \
        "'$d/real/reconnect.sh'" "$(cron_text)"

    run_install bash "$d/link/manual-setup/uninstall-cron.sh"
    assert_eq "an uninstall through the symlink finds and removes it" \
        "0" "$(cron_count 'InternetReconnector$')"

    # A line an earlier version wrote through the symlink, which names the
    # link's spelling. Re-installing the same way must replace it.
    printf "*/5 * * * * PATH='/usr/bin' '%s/reconnect.sh' >/dev/null 2>&1 # InternetReconnector\n" \
        "$d/link" > "$CRONTAB_FILE"
    run_install bash "$d/link/manual-setup/install-cron.sh"
    assert_eq "a line written through the symlink is replaced, not duplicated" \
        "1" "$(cron_count 'InternetReconnector$')"
    assert_contains "by one naming the physical path" \
        "'$d/real/reconnect.sh'" "$(cron_text)"

    # The other two readers of the line, which the cases above never reach in
    # the link's spelling: the uninstall through the link meets a line naming
    # the physical path, and only install-cron.sh ever met a link-spelled one.
    # So RECONNECT_ALIAS could be deleted from uninstall-cron.sh and
    # auto-setup.sh with every assertion here still passing (measured), and
    # those two would then call this checkout's own line another copy's --
    # "No cron job found" from the uninstall, and no settings carried by the
    # setup. Both are run through the link over a line in the link's spelling.
    mkdir -p "$d/etc"
    printf 'WIFI_SSID="OldNet"\n' > "$d/etc/config.env"
    link_line="$(printf "*/5 * * * * PATH='/usr/bin' RECONNECT_CONFIG='%s' '%s/reconnect.sh' >/dev/null 2>&1 # InternetReconnector" \
        "$d/etc/config.env" "$d/link")"
    printf '%s\n' "$link_line" > "$CRONTAB_FILE"
    run_install bash "$d/link/manual-setup/uninstall-cron.sh" --dry-run
    assert_contains "uninstall-cron.sh through the symlink claims a link-spelled line" \
        "Would remove the cron job" "$CRON_OUT"
    assert_not_contains "rather than finding nothing of its own" \
        "No cron job found" "$CRON_OUT"

    CRON_OUT="$(printf '\nhunter2\n\nno\n\n' | env NM_ACTIVE_PROFILE="OldNet" \
        NM_PROFILES="OldNet|OldNet" bash "$d/link/auto-setup.sh" 2>&1)"
    CRON_STATUS=$?
    assert_eq "auto-setup.sh through the symlink runs over a link-spelled line" \
        "0" "$CRON_STATUS"
    assert_contains "and takes that line's settings as its own" \
        "Using RECONNECT_CONFIG='$d/etc/config.env' from the installed cron job" "$CRON_OUT"
    assert_eq "writing the config the line names" "hunter2" \
        "$(sed -n 's/^WIFI_PASSWORD="\(.*\)"$/\1/p' "$d/etc/config.env" | head -n 1)"
    assert_eq "and leaving one job" "1" "$(cron_count 'InternetReconnector$')"

    # Recognising the line was not enough on its own. Both scripts hand the
    # crontab work to install-cron.sh, and they started it by the physical
    # path, which gave it no alias: the setup above then installed a second
    # job beside the link-spelled line, and a real uninstall reported the line,
    # watched --remove leave it as "a different copy", and exited 1 over it.
    # Only a run that writes can show that -- the dry run above cannot.
    printf '%s\n' "$link_line" > "$CRONTAB_FILE"
    run_install bash "$d/link/manual-setup/uninstall-cron.sh"
    assert_eq "an uninstall through the symlink removes a link-spelled line" \
        "0" "$CRON_STATUS"
    assert_eq "and leaves no job behind" "0" "$(cron_count 'InternetReconnector')"
fi

# An exported CDPATH. `cd` searches it for a relative name that does not start
# with `./`, and when it finds one there it prints where it went -- into the
# `$(cd ... && pwd -P)` that resolves each script's own directory. With
# CDPATH=. exported, `bash manual-setup/install-cron.sh` from the checkout root
# died on a cd error naming the path twice over, and reconnect.sh run the same
# way ended under `set -e` before it could log anything. Each script now clears
# CDPATH first. The documented `./` spellings never met it, which is why the
# fixture uses the bare relative ones.
d="$(new_case)"; co="$(new_checkout "$d")"
export CRONTAB_FILE="$d/crontab.txt"; : > "$CRONTAB_FILE"
CRON_OUT="$(cd "$co" && CDPATH=. bash manual-setup/install-cron.sh 2>&1)"
CRON_STATUS=$?
assert_eq "an exported CDPATH does not break install-cron.sh run by a bare relative path" \
    "0" "$CRON_STATUS"
assert_eq "and the job is installed" "1" "$(cron_count 'InternetReconnector$')"
assert_contains "naming the checkout's own reconnect.sh" "'$co/reconnect.sh'" "$(cron_text)"
CRON_OUT="$(cd "$co" && CDPATH=. bash manual-setup/uninstall-cron.sh 2>&1)"
CRON_STATUS=$?
assert_eq "nor uninstall-cron.sh" "0" "$CRON_STATUS"
assert_eq "which removes it" "0" "$(cron_count 'InternetReconnector$')"
printf 'WIFI_SSID="MyNet"\n' > "$co/config.env"
CRON_OUT="$(cd "$d" && CDPATH=. NM_ACTIVE_PROFILE="MyNet" NM_PROFILES="MyNet|MyNet" \
    bash co/reconnect.sh 2>&1)"
CRON_STATUS=$?
assert_eq "nor reconnect.sh" "0" "$CRON_STATUS"
assert_eq "which logs its outcome where it always does" "Wifi Good" \
    "$(tail -n 1 "$co/logs/$(date '+%Y-%m-%d').log" 2>/dev/null | sed 's/^\[[^]]*\] //')"

# =============================================================================
section "nmcli preflight and CRON_PATH"
# =============================================================================
# The installed job cannot do anything without nmcli, and under cron it cannot
# say so: reconnect.sh dies with a stated reason and cron sends that reason to
# /dev/null, leaving FAIL every interval and nothing else. This script used to
# report a clean install in both of the situations below, which is why the
# warnings exist -- and why they are warnings rather than refusals.

# The stub nmcli lives on the suite's own PATH, which is nowhere near the six
# system directories written onto the cron line, so a plain install is already
# the mismatch case. That is the failure that looks like a mystery: the job
# fails every interval while running ./reconnect.sh by hand works perfectly,
# because the user's own PATH does find nmcli.
d="$(new_case)"; co="$(new_checkout "$d")"
export CRONTAB_FILE="$d/crontab.txt"
: > "$CRONTAB_FILE"

run_install bash "$co/manual-setup/install-cron.sh"
assert_eq "an install with nmcli off the cron PATH still succeeds" "0" "$CRON_STATUS"
assert_eq "and the job is installed" "1" "$(cron_count 'InternetReconnector$')"
assert_contains "but it says the job will not find nmcli" \
    "is not on the PATH this job was" "$CRON_OUT"
assert_contains "and prints the command that fixes it" \
    "CRON_PATH='$STUB_BIN:" "$CRON_OUT"

# Widening it silences the warning and reaches the line, single-quoted like
# every other value written there.
run_install env CRON_PATH="$STUB_BIN:/usr/bin" bash "$co/manual-setup/install-cron.sh"
assert_eq "CRON_PATH is accepted" "0" "$CRON_STATUS"
assert_contains "and is written onto the line, quoted" \
    "PATH='$STUB_BIN:/usr/bin'" "$(cron_text)"
assert_not_contains "and the mismatch warning is gone" \
    "is not on the PATH this job was" "$CRON_OUT"

# Carried across a re-install like MINUTES and the RECONNECT_* settings. Without
# this a plain `./install-cron.sh` would silently put the six defaults back and
# the job would stop finding nmcli again, with nothing to show what changed.
run_install bash "$co/manual-setup/install-cron.sh"
assert_eq "a plain re-install keeps CRON_PATH" "0" "$CRON_STATUS"
assert_contains "and writes it out again" "PATH='$STUB_BIN:/usr/bin'" "$(cron_text)"
assert_not_contains "so the warning stays gone" \
    "is not on the PATH this job was" "$CRON_OUT"

# The check compares directory strings, so a difference the shell's own lookup does
# not care about has to be normalised away first: `/usr/bin/` and `/usr/bin` name
# one directory and are two strings to `case`. A single trailing slash anywhere in
# CRON_PATH made this warn about a PATH that was already correct and tell the user
# to re-run with a directory that was already on it. A warning that fires when
# nothing is wrong stops being believed on the day it is right, which is the only
# day it matters -- and reducing strip_trailing_slash() to the identity left the
# whole suite green.
run_install env CRON_PATH="$STUB_BIN/:/usr/bin" bash "$co/manual-setup/install-cron.sh"
assert_eq "a CRON_PATH entry with a trailing slash is accepted" "0" "$CRON_STATUS"
assert_not_contains "and does not warn about a PATH that already reaches nmcli" \
    "is not on the PATH this job was" "$CRON_OUT"

# The control. Without it the assertion above would also pass if the warning had
# stopped working altogether, which is the failure it is meant to be sensitive to.
run_install env CRON_PATH="/usr/bin" bash "$co/manual-setup/install-cron.sh"
assert_contains "while a PATH that really does not reach nmcli still warns" \
    "is not on the PATH this job was" "$CRON_OUT"

# A PATH that reaches nmcli and not bash. The cron line starts reconnect.sh
# through `#!/usr/bin/env bash`, so `env` looks bash up on this PATH alone: a
# CRON_PATH naming only nmcli's directory passed the nmcli check, installed with
# exit 0 and no note, and every scheduled run died in `env` before reconnect.sh
# ran a line -- no log line at all, not even FAIL. $STUB_BIN is exactly that
# directory: the stub nmcli is there and bash is not.
#
# The nmcli note is asserted absent, so the case is not passing on the wrong
# warning; and the suggested command must lead with bash's real directory.
run_install env CRON_PATH="$STUB_BIN" bash "$co/manual-setup/install-cron.sh"
assert_eq "a CRON_PATH without bash still installs" "0" "$CRON_STATUS"
assert_contains "but says the job could never start" \
    "bash is missing from the PATH this job was installed with" "$CRON_OUT"
assert_contains "and prints the command that fixes it" \
    "CRON_PATH='${real_bash%/*}:$STUB_BIN'" "$CRON_OUT"
assert_not_contains "while nmcli, which that PATH does reach, is not warned about" \
    "is not on the PATH this job was" "$CRON_OUT"

# The control: the same PATH with bash's directory added says nothing about
# bash, so the note above is about bash and not about a PATH that was set at all.
run_install env CRON_PATH="$STUB_BIN:${real_bash%/*}" bash "$co/manual-setup/install-cron.sh"
assert_not_contains "a CRON_PATH that reaches bash gets no bash note" \
    "bash is missing" "$CRON_OUT"

# It stopped being a literal in the script the moment it became settable, so it
# is vetted like every other value that reaches the crontab.
good="$(cron_text)"
run_install env CRON_PATH="/usr/bin:/tmp/it's" bash "$co/manual-setup/install-cron.sh"
assert_eq "a CRON_PATH containing a single quote is refused" "1" "$CRON_STATUS"
run_install env CRON_PATH='/usr/bin:/tmp/100%' bash "$co/manual-setup/install-cron.sh"
assert_eq "a CRON_PATH containing '%' is refused" "1" "$CRON_STATUS"
run_install env CRON_PATH=$'/usr/bin\n*/1 * * * * /usr/bin/id' bash "$co/manual-setup/install-cron.sh"
assert_eq "a CRON_PATH containing a newline is refused" "1" "$CRON_STATUS"
assert_contains "and the refusal says why" "contains a line break" "$CRON_OUT"
assert_eq "and none of the three changed the line" "$good" "$(cron_text)"

# The other half: nmcli missing outright. Needs a PATH that carries everything
# install-cron.sh uses and not nmcli, built from wrappers that exec the real
# binary by absolute path -- the same trick the date-preflight test above uses,
# and the only way to drop one command without losing the rest.
nonmcli="$TMP/no-nmcli"
mkdir -p "$nonmcli"
nonmcli_ok=1
[ -n "$real_bash" ] || nonmcli_ok=0
for tool in bash cat chmod date awk grep mktemp rm; do
    real_tool="$(command -v "$tool" || true)"
    if [ -z "$real_tool" ]; then
        nonmcli_ok=0
        continue
    fi
    printf '#!%s\nexec %s "$@"\n' "$real_bash" "$real_tool" > "$nonmcli/$tool"
    chmod +x "$nonmcli/$tool"
done
# The crontab stub goes in as itself: its shebang is an absolute path, so it
# does not need anything on PATH to start.
cp "$STUB_BIN/crontab" "$nonmcli/crontab" 2>/dev/null || nonmcli_ok=0

if [ "$nonmcli_ok" -ne 1 ]; then
    printf '  skip missing-nmcli test: could not build a PATH without nmcli\n'
else
    d="$(new_case)"; co="$(new_checkout "$d")"
    export CRONTAB_FILE="$d/crontab.txt"
    : > "$CRONTAB_FILE"
    printf 'WIFI_SSID="MyNet"\n' > "$co/config.env"

    run_install env PATH="$nonmcli" bash "$co/manual-setup/install-cron.sh"
    assert_eq "an install on a machine with no nmcli still succeeds" "0" "$CRON_STATUS"
    assert_eq "and the job is installed" "1" "$(cron_count 'InternetReconnector$')"
    assert_contains "but it says nmcli was not found" "nmcli was not found" "$CRON_OUT"
    assert_contains "and says what that means for every run" "log FAIL" "$CRON_OUT"
    assert_not_contains "and does not also give the PATH advice" \
        "is not on the PATH this job was" "$CRON_OUT"
fi

# =============================================================================
section "uninstall-cron.sh"
# =============================================================================

# The marker is defined in both scripts. uninstall-cron.sh delegates the crontab
# surgery to install-cron.sh precisely so the two cannot develop a second,
# subtly different idea of what "our line" is -- but the string that defines it
# is still written out twice, and nothing else here would notice them drifting.
# If they ever do, the uninstaller reports "No cron job found" and exits 0 while
# cron goes on running the job every interval, which is the one failure this
# script is arranged to make impossible.
install_marker="$(sed -n 's/^MARKER=\("[^"]*"\).*/\1/p' "$INSTALL" | head -n 1)"
uninstall_marker="$(sed -n 's/^MARKER=\("[^"]*"\).*/\1/p' "$UNINSTALL" | head -n 1)"
assert_contains "install-cron.sh defines a marker" "InternetReconnector" "$install_marker"
assert_eq "and uninstall-cron.sh defines exactly the same one" \
    "$install_marker" "$uninstall_marker"

d="$(new_case)"; co="$(new_checkout "$d")"
export CRONTAB_FILE="$d/crontab.txt"
: > "$CRONTAB_FILE"
run_install bash "$co/manual-setup/install-cron.sh"

before="$(cron_text)"
run_install bash "$co/manual-setup/uninstall-cron.sh" --dry-run
assert_eq "--dry-run succeeds" "0" "$CRON_STATUS"
assert_contains "--dry-run says what it would do" "Would remove the cron job" "$CRON_OUT"
assert_not_contains "and leaves nothing behind on an ordinary line" "Would leave" "$CRON_OUT"
assert_eq "--dry-run changes nothing" "$before" "$(cron_text)"

run_install bash "$co/manual-setup/uninstall-cron.sh"
assert_eq "uninstall succeeds" "0" "$CRON_STATUS"
assert_eq "uninstall removes the job" "0" "$(cron_count 'InternetReconnector$')"

run_install bash "$co/manual-setup/uninstall-cron.sh"
assert_eq "uninstalling twice is not an error" "0" "$CRON_STATUS"
assert_contains "the second uninstall says there was nothing to do" "No cron job found" "$CRON_OUT"

# `--help` used to exit from inside the parsing loop, so the loop never reached
# anything after it and the same stray word was refused or ignored depending on
# where it sat: `--bogus --help` exited 1, `--help --bogus` printed usage and
# exited 0. That is the wrong way round for a script whose argument policy is
# that anything unrecognised is an error, and it is the defect install-cron.sh
# fixed by moving its arity check ahead of its `case`. Both orders are asserted,
# because either one alone passes with the bug in place.
run_install bash "$co/manual-setup/uninstall-cron.sh" --help --bogus
assert_eq "a stray argument after --help is still refused" "1" "$CRON_STATUS"
assert_contains "and is named" "unknown argument: '--bogus'" "$CRON_OUT"

run_install bash "$co/manual-setup/uninstall-cron.sh" --bogus --help
assert_eq "and so is one before it" "1" "$CRON_STATUS"
assert_contains "and named the same way" "unknown argument: '--bogus'" "$CRON_OUT"

# This loop is driven by `$#`, so an empty argument always reached the unknown
# arm -- but unquoted the refusal came out as `ERROR: unknown argument: `,
# naming nothing at all, and a blanks-only one looked like a sentence that had
# stopped mid-word. `./uninstall-cron.sh "$flag"` with $flag unset is how that
# arrives. install-cron.sh and reconnect.sh quote theirs now for the same reason,
# so all three name what they rejected.
run_install bash "$co/manual-setup/uninstall-cron.sh" ""
assert_eq "an empty argument is refused" "1" "$CRON_STATUS"
assert_contains "and the quotes make the empty value visible" \
    "unknown argument: ''" "$CRON_OUT"

run_install bash "$co/manual-setup/uninstall-cron.sh" "  "
assert_contains "a blanks-only argument is shown between quotes too" \
    "unknown argument: '  '" "$CRON_OUT"

# The control: --help on its own still prints usage and exits 0, so the fix
# refused an argument rather than breaking the flag.
run_install bash "$co/manual-setup/uninstall-cron.sh" --help
assert_eq "--help on its own still succeeds" "0" "$CRON_STATUS"
assert_contains "and prints the usage block" "Usage: uninstall-cron.sh" "$CRON_OUT"

# ... and a legitimate combination of flags is still accepted in any order,
# which is what stops the fix being an arity check this script's grammar cannot
# carry: it takes any number of flags, unlike install-cron.sh's one.
run_install bash "$co/manual-setup/uninstall-cron.sh" --dry-run --purge-logs
assert_eq "several real flags together are still fine" "0" "$CRON_STATUS"
assert_contains "and the dry run reports as usual" "Dry run: nothing was changed" "$CRON_OUT"

# A job the user disabled by commenting the line out. install-cron.sh's
# classifier ignores comments, so --remove correctly does nothing; this script
# has to agree, or it reports a job it cannot remove and exits non-zero on a
# crontab that has nothing left to remove.
d="$(new_case)"; co="$(new_checkout "$d")"
export CRONTAB_FILE="$d/crontab.txt"
: > "$CRONTAB_FILE"
run_install bash "$co/manual-setup/install-cron.sh"
disabled="#$(cron_text)"
printf '%s\n' "$disabled" > "$CRONTAB_FILE"

run_install bash "$co/manual-setup/uninstall-cron.sh"
assert_eq "a commented-out job is not reported as installed" "0" "$CRON_STATUS"
assert_contains "and says there was nothing to remove" "No cron job found" "$CRON_OUT"
assert_not_contains "with no bogus still-installed warning" "is still installed" "$CRON_OUT"
assert_eq "the commented-out line is left exactly as it was" "$disabled" "$(cron_text)"

run_install bash "$co/manual-setup/uninstall-cron.sh" --dry-run
assert_eq "--dry-run agrees there is nothing to remove" "0" "$CRON_STATUS"
assert_contains "--dry-run says so" "No cron job to remove" "$CRON_OUT"

# --purge-logs deletes only the daily logs, and only with confirmation.
d="$(new_case)"; co="$(new_checkout "$d")"
export CRONTAB_FILE="$d/crontab.txt"
: > "$CRONTAB_FILE"
mkdir -p "$d/logs"
touch "$d/logs/2026-01-01.log" "$d/logs/2026-01-02.log" "$d/logs/notes.log" "$d/logs/keepme.txt"
# reconnect.sh creates this and never removes it, so the purge has to take it or
# it outlives an uninstall in a directory reported as cleared.
touch "$d/logs/.lock"

run_install env RECONNECT_LOG_DIR="$d/logs" bash "$co/manual-setup/uninstall-cron.sh" --purge-logs --dry-run
assert_contains "--dry-run lists the logs it would delete" "Would delete 2 log file(s)" "$CRON_OUT"
assert_contains "--dry-run names the lock file too" "Would also delete the lock file" "$CRON_OUT"
assert_exists "--dry-run deletes no logs" "$d/logs/2026-01-01.log"
assert_exists "--dry-run leaves the lock file alone" "$d/logs/.lock"

run_install env RECONNECT_LOG_DIR="$d/logs" bash "$co/manual-setup/uninstall-cron.sh" --purge-logs --yes
assert_missing "--purge-logs --yes deletes the daily logs" "$d/logs/2026-01-01.log"
assert_missing "--purge-logs --yes deletes the lock file" "$d/logs/.lock"
assert_exists "--purge-logs leaves a non-dated .log alone" "$d/logs/notes.log"
assert_exists "--purge-logs leaves a non-log file alone" "$d/logs/keepme.txt"

# Without a terminal and without --yes there is nobody to answer the prompt, so
# it must refuse rather than pick a default.
d="$(new_case)"; co="$(new_checkout "$d")"
export CRONTAB_FILE="$d/crontab.txt"
: > "$CRONTAB_FILE"
mkdir -p "$d/logs"; touch "$d/logs/2026-01-01.log"
CRON_OUT="$(RECONNECT_LOG_DIR="$d/logs" bash "$co/manual-setup/uninstall-cron.sh" --purge-logs < /dev/null 2>&1)"
CRON_STATUS=$?
assert_eq "--purge-logs with no terminal and no --yes refuses" "1" "$CRON_STATUS"
assert_exists "and deletes nothing" "$d/logs/2026-01-01.log"
assert_contains "and says nothing was changed, because nothing was" \
    "Nothing was changed" "$CRON_OUT"
assert_not_contains "rather than claiming a removal that never happened" \
    "The cron job was removed" "$CRON_OUT"

# The same refusal, but with a job installed. It fires *after* the removal --
# that runs first -- so a message saying only "needs confirmation", followed by
# exit 1, told a caller scripting the uninstall that the whole run had failed
# when its main action had succeeded.
d="$(new_case)"; co="$(new_checkout "$d")"
export CRONTAB_FILE="$d/crontab.txt"
: > "$CRONTAB_FILE"
mkdir -p "$d/logs"; touch "$d/logs/2026-01-01.log"
run_install bash "$co/manual-setup/install-cron.sh"
CRON_OUT="$(RECONNECT_LOG_DIR="$d/logs" bash "$co/manual-setup/uninstall-cron.sh" --purge-logs < /dev/null 2>&1)"
CRON_STATUS=$?
assert_eq "the refusal still exits non-zero" "1" "$CRON_STATUS"
assert_contains "and says the cron job was removed" "The cron job was removed" "$CRON_OUT"
assert_contains "and that the logs were kept" "logs were kept" "$CRON_OUT"
assert_eq "and the job really is gone" "0" "$(cron_count 'InternetReconnector')"
assert_exists "while the logs are still there" "$d/logs/2026-01-01.log"

# The lock file is a purge target in its own right, so counting only the daily
# logs made a refusal ask the user to confirm deleting nothing while a file sat
# there waiting to be deleted.
d="$(new_case)"; co="$(new_checkout "$d")"
export CRONTAB_FILE="$d/crontab.txt"
: > "$CRONTAB_FILE"
mkdir -p "$d/logs"; touch "$d/logs/.lock"
CRON_OUT="$(RECONNECT_LOG_DIR="$d/logs" bash "$co/manual-setup/uninstall-cron.sh" --purge-logs < /dev/null 2>&1)"
CRON_STATUS=$?
assert_eq "a lock file on its own is still something to confirm" "1" "$CRON_STATUS"
assert_contains "and the refusal names it" "delete the lock file" "$CRON_OUT"
assert_not_contains "rather than asking about zero log files" "0 log file(s)" "$CRON_OUT"
assert_exists "and it is still there" "$d/logs/.lock"

run_install env RECONNECT_LOG_DIR="$d/logs" bash "$co/manual-setup/uninstall-cron.sh" --purge-logs --yes
assert_eq "--yes deletes a lone lock file" "0" "$CRON_STATUS"
assert_missing "and it is gone" "$d/logs/.lock"
assert_contains "the report names the lock file" "Deleted the lock file" "$CRON_OUT"
assert_not_contains "without also reporting zero deleted logs" \
    "Deleted 0 log file(s)" "$CRON_OUT"

# The log directory comes off the installed cron line when the environment does
# not name one. Without that, an install made with a custom RECONNECT_LOG_DIR was
# uninstalled with "No daily logs to delete" and exit 0 while every log survived
# -- a cleanup reported but never performed, using a directory this script had
# just printed the correct alternative to on screen.
d="$(new_case)"; co="$(new_checkout "$d")"
export CRONTAB_FILE="$d/crontab.txt"
: > "$CRONTAB_FILE"
mkdir -p "$d/custom-logs"
touch "$d/custom-logs/2026-01-01.log" "$d/custom-logs/2026-01-02.log" "$d/custom-logs/.lock"
run_install env RECONNECT_LOG_DIR="$d/custom-logs" bash "$co/manual-setup/install-cron.sh"

# An explicit setting still wins over the line: it is the only way to reach a
# directory no cron line names, and the only option once the job is gone.
run_install env RECONNECT_LOG_DIR="$d/logs" bash "$co/manual-setup/uninstall-cron.sh" --purge-logs --dry-run
assert_contains "an explicit RECONNECT_LOG_DIR still wins over the cron line" \
    "No daily logs to delete in $d/logs" "$CRON_OUT"

run_install bash "$co/manual-setup/uninstall-cron.sh" --purge-logs --dry-run
assert_contains "the log directory is read off the installed cron line" \
    "Would delete 2 log file(s) from $d/custom-logs" "$CRON_OUT"
assert_contains "including the lock file kept there" "Would also delete the lock file" "$CRON_OUT"
assert_exists "a dry run still deletes nothing" "$d/custom-logs/2026-01-01.log"

run_install bash "$co/manual-setup/uninstall-cron.sh" --purge-logs --yes
assert_eq "the purge succeeds without being told where to look" "0" "$CRON_STATUS"
assert_missing "and the custom-directory logs are gone" "$d/custom-logs/2026-01-01.log"
assert_missing "and so is the lock file" "$d/custom-logs/.lock"

# ... but only when the line names an absolute directory. install-cron.sh refuses
# to write a relative RECONNECT_LOG_DIR and refuses to carry one back off the
# line, because cron runs the job from the user's home directory while a relative
# path here resolves against wherever the script was run from. Reading one back
# and acting on it applied that mismatch to a deletion: with
# RECONNECT_LOG_DIR='mylogs' hand-edited onto the line, `--purge-logs --yes` run
# from any directory containing a mylogs/ deleted every YYYY-MM-DD.log and the
# .lock inside it -- files this tool never wrote -- while the job's real logs
# under $HOME/mylogs survived, and the report named only "mylogs", from which the
# user could not tell which directory had been cleared.
#
# The fixture runs the uninstall from a directory that has such a mylogs/ in it,
# because that is the whole of the defect: a relative path plus a caller standing
# somewhere unrelated. The decoys are what the assertions turn on -- a run that
# merely exits 0 says nothing about whether they survived.
d="$(new_case)"; co="$(new_checkout "$d")"
export CRONTAB_FILE="$d/crontab.txt"
mkdir -p "$d/elsewhere/mylogs"
touch "$d/elsewhere/mylogs/2026-01-01.log" "$d/elsewhere/mylogs/.lock"
printf "*/5 * * * * PATH='/usr/bin' RECONNECT_LOG_DIR='mylogs' '%s/reconnect.sh' >/dev/null 2>&1 # InternetReconnector\n" \
    "$co" > "$CRONTAB_FILE"

CRON_OUT="$(cd "$d/elsewhere" && bash "$co/manual-setup/uninstall-cron.sh" --purge-logs --yes 2>&1)"
CRON_STATUS=$?
assert_eq "a relative log directory on the line does not fail the uninstall" \
    "0" "$CRON_STATUS"
assert_exists "and the caller's own dated log is not deleted" \
    "$d/elsewhere/mylogs/2026-01-01.log"
assert_exists "nor the lock file beside it" "$d/elsewhere/mylogs/.lock"
assert_contains "and the run says the value was ignored, rather than saying nothing" \
    "relative log directory" "$CRON_OUT"
assert_not_contains "and never reports deleting from the bare relative path" \
    "log file(s) from mylogs" "$CRON_OUT"
assert_eq "while the cron job itself is still removed" \
    "0" "$(cron_count 'InternetReconnector')"

# The control, and it is what stops the guard being written as "ignore the line".
# An absolute value on the line must still be honoured -- that is the behaviour
# log_dir_from_cron_line() exists for, and the block above would pass just as
# well if the line were no longer read at all.
d="$(new_case)"; co="$(new_checkout "$d")"
export CRONTAB_FILE="$d/crontab.txt"
mkdir -p "$d/abs-logs"; touch "$d/abs-logs/2026-01-01.log"
printf "*/5 * * * * PATH='/usr/bin' RECONNECT_LOG_DIR='%s' '%s/reconnect.sh' >/dev/null 2>&1 # InternetReconnector\n" \
    "$d/abs-logs" "$co" > "$CRONTAB_FILE"
run_install bash "$co/manual-setup/uninstall-cron.sh" --purge-logs --yes
assert_eq "an absolute log directory on the line is still honoured" "0" "$CRON_STATUS"
assert_missing "and its logs really are purged" "$d/abs-logs/2026-01-01.log"
assert_not_contains "with no relative-path note" "relative log directory" "$CRON_OUT"

# A line hand-edited past what install-cron.sh recognises. --remove correctly
# leaves it alone, so this script must notice the job is still scheduled, say so,
# and exit non-zero -- reporting a successful uninstall here would tell a caller
# the job was gone while cron went on running it every interval.
d="$(new_case)"; co="$(new_checkout "$d")"
export CRONTAB_FILE="$d/crontab.txt"
: > "$CRONTAB_FILE"
run_install bash "$co/manual-setup/install-cron.sh"
printf '%s (edited by hand)\n' "$(cron_text)" > "$CRONTAB_FILE"
edited="$(cron_text)"

# The dry run over that line. It used to answer off this script's loose matcher
# and promised "Would remove the cron job" -- while the real run below leaves the
# line and exits 1. The prediction comes from install-cron.sh --remove-dry-run
# now, the rule that actually deletes.
run_install bash "$co/manual-setup/uninstall-cron.sh" --dry-run
assert_eq "--dry-run over a line --remove will leave still succeeds" "0" "$CRON_STATUS"
assert_not_contains "and does not promise to remove it" "Would remove the cron job" "$CRON_OUT"
assert_contains "but says it would be left in place" "Would leave this line in place" "$CRON_OUT"
assert_contains "and names it" "(edited by hand)" "$CRON_OUT"
assert_eq "and changes nothing" "$edited" "$(cron_text)"
run_install bash "$co/manual-setup/install-cron.sh" --remove-dry-run
assert_eq "install-cron.sh --remove-dry-run lists nothing for it" "" "$CRON_OUT"

run_install bash "$co/manual-setup/uninstall-cron.sh"
assert_eq "an unrecognisable line makes the uninstall exit non-zero" "1" "$CRON_STATUS"
assert_contains "and warns that the job is still installed" "is still installed" "$CRON_OUT"
assert_contains "and says how to remove it" "crontab -e" "$CRON_OUT"
assert_eq "and the line is left exactly as it was" "$edited" "$(cron_text)"

# The same line with --purge-logs and no terminal. The refusal names what the run
# did to the job, and it used to say "The cron job was removed" -- directly under
# the WARNING that it was still installed -- because --remove exits 0 when it
# leaves a line it does not recognise.
mkdir -p "$d/logs"; touch "$d/logs/2026-01-01.log"
CRON_OUT="$(RECONNECT_LOG_DIR="$d/logs" bash "$co/manual-setup/uninstall-cron.sh" --purge-logs < /dev/null 2>&1)"
CRON_STATUS=$?
assert_eq "a surviving line with --purge-logs and no terminal exits non-zero" \
    "1" "$CRON_STATUS"
assert_contains "and the refusal says a line is still installed" \
    "A cron line is still installed" "$CRON_OUT"
assert_not_contains "rather than claiming the job was removed" \
    "The cron job was removed" "$CRON_OUT"
assert_exists "and the logs are kept" "$d/logs/2026-01-01.log"

# Another checkout whose absolute path *ends in* this one's -- /home/u/ir
# inside /mnt/backup/home/u/ir. The path used to be matched as a bare
# substring, so an uninstall from the shorter checkout claimed the other job,
# exited 1 declaring it "still installed", and with --purge-logs read the other
# job's log directory off its line and deleted its logs. The path is matched
# quoted or as a whole word now, the rule install-cron.sh's ours() applies.
d="$(new_case)"
short_co="$d/ir"
long_co="$d/backup$d/ir"
copy_checkout_into "$short_co"
copy_checkout_into "$long_co"
export CRONTAB_FILE="$d/crontab.txt"
: > "$CRONTAB_FILE"
mkdir -p "$d/long-logs"; touch "$d/long-logs/2026-01-01.log"
run_install env RECONNECT_LOG_DIR="$d/long-logs" bash "$long_co/manual-setup/install-cron.sh"
long_line="$(cron_text)"
assert_contains "the fixture's only job belongs to the longer checkout" \
    "'$long_co/reconnect.sh'" "$long_line"

run_install bash "$short_co/manual-setup/uninstall-cron.sh" --purge-logs --yes
assert_eq "an uninstall from the shorter checkout finds nothing of its own" \
    "0" "$CRON_STATUS"
assert_contains "and says so" "No cron job found" "$CRON_OUT"
assert_not_contains "rather than calling the other job still installed" \
    "is still installed" "$CRON_OUT"
assert_exists "and the other job's logs are not purged" "$d/long-logs/2026-01-01.log"
assert_eq "and the other job is left in place" "$long_line" "$(cron_text)"

# The control, and it is what stops the fix being "match nothing": the longer
# checkout still finds and removes its own job, and a line of ours that a
# hand-edit unquoted is still reported -- D7's looseness is kept.
run_install bash "$long_co/manual-setup/uninstall-cron.sh"
assert_eq "the longer checkout still removes its own job" \
    "0" "$(cron_count 'InternetReconnector')"
printf "*/5 * * * * PATH=/usr/bin %s/reconnect.sh >/dev/null 2>&1 # InternetReconnector\n" \
    "$short_co" > "$CRONTAB_FILE"
run_install bash "$short_co/manual-setup/uninstall-cron.sh" --dry-run
assert_contains "and a hand-unquoted line of ours is still found" \
    "Would remove the cron job" "$CRON_OUT"

# A machine with no cron at all. "There is no cron job to remove" is the same
# situation an ordinary second uninstall reports with exit 0, so answering it
# with exit 1 because `crontab` is absent made the two halves of one answer
# disagree -- a script driving the uninstall could not tell "nothing to do" from
# "the removal failed". Exiting there also abandoned --purge-logs, which needs no
# crontab at all.
#
# PATH is rebuilt from wrappers that exec the real binary by absolute path -- the
# same trick the date-preflight and missing-nmcli tests use, and the only way to
# drop one command without losing the rest.
nocrontab="$TMP/no-crontab"
mkdir -p "$nocrontab"
nocrontab_ok=1
[ -n "$real_bash" ] || nocrontab_ok=0
for tool in bash cat rm mktemp grep; do
    real_tool="$(command -v "$tool" || true)"
    if [ -z "$real_tool" ]; then
        nocrontab_ok=0
        continue
    fi
    printf '#!%s\nexec %s "$@"\n' "$real_bash" "$real_tool" > "$nocrontab/$tool"
    chmod +x "$nocrontab/$tool"
done

if [ "$nocrontab_ok" -ne 1 ]; then
    printf '  skip no-crontab test: could not build a PATH without crontab\n'
else
    d="$(new_case)"; co="$(new_checkout "$d")"
    export CRONTAB_FILE="$d/crontab.txt"
    : > "$CRONTAB_FILE"
    touch "$d/logs/2026-01-01.log" "$d/logs/.lock"

    run_install env PATH="$nocrontab" RECONNECT_LOG_DIR="$d/logs" \
        bash "$co/manual-setup/uninstall-cron.sh"
    assert_eq "no crontab command is nothing to remove, not a failed removal" \
        "0" "$CRON_STATUS"
    assert_contains "and the run says which of the two it is" \
        "crontab not found" "$CRON_OUT"
    assert_not_contains "and does not send you to a crontab -l it just said is absent" \
        "Verify with:" "$CRON_OUT"

    # The purge needs no crontab, so it must still happen rather than being
    # abandoned along with the crontab work.
    run_install env PATH="$nocrontab" RECONNECT_LOG_DIR="$d/logs" \
        bash "$co/manual-setup/uninstall-cron.sh" --purge-logs --yes
    assert_eq "--purge-logs still succeeds without a crontab" "0" "$CRON_STATUS"
    assert_missing "and the daily log is gone" "$d/logs/2026-01-01.log"
    assert_missing "and so is the lock file" "$d/logs/.lock"

    # `rm` is preflighted only where it is used, by the same rule as mktemp and
    # grep. Both its call sites are conditional -- read_crontab()'s temporary
    # file, and the purge -- so a run with no crontab and no --purge-logs never
    # invokes it. Checked unconditionally it turned that run into a failed one:
    # exit 1 with "rm not found" where the answer is "there is nothing to
    # remove" and exit 0, which is the very distinction the no-crontab handling
    # above exists to preserve.
    norm="$TMP/no-rm"
    mkdir -p "$norm"
    norm_ok=1
    for tool in bash cat mktemp grep; do
        real_tool="$(command -v "$tool" || true)"
        if [ -z "$real_tool" ]; then
            norm_ok=0
            continue
        fi
        printf '#!%s\nexec %s "$@"\n' "$real_bash" "$real_tool" > "$norm/$tool"
        chmod +x "$norm/$tool"
    done

    if [ "$norm_ok" -ne 1 ]; then
        printf '  skip no-rm test: could not build a PATH without rm\n'
    else
        d="$(new_case)"; co="$(new_checkout "$d")"
        touch "$d/logs/2026-01-01.log"

        run_install env PATH="$norm" RECONNECT_LOG_DIR="$d/logs" \
            bash "$co/manual-setup/uninstall-cron.sh"
        assert_eq "a run with nothing to remove does not need rm" "0" "$CRON_STATUS"
        assert_contains "and reports what it found, not a missing tool" \
            "crontab not found" "$CRON_OUT"
        assert_not_contains "rather than refusing over rm" "rm not found" "$CRON_OUT"

        # Nor does a dry run, and that half was missed the first time this gate
        # was narrowed: `--purge-logs` alone was let through the condition, so
        # `--purge-logs --dry-run` still refused -- even though a dry run exits
        # before the purge block, deletes nothing and calls no `rm`. Refusing to
        # *describe* what would be removed, over the command that would have done
        # the removing, is the same defect one flag further along. The rule needed
        # two steps and had been given one.
        run_install env PATH="$norm" RECONNECT_LOG_DIR="$d/logs" \
            bash "$co/manual-setup/uninstall-cron.sh" --purge-logs --dry-run
        assert_eq "--purge-logs --dry-run does not need rm either" "0" "$CRON_STATUS"
        assert_contains "and still reports what it would delete" \
            "Would delete 1 log file(s)" "$CRON_OUT"
        assert_not_contains "rather than refusing over rm" "rm not found" "$CRON_OUT"
        assert_exists "and the log it described is untouched" \
            "$d/logs/2026-01-01.log"

        # Nor does a purge that has nothing to purge, which is where the third
        # instance of this defect lived. The gate had been widened twice -- once
        # for `--purge-logs`, once for `--dry-run` -- and each widening left the
        # same failure one step further on, because a condition written before
        # the log directory is scanned can only guess at whether there is
        # anything to delete. With no crontab and no `rm`, `--purge-logs --yes`
        # over an empty log directory exited 1 with "rm not found" where the
        # answer is "crontab not found ..." followed by "No daily logs to delete"
        # and exit 0 -- a run with nothing to do reported as a failed one, which
        # is the single distinction the have_crontab handling exists to preserve.
        # The check is split rather than widened again: the crontab half stays up
        # front, the purge half asks the scan.
        #
        # A case of its own, because every fixture above has a log file in it and
        # that is exactly what hides this.
        empty_case="$(new_case)"
        run_install env PATH="$norm" RECONNECT_LOG_DIR="$empty_case/logs" \
            bash "$co/manual-setup/uninstall-cron.sh" --purge-logs --yes
        assert_eq "a purge with nothing to purge does not need rm" "0" "$CRON_STATUS"
        assert_contains "and says there was nothing to delete" \
            "No daily logs to delete" "$CRON_OUT"
        assert_not_contains "rather than refusing over rm" "rm not found" "$CRON_OUT"
        assert_contains "and still reports the crontab situation" \
            "crontab not found" "$CRON_OUT"

        # The lock file on its own is a purge target, so it must bring the check
        # back even with no daily logs -- otherwise the split gate would have
        # narrowed the rule past what it protects.
        touch "$empty_case/logs/.lock"
        run_install env PATH="$norm" RECONNECT_LOG_DIR="$empty_case/logs" \
            bash "$co/manual-setup/uninstall-cron.sh" --purge-logs --yes
        assert_eq "a lone lock file still needs rm" "1" "$CRON_STATUS"
        assert_contains "and says which command is missing" "rm not found" "$CRON_OUT"
        assert_exists "and the lock file it could not delete is still there" \
            "$empty_case/logs/.lock"

        # Still required where it is actually used, so the guard narrows the
        # check rather than deleting it.
        run_install env PATH="$norm" RECONNECT_LOG_DIR="$d/logs" \
            bash "$co/manual-setup/uninstall-cron.sh" --purge-logs --yes
        assert_eq "--purge-logs without rm is refused" "1" "$CRON_STATUS"
        assert_contains "and says which command is missing" "rm not found" "$CRON_OUT"
        assert_exists "and the log it could not delete is still there" \
            "$d/logs/2026-01-01.log"
    fi
fi

# =============================================================================
section "auto-setup.sh"
# =============================================================================
# The interactive front end: it asks for the four config.env settings and the
# interval, writes the file, runs reconnect.sh once to check the answers, and
# only then shells out to install-cron.sh.
#
# Driven by piping the answers in. `read -p` shows its prompt only when input is
# a terminal, so nothing here can assert on prompt text -- the observables are
# the file it writes, the crontab it produces, the exit status, and the lines it
# prints with `echo`, which are unconditional. That is a stronger set to assert
# on anyway: they are what the script *did*, not what it said it would do.
#
# ANSWERS are, in order: SSID, password, interface, hidden, interval.
run_setup() {
    local dir="$1"
    shift
    # `%b` rather than `%s`: an answer that is deliberately blanks-only has to be
    # written as an escape, because trailing spaces in this file would not
    # survive the first editor to strip them and the case would quietly stop
    # testing what it names.
    CRON_OUT="$(printf '%b' "$1" | "${@:2}" 2>&1)"
    CRON_STATUS=$?
    SETUP_CONFIG="$dir/config.env"
}
SETUP_CONFIG=""

# The value of $1 as reconnect.sh's own parser would read it back out of the
# config file, so an assertion is about what the scheduled job will actually see
# rather than about the bytes auto-setup.sh happened to write.
config_setting() {
    sed -n "s/^$1=\"\\(.*\\)\"\$/\\1/p" "$SETUP_CONFIG" | head -n 1
}

d="$(new_case)"; co="$(new_checkout "$d")"
export CRONTAB_FILE="$d/crontab.txt"
: > "$CRONTAB_FILE"
export NM_DEVICES="wlan0|wifi
eth0|ethernet
wlan1|wifi"

# A complete run, with the interface chosen by number off the offered list.
run_setup "$co" 'MyNet
hunter2
2
no
10
' env NM_ACTIVE_PROFILE="MyNet" NM_PROFILES="MyNet|MyNet" bash "$co/auto-setup.sh"
assert_eq "a full setup succeeds" "0" "$CRON_STATUS"
assert_eq "the SSID is written" "MyNet" "$(config_setting WIFI_SSID)"
assert_eq "the password is written" "hunter2" "$(config_setting WIFI_PASSWORD)"
assert_eq "picking '2' selects the second *Wi-Fi* device, not the second device" \
    "wlan1" "$(config_setting WIFI_IFACE)"
assert_eq "the hidden flag is written" "no" "$(config_setting WIFI_HIDDEN)"
assert_eq "and the cron job is installed exactly once" \
    "1" "$(cron_count 'InternetReconnector$')"
assert_contains "at the interval that was asked for" "*/10 * * * *" "$(cron_text)"
assert_contains "and the run says it tested the settings first" \
    "Testing the settings" "$CRON_OUT"

# The password must not reach the terminal at any point: it is read with -s, and
# the summary reports only that one is set. This is the property SECURITY.md and
# the house style both name, checked on the one script that handles the password
# as a value rather than passing it through.
#
# Two halves, because a pipe can only see one of them. The output assertion
# pins that the script never *prints* the password. It cannot see terminal
# echo -- stdin here is a pipe, and `read -s` changes nothing on a pipe -- so
# with `-s` deleted it stayed green (measured: 742 passed, 0 failed). The echo
# half is pinned on the source instead: the password prompt must be read with
# `-s`. A shape check is the level this can be observed at without a pty.
assert_not_contains "the password is never printed in the output" "hunter2" "$CRON_OUT"
assert_contains "the summary says a password is set without showing it" \
    "WIFI_PASSWORD (set, not shown)" "$CRON_OUT"
password_read="$(grep -c 'read -r -s -p "Wi-Fi password: "' "$AUTOSETUP")"
assert_eq "and the password prompt is read with -s, so the terminal does not echo it" \
    "1" "$password_read"

# Blanks are meaningful in both of these and must survive exactly. `read` strips
# leading and trailing blanks with the default IFS, so without `IFS=` a password
# typed with a padding space was silently stored without it and then rejected by
# the access point, with nothing saying the script had altered it. An SSID padded
# with spaces is legal here for the same reason config_value() preserves one:
# the suite already pins that end of it.
d="$(new_case)"; co="$(new_checkout "$d")"
export CRONTAB_FILE="$d/crontab.txt"; : > "$CRONTAB_FILE"
run_setup "$co" ' pad me
 spaced pw
wlan0
no
5
' env NM_ACTIVE_PROFILE=" pad me " NM_PROFILES=" pad me | pad me " bash "$co/auto-setup.sh"
assert_eq "an SSID's surrounding blanks are preserved" " pad me" "$(config_setting WIFI_SSID)"
assert_eq "and so are a password's" " spaced pw" "$(config_setting WIFI_PASSWORD)"

# A value full of characters a shell would act on. config.env is parsed rather
# than sourced, and auto-setup.sh writes every value inside double quotes, so
# these have to arrive at nmcli byte-for-byte. Asserted on the argv reconnect.sh
# builds rather than on the file, because the file is only half the round trip.
d="$(new_case)"; co="$(new_checkout "$d")"
export CRONTAB_FILE="$d/crontab.txt"; : > "$CRONTAB_FILE"
: > "$d/nmcli-args"
# The password below is single-quoted on purpose: every character in it has to
# arrive at nmcli literally, which is the whole point of this case.
# shellcheck disable=SC2016
run_setup "$co" 'Tricky
a"b$c`d#e
wlan0
no
5
' env NM_ACTIVE_PROFILE="Other" NM_PROFILES="" NM_SCAN="Tricky" \
    NM_ARGS_LOG="$d/nmcli-args" RECONNECT_SCAN_WAIT_SECS=0 \
    RECONNECT_CONNECT_ATTEMPTS=1 bash "$co/auto-setup.sh"
# shellcheck disable=SC2016
assert_contains "a password of shell metacharacters reaches nmcli intact" \
    'password a"b$c`d#e ' "$(cat "$d/nmcli-args")"
# shellcheck disable=SC2016
assert_not_contains "and is still never printed in the output" 'a"b$c' "$CRON_OUT"
# The control for the not-tried note: here the run had to connect with the
# password form, so the password *was* tried and the note would be false.
assert_not_contains "a run that connected with the password does not call it untried" \
    "was not tried" "$CRON_OUT"

# An empty password is the documented answer for anyone relying on a saved
# NetworkManager profile, and it has to stay empty rather than becoming the
# string "empty" or prompting again.
d="$(new_case)"; co="$(new_checkout "$d")"
export CRONTAB_FILE="$d/crontab.txt"; : > "$CRONTAB_FILE"
run_setup "$co" 'MyNet

wlan0
no
5
' env NM_ACTIVE_PROFILE="MyNet" NM_PROFILES="MyNet|MyNet" bash "$co/auto-setup.sh"
assert_eq "a skipped password succeeds" "0" "$CRON_STATUS"
assert_eq "and is stored as empty" "" "$(config_setting WIFI_PASSWORD)"
assert_contains "and the run says which route that takes" \
    "saved NetworkManager profile" "$CRON_OUT"
assert_not_contains "and with no password there is no untried-password note" \
    "was not tried" "$CRON_OUT"

# Enter on the interface question is the ordinary "let NetworkManager pick"
# answer and must produce an empty setting, not the first device on the list.
d="$(new_case)"; co="$(new_checkout "$d")"
export CRONTAB_FILE="$d/crontab.txt"; : > "$CRONTAB_FILE"
run_setup "$co" 'MyNet
pw

no
5
' env NM_ACTIVE_PROFILE="MyNet" NM_PROFILES="MyNet|MyNet" bash "$co/auto-setup.sh"
assert_eq "Enter on the interface question means automatic" "" "$(config_setting WIFI_IFACE)"

# That run found the machine already on MyNet -- no interface pinned, so the
# stub's active profile counts -- and the verification logged "Wifi Good"
# without reaching the connect: the password just typed was never tried. The
# README used to say a wrong password is caught here, and a wrong one was
# installed under "Settings work" with nothing to say it had not been used. The
# run says so now. (The first case in this section is not this one: it pins
# wlan1 while the stub's profile is active on wlan0, so it reconnects through
# the saved profile instead.) The controls are the runs where it must not.
assert_contains "an already-connected run says the typed password was not tried" \
    "the password you typed was not tried" "$CRON_OUT"
assert_contains "and still installs, since the settings it did use work" \
    "Settings work" "$CRON_OUT"
assert_not_contains "and the note does not repeat the password" "pw" \
    "$(printf '%s\n' "$CRON_OUT" | grep -A4 'NOTE: this machine is already on')"

# A device nmcli did not report can still be named, so the list is an offer
# rather than a restriction -- an adapter that is down appears nowhere in
# `nmcli device` and is exactly the case someone needs to type through.
d="$(new_case)"; co="$(new_checkout "$d")"
export CRONTAB_FILE="$d/crontab.txt"; : > "$CRONTAB_FILE"
run_setup "$co" 'MyNet
pw
wlan9
no
5
' env NM_ACTIVE_PROFILE="MyNet" NM_PROFILES="MyNet|MyNet" bash "$co/auto-setup.sh"
assert_eq "a device that is not on the list can still be typed" \
    "wlan9" "$(config_setting WIFI_IFACE)"

# ... and with no nmcli at all there is no list to offer, which must degrade to
# a typed name rather than failing. The adapter being down and nmcli being absent
# reach the same branch.
d="$(new_case)"; co="$(new_checkout "$d")"
export CRONTAB_FILE="$d/crontab.txt"; : > "$CRONTAB_FILE"
run_setup "$co" 'MyNet
pw
wlan0
no
5
' env NM_DEVICES="" NM_ACTIVE_PROFILE="MyNet" NM_PROFILES="MyNet|MyNet" \
    bash "$co/auto-setup.sh"
assert_eq "no detectable devices still lets a name be typed" \
    "wlan0" "$(config_setting WIFI_IFACE)"
assert_eq "and the setup still succeeds" "0" "$CRON_STATUS"

# An all-digit interface answer wider than bash can compare with. `[ "$iface"
# -ge 1 ]` printed a bare "integer expected" on stderr before the loop's own
# message -- the same bash diagnostic the 18-digit width rule keeps off the
# screen everywhere else, at the one numeric prompt that had no such rule. The
# interval prompt in this very script already guarded for it.
#
# The assertion is on the *absence* of the diagnostic and on the run finishing,
# not on the refusal: the refusal was never the part that was broken, and
# "There is no device ... in that list" was printed either way.
d="$(new_case)"; co="$(new_checkout "$d")"
export CRONTAB_FILE="$d/crontab.txt"; : > "$CRONTAB_FILE"
run_setup "$co" 'MyNet
pw
99999999999999999999999
1
no
5
' env NM_ACTIVE_PROFILE="MyNet" NM_PROFILES="MyNet|MyNet" bash "$co/auto-setup.sh"
assert_eq "an over-wide interface number is re-asked, not fatal" "0" "$CRON_STATUS"
assert_contains "and is refused like any other out-of-range number" \
    "There is no device 99999999999999999999999 in that list" "$CRON_OUT"
assert_not_contains "without leaking bash's own diagnostic" \
    "integer expected" "$CRON_OUT"
assert_eq "and the answer given next is the one that takes" \
    "wlan0" "$(config_setting WIFI_IFACE)"

# The other edge of the same rule, and it is the control: the width is measured
# after leading zeros are stripped, so a legal choice spelled with a long run of
# them still selects. Without this the guard could be "refuse anything long" and
# the assertions above would all still pass. `10#` on the subtraction is what
# makes it work -- bash reads a leading zero inside $(( )) as octal.
d="$(new_case)"; co="$(new_checkout "$d")"
export CRONTAB_FILE="$d/crontab.txt"; : > "$CRONTAB_FILE"
run_setup "$co" 'MyNet
pw
0000000000000000000002
no
5
' env NM_ACTIVE_PROFILE="MyNet" NM_PROFILES="MyNet|MyNet" bash "$co/auto-setup.sh"
assert_eq "leading zeros do not make an interface number too wide" \
    "wlan1" "$(config_setting WIFI_IFACE)"
assert_eq "and the setup completes" "0" "$CRON_STATUS"

# The boundary itself, which the two cases above leave unpinned. Both use an
# answer far past the rule -- 23 digits, and 22 leading zeros -- and an answer
# that far out is refused by *any* width rule this guard might drift to, so they
# establish that a rule exists and say nothing about where it draws its line.
# That is the same check-at-the-wrong-level-of-abstraction the environment
# override section describes for reconnect.sh and install-cron.sh, and it was
# measured here: widening this guard from 18 to 19 left the whole suite green
# while a 19-digit answer produced
# `auto-setup.sh: line NNN: [: 9999999999999999999: integer expected` -- the
# exact bash diagnostic the rule was added to keep off the screen.
#
# Nineteen digits is the value that matters: it is past intmax_t, so `-ge` is
# what refuses it once the width rule stops doing so. The assertion is on the
# absence of the diagnostic, not on the refusal, because the refusal is printed
# either way.
#
# Only this edge can be pinned here. Tightening the guard below 18 changes
# nothing observable at this prompt -- a width refusal and an out-of-range
# refusal print the same "There is no device ..." line -- so there is no
# assertion to write for it, and no defect either. The interval prompt below
# does pin both edges, because its two refusals word themselves differently.
d="$(new_case)"; co="$(new_checkout "$d")"
export CRONTAB_FILE="$d/crontab.txt"; : > "$CRONTAB_FILE"
run_setup "$co" 'MyNet
pw
9999999999999999999
1
no
5
' env NM_ACTIVE_PROFILE="MyNet" NM_PROFILES="MyNet|MyNet" bash "$co/auto-setup.sh"
assert_eq "a 19-digit interface number is refused, so the bound is not above 18" \
    "0" "$CRON_STATUS"
assert_contains "and is refused as out of range like any other number" \
    "There is no device 9999999999999999999 in that list" "$CRON_OUT"
assert_not_contains "with no bash diagnostic leaking out ahead of it" \
    "integer expected" "$CRON_OUT"
assert_eq "and the answer given next is the one that takes" \
    "wlan0" "$(config_setting WIFI_IFACE)"

# The two scripts this one drives are checked before the first question rather
# than at the point of use. reconnect.sh was not checked at all: a checkout
# missing it ran the whole interview, took the password, wrote config.env, and
# then reported "That did not work, so the cron job was NOT installed" with
# advice to correct a field -- none of which is true of a missing script.
# install-cron.sh was checked, but only after all of that had happened.
#
# Each case asserts that no config was written, which is what separates
# "refused before the interview" from "refused at the end": exit 1 alone cannot
# tell the two apart, and the second is what both used to do.
d="$(new_case)"; co="$(new_checkout "$d")"
export CRONTAB_FILE="$d/crontab.txt"; : > "$CRONTAB_FILE"
rm -f "$co/reconnect.sh"
run_setup "$co" 'MyNet
pw
wlan0
no
5
' env NM_ACTIVE_PROFILE="MyNet" NM_PROFILES="MyNet|MyNet" bash "$co/auto-setup.sh"
assert_eq "a checkout with no reconnect.sh is refused" "1" "$CRON_STATUS"
assert_contains "and says which script is missing" "reconnect.sh not found" "$CRON_OUT"
assert_missing "before the interview writes anything" "$co/config.env"
assert_not_contains "and does not blame the settings for it" \
    "That did not work" "$CRON_OUT"

d="$(new_case)"; co="$(new_checkout "$d")"
export CRONTAB_FILE="$d/crontab.txt"; : > "$CRONTAB_FILE"
rm -f "$co/manual-setup/install-cron.sh"
run_setup "$co" 'MyNet
pw
wlan0
no
5
' env NM_ACTIVE_PROFILE="MyNet" NM_PROFILES="MyNet|MyNet" bash "$co/auto-setup.sh"
assert_eq "a checkout with no install-cron.sh is refused too" "1" "$CRON_STATUS"
assert_contains "and names that one" "install-cron.sh not found" "$CRON_OUT"
assert_missing "and still writes nothing first" "$co/config.env"

# A UTF-8 BOM in front of the first key. reconnect.sh strips it on line 1 and
# reads the file perfectly well; existing_value() did not, so the *first* key
# came back mangled by three bytes nobody can see and no default was offered for
# it. A re-run then answered Enter with "The SSID is required" -- and driven
# from a pipe, as here, it re-asked until end of input and died.
#
# The fixture presses Enter at every prompt, so the SSID default is the only
# thing that can carry the run: if it is missing there is no answer to fall back
# on. That is what makes this assert the strip rather than assert around it.
d="$(new_case)"; co="$(new_checkout "$d")"
export CRONTAB_FILE="$d/crontab.txt"; : > "$CRONTAB_FILE"
printf '\xef\xbb\xbfWIFI_SSID="BomNet"\nWIFI_IFACE="wlan0"\nWIFI_HIDDEN="no"\n' \
    > "$co/config.env"
run_setup "$co" '




' env NM_ACTIVE_PROFILE="BomNet" NM_PROFILES="BomNet|BomNet" bash "$co/auto-setup.sh"
assert_eq "a config with a BOM is re-run without retyping anything" "0" "$CRON_STATUS"
assert_contains "the SSID behind the BOM is offered as the default and kept" \
    "BomNet" "$(config_setting WIFI_SSID)"
assert_not_contains "rather than being read as a missing SSID" \
    "The SSID is required" "$CRON_OUT"
assert_eq "and the other settings come across too" "wlan0" "$(config_setting WIFI_IFACE)"

# Bad answers are re-asked rather than fatal, because there is somebody present
# to ask. Each of these is followed by a good answer, so the run must finish.
d="$(new_case)"; co="$(new_checkout "$d")"
export CRONTAB_FILE="$d/crontab.txt"; : > "$CRONTAB_FILE"
# The two bad SSID answers are different arms and neither covers the other: an
# empty one is simply missing, while a blanks-only one is the value that passes
# an "is it empty?" test and then fails much later at the connect, which is why
# reconnect.sh refuses it and why this refuses it here rather than writing it.
run_setup "$co" '
   
MyNet
pw
wlan0
maybe
no
7
08
abc
20
' env NM_ACTIVE_PROFILE="MyNet" NM_PROFILES="MyNet|MyNet" bash "$co/auto-setup.sh"
assert_eq "a run full of re-prompts still finishes" "0" "$CRON_STATUS"
assert_contains "an empty SSID is refused as missing" \
    "The SSID is required" "$CRON_OUT"
assert_contains "a blanks-only SSID is refused with its own reason" \
    "nothing but blanks is refused" "$CRON_OUT"
assert_contains "an unparseable hidden answer is refused, quoting it" \
    "Answer yes or no; got: 'maybe'" "$CRON_OUT"
assert_contains "an interval that does not divide 60 is refused" \
    "divide 60 evenly" "$CRON_OUT"
assert_contains "and a non-numeric one is refused by name" \
    "A whole number of minutes; got: 'abc'" "$CRON_OUT"
assert_eq "the SSID that was finally accepted is the one written" \
    "MyNet" "$(config_setting WIFI_SSID)"
assert_contains "and the interval that was finally accepted is installed" \
    "*/20 * * * *" "$(cron_text)"

# The interval prompt's own 18-digit boundary, pinned on both edges -- which is
# possible here and not at the interface prompt, because the width refusal and
# the range refusal are worded differently and so are told apart by the message
# rather than by the exit status.
#
# 19 digits is past intmax_t. With the guard widened to 19 the value reached
# `$((10#$n))`, wrapped, and the range refusal reported
# `Between 1 and 59; got: '-8446744073709551617'` -- a negative number nobody
# typed, which is the message shape install-cron.sh's width-before-normalisation
# ordering exists to prevent, arriving in the script that copies that ordering.
# The whole suite stayed green while it did.
#
# 18 digits is the other edge: it must be refused by the *range* rule, which is
# what says the guard has not been tightened below 18 and started refusing
# values as too wide when they are merely too large.
d="$(new_case)"; co="$(new_checkout "$d")"
export CRONTAB_FILE="$d/crontab.txt"; : > "$CRONTAB_FILE"
run_setup "$co" 'MyNet
pw

no
9999999999999999999
999999999999999999
5
' env NM_ACTIVE_PROFILE="MyNet" NM_PROFILES="MyNet|MyNet" bash "$co/auto-setup.sh"
assert_eq "a run past both interval edges still finishes" "0" "$CRON_STATUS"
assert_contains "a 19-digit interval is refused by the width rule" \
    "Between 1 and 59, at most 18 digits; got: '9999999999999999999'" "$CRON_OUT"
assert_not_contains "rather than by a range check quoting what bash wrapped it to" \
    "-8446744073709551617" "$CRON_OUT"
assert_contains "an 18-digit interval is refused by the range check instead" \
    "Between 1 and 59; got: '999999999999999999'" "$CRON_OUT"
assert_contains "and the interval finally accepted is the one installed" \
    "*/5 * * * *" "$(cron_text)"

# MINUTES arriving from the environment skips the question above, and used to
# skip the rules with it: the value went to install-cron.sh unexamined, so
# `MINUTES=7 ./auto-setup.sh` announced "every 7 minutes", asked every question,
# took the password, wrote config.env, ran the verification, and only then
# failed on something it had been told at the start. Both paths go through
# check_interval() now, so the refusal is the same refusal and it arrives before
# anything is asked.
#
# The assertions are on config.env *not* existing and on the crontab being
# untouched, because exit 1 alone cannot tell "refused up front" from "refused
# at the end" -- and the second is what this used to do.
d="$(new_case)"; co="$(new_checkout "$d")"
export CRONTAB_FILE="$d/crontab.txt"; : > "$CRONTAB_FILE"
run_install env MINUTES=7 bash "$co/auto-setup.sh"
assert_eq "a MINUTES that does not divide 60 is refused" "1" "$CRON_STATUS"
assert_contains "with the same reason the typed answer gets" \
    "divide 60 evenly" "$CRON_OUT"
assert_contains "and it says which setting was wrong" "MINUTES:" "$CRON_OUT"
assert_missing "before the interview writes anything" "$co/config.env"
assert_eq "and nothing is installed" "0" "$(cron_count 'InternetReconnector')"

run_install env MINUTES=abc bash "$co/auto-setup.sh"
assert_eq "a non-numeric MINUTES is refused the same way" "1" "$CRON_STATUS"
assert_contains "quoting the value" "A whole number of minutes; got: 'abc'" "$CRON_OUT"

run_install env MINUTES=99999999999999999999 bash "$co/auto-setup.sh"
assert_eq "an over-wide MINUTES is refused too" "1" "$CRON_STATUS"
assert_contains "by the shared width rule" "at most 18 digits" "$CRON_OUT"

# RECONNECT_LOG_DIR is the other value passed straight through to
# install-cron.sh, and it was refused down there for the same reason -- at the
# end. It is checked beside RECONNECT_CONFIG now.
run_install env RECONNECT_LOG_DIR=mylogs bash "$co/auto-setup.sh"
assert_eq "a relative RECONNECT_LOG_DIR is refused up front" "1" "$CRON_STATUS"
assert_contains "with the reason cron makes it matter" "home directory" "$CRON_OUT"
assert_contains "and the value quoted" "got: 'mylogs'" "$CRON_OUT"
assert_missing "and nothing is written" "$co/config.env"

# A log directory that can never be created. reconnect.sh treats one it cannot
# create as a warning rather than a failure -- status() says so and carries on
# -- so the verification run passed over it, auto-setup.sh printed "Settings
# work", and the job it installed reconnected every interval without writing a
# line, with the warning going to /dev/null. Measured on Linux with the
# directory under a mode-555 parent. The check is on the nearest ancestor that
# exists, which is exactly what `mkdir -p` needs to be a writable directory.
#
# Two spellings. An ancestor that is a *file* is refused on any filesystem, so
# that case carries the refusal wherever the suite runs; the unwritable parent
# self-skips where directory modes are not enforced. Both are driven with a
# complete answer set and asserted on the interview never starting, since exit
# 1 is also what the old behaviour did not produce -- it exited 0.
printf 'not a directory\n' > "$d/afile"
run_setup "$co" 'MyNet
hunter2
wlan0
no
5
' env RECONNECT_LOG_DIR="$d/afile/logs" \
    NM_ACTIVE_PROFILE="MyNet" NM_PROFILES="MyNet|MyNet" bash "$co/auto-setup.sh"
assert_eq "a RECONNECT_LOG_DIR under a file is refused up front" "1" "$CRON_STATUS"
assert_contains "naming the ancestor that is in the way" \
    "RECONNECT_LOG_DIR cannot be created: $d/afile exists and is not a directory" "$CRON_OUT"
assert_not_contains "before the interview has printed a word" \
    "InternetReconnector setup" "$CRON_OUT"
assert_missing "and nothing is written" "$co/config.env"
assert_eq "and nothing is installed" "0" "$(cron_count 'InternetReconnector')"

ro_parent="$d/ro-parent"
mkdir -p "$ro_parent"
chmod 555 "$ro_parent" 2>/dev/null
if [ -w "$ro_parent" ]; then
    printf '  skip unwritable-log-parent setup test: this filesystem does not enforce the mode\n'
else
    run_setup "$co" 'MyNet
hunter2
wlan0
no
5
' env RECONNECT_LOG_DIR="$ro_parent/logs" \
        NM_ACTIVE_PROFILE="MyNet" NM_PROFILES="MyNet|MyNet" bash "$co/auto-setup.sh"
    assert_eq "a RECONNECT_LOG_DIR under an unwritable parent is refused up front" \
        "1" "$CRON_STATUS"
    assert_contains "naming the parent" \
        "RECONNECT_LOG_DIR cannot be created: $ro_parent is not writable" "$CRON_OUT"
    assert_not_contains "and asks nothing first" "InternetReconnector setup" "$CRON_OUT"
    assert_not_contains "rather than installing over a warning" "Settings work" "$CRON_OUT"
    assert_eq "and nothing is installed" "0" "$(cron_count 'InternetReconnector')"
fi
chmod 755 "$ro_parent" 2>/dev/null

# The control, and it is what stops the check being "the directory must
# exist": reconnect.sh creates a missing one on demand, so a directory that
# does not exist yet under a writable parent must still be accepted, and the
# verification run must then have created it and logged into it.
run_setup "$co" 'MyNet
hunter2
wlan0
no
5
' env RECONNECT_LOG_DIR="$d/fresh/logs" \
    NM_ACTIVE_PROFILE="MyNet" NM_PROFILES="MyNet|MyNet" bash "$co/auto-setup.sh"
assert_eq "a log directory that does not exist yet is still accepted" "0" "$CRON_STATUS"
assert_exists "and the verification run created it" "$d/fresh/logs"
assert_contains "and it reaches the cron line" "RECONNECT_LOG_DIR='$d/fresh/logs'" "$(cron_text)"
run_install bash "$co/manual-setup/install-cron.sh" --remove
rm -f "$co/config.env"

# The four numeric RECONNECT_* settings, which are the rest of what this script
# hands on without reading. They were the half of that rule left undone: MINUTES
# and RECONNECT_LOG_DIR were moved to the front and these were not, so
# `RECONNECT_CONNECT_ATTEMPTS=abc ./auto-setup.sh` still asked every question,
# took the Wi-Fi password and wrote config.env before reconnect.sh refused it at
# the verification run -- and the advice printed there then told the reader that
# "one field is wrong", which is untrue of an environment value.
#
# Asserted on no config.env existing, not on exit 1, for the reason the MINUTES
# block above gives: exit 1 alone cannot tell "refused up front" from "refused at
# the end", and the end is what this used to do.
#
# One assertion per bound, because the two mins are separate `case` arms in
# check_setting(): a wait that may be 0 and an attempts count that may not.
#
# This first case is driven with a *complete* set of answers rather than with no
# stdin at all, and that is not decoration. With no input the run dies at the
# first prompt on end-of-input, so `assert_missing` below holds whether the
# refusal came before the interview or not -- it passes for the wrong reason, and
# measured against the regression it does exactly that. Given every answer, a
# script that has stopped refusing up front completes the interview and writes
# the file, so the assertion has something to catch.
run_setup "$co" 'MyNet
hunter2
wlan0
no
5
' env RECONNECT_CONNECT_ATTEMPTS=abc NM_ACTIVE_PROFILE="MyNet" \
    NM_PROFILES="MyNet|MyNet" bash "$co/auto-setup.sh"
assert_eq "a non-numeric RECONNECT_CONNECT_ATTEMPTS is refused up front" \
    "1" "$CRON_STATUS"
assert_contains "with install-cron.sh's own wording for that setting" \
    "RECONNECT_CONNECT_ATTEMPTS must be a whole number >= 1; got: 'abc'" "$CRON_OUT"
assert_missing "before the interview writes anything" "$co/config.env"
assert_not_contains "and without blaming the answers for it" \
    "That did not work" "$CRON_OUT"

run_install env RECONNECT_CONNECT_ATTEMPTS=0 bash "$co/auto-setup.sh"
assert_eq "a zero RECONNECT_CONNECT_ATTEMPTS is refused up front too" \
    "1" "$CRON_STATUS"
assert_missing "and still writes nothing" "$co/config.env"

run_install env RECONNECT_NMCLI_WAIT_SECS=9000000000000000000 bash "$co/auto-setup.sh"
assert_eq "a 19-digit RECONNECT_* value is refused up front" "1" "$CRON_STATUS"
assert_contains "by the same 18-digit width rule the other scripts apply" \
    "at most 18 digits" "$CRON_OUT"
assert_missing "and writes nothing either" "$co/config.env"

run_install env RECONNECT_LOG_RETENTION_DAYS=abc bash "$co/auto-setup.sh"
assert_eq "the retention setting is covered as well" "1" "$CRON_STATUS"
assert_contains "with its own minimum of 0" \
    "RECONNECT_LOG_RETENTION_DAYS must be a whole number >= 0" "$CRON_OUT"

# The controls, and they are what stop this becoming "refuse every RECONNECT_*".
# Nothing may be refused here that install-cron.sh would have accepted: zero is
# legal for the two settings whose minimum is 0, an 18-digit value is inside the
# shared width rule, and a leading zero must not be read as octal or as width.
d="$(new_case)"; co="$(new_checkout "$d")"
export CRONTAB_FILE="$d/crontab.txt"; : > "$CRONTAB_FILE"
run_setup "$co" 'MyNet
pw

no
5
' env RECONNECT_SCAN_WAIT_SECS=0 RECONNECT_LOG_RETENTION_DAYS=0 \
    RECONNECT_CONNECT_ATTEMPTS=0000000000000000000003 \
    NM_ACTIVE_PROFILE="MyNet" NM_PROFILES="MyNet|MyNet" bash "$co/auto-setup.sh"
assert_eq "zero, and a leading-zero attempts count, are all still accepted" \
    "0" "$CRON_STATUS"
assert_eq "and the config is written" "MyNet" "$(config_setting WIFI_SSID)"
assert_contains "and the values reach the cron line intact" \
    "RECONNECT_CONNECT_ATTEMPTS='0000000000000000000003'" "$(cron_text)"

# The path this script writes to is checked before the interview too, and
# absolute was the only property of it that ever was. A RECONNECT_CONFIG naming a
# directory that does not exist -- or one that is itself a directory -- passed
# that check, took every question and the password, and died at the `: >` that
# creates the file. Same defect as the settings above, on the one value this
# script does not merely hand on.
d="$(new_case)"; co="$(new_checkout "$d")"
export CRONTAB_FILE="$d/crontab.txt"; : > "$CRONTAB_FILE"

# Driven with a complete set of answers, and asserted on the *interview* rather
# than on a config file, for two reasons that both come from measuring it. The
# exit status cannot discriminate here: with the check removed the run completes
# the interview and dies at the write, which is also exit 1. Nor can
# `assert_missing "$co/config.env"`, because with RECONNECT_CONFIG set the file
# would be written to $d/no-such-dir/ or $d/config-as-dir, never to $co --
# measured against the regression, three of the five assertions in this block
# passed with the guard deleted.
#
# `InternetReconnector setup` is the first thing this script prints, on the line
# immediately after the last of these checks, so its absence is exactly "nothing
# was asked". That is the same trap, and the same answer, as the complete answer
# set the numeric block above uses.
setup_answers='MyNet
hunter2
wlan0
no
5
'
run_setup "$co" "$setup_answers" env RECONNECT_CONFIG="$d/no-such-dir/config.env" \
    NM_ACTIVE_PROFILE="MyNet" NM_PROFILES="MyNet|MyNet" bash "$co/auto-setup.sh"
assert_eq "a config in a directory that does not exist is refused up front" \
    "1" "$CRON_STATUS"
assert_contains "and names the directory rather than the file" \
    "does not exist: $d/no-such-dir" "$CRON_OUT"
assert_not_contains "before the interview has printed a word" \
    "InternetReconnector setup" "$CRON_OUT"
assert_missing "and nothing was written where it was pointed" \
    "$d/no-such-dir/config.env"

mkdir -p "$d/config-as-dir"
run_setup "$co" "$setup_answers" env RECONNECT_CONFIG="$d/config-as-dir" \
    NM_ACTIVE_PROFILE="MyNet" NM_PROFILES="MyNet|MyNet" bash "$co/auto-setup.sh"
assert_eq "a config path that is a directory is refused up front" "1" "$CRON_STATUS"
assert_contains "and says it is not a regular file" "not a regular file" "$CRON_OUT"
assert_not_contains "and asks nothing first either" \
    "InternetReconnector setup" "$CRON_OUT"

# A config that exists and is writable but cannot be read. It is read twice
# before anything is written -- existing_value() offers each setting as a
# default, and the `cp` makes the .bak -- so -w on its own was not enough: the
# run printed "Its current settings are the defaults below", offered none, took
# the whole interview including the password, and died at the backup.
#
# Skipped where the filesystem does not enforce the mode, the same way the
# unreadable-config test in the reconnect.sh section is, because there the
# fixture is simply not unreadable and the assertion would be about the platform.
unreadable_cfg="$d/unreadable.env"
printf 'WIFI_SSID="Old"\n' > "$unreadable_cfg"
chmod 200 "$unreadable_cfg" 2>/dev/null
if [ -r "$unreadable_cfg" ]; then
    printf '  skip unreadable-config setup test: this filesystem does not enforce the mode\n'
else
    run_setup "$co" "$setup_answers" env RECONNECT_CONFIG="$unreadable_cfg" \
        NM_ACTIVE_PROFILE="MyNet" NM_PROFILES="MyNet|MyNet" bash "$co/auto-setup.sh"
    assert_eq "a writable but unreadable config is refused up front" "1" "$CRON_STATUS"
    assert_contains "and says it cannot read it" "cannot read $unreadable_cfg" "$CRON_OUT"
    assert_not_contains "before asking for anything" \
        "InternetReconnector setup" "$CRON_OUT"
fi
chmod 600 "$unreadable_cfg" 2>/dev/null

# A config that exists, and that the user can read and write, in a directory
# they cannot write. The backup is a third thing the run has to be able to
# write, and it is not the file: `cp` creates config.env.bak beside the config,
# which needs the directory. The three file checks passed such a config, the
# whole interview ran, the password was read, and the run died at the `cp` with
# "could not back up". Nothing was lost -- the copy fails before the truncation
# -- but the interview was, which is the thing the pre-interview block exists
# to save. Asserted on the interview never starting, since exit 1 is what both
# refusals produce.
#
# Skipped where the filesystem does not enforce a directory mode, the same way
# the unreadable-config cases are, because there the fixture is simply writable.
ro_dir="$d/ro-dir"
mkdir -p "$ro_dir"
printf 'WIFI_SSID="Old"\n' > "$ro_dir/config.env"
chmod 555 "$ro_dir" 2>/dev/null
if [ -w "$ro_dir" ]; then
    printf '  skip unwritable-directory setup test: this filesystem does not enforce the mode\n'
else
    run_setup "$co" "$setup_answers" env RECONNECT_CONFIG="$ro_dir/config.env" \
        NM_ACTIVE_PROFILE="MyNet" NM_PROFILES="MyNet|MyNet" bash "$co/auto-setup.sh"
    assert_eq "a config whose backup cannot be created is refused up front" \
        "1" "$CRON_STATUS"
    assert_contains "and names the backup as the thing that could not be written" \
        "so the backup $ro_dir/config.env.bak could not be created" "$CRON_OUT"
    assert_not_contains "before asking for anything" \
        "InternetReconnector setup" "$CRON_OUT"
    assert_eq "and the existing config is untouched" \
        "Old" "$(sed -n 's/^WIFI_SSID="\(.*\)"$/\1/p' "$ro_dir/config.env" | head -n 1)"

    # The exception the check allows for: a backup that already exists and can
    # be overwritten needs no directory permission, so the same directory with
    # a writable .bak in it must still be accepted. The .bak is created while
    # the directory is briefly writable, then the mode is put back.
    chmod 755 "$ro_dir" 2>/dev/null
    printf 'WIFI_SSID="Older"\n' > "$ro_dir/config.env.bak"
    chmod 555 "$ro_dir" 2>/dev/null
    run_setup "$co" "$setup_answers" env RECONNECT_CONFIG="$ro_dir/config.env" \
        NM_ACTIVE_PROFILE="MyNet" NM_PROFILES="MyNet|MyNet" bash "$co/auto-setup.sh"
    assert_eq "but an existing writable backup in that directory is still accepted" \
        "0" "$CRON_STATUS"
    assert_eq "and the backup holds the config as it stood" \
        "Old" "$(sed -n 's/^WIFI_SSID="\(.*\)"$/\1/p' "$ro_dir/config.env.bak" | head -n 1)"
fi
chmod 755 "$ro_dir" 2>/dev/null

# The control: an ordinary writable path in a directory that exists is untouched
# by all of that. Without it the two assertions above would pass just as well
# against a script that refused every RECONNECT_CONFIG.
mkdir -p "$d/good-dir"
run_setup "$co" 'MyNet
pw

no
5
' env RECONNECT_CONFIG="$d/good-dir/config.env" \
    NM_ACTIVE_PROFILE="MyNet" NM_PROFILES="MyNet|MyNet" bash "$co/auto-setup.sh"
assert_eq "a writable config path in an existing directory still works" \
    "0" "$CRON_STATUS"
assert_exists "and the config is written where it was asked for" \
    "$d/good-dir/config.env"

# The two path settings are handed straight to install-cron.sh, which refuses
# three characters in anything it writes onto a cron line: a single quote ends
# the quoting it wraps every value in, cron reads an unescaped '%' as a newline,
# and a line break ends the crontab record whatever quoting it sits inside.
# Absoluteness was the only one of those four rules copied here, and a value
# carrying one of the three is absolute -- so it passed, and the run then asked
# every question, read the Wi-Fi password, wrote config.env and ran the
# verification before install-cron.sh refused it at the very end. With
# RECONNECT_CONFIG the file, password included, was left on disk at a path that
# can never be installed.
#
# Asserted on the interview not having started, for the reason the block above
# gives: exit 1 is what both the up-front refusal and the refusal at the end
# produce. The wording is pinned too, because the point is that the two scripts
# refuse the same value with the same words rather than growing a second rule.
d="$(new_case)"; co="$(new_checkout "$d")"
export CRONTAB_FILE="$d/crontab.txt"; : > "$CRONTAB_FILE"

run_setup "$co" "$setup_answers" env RECONNECT_LOG_DIR="/tmp/it's" \
    NM_ACTIVE_PROFILE="MyNet" NM_PROFILES="MyNet|MyNet" bash "$co/auto-setup.sh"
assert_eq "a single quote in RECONNECT_LOG_DIR is refused up front" "1" "$CRON_STATUS"
assert_contains "with install-cron.sh's own wording" \
    "RECONNECT_LOG_DIR contains a single quote" "$CRON_OUT"
assert_not_contains "before the interview has printed a word" \
    "InternetReconnector setup" "$CRON_OUT"
assert_missing "and no config is written" "$co/config.env"

run_setup "$co" "$setup_answers" env RECONNECT_LOG_DIR='/tmp/100%' \
    NM_ACTIVE_PROFILE="MyNet" NM_PROFILES="MyNet|MyNet" bash "$co/auto-setup.sh"
assert_eq "a '%' in RECONNECT_LOG_DIR is refused up front" "1" "$CRON_STATUS"
assert_contains "and is named as cron's newline" \
    "which cron treats as a newline" "$CRON_OUT"
assert_not_contains "and asks nothing first" "InternetReconnector setup" "$CRON_OUT"

run_setup "$co" "$setup_answers" env RECONNECT_LOG_DIR=$'/tmp/ir\n*/1 * * * * /usr/bin/id' \
    NM_ACTIVE_PROFILE="MyNet" NM_PROFILES="MyNet|MyNet" bash "$co/auto-setup.sh"
assert_eq "a line break in RECONNECT_LOG_DIR is refused up front" "1" "$CRON_STATUS"
assert_contains "and says why quoting cannot help" \
    "contains a line break" "$CRON_OUT"
assert_not_contains "and asks nothing first" "InternetReconnector setup" "$CRON_OUT"

# RECONNECT_CONFIG is the worse of the two, because the file this script writes
# is the thing at that path: without the check the password was written to it
# and only then was the path refused. Asserted on the file, since here it is
# reachable and named.
run_setup "$co" "$setup_answers" env RECONNECT_CONFIG="$d/it's.env" \
    NM_ACTIVE_PROFILE="MyNet" NM_PROFILES="MyNet|MyNet" bash "$co/auto-setup.sh"
assert_eq "a single quote in RECONNECT_CONFIG is refused up front" "1" "$CRON_STATUS"
assert_contains "with the same wording again" \
    "RECONNECT_CONFIG contains a single quote" "$CRON_OUT"
assert_not_contains "and asks nothing first" "InternetReconnector setup" "$CRON_OUT"
assert_missing "so no password is left at a path that can never be installed" \
    "$d/it's.env"

# The controls, and they are what stop this becoming "refuse every path". A
# directory containing none of the three characters must still be honoured --
# including one with a space in it, which is quotable and which install-cron.sh
# accepts, so refusing it here would refuse a run that would have installed.
d="$(new_case)"; co="$(new_checkout "$d")"
export CRONTAB_FILE="$d/crontab.txt"; : > "$CRONTAB_FILE"
mkdir -p "$d/log dir"
run_setup "$co" "$setup_answers" env RECONNECT_LOG_DIR="$d/log dir" \
    NM_ACTIVE_PROFILE="MyNet" NM_PROFILES="MyNet|MyNet" bash "$co/auto-setup.sh"
assert_eq "a log directory containing a space is still accepted" "0" "$CRON_STATUS"
assert_contains "and reaches the cron line quoted" \
    "RECONNECT_LOG_DIR='$d/log dir'" "$(cron_text)"

# The other two values install-cron.sh vets with that same rule, which the block
# above did not cover: CRON_PATH, and this checkout's own install path.
#
# CRON_PATH is the reachable one -- it needs a single deliberately-set variable,
# and the README tells you to set it when nmcli lives outside the six standard
# directories. Measured before the fix: `CRON_PATH="/usr/bin:/opt/it's/bin"
# ./auto-setup.sh` asked every question, read the Wi-Fi password, wrote
# config.env and completed the verification run before install-cron.sh refused
# it -- and the advice it then printed, "fix the reason above and run
# ./install-cron.sh", could not be followed, because that script fails the same
# way until the variable changes.
#
# Asserted on the interview never starting, not on the exit status, for the
# reason the block above gives: exit 1 is what both the up-front refusal and the
# refusal at the end produce. The wording is pinned because the point is that
# both scripts refuse the same value with the same words.
d="$(new_case)"; co="$(new_checkout "$d")"
export CRONTAB_FILE="$d/crontab.txt"; : > "$CRONTAB_FILE"

run_setup "$co" "$setup_answers" env CRON_PATH="/usr/bin:/opt/it's/bin" \
    NM_ACTIVE_PROFILE="MyNet" NM_PROFILES="MyNet|MyNet" bash "$co/auto-setup.sh"
assert_eq "a single quote in CRON_PATH is refused up front" "1" "$CRON_STATUS"
assert_contains "with install-cron.sh's own wording" \
    "CRON_PATH contains a single quote" "$CRON_OUT"
assert_not_contains "before the interview has printed a word" \
    "InternetReconnector setup" "$CRON_OUT"
assert_missing "and no config is written" "$co/config.env"
assert_eq "and nothing is installed" "0" "$(cron_count 'InternetReconnector')"

run_setup "$co" "$setup_answers" env CRON_PATH='/usr/bin:/opt/100%/bin' \
    NM_ACTIVE_PROFILE="MyNet" NM_PROFILES="MyNet|MyNet" bash "$co/auto-setup.sh"
assert_eq "a '%' in CRON_PATH is refused up front" "1" "$CRON_STATUS"
assert_contains "and is named as cron's newline" \
    "which cron treats as a newline" "$CRON_OUT"
assert_not_contains "and asks nothing first" "InternetReconnector setup" "$CRON_OUT"

run_setup "$co" "$setup_answers" env CRON_PATH=$'/usr/bin\n*/1 * * * * /usr/bin/id' \
    NM_ACTIVE_PROFILE="MyNet" NM_PROFILES="MyNet|MyNet" bash "$co/auto-setup.sh"
assert_eq "a line break in CRON_PATH is refused up front" "1" "$CRON_STATUS"
assert_contains "and says why quoting cannot help" "contains a line break" "$CRON_OUT"
assert_not_contains "and asks nothing first" "InternetReconnector setup" "$CRON_OUT"

# The control, and it is what stops the check becoming "refuse every CRON_PATH".
# A legal one must still install and must still reach the line, because that is
# the whole reason the variable exists.
run_setup "$co" "$setup_answers" env CRON_PATH="/usr/bin:/opt/nm/bin" \
    NM_ACTIVE_PROFILE="MyNet" NM_PROFILES="MyNet|MyNet" bash "$co/auto-setup.sh"
assert_eq "a legal CRON_PATH is still accepted" "0" "$CRON_STATUS"
assert_contains "and still reaches the cron line" \
    "PATH='/usr/bin:/opt/nm/bin'" "$(cron_text)"

# The install path is the fourth value, and it is normally caught by accident:
# $CONFIG_FILE defaults to $SCRIPT_DIR/config.env, so a checkout under a hostile
# directory fails the RECONNECT_CONFIG check first. The gap needs
# RECONNECT_CONFIG pointed somewhere clean, which is why the fixture below does
# that -- without it this case would pass against a script that never looked at
# the install path at all.
#
# Self-skips where the filesystem will not take a directory named with a single
# quote, because there the fixture cannot be built and the assertion would be
# about the platform rather than about the code.
d="$(new_case)"
quoted_root="$d/it's"
if ! mkdir -p "$quoted_root" 2>/dev/null || [ ! -d "$quoted_root" ]; then
    printf '  skip quoted-install-path test: this filesystem will not take a directory named with a single quote\n'
else
    co="$(new_checkout "$quoted_root")"
    export CRONTAB_FILE="$d/crontab.txt"; : > "$CRONTAB_FILE"
    mkdir -p "$d/clean"

    run_setup "$co" "$setup_answers" env RECONNECT_CONFIG="$d/clean/config.env" \
        NM_ACTIVE_PROFILE="MyNet" NM_PROFILES="MyNet|MyNet" bash "$co/auto-setup.sh"
    assert_eq "a single quote in the install path is refused up front" "1" "$CRON_STATUS"
    assert_contains "with install-cron.sh's own wording for that one" \
        "the install path contains a single quote" "$CRON_OUT"
    assert_not_contains "before the interview has printed a word" \
        "InternetReconnector setup" "$CRON_OUT"
    assert_missing "so no password is written for a run that can never install" \
        "$d/clean/config.env"
    assert_eq "and nothing is installed" "0" "$(cron_count 'InternetReconnector')"

    # The same checkout with RECONNECT_CONFIG *unset*, which is the ordinary
    # case, and it pins the order of the two checks rather than their presence.
    # The default config path lives beside the script and so carries the same
    # quote, and both checks refuse it -- but only one of them names the cause.
    # With the config check first, the refusal read "RECONNECT_CONFIG contains a
    # single quote": a variable the user had never set, for a checkout the
    # message did not mention, and following it (pointing RECONNECT_CONFIG
    # somewhere clean) earned a second refusal for the same root cause. The
    # install path is vetted first now, so the checkout is named straight away,
    # exactly as install-cron.sh names it from the same directory. Both halves
    # are asserted: the right name present and the wrong one absent, because
    # either order produces exit 1 and stops before the interview.
    run_setup "$co" "$setup_answers" env NM_ACTIVE_PROFILE="MyNet" \
        NM_PROFILES="MyNet|MyNet" bash "$co/auto-setup.sh"
    assert_eq "a quoted checkout is refused up front with RECONNECT_CONFIG unset too" \
        "1" "$CRON_STATUS"
    assert_contains "and the refusal names the checkout path, which is the cause" \
        "the install path contains a single quote" "$CRON_OUT"
    assert_not_contains "rather than a RECONNECT_CONFIG the user never set" \
        "RECONNECT_CONFIG contains" "$CRON_OUT"
    assert_not_contains "and asks nothing first" "InternetReconnector setup" "$CRON_OUT"

    # The line-break spelling, which is the one that pins the *noun* in the
    # message. install-cron.sh says "leave the rest of the path" for the install
    # path and "leave the rest of the value" for CRON_PATH and every
    # RECONNECT_* setting, so check_cron_safe() takes the noun as an argument;
    # with that argument dropped this reads "value" and the two scripts stop
    # agreeing in the one case out of three where they differ. Nothing else in
    # this file would notice.
    #
    # Its own self-skip: a directory named with a newline is a stronger demand
    # on the filesystem than one named with a quote.
    nl_root="$d/$(printf 'ir\nline')"
    if ! mkdir -p "$nl_root" 2>/dev/null || [ ! -d "$nl_root" ]; then
        printf '  skip line-break-install-path test: this filesystem will not take a directory named with a newline\n'
    else
        co="$(new_checkout "$nl_root")"
        : > "$CRONTAB_FILE"
        run_setup "$co" "$setup_answers" env RECONNECT_CONFIG="$d/clean/config.env" \
            NM_ACTIVE_PROFILE="MyNet" NM_PROFILES="MyNet|MyNet" bash "$co/auto-setup.sh"
        assert_eq "a line break in the install path is refused up front" \
            "1" "$CRON_STATUS"
        assert_contains "and the message says 'the rest of the path', as install-cron.sh does" \
            "leave the rest of the path in the crontab" "$CRON_OUT"
        assert_not_contains "not 'the rest of the value', which is the other three" \
            "leave the rest of the value in the crontab" "$CRON_OUT"
        assert_not_contains "and it asks nothing first" \
            "InternetReconnector setup" "$CRON_OUT"
    fi

    # The control: a checkout path containing a space is quotable, and
    # install-cron.sh accepts it, so refusing it here would refuse a run that
    # would have installed. Same fixture shape, one character different.
    spaced_root="$d/has space"
    mkdir -p "$spaced_root"
    co="$(new_checkout "$spaced_root")"
    : > "$CRONTAB_FILE"
    run_setup "$co" "$setup_answers" env RECONNECT_CONFIG="$d/clean/config.env" \
        NM_ACTIVE_PROFILE="MyNet" NM_PROFILES="MyNet|MyNet" bash "$co/auto-setup.sh"
    assert_eq "an install path containing a space is still accepted" "0" "$CRON_STATUS"
    assert_contains "and reaches the cron line quoted" \
        "'$co/reconnect.sh'" "$(cron_text)"
fi

# The controls. Without these every assertion above would pass just as well
# against a script that refused every MINUTES and every RECONNECT_LOG_DIR.
d="$(new_case)"; co="$(new_checkout "$d")"
export CRONTAB_FILE="$d/crontab.txt"; : > "$CRONTAB_FILE"
run_setup "$co" 'MyNet
pw

no
' env MINUTES=10 NM_ACTIVE_PROFILE="MyNet" NM_PROFILES="MyNet|MyNet" \
    bash "$co/auto-setup.sh"
assert_eq "a legal MINUTES still skips the question and installs" "0" "$CRON_STATUS"
assert_contains "at the interval it names" "*/10 * * * *" "$(cron_text)"
assert_contains "and says it took the interval from MINUTES" \
    "Using the interval from MINUTES: every 10 minutes" "$CRON_OUT"

# A leading zero is legal and is normalised, so what the run announces is what
# install-cron.sh writes rather than the spelling that arrived.
d="$(new_case)"; co="$(new_checkout "$d")"
export CRONTAB_FILE="$d/crontab.txt"; : > "$CRONTAB_FILE"
run_setup "$co" 'MyNet
pw

no
' env MINUTES=05 NM_ACTIVE_PROFILE="MyNet" NM_PROFILES="MyNet|MyNet" \
    bash "$co/auto-setup.sh"
assert_eq "MINUTES=05 is accepted" "0" "$CRON_STATUS"
assert_contains "and announced as the 5 it normalises to" \
    "every 5 minutes" "$CRON_OUT"
assert_contains "and installed as */5" "*/5 * * * *" "$(cron_text)"

# Re-running to change one setting must not reset the others, and must not reset
# the interval either. Pressing Enter at the interval question passes an empty
# MINUTES to install-cron.sh, which reads that as "not set" and keeps what is on
# the line. Defaulting to 5 here instead looked identical and silently undid the
# carry-over previous_minutes() exists to provide -- the surprise being that the
# script that calls install-cron.sh reintroduced it one level up.
d="$(new_case)"; co="$(new_checkout "$d")"
export CRONTAB_FILE="$d/crontab.txt"; : > "$CRONTAB_FILE"
run_setup "$co" 'MyNet
hunter2
wlan0
no
10
' env NM_ACTIVE_PROFILE="MyNet" NM_PROFILES="MyNet|MyNet" bash "$co/auto-setup.sh"
assert_contains "the first run installs a 10-minute interval" "*/10 * * * *" "$(cron_text)"

run_setup "$co" '




' env NM_ACTIVE_PROFILE="MyNet" NM_PROFILES="MyNet|MyNet" bash "$co/auto-setup.sh"
assert_eq "a re-run of nothing but Enter succeeds" "0" "$CRON_STATUS"
assert_eq "the SSID is kept" "MyNet" "$(config_setting WIFI_SSID)"
assert_eq "the password is kept" "hunter2" "$(config_setting WIFI_PASSWORD)"
assert_eq "the interface is kept" "wlan0" "$(config_setting WIFI_IFACE)"
assert_contains "the interval is kept rather than reset to 5" \
    "*/10 * * * *" "$(cron_text)"
assert_contains "and the run says it kept the password rather than clearing it" \
    "Keeping the existing password" "$CRON_OUT"
assert_not_contains "and a kept password is not reported as one typed and untried" \
    "was not tried" "$CRON_OUT"
assert_exists "the previous config is preserved as a backup" "$co/config.env.bak"
# That backup is a copy of a file holding a password, and it is matched by
# neither of the patterns that cover the original: `config.env` is exact, and
# `*.env` does not match a name ending in `.bak`. So it needs ignore rules of its
# own, and this is what notices if one of them is ever removed.
#
# Matched as a glob rather than searched for as text. `assert_contains
# "config.env.bak" "$(cat .gitignore)"` was what stood here, and that is a check
# at the wrong level: it is satisfied by a comment mentioning the name, or by a
# `!config.env.bak` negation, and it says nothing at all about a backup kept
# under any other name. auto-setup.sh writes "$CONFIG_FILE.bak" for whatever
# RECONNECT_CONFIG names, so `wifi.env.bak` -- the `.bak` of exactly the "copy
# kept under a different name" case `*.env` exists for -- was left untracked but
# not ignored, holding the password in plaintext, and this assertion stayed
# green over it.
#
# Only bare filenames are asked about, so a shell `case` *is* fnmatch for every
# pattern that can match one. Negation is honoured the way git honours it: the
# file is read top to bottom and the *last* pattern that matches decides, with a
# `!` pattern deciding "not ignored". This matcher used to return at the first
# match and had no idea of `!`, under a comment saying the file had no negation
# in it -- true until `*.env.*` and `!*.env.example` were added, after which
# `*.env.*` matched config.env.example first and the control below failed on a
# .gitignore git itself reads correctly (`git check-ignore` says the example is
# not ignored). A red line blaming the ignore rules invites "fixing" them by
# deleting `*.env.*`, the rule that keeps hand-made copies of the password out.
#
# Directory patterns (`.idea/`, `.claude/settings.local.json`) are taken as
# globs too, which is harmless here: a pattern with a '/' in it cannot match the
# bare names asked about.
gitignored() {
    local line verdict=1 negated
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        case "$line" in '' | '#'*) continue ;; esac
        negated=0
        case "$line" in '!'*) negated=1; line="${line#!}" ;; esac
        # The pattern is unquoted on purpose: it is a glob, not a literal.
        # Matched, it sets the verdict -- 0 for ignored, 1 for re-included --
        # and the loop carries on, because a later line may overturn it.
        # shellcheck disable=SC2254
        case "$2" in $line) verdict="$negated" ;; esac
    done < "$1"
    return "$verdict"
}
ignore_verdict() {
    if gitignored "$1" "$2"; then printf 'ignored'; else printf 'not ignored'; fi
}
assert_eq "and the backup is gitignored, since it holds the same password" \
    "ignored" "$(ignore_verdict "$REPO_DIR/.gitignore" config.env.bak)"
assert_eq "so is the backup of a config kept under another name" \
    "ignored" "$(ignore_verdict "$REPO_DIR/.gitignore" wifi.env.bak)"
assert_eq "and that config itself, which is why the .bak needed covering too" \
    "ignored" "$(ignore_verdict "$REPO_DIR/.gitignore" wifi.env)"
# The rule the negation below overrides, held on its own: any other hand-made
# copy of a config. Without this, the example passing as "not ignored" could
# mean the matcher had stopped reading `*.env.*` rather than that `!` won.
assert_eq "and so is any other copy of a config, such as config.env.old" \
    "ignored" "$(ignore_verdict "$REPO_DIR/.gitignore" config.env.old)"
# The controls. Without them every assertion above would pass against a
# .gitignore that ignored the whole checkout, or against a matcher that always
# said yes.
assert_eq "while the example config is not ignored" \
    "not ignored" "$(ignore_verdict "$REPO_DIR/.gitignore" config.env.example)"
assert_eq "nor is a script" \
    "not ignored" "$(ignore_verdict "$REPO_DIR/.gitignore" reconnect.sh)"
assert_eq "and the backup is the file as it stood" \
    "MyNet" "$(sed -n 's/^WIFI_SSID="\(.*\)"$/\1/p' "$co/config.env.bak" | head -n 1)"

# The control for the block above: an explicit interval on a re-run still
# changes it, so "keep what is installed" has not become "ignore the answer".
run_setup "$co" '



15
' env NM_ACTIVE_PROFILE="MyNet" NM_PROFILES="MyNet|MyNet" bash "$co/auto-setup.sh"
assert_contains "an explicit interval on a re-run still changes it" \
    "*/15 * * * *" "$(cron_text)"

# On a re-run Enter keeps the stored password and interface, so it cannot also
# clear them, and nothing else could: the screen said "Leave empty (just press
# Enter) to let NetworkManager pick" and then kept the old device, and a stored
# password could never be taken out -- the route SECURITY.md recommends was
# closed to anyone who had used this before. '-' clears either one now. This
# checkout still holds hunter2 and wlan0 from the runs above; the list is
# offered, so this is the numbered-list prompt.
assert_eq "the fixture starts with a stored interface" "wlan0" "$(config_setting WIFI_IFACE)"
run_setup "$co" '\n-\n-\nno\n\n' env NM_ACTIVE_PROFILE="MyNet" NM_PROFILES="MyNet|MyNet" \
    bash "$co/auto-setup.sh"
assert_eq "a re-run answering '-' at both prompts succeeds" "0" "$CRON_STATUS"
assert_eq "and clears the stored password" "" "$(config_setting WIFI_PASSWORD)"
assert_contains "saying so" "Removing the stored password" "$CRON_OUT"
assert_eq "and the interface, back to automatic" "" "$(config_setting WIFI_IFACE)"
assert_contains "the screen says how, with a device set" "or type - to let" "$CRON_OUT"
assert_not_contains "rather than that Enter means automatic" \
    "Leave empty (just press Enter)" "$CRON_OUT"

# With no password stored, '-' still means "none" rather than the password '-',
# and the typed-name prompt (no device list) takes '-' the same way.
run_setup "$co" '\n-\nwlan0\nno\n\n' env NM_DEVICES="" NM_ACTIVE_PROFILE="MyNet" \
    NM_PROFILES="MyNet|MyNet" bash "$co/auto-setup.sh"
assert_eq "'-' with no stored password stores none" "" "$(config_setting WIFI_PASSWORD)"
assert_eq "and a typed interface is set again" "wlan0" "$(config_setting WIFI_IFACE)"
run_setup "$co" '\n\n-\nno\n\n' env NM_DEVICES="" NM_ACTIVE_PROFILE="MyNet" \
    NM_PROFILES="MyNet|MyNet" bash "$co/auto-setup.sh"
assert_eq "the typed-name prompt clears it with '-' too" "" "$(config_setting WIFI_IFACE)"

# The settings already on the installed cron line. install-cron.sh carries every
# RECONNECT_* value across a re-install, and this script resolved the same
# settings from the environment alone -- so after a manual install with a custom
# RECONNECT_CONFIG, a plain re-run looked for a config beside itself, found none,
# offered no defaults, wrote and verified <checkout>/config.env, printed
# "Settings work", and then re-installed a job still pointed at the other file,
# which nobody had tested and which had not changed. The verification log went
# to <checkout>/logs while the job's went to the directory on the line.
#
# The fixture is that exact sequence. Every assertion is on the *other* path:
# the config written there, the old value offered as a default and kept, the
# verification line landing in the line's log directory, and the checkout's
# own config.env and logs/ never being created.
d="$(new_case)"; co="$(new_checkout "$d")"
export CRONTAB_FILE="$d/crontab.txt"; : > "$CRONTAB_FILE"
mkdir -p "$d/etc"
printf 'WIFI_SSID="OldNet"\nWIFI_IFACE="wlan0"\n' > "$d/etc/config.env"
run_install env RECONNECT_CONFIG="$d/etc/config.env" RECONNECT_LOG_DIR="$d/etc/logs" \
    RECONNECT_CONNECT_ATTEMPTS=2 bash "$co/manual-setup/install-cron.sh"
assert_contains "the fixture's job names a config elsewhere" \
    "RECONNECT_CONFIG='$d/etc/config.env'" "$(cron_text)"
rm -rf "$co/logs"

run_setup "$co" '
hunter2



' env NM_ACTIVE_PROFILE="OldNet" NM_PROFILES="OldNet|OldNet" bash "$co/auto-setup.sh"
assert_eq "a plain re-run over a job with a custom config path succeeds" "0" "$CRON_STATUS"
assert_contains "and says it took the config path from the line" \
    "Using RECONNECT_CONFIG='$d/etc/config.env' from the installed cron job" "$CRON_OUT"
assert_contains "and the log directory" \
    "Using RECONNECT_LOG_DIR='$d/etc/logs' from the installed cron job" "$CRON_OUT"
# Under the script's own header, not above it: printed where they were
# collected, these were the first lines of the run, ahead of its title.
assert_contains "and those notes come after the script's header, not before it" \
    "InternetReconnector setup" "${CRON_OUT%%Using RECONNECT_CONFIG=*}"
assert_contains "and offers the config on that path as the current one" \
    "There is already a config at $d/etc/config.env" "$CRON_OUT"
SETUP_CONFIG="$d/etc/config.env"
assert_eq "the SSID from that file is kept as the default" "OldNet" "$(config_setting WIFI_SSID)"
assert_eq "and the new password is written into that file" "hunter2" "$(config_setting WIFI_PASSWORD)"
assert_exists "with its backup beside it" "$d/etc/config.env.bak"
assert_missing "and no config is written beside the script" "$co/config.env"
assert_exists "the verification run logged into the line's log directory" \
    "$d/etc/logs/$(date '+%Y-%m-%d').log"
assert_missing "and not into the checkout's" "$co/logs"
assert_contains "and the re-installed job still reads that config" \
    "RECONNECT_CONFIG='$d/etc/config.env'" "$(cron_text)"
assert_contains "and the tuning setting on the line is carried too" \
    "RECONNECT_CONNECT_ATTEMPTS='2'" "$(cron_text)"
assert_eq "as one job" "1" "$(cron_count 'InternetReconnector$')"

# The control: the environment still wins over the line, since that is the
# documented way to move a setting. Without this the block above would pass
# against a script that ignored the environment entirely.
#
# Five answers, the last an Enter for the interval. This fixture used to give
# four and run out of input at the interval prompt, and it passed only because
# end of input there was taken as "keep the default" -- the defect the
# end-of-input block below now pins.
mkdir -p "$d/new"
run_setup "$co" 'NewNet
pw



' env RECONNECT_CONFIG="$d/new/config.env" NM_ACTIVE_PROFILE="NewNet" \
    NM_PROFILES="NewNet|NewNet" bash "$co/auto-setup.sh"
assert_eq "an explicit RECONNECT_CONFIG still wins over the line" "0" "$CRON_STATUS"
assert_not_contains "and is not reported as taken from the line" \
    "Using RECONNECT_CONFIG=" "$CRON_OUT"
assert_exists "the config goes where the environment says" "$d/new/config.env"
assert_contains "and so does the job" "RECONNECT_CONFIG='$d/new/config.env'" "$(cron_text)"
SETUP_CONFIG="$d/etc/config.env"
assert_eq "while the line's old config is left alone" "OldNet" "$(config_setting WIFI_SSID)"

# Holding the notes until the header must not lose them on a run refused before
# the header: a refusal of a value carried off the line still has to say where
# that value came from, so die() prints any note still held.
d="$(new_case)"; co="$(new_checkout "$d")"
export CRONTAB_FILE="$d/crontab.txt"
printf "*/5 * * * * PATH='/usr/bin' RECONNECT_CONNECT_ATTEMPTS='nope' '%s/reconnect.sh' >/dev/null 2>&1 # InternetReconnector\n" \
    "$co" > "$CRONTAB_FILE"
run_setup "$co" "$setup_answers" env NM_ACTIVE_PROFILE="MyNet" \
    NM_PROFILES="MyNet|MyNet" bash "$co/auto-setup.sh"
assert_eq "a bad value carried off the line is refused up front" "1" "$CRON_STATUS"
assert_contains "and the refusal still says it came from the installed job" \
    "Using RECONNECT_CONNECT_ATTEMPTS='nope' from the installed cron job" "$CRON_OUT"
assert_not_contains "before the interview has printed a word" \
    "InternetReconnector setup" "$CRON_OUT"

# Another checkout whose absolute path ends in this one's. The line was matched
# on a bare substring of the path, so a plain run here adopted that job's
# RECONNECT_CONFIG and rewrote *its* config.env with these answers, exit 0.
d="$(new_case)"
short_co="$d/ir"
long_co="$d/backup$d/ir"
copy_checkout_into "$short_co"
copy_checkout_into "$long_co"
export CRONTAB_FILE="$d/crontab.txt"; : > "$CRONTAB_FILE"
mkdir -p "$d/long-etc"
printf 'WIFI_SSID="LongNet"\nWIFI_PASSWORD="long-secret"\n' > "$d/long-etc/config.env"
run_install env RECONNECT_CONFIG="$d/long-etc/config.env" \
    bash "$long_co/manual-setup/install-cron.sh"
run_setup "$short_co" "$setup_answers" env NM_ACTIVE_PROFILE="MyNet" \
    NM_PROFILES="MyNet|MyNet" bash "$short_co/auto-setup.sh"
assert_eq "a setup beside another checkout's job succeeds" "0" "$CRON_STATUS"
assert_not_contains "without taking that job's settings" \
    "from the installed cron job" "$CRON_OUT"
SETUP_CONFIG="$d/long-etc/config.env"
assert_eq "and that job's config is left alone" "long-secret" "$(config_setting WIFI_PASSWORD)"
assert_exists "and this checkout's own config is written" "$short_co/config.env"

# The marker is now written out three times. The two cron scripts are pinned
# against each other in their own section; this holds the third copy to them.
setup_marker="$(sed -n 's/^MARKER=\("[^"]*"\).*/\1/p' "$AUTOSETUP" | head -n 1)"
assert_eq "auto-setup.sh defines the same marker as install-cron.sh" \
    "$install_marker" "$setup_marker"

# The verification run is the point of the script. A configuration reconnect.sh
# rejects must stop before the crontab is touched: cron sends the job's stderr to
# /dev/null, so a job installed on bad settings announces itself only as FAIL in
# a log file, with the reason thrown away every interval.
d="$(new_case)"; co="$(new_checkout "$d")"
export CRONTAB_FILE="$d/crontab.txt"; : > "$CRONTAB_FILE"
run_setup "$co" 'Nowhere

wlan0
no
5
' env NM_ACTIVE_PROFILE="Other" NM_PROFILES="" NM_SCAN="" \
    RECONNECT_SCAN_WAIT_SECS=0 RECONNECT_CONNECT_ATTEMPTS=1 bash "$co/auto-setup.sh"
assert_eq "settings reconnect.sh rejects fail the setup" "1" "$CRON_STATUS"
assert_eq "and no cron job is installed" "0" "$(cron_count 'InternetReconnector')"
assert_contains "and it says so rather than leaving it to be inferred" \
    "was NOT installed" "$CRON_OUT"
assert_exists "while the config is kept, so one field can be corrected" \
    "$co/config.env"
assert_contains "and reconnect.sh's own reason is passed through" \
    "no saved NetworkManager profile" "$CRON_OUT"
# The advice under that reason must not assert a cause the run cannot know. It
# used to say the reason "usually means one field is wrong rather than all of
# them", which is true when reconnect.sh refused an answer -- as here -- and
# false for every other way it can refuse: a missing nmcli, awk or date, or an
# unwritable log directory. For those it sent the reader back through the
# interview to correct a field that was never wrong. Asserted on this fixture,
# where the old wording happened to be right, because that is the case where a
# revert would otherwise look harmless.
assert_contains "and the advice offers both readings of it" \
    "Read the reason above" "$CRON_OUT"
assert_contains "including the one where re-running is the answer" \
    "each current value is offered as the default" "$CRON_OUT"
assert_contains "and the one where it is not" \
    "would fail the same way" "$CRON_OUT"
assert_not_contains "rather than asserting a cause it cannot know" \
    "usually means one" "$CRON_OUT"
assert_contains "and with no job installed the answers are kept for the re-run" \
    "has been kept" "$CRON_OUT"
# The by-hand install it suggests carries the interval chosen at the prompt and
# the settings this run was given; a bare `./manual-setup/install-cron.sh` would
# have installed another interval and the default timeouts.
assert_contains "and the install it suggests carries the interval and settings of this run" \
    "MINUTES='5' RECONNECT_SCAN_WAIT_SECS='0' RECONNECT_CONNECT_ATTEMPTS='1' ./manual-setup/install-cron.sh" \
    "$CRON_OUT"

# A refused re-run over a job that is already installed. The config is written
# ahead of the verification, and the installed job reads that same file -- so a
# re-run refused as "the cron job was NOT installed" left the job it had not
# installed running on the refused settings: a working job logged FAIL from its
# next run on. A refusal puts the previous config back now, wherever a job of
# this checkout's is installed. Asserted on the file, on the crontab, and on the
# job itself still reconnecting with what it had.
d="$(new_case)"; co="$(new_checkout "$d")"
export CRONTAB_FILE="$d/crontab.txt"; : > "$CRONTAB_FILE"
run_setup "$co" 'MyNet\n\n\nno\n\n' env NM_ACTIVE_PROFILE="MyNet" NM_PROFILES="MyNet|MyNet" \
    bash "$co/auto-setup.sh"
assert_eq "the fixture starts with a working job installed" "1" "$(cron_count 'InternetReconnector$')"
installed_before="$(cron_text)"
run_setup "$co" 'MyNte\n\n\nno\n\n' env NM_ACTIVE_PROFILE="Other" NM_PROFILES="MyNet|MyNet" \
    NM_SCAN="MyNet" RECONNECT_SCAN_WAIT_SECS=0 RECONNECT_CONNECT_ATTEMPTS=1 bash "$co/auto-setup.sh"
assert_eq "a re-run whose verification fails over an installed job is refused" "1" "$CRON_STATUS"
assert_eq "and the installed job's config is put back" "MyNet" "$(config_setting WIFI_SSID)"
assert_contains "and the run says so" "has been put back" "$CRON_OUT"
assert_not_contains "rather than claiming the refused answers were kept" "has been kept" "$CRON_OUT"
assert_not_contains "nor suggesting an install that would schedule the old settings again" \
    "install the job directly" "$CRON_OUT"
assert_eq "and the cron line is untouched" "$installed_before" "$(cron_text)"
NM_ACTIVE_PROFILE="Other" NM_PROFILES="MyNet|MyNet" NM_SCAN="MyNet" run_reconnect "$co"
assert_eq "so the installed job still reconnects with the settings it had" \
    "Wifi Reconnected" "$RC_LOG"

# The lock-held spelling: the verification steps aside, so nothing was tested --
# and the job used to run on the password just typed. A stub flock that refuses
# stands in for the scheduled run holding the lock, so this runs on every host.
held_flock_bin="$TMP/held-flock-bin"
mkdir -p "$held_flock_bin"
printf '#!/usr/bin/env bash\nexit 1\n' > "$held_flock_bin/flock"
chmod +x "$held_flock_bin/flock"
run_setup "$co" '\nwrongpass\n\nno\n\n' env PATH="$held_flock_bin:$PATH" \
    NM_ACTIVE_PROFILE="Other" NM_PROFILES="MyNet|MyNet" NM_SCAN="MyNet" bash "$co/auto-setup.sh"
assert_contains "a skipped verification over an installed job is refused as untested" \
    "the settings were NOT tested" "$CRON_OUT"
assert_eq "and the untested password does not reach the job's config" "" \
    "$(config_setting WIFI_PASSWORD)"
assert_contains "and the run says the previous config was put back" "has been put back" "$CRON_OUT"

# A flock that cannot lock at all (exit 71, ENOLCK) is not "another run", so the
# verification must run and pass rather than being refused as untested on every
# attempt -- which on such a filesystem left no way to install through here.
d="$(new_case)"; co="$(new_checkout "$d")"
export CRONTAB_FILE="$d/crontab.txt"; : > "$CRONTAB_FILE"
run_setup "$co" "$setup_answers" env PATH="$errflock_bin:$PATH" \
    NM_ACTIVE_PROFILE="MyNet" NM_PROFILES="MyNet|MyNet" bash "$co/auto-setup.sh"
assert_eq "a flock that cannot lock does not refuse the setup" "0" "$CRON_STATUS"
assert_not_contains "as an untested run" "NOT tested" "$CRON_OUT"
assert_eq "and the job is installed" "1" "$(cron_count 'InternetReconnector$')"

# No config before, but a job installed -- the manual route in the "wrong" order.
# The job was finding no config; a refusal must not leave it a refused one.
d="$(new_case)"; co="$(new_checkout "$d")"
export CRONTAB_FILE="$d/crontab.txt"; : > "$CRONTAB_FILE"
run_install bash "$co/manual-setup/install-cron.sh"
run_setup "$co" 'Nowhere\n\n\nno\n\n' env NM_ACTIVE_PROFILE="Other" NM_PROFILES="" NM_SCAN="" \
    RECONNECT_SCAN_WAIT_SECS=0 RECONNECT_CONNECT_ATTEMPTS=1 bash "$co/auto-setup.sh"
assert_eq "a refused first setup over an installed job fails" "1" "$CRON_STATUS"
assert_missing "and removes the config again, as the job had none" "$co/config.env"
assert_contains "and says so" "removed again" "$CRON_OUT"

# The verification run is judged by the log line it writes, not by its exit
# status. reconnect.sh exits 0 when it finds its overlap lock held by another
# run -- it logs "Skipped (already running)" and never touches nmcli -- so a
# re-run of auto-setup.sh while the scheduled job was mid-run printed the
# "still in progress" note and then "Settings work. Installing the cron job..."
# and installed a job whose settings nobody had tested. That is exactly when
# somebody re-runs it (to fix a wrong password), and a failing run holds the
# lock for ~139 of every 300 seconds at the defaults. Measured on Linux with
# the lock held and a password nmcli refused: exit 0, one job installed.
#
# The lock is held the way the overlap section above holds it. The fixture is
# a *wrong* password, so the run would be refused if it were actually tested:
# that is what separates "refused because the skip was noticed" from "refused
# because the settings are bad", together with the message. Self-skips
# without flock, like the overlap section.
if ! command -v flock >/dev/null 2>&1; then
    printf '  skip lock-held setup test: this system has no flock\n'
else
    d="$(new_case)"; co="$(new_checkout "$d")"
    export CRONTAB_FILE="$d/crontab.txt"; : > "$CRONTAB_FILE"
    mkdir -p "$co/logs"; touch "$co/logs/.lock"
    exec 8>>"$co/logs/.lock"
    if ! flock -n 8; then
        exec 8>&-
        printf '  skip lock-held setup test: could not take the lock\n'
    else
        run_setup "$co" "$setup_answers" env NM_ACTIVE_PROFILE="Other" NM_PROFILES="" \
            NM_SCAN="MyNet" NM_CONNECT_RC=1 RECONNECT_SCAN_WAIT_SECS=0 \
            RECONNECT_CONNECT_ATTEMPTS=1 bash "$co/auto-setup.sh"
        exec 8>&-
        assert_eq "a verification run that stepped aside does not count as a pass" \
            "1" "$CRON_STATUS"
        assert_contains "and the run says the settings were not tested" \
            "the settings were NOT tested" "$CRON_OUT"
        assert_not_contains "rather than claiming they work" "Settings work" "$CRON_OUT"
        assert_eq "and no job is installed on untested settings" \
            "0" "$(cron_count 'InternetReconnector')"
        assert_exists "while the config is kept for the re-run" "$co/config.env"

        # The control: the same answers with the lock free are actually tested,
        # and refused for the real reason. Without this the assertions above
        # would pass against a script that refused every verification run.
        run_setup "$co" "$setup_answers" env NM_ACTIVE_PROFILE="Other" NM_PROFILES="" \
            NM_SCAN="MyNet" NM_CONNECT_RC=1 RECONNECT_SCAN_WAIT_SECS=0 \
            RECONNECT_CONNECT_ATTEMPTS=1 bash "$co/auto-setup.sh"
        assert_eq "with the lock free the same settings are tested and refused" \
            "1" "$CRON_STATUS"
        assert_contains "for the real reason" "That did not work" "$CRON_OUT"
        assert_not_contains "and not as a skipped test" "NOT tested" "$CRON_OUT"
    fi
fi

# The readback has to be *this run's* line, not whatever is last in the file.
# The first version took the last line, and reconnect.sh treats a day file it
# cannot append to as a warning and carries on -- so a stale line at the end of
# an unwritable file stood in for the run's outcome. With the lock held that
# reopened the exact hole the readback had just closed (a stale "Wifi Good"
# installed a wrong password under "Settings work"; measured on Linux), and a
# stale "FAIL" refused a run that had genuinely tested the settings. The run
# reports its own outcome through IR_OUTCOME_FILE now, written only once its
# day-file append succeeds, so neither stale line can stand in for it.
#
# A day file that is already unwritable when the setup starts -- what an earlier
# `sudo ./reconnect.sh` leaves -- is refused before the interview now, with the
# default log directory as much as with an explicit RECONNECT_LOG_DIR. It used
# to be found only after every question and the password, as a verification
# run that "wrote no new line". Asserted on the interview never starting and on
# no config.env, since exit 1 is also what the late refusal produced.
#
# The readback itself is then pinned with the file going unwritable *during*
# the run, which no pre-interview check can foresee: a stand-in nmcli makes the
# day file read-only on its first call, before reconnect.sh appends. Settings
# that would pass are used and the file carries a stale "Wifi Good", so the run
# must be refused as having written nothing -- which is where the old readback
# said "Settings work". Both self-skip where the filesystem does not enforce the
# mode.
d="$(new_case)"; co="$(new_checkout "$d")"
export CRONTAB_FILE="$d/crontab.txt"; : > "$CRONTAB_FILE"
mkdir -p "$co/logs"
stale_log="$co/logs/$(date '+%Y-%m-%d').log"
printf '[00:00:00] Wifi Good\n' > "$stale_log"
chmod 444 "$stale_log" 2>/dev/null
if [ -w "$stale_log" ]; then
    printf '  skip unwritable-day-file setup tests: this filesystem does not enforce the mode\n'
else
    run_setup "$co" "$setup_answers" env NM_ACTIVE_PROFILE="MyNet" \
        NM_PROFILES="MyNet|MyNet" bash "$co/auto-setup.sh"
    assert_eq "an unwritable day log in the default log directory is refused" \
        "1" "$CRON_STATUS"
    assert_contains "naming today's log file" \
        "today's log file $stale_log cannot be written to" "$CRON_OUT"
    assert_not_contains "before the interview has printed a word" \
        "InternetReconnector setup" "$CRON_OUT"
    assert_missing "and before config.env is written" "$co/config.env"
    assert_eq "and no job is installed" "0" "$(cron_count 'InternetReconnector')"

    chmod 644 "$stale_log" 2>/dev/null
    chmod_nmcli_bin="$TMP/chmod-nmcli-bin"
    mkdir -p "$chmod_nmcli_bin"
    cat > "$chmod_nmcli_bin/nmcli" <<'STUB'
#!/usr/bin/env bash
chmod 444 "$RACE_CHMOD_LOG" 2>/dev/null
exec "$RACE_REAL_NMCLI" "$@"
STUB
    chmod +x "$chmod_nmcli_bin/nmcli"
    run_setup "$co" "$setup_answers" env PATH="$chmod_nmcli_bin:$PATH" \
        RACE_CHMOD_LOG="$stale_log" RACE_REAL_NMCLI="$STUB_BIN/nmcli" \
        NM_ACTIVE_PROFILE="MyNet" NM_PROFILES="MyNet|MyNet" bash "$co/auto-setup.sh"
    assert_eq "a verification run that could not write its line is not a pass" \
        "1" "$CRON_STATUS"
    assert_contains "and the run says no new line was written" \
        "wrote no new line" "$CRON_OUT"
    assert_not_contains "rather than reading a stale line as this run's" \
        "Settings work" "$CRON_OUT"
    assert_eq "and no job is installed on it" "0" "$(cron_count 'InternetReconnector')"
    assert_exists "while the config is kept" "$co/config.env"
    rm -f "$co/config.env" "$co/config.env.bak"
fi
chmod 644 "$stale_log" 2>/dev/null

# The control, and it is what stops the readback becoming "refuse whenever the
# file already has lines in it": the same stale line in a *writable* file --
# a stale FAIL this time, the one that used to cause a wrong refusal -- must be
# passed over for the line this run appends after it, and the job installed.
printf '[00:00:00] FAIL\n' > "$stale_log"
: > "$CRONTAB_FILE"
run_setup "$co" "$setup_answers" env NM_ACTIVE_PROFILE="MyNet" \
    NM_PROFILES="MyNet|MyNet" bash "$co/auto-setup.sh"
assert_eq "a stale FAIL ahead of this run's line does not refuse the run" "0" "$CRON_STATUS"
assert_contains "and the settings are reported as working" "Settings work" "$CRON_OUT"
assert_eq "and the job is installed" "1" "$(cron_count 'InternetReconnector')"
assert_eq "with this run's line appended after the stale one" \
    "2" "$(grep -c . "$stale_log")"

# A default logs/ directory that exists but cannot be written, with
# RECONNECT_LOG_DIR unset: refused before the interview, and named as the log
# directory rather than as a RECONNECT_LOG_DIR the user never set. The check
# used to run only for an explicit RECONNECT_LOG_DIR.
d="$(new_case)"; co="$(new_checkout "$d")"
export CRONTAB_FILE="$d/crontab.txt"; : > "$CRONTAB_FILE"
mkdir -p "$co/logs"
chmod 555 "$co/logs" 2>/dev/null
if [ -w "$co/logs" ]; then
    printf '  skip unwritable-default-log-dir setup test: this filesystem does not enforce the mode\n'
else
    run_setup "$co" "$setup_answers" env NM_ACTIVE_PROFILE="MyNet" \
        NM_PROFILES="MyNet|MyNet" bash "$co/auto-setup.sh"
    assert_eq "an unwritable default log directory is refused" "1" "$CRON_STATUS"
    assert_contains "and named as the log directory" \
        "The log directory $co/logs exists but is not writable" "$CRON_OUT"
    assert_not_contains "not as a setting the user never set" \
        "RECONNECT_LOG_DIR" "$CRON_OUT"
    assert_not_contains "before the interview has printed a word" \
        "InternetReconnector setup" "$CRON_OUT"
    assert_missing "and before config.env is written" "$co/config.env"
fi
chmod 755 "$co/logs" 2>/dev/null

# Counting the lines first shut out stale lines but not *concurrent* ones: the
# installed job appends to the same day file, and the first line past the count
# was taken as this run's. Both directions are pinned, each with a stand-in for
# the scheduled job that writes into that file at the moment it would. The
# verification now reports its outcome through IR_OUTCOME_FILE, a path nothing
# else has, so neither line can stand in for it.
#
# First: the job finishes in the instant before the verification asks for the
# lock, so its "Wifi Good" is in the file while the lock is still held. The
# stand-in flock writes that line and refuses, which is what the verification
# then sees; it steps aside and never touches nmcli. The password is wrong, so
# "Settings work" here would be a wrong password installed untested. A stub
# flock rather than a real one, so this runs on every host.
# Each stand-in gets a directory of its own, so each case puts only one of them
# on PATH.
race_flock_bin="$TMP/race-flock-bin"
race_nmcli_bin="$TMP/race-nmcli-bin"
mkdir -p "$race_flock_bin" "$race_nmcli_bin"
cat > "$race_flock_bin/flock" <<'STUB'
#!/usr/bin/env bash
printf '[%s] Wifi Good\n' "$(date '+%H:%M:%S')" >> "$RACE_LOG_DIR/$(date '+%Y-%m-%d').log"
exit 1
STUB
cat > "$race_nmcli_bin/nmcli" <<'STUB'
#!/usr/bin/env bash
case "$*" in
    *"connection up id "*)
        printf '[%s] Skipped (already running)\n' "$(date '+%H:%M:%S')" \
            >> "$RACE_LOG_DIR/$(date '+%Y-%m-%d').log" ;;
esac
exec "$RACE_REAL_NMCLI" "$@"
STUB
chmod +x "$race_flock_bin/flock" "$race_nmcli_bin/nmcli"

d="$(new_case)"; co="$(new_checkout "$d")"
export CRONTAB_FILE="$d/crontab.txt"; : > "$CRONTAB_FILE"
mkdir -p "$co/logs"
run_setup "$co" "$setup_answers" env PATH="$race_flock_bin:$PATH" RACE_LOG_DIR="$co/logs" \
    NM_ACTIVE_PROFILE="Other" NM_PROFILES="" NM_SCAN="MyNet" NM_CONNECT_RC=1 \
    RECONNECT_SCAN_WAIT_SECS=0 RECONNECT_CONNECT_ATTEMPTS=1 bash "$co/auto-setup.sh"
assert_eq "another run's line ahead of a skipped verification is not a pass" \
    "1" "$CRON_STATUS"
assert_contains "and the run says the settings were not tested" \
    "the settings were NOT tested" "$CRON_OUT"
assert_not_contains "rather than installing them as working" "Settings work" "$CRON_OUT"
assert_eq "and no job is installed" "0" "$(cron_count 'InternetReconnector')"
assert_contains "the fixture really did put the other run's line first" \
    "Wifi Good" "$(head -n 1 "$co/logs/$(date '+%Y-%m-%d').log")"

# Second, the other way round: the job fires while the verification is
# connecting, steps aside, and its "Skipped (already running)" lands ahead of
# the verification's own "Wifi Reconnected". That verification did test the
# settings, so it must pass rather than be refused as untested.
d="$(new_case)"; co="$(new_checkout "$d")"
export CRONTAB_FILE="$d/crontab.txt"; : > "$CRONTAB_FILE"
mkdir -p "$co/logs"
run_setup "$co" "$setup_answers" env PATH="$race_nmcli_bin:$PATH" RACE_LOG_DIR="$co/logs" \
    RACE_REAL_NMCLI="$STUB_BIN/nmcli" NM_ACTIVE_PROFILE="Other" NM_PROFILES="MyNet|MyNet" \
    NM_SCAN="MyNet" RECONNECT_SCAN_WAIT_SECS=0 RECONNECT_CONNECT_ATTEMPTS=1 \
    bash "$co/auto-setup.sh"
assert_eq "another run's skip line during a verification that connected is not a refusal" \
    "0" "$CRON_STATUS"
assert_contains "and the settings are reported as working" "Settings work" "$CRON_OUT"
assert_not_contains "rather than as untested" "NOT tested" "$CRON_OUT"
assert_eq "and the job is installed" "1" "$(cron_count 'InternetReconnector$')"
assert_contains "the fixture really did put the skip line first" \
    "Skipped (already running)" "$(head -n 1 "$co/logs/$(date '+%Y-%m-%d').log")"

# End of input is a stated failure, not consent -- and the failure it replaces is
# worse than falling through to the defaults. Measured with auto-setup.sh's
# `|| die` removed: the run hangs. `read` returns failure at EOF without
# assigning, the SSID is the one prompt with no default so it re-asks, and
# re-asking reads EOF again, forever, printing nothing at all because `read -p`
# shows its prompt only on a terminal.
#
# So this one case is bounded, and that is not belt-and-braces. Every other
# assertion in this file reports a regression as a red line; this one, unbounded,
# reports it by hanging -- measured, the mutation ran the whole suite green up to
# here and then stopped dead, never reaching the summary, so CI would show a
# timeout with no failing assertion named. That is the same trap the IR_ARGV_PROBE
# guard was added for further up, and it gets the same answer: make the failure
# report itself. The bound has to be generous enough that a slow machine does not
# trip it, since a false failure here is worse than the slow feedback.
#
# `timeout` is not on the prerequisite list, because it is needed for exactly one
# assertion and refusing to run the whole suite without it would be the very
# "precondition on a path that does not use it" defect this file spends a section
# pinning. Where it is missing the case still runs, just unbounded and back to
# hanging on a regression, and it says so.
# The array carries `env` so that it is never empty, and that is not cosmetic:
# expanding an empty array as "${arr[@]}" under `set -u` is an unbound-variable
# error on bash before 4.4, which in a non-interactive shell ends the run. It
# would have fired on exactly the hosts that take the `else` branch below --
# bash 4.0-4.3 with no timeout(1) -- aborting the suite here with
# `eof_bound[@]: unbound variable` rather than running the rest of this section
# and the crontab-safety one. So the branch that reports the missing bound was
# also the branch that broke the run.
eof_bound=(env)
if command -v timeout >/dev/null 2>&1; then
    eof_bound=(timeout 60 env)
else
    printf '  note: no timeout(1) here, so the end-of-input case runs unbounded\n'
fi
d="$(new_case)"; co="$(new_checkout "$d")"
export CRONTAB_FILE="$d/crontab.txt"; : > "$CRONTAB_FILE"
run_setup "$co" '' "${eof_bound[@]}" NM_ACTIVE_PROFILE="MyNet" \
    NM_PROFILES="MyNet|MyNet" bash "$co/auto-setup.sh"
# 124 is timeout(1)'s "it was still running", which is the regression this case
# exists to catch. Named separately from any other non-1 status so the report
# says "it hung" rather than leaving a bare number to be looked up.
if [ "$CRON_STATUS" -eq 124 ]; then
    no "running out of input fails the setup" \
        "auto-setup.sh did not stop at end of input -- it hung until the bound" \
        "expected: exit 1 with a stated reason"
else
    assert_eq "running out of input fails the setup" "1" "$CRON_STATUS"
fi
assert_contains "and says what it was asking for at the time" \
    "no more input (end of file)" "$CRON_OUT"
assert_contains "and points at the by-hand route instead" "install-cron.sh" "$CRON_OUT"
assert_missing "and nothing is written" "$co/config.env"
assert_eq "and nothing is installed" "0" "$(cron_count 'InternetReconnector')"

# The case above runs out of input at the very first prompt, which is read by
# ask() in the main shell. Every prompt after the password is read through
# ask_trimmed() instead, which always runs inside a command substitution -- and
# bash clears `set -e` there, so ask()'s refusal used to end only the inner
# subshell. ask_trimmed() then returned an empty reply with status 0, and every
# caller read it as "take the default": measured, input ending after the
# password printed "no more input" three times, then wrote config.env,
# installed the job and exited 0. The first-prompt case could not see that,
# because it never reaches ask_trimmed() at all.
#
# One case per trimmed prompt, since each is a separate call site: the
# interface (with a device list, so it is the numbered-list prompt), the hidden
# flag, and the interval. Asserted on no config.env and no job, because exit 0
# plus an installed job is exactly what the defect produced.
d="$(new_case)"; co="$(new_checkout "$d")"
export CRONTAB_FILE="$d/crontab.txt"
for eof_answers in 'MyNet\n\n' 'MyNet\n\nwlan0\n' 'MyNet\n\nwlan0\nno\n'; do
    : > "$CRONTAB_FILE"
    rm -f "$co/config.env"
    run_setup "$co" "$eof_answers" "${eof_bound[@]}" NM_DEVICES="wlan0|wifi" \
        NM_ACTIVE_PROFILE="MyNet" NM_PROFILES="MyNet|MyNet" bash "$co/auto-setup.sh"
    assert_eq "running out of input after '$eof_answers' fails the setup" \
        "1" "$CRON_STATUS"
    assert_contains "and says it ran out of input" "no more input (end of file)" "$CRON_OUT"
    assert_not_contains "rather than carrying on to the install" "Setup complete" "$CRON_OUT"
    assert_missing "and nothing is written" "$co/config.env"
    assert_eq "and nothing is installed" "0" "$(cron_count 'InternetReconnector')"
done

# The control: the same answers with the last one supplied complete normally,
# so the cases above are refusing end of input and not the answers themselves.
: > "$CRONTAB_FILE"
run_setup "$co" 'MyNet\n\nwlan0\nno\n\n' env NM_DEVICES="wlan0|wifi" \
    NM_ACTIVE_PROFILE="MyNet" NM_PROFILES="MyNet|MyNet" bash "$co/auto-setup.sh"
assert_eq "with every answer given the same run completes" "0" "$CRON_STATUS"
assert_eq "and installs the job" "1" "$(cron_count 'InternetReconnector$')"

# The other side of end of input: a last answer with no newline after it is an
# answer. `read` returns 1 for it but assigns it, and ask() used to throw it away
# as end of input -- the run then asked every question, took the password and
# was refused at the last prompt, writing nothing. Pinned on both prompts that
# can come last: the interval, and the hidden flag when MINUTES skips the
# interval.
: > "$CRONTAB_FILE"
rm -f "$co/config.env"
run_setup "$co" 'MyNet\n\nwlan0\nno\n10' env NM_DEVICES="wlan0|wifi" \
    NM_ACTIVE_PROFILE="MyNet" NM_PROFILES="MyNet|MyNet" bash "$co/auto-setup.sh"
assert_eq "a last answer with no newline after it is still an answer" "0" "$CRON_STATUS"
assert_not_contains "rather than end of input" "no more input" "$CRON_OUT"
assert_contains "and it is the interval installed" "*/10 * * * *" "$(cron_text)"
: > "$CRONTAB_FILE"
rm -f "$co/config.env"
run_setup "$co" 'MyNet\n\nwlan0\nyes' env MINUTES=10 NM_DEVICES="wlan0|wifi" \
    NM_ACTIVE_PROFILE="MyNet" NM_PROFILES="MyNet|MyNet" bash "$co/auto-setup.sh"
assert_eq "the same for the hidden flag when it is the last prompt" "0" "$CRON_STATUS"
assert_eq "and that answer is the one written" "yes" "$(config_setting WIFI_HIDDEN)"

# The argument policy the other four scripts share. This one has no flags at all
# beyond --help, so every other argument is unknown.
d="$(new_case)"; co="$(new_checkout "$d")"
export CRONTAB_FILE="$d/crontab.txt"; : > "$CRONTAB_FILE"

run_install bash "$co/auto-setup.sh" --help
assert_eq "--help succeeds" "0" "$CRON_STATUS"
assert_contains "and prints the usage block" "Usage: auto-setup.sh" "$CRON_OUT"
assert_eq "and installs nothing" "0" "$(cron_count 'InternetReconnector')"

run_install bash "$co/auto-setup.sh" --bogus
assert_eq "an unknown argument is refused" "1" "$CRON_STATUS"
assert_contains "and is named, between quotes" "unknown argument: '--bogus'" "$CRON_OUT"

run_install bash "$co/auto-setup.sh" ""
assert_eq "an empty argument is refused, not read as no argument" "1" "$CRON_STATUS"
assert_contains "and the quotes make it visible" "unknown argument: ''" "$CRON_OUT"

run_install bash "$co/auto-setup.sh" --help extra
assert_eq "a stray argument after --help is refused" "1" "$CRON_STATUS"
assert_contains "and says what was wrong" "too many arguments" "$CRON_OUT"
assert_missing "none of those wrote a config" "$co/config.env"

# A relative RECONNECT_CONFIG is refused up front rather than after the whole
# interview: install-cron.sh would refuse it at the end anyway, and by then every
# question has been asked and the file written.
run_install env RECONNECT_CONFIG=config.env bash "$co/auto-setup.sh"
assert_eq "a relative RECONNECT_CONFIG is refused" "1" "$CRON_STATUS"
assert_contains "with the reason cron makes it matter" "home directory" "$CRON_OUT"
assert_contains "and the value quoted" "got: 'config.env'" "$CRON_OUT"

# config.env holds a password, so it is created empty, chmodded, and only then
# written into -- the reverse order leaves the secret world-readable for the
# instant between. Skipped where the filesystem does not enforce the mode, the
# same way the unreadable-config test is.
d="$(new_case)"; co="$(new_checkout "$d")"
export CRONTAB_FILE="$d/crontab.txt"; : > "$CRONTAB_FILE"
run_setup "$co" 'MyNet
hunter2
wlan0
no
5
' env NM_ACTIVE_PROFILE="MyNet" NM_PROFILES="MyNet|MyNet" bash "$co/auto-setup.sh"
# The mode as `ls -l` reports it, first field only -- taken with a parameter
# expansion rather than `cut`, so the check needs no command beyond `ls`. The
# paths are ones this suite created, so SC2012's concern about odd filenames
# does not arise here.
file_mode() {
    local line
    # shellcheck disable=SC2012
    line="$(ls -l "$1")" || return 1
    printf '%s' "${line%% *}"
}
probe_mode="$d/mode-probe"
: > "$probe_mode"
chmod 600 "$probe_mode" 2>/dev/null
if [ "$(file_mode "$probe_mode")" != "-rw-------" ]; then
    printf '  skip config mode test: this filesystem does not enforce the mode
'
else
    assert_eq "the config holding the password is mode 600"         "-rw-------" "$(file_mode "$co/config.env")"

    # The backup, and the fixture is the one that shows why it needs a chmod of
    # its own: a config the user wrote by hand and left at 644. `cp` gives the
    # copy the source's mode, so the backup came out world-readable with the
    # same password in it, while the new config was tightened to 600 and the
    # run reported only that the previous one was saved. The original's mode
    # is checked first so the case cannot pass on a filesystem that made it
    # 600 regardless.
    chmod 644 "$co/config.env" 2>/dev/null
    if [ "$(file_mode "$co/config.env")" != "-rw-r--r--" ]; then
        printf '  skip backup mode test: could not make the fixture world-readable\n'
    else
        run_setup "$co" '




' env NM_ACTIVE_PROFILE="MyNet" NM_PROFILES="MyNet|MyNet" bash "$co/auto-setup.sh"
        assert_eq "a re-run over a world-readable config succeeds" "0" "$CRON_STATUS"
        assert_eq "the backup of it is mode 600, not the 644 it was copied from" \
            "-rw-------" "$(file_mode "$co/config.env.bak")"
        assert_eq "and the new config is 600 as before" \
            "-rw-------" "$(file_mode "$co/config.env")"
        assert_eq "and the backup still holds the password it was made to keep" \
            "hunter2" "$(sed -n 's/^WIFI_PASSWORD="\(.*\)"$/\1/p' "$co/config.env.bak" | head -n 1)"
    fi
fi

# A machine with no crontab at all. That is the last thing a run needs, and it
# was not checked until install-cron.sh refused at the very end -- after the
# interview, the password, the config write and a passing verification. It is
# refused before the first question now, like every other run that cannot
# finish. The PATH is the no-crontab one the uninstall section builds.
if [ "${nocrontab_ok:-0}" -ne 1 ]; then
    printf '  skip no-crontab setup test: could not build a PATH without crontab\n'
else
    d="$(new_case)"; co="$(new_checkout "$d")"
    run_setup "$co" "$setup_answers" env PATH="$nocrontab" bash "$co/auto-setup.sh"
    assert_eq "a setup with no crontab command is refused" "1" "$CRON_STATUS"
    assert_contains "and says which command is missing" "crontab not found" "$CRON_OUT"
    assert_not_contains "before the interview has printed a word" \
        "InternetReconnector setup" "$CRON_OUT"
    assert_missing "and before config.env is written" "$co/config.env"
fi

# The rest of install-cron.sh's install preflights, one PATH per command so
# that deleting one check cannot be masked by another still firing. mktemp and
# rm are nothing reconnect.sh needs, so without them the run answered every
# question, wrote config.env, printed "Settings work" and was then refused by
# install-cron.sh; awk and date were caught only by the verification run, after
# the interview. Asserted on the interview never starting, since exit 1 is also
# what a refusal at the end produces. The controls are every other case in this
# section, which run with all four present.
for setup_missing in mktemp awk rm date; do
    nosetup_bin="$TMP/no-$setup_missing-for-setup"
    if [ -z "$real_bash" ] || ! build_path_without "$nosetup_bin" "$setup_missing"; then
        printf '  skip no-%s setup test: could not build a PATH without it\n' "$setup_missing"
        continue
    fi
    d="$(new_case)"; co="$(new_checkout "$d")"
    export CRONTAB_FILE="$d/crontab.txt"; : > "$CRONTAB_FILE"
    run_setup "$co" "$setup_answers" env PATH="$nosetup_bin" bash "$co/auto-setup.sh"
    assert_eq "a setup with no $setup_missing is refused" "1" "$CRON_STATUS"
    assert_contains "and names $setup_missing" "$setup_missing not found" "$CRON_OUT"
    assert_not_contains "before the interview has printed a word" \
        "InternetReconnector setup" "$CRON_OUT"
    assert_missing "and before config.env is written" "$co/config.env"
done

# `cp`, which only a re-run over an existing config needs, to make the .bak. It
# was checked at the `cp` itself, so a machine without one answered every
# question and typed the password before being refused. build_path_without()
# never puts `cp` on its PATH, so a PATH built with nothing excluded is exactly
# "everything but cp". The control is every re-run case above, which has cp.
nocp_bin="$TMP/no-cp-for-setup"
if [ -z "$real_bash" ] || ! build_path_without "$nocp_bin"; then
    printf '  skip no-cp setup test: could not build a PATH without it\n'
else
    d="$(new_case)"; co="$(new_checkout "$d")"
    export CRONTAB_FILE="$d/crontab.txt"; : > "$CRONTAB_FILE"
    printf 'WIFI_SSID="OldNet"\n' > "$co/config.env"
    run_setup "$co" "$setup_answers" env PATH="$nocp_bin" bash "$co/auto-setup.sh"
    assert_eq "a re-run with no cp is refused" "1" "$CRON_STATUS"
    assert_contains "and names cp" "cp not found" "$CRON_OUT"
    assert_not_contains "before the interview has printed a word" \
        "InternetReconnector setup" "$CRON_OUT"
    assert_eq "and the existing config is untouched" \
        'WIFI_SSID="OldNet"' "$(cat "$co/config.env")"
fi

# A crontab command that is present but refuses to read -- what cron.allow and
# cron.deny produce. The presence check above passes, and the read that looks
# for the installed line used to treat any failure as "no line": the run asked
# every question, took the password, wrote config.env and printed "Settings
# work" before install-cron.sh refused to write over a crontab it could not
# read. Asserted on the interview never starting, since exit 1 is also what the
# refusal at the end produced. The control is every other case in this section:
# their empty crontabs answer "no crontab for tester" and must keep working.
d="$(new_case)"; co="$(new_checkout "$d")"
export CRONTAB_FILE="$d/crontab.txt"; : > "$CRONTAB_FILE"
run_setup "$co" "$setup_answers" env CRONTAB_FAIL=l \
    CRONTAB_FAIL_MSG="You (tester) are not allowed to use this program (crontab)" \
    NM_ACTIVE_PROFILE="MyNet" NM_PROFILES="MyNet|MyNet" bash "$co/auto-setup.sh"
assert_eq "a crontab that cannot be read is refused" "1" "$CRON_STATUS"
assert_contains "and says so" "could not read the current crontab" "$CRON_OUT"
assert_contains "passing on what crontab said" "not allowed to use this program" "$CRON_OUT"
assert_not_contains "before the interview has printed a word" \
    "InternetReconnector setup" "$CRON_OUT"
assert_missing "and before config.env is written" "$co/config.env"

# What Enter at the interval question means depends on whether a job is
# installed, not on whether a config exists. The prompt tested the config, so
# after installing first and configuring second -- an order install-cron.sh
# anticipates with its "no config file yet" note -- it said "Press Enter for
# every 5 minutes" and then installed the 10 already on the line.
d="$(new_case)"; co="$(new_checkout "$d")"
export CRONTAB_FILE="$d/crontab.txt"; : > "$CRONTAB_FILE"
run_install env MINUTES=10 bash "$co/manual-setup/install-cron.sh"
assert_missing "the fixture has a job but no config yet" "$co/config.env"
run_setup "$co" 'MyNet
pw

no

' env NM_ACTIVE_PROFILE="MyNet" NM_PROFILES="MyNet|MyNet" bash "$co/auto-setup.sh"
assert_eq "a first setup over an installed job succeeds" "0" "$CRON_STATUS"
# Pinned on the prompt's own wording, trailing full stop included. It used to
# be the bare "(every 10 minutes)", and install-cron.sh's closing "Installed cron
# job (every 10 minutes):" contains that too -- so with the prompt no longer
# naming the interval at all the assertion still passed (measured: no new
# failure), and the half of the fix it was named for was unpinned.
assert_contains "and the interval prompt says Enter keeps what is installed" \
    "Press Enter to keep the interval already installed" "$CRON_OUT"
assert_contains "and names the installed interval" \
    "(every 10 minutes)." "$CRON_OUT"
assert_not_contains "rather than promising the default" \
    "Press Enter for every 5 minutes" "$CRON_OUT"
assert_contains "and that interval is what stays installed" "*/10 * * * *" "$(cron_text)"

# The control: with no job installed the default is what the prompt offers.
d="$(new_case)"; co="$(new_checkout "$d")"
export CRONTAB_FILE="$d/crontab.txt"; : > "$CRONTAB_FILE"
run_setup "$co" 'MyNet
pw

no

' env NM_ACTIVE_PROFILE="MyNet" NM_PROFILES="MyNet|MyNet" bash "$co/auto-setup.sh"
assert_contains "with no job installed the prompt offers every 5 minutes" \
    "Press Enter for every 5 minutes" "$CRON_OUT"
assert_contains "and installs it" "*/5 * * * *" "$(cron_text)"

# An installed interval install-cron.sh would refuse. A hand-edited `*/7` was
# offered as "Press Enter to keep the interval already installed (every 7
# minutes)", and Enter then ran the whole interview and the verification before
# install-cron.sh refused it with "must divide 60 evenly"; a three-digit one
# took the general "keep" wording and met the same refusal. It is reported now,
# and Enter means every 5 minutes. Asserted on the run finishing and on the
# crontab, since a refusal at the end is exactly what both used to produce.
for bad_interval in 7 123; do
    d="$(new_case)"; co="$(new_checkout "$d")"
    export CRONTAB_FILE="$d/crontab.txt"
    printf "*/%s * * * * PATH='/usr/bin' '%s/reconnect.sh' >/dev/null 2>&1 # InternetReconnector\n" \
        "$bad_interval" "$co" > "$CRONTAB_FILE"
    run_setup "$co" 'MyNet\npw\n\nno\n\n' env NM_ACTIVE_PROFILE="MyNet" \
        NM_PROFILES="MyNet|MyNet" bash "$co/auto-setup.sh"
    assert_eq "an installed */$bad_interval does not fail the setup at the end" \
        "0" "$CRON_STATUS"
    assert_contains "and the prompt says it cannot be kept" \
        "The interval on the installed cron line cannot be kept" "$CRON_OUT"
    assert_not_contains "rather than offering to keep it" \
        "Press Enter to keep the interval already installed" "$CRON_OUT"
    assert_contains "and Enter installs every 5 minutes instead" "*/5 * * * *" "$(cron_text)"
    assert_eq "as the one job" "1" "$(cron_count 'InternetReconnector$')"
done

# The two installed lines whose interval install-cron.sh does not carry at all.
# A schedule that is not `*/N` got "Press Enter to keep the interval already
# installed." and install-cron.sh then replaced it with `*/5`; a line edited
# after the marker got the same promise with its interval named, and
# install-cron.sh left it and installed a second job every 5 minutes. Both are
# reported as unkeepable now. The prompt is keyed on the line install-cron.sh's
# ours() claims, not on the looser one the settings are carried off.
d="$(new_case)"; co="$(new_checkout "$d")"
export CRONTAB_FILE="$d/crontab.txt"
printf "0,30 * * * * PATH='/usr/bin' '%s/reconnect.sh' >/dev/null 2>&1 # InternetReconnector\n" \
    "$co" > "$CRONTAB_FILE"
run_setup "$co" 'MyNet\npw\n\nno\n\n' env NM_ACTIVE_PROFILE="MyNet" \
    NM_PROFILES="MyNet|MyNet" bash "$co/auto-setup.sh"
assert_eq "an installed non-*/N schedule does not fail the setup" "0" "$CRON_STATUS"
assert_contains "and the prompt says it cannot be kept" \
    "The interval on the installed cron line cannot be kept" "$CRON_OUT"
assert_contains "naming the schedule" "'0,30 * * * *' is not one" "$CRON_OUT"
assert_not_contains "rather than promising to keep it" \
    "Press Enter to keep the interval already installed" "$CRON_OUT"
assert_contains "and Enter installs every 5 minutes, as the prompt says" "*/5 * * * *" "$(cron_text)"
assert_eq "as the one job" "1" "$(cron_count 'InternetReconnector$')"

printf "*/10 * * * * PATH='/usr/bin' '%s/reconnect.sh' >/dev/null 2>&1 # InternetReconnector # my note\n" \
    "$co" > "$CRONTAB_FILE"
run_setup "$co" '\n\n\nno\n\n' env NM_ACTIVE_PROFILE="MyNet" \
    NM_PROFILES="MyNet|MyNet" bash "$co/auto-setup.sh"
assert_eq "a line edited after the marker does not fail the setup" "0" "$CRON_STATUS"
assert_contains "and the prompt says its interval cannot be kept" \
    "edited past what install-cron.sh recognises" "$CRON_OUT"
assert_not_contains "rather than naming it as the one Enter keeps" \
    "(every 10 minutes)." "$CRON_OUT"
assert_contains "while install-cron.sh still says what it left" "now runs from both" "$CRON_OUT"

# The control: a line install-cron.sh does claim still has its interval kept, by
# the pinned wording -- here one that a hand-edit unquoted and indented, which
# ours() still claims, so the stricter test cannot be one that claims nothing.
printf " */10 * * * * PATH=/usr/bin %s/reconnect.sh >/dev/null 2>&1 # InternetReconnector \n" \
    "$co" > "$CRONTAB_FILE"
run_setup "$co" '\n\n\nno\n\n' env NM_ACTIVE_PROFILE="MyNet" \
    NM_PROFILES="MyNet|MyNet" bash "$co/auto-setup.sh"
assert_contains "a line install-cron.sh claims still has its interval kept" \
    "(every 10 minutes)." "$CRON_OUT"
assert_contains "and kept it is" "*/10 * * * *" "$(cron_text)"
assert_eq "as the one job" "1" "$(cron_count 'InternetReconnector$')"

# install-cron.sh failing after the verification passed. The refusal used to say
# "the cron job is not installed" whatever was in the crontab -- on a re-run the
# job already there stays -- and to run a bare ./manual-setup/install-cron.sh,
# which drops the interval chosen at the prompt: measured, a re-run answering 15
# over a */10 job was told to run it, and it reinstalled */10. The advice is
# followed literally here, out of the output, so the assertion is on what that
# command installs rather than on its spelling. A failing crontab write is the
# reachable failure once the pre-interview checks have passed.
d="$(new_case)"; co="$(new_checkout "$d")"
export CRONTAB_FILE="$d/crontab.txt"; : > "$CRONTAB_FILE"
run_setup "$co" 'MyNet\npw\n\nno\n10\n' env NM_ACTIVE_PROFILE="MyNet" \
    NM_PROFILES="MyNet|MyNet" bash "$co/auto-setup.sh"
installed_before="$(cron_text)"
assert_contains "the fixture starts with a */10 job installed" "*/10 * * * *" "$installed_before"
run_setup "$co" '\n\n\n\n15\n' env CRONTAB_FAIL=w CRONTAB_FAIL_MSG="crontab: write error" \
    NM_ACTIVE_PROFILE="MyNet" NM_PROFILES="MyNet|MyNet" bash "$co/auto-setup.sh"
assert_eq "an install-cron.sh failure after the test fails the setup" "1" "$CRON_STATUS"
assert_not_contains "without claiming no job is installed over one that is" \
    "the cron job is not installed" "$CRON_OUT"
assert_contains "and says the installed job was left as it was" \
    "the one already installed was left as it was" "$CRON_OUT"
assert_eq "which it was" "$installed_before" "$(cron_text)"
install_advice="$(printf '%s\n' "$CRON_OUT" | grep -A1 'fix the reason above and run:' | tail -n 1)"
assert_eq "and the command it gives carries the interval just chosen" \
    "  MINUTES='15' ./manual-setup/install-cron.sh" "$install_advice"
CRON_OUT="$(cd "$co" && eval "$install_advice" 2>&1)"
assert_contains "so following it installs that interval" "*/15 * * * *" "$(cron_text)"
assert_eq "as the one job" "1" "$(cron_count 'InternetReconnector$')"

# The control, and the other half: with no job installed the refusal says none
# was, and a RECONNECT_CONFIG given only for this run is carried into the
# command too, or following it would install a job reading the default config.
d="$(new_case)"; co="$(new_checkout "$d")"
export CRONTAB_FILE="$d/crontab.txt"; : > "$CRONTAB_FILE"
mkdir -p "$d/etc"
run_setup "$co" 'MyNet\npw\n\nno\n\n' env CRONTAB_FAIL=w RECONNECT_CONFIG="$d/etc/config.env" \
    NM_ACTIVE_PROFILE="MyNet" NM_PROFILES="MyNet|MyNet" bash "$co/auto-setup.sh"
assert_eq "an install-cron.sh failure on a first setup fails it" "1" "$CRON_STATUS"
assert_contains "and says no job was installed" "so no cron job was installed" "$CRON_OUT"
install_advice="$(printf '%s\n' "$CRON_OUT" | grep -A1 'fix the reason above and run:' | tail -n 1)"
assert_eq "and the command carries the config path given for this run" \
    "  RECONNECT_CONFIG='$d/etc/config.env' ./manual-setup/install-cron.sh" "$install_advice"
CRON_OUT="$(cd "$co" && eval "$install_advice" 2>&1)"
assert_contains "so following it installs a job reading that config" \
    "RECONNECT_CONFIG='$d/etc/config.env'" "$(cron_text)"

# Every setting the command claims to carry, not only the three the fixtures
# above happen to set. Those pinned RECONNECT_CONFIG, the scan wait and the
# attempts count, so cutting install_command()'s list down to those three left
# the whole suite green while the advice dropped RECONNECT_LOG_DIR, the
# retention, the nmcli wait and CRON_PATH -- and followed, it would have
# installed a job logging somewhere else, with other timeouts, on a PATH that
# may not reach nmcli. All seven are set here, the exact command is asserted in
# install_command()'s order, and the command is run and each value looked for
# on the line it writes.
d="$(new_case)"; co="$(new_checkout "$d")"
export CRONTAB_FILE="$d/crontab.txt"; : > "$CRONTAB_FILE"
mkdir -p "$d/etc"
all_path="$STUB_BIN:/usr/bin:/bin"
run_setup "$co" 'MyNet\npw\n\nno\n15\n' env CRONTAB_FAIL=w \
    RECONNECT_CONFIG="$d/etc/config.env" RECONNECT_LOG_DIR="$d/job-logs" \
    RECONNECT_LOG_RETENTION_DAYS=30 RECONNECT_SCAN_WAIT_SECS=0 \
    RECONNECT_CONNECT_ATTEMPTS=1 RECONNECT_NMCLI_WAIT_SECS=7 CRON_PATH="$all_path" \
    NM_ACTIVE_PROFILE="MyNet" NM_PROFILES="MyNet|MyNet" bash "$co/auto-setup.sh"
assert_eq "an install-cron.sh failure with every setting given fails the setup" "1" "$CRON_STATUS"
install_advice="$(printf '%s\n' "$CRON_OUT" | grep -A1 'fix the reason above and run:' | tail -n 1)"
assert_eq "and the command it gives carries all seven settings and the interval" \
    "  MINUTES='15' RECONNECT_CONFIG='$d/etc/config.env' RECONNECT_LOG_DIR='$d/job-logs' RECONNECT_LOG_RETENTION_DAYS='30' RECONNECT_SCAN_WAIT_SECS='0' RECONNECT_CONNECT_ATTEMPTS='1' RECONNECT_NMCLI_WAIT_SECS='7' CRON_PATH='$all_path' ./manual-setup/install-cron.sh" \
    "$install_advice"
CRON_OUT="$(cd "$co" && eval "$install_advice" 2>&1)"
for carried in "*/15 * * * *" "PATH='$all_path'" "RECONNECT_CONFIG='$d/etc/config.env'" \
    "RECONNECT_LOG_DIR='$d/job-logs'" "RECONNECT_LOG_RETENTION_DAYS='30'" \
    "RECONNECT_SCAN_WAIT_SECS='0'" "RECONNECT_CONNECT_ATTEMPTS='1'" \
    "RECONNECT_NMCLI_WAIT_SECS='7'"; do
    assert_contains "so following it installs $carried" "$carried" "$(cron_text)"
done

# A day file that exists and cannot be read or written. The day file used to be
# read back after the verification run, and a failing redirect there ended the
# run under `set -e` with bash's own "Permission denied", exit 1 and no stated
# reason, after config.env had been written. The outcome comes through
# IR_OUTCOME_FILE now, and a day file the run cannot append to is refused before
# the interview, in the script's own words. Self-skips where the filesystem does
# not enforce the mode.
d="$(new_case)"; co="$(new_checkout "$d")"
export CRONTAB_FILE="$d/crontab.txt"; : > "$CRONTAB_FILE"
mkdir -p "$co/logs"
locked_log="$co/logs/$(date '+%Y-%m-%d').log"
printf '[00:00:00] Wifi Good\n' > "$locked_log"
chmod 000 "$locked_log" 2>/dev/null
if [ -r "$locked_log" ]; then
    printf '  skip unreadable-day-file setup test: this filesystem does not enforce the mode\n'
else
    run_setup "$co" "$setup_answers" env NM_ACTIVE_PROFILE="MyNet" \
        NM_PROFILES="MyNet|MyNet" bash "$co/auto-setup.sh"
    assert_eq "an unreadable day file does not pass the verification" "1" "$CRON_STATUS"
    assert_contains "and the run gives its own reason" \
        "today's log file $locked_log cannot be written to" "$CRON_OUT"
    assert_not_contains "rather than bash's redirect diagnostic" \
        "Permission denied" "$CRON_OUT"
    assert_not_contains "before the interview has printed a word" \
        "InternetReconnector setup" "$CRON_OUT"
    assert_eq "and nothing is installed" "0" "$(cron_count 'InternetReconnector')"
fi
chmod 644 "$locked_log" 2>/dev/null

unset NM_DEVICES

# =============================================================================
section "crontab safety guards"
# =============================================================================
# The paths that exist so this tool can never wipe cron entries it did not write.
# They were the only substantial part of the code with no coverage, which is the
# wrong way round: a regression in one of them destroys data that has nothing to
# do with this project, and the destruction is silent.

# A `crontab -l` that fails for a reason other than "no crontab" must not be read
# as "the user has no entries" -- doing so would write back only our own line.
d="$(new_case)"; co="$(new_checkout "$d")"
export CRONTAB_FILE="$d/crontab.txt"
printf '0 3 * * * /usr/bin/backup.sh\n' > "$CRONTAB_FILE"
before="$(cron_text)"
denied=(CRONTAB_FAIL=l CRONTAB_FAIL_RC=1 CRONTAB_FAIL_MSG="crontab: permission denied")

run_install env "${denied[@]}" bash "$co/manual-setup/install-cron.sh"
assert_eq "an unreadable crontab aborts the install" "1" "$CRON_STATUS"
assert_contains "and says it refused rather than continuing" "Refusing to continue" "$CRON_OUT"
assert_contains "and passes on what crontab said" "permission denied" "$CRON_OUT"
assert_eq "and the user's entries are untouched" "$before" "$(cron_text)"

run_install env "${denied[@]}" bash "$co/manual-setup/install-cron.sh" --remove
assert_eq "--remove aborts on an unreadable crontab too" "1" "$CRON_STATUS"
assert_eq "and changes nothing" "$before" "$(cron_text)"

run_install env "${denied[@]}" bash "$co/manual-setup/uninstall-cron.sh"
assert_eq "uninstall-cron.sh aborts on an unreadable crontab" "1" "$CRON_STATUS"
assert_contains "and says nothing was changed" "Nothing was changed" "$CRON_OUT"
assert_eq "and the user's entries are still untouched" "$before" "$(cron_text)"

# The distinction the guard turns on: exit 1 with "no crontab" on stderr is the
# ordinary empty case and must still be allowed straight through.
d="$(new_case)"; co="$(new_checkout "$d")"
export CRONTAB_FILE="$d/crontab.txt"
: > "$CRONTAB_FILE"
run_install bash "$co/manual-setup/install-cron.sh"
assert_eq "an empty crontab is not mistaken for a read failure" "0" "$CRON_STATUS"
assert_eq "and the job is installed" "1" "$(cron_count 'InternetReconnector$')"

# A failed read whose stderr is a single newline. install-cron.sh and
# uninstall-cron.sh ask `-s` of the file their stderr went to, which a lone
# newline satisfies, so they refuse; auto-setup.sh read the same stderr through a
# command substitution, which strips it to nothing, and took it for "no crontab
# yet" -- so it asked every question, read the password, wrote config.env and
# printed "Settings work" before install-cron.sh refused. All three are held to
# the same answer here. An empty CRONTAB_FAIL_MSG is how the stub prints the
# newline alone.
d="$(new_case)"; co="$(new_checkout "$d")"
export CRONTAB_FILE="$d/crontab.txt"
: > "$CRONTAB_FILE"
run_install env CRONTAB_FAIL=l CRONTAB_FAIL_MSG="" bash "$co/manual-setup/install-cron.sh"
assert_eq "a read failing with only a newline on stderr is refused by install-cron.sh" \
    "1" "$CRON_STATUS"
run_install env CRONTAB_FAIL=l CRONTAB_FAIL_MSG="" bash "$co/manual-setup/uninstall-cron.sh"
assert_eq "and by uninstall-cron.sh" "1" "$CRON_STATUS"
run_setup "$co" "$setup_answers" env CRONTAB_FAIL=l CRONTAB_FAIL_MSG="" \
    NM_ACTIVE_PROFILE="MyNet" NM_PROFILES="MyNet|MyNet" bash "$co/auto-setup.sh"
assert_eq "and by auto-setup.sh" "1" "$CRON_STATUS"
assert_contains "which says it could not read the crontab" \
    "could not read the current crontab" "$CRON_OUT"
assert_not_contains "before the interview has printed a word" \
    "InternetReconnector setup" "$CRON_OUT"
assert_missing "and before config.env is written" "$co/config.env"

# BusyBox's spelling of "no crontab yet". Its `crontab -l` opens the user's
# spool file and, when there is none, says "can't open '<user>': No such file or
# directory" and exits 1 -- no "no crontab" anywhere -- so every first install
# on a BusyBox cron was refused as a read failure. This pins the message as
# BusyBox's source writes it; it has not been run against a real BusyBox cron.
busybox_none="crontab: can't open 'tester': No such file or directory"
d="$(new_case)"; co="$(new_checkout "$d")"
export CRONTAB_FILE="$d/crontab.txt"
: > "$CRONTAB_FILE"
run_install env CRONTAB_FAIL=l CRONTAB_FAIL_MSG="$busybox_none" \
    bash "$co/manual-setup/install-cron.sh"
assert_eq "BusyBox's no-crontab message lets a first install through" "0" "$CRON_STATUS"
assert_eq "and the job is installed" "1" "$(cron_count 'InternetReconnector$')"
: > "$CRONTAB_FILE"
run_install env CRONTAB_FAIL=l CRONTAB_FAIL_MSG="$busybox_none" \
    bash "$co/manual-setup/uninstall-cron.sh"
assert_eq "uninstall-cron.sh reads it as nothing to remove" "0" "$CRON_STATUS"
assert_contains "and says so" "No cron job found" "$CRON_OUT"
: > "$CRONTAB_FILE"
run_setup "$co" "$setup_answers" env CRONTAB_FAIL=l CRONTAB_FAIL_MSG="$busybox_none" \
    NM_ACTIVE_PROFILE="MyNet" NM_PROFILES="MyNet|MyNet" bash "$co/auto-setup.sh"
assert_eq "and auto-setup.sh runs to the end over it" "0" "$CRON_STATUS"
assert_eq "installing the job" "1" "$(cron_count 'InternetReconnector$')"

# The control: the same message with any other reason is a real read failure,
# and each of the three still refuses it rather than writing over the crontab.
busybox_denied="crontab: can't open 'tester': Permission denied"
printf '0 3 * * * /usr/bin/backup.sh\n' > "$CRONTAB_FILE"
before="$(cron_text)"
rm -f "$co/config.env"
run_install env CRONTAB_FAIL=l CRONTAB_FAIL_MSG="$busybox_denied" \
    bash "$co/manual-setup/install-cron.sh"
assert_eq "a BusyBox open failure for another reason is still refused" "1" "$CRON_STATUS"
assert_eq "and the user's entries are untouched" "$before" "$(cron_text)"
run_install env CRONTAB_FAIL=l CRONTAB_FAIL_MSG="$busybox_denied" \
    bash "$co/manual-setup/uninstall-cron.sh"
assert_eq "by uninstall-cron.sh too" "1" "$CRON_STATUS"
run_setup "$co" "$setup_answers" env CRONTAB_FAIL=l CRONTAB_FAIL_MSG="$busybox_denied" \
    NM_ACTIVE_PROFILE="MyNet" NM_PROFILES="MyNet|MyNet" bash "$co/auto-setup.sh"
assert_eq "and by auto-setup.sh" "1" "$CRON_STATUS"
assert_missing "before it writes a config" "$co/config.env"

# A write that fails must be fatal and must say so. Both branches used to discard
# their status, so a failed write was reported as a success.
d="$(new_case)"; co="$(new_checkout "$d")"
export CRONTAB_FILE="$d/crontab.txt"
printf '0 3 * * * /usr/bin/backup.sh\n' > "$CRONTAB_FILE"
before="$(cron_text)"
run_install env CRONTAB_FAIL=w CRONTAB_FAIL_RC=2 CRONTAB_FAIL_MSG="crontab: installation failed" \
    bash "$co/manual-setup/install-cron.sh"
assert_eq "a failed crontab write is fatal" "1" "$CRON_STATUS"
assert_contains "and names what crontab said" "installation failed" "$CRON_OUT"
assert_contains "and points at crontab -l" "crontab -l" "$CRON_OUT"
assert_eq "and the user's entries survive it" "$before" "$(cron_text)"

# The same on the removal path, where the write is `crontab -r`. This is the one
# that used to print "Removed the InternetReconnector cron job." and exit 0 while
# the job was still installed and still running.
d="$(new_case)"; co="$(new_checkout "$d")"
export CRONTAB_FILE="$d/crontab.txt"
: > "$CRONTAB_FILE"
run_install bash "$co/manual-setup/install-cron.sh"
run_install env CRONTAB_FAIL=r CRONTAB_FAIL_RC=1 CRONTAB_FAIL_MSG="crontab: cannot remove" \
    bash "$co/manual-setup/install-cron.sh" --remove
assert_eq "a failed crontab -r is fatal" "1" "$CRON_STATUS"
assert_not_contains "and is never reported as a removal" \
    "Removed the InternetReconnector cron job" "$CRON_OUT"
assert_eq "and the job is still there" "1" "$(cron_count 'InternetReconnector$')"

# A classifier failure must refuse to write, for the same reason the read guard
# exists: an empty result would otherwise read as "no other entries" and reach
# `crontab -r`, taking every unrelated entry with it.
d="$(new_case)"; co="$(new_checkout "$d")"
export CRONTAB_FILE="$d/crontab.txt"
printf '0 3 * * * /usr/bin/backup.sh\n' > "$CRONTAB_FILE"
before="$(cron_text)"
mkdir -p "$d/badbin"
printf '#!/usr/bin/env bash\nexit 3\n' > "$d/badbin/awk"
chmod +x "$d/badbin/awk"
run_install env PATH="$d/badbin:$PATH" bash "$co/manual-setup/install-cron.sh"
assert_eq "a failing classifier aborts the install" "1" "$CRON_STATUS"
assert_contains "and says why" "could not classify the current crontab" "$CRON_OUT"
assert_contains "and states the entries were left alone" "left untouched" "$CRON_OUT"
assert_eq "and they were" "$before" "$(cron_text)"

# uninstall-cron.sh re-reads the crontab after the removal to check the line is
# really gone. That read used to be nested inside the substitution that consumed
# it -- `leftover="$(our_cron_lines "$(read_crontab)")"` -- where read_crontab's
# die exits only its own subshell and `set -e` cannot see it, because a failing
# substitution used as an *argument* is not a checked command. An unreadable
# crontab therefore produced an empty result, which reads exactly like "no line
# left": the script printed the read error, then "Verify with: crontab -l", and
# exited 0 on a crontab it had just failed to read.
#
# CRONTAB_FAIL=l alone cannot reach this -- it fails the first read too, which
# dies correctly long before the check. CRONTAB_FAIL_SKIP=2 lets the first read
# and install-cron.sh's own read through and fails only the third, which is the
# post-removal one.
d="$(new_case)"; co="$(new_checkout "$d")"
export CRONTAB_FILE="$d/crontab.txt"
: > "$CRONTAB_FILE"
run_install bash "$co/manual-setup/install-cron.sh"
assert_eq "the job is installed to begin with" "1" "$(cron_count 'InternetReconnector$')"

run_install env CRONTAB_FAIL=l CRONTAB_FAIL_SKIP=2 CRONTAB_FAIL_RC=1 \
    CRONTAB_FAIL_MSG="crontab: permission denied" bash "$co/manual-setup/uninstall-cron.sh"
assert_eq "an unreadable crontab after the removal is not reported as success" \
    "1" "$CRON_STATUS"
assert_contains "and says the removal happened but could not be confirmed" \
    "could not confirm it" "$CRON_OUT"
assert_not_contains "and does not claim nothing was changed, because something was" \
    "Nothing was changed" "$CRON_OUT"
assert_not_contains "and never signs off as though the check had run" \
    "Verify with:" "$CRON_OUT"
assert_eq "the removal itself still went through" "0" "$(cron_count 'InternetReconnector$')"

# The control for the knob above: a skip count higher than the number of reads
# never fires, so the ordinary uninstall must still succeed. Without this a stub
# that failed everything would make the case above pass for the wrong reason.
d="$(new_case)"; co="$(new_checkout "$d")"
export CRONTAB_FILE="$d/crontab.txt"
: > "$CRONTAB_FILE"
run_install bash "$co/manual-setup/install-cron.sh"
run_install env CRONTAB_FAIL=l CRONTAB_FAIL_SKIP=9 bash "$co/manual-setup/uninstall-cron.sh"
assert_eq "a failure that never fires leaves the uninstall succeeding" "0" "$CRON_STATUS"
assert_eq "and the job is gone" "0" "$(cron_count 'InternetReconnector$')"

# read_crontab()'s own temporary file. It runs inside a command substitution,
# where bash clears `set -e`, so a failed mktemp used to leave the stderr path
# empty and carry on; the empty redirect then failed `crontab -l` with status 1,
# no output and an empty stderr file -- the "no crontab yet" shape -- and the
# uninstall printed "No cron job found" and exited 0 over a job still installed.
# A TMPDIR naming a directory that does not exist is how that arrives.
# Asserted on the crontab as well as the status, because exit 0 with the job
# still there is exactly what the defect produced.
d="$(new_case)"; co="$(new_checkout "$d")"
export CRONTAB_FILE="$d/crontab.txt"
: > "$CRONTAB_FILE"
run_install bash "$co/manual-setup/install-cron.sh"
assert_eq "the job is installed to begin with" "1" "$(cron_count 'InternetReconnector$')"
run_install env TMPDIR="$d/no-such-tmpdir" bash "$co/manual-setup/uninstall-cron.sh"
assert_eq "a temporary file that cannot be created fails the uninstall" "1" "$CRON_STATUS"
assert_contains "and says so" "could not create a temporary file" "$CRON_OUT"
assert_not_contains "rather than reading the crontab as empty" "No cron job found" "$CRON_OUT"
assert_eq "and the job is left for a run that can see it" \
    "1" "$(cron_count 'InternetReconnector$')"

# The control: the same checkout with an ordinary TMPDIR still removes the job,
# so the case above is not passing because the uninstall refuses everything.
run_install bash "$co/manual-setup/uninstall-cron.sh"
assert_eq "with a usable TMPDIR the same uninstall succeeds" "0" "$CRON_STATUS"
assert_eq "and removes the job" "0" "$(cron_count 'InternetReconnector$')"

# A crontab bigger than the pipe buffer. Every fixture above is a few hundred
# bytes, and the size was load-bearing in a way nothing here measured: the
# helpers that answer "are there any entries?" and "is one of them ours?" were
# both `printf '%s\n' "$text" | <reader>` pipelines whose reader stops early --
# `grep -q` at the first match, `awk ... exit` at the first match. `printf` is a
# builtin, so it runs in the pipeline's own subshell; once the text no longer
# fits in the pipe buffer it is still writing when the reader exits, dies of
# SIGPIPE with 141, and `set -o pipefail` makes 141 the pipeline's status. Both
# helpers therefore returned the *wrong answer* above roughly 64 KiB and the
# right one below it, which is why a suite full of small fixtures saw nothing.
#
# What that cost, measured against the code as it stood:
#
#   * has_entries() said "no entries" for a crontab full of them, and
#     write_crontab() answers that with `crontab -r`. A user crontab of 2,000
#     unrelated entries was deleted outright by an ordinary install, which then
#     printed "Installed cron job (every 5 minutes)" and exited 0. On --remove
#     the whole crontab went the same way, reported as a successful removal.
#   * has_ours() said "no line of ours" when ours was near the front, so
#     --remove printed "nothing to remove", exited 0, and left the job running.
#
# So the two directions are asserted separately and both fixtures are built past
# the buffer. Nothing else in this file would notice either one coming back:
# replacing has_entries() with the pipeline again leaves every other assertion
# green.
#
# ${#text} rather than `wc -c`: it is a shell expansion, so the size check needs
# no command that could itself be missing.
d="$(new_case)"; co="$(new_checkout "$d")"
export CRONTAB_FILE="$d/crontab.txt"
awk 'BEGIN { for (i = 1; i <= 5000; i++) printf "0 3 * * * /usr/bin/backup-%d.sh\n", i }' \
    > "$CRONTAB_FILE"
big_before="$(cron_text)"
big_size_ok=0
[ "${#big_before}" -le 65536 ] || big_size_ok=1
assert_eq "the fixture really is larger than a 64 KiB pipe buffer" "1" "$big_size_ok"
assert_eq "and it starts with 5000 unrelated entries" "5000" "$(cron_count 'backup-')"

run_install bash "$co/manual-setup/install-cron.sh"
assert_eq "an install onto a large crontab succeeds" "0" "$CRON_STATUS"
assert_eq "and every unrelated entry survives it" "5000" "$(cron_count 'backup-')"
assert_eq "and our job is installed exactly once" "1" "$(cron_count 'InternetReconnector$')"

run_install bash "$co/manual-setup/install-cron.sh" --remove
assert_eq "a removal from a large crontab succeeds" "0" "$CRON_STATUS"
assert_eq "and every unrelated entry survives that too" "5000" "$(cron_count 'backup-')"
assert_eq "and our job is gone" "0" "$(cron_count 'InternetReconnector')"

# The other direction: our line at the *front* of a large crontab is the case
# has_ours() got wrong, because that is when awk reaches its match with most of
# the input still unwritten. With our line last -- where the installer puts it --
# awk reads to the end anyway and the bug is invisible, so the order here is the
# whole point of the fixture.
d="$(new_case)"; co="$(new_checkout "$d")"
export CRONTAB_FILE="$d/crontab.txt"
{
    printf "*/5 * * * * PATH='/usr/bin' '%s/reconnect.sh' >/dev/null 2>&1 # InternetReconnector\n" "$co"
    awk 'BEGIN { for (i = 1; i <= 5000; i++) printf "0 3 * * * /usr/bin/backup-%d.sh\n", i }'
} > "$CRONTAB_FILE"
assert_eq "the fixture carries our line ahead of 5000 others" \
    "1" "$(cron_count 'InternetReconnector$')"

run_install bash "$co/manual-setup/install-cron.sh" --remove
assert_eq "--remove finds our line at the front of a large crontab" "0" "$CRON_STATUS"
assert_contains "and reports the removal rather than finding nothing" \
    "Removed the InternetReconnector cron job" "$CRON_OUT"
assert_eq "and the job really is gone" "0" "$(cron_count 'InternetReconnector')"
assert_eq "with the unrelated entries left alone" "5000" "$(cron_count 'backup-')"

# uninstall-cron.sh drives install-cron.sh --remove, so it inherits whatever that
# does with a large crontab. Asserted separately because its post-condition check
# reads the crontab a second way -- through our_cron_lines(), a `while read` loop
# over three `case` tests, which reads to the end and runs no external command at
# all -- so the two halves of the uninstall could disagree. (This comment used to
# say that second way was grep. It was three greps once; the rewrite that removed
# them is the one the failing-grep block above exists for, and the only grep left
# in that script matches crontab's *stderr* inside read_crontab().)
d="$(new_case)"; co="$(new_checkout "$d")"
export CRONTAB_FILE="$d/crontab.txt"
{
    printf "*/5 * * * * PATH='/usr/bin' '%s/reconnect.sh' >/dev/null 2>&1 # InternetReconnector\n" "$co"
    awk 'BEGIN { for (i = 1; i <= 5000; i++) printf "0 3 * * * /usr/bin/backup-%d.sh\n", i }'
} > "$CRONTAB_FILE"
run_install bash "$co/manual-setup/uninstall-cron.sh"
assert_eq "uninstall-cron.sh handles a large crontab" "0" "$CRON_STATUS"
assert_not_contains "without warning that the job is still installed" \
    "is still installed" "$CRON_OUT"
assert_eq "and the job is gone" "0" "$(cron_count 'InternetReconnector')"
assert_eq "and the unrelated entries are all still there" "5000" "$(cron_count 'backup-')"

# =============================================================================

printf '\n----------------------------------------\n'
printf '%d passed, %d failed\n' "$PASS" "$FAIL"

[ "$FAIL" -eq 0 ] || exit 1
exit 0
