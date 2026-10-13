#!/usr/bin/env bash
#
# install-cron.sh
#
# Installs (or removes) a cron entry that runs reconnect.sh every 5 minutes.
# Idempotent: running it repeatedly will not create duplicate entries.
#
# Usage (from the checkout root):
#   ./manual-setup/install-cron.sh            # install / update the every-5-minutes job
#   ./manual-setup/install-cron.sh --remove   # remove the job
#   ./manual-setup/install-cron.sh --remove-dry-run  # print what --remove would delete
#   ./manual-setup/install-cron.sh --help     # show usage
#   MINUTES=10 ./manual-setup/install-cron.sh # install with a different interval

set -euo pipefail

# For the reason written out in reconnect.sh: an exported CDPATH makes the `cd`
# below print into the substitution that resolves this script's directory.
# `bash manual-setup/install-cron.sh` is the spelling that reaches it.
unset CDPATH

# Split with parameter expansion rather than `dirname`, matching reconnect.sh,
# where the same line runs before anything can report a failure and the reasoning
# is written out in full. Here the payoff is smaller -- this script's stderr is
# not thrown away -- but one idea of how the script finds itself, shared by all
# four, is worth more than the two lines it costs. `*/*` fails for a bare name
# (`bash install-cron.sh`), which means the current directory; the empty result
# is a script sitting directly in `/`.
script_src="${BASH_SOURCE[0]}"
case "$script_src" in
    */*)
        script_dir="${script_src%/*}"
        [ -n "$script_dir" ] || script_dir=/
        ;;
    *) script_dir=. ;;
esac
#
# `pwd -P`, the physical path, in all four scripts. A plain `pwd` reports the
# path the way it was reached, so a checkout reached through a symlink (a
# symlinked home directory, or `~/ir -> /mnt/data/ir`) had two spellings, and
# the cron line recorded whichever one the installer happened to be run through.
# Re-installing through the other spelling then failed ours()' path test, called
# this checkout's own line "a different copy of reconnect.sh", left it in place
# and appended a second job -- two jobs for one checkout, on the re-install the
# README calls idempotent. The physical path is the same whichever way in.
SCRIPT_DIR="$(cd "$script_dir" && pwd -P)"
# This script lives in manual-setup/, one level below the checkout root, and
# everything it schedules or writes about lives at the root: reconnect.sh,
# config.env, logs/, auto-setup.sh and tests/. The root is resolved once here
# and used for all of them, so moving this directory again means changing one
# line. Only install-cron.sh, uninstall-cron.sh and config.env.example sit
# beside this file.
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
RECONNECT="$ROOT_DIR/reconnect.sh"
# The spelling a plain `pwd` gives for the way this run reached the checkout.
# Lines are only ever *written* with $RECONNECT, but a line an earlier version
# wrote through a symlink names this spelling instead, and it is still this
# checkout's line: matched as ours, so a re-install replaces it rather than
# leaving it as "another copy" beside a new one. Equal to $RECONNECT whenever no
# symlink is involved.
RECONNECT_ALIAS="$(cd "$script_dir/.." && pwd)/reconnect.sh"
MARKER="# InternetReconnector"          # tag used to find/replace our line

# Left empty when the caller did not set it. The default is not applied here,
# because "unset" has to stay distinguishable from "explicitly 5" until the
# previously installed interval has been read off the crontab further down.
MINUTES_REQUESTED="${MINUTES:-}"

die() {
    echo "ERROR: $*" >&2
    exit 1
}

# True when $1 -- digits only by the time it gets here -- is narrow enough for
# bash to do arithmetic on. This is reconnect.sh's fits_in_integer(), deliberately
# identical, because the two scripts have to refuse exactly the same set of values.
#
# They did not. Every numeric bound in this script is `[ "$((10#$value))" -ge N ]`,
# and bash arithmetic is intmax_t that wraps in silence: `10#99999999999999999999`
# is 7766279631452241919, which is comfortably >= 1, so
# RECONNECT_CONNECT_ATTEMPTS=99999999999999999999 passed validation here and was
# written onto the cron line. reconnect.sh bounds the same setting with
# `[ ... -ge 1 ]`, where `test` refuses an out-of-range integer outright -- so the
# install reported success and every scheduled run then died, with the reason going
# to /dev/null. That is precisely the FAIL-every-interval outcome validating here
# exists to prevent, produced by the validation itself. The comment further down
# claiming these rules "deliberately mirror reconnect.sh's" was false for exactly
# this class of value.
#
# It also fixes the message. `validate_minutes()` normalised with `$((10#$n))`
# before its range check, so an over-wide MINUTES was refused with
# "must be between 1 and 59; got: 7766279631452241919" -- a number the user never
# typed. The width test runs before the normalisation now, so the value that is
# echoed back is the one that arrived.
#
# Leading zeros are stripped before the width is measured, so 0000000000000000000030
# is still a legal 30. Eighteen digits is the widest run that cannot overflow a
# signed 64-bit integer.
fits_in_integer() {
    local n="${1#"${1%%[!0]*}"}"
    [ "${#n}" -le 18 ]
}

usage() {
    # Checked here rather than at the top of the file, because this is one of
    # only two places the script uses `cat` and both are conditional: this one
    # is reached by --help and by an argument error, the other by a *failed*
    # crontab read. An ordinary install or removal calls neither.
    #
    # Up there it was unconditional, and that turned a run that would have
    # worked into a refusal: on a machine with no `cat`, a plain
    # ./install-cron.sh exited 1 with "cat not found" without going anywhere
    # near a heredoc. Same rule as the MINUTES, chmod, date, rm and sleep gates
    # -- a precondition belongs on the path that uses it.
    #
    # The check still has to run before the heredoc rather than after it: under
    # `set -e` a failed `cat` aborts the script before the `exit 0` that follows
    # usage(), so --help would print an empty screen and exit 1 with nothing
    # said. Inside the function it is ahead of the heredoc by construction.
    command -v cat >/dev/null 2>&1 \
        || die "cat not found. Install coreutils."
    cat <<'USAGE'
Usage: install-cron.sh [--remove | --remove-dry-run | --help]

  (no arguments)   Install or update the cron job that runs reconnect.sh.
  --remove         Remove the cron job.
  --remove-dry-run Print the cron lines --remove would delete, one per line,
                   and change nothing. uninstall-cron.sh --dry-run uses it.
  --help, -h       Show this message.

Environment:
  MINUTES=N        Run every N minutes. Must divide 60 evenly: 1, 2, 3, 4, 5,
                   6, 10, 12, 15, 20 or 30. Defaults to the interval already on
                   the installed cron line, or to 5 if there is none, so
                   re-running this script does not reset an interval you chose
                   earlier.

  RECONNECT_*      Any of RECONNECT_CONFIG, RECONNECT_LOG_DIR,
                   RECONNECT_LOG_RETENTION_DAYS, RECONNECT_SCAN_WAIT_SECS,
                   RECONNECT_CONNECT_ATTEMPTS or RECONNECT_NMCLI_WAIT_SECS set
                   here is written onto the cron line. Values already on an
                   installed line are kept when you re-run this script. The
                   numeric ones are validated here, so a value reconnect.sh
                   would reject is refused now rather than failing silently on
                   every scheduled run.

                   Setting one to an empty string does not clear it: an empty
                   value is indistinguishable from an unset one, so the value
                   already on the line is kept. To get back to the defaults,
                   run --remove and then install again. That clears the
                   interval too, so pass MINUTES again if you had changed it.

                   RECONNECT_CONFIG and RECONNECT_LOG_DIR must be absolute
                   paths, and a relative one is refused. Cron runs the job from
                   your home directory rather than from this one, so a relative
                   path would not point where it points when you type it. A
                   config the job could not read, and a log directory it could
                   never create or write, are noted after the install.

  CRON_PATH=P      The PATH written onto the cron line. Defaults to the
                   interval-style carry-over: whatever is on the installed line,
                   or the standard six system directories if there is none.
                   Widen it when nmcli lives somewhere else -- this script says
                   so, and prints the exact command, when it notices.
USAGE
}

# --- Parse arguments ---------------------------------------------------------
# Anything unrecognised is an error. Silently installing the job in response to
# e.g. `--help` would be a nasty surprise.
# The arity check comes first so it applies to every flag alike. It used to sit
# after the case, where `--help` had already exited 0 -- so `--help extra`
# silently ignored the extra word while `--remove extra` rejected it, which is
# the wrong way round for a script whose whole argument policy is "anything
# unrecognised is an error".
#
# The count is what decides whether there is an argument at all, rather than a
# `'')` arm in the case below. `"${1:-}"` collapses "no argument" and "an empty
# argument" into the same empty string, so `./install-cron.sh ""` matched that
# arm, installed the cron job and exited 0 -- which is exactly the "silently
# installing the job in response to an argument" surprise the paragraph above
# names as the reason this policy exists, arriving through the one spelling the
# policy could not see. `./install-cron.sh "$mode"` with $mode unset is how a
# wrapper produces it, and the other two scripts refuse the same input:
# uninstall-cron.sh's parsing loop is driven by `$#` and reconnect.sh tests `$#`
# directly, so both send an empty argument to their "unknown" arm. Testing the
# count here makes all three agree.
#
# The value is quoted in the refusal for the reason reconnect.sh's WIFI_HIDDEN
# check quotes its own: unquoted, that empty argument produced
# `ERROR: unknown argument: ` -- a message naming nothing, which sends the reader
# looking for a word they cannot see.
mode=install
[ "$#" -le 1 ] || { usage >&2; die "too many arguments"; }
if [ "$#" -eq 1 ]; then
    case "$1" in
        --remove) mode=remove ;;
        --remove-dry-run) mode=remove-dry-run ;;
        -h | --help) usage; exit 0 ;;
        *) usage >&2; die "unknown argument: '$1'" ;;
    esac
fi

# --- Validate the interval ---------------------------------------------------
# The value is interpolated straight into the crontab, so it has to be a plain
# number in range: anything else would produce a malformed schedule or splice
# extra content into the user's crontab. $2 names where the value came from, so
# a rejected value carried off an existing cron line does not read as if the
# user had just typed it.
# The rejected value is quoted in every message here, for the reason
# reconnect.sh's WIFI_HIDDEN check quotes its own and writes out in full.
# `MINUTES` arrives from the environment, so `MINUTES="$n" ./install-cron.sh`
# with $n blank is how it comes in -- and unquoted the first arm produced
# `MINUTES must be a whole number of minutes; got: ` with nothing after it, a
# refusal naming nothing at all. A tab was worse than a space: it printed as
# alignment, so the message did not even look truncated.
validate_minutes() {
    local n="$1" what="$2"
    case "$n" in
        '' | *[!0-9]*) die "$what must be a whole number of minutes; got: '$n'" ;;
    esac

    # Ahead of the normalisation below, so that the value echoed back is the one
    # the caller typed rather than what bash's arithmetic turned it into. See
    # fits_in_integer().
    fits_in_integer "$n" \
        || die "$what must be between 1 and 59; got: '$n'"

    # Forced to base 10 before any arithmetic. Bash reads a leading zero as
    # octal, so `08` and `09` are not numbers at all: `$((60 % n))` below failed
    # with "value too great for base", and because a failed expansion in a `case`
    # word does not trip `set -e`, validate_minutes returned as though the value
    # had passed. `MINUTES=08` printed a bash diagnostic nobody could act on and
    # then installed `*/08` -- an interval that does not divide 60, which is the
    # one thing this function exists to reject -- and exited 0.
    n=$((10#$n))

    # $n is the normalised number by this point, not what was typed -- `08`
    # reaches here as 8. Quoted anyway, so every refusal in this function has one
    # shape and nobody has to work out which of them shows the raw value.
    { [ "$n" -ge 1 ] && [ "$n" -le 59 ]; } \
        || die "$what must be between 1 and 59; got: '$n'"

    # `*/N` restarts the count at the top of every hour, so it is only a
    # uniform "every N minutes" when N divides 60. `*/7` fires at :00 .. :56
    # and then waits four minutes, which is not what the flag says it does.
    # Rejecting the values that cannot be expressed beats silently scheduling
    # something else.
    case "$((60 % n))" in
        0) ;;
        *) die "$what must divide 60 evenly (1, 2, 3, 4, 5, 6, 10, 12, 15, 20, 30), otherwise cron leaves an uneven gap at the top of each hour; got: '$n'" ;;
    esac
}

# Reject a bad MINUTES before touching the crontab, so the failure comes back
# straight away rather than after the read. It is validated again once the
# interval has actually been resolved, which is what the cron line is built
# from.
#
# Only on an install. `--remove` never reads the interval, so validating it
# there refused to take a job back out over a value the removal would not have
# used: an exported `MINUTES=7` made `--remove` exit 1 with "MINUTES must divide
# 60 evenly" and leave the job installed, and uninstall-cron.sh -- which shells
# out to this script and passes its environment along -- failed the same way,
# reporting only that the removal had failed. An uninstall should not be
# blocked by an install-time setting.
if [ "$mode" = install ] && [ -n "$MINUTES_REQUESTED" ]; then
    validate_minutes "$MINUTES_REQUESTED" MINUTES
fi

command -v crontab >/dev/null 2>&1 \
    || die "crontab not found. Install cron (e.g. 'sudo apt install cron')."

# Checked up front for the same reason reconnect.sh checks nmcli and awk: under
# `set -e` a missing one aborts from inside a command substitution with a bare
# "not found" and no indication of which step wanted it.
command -v mktemp >/dev/null 2>&1 \
    || die "mktemp not found. Install coreutils."
command -v awk >/dev/null 2>&1 \
    || die "awk not found. Install one (e.g. 'sudo apt install gawk')."

# `grep` used to be checked here too, and this script no longer runs it at all.
# It had two call sites and both are gone: has_entries() now answers with a
# `case` because a pipeline could not tell a failure from an empty crontab, and
# the "no crontab yet" test above the read is a `case` for the reason written out
# beside mentions_no_crontab().
#
# Removing the check matters on its own, not only as tidying. `--remove` over a
# crontab that holds no line of ours reads it with `crontab -l`, classifies it
# with awk and writes nothing -- so it never touched grep, yet on a machine
# without one it exited 1 with "grep not found" where the answer is "No
# InternetReconnector cron job found; nothing to remove." and exit 0. That is a
# run with nothing to do turned into a failed removal, which is exactly what the
# `date` gate below and uninstall-cron.sh's conditional mktemp, grep and rm
# checks exist to prevent, and the two scripts disagreed about this one command.
#
# uninstall-cron.sh still runs one grep and still checks for it, and that is not
# the same oversight read back. Its grep sits inside read_crontab(), on the
# branch where `crontab -l` has failed, telling "no crontab yet" from a read
# failure -- the job mentions_no_crontab() does here without grep -- and the
# check for it sits on that same branch, so a readable crontab never meets
# either. (This paragraph used to say its our_cron_lines() "really does run
# three greps" and that the check was gated on there being a crontab at all;
# both were true once and neither is now -- our_cron_lines() is a shell `case`
# loop, and the gate was narrowed to the branch that uses the command. A
# description of the sibling script that lags two rewrites behind sends a
# reader auditing the preflight set after greps that are not there.)

# `rm` is here for a different reason from the two above: it is not reached
# from a command substitution but from the EXIT trap set a few lines below, where
# a failure arrives after all the work is done and can replace a successful run's
# status with the trap's. uninstall-cron.sh has always checked it and this script
# never did -- and two scripts that preflight the same commands for the same
# stated reasons, disagreeing about one of them, is the shape an oversight takes.
command -v rm >/dev/null 2>&1 \
    || die "rm not found. Install coreutils."

# The check below is install-only, which is why it sits inside this guard and the
# four unconditional ones above do not. `--remove` never reaches `date`: it is
# used only by the closing summary's example filename. (`usage()` carries a fifth
# `command -v` further up the file, but that one is conditional by construction --
# it only runs when usage() is called -- so it is not one of the four.)
#
# This block used to hold two checks, and the sentence above used to say so and
# to count six unconditional ones. Every one of those figures has gone stale in
# turn, always in the pass that moved a check: `chmod` moved out of here to its
# own call site in the executable-bit loop below, `cat` moved out into `usage()`,
# and `grep` was deleted once nothing in this script ran it any more. The counts
# are worth keeping correct rather than dropping, because this comment is what a
# reader audits the preflight set against -- and one that says "two below"
# invites putting `chmod` back here, which is exactly the defect its move
# removed. If you move or delete another one, re-count both figures here.
#
# Checked unconditionally, `date` -- and `chmod` while it was still here --
# refused to take a job back out over a tool the removal was never going to
# reach, and because uninstall-cron.sh shells out to `install-cron.sh --remove`,
# the whole uninstall failed with "install-cron.sh --remove failed; the crontab
# was left as it was" and the job stayed scheduled. That is exactly the failure
# the MINUTES validation above was gated for ("An uninstall should not be blocked
# by an install-time setting"), and the same principle uninstall-cron.sh states
# where it checks mktemp and grep only when there is a crontab to use them on.
if [ "$mode" = install ]; then
    # `chmod` used to be checked here too, and install-only was not a narrow
    # enough gate for it: the loop further down runs `chmod` only for a script
    # whose executable bit is actually missing, and on an ordinary checkout --
    # a clone with the committed modes intact -- there is never one. So this
    # refused a perfectly good install over a command that install was not
    # going to invoke, which is the defect the gate above exists to prevent,
    # one step further in. It now sits at the call site; see the loop.

    # reconnect.sh needs date to name its log file and dies without it, so a job
    # installed on a machine that has no date can never do anything but fail.
    # This script uses it directly too, in the closing summary's example
    # filename -- where a missing one produced "e.g. .log" and said nothing,
    # because the substitution is an argument to echo and `set -e` does not fire
    # on it.
    command -v date >/dev/null 2>&1 \
        || die "date not found. Install coreutils (reconnect.sh needs it to name its log files)."
fi

# --- Read the current crontab ------------------------------------------------
# "No crontab yet" and "could not read the crontab" both make `crontab -l` exit
# non-zero. Treating them alike would be destructive: on a read failure we would
# see an empty crontab, and then write back only our own line -- wiping every
# other entry the user has. So only the recognised "no crontab" case is allowed
# through, and anything else aborts before we write.
#
# LC_ALL=C keeps cron's diagnostics in English so the check below is stable.
#
# True when crontab's diagnostic says there is simply no crontab yet, matched
# case-insensitively the way `grep -qi 'no crontab'` used to. Doing it with a
# `case` rather than with grep is what lets this script drop its `grep`
# preflight altogether: grep was checked for on every run, and after
# has_entries() stopped using it this was the only call site left -- one that an
# ordinary first-ever install reaches, because "no crontab for <user>" *is* the
# empty case. Guarding it with `command -v grep` instead would have been worse
# than either: with no grep there is no way to tell "no crontab yet" from a real
# read failure, so the guard would have to pick between refusing every first
# install on such a machine and treating a failed read as an empty crontab,
# which is the destructive answer this whole block exists to refuse.
#
# `$(<file)` is a bash builtin read with no fork, so nothing here needs a
# command on PATH. The bracket expressions are a per-letter case fold rather than
# `shopt -s nocasematch`, which would leave a global shell option set for the
# rest of the run; the space between the words is literal, as it was under grep.
#
# The second arm is BusyBox's spelling of the same case. Its `crontab -l` just
# opens the user's file in the spool directory and, when there is none, says
# `crontab: can't open '<user>': No such file or directory` and exits 1 -- no
# "no crontab" anywhere, so every first install on a BusyBox cron was refused
# as a read failure, while the README says such a system otherwise works. Only
# that exact shape is taken: the same message with any other reason (Permission
# denied, say) is a real read failure and is still refused, and a spool
# directory that is missing fails earlier with "can't change directory". This
# is matched on BusyBox's source, not on a run against a real BusyBox cron.
# uninstall-cron.sh and auto-setup.sh recognise the same two shapes.
mentions_no_crontab() {
    case "$1" in
        *[Nn][Oo]" "[Cc][Rr][Oo][Nn][Tt][Aa][Bb]*) return 0 ;;
        *"can't open '"*"': No such file or directory"*) return 0 ;;
        *) return 1 ;;
    esac
}

