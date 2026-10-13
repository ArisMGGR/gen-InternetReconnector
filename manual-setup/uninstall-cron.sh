#!/usr/bin/env bash
#
# uninstall-cron.sh
#
# Removes the cron entry installed by install-cron.sh, and optionally the
# daily log files reconnect.sh has written.
#
# The crontab surgery itself lives in install-cron.sh --remove, which knows
# exactly which lines belong to this checkout (and which marked lines belong
# to a different one, and must be left alone). Rewriting that logic here would
# give us a second, subtly different idea of what "our line" means, and the
# cheapest way for an uninstaller to delete someone else's cron job is to
# disagree with the installer about that. So this script drives that one and
# adds what an uninstall needs on top: an independent check that the job is
# really gone, and a way to clean up the logs.
#
# Usage (from the checkout root):
#   ./manual-setup/uninstall-cron.sh              # remove the cron job
#   ./manual-setup/uninstall-cron.sh --purge-logs # also delete logs/YYYY-MM-DD.log
#   ./manual-setup/uninstall-cron.sh --dry-run    # report what would be removed
#   ./manual-setup/uninstall-cron.sh --yes        # do not ask before deleting logs
#   ./manual-setup/uninstall-cron.sh --help       # show usage

set -euo pipefail

# For the reason written out in reconnect.sh: an exported CDPATH makes the `cd`
# below print into the substitution that resolves this script's directory.
unset CDPATH

