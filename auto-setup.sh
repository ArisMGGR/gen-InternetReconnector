#!/usr/bin/env bash
#
# auto-setup.sh
#
# Walks through the whole of the README's setup section in one go: asks for the
# network settings, writes config.env, tests the result by running reconnect.sh
# once, and only then installs the cron job.
#
# Usage:
#   ./auto-setup.sh          # ask, write config.env, verify, install the cron job
#   ./auto-setup.sh --help   # show usage
#
# What it writes: config.env (and a config.env.bak beside it, if there was one
# to preserve -- copied back over config.env when the test fails while a job is
# installed); through the verification run of reconnect.sh, that run's line
# in today's logs/YYYY-MM-DD.log (and logs/.lock, where flock exists); a
# temporary file that run reports its outcome into, removed on exit; and,
# through install-cron.sh, the cron line. It never edits the crontab itself --
# see the comment above the install step.

set -euo pipefail

# For the reason written out in reconnect.sh: an exported CDPATH makes the `cd`
# below print into the substitution that resolves this script's directory.
unset CDPATH

# Split with parameter expansion rather than `dirname`, for the reason written
# out in full in reconnect.sh and shared by all four scripts. `*/*` fails for a
# bare name (`bash auto-setup.sh`), which means the current directory; the empty
# result is a script sitting directly in `/`.
script_src="${BASH_SOURCE[0]}"
case "$script_src" in
    */*)
        script_dir="${script_src%/*}"
        [ -n "$script_dir" ] || script_dir=/
        ;;
    *) script_dir=. ;;
esac
# `pwd -P` for the reason install-cron.sh gives where it resolves the same path:
# the cron line is written with the physical path, whichever symlink the
# checkout was reached through, so this has to look for that spelling.
SCRIPT_DIR="$(cd "$script_dir" && pwd -P)"
RECONNECT="$SCRIPT_DIR/reconnect.sh"
# The spelling this run reached the checkout by, which a line an earlier version
# wrote through a symlink names; install-cron.sh's ours() accepts it too.
RECONNECT_ALIAS="$(cd "$script_dir" && pwd)/reconnect.sh"
# The two cron scripts and the example config live under manual-setup/, one
# level below this script; reconnect.sh, config.env and logs/ stay at the root
# beside it, because reconnect.sh resolves its own defaults against its own
# directory and the cron line names it there.
MANUAL_DIR="$SCRIPT_DIR/manual-setup"
# Started by the spelling this run arrived by, for the reason uninstall-cron.sh
# gives beside its own INSTALLER: install-cron.sh takes its alias from the path
# it is started through, so started by the physical path it called a line
# written through a symlink "a different copy" and installed a second job
# beside it -- after this script had read that same line as its own.
INSTALLER="${RECONNECT_ALIAS%/reconnect.sh}/manual-setup/install-cron.sh"
EXAMPLE="$MANUAL_DIR/config.env.example"

# The tag install-cron.sh puts at the end of the line it writes. Defined here
# too, for the reason uninstall-cron.sh defines it: the line has to be found
# before the installer is called. The suite pins all three copies agreeing.
MARKER="# InternetReconnector"

# The "Using <SETTING>=... from the installed cron job" notes, held until the
# script's own header has been printed (see where they are collected). Set
# here, ahead of die(), because die() prints any still held: a refusal of a
# value carried off the cron line must still say where that value came from.
carried_notes=""

die() {
    if [ -n "$carried_notes" ]; then
        printf '%s' "$carried_notes" >&2
        carried_notes=""
    fi
    echo "ERROR: $*" >&2
    exit 1
}

usage() {
    # Checked inside the function rather than at the top of the file, the way
    # install-cron.sh and uninstall-cron.sh check theirs: `cat` is used here and
    # nowhere else in this script, so an ordinary setup never calls it. An
    # unconditional preflight would refuse a run that would have worked, over a
    # command that run does not invoke.
    #
    # Still ahead of the heredoc, so that under `set -e` a failed `cat` cannot
    # abort before the `exit 0` below and leave --help printing an empty screen.
    command -v cat >/dev/null 2>&1 \
        || die "cat not found. Install coreutils."
    cat <<'USAGE'
Usage: auto-setup.sh [--help]

Asks for your Wi-Fi settings, writes config.env, tests them by running
reconnect.sh once, and installs the cron job if that test succeeds. The test
is judged by the log line it writes, not by its exit status alone: a run that
stepped aside because the scheduled job was still going, or that could not
write its line at all, is "not tested" and installs nothing.

  (no arguments)   Run the setup.
  --help, -h       Show this message.

You are asked for:

  WIFI_SSID        The network to stay connected to. Required.
  WIFI_PASSWORD    Optional. Leave it empty if NetworkManager already has a
                   saved profile for the network -- connect once through the
                   desktop UI and the password never has to be stored here at
                   all. See .github/SECURITY.md. On a re-run Enter keeps the
                   stored one and '-' removes it.
  WIFI_IFACE       Optional. Which Wi-Fi device to pin, chosen from the ones
                   nmcli reports. Leave it empty to let NetworkManager pick;
                   on a re-run Enter keeps the stored one and '-' clears it.
  WIFI_HIDDEN      Whether the network broadcasts its SSID. Defaults to no.
  Interval         How often cron runs the job. Defaults to 5 minutes, and
                   must divide 60 evenly.

Re-running it is safe: the current settings become the defaults, and the
previous config.env is kept as config.env.bak, at mode 600 like the config
itself. If the test fails while a cron job of this checkout is installed, the
previous config.env is put back (or a new one removed), so the job keeps
reading what it read before.

Environment:
  Any RECONNECT_* setting already on the installed cron line is used when the
  environment does not set it, so a re-run tests and re-installs the same
  config and log directory the job is using. Setting one here overrides it.

  RECONNECT_CONFIG  Where to write the config. Defaults to config.env next to
                    this script. Must be an absolute path, because the cron job
                    install-cron.sh writes runs from your home directory, and
                    must not contain a single quote, a '%' or a line break,
                    which cannot be written onto a cron line safely.
  RECONNECT_LOG_DIR Passed through to the job. Held to the same two rules, for
                    the same reasons, and must be a directory that exists or
                    can be created: reconnect.sh treats one it cannot create
                    as a warning, not a failure, so a job pointed at one would
                    run without ever writing a log line.
  MINUTES           Skips the interval question and uses this value.

  RECONNECT_SCAN_WAIT_SECS, RECONNECT_CONNECT_ATTEMPTS,
  RECONNECT_NMCLI_WAIT_SECS, RECONNECT_LOG_RETENTION_DAYS
                    Passed through to the job. Not asked about here, but checked
                    against install-cron.sh's rules.

  CRON_PATH         Passed through to the job. install-cron.sh is what chooses
                    it, defaults it and carries it across a re-install -- none
                    of that happens here -- but a value carrying a single quote,
                    a '%' or a line break is refused here, before the interview,
                    rather than at the end of it.

All of those are checked before the first question, as is whether config.env can
actually be read and written (and, when it already exists, whether its backup
can be written beside it), whether the log directory (the default logs/ too)
and today's log file in it can be written, whether this checkout's own path can
be written onto a cron line, whether crontab is installed and your crontab can
be read, and
whether the commands install-cron.sh needs (mktemp, awk, rm, date) are there,
so a run that cannot work is refused rather than found out at the end of the
interview. The checkout path is checked first: when RECONNECT_CONFIG is unset
the config lives beside the script, so a checkout path that cannot be installed
is the reason the config path cannot be either.
USAGE
}

# --- Parse arguments ---------------------------------------------------------
# The arity check comes first so it applies to every flag alike, and `$#` is what
# decides whether there is an argument at all rather than a `'')` arm below.
# Both for the reason install-cron.sh's parser states in full: `"${1:-}"`
# collapses "no argument" and "an empty argument" into one empty string, so
# `./auto-setup.sh ""` would start rewriting the user's config in response to an
# argument it could not see. `./auto-setup.sh "$flag"` with $flag unset is how
# that arrives.
#
# The value is quoted in the refusal for the reason the other four scripts quote
# theirs: unquoted, an empty or blanks-only argument produced a message naming
# nothing at all.
[ "$#" -le 1 ] || { usage >&2; die "too many arguments"; }
if [ "$#" -eq 1 ]; then
    case "$1" in
        -h | --help) usage; exit 0 ;;
        *) usage >&2; die "unknown argument: '$1'" ;;
    esac
fi

# --- Interpreter check -------------------------------------------------------
# ${old_hidden,,} and ${hidden,,} further down need bash 4.0, exactly as
# ${WIFI_HIDDEN,,} does in reconnect.sh -- which is not a coincidence, because
# the spellings this script accepts for the hidden flag are deliberately the
# ones reconnect.sh accepts. On bash 3.2, still what /bin/bash is on macOS, the
# expansion fails with a bare "bad substitution" that names neither the cause
# nor the requirement.
#
# Ahead of every prompt, because of where the first `,,` sits: it is in the
# hidden-network question, *after* the SSID prompt and after the password
# prompt. Without this guard the run asked for the Wi-Fi password, read it, and
# only then died on an expansion -- collecting a secret for a run that could
# never have finished. That is the whole of what this check buys, and it is why
# it is not down beside the expansion it is about.
#
# But *below* the argument parsing, not above it, and that is the half this
# check first got wrong. Sitting at the top of the file it also fired on
# `--help` and on every argument refusal, and neither reaches a bash 4
# construct: usage() is a `cat` heredoc and the refusals are die() calls. So on
# macOS `./auto-setup.sh --help` printed "bash 4.0 or newer is required" instead
# of the usage block -- which is the one thing still worth reading there, since
# it says to write config.env by hand from config.env.example and run
# install-cron.sh, and the README records that those two cron scripts do run on
# bash 3.x. That is a precondition enforced on a path that does not use the
# thing it checks, the defect CONTRIBUTING.md states as a rule and the suite
# pins for cat, chmod, date, grep, rm and sleep -- the `cat` case being the same
# shape in the same function this one was refusing to let run.
#
# install-cron.sh and uninstall-cron.sh deliberately carry no such check: they
# use no bash 4 construct at all, which is what lets the README say the two
# cron scripts avoid the features reconnect.sh needs. This script does not
# avoid them, so it states the requirement the way reconnect.sh does.
if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ]; then
    die "bash 4.0 or newer is required; this is bash ${BASH_VERSION:-unknown}."
fi

# --- Settings already on the installed cron line ------------------------------
# install-cron.sh carries every RECONNECT_* setting across a re-install: a value
# it finds on the line it wrote earlier is written out again unless the
# environment overrides it. This script used to resolve the same settings from
# the environment alone, and the two disagreed whenever a job had been installed
# with a custom RECONNECT_CONFIG or RECONNECT_LOG_DIR and this script was then
# re-run plain, which the README says to do to change a setting. Measured: with
# RECONNECT_CONFIG='/etc/ir/config.env' on the line, a plain ./auto-setup.sh
# offered no current values (it looked for a config beside itself and found
# none), wrote and verified <checkout>/config.env, printed "Settings work", and
# then called install-cron.sh -- which put the job back on /etc/ir/config.env,
# a file nobody had tested and whose contents had not changed. The verification
# log went to <checkout>/logs while the job's went to the directory on the line.
#
# So the line is read first, and whatever it names that the environment does
# not is exported, so that existing_value(), the pre-interview checks, the
# verification run and install-cron.sh all see one value. The environment still
# wins, because that is the documented way to move a setting.
#
# Read through `crontab -l`, where "no crontab yet" means "no line" and any other
# failed read is refused before the interview (see the read below). The line is
# recognised the way
# uninstall-cron.sh recognises it -- not a comment, carries the marker, names
# this checkout's reconnect.sh -- and the value is taken off it the way
# install-cron.sh's previous_value() takes it: single-quoted when we wrote it,
# bare if a hand-edit unquoted it. That is a third reader of a line two scripts
# already read, kept to the same two rules the other two use so it cannot
# acquire a different idea of which line is ours.
#
# "Names this checkout's reconnect.sh" means quoted, or as a whole blank-delimited
# word -- uninstall-cron.sh's names_our_script(), and the path rule of
# install-cron.sh's ours(). It used to be a bare substring, which also matched
# another checkout whose absolute path merely ends in this one's (/home/u/ir
# inside /mnt/backup/home/u/ir): a plain re-run here then took that job's
# RECONNECT_CONFIG, rewrote *its* config.env with these answers, and exited 0.
names_our_script() {
    local word path
    for path in "$RECONNECT" "$RECONNECT_ALIAS"; do
        case "$1" in
            *"'$path'"* | *"\"$path\""*) return 0 ;;
        esac
    done
    local -a words
    read -r -a words <<< "$1"
    for word in "${words[@]}"; do
        [ "$word" != "$RECONNECT" ] || return 0
        [ "$word" != "$RECONNECT_ALIAS" ] || return 0
    done
    return 1
}

# True when install-cron.sh's ours() would claim $1 as its own line: the marker at
# the very end once trailing blanks are gone (marked()), and this checkout's
# reconnect.sh single-quoted or as a whole blank-delimited word (names_target()).
# Comments are skipped by the caller, as marked() skips them. Stricter than
# names_our_script() on purpose -- no double-quoted spelling, no marker mid-line --
# because this one predicts what that script will do, not what is worth reporting.
installer_claims() {
    local line="${1%"${1##*[![:space:]]}"}" word path
    case "$line" in *"$MARKER") ;; *) return 1 ;; esac
    for path in "$RECONNECT" "$RECONNECT_ALIAS"; do
        case "$1" in *"'$path'"*) return 0 ;; esac
    done
    local -a words
    read -r -a words <<< "$1"
    for word in "${words[@]}"; do
        [ "$word" != "$RECONNECT" ] || return 0
        [ "$word" != "$RECONNECT_ALIAS" ] || return 0
    done
    return 1
}

# True when crontab's diagnostic says there is simply no crontab yet -- the
# same case-folded test install-cron.sh's mentions_no_crontab() makes, so the
# two scripts agree about which failed reads are really the empty case,
# BusyBox's "can't open '<user>': No such file or directory" included (see the
# comment on that function for why only that exact shape is taken).
mentions_no_crontab() {
    case "$1" in
        *[Nn][Oo]" "[Cc][Rr][Oo][Nn][Tt][Aa][Bb]*) return 0 ;;
        *"can't open '"*"': No such file or directory"*) return 0 ;;
        *) return 1 ;;
    esac
}

# A read that fails for any reason other than "no crontab yet" is refused here,
# before the interview, and no longer treated as "no line". The lookup itself
# only fills in defaults, but install-cron.sh refuses to write over a crontab
# it cannot read, so a run whose read fails cannot finish -- and treating the
# failure as "no line" let it ask every question, take the Wi-Fi password, write
# config.env and pass the verification before install-cron.sh refused at the
# very end. Measured with crontab -l answering "You (tester) are not allowed to
# use this program (crontab)", which is what cron.allow/cron.deny produce. The
# test is install-cron.sh's, condition for condition. stderr is fetched with a
# second read rather than a temporary file, since this script needs none
# anywhere else.
#
# "Condition for condition" includes what counts as stderr being non-empty.
# install-cron.sh asks `[ -s "$cron_err" ]` of the file, which is true for a
# single newline; a command substitution strips trailing newlines, so here the
# same newline-only diagnostic used to come back as "" and pass as "no crontab
# yet" -- and the interview, the password and the config were all spent before
# install-cron.sh refused it. The `printf x` sentinel keeps the bytes exactly as
# crontab wrote them, so `-n` here and `-s` there agree.
#
# Two lines are looked for, because two different questions are asked of the
# crontab. $installed_line is the first line of this checkout's by the loose rule
# above, and it is what the settings are carried off: a line a hand-edit took past
# what install-cron.sh recognises still names the config and log directory the
# job is using. $installer_line is the first line install-cron.sh's ours() would
# claim -- the one whose interval it carries across a re-install -- and only that
# one can say what pressing Enter at the interval prompt will install. Using the
# loose line for that too promised "keep the interval already installed" over a
# line edited after the marker, where install-cron.sh leaves the line alone and
# installs a second job every 5 minutes beside it.
installed_line=""
installer_line=""
if command -v crontab >/dev/null 2>&1; then
    installed_crontab=""
    cron_read_rc=0
    installed_crontab="$(LC_ALL=C crontab -l 2>/dev/null)" || cron_read_rc=$?
    if [ "$cron_read_rc" -ne 0 ]; then
        cron_read_err="$(LC_ALL=C crontab -l 2>&1 >/dev/null; printf x)"
        cron_read_err="${cron_read_err%x}"
        if [ "$cron_read_rc" -ne 1 ] || [ -n "$installed_crontab" ] \
            || { [ -n "$cron_read_err" ] && ! mentions_no_crontab "$cron_read_err"; }; then
            # As written, the way install-cron.sh passes its file on with `cat`.
            [ -z "$cron_read_err" ] || printf '%s' "$cron_read_err" >&2
            die "could not read the current crontab (crontab -l exited $cron_read_rc). install-cron.sh refuses to write over a crontab it cannot read, so the job could not be installed. Nothing was asked for, so nothing is lost -- fix that (cron.allow and cron.deny are the usual cause) and run this again."
        fi
        installed_crontab=""
    fi
    while IFS= read -r cron_line; do
        stripped="${cron_line#"${cron_line%%[![:space:]]*}"}"
        case "$stripped" in '#'*) continue ;; esac
        case "$cron_line" in *"$MARKER"*) ;; *) continue ;; esac
        names_our_script "$cron_line" || continue
        [ -n "$installed_line" ] || installed_line="$cron_line"
        if [ -z "$installer_line" ] && installer_claims "$cron_line"; then
            installer_line="$cron_line"
        fi
    done <<< "$installed_crontab"
fi

# The value assigned to $1 on that line, if any. The trailing '=' keeps
# RECONNECT_LOG_DIR= from matching inside RECONNECT_LOG_RETENTION_DAYS=.
installed_value() {
    local rest
    case "$installed_line" in
        *"$1="*) rest="${installed_line#*"$1"=}" ;;
        *) return 1 ;;
    esac
    case "$rest" in
        "'"*) rest="${rest#\'}"; printf '%s' "${rest%%\'*}" ;;
        *) printf '%s' "${rest%%[[:space:]]*}" ;;
    esac
}

# Said out loud, so a refusal of a carried value reads as what it is: a value
# off the installed line, not one the user typed. Held rather than printed
# here, because printing here put these lines above the script's own
# "InternetReconnector setup" header. They are printed just below that header
# on a run that gets there, and by die() ahead of the refusal on one that does
# not. The names are literals, so the word splitting in the `for` is the point.
for setting in RECONNECT_CONFIG RECONNECT_LOG_DIR RECONNECT_LOG_RETENTION_DAYS \
    RECONNECT_SCAN_WAIT_SECS RECONNECT_CONNECT_ATTEMPTS RECONNECT_NMCLI_WAIT_SECS; do
    [ -z "${!setting:-}" ] || continue
    carried="$(installed_value "$setting" || true)"
    [ -n "$carried" ] || continue
    export "$setting=$carried"
    carried_notes="${carried_notes}Using $setting='$carried' from the installed cron job; set $setting in the environment to override it.
"
done

# Resolved the way reconnect.sh resolves it, so the file this writes is the file
# the verification run then reads and the installed job then uses. Someone who
# has RECONNECT_CONFIG set -- in the environment, or on the installed line read
# back just above -- has already chosen where their config lives, and writing to
# the default anyway would leave them with two.
CONFIG_FILE="${RECONNECT_CONFIG:-$SCRIPT_DIR/config.env}"

# --- Refusals before the interview -------------------------------------------
# Everything below refuses a run that cannot finish, and all of it sits here
# rather than at the point of use, for one reason: a run that cannot finish
# should say so before it asks for anything, not after the whole interview and
# the password have been collected. Each of these was learned the same way, by
# being discovered at the far end.
#
# The interval rules the typed answer is held to, in one place so that the
# answer somebody types and the value that arrives in MINUTES cannot drift
# apart. Prints the normalised value and returns 0, or prints the reason it
# refuses and returns 1 -- one function serving a re-prompt further down and a
# die() just below, which is what stops this script growing a second, slightly
# different idea of what a legal interval is.
#
# install-cron.sh validates it again regardless; this is a convenience, not the
# enforcement. The rules deliberately mirror validate_minutes() there.
check_interval() {
    local n="$1" stripped
    case "$n" in
        '' | *[!0-9]*)
            printf "A whole number of minutes; got: '%s'" "$n"; return 1 ;;
    esac
    # Measured after stripping leading zeros, matching fits_in_integer() in
    # reconnect.sh and install-cron.sh: bash arithmetic below wraps in silence
    # past intmax_t, so an over-wide value has to be refused before it is used.
    # Before the normalisation, not after, so the value echoed back is the one
    # that arrived rather than what bash turned it into -- at 19 digits the
    # range message otherwise reported `got: '-8446744073709551617'`, a negative
    # nobody typed.
    stripped="${n#"${n%%[!0]*}"}"
    if [ "${#stripped}" -gt 18 ]; then
        printf "Between 1 and 59, at most 18 digits; got: '%s'" "$n"; return 1
    fi
    # Forced to base 10: bash reads a leading zero as octal, and `08` is not
    # octal at all, so `$((60 % n))` would fail rather than answer.
    n=$((10#$n))
    if [ "$n" -lt 1 ] || [ "$n" -gt 59 ]; then
        printf "Between 1 and 59; got: '%s'" "$n"; return 1
    fi
    if [ "$((60 % n))" -ne 0 ]; then
        printf "It has to divide 60 evenly (1, 2, 3, 4, 5, 6, 10, 12, 15, 20, 30), or cron leaves an uneven gap at the top of each hour; got: '%s'" "$n"
        return 1
    fi
    printf '%s' "$n"
    return 0
}

# The four numeric RECONNECT_* settings, held to install-cron.sh's rules rather
# than to a second set written here. Prints nothing and returns 0 when the value
# is one that script would accept, or prints the reason and returns 1 -- the
# same contract check_interval() above has, so the block below can treat the two
# alike.
#
# The bounds, the 18-digit width rule and the wording are validate_setting()'s in
# install-cron.sh, deliberately, for the reason that function gives for mirroring
# reconnect.sh: a rule applied on one side of a pair and not the other means one
# script refusing a value the other would have run perfectly well, or accepting
# one it then refuses. Here the risk is only the first, since this is a copy of
# the stricter side -- but a copy that drifts is how the pair stopped agreeing
# the last three times, so if you change a bound there, change it here.
#
# The width test runs before the `$(( ))` for the reason it does in both other
# scripts: bash arithmetic wraps in silence past intmax_t, so an over-wide value
# has to be refused before it is normalised, or the message quotes a number
# nobody typed.
check_setting() {
    local name="$1" value="$2" min stripped
    case "$name" in
        RECONNECT_SCAN_WAIT_SECS | RECONNECT_LOG_RETENTION_DAYS) min=0 ;;
        RECONNECT_CONNECT_ATTEMPTS | RECONNECT_NMCLI_WAIT_SECS) min=1 ;;
        *) return 0 ;;
    esac
    case "$value" in
        '' | *[!0-9]*)
            printf "must be a whole number >= %s; got: '%s'" "$min" "$value"
            return 1 ;;
    esac
    stripped="${value#"${value%%[!0]*}"}"
    if [ "${#stripped}" -gt 18 ]; then
        printf "must be a whole number >= %s, at most 18 digits; got: '%s'" \
            "$min" "$value"
        return 1
    fi
    if [ "$((10#$value))" -lt "$min" ]; then
        printf "must be a whole number >= %s; got: '%s'" "$min" "$value"
        return 1
    fi
    return 0
}

# The three characters install-cron.sh refuses in any value it writes onto the
# cron line: a single quote ends the quoting it wraps every value in, cron reads
# an unescaped '%' as a newline, and a real line break ends the crontab record no
# matter what quoting it sits inside. None of the three can be quoted away, which
# is why that script refuses rather than escapes them.
#
# Applied here for exactly the reason absoluteness is: both path settings are
# handed straight to install-cron.sh, so a value it will refuse is a value this
# whole interview is spent for nothing on. Absoluteness was the only one of the
# four rules that had been copied, and a value carrying one of these three is
# absolute -- so `RECONNECT_LOG_DIR="/tmp/it's"` passed here, and the run then
# asked every question, read the Wi-Fi password, wrote config.env and ran the
# verification before install-cron.sh refused it at the very end. With
# RECONNECT_CONFIG it was worse than a wasted interview: the config file, the
# password in it included, was left on disk at a path that can never be
# installed.
#
# Same contract as check_interval() and check_setting() above: prints the reason
# and returns 1, or prints nothing and returns 0. The wording is
# install-cron.sh's, deliberately, so the two refuse the same values with the
# same words -- if you change a rule there, change it here.
#
# $2 is the noun the line-break message uses, and it exists because
# install-cron.sh does not use one word for all four of the things it vets: it
# says "leave the rest of the *value*" for CRON_PATH and for every RECONNECT_*
# setting, and "leave the rest of the *path*" for the install path. Defaulted to
# "value", so the two call sites that came first need no argument and the only
# one that passes it is the install path. Without this the messages would agree
# in two cases out of three, which is the kind of near-agreement that makes a
# later reader think the pair has drifted when it has not.
check_cron_safe() {
    local noun="${2:-value}"
    case "$1" in
        *"'"*)
            printf "contains a single quote, which cannot be used safely in a crontab: %s" "$1"
            return 1 ;;
        *'%'*)
            printf "contains '%%', which cron treats as a newline: %s" "$1"
            return 1 ;;
        *$'\n'* | *$'\r'*)
            printf "contains a line break, which would end the cron line early and leave the rest of the %s in the crontab as a separate entry: %s" "$noun" "$1"
            return 1 ;;
    esac
    return 0
}

# Both scripts this one drives, checked before a single question is asked.
#
# install-cron.sh was already checked, but only at the point of use -- which is
# after the interview, after the password has been typed and after config.env
# has been written. reconnect.sh was not checked at all: the verification run
# just invoked `bash "$RECONNECT"`, so on a checkout missing it the whole
# interview ran and the failure arrived as "That did not work, so the cron job
# was NOT installed", followed by advice that "the reason above usually means
# one field is wrong rather than all of them" and that re-running offers each
# value as a default. None of that is true of a missing script, and it sends
# the reader back through the same questions to fix a field that was never
# wrong.
#
# Checked here rather than left where each is used, for the reason every check
# in this block sits here: a run that cannot finish should say so before it
# asks for anything, not after. install-cron.sh's own `[ -f "$RECONNECT" ]`
# refuses a missing reconnect.sh too, in its own words: it names the checkout
# root above manual-setup/, where this names the directory beside this script.
# Both name the same file.
[ -f "$RECONNECT" ] \
    || die "reconnect.sh not found next to this script (expected at $RECONNECT); it is what this tests your settings with, and what the cron job runs."
[ -f "$INSTALLER" ] \
    || die "install-cron.sh not found under manual-setup/ (expected at $INSTALLER); it is what installs the cron entry."

# crontab is the last thing this run needs, which is exactly why it has to be
# checked first. It was not checked at all: on a machine without cron the
# interview ran, the Wi-Fi password was read, config.env was written and the
# verification passed ("Settings work") before install-cron.sh refused with
# "crontab not found" at the very end -- the one gap left in a block whose rule
# is that a run which cannot finish says so before it asks for anything.
command -v crontab >/dev/null 2>&1 \
    || die "crontab not found. Install cron (e.g. 'sudo apt install cron'); it is what schedules the job. Nothing was asked for, so nothing is lost -- install it and run this again."

# The rest of install-cron.sh's install preflights, for the reason crontab is
# checked just above. That script refuses outright without mktemp, awk or rm,
# and without date on an install, and this run always ends in an install. Two
# of the four were caught only by accident and two not at all: reconnect.sh
# needs awk and date too, so a missing one failed the verification run -- after
# the interview -- while mktemp and rm are nothing reconnect.sh needs, so a
# machine without either answered every question, read the password, wrote
# config.env, printed "Settings work" and was then refused by install-cron.sh
# with "mktemp not found". Checked in install-cron.sh's order, after crontab,
# so a machine missing several is told about the same one first.
for setup_tool in mktemp awk rm date; do
    command -v "$setup_tool" >/dev/null 2>&1 \
        || die "$setup_tool not found. Install it (coreutils or your distro's package); install-cron.sh needs it to install the job. Nothing was asked for, so nothing is lost -- install it and run this again."
done

# The file the verification run reports its outcome into (reconnect.sh's
# IR_OUTCOME_FILE; see the readback below for why the day log is not used).
# Made here rather than beside the run, because a mktemp that fails -- a TMPDIR
# that does not exist, say -- is a run that cannot finish, and install-cron.sh
# would fail on the same mktemp at the end anyway. Single quotes so the path is
# expanded when the trap runs, as install-cron.sh's own trap does it.
verify_outcome="$(mktemp)" \
    || die "could not create a temporary file (mktemp failed -- check TMPDIR); the settings test and install-cron.sh both need one. Nothing was asked for, so nothing is lost -- fix that and run this again."
trap 'rm -f "$verify_outcome"' EXIT

# The install path is one of the four values install-cron.sh vets with the
# crontab-safety rule. It is not a setting -- it is where this checkout happens
# to sit -- and install-cron.sh vets it in exactly this position too,
# immediately after its own `[ -f "$RECONNECT" ]`, with the `case` that refuses
# a single quote, a '%' or a line break in the install path.
#
# It is vetted *first*, ahead of the config path below, and the order is the
# point. $CONFIG_FILE defaults to $SCRIPT_DIR/config.env, so a checkout under a
# directory carrying one of the three characters fails both checks -- and when
# the config check ran first, a user who had never set RECONNECT_CONFIG was
# refused with "RECONNECT_CONFIG contains a single quote", naming a variable
# they had not set for a cause the message did not mention. Following that
# message and pointing RECONNECT_CONFIG somewhere clean earned a second refusal,
# "the install path contains a single quote", which is the one that should have
# come first: the checkout is the root cause, the config path only inherits it.
# Measured, in both orders. With the install path vetted first, the checkout is
# named straight away, exactly as install-cron.sh names it.
#
# The other case this check exists for is the one the order does not settle:
# RECONNECT_CONFIG pointed somewhere clean from a checkout that is not. Before
# this check existed, the interview ran, the Wi-Fi password was read, config.env
# was written, the verification run passed, and install-cron.sh refused at the
# end over a path no answer could change.
reconnect_cron_reason="$(check_cron_safe "$RECONNECT" path)" \
    || die "the install path $reconnect_cron_reason"

# Checked here rather than left to install-cron.sh, which refuses a relative
# RECONNECT_CONFIG much further along -- after this script has already asked
# every question and written the file. Cron runs the job from the user's home
# directory while this script resolves a relative path against wherever it was
# run from, so the two would disagree about which file the job reads. Catching it
# now costs one comparison and saves the whole interview.
case "$CONFIG_FILE" in
    /*) ;;
    *) die "RECONNECT_CONFIG must be an absolute path; got: '$CONFIG_FILE'. Cron runs the job from your home directory rather than from this one, so a relative path would not point where it points now." ;;
esac
config_cron_reason="$(check_cron_safe "$CONFIG_FILE")" \
    || die "RECONNECT_CONFIG $config_cron_reason"

# Absolute was not the only way that path can be unusable, and the check above
# was the only one it got. A RECONNECT_CONFIG naming a directory that does not
# exist, one the user cannot write, or a path that is itself a directory passed
# it, took the whole interview including the password, and then died at the
# `: > "$CONFIG_FILE"` further down -- the failure this whole block exists to
# move to the front, arriving through the one property of that path nothing here
# looked at.
#
# `-w` is a prediction rather than a guarantee: a read-only mount, an ACL, or a
# run as root can all disagree with it. So the write below keeps its own `|| die`
# and this does not replace it -- it turns the common case from "refused after
# the interview" into "refused before it", which is the whole of what it is for.
#
# $CONFIG_FILE is absolute by the time it gets here, so `%/*` always leaves a
# directory; the empty result is a config sitting directly in `/`.
config_dir="${CONFIG_FILE%/*}"
[ -n "$config_dir" ] || config_dir=/
if [ -e "$CONFIG_FILE" ]; then
    [ -f "$CONFIG_FILE" ] \
        || die "RECONNECT_CONFIG is not a regular file: $CONFIG_FILE. This script writes the config there, so it cannot be a directory or a device."
    # Readable as well as writable, and the two are not the same test. An
    # existing config is *read* twice before anything is written: existing_value()
    # offers each current setting as a default, and the `cp` further down copies
    # the file to $CONFIG_FILE.bak. A file that is writable but not readable
    # (mode 0200, or an ACL) passed the two checks around this one, printed "Its
    # current settings are the defaults below -- press Enter to keep one" with no
    # default actually available for any of them, ran the whole interview
    # including the password prompt, and only then died at the backup. A file
    # owned by another user at mode 600 is caught by the -w test below; this is
    # the case that was not.
    [ -r "$CONFIG_FILE" ] \
        || die "cannot read $CONFIG_FILE (check its owner and mode). Its current settings are offered as the defaults and it is copied to $CONFIG_FILE.bak before being overwritten, so it has to be readable as well as writable. Nothing was asked for, so nothing is lost -- fix the permissions and run this again."
    [ -w "$CONFIG_FILE" ] \
        || die "cannot write $CONFIG_FILE (check its owner and mode). Nothing was asked for, so nothing is lost -- fix the permissions and run this again."
    # The backup is a third thing this branch has to be able to write, and it
    # is not the file: `cp` creates $CONFIG_FILE.bak beside the config, which
    # needs the *directory* to be writable -- unless a backup already exists
    # there and can be overwritten, in which case the directory need not be. A
    # config the user can read and write in a directory they cannot write (one
    # placed under /etc/... and chowned to them, say) passed the three checks
    # above, took the whole interview including the password, and died at the
    # `cp` further down with "could not back up". The config was intact -- the
    # copy fails before anything is truncated -- so nothing was lost but the
    # interview, which is exactly what this block exists to save.
    [ -w "$config_dir" ] || [ -w "$CONFIG_FILE.bak" ] \
        || die "cannot write into $config_dir (check its owner and mode), so the backup $CONFIG_FILE.bak could not be created before $CONFIG_FILE is overwritten. Nothing was asked for, so nothing is lost -- fix the permissions and run this again."
    # And the command that makes the backup. This was checked only at the `cp`
    # itself, after the whole interview and the password -- the one need of
    # this branch left for the far end, on a run that could never get past it.
    command -v cp >/dev/null 2>&1 \
        || die "cp not found. Install coreutils; it is what backs up the existing $CONFIG_FILE before it is overwritten. Nothing was asked for, so nothing is lost -- install it and run this again."
else
    [ -d "$config_dir" ] \
        || die "the directory for RECONNECT_CONFIG does not exist: $config_dir. Create it, or point RECONNECT_CONFIG somewhere that does."
    [ -w "$config_dir" ] \
        || die "cannot write into $config_dir (check its owner and mode), so $CONFIG_FILE could not be created."
fi

# RECONNECT_LOG_DIR is the other path setting install-cron.sh insists is
# absolute, and it was left to be refused down there for the same reason
# RECONNECT_CONFIG used to be: it is not read by this script, only passed
# through. That is not a reason to find out at the end. The check is the one
# install-cron.sh applies, so nothing is refused here that would have installed.
if [ -n "${RECONNECT_LOG_DIR:-}" ]; then
    case "$RECONNECT_LOG_DIR" in
        /*) ;;
        *) die "RECONNECT_LOG_DIR must be an absolute path; got: '$RECONNECT_LOG_DIR'. Cron runs the job from your home directory rather than from this one, so a relative path would not point where it points now." ;;
    esac
    log_dir_cron_reason="$(check_cron_safe "$RECONNECT_LOG_DIR")" \
        || die "RECONNECT_LOG_DIR $log_dir_cron_reason"
fi

# The directory the verification run, and then the job, will log into --
# resolved the way reconnect.sh resolves it.
VERIFY_LOG_DIR="${RECONNECT_LOG_DIR:-$SCRIPT_DIR/logs}"

# Whether that directory can exist at all, which is the check the config path
# gets above. reconnect.sh creates the log directory on demand, so a missing one
# is fine -- but it treats one it *cannot* create as non-fatal by design
# (status() warns on stderr and the run carries on as though it had logged), so
# the verification run passed over a directory under a parent the user cannot
# write, this script printed "Settings work", and the job it installed
# reconnected every interval without ever writing a line -- with the warning
# going to /dev/null under cron. Measured: RECONNECT_LOG_DIR pointed under a
# mode-555 directory installed cleanly and the directory stayed empty.
#
# For the default directory as well as an explicit RECONNECT_LOG_DIR. This used
# to sit inside the RECONNECT_LOG_DIR branch, so with the setting unset nothing
# looked at <checkout>/logs at all: a checkout whose logs/ could not be written
# asked every question and took the Wi-Fi password, and only then was the
# verification refused as having written no line. The name in the messages
# follows which one it is, so a user who never set RECONNECT_LOG_DIR is not told
# that it is wrong.
#
# The test is on the nearest ancestor that exists: `mkdir -p` succeeds exactly
# when that ancestor is a writable directory. `-w` is the same prediction the
# config-path check makes, and the readback after the verification run is what
# catches the cases it gets wrong.
if [ -n "${RECONNECT_LOG_DIR:-}" ]; then
    log_dir_name=RECONNECT_LOG_DIR
else
    log_dir_name="The log directory $VERIFY_LOG_DIR"
fi
log_dir_probe="$VERIFY_LOG_DIR"
while [ ! -e "$log_dir_probe" ]; do
    case "$log_dir_probe" in
        */*) log_dir_probe="${log_dir_probe%/*}"; [ -n "$log_dir_probe" ] || log_dir_probe=/ ;;
        *) log_dir_probe=/ ;;
    esac