cron_err="$(mktemp)"
# Single quotes so $cron_err is expanded when the trap runs, not now: embedding
# the path into the trap string broke on a TMPDIR containing a quote.
trap 'rm -f "$cron_err"' EXIT

current=""
rc=0
current="$(LC_ALL=C crontab -l 2>"$cron_err")" || rc=$?
if [ "$rc" -ne 0 ]; then
    if [ "$rc" -ne 1 ] || [ -n "$current" ] \
        || { [ -s "$cron_err" ] && ! mentions_no_crontab "$(<"$cron_err")"; }; then
        # `cat` is no longer preflighted on every run -- it is checked inside
        # usage(), the only other place it is used -- so it may genuinely be
        # absent here. Losing crontab's own diagnostic is much the smaller loss:
        # the refusal below still states what happened and still leaves the
        # user's entries alone, whereas a preflight would have refused every
        # install on this machine over a command almost none of them run.
        if [ -s "$cron_err" ] && command -v cat >/dev/null 2>&1; then
            cat "$cron_err" >&2
        fi
        die "could not read the current crontab (crontab -l exited $rc). Refusing to continue, so your existing cron entries are left untouched."
    fi
    current=""
fi

# --- Deciding which crontab lines are ours -----------------------------------
# A line is ours only when all three hold: it is not a comment, it ends with our
# marker, and its command runs *this* checkout's reconnect.sh. Each rule earns
# its place. Matching the marker anywhere swallowed a user's own note that
# merely mentioned InternetReconnector, and matching the suffix alone still
# swallowed one ending in those words -- our entry is a crontab command, so it
# never starts with '#', and that is what separates the two.
#
# Requiring the path as well is what stops the two remaining ways this claimed
# lines it had not written. A user's own command that happens to end in
# "# InternetReconnector" is no longer deleted, and installing from a second
# checkout no longer silently removes the first checkout's job: the marker alone
# says nothing about which copy of the tool wrote a line, so every install
# treated every other install's entry as its own. Lines belonging to another
# checkout are now reported and left alone.
#
# The path is matched in the single-quoted form we write it in, and also as a
# bare whitespace-delimited word, so a line someone unquoted by hand is still
# recognised as ours rather than being orphaned and then duplicated.
CLASSIFY_AWK='
function marked(line,   ml) {
    if (line ~ /^[[:space:]]*#/) return 0
    # Trailing blanks go before the suffix is compared. Without this, one space
    # after the marker hid a line from ours(), our_line() and foreign_lines()
    # all at once -- so a re-install neither replaced it nor warned about it, it
    # simply appended a second job, and the two then ran alongside each other
    # every interval. That is the opposite of the idempotence the README
    # promises, and it was silent. The comment test above already tolerates
    # blanks at the front of the line; this makes the suffix test as tolerant at
    # the back. uninstall-cron.sh matches loosely and always did find such a
    # line, so this also settles a disagreement between the two scripts about
    # what counts as ours.
    sub(/[[:space:]]+$/, "", line)
    ml = length(marker)
    return length(line) >= ml && substr(line, length(line) - ml + 1) == marker
}
function names_target(line,   i, n, f) {
    if (index(line, quoted_target) > 0 || index(line, quoted_alias) > 0) return 1
    n = split(line, f, /[[:space:]]+/)
    for (i = 1; i <= n; i++)
        if (f[i] == target || f[i] == alias) return 1
    return 0
}
function ours(line) {
    return marked(line) && names_target(line)
}
# The reconnect.sh of this checkout in double quotes, the one spelling a
# hand-edit produces that names_target() does not accept. Never used to claim a
# line, only to tell an edited line of ours from a line of another checkout.
# (No apostrophes in these comments: this program sits inside single quotes.)
function names_target_dq(line) {
    return index(line, dq_target) > 0 || index(line, dq_alias) > 0
}
# Runs the reconnect.sh of this checkout and carries the marker, but was edited
# by hand past what ours() accepts: text added after the marker ("... #
# InternetReconnector # my note"), or the path put in double quotes. Such a line
# is not claimed -- a command of the user can mention the marker mid-line, and
# deletion must never take a line it cannot be sure it wrote -- but it is not
# ignored either. Text after the marker used to make it neither ours nor
# foreign, so a re-install appended a second job beside it without a word.
# Double quotes made it "foreign": the note called the own line of this
# checkout "a different copy of reconnect.sh" and said to run --remove from
# that copy -- advice that cannot work, because this is that copy. Both are
# reported as what they are now; see warn_about_edited().
function edited(line) {
    if (line ~ /^[[:space:]]*#/) return 0
    if (index(line, marker) == 0 || ours(line)) return 0
    return names_target(line) || names_target_dq(line)
}
BEGIN {
    marker = ENVIRON["MARKER"]
    target = ENVIRON["RECONNECT"]
    quoted_target = sprintf("%c%s%c", 39, target, 39)
    alias = ENVIRON["RECONNECT_ALIAS"]
    quoted_alias = sprintf("%c%s%c", 39, alias, 39)
    dq_target = sprintf("%c%s%c", 34, target, 34)
    dq_alias = sprintf("%c%s%c", 34, alias, 34)
}
'

# Run CLASSIFY_AWK plus the rules in $1 over the crontab text in $2.
#
# A rule passed in here must never `exit` early, however tempting it is once the
# answer is known. The writer on the left of this pipe is `printf`, a builtin, so
# it runs in the pipeline's own subshell: an awk that exits closes the pipe, the
# subshell is killed by SIGPIPE and exits 141, and `set -o pipefail` makes 141
# the status of the whole pipeline -- which is the value has_ours() returns as
# its answer. None of that shows up until the crontab is bigger than the pipe
# buffer, because a smaller write lands in the buffer and finishes before awk is
# scheduled at all.
#
# Measured, before the `exit`s below were removed: with our line first in a
# 5,001-line crontab, `install-cron.sh --remove` printed "No InternetReconnector
# cron job found ...; nothing to remove." and exited 0 while the job stayed
# scheduled and went on running every interval. Reading the whole input costs one
# scan of a file that is a few kilobytes in every realistic case, which is
# nothing next to an answer that silently inverts past 64 KiB.
#
# has_entries() had the same defect in a worse place -- see its comment.
classify() {
    printf '%s\n' "$2" | MARKER="$MARKER" RECONNECT="$RECONNECT" \
        RECONNECT_ALIAS="$RECONNECT_ALIAS" awk "$CLASSIFY_AWK$1"
}

# True when the crontab text contains a line of ours.
# The awk rules below are passed through as program text, so the `$0` in them
# is awk's whole-record variable and must not be expanded by the shell.
# shellcheck disable=SC2016
has_ours() {
    classify 'ours($0) { found = 1 } END { exit found ? 0 : 1 }' "$1"
}

# Our line, as it currently stands in the crontab. Used to carry the user's own
# environment overrides across a re-install.
#
# `!seen` rather than `exit` keeps this to the first matching line while still
# reading the input to the end, for the reason classify() states. This one was
# the less dangerous of the two -- awk had already printed the line before the
# pipe closed, and the caller assigns the result without checking its status --
# but it is the same trap, and leaving one of the pair as a working example of
# the pattern is how the other one comes back.
# shellcheck disable=SC2016
our_line() {
    classify 'ours($0) && !seen { print; seen = 1 }' "$1"
}

# Marked lines that belong to a different checkout. Reported, never removed.
# A line of this checkout's that a hand-edit took past ours() is edited, not
# foreign, and is reported by warn_about_edited() instead.
# shellcheck disable=SC2016
foreign_lines() {
    classify 'marked($0) && !ours($0) && !edited($0) { print }' "$1"
}

# Lines of this checkout's that a hand-edit took past what ours() recognises.
# Reported, never removed -- see edited() in CLASSIFY_AWK.
# shellcheck disable=SC2016
edited_lines() {
    classify 'edited($0) { print }' "$1"
}

# Everything that is not one of our lines. Blank lines are kept: this is the
# user's file and we only own the lines we wrote ourselves. Trailing blank
# lines are dropped so repeated runs cannot accumulate them.
# shellcheck disable=SC2016
strip_ours() {
    classify '
        /^[[:space:]]*$/ { blanks[++n] = $0; next }
        ours($0) { next }
        { for (i = 1; i <= n; i++) print blanks[i]; n = 0; print }
    ' "$1"
}

# The classifier's exit status is checked rather than discarded. This used to
# end in `|| true`, which made "awk fell over" indistinguishable from "the user
# has no other entries": both produce an empty result, and write_crontab()
# answers an empty body with `crontab -r`. A classifier that failed for any
# reason would therefore have deleted every unrelated cron entry the user had --
# the exact outcome the read above refuses to risk when `crontab -l` fails, so
# the write path has to be at least as careful as the read path.
others=""
strip_rc=0
others="$(strip_ours "$current")" || strip_rc=$?
[ "$strip_rc" -eq 0 ] \
    || die "could not classify the current crontab (awk exited $strip_rc). Refusing to continue, so your existing cron entries are left untouched."

# True when $1 contains at least one non-blank character.
#
# Matched in the shell, with no pipeline and no external command, because the
# answer decides whether write_crontab() below calls `crontab -r`. It used to be
# `printf '%s\n' "$1" | grep -q '[^[:space:]]'`, and that reported "no entries"
# for a crontab that was full of them:
#
#   * `grep -q` exits at the first match, closing the pipe;
#   * `printf` is a builtin running in the pipeline's own subshell, so it is then
#     killed by SIGPIPE and exits 141 -- which only happens once the text is
#     bigger than the pipe buffer, because a smaller write lands in the buffer
#     and finishes before grep is even scheduled;
#   * `set -o pipefail` at the top of this file makes 141 the pipeline's status.
#
# So the function was correct for a small crontab and wrong for a large one, at
# a threshold nothing in the code mentions -- 64 KiB, the pipe buffer. Measured:
# a user crontab of 1,900 unrelated entries (63,493 bytes) installed correctly;
# one of 2,000 (66,893 bytes) was replaced by our single line, with "Installed
# cron job" printed and exit 0. On the removal path a 5,001-line crontab was
# deleted outright by `crontab -r` while the script printed "Removed the
# InternetReconnector cron job." and exited 0, and uninstall-cron.sh inherited
# all of it by shelling out to `install-cron.sh --remove`.
#
# That is the outcome the read guard further up refuses to risk and the reason
# strip_ours()'s exit status is checked rather than discarded, arriving through
# the one helper on the write path that still could not tell a failure from an
# empty answer. A `case` cannot fail, cannot be cut short, and needs no
# subprocess, so there is no failure left for the caller to misread. Do not
# "simplify" this back into a pipeline, and in particular do not fix such a
# pipeline by testing ${PIPESTATUS[1]}: that leaves a helper whose own failure
# still means "empty", which is the shape of the bug rather than the bug.
has_entries() {
    case "$1" in
        *[![:space:]]*) return 0 ;;
        *) return 1 ;;
    esac
}