# Split with parameter expansion rather than `dirname`, for the reason written
# out in full in reconnect.sh and shared by all four scripts. `*/*` fails for a
# bare name (`bash uninstall-cron.sh`), which means the current directory; the
# empty result is a script sitting directly in `/`.
script_src="${BASH_SOURCE[0]}"
case "$script_src" in
    */*)
        script_dir="${script_src%/*}"
        [ -n "$script_dir" ] || script_dir=/
        ;;
    *) script_dir=. ;;
esac
# `pwd -P` for the reason install-cron.sh gives where it resolves the same path:
# the physical path is the one the cron line is written with, whichever symlink
# the checkout was reached through.
SCRIPT_DIR="$(cd "$script_dir" && pwd -P)"
# This script lives in manual-setup/, one level below the checkout root, beside
# install-cron.sh. reconnect.sh and the default logs/ live at the root, which is
# what the cron line names and what reconnect.sh resolves its own defaults
# against -- so the root is resolved once here and used for both. Resolving them
# against this directory instead would make the report look for a job that
# runs a reconnect.sh that does not exist and purge a logs/ nothing writes to.
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
# Called by the spelling this run arrived by, not by the physical path.
# install-cron.sh takes its RECONNECT_ALIAS from the path it is started through,
# so starting it by $SCRIPT_DIR left it with no alias at all: a line written
# through a symlink was reported here as ours, `--remove` then called it
# "a different copy" and left it, and the uninstall ended in the "still
# installed" WARNING and exit 1 over the checkout's own job. Through a plain
# directory the two spellings are the same.
INSTALLER="$(cd "$script_dir" && pwd)/install-cron.sh"
RECONNECT="$ROOT_DIR/reconnect.sh"
# The spelling this run reached the checkout by, which a line written through a
# symlink by an earlier version names. install-cron.sh's ours() accepts it too,
# so this keeps reporting every line --remove would delete (D7's direction).
RECONNECT_ALIAS="$(cd "$script_dir/.." && pwd)/reconnect.sh"
MARKER="# InternetReconnector"

# Provisional. Refined once the crontab has been read, from the value
# install-cron.sh wrote onto the cron line -- see log_dir_from_cron_line().
LOG_DIR="${RECONNECT_LOG_DIR:-$ROOT_DIR/logs}"

die() {
    echo "ERROR: $*" >&2
    exit 1
}

usage() {
    # Inside the function, for the reason install-cron.sh's copy states: `cat`
    # is used in exactly two places here and both are conditional -- this
    # heredoc, and the line in read_crontab() that passes crontab's own
    # diagnostic on before a refusal. An ordinary uninstall reaches neither, so
    # an unconditional preflight refused a run that would have worked, over a
    # command that run never invokes. Still ahead of the heredoc, so `--help`
    # cannot abort under `set -e` and print an empty screen.
    command -v cat >/dev/null 2>&1 \
        || die "cat not found. Install coreutils."
    cat <<'USAGE'
Usage: uninstall-cron.sh [--purge-logs] [--dry-run] [--yes] [--help]

  (no arguments)   Remove the cron job that runs this checkout's reconnect.sh.
  --purge-logs     Also delete the daily logs (logs/YYYY-MM-DD.log) and the
                   logs/.lock file reconnect.sh uses. Asks first unless --yes
                   is given, and where there is no terminal to ask at -- from a
                   script, or from cron -- it keeps the logs rather than
                   guessing at an answer, and exits 1. Only the logs are kept:
                   the cron job is removed first and stays removed, so a run
                   that stops there has still done its main job. Pass --yes to
                   delete without being asked.
  --dry-run        Report what would be removed, change nothing.
  --yes, -y        Do not ask before deleting logs.
  --help, -h       Show this message.

Your config.env is never touched: it holds the SSID and password, it is not
something this script created, and re-installing later is much easier with it
still in place. Delete it yourself if you want it gone -- and config.env.bak
beside it too, if auto-setup.sh left one, since that holds the password as well.

Environment:
  RECONNECT_LOG_DIR   Log directory to purge. Defaults to the directory named
                      on the installed cron line, or to logs/ at the checkout
                      root when there is no line to read it from. Set it
                      explicitly to override both.

                      Only an absolute path is taken off the cron line. Cron
                      runs the job from your home directory and this script
                      runs from wherever you are, so a relative one there
                      names two different directories; it is reported and
                      ignored rather than purged on a guess. Setting this
                      variable is how you point the purge at it.
USAGE
}

# --- Parse arguments ---------------------------------------------------------
purge_logs=0
dry_run=0
assume_yes=0
show_help=0
exit_status=0
# What happened to the cron job by the time the log purge asks for
# confirmation: "none" (there was nothing to remove), "removed", or "left" (a
# line survived --remove; the WARNING says which). The removal runs first, and a
# refusal that does not say what it did reads as though the whole run had
# declined to do anything. It used to be a yes/no set whenever --remove exited
# 0 -- which it does when it leaves a hand-edited line alone -- so the refusal
# said "The cron job was removed" directly under a WARNING that it was still
# installed.
job_outcome=none
while [ "$#" -gt 0 ]; do
    case "$1" in
        --purge-logs) purge_logs=1 ;;
        --dry-run) dry_run=1 ;;
        -y | --yes) assume_yes=1 ;;
        -h | --help) show_help=1 ;;
        # Quoted for the reason reconnect.sh's WIFI_HIDDEN check quotes its
        # value, written out in full there. This loop is driven by `$#`, so an
        # empty argument does reach this arm -- and unquoted it produced
        # `ERROR: unknown argument: `, a refusal naming nothing at all. A
        # blanks-only argument was worse: the message looked like it had simply
        # stopped mid-sentence. `./uninstall-cron.sh "$flag"` with $flag unset is
        # how that arrives.
        *) usage >&2; die "unknown argument: '$1'" ;;
    esac
    shift
done

# Acted on only once the whole list has been read. Exiting from inside the loop
# meant the loop never reached anything after `--help`, so the same stray word
# was refused or ignored depending on where it sat:
# `uninstall-cron.sh --bogus --help` exited 1 with "unknown argument", while
# `uninstall-cron.sh --help --bogus` printed usage and exited 0. That is the
# wrong way round for a script whose whole argument policy is that anything
# unrecognised is an error, and it is the same defect install-cron.sh fixed by
# moving its arity check ahead of its `case`. This script's grammar takes any
# number of flags in any order, so the equivalent is to finish parsing first.
if [ "$show_help" -eq 1 ]; then
    usage
    exit 0
fi

# --- Is the job actually installed? ------------------------------------------
# Read the crontab ourselves first, so we can say what we found before touching
# anything and can check afterwards that it is gone. As in install-cron.sh, a
# read failure is not treated as "empty crontab": here that would only mislead
# the report, but it is the same distinction and worth keeping identical.
# $1 says what the caller has already done, so a read failure does not claim
# more than it knows. The first read really has changed nothing; the read after
# the removal cannot say that, because by then the job is gone.
read_crontab() {
    local consequence="${1:-Nothing was changed.}"
    local out rc=0 err
    # Checked, not left to `set -e`. This function always runs inside a command
    # substitution, and bash clears `set -e` there -- auto-setup.sh's
    # ask_trimmed() records the same trap -- so a failed mktemp left $err
    # empty and the run carried on. The `2>""` below then failed as a
    # redirect, which made `crontab -l` "exit 1 with no output and nothing on
    # stderr" -- exactly the shape the test further down accepts as "no crontab
    # yet". Measured with TMPDIR pointing at a directory that does not exist:
    # "No cron job found", "Verify with: crontab -l" and exit 0, over a job
    # still installed and still running. That is the read failure this
    # function's own header says must never be treated as an empty crontab.
    err="$(mktemp)" \
        || die "could not create a temporary file (mktemp failed -- check TMPDIR), which is what tells \"there is no crontab yet\" from a crontab that could not be read. $consequence"
    out="$(LC_ALL=C crontab -l 2>"$err")" || rc=$?
    if [ "$rc" -ne 0 ]; then
        # The one `grep` this script runs, checked on the one branch that
        # reaches it. The condition here is deliberately the same one that
        # governs the `grep -qi` two lines below -- status 1, no output, and
        # something on stderr to match -- rather than an approximation of it.
        #
        # It used to sit up front beside `mktemp`, gated only on there being a
        # `crontab` command at all, and those are not the same path: when the
        # crontab is readable `crontab -l` succeeds, this branch is never
        # entered, and no grep is ever invoked. So on a machine with a crontab
        # and no grep, every run was refused with "grep not found" over a
        # command it was never going to use -- including `--dry-run`, which
        # changes nothing, and an ordinary uninstall whose other entries mean
        # the rewrite goes through `crontab -` and the post-removal read
        # succeeds too. That is a precondition enforced on a path that does not
        # use the thing it checks, which is the same defect the `cat`, `chmod`,
        # `date` and `rm` gates in these scripts were each narrowed for, and the
        # one install-cron.sh removed its own grep preflight over.
        #
        # `mktemp` stays up front: read_crontab() opens a temporary file on
        # every call, so that one really is used whenever there is a crontab.
        if [ "$rc" -eq 1 ] && [ -z "$out" ] && [ -s "$err" ]; then
            command -v grep >/dev/null 2>&1 || {
                rm -f "$err"
                die "grep not found. Install it (e.g. 'sudo apt install grep'). It is what tells \"there is no crontab yet\" from a crontab that could not be read, and guessing between those two is not safe. $consequence"
            }
        fi
        # The second alternative is BusyBox's "no crontab yet", the shape
        # install-cron.sh's mentions_no_crontab() explains and accepts.
        if [ "$rc" -ne 1 ] || [ -n "$out" ] \
            || { [ -s "$err" ] \
                && ! grep -qiE "no crontab|can't open '.*': No such file or directory" "$err"; }; then
            # `cat` is checked in usage(), the only other place it is used, and
            # so is not guaranteed here. Passing crontab's diagnostic on is
            # worth having and not worth refusing every ordinary uninstall for:
            # the die() below still names what failed and what was left alone.
            if [ -s "$err" ] && command -v cat >/dev/null 2>&1; then
                cat "$err" >&2
            fi
            rm -f "$err"
            die "could not read the current crontab (crontab -l exited $rc). $consequence"
        fi
        out=""
    fi
    rm -f "$err"
    printf '%s\n' "$out"
}

# Lines that run this checkout's reconnect.sh under our marker. Deliberately
# loose -- it is a report and a post-condition check, not the thing that
# decides what gets deleted -- so a line someone hand-edited still shows up.
#
# Comments are the one thing it must not be loose about, because install-cron.sh
# is not: its `marked()` excludes any line starting with '#', so a job the user
# disabled by commenting it out is invisible to --remove. Matching it here made
# the two scripts disagree -- this one reported "Found the cron job", --remove
# correctly did nothing, and the post-condition check then declared the job
# "still installed" and exited 1 on a crontab that had nothing left to remove.
#
# Matched in the shell, with no pipeline and no external command. It used to be
# three greps ending in `|| true`, and that `|| true` could not tell "no line of
# ours" from "grep failed" -- both come back empty. Everything below is driven
# by the result: an empty one means the script prints "No cron job found for
# <path>.", never calls `install-cron.sh --remove` at all, signs off with
# "Verify with: crontab -l" and exits 0. So a grep that was present (passing the
# preflight below) but failed for any reason reported a successful uninstall
# over a job still sitting in the crontab and still running every interval --
# which is the one outcome this script's header says it is arranged to make
# impossible, arriving through the helper that decides whether there is anything
# to remove.
#
# Measured, before this rewrite: with a `grep` on PATH that exits 2, an
# uninstall over an installed job printed "No cron job found", exited 0, and
# left the line in place.
#
# It is answered the way install-cron.sh answered the same class of defect in
# has_entries() and mentions_no_crontab(): with a `case`, which cannot fail,
# cannot be cut short and needs no subprocess, so there is no failure left for a
# caller to misread. Deliberately not fixed by testing ${PIPESTATUS[@]} instead
# -- install-cron.sh's has_entries() comment says why in full, and the short
# version is that it leaves a helper whose own failure still means "empty",
# which is the shape of the bug rather than the bug.
#
# The three rules: skip a line whose first non-blank character is '#', keep one
# containing the marker anywhere, and keep one that names this checkout's
# reconnect.sh -- quoted (single or double) or as a whole blank-delimited word.
# The marker rule is looser than install-cron.sh's ours(), which wants it at the
# end of the line; tests/DECISIONS.md D7 records why.
#
# The path is *not* a bare substring any more, and that looseness was one step
# too far. A bare substring matched another checkout whose absolute path merely
# ends in this one's -- /home/u/ir inside /mnt/backup/home/u/ir -- so an
# uninstall from the shorter checkout reported the other checkout's job as its
# own, watched --remove correctly leave it, declared it "still installed" and
# exited 1. With --purge-logs it was worse: the log directory is read off the
# first line found here, so `--purge-logs --yes` deleted the *other* job's logs.
# Matching the path as a quoted string or a whole word is exactly the path rule
# ours() applies (plus the double-quoted spelling a hand-edit might produce), so
# this still reports every line --remove would delete, which is the direction D7
# says the looseness must never fail in.
names_our_script() {
    local word path
    for path in "$RECONNECT" "$RECONNECT_ALIAS"; do
        case "$1" in
            *"'$path'"* | *"\"$path\""*) return 0 ;;
        esac
    done
    # `read -a` splits on blanks without globbing, unlike an unquoted `for`.
    local -a words
    read -r -a words <<< "$1"
    for word in "${words[@]}"; do
        [ "$word" != "$RECONNECT" ] || return 0
        [ "$word" != "$RECONNECT_ALIAS" ] || return 0
    done
    return 1
}

our_cron_lines() {
    local line stripped
    while IFS= read -r line; do
        stripped="${line#"${line%%[![:space:]]*}"}"
        case "$stripped" in '#'*) continue ;; esac
        case "$line" in *"$MARKER"*) ;; *) continue ;; esac
        names_our_script "$line" || continue
        printf '%s\n' "$line"
    done <<< "$1"
}

# Not fatal, and not an early exit. "There is no cron job to remove" is the same
# situation this script reports with exit 0 further down when the crontab simply
# has no line of ours, so answering it with exit 1 because cron was never
# installed made the two halves of one answer disagree -- and a script driving
# the uninstall could not tell a machine with nothing to remove from a machine
# where the removal had failed. The suite already pins the other spelling of it:
# "uninstalling twice is not an error".
#
# Exiting also abandoned --purge-logs, which needs no crontab at all: the log
# directory comes from RECONNECT_LOG_DIR or from the default beside this script,
# and only the refinement that reads it off the installed line needs the crontab.
# So the crontab work is skipped and the rest of the run continues.
have_crontab=1
command -v crontab >/dev/null 2>&1 || have_crontab=0

# As in install-cron.sh: a missing one of these would otherwise abort from
# inside a command substitution with a bare "not found".
#
# Only where there is a crontab to read, because that is the only thing that
# uses it: read_crontab() opens a temporary file on every call, and nothing else
# here runs mktemp. Checking it unconditionally would refuse to run over a tool
# the run was never going to reach, which is the same complaint the crontab
# check above was just fixed for.
#
# `grep` used to be checked here too, on the same gate, and this was one gate too
# wide for it: read_crontab() runs grep only when `crontab -l` *fails*, so a
# readable crontab never reaches one. The check now sits on that branch, beside
# the grep it is about; see read_crontab(). `grep` also used to have a second
# caller here, our_cron_lines(), which is a shell `case` now and runs none.
if [ "$have_crontab" -eq 1 ]; then
    command -v mktemp >/dev/null 2>&1 \
        || die "mktemp not found. Install coreutils."
fi

# `rm` has two call sites here and both are conditional, so this check is too,
# by the same rule as the two above. This is the half that clears
# read_crontab()'s temporary file, where a failure would abort a run that had
# changed nothing; the purge's own half is checked further down, immediately
# after the thing it would delete has been counted.
#
# It used to sit with `cat` at the top, unconditionally, and that turned a run
# with nothing to do into a failed one: on a machine with no crontab and without
# --purge-logs, `rm` is never invoked, yet the run exited 1 with "rm not found"
# where it would otherwise have printed "crontab not found, so there is no cron
# job to remove." and exited 0. A script driving the uninstall could then not
# tell "nothing to do" from "the removal failed", which is the one distinction
# the have_crontab handling above exists to preserve -- so the check defeated,
# on a different tool, exactly what the code beneath it was written to protect.
#
# Two later passes each widened the condition by one term -- first `--purge-logs`,
# then `--dry-run` -- and each time the same defect turned up one flag further
# along, because a condition written here can only guess at what the purge will
# find. It is split instead of widened a third time; see the check below.
if [ "$have_crontab" -eq 1 ]; then
    command -v rm >/dev/null 2>&1 \
        || die "rm not found. Install coreutils."
fi

# The log directory the installed job actually writes to. install-cron.sh puts
# RECONNECT_LOG_DIR on the cron line single-quoted, so it can simply be read back
# -- and reading it is what stops --purge-logs looking in the wrong place. This
# used to default to $SCRIPT_DIR/logs and ignore the line entirely, so an install
# made with a custom RECONNECT_LOG_DIR was uninstalled with "No daily logs to
# delete" and exit 0 while every log survived: a cleanup reported but never
# performed, and reported using a value this script had just printed on screen.
#
# The unquoted branch mirrors install-cron.sh's previous_value(), for a line
# someone unquoted by hand.
log_dir_from_cron_line() {
    local line="$1" rest
    case "$line" in
        *"RECONNECT_LOG_DIR="*) rest="${line#*RECONNECT_LOG_DIR=}" ;;
        *) return 1 ;;
    esac
    case "$rest" in
        "'"*) rest="${rest#\'}"; printf '%s' "${rest%%\'*}" ;;
        *) printf '%s' "${rest%%[[:space:]]*}" ;;
    esac
}

# Both stay empty where there is no crontab command to read one with, which is
# the same shape as "the crontab holds no line of ours" and is handled as such
# everywhere below. read_crontab() is not reached at all, so its mktemp and its
# `crontab -l` are not either.
before=""
installed=""
if [ "$have_crontab" -eq 1 ]; then
    before="$(read_crontab)"
    installed="$(our_cron_lines "$before")"
fi

# An explicit RECONNECT_LOG_DIR still wins: it is the documented way to point
# this at a directory no cron line names, which is the only option left once the
# job has already been removed. Where it is unset, the installed line is a better
# answer than the default -- it is what the job is actually using.
#
# Only if it is absolute. install-cron.sh refuses to write a relative value onto
# the line and refuses to carry one back off it, with the reason spelled out at
# its own check: cron runs the job from the user's home directory, while this
# script resolves a relative path against wherever it happened to be run from.
# Reading one back here and acting on it applied that mismatch to a *deletion*.
# With RECONNECT_LOG_DIR='mylogs' hand-edited onto the line, `--purge-logs --yes`
# run from any directory that happens to contain a mylogs/ deleted every
# YYYY-MM-DD.log and the .lock inside it -- files this tool never wrote -- while
# the job's real logs under $HOME/mylogs survived, and the report said only
# "Deleted 1 log file(s) from mylogs", a relative path from which the user could
# not tell which directory had been cleared.
#
# Ignored rather than refused, because refusing would block the cron removal over
# a value only the log purge uses -- the same rule that keeps an install-time
# setting from blocking an uninstall. The default stands instead, and the note
# says so: silently falling back would leave the purge looking in the wrong place
# with nothing to explain it, which is the defect log_dir_from_cron_line() was
# added to fix.
if [ -z "${RECONNECT_LOG_DIR:-}" ] && [ -n "$installed" ]; then
    from_line="$(log_dir_from_cron_line "${installed%%$'\n'*}" || true)"
    case "$from_line" in
        '') ;;
        /*) LOG_DIR="$from_line" ;;
        *)
            echo "NOTE: the installed cron line names a relative log directory," >&2
            echo "      RECONNECT_LOG_DIR='$from_line', which cron resolves against your" >&2
            echo "      home directory and this script would resolve against the directory" >&2
            echo "      you are in. It was ignored rather than guessed at; $LOG_DIR" >&2
            echo "      is being used instead. To purge the job's real logs, name them:" >&2
            echo "        RECONNECT_LOG_DIR=\"\$HOME/$from_line\" $0 --purge-logs" >&2
            ;;
    esac
fi

if [ -n "$installed" ]; then
    echo "Found the cron job:"
    # One printf per line. `printf FMT "$installed"` reuses its format once per
    # *argument*, and a multi-line string is a single argument, so a crontab
    # carrying more than one matching line printed the first indented and the
    # rest flush against the left margin. our_cron_lines() is deliberately loose
    # and really can return several, which is the case this exists for. The
    # `printf '  %s\n' "${log_files[@]}"` calls below pass an array, where the
    # reuse is the point rather than a bug -- the two spellings look identical
    # and behave differently.
    while IFS= read -r cron_line; do
        printf '  %s\n' "$cron_line"
    done <<< "$installed"
elif [ "$have_crontab" -eq 0 ]; then
    # Said out loud rather than folded into the line below. "No cron job found"
    # would be true but would imply the crontab was read and came back without
    # one, which is a different fact from "there is no cron on this machine" --
    # and the second is the one worth knowing if you expected a job to be there.
    echo "crontab not found, so there is no cron job to remove."
else
    echo "No cron job found for $RECONNECT."
fi

# --- Logs to purge -----------------------------------------------------------
# Only files named exactly YYYY-MM-DD.log are ours: that is what reconnect.sh
# writes, and anything else in that directory belongs to the user. The same
# restraint reconnect.sh shows when it prunes old logs.
log_files=()
lock_file=""
if [ "$purge_logs" -eq 1 ] && [ -d "$LOG_DIR" ]; then
    for file in "$LOG_DIR"/*.log; do
        [ -f "$file" ] || continue
        base="${file##*/}"
        case "${base%.log}" in
            [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) log_files+=("$file") ;;
        esac
    done
    # The lock file is ours too. reconnect.sh creates it and never removes it,
    # so a purge that took only the daily logs left it sitting in a directory it
    # had just reported as cleared of this tool's output. Nothing else reads it
    # and the next run recreates it, so there is nothing to preserve.
    [ ! -f "$LOG_DIR/.lock" ] || lock_file="$LOG_DIR/.lock"