done
[ -d "$log_dir_probe" ] \
    || die "$log_dir_name cannot be created: $log_dir_probe exists and is not a directory. reconnect.sh would run without ever writing a log line."
if [ "$log_dir_probe" = "$VERIFY_LOG_DIR" ]; then
    [ -w "$log_dir_probe" ] \
        || die "$log_dir_name exists but is not writable: $log_dir_probe (check its owner and mode). reconnect.sh would run without ever writing a log line, and under cron the warning saying so goes to /dev/null. Nothing was asked for, so nothing is lost -- fix that and run this again."
else
    [ -w "$log_dir_probe" ] \
        || die "$log_dir_name cannot be created: $log_dir_probe is not writable (check its owner and mode). reconnect.sh would run without ever writing a log line, and under cron the warning saying so goes to /dev/null."
fi

# Today's log file, which is the one the verification run appends to. A
# directory that can be written is not enough: a day file left by an earlier
# `sudo ./reconnect.sh` -- the ordinary way to get one, as the readback comment
# further down says -- is root's and cannot be appended to, so the run logs
# nothing, its outcome is empty and the setup is refused. That used to be
# discovered after the whole interview and the password. It is a prediction
# about one date: a run that crosses midnight appends to a new file, and the
# readback still catches what this misses.
verify_day_log="$VERIFY_LOG_DIR/$(date '+%Y-%m-%d').log"
if [ -e "$verify_day_log" ]; then
    { [ -f "$verify_day_log" ] && [ -w "$verify_day_log" ]; } \
        || die "today's log file $verify_day_log cannot be written to (check its owner and mode -- a file left by an earlier 'sudo ./reconnect.sh' is the usual cause). The settings test appends its outcome there, and so would the job. Nothing was asked for, so nothing is lost -- fix that and run this again."