# Replace the user's crontab with the given body. An empty body means "no
# entries left", which we express with `crontab -r` rather than piping an empty
# string in. We never fall back to `crontab -r` on a *failed* write, so a
# transient error can't wipe the user's other cron entries.
#
# Both branches used to discard their exit status, so a failing write was
# reported as a success: `--remove` printed "Removed the InternetReconnector
# cron job." and exited 0 while the job was still installed and still running.
# A write that fails is fatal now, and says what crontab said.
write_crontab() {
    local out rc=0
    if has_entries "$1"; then
        out="$(printf '%s\n' "$1" | crontab - 2>&1)" || rc=$?
    else
        out="$(crontab -r 2>&1)" || rc=$?
    fi
    if [ "$rc" -ne 0 ]; then
        if [ -n "$out" ]; then printf '%s\n' "$out" >&2; fi
        die "could not update the crontab (crontab exited $rc). Check it with 'crontab -l'."
    fi
    return 0
}

# Warn about marked lines written by another checkout, which we deliberately
# leave in place. Saying so beats both silently deleting them (what this used
# to do) and silently leaving the user with two jobs they did not expect.
warn_about_foreign() {
    local foreign line
    foreign="$(foreign_lines "$1")"
    if [ -n "$foreign" ]; then
        echo "NOTE: these cron lines carry our marker but run a different copy of" >&2
        echo "      reconnect.sh, so they were left untouched:" >&2
        # One printf per line, not one for the whole block. `printf FMT "$foreign"`
        # reuses its format once per *argument*, and a multi-line string is one
        # argument -- so with two other checkouts installed the first line came out
        # indented under the sentence above and the second flush against the left
        # margin, reading as the start of a new sentence rather than as a second
        # cron line. The neighbouring `printf '  %s\n' "${log_files[@]}"` calls in
        # uninstall-cron.sh pass an array, where the reuse does do what it looks
        # like, which is what made the difference easy to miss.
        while IFS= read -r line; do
            printf '        %s\n' "$line" >&2
        done <<< "$foreign"
        echo "      Run install-cron.sh --remove from that copy to remove them." >&2
    fi
}