fi

# The purge's own `rm` check, and it sits here rather than up with the crontab
# one because here is the first point at which the answer is known rather than
# guessed. The condition up there was widened twice -- once for `--purge-logs`,
# once for `--dry-run` -- and each widening left the same defect one step
# further on: with no crontab and no `rm`, `--purge-logs --yes` over an empty
# log directory exited 1 with "rm not found" where the answer is "crontab not
# found, so there is no cron job to remove." followed by "No daily logs to
# delete in ..." and exit 0. That is a run with nothing to do reported as a
# failed one, over a command it was never going to invoke -- the same complaint
# the have_crontab handling and the two earlier narrowings were each written to
# answer, arriving through the one case a condition written before the scan
# cannot see: whether there is anything to delete at all.
#
# The scan above is what settles it, so the check goes after the scan and asks
# about its result. A dry run is still excluded, because it exits before the
# purge block and deletes nothing.
#
# Still ahead of everything that changes state -- the cron removal is below --
# so a run that genuinely cannot purge is refused before it has done half a job,
# which is what checking up front bought in the first place.
if [ "$purge_logs" -eq 1 ] && [ "$dry_run" -eq 0 ] \
    && { [ "${#log_files[@]}" -gt 0 ] || [ -n "$lock_file" ]; }; then
    command -v rm >/dev/null 2>&1 \
        || die "rm not found. Install coreutils."