fi

# CRON_PATH is the third value install-cron.sh vets with the rule above, and it
# was the one this block did not copy. It is not asked about here and it is not
# defaulted here -- that really is left to install-cron.sh, and the usage block
# says so -- but "we do not choose it" is a different thing from "we let the
# interview run for a value we already know cannot be installed", which is the
# distinction the whole of this block exists to draw. Measured: with
# CRON_PATH="/usr/bin:/opt/it's/bin" the run asked every question, read the
# Wi-Fi password, wrote config.env and completed the verification before
# install-cron.sh refused it -- and its closing advice, "fix the reason above and
# run ./install-cron.sh", cannot be followed, because that script fails the same
# way until the variable changes.
#
# Absoluteness is deliberately not checked: CRON_PATH is a list of directories,
# not a path, and install-cron.sh does not require it to be absolute either.
# Nothing is refused here that would have installed.
if [ -n "${CRON_PATH:-}" ]; then
    cron_path_cron_reason="$(check_cron_safe "$CRON_PATH")" \
        || die "CRON_PATH $cron_path_cron_reason"
fi

# The four numeric settings, for exactly the reason MINUTES and
# RECONNECT_LOG_DIR are checked here: this script does not read them, it only
# hands them on, and "not read here" was taken as "not this script's problem"
# until the interview had already been spent. `RECONNECT_CONNECT_ATTEMPTS=abc
# ./auto-setup.sh` asked every question, took the Wi-Fi password, wrote
# config.env, and only then failed -- at the verification run, whose refusal then
# arrived under advice saying the reason "usually means one field is wrong",
# which is untrue of an environment value and sends the reader back through the
# same questions to correct a field that was never wrong.
#
# The two gates the value would otherwise meet are both past the password:
# reconnect.sh refuses it at the verification run, and install-cron.sh after
# that. Neither is a moment when anything can still be saved.
#
# The names are literals, so the word splitting in the `for` is the point rather
# than an oversight; none of them can contain a space or a glob character.
for setting in RECONNECT_SCAN_WAIT_SECS RECONNECT_CONNECT_ATTEMPTS \
    RECONNECT_NMCLI_WAIT_SECS RECONNECT_LOG_RETENTION_DAYS; do
    # Empty is skipped rather than refused, because that is what both scripts
    # downstream do with it: reconnect.sh reads these as `${VAR:-default}`, so an
    # empty one is the default, and install-cron.sh's own loop skips it. Refusing
    # here would refuse a run that would have installed, which is the failure
    # this block is a copy of the rules to avoid.
    setting_value="${!setting:-}"
    [ -n "$setting_value" ] || continue
    setting_reason="$(check_setting "$setting" "$setting_value")" \
        || die "$setting $setting_reason"