# Warn about lines of ours that a hand-edit took past ours(). $2 is what this
# run did about the job, so the note says what that means: on an install there
# are now two jobs running this script; on a removal the edited one is still
# there. Same one-printf-per-line rule as warn_about_foreign().
warn_about_edited() {
    local edited line
    edited="$(edited_lines "$1")"
    [ -n "$edited" ] || return 0
    echo "NOTE: these cron lines run this checkout's reconnect.sh and carry our" >&2
    echo "      marker, but were edited by hand (text added after the marker, or" >&2
    echo "      the path put in double quotes), so they are not recognised as this" >&2
    echo "      script's own and were left untouched:" >&2
    while IFS= read -r line; do
        printf '        %s\n' "$line" >&2
    done <<< "$edited"
    case "$2" in
        install)
            echo "      The job was installed as well, so reconnect.sh now runs from both." >&2
            echo "      Remove one with 'crontab -e'." >&2
            ;;
        *)
            echo "      It still runs. Remove it by hand with 'crontab -e'." >&2
            ;;
    esac
}

# --- What --remove would delete ----------------------------------------------
# uninstall-cron.sh --dry-run reports what an uninstall would do, and it used to
# answer "Would remove the cron job" off its own deliberately loose matcher (D7)
# -- so over a line edited after the marker it promised a removal that the real
# run, which goes through ours() below, then declined: "nothing to remove", the
# "still installed" WARNING and exit 1. A prediction of what is deleted has to
# use the rule that deletes, so this prints exactly the lines --remove takes and
# nothing else: no notes, nothing written. Same preflights and the same guarded
# read as --remove, and never a date check, because nothing here is installed.
# shellcheck disable=SC2016
if [ "$mode" = remove-dry-run ]; then
    would_remove=""
    would_rc=0
    would_remove="$(classify 'ours($0) { print }' "$current")" || would_rc=$?
    [ "$would_rc" -eq 0 ] \
        || die "could not classify the current crontab (awk exited $would_rc). Nothing was changed."
    [ -z "$would_remove" ] || printf '%s\n' "$would_remove"
    exit 0