fi

# What a purge would actually delete, in words. The count on its own read
# "0 log file(s)" whenever the lock file was the only thing left to remove, so
# the confirmation -- and the refusal, where there is nobody to confirm -- asked
# the user about deleting nothing while a file sat there waiting to be deleted.
purge_targets() {
    if [ "${#log_files[@]}" -gt 0 ] && [ -n "$lock_file" ]; then
        printf '%s log file(s) and the lock file' "${#log_files[@]}"
    elif [ "${#log_files[@]}" -gt 0 ]; then
        printf '%s log file(s)' "${#log_files[@]}"
    else
        printf 'the lock file'
    fi
}

# --- Dry run -----------------------------------------------------------------
if [ "$dry_run" -eq 1 ]; then
    # Say what would happen to the cron job, not just to the logs. Reporting
    # only the logs left the caller to infer the main action from the "Found
    # the cron job" line printed further up, which is the one thing a dry run
    # exists to spell out.
    #
    # What would be removed is asked of install-cron.sh, which does the removing.
    # $installed is this script's loose report (D7) and can hold a line --remove
    # will leave -- one edited after the marker, say -- and answering off it
    # promised "Would remove the cron job" over a line the real run then left in
    # place, ending in the "still installed" WARNING and exit 1. Lines reported
    # here that install-cron.sh will not take are named as what they are.
    if [ -n "$installed" ]; then
        [ -f "$INSTALLER" ] \
            || die "install-cron.sh not found next to this script (expected at $INSTALLER); it is what removes the cron entry, and what says which lines it would remove."
        would_remove="$(bash "$INSTALLER" --remove-dry-run)" \
            || die "install-cron.sh --remove-dry-run failed. Nothing was changed."
        [ -z "$would_remove" ] || echo "Would remove the cron job for $RECONNECT."
        would_leave=""
        while IFS= read -r cron_line; do
            case $'\n'"$would_remove"$'\n' in
                *$'\n'"$cron_line"$'\n'*) ;;
                *) would_leave="$would_leave$cron_line"$'\n' ;;
            esac
        done <<< "$installed"
        if [ -n "$would_leave" ]; then
            echo "Would leave this line in place: it runs this checkout's reconnect.sh,"
            echo "but install-cron.sh does not recognise it as its own, so the real run"
            echo "would report it as still installed and exit 1. Remove it by hand with"
            echo "'crontab -e':"
            while IFS= read -r cron_line; do
                [ -z "$cron_line" ] || printf '  %s\n' "$cron_line"
            done <<< "$would_leave"
        fi
    else
        echo "No cron job to remove."
    fi
    if [ "$purge_logs" -eq 1 ]; then
        if [ "${#log_files[@]}" -gt 0 ]; then
            echo "Would delete ${#log_files[@]} log file(s) from $LOG_DIR:"
            printf '  %s\n' "${log_files[@]}"
        else
            echo "No daily logs to delete in $LOG_DIR."
        fi
        [ -z "$lock_file" ] || echo "Would also delete the lock file $lock_file."
    fi
    echo
    echo "Dry run: nothing was changed."
    exit 0