done

# MINUTES skips the interval question, so nothing else would ever look at it:
# the typed answer is validated and re-asked at the prompt below, and a value
# arriving this way went to install-cron.sh unexamined. `MINUTES=7
# ./auto-setup.sh` therefore announced "every 7 minutes", asked every question,
# took the Wi-Fi password, wrote config.env, ran the verification, and only then
# failed on a value this script had already been told about -- the interview
# spent on a run that could not have installed anything.
#
# The reason is quoted from the same function the prompt uses, so the two paths
# refuse the same values with the same words.
#
# $checked_minutes carries whichever of the two check_interval() printed: the
# normalised value when it returned 0, the reason when it returned 1. That is
# what lets the die() below quote the reason and the interval section further
# down use the value, and it is why the name is not `reason`.
checked_minutes=""
if [ -n "${MINUTES:-}" ]; then
    checked_minutes="$(check_interval "$MINUTES")" \
        || die "MINUTES: $checked_minutes"
fi

# --- Asking -------------------------------------------------------------------
# Every prompt goes through here so that end-of-input is a stated failure exactly
# once rather than at each prompt that reads through it.
#
# There is deliberately no `[ -t 0 ]` check. uninstall-cron.sh refuses to delete
# logs without a terminal, and that is right there because the alternative is
# picking an answer for someone who was never asked -- but an answer arriving on
# a pipe *is* an answer, and refusing it would make this script undrivable by
# anything, the test suite included. What must not happen is a run that treats
# "there is no more input" as consent, so EOF stops the script instead of
# returning the empty string that every prompt below reads as "take the default".
#
# Measured, with the `|| die` removed: `./auto-setup.sh < /dev/null` does not
# fall through to the defaults, it *hangs*. `read` returns failure at EOF without
# assigning anything, the SSID prompt is the one answer that has no default and
# so re-asks, and re-asking reads EOF again -- a loop with no exit that prints
# nothing, because `read -p` shows its prompt only on a terminal. A truncated
# pipe is exactly how that arrives.
# `IFS=` matters and is not decoration. With the default IFS, `read` strips
# leading and trailing blanks from what it assigns -- so a password typed as
# " hunter2 " was stored as "hunter2" and then rejected by the access point,
# with nothing anywhere saying the script had altered it. The same trimming would
# quietly rewrite an SSID with a padding space, which this project deliberately
# supports: config_value() preserves those when the value is quoted, and the
# suite pins it. What the user typed is what gets written.
#
# End of input is "read failed and nothing arrived", not "read failed". `read`
# also returns 1 for a last answer that has no newline after it -- the reply is
# assigned all the same -- and that answer used to be thrown away as end of
# input: `printf 'MyNet\npw\n\nno\n10' | ./auto-setup.sh` asked every question,
# took the password and was then refused at the interval prompt, writing nothing.
# load_config() in reconnect.sh and existing_value() below have always read an
# unterminated last line the same way. The password prompt applies the same rule.
ask() {
    local prompt="$1" reply=""
    IFS= read -r -p "$prompt" reply || [ -n "$reply" ] || die "no more input (end of file) while asking: $prompt
Run this from a terminal, or write $CONFIG_FILE by hand from $EXAMPLE and then run ./manual-setup/install-cron.sh."
    printf '%s' "$reply"
}