fi

# --- Remove ------------------------------------------------------------------
if [ "$mode" = remove ]; then
    if has_ours "$current"; then
        write_crontab "$others"
        echo "Removed the InternetReconnector cron job."
    else
        echo "No InternetReconnector cron job found for $RECONNECT; nothing to remove."
    fi
    warn_about_foreign "$current"
    warn_about_edited "$current" remove
    exit 0
fi

# --- Install -----------------------------------------------------------------
[ -f "$RECONNECT" ] || die "reconnect.sh not found at the checkout root above this script (expected at $RECONNECT)."

# The path is single-quoted in the cron line so directories containing spaces
# work. Three things cannot be quoted away and so are rejected outright: a
# single quote would terminate that quoting, cron treats an unescaped '%' in a
# command as a newline, and a real line break ends the crontab record no matter
# what quoting it sits inside.
case "$RECONNECT" in
    *"'"*) die "the install path contains a single quote, which cannot be used safely in a crontab: $RECONNECT" ;;
    *'%'*) die "the install path contains '%', which cron treats as a newline: $RECONNECT" ;;
    *$'\n'* | *$'\r'*) die "the install path contains a line break, which would end the cron line early and leave the rest of the path in the crontab as a separate entry: $RECONNECT" ;;
esac

# The scripts' executable bits are set further down, once every value written
# onto the line has been vetted -- see "Executable bits" below.

# --- Environment carried on the cron line ------------------------------------
# Cron runs with a minimal environment and no DBus/display context. nmcli needs
# to reach the user's NetworkManager, which works for the user who owns the
# session; we also export a PATH so nmcli is found.
#
# The RECONNECT_* settings are carried across a re-install. The note printed at
# the end of an install tells the user to lower them "in the cron environment",
# which means editing them onto the line we wrote -- and because the line was
# regenerated from scratch every time, the next run of this script silently
# threw the user's tuning away and put the defaults back. They are now read off
# the existing line and written out again, and anything set in this script's own
# environment wins, so `RECONNECT_SCAN_WAIT_SECS=5 ./install-cron.sh` is a way
# to set them that does not involve hand-editing a crontab at all.
#
# The PATH itself is resolved further down, once previous_value() exists to read
# the installed line back; only its default lives here.
CRON_PATH_DEFAULT=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
RECONNECT_SETTINGS="RECONNECT_CONFIG RECONNECT_LOG_DIR RECONNECT_LOG_RETENTION_DAYS
RECONNECT_SCAN_WAIT_SECS RECONNECT_CONNECT_ATTEMPTS RECONNECT_NMCLI_WAIT_SECS"

previous_line="$(our_line "$current")"

# --- Resolving the interval --------------------------------------------------
# MINUTES is carried across a re-install exactly like the RECONNECT_* settings
# below. It used to be the one setting that was not: a user who installed with
# `MINUTES=10 ./install-cron.sh` and later re-ran plain `./install-cron.sh` --
# which the README calls idempotent, and which is the natural thing to do after
# moving the checkout -- had the interval silently reset to 5. The interval is
# the first field of our own cron line, so it can simply be read back.
#
# Only the `*/N` spelling is recognised, because that is the only one this
# script writes. Anything else on that field means the line was hand-edited,
# and guessing at what a hand-written schedule meant is worse than falling back
# to the default.
#
# Leading blanks are stripped before the prefix is looked at. marked() tolerates
# them deliberately -- its comment test already did -- so a line somebody
# indented by hand is still claimed as ours and rewritten, and previous_value()
# is not anchored to the front of the line either, so PATH and every RECONNECT_*
# value carried across such a line untouched. This test was the one that did not,
# and the interval was therefore the single setting one stray leading space threw
# away: it reset to 5 in silence, on the re-install the README calls idempotent,
# which is precisely the surprise carrying the interval over exists to prevent.
previous_minutes() {
    local line field
    line="${previous_line#"${previous_line%%[![:space:]]*}"}"
    case "$line" in
        '*/'*) ;;
        *) return 1 ;;
    esac
    field="${line%%[[:space:]]*}"
    field="${field#\*/}"
    case "$field" in
        '' | *[!0-9]*) return 1 ;;
    esac
    printf '%s' "$field"
}

if [ -n "$MINUTES_REQUESTED" ]; then
    MINUTES="$MINUTES_REQUESTED"
else
    MINUTES="$(previous_minutes || true)"
    if [ -n "$MINUTES" ]; then
        # Validated rather than trusted: the line has been sitting in a file
        # the user can edit, and it is about to be interpolated back into one.
        validate_minutes "$MINUTES" "the interval on the installed cron line"
    else
        MINUTES=5
    fi
fi

# Canonical form, so a value the user spelled `05` is written as `*/5` rather
# than `*/05`. Every branch above has been through validate_minutes, so this is
# digits only by now and cannot fail. It also keeps the arithmetic at the end of
# this script -- the interval-vs-worst-case warning -- reading base 10.
MINUTES=$((10#$MINUTES))

# reconnect.sh validates the numeric RECONNECT_* settings itself and dies with a
# stated reason -- but under cron that reason goes to /dev/null, so an install
# that accepted a value reconnect.sh will reject produced a job that logged FAIL
# every interval and explained itself to nobody. That is the same failure the
# "no config file yet" warning further down exists to prevent, and the same
# argument that validates MINUTES before the crontab is touched: catch it at the
# one moment somebody is looking. The rules deliberately mirror reconnect.sh's,
# and $3 names where the value came from so a rejected value carried off an
# existing cron line does not read as if the user had just typed it.
#
# RECONNECT_CONFIG and RECONNECT_LOG_DIR are paths, not numbers, and are left
# alone here: both are noted after the install if the job could not use them --
# the config if it is missing or unreadable, the log directory if it can never
# be created or written.
validate_setting() {
    local name="$1" value="$2" what="$3" min
    case "$name" in
        RECONNECT_SCAN_WAIT_SECS | RECONNECT_LOG_RETENTION_DAYS) min=0 ;;
        RECONNECT_CONNECT_ATTEMPTS | RECONNECT_NMCLI_WAIT_SECS) min=1 ;;
        *) return 0 ;;
    esac
    # Quoted for the reason validate_minutes() above quotes its own, and matching
    # reconnect.sh, which quotes these four settings' refusals too: a
    # `RECONNECT_CONNECT_ATTEMPTS` of nothing but blanks otherwise produced
    # `must be a whole number >= 1; got: ` -- a refusal whose subject is
    # invisible. The value can also arrive off the installed cron line, where
    # $what says so, and a blank one there is exactly as hard to see.
    case "$value" in
        '' | *[!0-9]*)
            die "$what must be a whole number >= $min; got: '$value'" ;;
    esac
    # Ahead of the arithmetic, because the arithmetic is what silently accepts an
    # over-wide value. The bound and the width rule are reconnect.sh's for the
    # same setting, so the pair refuses the same values. The wording is the same
    # for the two settings whose minimum is 1; for the two whose minimum is 0,
    # reconnect.sh says "non-negative whole number of seconds/days" where this
    # says ">= 0" -- the same rule in different words, and auto-setup.sh's
    # check_setting() copies the wording used here. See fits_in_integer().
    fits_in_integer "$value" \
        || die "$what must be a whole number >= $min, at most 18 digits; got: '$value'"
    # Base 10 for the same reason validate_minutes() forces it: bash reads a
    # leading zero as octal, and `08` is not octal at all.
    [ "$((10#$value))" -ge "$min" ] \
        || die "$what must be a whole number >= $min; got: '$value'"
}

# The value assigned to $1 on the line we previously installed, if any. Values
# we write are shell words: single-quoted when they contain a space, otherwise
# bare. The trailing '=' makes each name unambiguous, so looking for
# RECONNECT_LOG_DIR= cannot match RECONNECT_LOG_RETENTION_DAYS=.
previous_value() {
    local rest
    case "$previous_line" in
        *"$1="*) rest="${previous_line#*"$1"=}" ;;
        *) return 1 ;;
    esac
    case "$rest" in
        "'"*) rest="${rest#\'}"; printf '%s' "${rest%%\'*}" ;;
        *) printf '%s' "${rest%%[[:space:]]*}" ;;
    esac
}