fi

# --- Remove the cron job -----------------------------------------------------
if [ -n "$installed" ]; then
    [ -f "$INSTALLER" ] \
        || die "install-cron.sh not found next to this script (expected at $INSTALLER); it is what removes the cron entry."
    bash "$INSTALLER" --remove \
        || die "install-cron.sh --remove failed; the crontab was left as it was."
    job_outcome=removed

    # Check rather than assume. The installer only deletes lines it is certain
    # are its own, so a line that has been hand-edited past recognition can
    # survive a successful --remove -- and an uninstaller that then reports
    # success would leave the job running.
    # The read gets an assignment of its own. Nested inside the substitution
    # that consumed it, read_crontab()'s die exited only that subshell -- `set
    # -e` never saw it, because a failing substitution used as an *argument* is
    # not a checked command. The empty result then read as "no line left", so a
    # crontab this script had just failed to read was reported as a verified
    # uninstall: the read error went to stderr, "Verify with: crontab -l"
    # followed it, and the script exited 0. As its own assignment the failure is
    # fatal, the way `before=` above already is.
    after="$(read_crontab "The cron job was removed, but this run could not confirm it. Check with 'crontab -l'.")"
    leftover="$(our_cron_lines "$after")"
    if [ -n "$leftover" ]; then
        echo "WARNING: a cron line for $RECONNECT is still installed:" >&2
        # Per line, for the reason given where "Found the cron job:" is printed.
        while IFS= read -r cron_line; do
            printf '  %s\n' "$cron_line" >&2
        done <<< "$leftover"
        echo "         It no longer matches what install-cron.sh writes, so it was left" >&2
        echo "         alone. Remove it by hand with 'crontab -e'." >&2
        # The job is still scheduled, so this run did not do what it was asked
        # to do. Exiting 0 here would tell a script that called us that the
        # uninstall succeeded.
        exit_status=1
        job_outcome=left
    fi