# For the answers where surrounding blanks can only be a slip: an interface name
# cannot contain them, and neither can a number or the word yes. Trimming here
# means `5 ` is accepted as 5 rather than refused as "not a whole number", which
# is a needless re-prompt over something with exactly one sensible reading. It is
# deliberately not used for the SSID or the password, where a blank can be real.
#
# The `|| exit 1` is what carries ask()'s end-of-input refusal out of here, and
# it is not redundant with `set -e`. This function always runs inside a command
# substitution, and bash clears `set -e` in those, so the failed assignment
# below used to be ignored: ask()'s die() ended only the inner subshell, this
# function went on to print an empty reply and return 0, and every caller read
# that as "take the default". Measured: with the answers running out after the
# password, the run printed "no more input" three times and then wrote
# config.env, installed the cron job and exited 0 -- end of input taken as
# consent, the one thing ask() exists to prevent. die()'s message has already
# been printed by then, so a bare exit is enough, and the caller's assignment
# fails under its own `set -e`.
ask_trimmed() {
    local reply
    reply="$(ask "$1")" || exit 1
    reply="${reply#"${reply%%[![:space:]]*}"}"
    reply="${reply%"${reply##*[![:space:]]}"}"
    printf '%s' "$reply"
}

# --- Existing configuration ---------------------------------------------------
# Read only to pre-fill the prompts below.
#
# This is a second parser for a file reconnect.sh already parses, which is
# normally the exact thing this project refuses to do -- uninstall-cron.sh shells
# out to install-cron.sh rather than grow a second idea of what "our cron line"
# means, for precisely this reason. It is tolerable here, and only here, because
# of what the result is used for: it fills in a default that is then shown on
# screen and confirmed by a person, it decides nothing, and reconnect.sh re-reads
# the file for real a few steps later in the verification run. The worst a
# disagreement can do is offer a wrong default that the user can see and type
# over. Do not grow this into anything that acts on what it reads.
#
# The value handling mirrors config_value(): trim blanks from both ends, then
# strip one layer of matching quotes and take what is inside literally.
existing_value() {
    local want="$1" line lineno=0 key v
    [ -f "$CONFIG_FILE" ] || return 1
    [ -r "$CONFIG_FILE" ] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        lineno=$((lineno + 1))
        # The UTF-8 byte-order mark, stripped from the first line only, exactly
        # as load_config() does it in reconnect.sh -- and this is one of the
        # places the two parsers really do have to agree, not merely a tidiness.
        # Without it a config.env that reconnect.sh reads perfectly well was one
        # this parser read with its *first* key mangled: the three invisible
        # bytes sit in front of it, so `WIFI_SSID` did not compare equal to
        # `WIFI_SSID` and no default was offered for it. Re-running the script
        # over such a file then answered Enter with "The SSID is required", and
        # driven from a pipe rather than a terminal it re-asked until end of
        # input and died. Only the first line can carry a BOM, which is why the
        # strip is anchored to it here for the same reason it is there.
        [ "$lineno" -ne 1 ] || line="${line#$'\xef\xbb\xbf'}"
        line="${line#"${line%%[![:space:]]*}"}"
        case "$line" in '' | '#'*) continue ;; esac
        case "$line" in export[[:space:]]*)
            line="${line#export}"
            line="${line#"${line%%[![:space:]]*}"}"
            ;;
        esac
        case "$line" in *=*) ;; *) continue ;; esac
        key="${line%%=*}"
        key="${key#"${key%%[![:space:]]*}"}"
        key="${key%"${key##*[![:space:]]}"}"
        [ "$key" = "$want" ] || continue
        v="${line#*=}"
        v="${v#"${v%%[![:space:]]*}"}"
        v="${v%"${v##*[![:space:]]}"}"
        case "$v" in
            '"'*'"') v="${v:1:${#v}-2}" ;;
            "'"*"'") v="${v:1:${#v}-2}" ;;
        esac
        printf '%s' "$v"
        return 0
    done < "$CONFIG_FILE"
    return 1
}

had_config=0
old_ssid=""
old_iface=""
old_hidden=""
had_password=0
if [ -f "$CONFIG_FILE" ]; then
    had_config=1
    old_ssid="$(existing_value WIFI_SSID || true)"
    old_iface="$(existing_value WIFI_IFACE || true)"
    old_hidden="$(existing_value WIFI_HIDDEN || true)"
    # Whether there is one, never what it is. Nothing in this script prints a
    # password, and a "current value" shown for confirmation would be the one
    # place that did.
    [ -z "$(existing_value WIFI_PASSWORD || true)" ] || had_password=1
fi

echo "InternetReconnector setup"
echo
if [ -n "$carried_notes" ]; then
    printf '%s\n' "$carried_notes"
    carried_notes=""
fi
if [ "$had_config" -eq 1 ]; then
    echo "There is already a config at $CONFIG_FILE."
    echo "Its current settings are the defaults below -- press Enter to keep one."
    echo "The old file will be saved as $CONFIG_FILE.bak before anything is written."
    echo
fi

# --- WIFI_SSID ----------------------------------------------------------------
# Required, and blanks-only is refused for the reason reconnect.sh refuses it:
# a value that is only spaces passes an "is it empty?" test and then fails much
# later at the connect, as a runtime error standing in for a config error. Asked
# again rather than fatally, because there is somebody right here to ask.
ssid=""
while true; do
    if [ -n "$old_ssid" ]; then
        ssid="$(ask "Wi-Fi network name (SSID) [$old_ssid]: ")"
        [ -n "$ssid" ] || ssid="$old_ssid"
    else
        ssid="$(ask "Wi-Fi network name (SSID): ")"
    fi
    case "$ssid" in
        '') echo "  The SSID is required." >&2 ;;
        *[![:space:]]*) break ;;
        *) echo "  An SSID of nothing but blanks is refused: it would fail later at the connect, naming neither the setting nor anything you can see." >&2 ;;
    esac
done