# --- Resolving the PATH written onto the line --------------------------------
# The six directories below cover an ordinary distribution, and they were once
# hardcoded. That is wrong wherever nmcli lives somewhere else -- NixOS puts it
# under /run/current-system/sw/bin, Guix under a profile, a source build under
# /opt or /usr/local/network-manager/bin -- and the failure it produces is the
# worst kind this script deals with: cron gets this PATH and nothing else, so
# reconnect.sh cannot find nmcli, dies with a stated reason, and the reason goes
# to /dev/null. FAIL every interval, explained to nobody.
#
# So it is settable, and it is carried across a re-install exactly like MINUTES
# and the RECONNECT_* settings. Carrying it matters as much as making it
# settable: a user who had to widen it once would otherwise have the next plain
# `./install-cron.sh` silently put the six defaults back, and the job would stop
# finding nmcli again with nothing to show what changed.
#
# $cron_path_from names where the value came from, so a rejected one carried off
# an existing line does not read as if the user had just typed it -- the same
# reason validate_minutes() and validate_setting() take that argument.
if [ -n "${CRON_PATH:-}" ]; then
    cron_path_from=CRON_PATH
else
    CRON_PATH="$(previous_value PATH || true)"
    cron_path_from="the PATH on the installed cron line"
fi
if [ -z "$CRON_PATH" ]; then
    CRON_PATH="$CRON_PATH_DEFAULT"
    cron_path_from="the default PATH"
fi

# Vetted like every other value that reaches the crontab, and for the same three
# reasons: a single quote ends the quoting, cron reads an unescaped '%' as a
# newline, and a line break ends the record whatever quotes it sits inside. This
# check is new because the value is: while it was a literal in this file there
# was nothing to vet.
case "$CRON_PATH" in
    *"'"*) die "$cron_path_from contains a single quote, which cannot be used safely in a crontab: $CRON_PATH" ;;
    *'%'*) die "$cron_path_from contains '%', which cron treats as a newline: $CRON_PATH" ;;
    *$'\n'* | *$'\r'*) die "$cron_path_from contains a line break, which would end the cron line early and leave the rest of the value in the crontab as a separate entry: $CRON_PATH" ;;
esac

# Single-quoted for the reason the RECONNECT_* values are: cron hands the line to
# a shell, and an unquoted value leaves every metacharacter in it for that shell
# to interpret. A PATH is not obviously dangerous, but it stopped being a literal
# the moment it became settable.
cron_env="PATH='$CRON_PATH'"
# The paths the installed job will actually use, recorded as the line is built.
# The summary at the end used to report "$SCRIPT_DIR/logs" unconditionally, which
# was simply wrong whenever RECONNECT_LOG_DIR was set: the value was written onto
# the cron line a few lines below and then the user was sent to look somewhere
# else for their logs.
installed_log_dir=""
installed_config=""
# The three timeouts the closing overlap warning is computed from, recorded the
# same way and for the same reason.
installed_scan_wait=""
installed_attempts=""
installed_nmcli_wait=""
# RECONNECT_SETTINGS is a whitespace-separated list of variable *names*, so the
# word splitting here is the point rather than an oversight. The names are
# literals defined a few lines up; none of them can contain a space or a glob
# character.
# shellcheck disable=SC2086
for setting in $RECONNECT_SETTINGS; do
    value=""
    if [ -n "${!setting:-}" ]; then
        value="${!setting}"
        value_from="$setting"
    else
        value="$(previous_value "$setting" || true)"
        value_from="$setting on the installed cron line"
    fi
    [ -n "$value" ] || continue
    # Checked whichever side it came from. A value read back off the line has
    # been sitting in a file the user can edit, and it is about to be
    # interpolated into one again -- the same reason the interval is re-validated
    # rather than trusted.
    validate_setting "$setting" "$value" "$value_from"
    # The same three things the install path is vetted for, and for the same
    # reasons: a single quote would end the quoting, cron reads an unescaped '%'
    # as a newline, and a line break ends the crontab record outright.
    #
    # The line break was the one that was missing, and it was the worst of the
    # three, because quoting the value gave no protection at all:
    # RECONNECT_LOG_DIR=$'/tmp/ir\n*/1 * * * * some-command' was written out
    # inside single quotes and produced three crontab lines -- a truncated
    # assignment cron cannot parse, and the rest of the value standing on its own
    # as a schedule cron will happily run. The installer exited 0 reporting
    # success while its own job had stopped working. Only an environment value
    # can carry one; a value read back off an existing line cannot, since a line
    # has no newline in it.
    case "$value" in
        *"'"*) die "$setting contains a single quote, which cannot be used safely in a crontab: $value" ;;
        *'%'*) die "$setting contains '%', which cron treats as a newline: $value" ;;
        *$'\n'* | *$'\r'*) die "$setting contains a line break, which would end the cron line early and leave the rest of the value in the crontab as a separate entry: $value" ;;
    esac
    # Cron runs the job with the user's home directory as its working directory,
    # while this script resolves a relative path against wherever it happened to
    # be run from. The two disagree silently, and the disagreement defeated the
    # "there is no config file yet" warning further down:
    # `RECONNECT_CONFIG=config.env ./install-cron.sh` from inside the checkout
    # passed that check -- the file is right there -- and then installed a job
    # that reads $HOME/config.env, does not find it, and logs FAIL every
    # interval with the reason going to /dev/null. That is precisely the failure
    # the warning exists to catch. The same mismatch pointed the closing
    # "Logs go to:" summary, and uninstall-cron.sh --purge-logs, at a directory
    # the job never writes to.
    #
    # Refused rather than resolved. Resolving would have to happen on the value
    # read back off an existing line too, which would quietly change what an
    # already installed job means -- and the value the user typed is the one
    # moment there is somebody to ask.
    #
    # The value is quoted for the reason every other refusal in this script
    # quotes its own: a blanks-only path is not empty, so it reaches this check
    # rather than being skipped above, and unquoted it produced `must be an
    # absolute path; got:  . Cron runs ...` -- a refusal whose subject is
    # invisible. `RECONNECT_CONFIG=" " ./install-cron.sh` is how it arrives from
    # the environment, and a blanks-only value already on the installed line
    # arrives the same way on every re-install, with nothing visible to correct.
    # This was the one refusal in the file left bare after the others were
    # quoted, and auto-setup.sh's copy of this same check quotes it.
    case "$setting" in
        RECONNECT_CONFIG | RECONNECT_LOG_DIR)
            case "$value" in
                /*) ;;
                *) die "$value_from must be an absolute path; got: '$value'. Cron runs the job from your home directory rather than from this one, so a relative path would not point where it points now." ;;
            esac
            ;;
    esac
    # Always single-quoted, never bare. Quoting only when the value happened to
    # contain a space left every other shell metacharacter to be interpreted by
    # the shell cron runs the line with, and cron's own vetting above only
    # rejects two of them. `RECONNECT_LOG_DIR=/tmp/a;reboot` was written out
    # unquoted and produced a crontab whose second command was `reboot` and
    # which never ran reconnect.sh at all; a value containing `$(...)` was left
    # for cron's shell to command-substitute at run time. The quotes are safe
    # because a value containing one is rejected just above, and they are what
    # the install path itself has always used.
    cron_env="$cron_env $setting='$value'"
    case "$setting" in
        RECONNECT_LOG_DIR) installed_log_dir="$value" ;;
        RECONNECT_CONFIG) installed_config="$value" ;;
        RECONNECT_SCAN_WAIT_SECS) installed_scan_wait="$value" ;;
        RECONNECT_CONNECT_ATTEMPTS) installed_attempts="$value" ;;
        RECONNECT_NMCLI_WAIT_SECS) installed_nmcli_wait="$value" ;;
    esac
done

# Whatever was not overridden falls back to what reconnect.sh itself defaults to.
# reconnect.sh resolves both against *its* directory, the checkout root -- not
# against manual-setup/, where this script lives -- so the root is what these
# fall back to. Pointing them here would send the "no config file yet" note and
# the closing "Logs go to:" line at files the job never reads or writes.
[ -n "$installed_log_dir" ] || installed_log_dir="$ROOT_DIR/logs"
[ -n "$installed_config" ] || installed_config="$ROOT_DIR/config.env"
[ -n "$installed_scan_wait" ] || installed_scan_wait=15
[ -n "$installed_attempts" ] || installed_attempts=3
[ -n "$installed_nmcli_wait" ] || installed_nmcli_wait=20

# --- Executable bits ---------------------------------------------------------
# Only after every value written onto the line has been vetted, and only if it
# is actually needed: this writes to the user's checkout, so it should not
# happen on a run that is about to abort anyway. It used to sit straight after
# the install-path check, ahead of the CRON_PATH and RECONNECT_* vetting above,
# so `RECONNECT_CONNECT_ATTEMPTS=abc ./install-cron.sh` refused the value and
# exited 1 having already chmodded the checkout. Still ahead of the crontab
# write, though: a chmod that fails after the line is installed would leave a
# job whose script cannot be started, which is worse than refusing.
#
# The failure is reported rather than left to `set -e`. A read-only checkout, or
# one owned by another user, makes chmod fail -- and without the `|| die` that
# aborted the script with no message at all, which is a miserable thing to debug
# for what is really a one-line permissions problem.
# Every script the documentation tells you to run directly, not just
# reconnect.sh. The cron line only needs that one, but the README tells the user
# to run ./uninstall-cron.sh later and ./tests/run-tests.sh before proposing a
# change, and a checkout that arrived without its permission bits -- a zip
# download, a filesystem with no execute bit, a clone taken before the committed
# modes were fixed -- leaves those failing with "Permission denied" long after
# this script has run. The list covered three of those four for no reason anybody
# had written down, which is the shape an oversight takes once the reasoning
# beside it is stated in full. auto-setup.sh joined the list when it was added,
# on the same rule: the README tells you to run it directly, so it needs its bit
# set for the same reason the other three do.
#
# A script that is not there is skipped, so a checkout without the test suite is
# not a failure. The two cron scripts sit beside this file; the other three sit
# at the checkout root.
for script in "$RECONNECT" "$SCRIPT_DIR/install-cron.sh" \
    "$SCRIPT_DIR/uninstall-cron.sh" "$ROOT_DIR/auto-setup.sh" \
    "$ROOT_DIR/tests/run-tests.sh"; do
    [ -f "$script" ] || continue
    [ ! -x "$script" ] || continue
    # Below both `continue`s, so it is reached only for a script that really
    # does need its bit set. As a preflight up with crontab and mktemp this
    # refused every install on a machine without `chmod`, including the ordinary
    # case where the loop makes it this far for nothing -- a clone with its
    # committed modes intact skips every iteration here and never calls `chmod`
    # at all. That is a working install turned into "chmod not found", which is
    # what the install-only gate on `date` and the conditional `rm` gate in
    # uninstall-cron.sh exist to stop happening.
    #
    # It is still worth checking rather than leaving to `set -e` or to the
    # `|| die` below, for the reason it was first added: the failure message
    # there names a permissions problem, and on a machine with no chmod that
    # would send the reader after something that is not wrong.
    command -v chmod >/dev/null 2>&1 \
        || die "chmod not found. Install coreutils ($script is not executable and cannot be made so)."
    chmod +x "$script" \
        || die "cannot make $script executable (check its owner and mode, and that the filesystem is writable)."
done

cron_line="*/$MINUTES * * * * $cron_env '$RECONNECT' >/dev/null 2>&1 $MARKER"