fi

# --- Purge logs --------------------------------------------------------------
if [ "$purge_logs" -eq 1 ]; then
    if [ "${#log_files[@]}" -eq 0 ] && [ -z "$lock_file" ]; then
        echo "No daily logs to delete in $LOG_DIR."
    else
        if [ "$assume_yes" -ne 1 ]; then
            # Without a terminal there is nobody to answer, and deleting logs
            # on a silent default is not a decision to make for the user.
            #
            # The refusal names what has already happened as well as what has
            # not. By the time it fires the cron job is gone -- the removal runs
            # first -- so "needs confirmation" on its own, followed by exit 1,
            # told a caller scripting the uninstall that the run had failed when
            # its main action had succeeded. Same reason read_crontab() takes a
            # consequence argument: a message is only true of the moment it is
            # printed at.
            if [ ! -t 0 ]; then
                case "$job_outcome" in
                    removed) purge_consequence="The cron job was removed; the logs were kept." ;;
                    left) purge_consequence="A cron line is still installed (see the WARNING above); the logs were kept." ;;
                    *) purge_consequence="Nothing was changed." ;;
                esac
                die "--purge-logs needs confirmation and there is no terminal to ask at. $purge_consequence Re-run with --yes to delete $(purge_targets) from $LOG_DIR."
            fi
            echo
            echo "About to delete $(purge_targets) from $LOG_DIR:"
            [ "${#log_files[@]}" -eq 0 ] || printf '  %s\n' "${log_files[@]}"
            [ -z "$lock_file" ] || printf '  %s (lock file)\n' "$lock_file"
            printf 'Delete them? [y/N] '
            # `|| true` rather than a bare read. Under `set -e` a read that
            # hits EOF -- Ctrl-D at the prompt -- exited 1 straight out of the
            # script: no "Kept the logs.", no message of any kind, and the
            # exit_status accumulated above thrown away, so a deliberate cancel
            # was indistinguishable from a crash. An empty answer falls through
            # to the `*)` arm below, which is already the "keep them" case.
            #
            # And not `|| reply=""`, which is what stood here: an answer typed
            # without a newline before Ctrl-D is still an answer -- `read`
            # returns 1 but assigns it -- and clearing it turned a typed "y"
            # into "Kept the logs.". auto-setup.sh's ask() takes an
            # unterminated answer the same way.
            reply=""
            read -r reply || true
            case "$reply" in
                [yY] | [yY][eE][sS]) ;;
                *) echo "Kept the logs."; exit "$exit_status" ;;
            esac
        fi
        [ "${#log_files[@]}" -eq 0 ] || rm -f -- "${log_files[@]}"
        [ -z "$lock_file" ] || rm -f -- "$lock_file"
        # Only when there were any. "Deleted 0 log file(s)." followed by
        # "Deleted the lock file ..." reported a deletion that did not happen
        # alongside one that did.
        [ "${#log_files[@]}" -eq 0 ] \
            || echo "Deleted ${#log_files[@]} log file(s) from $LOG_DIR."
        [ -z "$lock_file" ] || echo "Deleted the lock file $lock_file."
    fi
fi

# Only where there is a crontab to verify with. Sending someone to run
# `crontab -l` on a machine that has just been reported as having no crontab
# command is advice that cannot be followed, and it reads as though the run had
# checked something it did not.
if [ "$have_crontab" -eq 1 ]; then
    echo
    echo "Verify with:  crontab -l"
fi

exit "$exit_status"