# --- WIFI_PASSWORD ------------------------------------------------------------
# `read -s`, so it is never echoed to the terminal and never reaches the scroll
# back. It is not asked for twice: a typo is caught a few steps below by the
# verification run, which reports nmcli's own reason with the password scrubbed
# out, and that is a better check than asking someone to type it identically
# twice -- but only when that run actually uses it. A run that finds the machine
# already on the network logs "Wifi Good" and never reaches the connect, and one
# that reconnects through a saved profile never reaches the password form, so in
# both the password goes untested. The first of those is visible in the log line
# and is said out loud after the run; see the note beside the readback.
#
# Skippable, and said so out loud, because WIFI_PASSWORD is genuinely optional
# and SECURITY.md steers people away from it: once NetworkManager has a saved
# profile, `nmcli connection up` needs no password, so the setting can stay empty
# and the secret never enters this file at all.
#
# On a re-run Enter keeps the stored password, so it cannot also mean "none":
# '-' is the answer that removes it. Without one, a password once stored could
# never be taken out again by this script -- the route SECURITY.md recommends
# (leave WIFI_PASSWORD empty and rely on the saved profile) was closed to
# anyone who had used it before. '-' cannot be a real Wi-Fi password: a WPA
# passphrase is 8 to 63 characters, and a WEP key is never one. It means "no
# password" on a first run too, so the same answer works either way.
echo
echo "Wi-Fi password. This is optional:"
if [ "$had_password" -eq 1 ]; then
    echo "  * press Enter to keep the password already in $CONFIG_FILE,"
    echo "  * type - to remove it and rely on the saved NetworkManager profile,"
    echo "  * or type a new one to replace it."
else
    echo "  * leave it empty if NetworkManager already has a saved profile for"
    echo "    this network -- connect once through the desktop UI and the password"
    echo "    never has to be stored here at all (see .github/SECURITY.md),"
    echo "  * otherwise type it now. It is not shown as you type."
fi
password=""
keep_password=0
IFS= read -r -s -p "Wi-Fi password: " password \
    || [ -n "$password" ] || die "no more input (end of file) while asking for the password.
Run this from a terminal, or write $CONFIG_FILE by hand from $EXAMPLE and then run ./manual-setup/install-cron.sh."
echo
if [ -z "$password" ] && [ "$had_password" -eq 1 ]; then
    keep_password=1
    password="$(existing_value WIFI_PASSWORD || true)"
    echo "  Keeping the existing password."
elif [ "$password" = "-" ] && [ "$had_password" -eq 1 ]; then
    password=""
    echo "  Removing the stored password. The saved NetworkManager profile will be used."
    echo "  $CONFIG_FILE.bak will still hold the old one; delete it once this run succeeds."
elif [ -z "$password" ] || [ "$password" = "-" ]; then
    password=""
    echo "  No password stored. The saved NetworkManager profile will be used."
fi

# --- WIFI_IFACE ---------------------------------------------------------------
# Offered as a list rather than asked for blind, because this is the one setting
# the README already answers with "go and run a command": `nmcli device status`.
# Doing it here saves the round trip and stops a typo becoming a run that fails
# at the connect with nmcli's own device error.
#
# The terse output is split on ':' with no unescaping, unlike the SSID handling
# in reconnect.sh, and that is safe for this field specifically: these are kernel
# network interface names, which cannot contain ':' or '\'. An SSID can contain
# both, which is why reconnect.sh carries an unescaper and this does not.
wifi_devices=()
if command -v nmcli >/dev/null 2>&1; then
    while IFS= read -r dev_line; do
        [ -n "$dev_line" ] || continue
        case "$dev_line" in
            *:wifi) wifi_devices+=("${dev_line%:wifi}") ;;
        esac
    done < <(nmcli -t -f DEVICE,TYPE device 2>/dev/null || true)
fi

#
# With a device already set, Enter keeps it, so "leave it empty" cannot also be
# how to go back to automatic -- and the screen used to say it was, then kept
# the old device. '-' is the answer that clears it, as at the password prompt;
# the text above the prompt says which of the two Enter means on this run.
echo
iface=""
if [ "${#wifi_devices[@]}" -eq 0 ]; then
    # No list to offer: either nmcli is absent, or it reports no Wi-Fi device.
    # Neither is a reason to refuse -- the setting is optional and the machine
    # may simply not have its adapter up yet -- so fall back to a typed name.
    if [ -n "$old_iface" ]; then
        echo "Wi-Fi interface. Press Enter to keep $old_iface, or type - to let"
        echo "NetworkManager pick the device. ('nmcli device status' lists them.)"
        iface="$(ask_trimmed "Interface [$old_iface]: ")"
        case "$iface" in
            '') iface="$old_iface" ;;
            -) iface="" ;;
        esac
    else
        echo "Wi-Fi interface. Leave empty to let NetworkManager pick the device,"
        echo "which is the usual answer. ('nmcli device status' lists them.)"
        iface="$(ask_trimmed "Interface []: ")"
        [ "$iface" != "-" ] || iface=""
    fi
else
    if [ -n "$old_iface" ]; then
        echo "Wi-Fi interface. Press Enter to keep $old_iface, or type - to let"
        echo "NetworkManager pick. Detected Wi-Fi devices:"
    else
        echo "Wi-Fi interface. Leave empty (just press Enter) to let NetworkManager"
        echo "pick, which is the usual answer. Detected Wi-Fi devices:"
    fi
    i=1
    for dev in "${wifi_devices[@]}"; do
        if [ "$dev" = "$old_iface" ]; then
            printf '  %s) %s   (currently set)\n' "$i" "$dev"
        else
            printf '  %s) %s\n' "$i" "$dev"
        fi
        i=$((i + 1))
    done
    while true; do
        if [ -n "$old_iface" ]; then
            iface="$(ask_trimmed "Number, name, - for automatic, or Enter to keep [$old_iface]: ")"
            [ -n "$iface" ] || { iface="$old_iface"; break; }
        else
            iface="$(ask_trimmed "Number, name, or Enter for automatic: ")"
            [ -n "$iface" ] || break
        fi
        # Ahead of the case below, which would take '-' as a device name.
        [ "$iface" != "-" ] || { iface=""; break; }
        # A number selects from the list; anything else is taken as a device
        # name, so a device nmcli did not report can still be named by hand.
        #
        # There is deliberately no `''` arm. An empty answer is settled by the
        # two `[ -n "$iface" ]` tests just above, both of which break before the
        # loop reaches here, so an arm for it could never be taken -- and an
        # unreachable arm reads as though empty were a case this `case` still
        # had to consider. If either of those tests is ever removed, the digits
        # arm below needs an emptiness test of its own before the `-ge`:
        # `[ "" -ge 1 ]` produces the same bash diagnostic the width rule below
        # exists to keep off the screen.
        case "$iface" in
            *[!0-9]*) break ;;
            *)
                # Digits only by here, and that was not enough. Bash compares
                # with intmax_t, so `[ "$iface" -ge 1 ]` on a wider run of
                # digits printed a bare "integer expected" on stderr before
                # this loop could say anything of its own -- measured with an
                # answer of 23 digits, which produced
                # `auto-setup.sh: line NNN: [: 99999999999999999999999:
                # integer expected` and only then the message below.
                #
                # Measured after stripping leading zeros, matching
                # fits_in_integer() in reconnect.sh and install-cron.sh and the
                # interval prompt further down, so an answer spelled 0000000001
                # still selects the first device. An over-wide answer is not a
                # device number in any case, so it is refused exactly the way
                # any other out-of-range one is rather than getting a message
                # of its own.
                iface_digits="${iface#"${iface%%[!0]*}"}"
                if [ "${#iface_digits}" -le 18 ] \
                    && [ "$iface" -ge 1 ] && [ "$iface" -le "${#wifi_devices[@]}" ]; then
                    # Forced to base 10 for the reason the interval prompt
                    # forces it: bash reads a leading zero inside $(( )) as
                    # octal, and `08` is not octal at all, so an answer of 08
                    # on a list that long would have failed the subtraction
                    # rather than selecting the eighth device.
                    iface="${wifi_devices[$((10#$iface - 1))]}"
                    break
                fi
                echo "  There is no device $iface in that list." >&2
                ;;
        esac
    done
fi
# The same guard reconnect.sh applies, for the same reason: an interface name
# cannot be made of blanks, so this refuses nothing legal and catches a stray
# quoted space that would otherwise reach nmcli as `ifname "   "`.
case "$iface" in
    '' | *[![:space:]]*) ;;
    *)
        echo "  An interface of nothing but blanks is not a device name; using automatic instead." >&2
        iface=""
        ;;
esac

# --- WIFI_HIDDEN --------------------------------------------------------------
# The spellings accepted here are the ones reconnect.sh accepts, so an answer
# this script takes is never one the scheduled job then refuses.
echo
hidden_default=no
case "${old_hidden,,}" in
    yes | true | 1) hidden_default=yes ;;
esac
hidden=""
while true; do
    hidden="$(ask_trimmed "Does this network hide its name (a hidden SSID)? [yes/no, default $hidden_default]: ")"
    [ -n "$hidden" ] || hidden="$hidden_default"
    case "${hidden,,}" in
        yes | true | 1) hidden=yes; break ;;
        no | false | 0) hidden=no; break ;;
        *) echo "  Answer yes or no; got: '$hidden'" >&2 ;;
    esac
done

# --- Interval -----------------------------------------------------------------
# Validated here against the same rule install-cron.sh enforces, so a bad answer
# is a re-prompt with somebody present rather than a hard exit after the config
# has already been written. install-cron.sh validates it again regardless -- this
# is a convenience, not the enforcement.
#
# MINUTES already set in the environment skips the question, because that is the
# documented way to choose an interval without being asked. It has already been
# checked and normalised by the block at the top of this script, so the value
# quoted below is one install-cron.sh will accept.
#
# An empty answer stays empty and is handed to install-cron.sh as an empty
# MINUTES, which that script reads as "not set" and answers with the interval
# already on the installed cron line, falling back to 5 only when there is no
# line to read. Defaulting to 5 here instead looked equivalent and was not: it
# overrode the carry-over, so re-running this script to change one setting reset
# a chosen interval back to 5 in silence -- which is the exact surprise
# install-cron.sh grew previous_minutes() to prevent, reintroduced one level up
# by the script that calls it.
minutes=""
if [ -n "${MINUTES:-}" ]; then
    # The normalised value check_interval() printed, not the raw MINUTES: `05`
    # arrives here as 5, so the line below quotes what will actually be
    # installed and the two paths out of this block agree about what $minutes
    # holds.
    minutes="$checked_minutes"
    echo
    echo "Using the interval from MINUTES: every $minutes minutes."