# Recombine: keep the user's other entries, then append ours.
if has_entries "$others"; then
    write_crontab "$others
$cron_line"
else
    write_crontab "$cron_line"
fi

echo "Installed cron job (every $MINUTES minutes):"
echo "  $cron_line"

# A warning, not a failure. Installing before configuring is an easy order to
# get the wrong way round -- the README puts configuration first, but nothing
# enforced it -- and the result was a job that logged FAIL every interval with
# the reason going to /dev/null under cron. Saying so here costs nothing and is
# the only moment anyone is looking.
if [ ! -e "$installed_config" ]; then
    # The spacer goes on the same stream as the note it spaces. On stdout it
    # detached from the message whenever the two were redirected separately,
    # which is exactly how a scripted install runs this: `>/dev/null` showed the
    # note jammed against what preceded it, `2>/dev/null` showed a stray blank
    # line and no note at all.
    echo >&2
    echo "NOTE: there is no config file at $installed_config yet, so every run will" >&2
    echo "      log FAIL until you create one:" >&2
    echo "        cp '$SCRIPT_DIR/config.env.example' '$installed_config'" >&2
    echo "        chmod 600 '$installed_config'" >&2
# Existence was the only thing this checked, and reconnect.sh refuses two more:
# a config that is not a regular file and one it cannot read. Both produce the
# same FAIL every interval with the reason going to /dev/null, and both passed
# here in silence -- `RECONNECT_CONFIG=/etc/ir` naming the directory rather than
# the file installed with exit 0 and no note. auto-setup.sh refuses both before
# its interview; this script warns, for the reason it warns about a missing one.
# `-r` is asked as the user running this script, which is the user the job runs
# as, since the line goes into that user's crontab.
elif [ ! -f "$installed_config" ]; then
    echo >&2
    echo "NOTE: $installed_config is not a regular file (a directory, say)," >&2
    echo "      so every run will log FAIL. RECONNECT_CONFIG has to name the" >&2
    echo "      config file itself; re-run this script with that path." >&2
elif [ ! -r "$installed_config" ]; then
    echo >&2
    echo "NOTE: $installed_config cannot be read by you, and the job runs as you," >&2
    echo "      so every run will log FAIL until you can read it. Check its owner" >&2
    echo "      and mode." >&2
fi

# The log directory, for the same reason and with the same stance. reconnect.sh
# creates it on demand, so a missing one is fine -- but one it cannot create, or
# cannot write, is a warning there by design, and under cron that warning goes
# to /dev/null: the job reconnects every interval and never writes a line, not
# even FAIL, while the summary below names that directory as where the logs go.
# auto-setup.sh refuses such a directory before its interview; this script said
# nothing at all, so `RECONNECT_LOG_DIR=/var/log/ir ./install-cron.sh` installed
# with exit 0 a job that could never log. Today's day file is checked too, as
# auto-setup.sh checks it: one left by an earlier `sudo ./reconnect.sh` cannot be
# appended to.
#
# The test is on the nearest ancestor that exists, which is exactly what
# `mkdir -p` needs to be a writable directory. `-w` is a prediction, as it is
# there; the point is the common case.
log_dir_problem=""
log_dir_probe="$installed_log_dir"
while [ ! -e "$log_dir_probe" ]; do
    case "$log_dir_probe" in
        */*) log_dir_probe="${log_dir_probe%/*}"; [ -n "$log_dir_probe" ] || log_dir_probe=/ ;;
        *) log_dir_probe=/ ;;
    esac
done
if [ ! -d "$log_dir_probe" ]; then
    log_dir_problem="$log_dir_probe exists and is not a directory"
elif [ ! -w "$log_dir_probe" ]; then
    log_dir_problem="$log_dir_probe is not writable"
else
    installed_day_log="$installed_log_dir/$(date '+%Y-%m-%d').log"
    if [ -e "$installed_day_log" ] \
        && { [ ! -f "$installed_day_log" ] || [ ! -w "$installed_day_log" ]; }; then
        log_dir_problem="today's log file $installed_day_log cannot be written to"
    fi
fi
if [ -n "$log_dir_problem" ]; then
    echo >&2
    echo "NOTE: the job cannot log to $installed_log_dir:" >&2
    echo "      $log_dir_problem. reconnect.sh treats that as a warning" >&2
    echo "      and carries on, and under cron the warning goes to /dev/null, so" >&2
    echo "      every run would go unrecorded. Fix that, or re-run this script" >&2
    echo "      with RECONNECT_LOG_DIR naming a directory you can write." >&2
fi

# --- Will the job be able to find nmcli? -------------------------------------
# The one command the installed job cannot do anything without, and the one this
# script never checked for. An install on a machine with no NetworkManager
# succeeded, printed "Installed cron job (every 5 minutes)", and produced a job
# that logged FAIL every interval: reconnect.sh dies with "nmcli not found", and
# under cron that reason goes to /dev/null. Exactly the failure the missing
# config warning above exists to prevent, and the same argument as validating
# the RECONNECT_* values here rather than leaving them to the scheduled run --
# this is the one moment somebody is looking.
#
# A warning, not a failure: setting a machine up in either order is reasonable,
# and refusing to install would be a worse answer than saying so.
#
# Two distinct problems needing two distinct answers. nmcli may be absent
# outright, or present somewhere the PATH on the cron line does not reach -- and
# the second is the one that looks like a mystery, because running
# ./reconnect.sh by hand keeps working perfectly under the user's own PATH.
#
# The check below compares directory strings, so a difference the shell's own
# lookup does not care about has to be normalised away first. `/usr/bin/` and
# `/usr/bin` name one directory but are two strings to `case`, so a single
# trailing slash anywhere in CRON_PATH made this warn about a PATH that was
# already correct and tell the user to re-run with a directory that was already
# on it. A warning that fires when nothing is wrong stops being believed on the
# day it is right, which is the only day it matters.
#
# Only a trailing slash is normalised. Two spellings differing any other way -- a
# symlink, a `//` in the middle, a `..` -- are still two strings here. Resolving
# those needs real path resolution this script has no reason to grow, and the
# error it leaves is a warning too many rather than one too few.
strip_trailing_slash() {
    local p="$1"
    while [ "${#p}" -gt 1 ] && [ "${p%/}" != "$p" ]; do
        p="${p%/}"
    done
    printf '%s' "$p"
}

# A PATH with every entry normalised, wrapped in ':' at both ends so the
# membership test cannot match part of an entry. Split by parameter expansion
# rather than by word splitting on IFS, which would also glob an entry
# containing '*'.
normalised_path_list() {
    local rest="$1" entry out=""
    while [ -n "$rest" ]; do
        case "$rest" in
            *:*) entry="${rest%%:*}"; rest="${rest#*:}" ;;
            *) entry="$rest"; rest="" ;;
        esac
        out="$out:$(strip_trailing_slash "$entry")"
    done
    printf '%s:' "$out"
}

nmcli_path="$(command -v nmcli 2>/dev/null || true)"
case "$nmcli_path" in
    */*) nmcli_dir="${nmcli_path%/*}" ;;
    *) nmcli_dir="" ;;              # not found, or a shell builtin or function
esac

if [ -z "$nmcli_path" ]; then
    echo >&2
    echo "NOTE: nmcli was not found on this machine, so every run will log FAIL" >&2
    echo "      until NetworkManager is installed:" >&2
    echo "        sudo apt install network-manager   # or your distro's equivalent" >&2
elif [ -n "$nmcli_dir" ]; then
    nmcli_dir_norm="$(strip_trailing_slash "$nmcli_dir")"
    cron_path_norm="$(normalised_path_list "$CRON_PATH")"
    case "$cron_path_norm" in
        *":$nmcli_dir_norm:"*) ;;
        *)
            echo >&2
            echo "NOTE: nmcli is at $nmcli_path, which is not on the PATH this job was" >&2
            echo "      installed with:" >&2
            echo "        $CRON_PATH" >&2
            echo "      Cron gives the job that PATH and nothing else, so it would not find" >&2
            echo "      nmcli and every run would log FAIL -- while running ./reconnect.sh" >&2
            echo "      by hand keeps working, because your own PATH does find it." >&2
            echo "      Re-run this script with that directory included:" >&2
            echo "        CRON_PATH='$nmcli_dir:$CRON_PATH' ./manual-setup/install-cron.sh" >&2
            ;;
    esac
fi

# --- Will the job start at all? ----------------------------------------------
# The cron line runs reconnect.sh by path, and the kernel starts it through its
# shebang, `#!/usr/bin/env bash` -- so `env` looks bash up on the PATH written
# onto the line and nowhere else. The nmcli check above was the only one that
# PATH got, and it is the narrower of the two: a CRON_PATH naming just the
# directory nmcli lives in (`CRON_PATH=/opt/nm/bin`, a natural reading of "the
# PATH written onto the cron line") passed it, installed with exit 0 and no
# note, and every scheduled run then died in `env` with "'bash': No such file or
# directory" before reconnect.sh had run a line. That is worse than the FAIL the
# nmcli note warns about: reconnect.sh never starts, so it cannot write even
# that, and logs/ stays empty while cron sends env's complaint to /dev/null.
#
# A warning, for the reason the nmcli one is. Empty and relative entries are
# skipped: cron runs the job from the home directory, not from here, so testing
# them from this directory would answer a different question.
cron_path_has_bash() {
    local rest="$CRON_PATH" entry
    while [ -n "$rest" ]; do
        case "$rest" in
            *:*) entry="${rest%%:*}"; rest="${rest#*:}" ;;
            *) entry="$rest"; rest="" ;;
        esac
        case "$entry" in /*) ;; *) continue ;; esac
        if [ -f "$entry/bash" ] && [ -x "$entry/bash" ]; then
            return 0
        fi
    done
    return 1
}

if ! cron_path_has_bash; then
    bash_path="$(command -v bash 2>/dev/null || true)"
    echo >&2
    echo "NOTE: bash is missing from the PATH this job was installed with:" >&2
    echo "        $CRON_PATH" >&2
    echo "      reconnect.sh starts through '#!/usr/bin/env bash', which looks bash" >&2
    echo "      up on that PATH alone, so every scheduled run would fail before it" >&2
    echo "      could write a log line -- not even FAIL." >&2
    case "$bash_path" in
        /*/*)
            echo "      Re-run this script with bash's directory included:" >&2
            echo "        CRON_PATH='${bash_path%/*}:$CRON_PATH' ./manual-setup/install-cron.sh" >&2
            ;;
        *)
            echo "      Re-run this script with a CRON_PATH that includes bash's directory." >&2
            ;;
    esac
fi

warn_about_foreign "$current"
warn_about_edited "$current" install

# A run that keeps failing waits SCAN_WAIT_SECS for the scan, then makes
# CONNECT_ATTEMPTS attempts of up to two NMCLI_WAIT_SECS nmcli calls each (the
# saved profile, then the password form), with a 2s pause between attempts. With
# the defaults that is 15 + 3*2*20 + 2*2 = 139s, the ~140s the README quotes.
#
# Computed from the values actually being installed rather than from that
# constant. Hardcoding 140 was wrong in both directions, and the second one
# mattered: raising the timeouts -- RECONNECT_NMCLI_WAIT_SECS=60 with
# RECONNECT_CONNECT_ATTEMPTS=5 is a worst case over 600s -- printed no warning at
# all on a 5-minute interval where every failing run overlaps. In the other
# direction it warned about an interval that was fine, and told the user to lower
# settings they had already lowered past the suggested values, which is the kind
# of advice that teaches people to ignore the warning.
#
# reconnect.sh takes a lock, so an overlap no longer doubles up on nmcli or on
# the log, but a run still cannot finish inside the interval and some intervals
# are simply skipped -- and where flock is missing there is no lock at all. Both
# are worth saying out loud.
#
# Base 10 forced for the same reason validate_minutes() forces it: these values
# have been through validate_setting(), which accepts a leading zero, and bash
# reads `08` in arithmetic as a bad octal number rather than as 8.
#
# Every step is checked for overflow first, because fits_in_integer() does not
# cover this line. That function bounds each *value* at the 18 digits bash can
# compare and count with -- but the sum below multiplies two of them, and a
# product passes intmax_t long before either operand does. Written as one
# unchecked expression it wrapped in silence, exactly the way the `$(( ))`
# bounds in validate_setting() used to:
# RECONNECT_NMCLI_WAIT_SECS=999999999999999999 with
# RECONNECT_CONNECT_ATTEMPTS=5 came out as -8446744073709551603, so the
# comparison below was false and the install printed no warning at all -- for
# the one configuration whose worst case is furthest past the interval. Smaller
# pairs wrapped positive instead and warned with a figure the installed timeouts
# cannot produce, which is the same defect wearing a plausible number.
#
# Each check divides the headroom rather than multiplying and looking back, so
# nothing relies on how bash behaves once it has already overflowed. `attempts`
# doubled cannot overflow on its own: 18 digits is under a fifth of intmax_t.
INTMAX=9223372036854775807
scan_n=$(( 10#$installed_scan_wait ))
attempts_n=$(( 10#$installed_attempts ))
nmcli_n=$(( 10#$installed_nmcli_wait ))
worst_case_overflowed=0
worst_case=$(( attempts_n * 2 ))
if [ "$nmcli_n" -ne 0 ] && [ "$(( INTMAX / nmcli_n ))" -lt "$worst_case" ]; then
    worst_case_overflowed=1
else
    worst_case=$(( worst_case * nmcli_n ))
    gap=$(( (attempts_n - 1) * 2 ))
    if [ "$(( INTMAX - worst_case ))" -lt "$scan_n" ]; then
        worst_case_overflowed=1
    else
        worst_case=$(( worst_case + scan_n ))
        if [ "$(( INTMAX - worst_case ))" -lt "$gap" ]; then
            worst_case_overflowed=1
        else
            worst_case=$(( worst_case + gap ))
        fi
    fi
fi

# An overflowed worst case is past 2^63 seconds, so no interval can accommodate
# it and the warning is unconditionally right. What it must not do is quote the
# wrapped figure as though it were a number of seconds.
if [ "$worst_case_overflowed" -eq 1 ]; then
    worst_case_phrase="longer than a 64-bit count of seconds"
else
    worst_case_phrase="up to ~${worst_case}s"
fi

if [ "$worst_case_overflowed" -eq 1 ] || [ "$((MINUTES * 60))" -lt "$worst_case" ]; then
    echo
    echo "NOTE: a failing run can take $worst_case_phrase with the timeouts this job is"
    echo "      installed with, which is longer than your $MINUTES-minute interval."
    echo "      reconnect.sh takes a lock, so an overlapping run steps aside rather than"
    echo "      running twice over, but that interval is then skipped. To make a run"
    echo "      finish sooner, re-run this script with lower values for"
    echo "      RECONNECT_SCAN_WAIT_SECS (now $installed_scan_wait),"
    echo "      RECONNECT_CONNECT_ATTEMPTS (now $installed_attempts) or"
    echo "      RECONNECT_NMCLI_WAIT_SECS (now $installed_nmcli_wait), or use a longer"
    echo "      interval."
fi

echo
echo "Verify with:  crontab -l"
echo "Logs go to:   $installed_log_dir/ (one file per day, e.g. $(date '+%Y-%m-%d').log)"