else
    echo
    # What Enter means depends on whether a job is installed, not on whether a
    # config exists -- install-cron.sh reads the interval off the cron line, and
    # the line can exist without a config. This used to test $had_config, so
    # after the manual route in the "wrong" order (install first, which
    # install-cron.sh itself anticipates with its "no config file yet" note), a
    # first run here said "Press Enter for every 5 minutes" and then installed
    # the 10 the line already carried. The interval is read off the line the
    # way install-cron.sh's previous_minutes() reads it, so the prompt can name
    # it; a line whose interval install-cron.sh will not carry is reported as
    # such instead (see below).
    #
    # The interval read off the line is held to check_interval() too, because
    # install-cron.sh validates it before keeping it. A hand-edited `*/7` used
    # to be offered here as "Press Enter to keep the interval already installed
    # (every 7 minutes)", and pressing Enter ran the verification, printed
    # "Settings work" and was then refused by install-cron.sh with "must divide
    # 60 evenly" -- after the interview, over a default this script had offered,
    # with closing advice to re-run install-cron.sh, which fails the same way. A
    # value wider than two digits (`*/123`) took a general "keep" wording and
    # met the same refusal. Such an interval is now said to be unusable, and
    # Enter means 5, passed to install-cron.sh explicitly so that it never
    # validates the line's interval at all.
    #
    # The field is taken whole, as previous_minutes() takes it, and
    # check_interval() applies the width rule before any arithmetic.
    #
    # Read off $installer_line, the line install-cron.sh will itself carry, and
    # never off the loose $installed_line. Every installed line therefore ends in
    # one of two answers: an interval that is kept and named, or a stated reason
    # it cannot be kept, with Enter meaning 5. There used to be a third, "Press
    # Enter to keep the interval already installed." with no figure, for a line
    # whose schedule was not `*/N` -- and install-cron.sh keeps nothing there:
    # previous_minutes() reads only `*/N`, so a hand-made `0,30 * * * *` was
    # replaced by `*/5` right after the promise to keep it. A line edited past
    # what ours() recognises got the promise too, interval named and all, and
    # install-cron.sh then left it and installed a second job every 5 minutes.
    installed_minutes=""
    installed_minutes_reason=""
    if [ -n "$installer_line" ]; then
        installed_field="${installer_line#"${installer_line%%[![:space:]]*}"}"
        case "$installed_field" in
            '*/'*)
                installed_field="${installed_field%%[[:space:]]*}"
                installed_field="${installed_field#\*/}"
                case "$installed_field" in
                    '' | *[!0-9]*)
                        installed_minutes_reason="install-cron.sh keeps only an every-N-minutes schedule, and '*/$installed_field' is not one." ;;
                    *)
                        if ! installed_minutes="$(check_interval "$installed_field")"; then
                            installed_minutes_reason="install-cron.sh would refuse it: $installed_minutes"
                            installed_minutes=""
                        fi
                        ;;
                esac
                ;;
            *)
                read -r sched_1 sched_2 sched_3 sched_4 sched_5 _ <<< "$installer_line"
                installed_minutes_reason="install-cron.sh keeps only an every-N-minutes schedule, and '$sched_1 $sched_2 $sched_3 $sched_4 $sched_5' is not one."
                ;;
        esac
    elif [ -n "$installed_line" ]; then
        installed_minutes_reason="that line was edited past what install-cron.sh recognises as its own, so it is left in place and a new line is installed beside it."
    fi
    if [ -n "$installed_minutes" ]; then
        echo "Run how often? Press Enter to keep the interval already installed"
        echo "(every $installed_minutes minutes)."
    elif [ -n "$installed_minutes_reason" ]; then
        echo "The interval on the installed cron line cannot be kept, because"
        echo "$installed_minutes_reason"
        echo "Run how often? Press Enter for every 5 minutes."
    else
        echo "Run how often? Press Enter for every 5 minutes."
    fi
    while true; do
        answer="$(ask_trimmed "Interval in minutes: ")"
        # Empty means "let install-cron.sh decide", so there is nothing to
        # validate and nothing to pass -- except where the installed interval
        # cannot be kept, where Enter means the 5 the prompt just offered.
        if [ -z "$answer" ]; then
            [ -z "$installed_minutes_reason" ] || minutes=5
            break
        fi
        # The rules, the wording and the normalisation all live in
        # check_interval(); on success $minutes is the value it normalised, on
        # failure it is the reason, which is printed and then cleared so that a
        # reason can never be mistaken for an interval further down.
        if minutes="$(check_interval "$answer")"; then
            break
        fi
        echo "  $minutes" >&2
        minutes=""
    done
fi

# --- Write the config ---------------------------------------------------------
echo
if [ "$had_config" -eq 1 ]; then
    # `cp` is checked before the interview, beside the backup's other needs.
    cp -- "$CONFIG_FILE" "$CONFIG_FILE.bak" \
        || die "could not back up $CONFIG_FILE to $CONFIG_FILE.bak; nothing was changed."
    # The backup gets mode 600 of its own, and not only by inheritance. `cp`
    # creates the copy with the *source's* mode, and the source is whatever the
    # user left it at: the README's `chmod 600` is an instruction, nothing
    # enforces it, and reconnect.sh runs a 644 config without comment. So a
    # hand-made config left world-readable produced a world-readable backup
    # holding the same password -- while the new config below was tightened to
    # 600 and the line above reported only that the previous one was saved.
    # After that run `ls -l` showed a 600 config beside a readable copy of it,
    # under documentation saying the password lives at mode 600. The exposure
    # was not new, but the run that appeared to have closed it had not.
    #
    # Refused rather than warned about when chmod fails, for the reason the
    # main file's chmod is: a password is about to sit in a file whose mode is
    # not what this script says it is. Where chmod is missing altogether the
    # warning further down names both files.
    if command -v chmod >/dev/null 2>&1; then
        chmod 600 "$CONFIG_FILE.bak" \
            || die "could not set mode 600 on $CONFIG_FILE.bak; refusing to leave a copy of the password in a file whose permissions are unknown. $CONFIG_FILE itself is unchanged."
    fi
    echo "Saved the previous config as $CONFIG_FILE.bak"
fi

# The file is created empty and its mode set *before* anything is written into
# it, so the password never exists on disk in a world-readable file even for the
# instant between the write and the chmod. Writing first and chmodding after is
# the obvious order and it is the wrong one.
#
# The redirections are in this order because bash applies them left to right: with
# `> "$CONFIG_FILE"` first, a failing open is reported before stderr has been
# silenced, so bash's own `auto-setup.sh: line NNN: ...: No such file or
# directory` was printed ahead of the stated reason below -- the raw diagnostic
# the width guards further up exist to keep off the screen, at the one place the
# script had a perfectly good message of its own to print instead. The same
# ordering, for the same reason, as the descriptor probe in the suite's nmcli
# stub.
#
# The `|| die` stays whatever the checks at the top of this script said: `-w` is
# a prediction, and this is the write.
: 2>/dev/null > "$CONFIG_FILE" || die "could not write $CONFIG_FILE (check the directory's owner and mode)."
if command -v chmod >/dev/null 2>&1; then
    chmod 600 "$CONFIG_FILE" \
        || die "could not set mode 600 on $CONFIG_FILE; refusing to write a password into a file whose permissions are unknown."
elif [ -n "$password" ]; then
    # No chmod and a password to store: say so rather than quietly leaving the
    # secret at whatever the umask happened to give it. The backup, where there
    # is one, holds the previous password at whatever mode the previous file
    # had, so it is named too.
    echo "WARNING: chmod was not found, so $CONFIG_FILE keeps its default" >&2
    echo "         permissions. It holds your Wi-Fi password. Restrict it yourself:" >&2
    echo "           chmod 600 '$CONFIG_FILE'" >&2
    if [ "$had_config" -eq 1 ]; then
        echo "         The backup was left at the previous file's mode; restrict it too:" >&2
        echo "           chmod 600 '$CONFIG_FILE.bak'" >&2
    fi
fi

# Every value is written inside double quotes. reconnect.sh's parser strips one
# layer of matching quotes and takes what is inside literally -- no expansion, no
# escape processing -- so this round-trips anything `read` can produce, including
# a value with leading or trailing spaces, a '#', a '$', a backtick or an
# embedded quote. A newline is the one thing it could not carry, and `read`
# cannot produce one.
{
    printf '# Written by auto-setup.sh. See manual-setup/config.env.example for what each\n'
    printf '# setting means. This file is parsed, not run as a shell script.\n'
    printf 'WIFI_SSID="%s"\n' "$ssid"
    printf 'WIFI_PASSWORD="%s"\n' "$password"
    printf 'WIFI_IFACE="%s"\n' "$iface"
    printf 'WIFI_HIDDEN="%s"\n' "$hidden"
} >> "$CONFIG_FILE" || die "could not write $CONFIG_FILE."

echo "Wrote $CONFIG_FILE"
printf '  WIFI_SSID     %s\n' "$ssid"
if [ "$keep_password" -eq 1 ]; then
    printf '  WIFI_PASSWORD (unchanged)\n'
elif [ -n "$password" ]; then
    printf '  WIFI_PASSWORD (set, not shown)\n'
else
    printf '  WIFI_PASSWORD (empty -- using the saved NetworkManager profile)\n'
fi
if [ -n "$iface" ]; then
    printf '  WIFI_IFACE    %s\n' "$iface"
else
    printf '  WIFI_IFACE    (automatic)\n'
fi
printf '  WIFI_HIDDEN   %s\n' "$hidden"

# --- Verify -------------------------------------------------------------------
# The README's own setup order is configure, test by hand, then install, and this
# is the "test by hand" step. It matters more here than it does there: cron sends
# the job's stderr to /dev/null, so a wrong password or a mistyped SSID installed
# without this check announces itself only as FAIL in a log file, with the reason
# thrown away every interval. Running it once now is the single moment somebody
# is present to read the reason.
#
# reconnect.sh writes one log line for this run, exactly as the README's
# by-hand test does -- and that line, not the exit status, is what says whether
# the settings were tested. Exit 0 alone was taken as "they work", and it is
# not: reconnect.sh also exits 0 when it finds its overlap lock held by another
# run, logging "Skipped (already running)" without touching nmcli at all. A
# re-run of this script while the installed job is mid-run -- which is exactly
# when somebody re-runs it to fix a wrong password, and a failing run holds
# the lock for ~139 of every 300 seconds at the defaults -- therefore printed
# "NOTE: another reconnect.sh run is still in progress; skipping." and, two
# lines later, "Settings work. Installing the cron job...", and installed a
# job whose settings nobody had tested. Measured, with the lock held and a
# password nmcli refused: exit 0, "Settings work", one job in the crontab; the
# same answers with the lock free were refused.
#
# So the outcome this run logged is read back, and it has to be *this run's*.
# Two earlier versions read it out of the day file, and both let another line
# stand in for it:
#
#   * The last line in the file. reconnect.sh treats a day file it cannot
#     append to as a warning and carries on (a file left by an earlier
#     `sudo ./reconnect.sh` is the ordinary way to get one), so a stale
#     "Wifi Good" at the end installed a wrong password under "Settings work",
#     and a stale "FAIL" refused settings that had been tested.
#   * The first line past a count taken before the run. That shut out stale
#     lines but not concurrent ones: the installed job appends to the same
#     file. Measured with stubs: a scheduled run stepping aside mid-verification
#     put "Skipped (already running)" first, and a verification that had
#     reconnected was refused as untested; one finishing in the instant before
#     the verification found the lock held put its "Wifi Good" first, and a
#     verification that never ran nmcli installed a wrong password under
#     "Settings work".
#
# So the run is handed a file of its own (IR_OUTCOME_FILE, made before the
# interview), and reconnect.sh's status() writes the outcome there after its
# day-file append succeeds. Nothing else has that path. An empty file is
# refused: the run could not record its outcome at all -- a log directory it
# could not create, a day file it could not append to -- and a job that cannot
# log is the silence every check here exists to prevent.
#
# Read with the builtin, `2>/dev/null` ahead of the `<` for the reason the
# config write orders its redirections that way, and never fatal.
#
# A refusal below must also leave an installed job reading what it read before.
# The config is written ahead of this run, and the job that is already in the
# crontab reads that same file -- so a re-run refused here used to say "the cron
# job was NOT installed" and "$CONFIG_FILE has been kept" while the job it had
# not installed was already running on the refused settings. Measured with
# stubs: a working job, then a re-run with the SSID mistyped, refused as it
# should be -- and the job's next run logged FAIL, every interval after that,
# with the reason going to /dev/null. With the lock held it was the untested
# case again: "the settings were NOT tested", and the job then ran on the
# password just typed. Writing the file only after the run passes would mean
# testing a different path from the one the job reads, so the write stays where
# it is and a refusal undoes it instead -- but only where a job of this
# checkout's is installed. With none there is nothing that reads the file, and
# keeping it is what lets a re-run offer the answers just given as defaults.
config_put_back=0
put_back_config() {
    if [ -z "$installed_line" ]; then
        echo "$CONFIG_FILE has been kept:" >&2
        echo "on a re-run each current value is offered as the default, so only" >&2
        echo "the wrong one has to be retyped." >&2
        return 0
    fi
    config_put_back=1
    if [ "$had_config" -eq 1 ]; then
        if cp -- "$CONFIG_FILE.bak" "$CONFIG_FILE" 2>/dev/null; then
            echo "The installed cron job reads $CONFIG_FILE, so the previous config" >&2
            echo "has been put back from $CONFIG_FILE.bak and the job carries on with" >&2
            echo "the settings it had. A re-run offers those as the defaults, so give" >&2
            echo "your change again." >&2
            return 0
        fi
        echo "WARNING: could not put the previous config back from $CONFIG_FILE.bak." >&2
        echo "         The installed cron job now reads the settings above, which did" >&2
        echo "         not pass. Restore it yourself:" >&2
        echo "           cp '$CONFIG_FILE.bak' '$CONFIG_FILE'" >&2
        return 0
    fi
    if rm -f -- "$CONFIG_FILE" 2>/dev/null; then
        echo "The installed cron job reads $CONFIG_FILE, which did not exist before" >&2
        echo "this run, so it has been removed again and the job finds no config, as" >&2
        echo "it did before. A re-run asks for every setting again." >&2
        return 0
    fi
    echo "WARNING: could not remove $CONFIG_FILE again. The installed cron job now" >&2
    echo "         reads the settings above, which did not pass. Remove it yourself." >&2
    return 0
}

# The install-cron.sh command a refusal below tells the user to run by hand,
# carrying what this run would have handed it: the interval chosen at the prompt
# and every setting in the environment, the ones carried off the cron line
# included. The advice used to be a bare `./manual-setup/install-cron.sh`, and
# followed literally that is a different install: MINUTES typed at the prompt
# exists only in this script, so the job went in at the interval already on the
# line (or 5) rather than the one just chosen -- measured, a re-run answering 15
# over a */10 job whose crontab write failed was told to run it, and it
# reinstalled */10. A RECONNECT_CONFIG given only for this run was dropped the
# same way, pointing the job at a config nobody had written.
#
# Single quotes are safe around every value: the paths and CRON_PATH were held
# to check_cron_safe() before the interview, which refuses a single quote, and
# the numeric settings and the interval are digits.
install_command() {
    local cmd="" setting
    [ -z "$minutes" ] || cmd="MINUTES='$minutes' "
    for setting in RECONNECT_CONFIG RECONNECT_LOG_DIR RECONNECT_LOG_RETENTION_DAYS \
        RECONNECT_SCAN_WAIT_SECS RECONNECT_CONNECT_ATTEMPTS RECONNECT_NMCLI_WAIT_SECS \
        CRON_PATH; do
        [ -z "${!setting:-}" ] || cmd="$cmd$setting='${!setting}' "
    done
    printf '%s./manual-setup/install-cron.sh' "$cmd"
}

# VERIFY_LOG_DIR was resolved, and vetted, before the interview.
echo
echo "Testing the settings by running reconnect.sh once..."
echo
verify_status=0
IR_OUTCOME_FILE="$verify_outcome" RECONNECT_CONFIG="$CONFIG_FILE" bash "$RECONNECT" \
    || verify_status=$?

verify_line=""
if [ "$verify_status" -eq 0 ]; then
    IFS= read -r verify_line 2>/dev/null < "$verify_outcome" || true
    case "$verify_line" in
        "Skipped (already running)")
            echo >&2
            echo "Another reconnect.sh run was still in progress -- most likely the" >&2
            echo "scheduled job -- so this one stepped aside: the settings were NOT tested" >&2
            echo "and the cron job was NOT installed. Wait for that run to finish (a" >&2
            echo "failing one takes up to a few minutes) and re-run this script." >&2
            put_back_config
            exit 1
            ;;
        "Wifi Good")
            # Already on the network, so reconnect.sh never reached the connect
            # and a password typed above was not used at all. "Settings work"
            # follows, and the README used to promise that a wrong password is
            # caught here; measured, a wrong one was installed under that line
            # with nothing to say it had not been tried. Not a refusal: the
            # settings that were exercised did work, and the usual reason to be
            # connected while running this is that the network is the right one.
            # Only for a password typed this run -- a kept one was said to be
            # kept, and an empty one has nothing to test.
            if [ -n "$password" ] && [ "$keep_password" -eq 0 ]; then
                echo
                echo "NOTE: this machine is already on $ssid, so the test did not need to"
                echo "      connect and the password you typed was not tried. It is used only"
                echo "      when a later run has to reconnect without a working saved profile;"
                echo "      if it is wrong, that run will log FAIL."
            fi
            ;;
        "Wifi Reconnected") ;;
        *)
            echo >&2
            echo "reconnect.sh exited 0 but wrote no new line to its log in" >&2
            echo "$VERIFY_LOG_DIR, so the settings could not be confirmed and the cron job" >&2
            echo "was NOT installed. A job that cannot write its log line would fail in" >&2
            echo "silence. Read the warning above (usually the log directory cannot be" >&2
            echo "created, or today's log file cannot be written to -- check its owner" >&2
            echo "and mode), fix it, and re-run this script." >&2
            put_back_config
            exit 1
            ;;
    esac
fi

if [ "$verify_status" -ne 0 ]; then
    echo
    # Says what to do without asserting why it failed. It used to state a cause
    # -- "the reason above usually means one field is wrong rather than all of
    # them" -- and that is only true when reconnect.sh refused an *answer*. It
    # also refuses a missing nmcli, a missing date or awk, and a log directory it
    # cannot write, and for every one of those the advice was actively wrong: no
    # field was wrong, and re-running to retype the same correct answers fails
    # identically. The environment values that used to land here are refused
    # before the interview now, which narrows the case but does not close it,
    # because a missing command still reaches this line.
    echo "That did not work, so the cron job was NOT installed." >&2
    put_back_config
    echo "Read the reason above:" >&2
    echo "  * if it names one of the settings you just gave, re-run this script" >&2
    echo "    and correct it;" >&2
    echo "  * if it names a missing command or something in your environment, fix" >&2
    echo "    that instead -- re-running with the same answers" >&2
    echo "    would fail the same way." >&2
    echo >&2
    # install-cron.sh directly is only advice where the answers were kept: with
    # the config put back, an install would schedule the old settings, which
    # are already scheduled.
    if [ "$config_put_back" -eq 1 ]; then
        echo "Fix it and re-run this script:" >&2
        echo "  ./auto-setup.sh" >&2
    else
        echo "Fix it and either re-run this script, or install the job directly:" >&2
        echo "  ./auto-setup.sh" >&2
        echo "  $(install_command)" >&2
    fi
    exit 1
fi

# --- Install ------------------------------------------------------------------
# Delegated to install-cron.sh rather than written here, for the reason
# uninstall-cron.sh gives for delegating the same work: a second idea of what
# this tool's cron line looks like is how one of them ends up deleting or
# duplicating the other's. That script also validates MINUTES again, carries the
# RECONNECT_* settings across, vets everything that reaches the crontab, and
# warns about nmcli being off the cron PATH -- none of which is worth
# reimplementing here.
echo
echo "Settings work. Installing the cron job..."
echo
# The `[ -f "$INSTALLER" ]` check used to sit here, and here was too late: by
# this line the interview is over and config.env has been written, so a
# checkout missing install-cron.sh asked every question before saying so. It
# moved up beside reconnect.sh's, ahead of the first prompt; see the comment
# there. Nothing replaces it here, because a file that existed then and does
# not now is not a case worth a second check -- the `|| die` below reports it.
#
# A failure here says what it left behind. It used to say "the cron job is not
# installed" whatever was in the crontab, and on a re-run that is false: the job
# of this checkout's that was already there stays, since install-cron.sh refuses
# before it writes. The two cases are told apart the way put_back_config() tells
# them apart.
if [ -n "$installed_line" ]; then
    install_failed="install-cron.sh failed, so the cron job was not updated; the one already installed was left as it was."
else
    install_failed="install-cron.sh failed, so no cron job was installed."
fi
MINUTES="$minutes" bash "$INSTALLER" \
    || die "$install_failed $CONFIG_FILE was written and passed the test -- fix the reason above and run:
  $(install_command)"

echo
echo "Setup complete. To change a setting, re-run this script; to remove the"
echo "job again, run ./manual-setup/uninstall-cron.sh"
