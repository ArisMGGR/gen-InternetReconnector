#!/usr/bin/env bash
#
# reconnect.sh
#
# Checks whether this machine is connected to a target Wi-Fi network and,
# if it is not, (re)connects to it.
#
# Designed to be run periodically (e.g. every 5 minutes) from cron.
# Relies on NetworkManager's `nmcli`, which is the standard Wi-Fi manager
# on most Linux desktops (Ubuntu, Fedora, Debian, etc.).
#
# Logging: one file per day under logs/ (e.g. logs/2026-08-06.log). Each run
# appends exactly one line:
#   [HH:MM:SS] Wifi Good          -> already connected to the target network
#   [HH:MM:SS] Wifi Reconnected   -> was disconnected, reconnected successfully
#   [HH:MM:SS] FAIL               -> could not connect (or a setup error)
#   [HH:MM:SS] Skipped (already running)
#                                 -> a previous run was still going; this one
#                                    stepped aside and did nothing
#
# Configuration lives in `config.env` (see config.env.example). That file
# holds the SSID and password and is intentionally NOT committed to git.

set -euo pipefail

# --- Resolve paths -----------------------------------------------------------
# Resolve the directory this script lives in, so it works the same whether it
# is invoked from cron, from an absolute path, or from the current directory.
#
# Split with parameter expansion rather than `dirname`. This line runs before
# any preflight can: SCRIPT_DIR is what LOG_DIR defaults to, so until it is
# resolved there is nowhere to record a failure. A missing `dirname` therefore
# aborted the whole run under `set -e` with no log line at all -- exit 1, an
# empty logs/, and a bare "dirname: command not found" that cron sends to
# /dev/null -- which is the silent exit the `date` and `sleep` preflights below
# exist to prevent, arriving before either of them could fire. The expansion
# needs no external command, so that failure is no longer reachable.
#
# The two cases `dirname` handled that a bare `%/*` does not: a name with no
# slash in it (`bash reconnect.sh`), which means the current directory, and a
# script sitting directly in `/`, where stripping the last component leaves the
# empty string rather than `/`.
script_src="${BASH_SOURCE[0]}"
case "$script_src" in
    */*)
        script_dir="${script_src%/*}"
        [ -n "$script_dir" ] || script_dir=/
        ;;
    *) script_dir=. ;;
esac
SCRIPT_DIR="$(cd "$script_dir" && pwd)"
CONFIG_FILE="${RECONNECT_CONFIG:-$SCRIPT_DIR/config.env}"
LOG_DIR="${RECONNECT_LOG_DIR:-$SCRIPT_DIR/logs}"
LOG_RETENTION_DAYS="${RECONNECT_LOG_RETENTION_DAYS:-90}"

# True when $1 is a string of digits only (and non-empty).
is_uint() {
    case "$1" in
        '' | *[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

# True when $1 -- digits only by the time it gets here -- is narrow enough that
# bash can actually compare and count with it. Bash integers are intmax_t, and the
# two ways of going past that fail differently and both badly: `test -ge` refuses
# with a bare "integer expected" on stderr and a non-zero status, while `$(( ))`
# wraps in silence.
#
# Digits alone was not enough. A 20-digit RECONNECT_LOG_RETENTION_DAYS passed
# is_uint(), passed the validation further down, and then reached
# `[ ... -gt 0 ]` inside prune_logs() -- so pruning was silently off and a bash
# diagnostic was printed on every single run, with nothing saying why. Worse,
# install-cron.sh bounds the same settings with `$(( ))` rather than with `test`,
# so the identical value wrapped back into range there and was written onto the
# cron line: the installer reported a clean install for a value this script then
# refused, which is FAIL every interval with the reason going to /dev/null -- the
# one outcome validating in the installer exists to prevent. The two scripts now
# apply the same width rule, and install-cron.sh's fits_in_integer() is this
# function.
#
# Leading zeros are stripped before the width is measured, so a value spelled
# 0000000000000000000030 is still a legal 30. Eighteen digits is the widest run
# that cannot overflow a signed 64-bit integer.
fits_in_integer() {
    local n="${1#"${1%%[!0]*}"}"
    [ "${#n}" -le 18 ]
}

# --- Logging -----------------------------------------------------------------
# Delete daily logs older than LOG_RETENTION_DAYS. Only files whose name is
# exactly YYYY-MM-DD.log are considered, so nothing else a user keeps in the
# log directory is ever touched. ISO dates sort lexicographically, which is why
# a plain string comparison against the cutoff date is enough.
#
# The filter checks the *shape* of the name, not that it is a real date, and the
# comparison is lexicographic. A file called 2026-13-99.log therefore sorts after
# any cutoff and is never pruned. That is the harmless direction to err in -- the
# rule that matters is that nothing outside this naming scheme is ever deleted --
# so it is left as is rather than grown into date validation.
#
# Set RECONNECT_LOG_RETENTION_DAYS=0 to keep every log forever.
prune_logs() {
    is_uint "$LOG_RETENTION_DAYS" || return 0
    # Before the comparison, not after: prune_logs() is reached from status(),
    # which is reached from die(), so it sees values that have not been through
    # the validation further down. A value too wide for bash made the `-gt` below
    # print "integer expected" on stderr on every run rather than returning an
    # answer.
    fits_in_integer "$LOG_RETENTION_DAYS" || return 0
    [ "$LOG_RETENTION_DAYS" -gt 0 ] || return 0

    local cutoff file base
    # `date -d` is GNU-specific; where it is missing, pruning quietly does
    # nothing rather than guessing at dates.
    cutoff="$(date -d "$LOG_RETENTION_DAYS days ago" '+%Y-%m-%d' 2>/dev/null)" || return 0
    [ -n "$cutoff" ] || return 0

    for file in "$LOG_DIR"/*.log; do
        [ -f "$file" ] || continue
        base="${file##*/}"
        base="${base%.log}"
        case "$base" in
            [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
            *) continue ;;
        esac
        if [[ "$base" < "$cutoff" ]]; then
            rm -f "$file" 2>/dev/null || true
        fi
    done
    return 0
}

# Append one line to today's log file: logs/YYYY-MM-DD.log, prefixed with the
# time of day in [HH:MM:SS] form.
#
# Logging must never abort the run: if the log directory cannot be created or
# written, warn on stderr and carry on. Under cron stderr goes to /dev/null,
# but a hand-run then still shows why nothing is being recorded.
#
# The redirections on the printf are in this order because bash applies them
# left to right: with the `>>` first, a day file that cannot be opened made
# bash print its own `reconnect.sh: line NNN: /.../2026-09-11.log: Permission
# denied` before stderr had been silenced, ahead of the WARNING below that
# states the reason. auto-setup.sh's config write and the suite's nmcli stub
# order theirs the same way for the same reason; this was the one of the three
# that did not.
status() {
    if ! mkdir -p "$LOG_DIR" 2>/dev/null; then
        echo "WARNING: cannot create log directory: $LOG_DIR" >&2
        return 0
    fi
    if ! printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*" \
        2>/dev/null >> "$LOG_DIR/$(date '+%Y-%m-%d').log"; then
        echo "WARNING: cannot write to log directory: $LOG_DIR" >&2
    fi
    prune_logs
    return 0
}

# A setup error (missing config, bad value, missing nmcli) counts as a failure:
# record FAIL, print the reason to stderr for anyone running it by hand, then
# exit. Every exit path out of this script goes through either status() or
# die(), so each run appends exactly one line.
die() {
    status "FAIL"
    echo "ERROR: $*" >&2
    exit 1
}

# --- date --------------------------------------------------------------------
# `date` names the log file and timestamps every line, so a run without it
# cannot record its own outcome: status() would append a malformed line to a
# file called literally `.log`.
#
# Checked here, ahead of everything else, rather than beside the nmcli and awk
# checks further down. Sitting there it did not cover any of the die() calls
# that fire while the config is being read and validated -- every one of which
# runs before it -- so on a machine with no date a bad config key still
# produced exactly the failure this check exists to prevent: `[] FAIL` written
# into `logs/.log`, a name that neither prune_logs() nor
# `uninstall-cron.sh --purge-logs` will ever clean up, because neither will
# touch anything outside YYYY-MM-DD.log.
#
# The one path still exposed is die()'s own message just below, which cannot be
# helped: reporting that date is missing is the one thing that cannot wait for
# date to be present.
command -v date >/dev/null 2>&1 || die "date not found. Install coreutils."

# --- Interpreter check -------------------------------------------------------
# ${WIFI_HIDDEN,,} below needs bash 4.0. On bash 3.2 -- which is still what
# /bin/bash is on macOS -- it fails at expansion time with a bare "bad
# substitution" that says nothing about the cause. Check it up front so the
# reason is stated, and so the run is recorded like any other setup error.
if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ]; then
    die "bash 4.0 or newer is required; this is bash ${BASH_VERSION:-unknown}."
fi

# --- Arguments ---------------------------------------------------------------
# This script takes none. It used to accept whatever it was given and ignore it
# in silence, so `./reconnect.sh --help` printed no help: it read the config,
# called nmcli and attempted a live connect, then logged the outcome with
# nothing anywhere to say that the argument had meant nothing at all.
#
# install-cron.sh and uninstall-cron.sh both refuse an unrecognised argument,
# and install-cron.sh's comment gives the reason -- "silently installing the job
# in response to e.g. --help would be a nasty surprise". Driving the radio in
# response to one is the same surprise in the script that actually does it, so
# the rule now holds in all four rather than in two.
#
# Refused through die(), not a bare exit, so this path records FAIL like every
# other setup error and "each run appends exactly one line" still holds without
# an exception being carved into it. That is also why the check sits here rather
# than at the top of the file: die() timestamps through date, so it cannot run
# before the preflight above.
#
# There is deliberately no --help of its own. A usage exit that wrote no log
# line would be the first exit path in this script to skip status(), and the
# message below carries the same information a usage block would.
#
# The argument is quoted in the message for the reason the WIFI_HIDDEN check
# further down quotes its value, written out in full there: unquoted, an empty
# or blanks-only argument produced `got: . There is nothing to pass` -- a
# refusal whose subject is invisible, so the reader cannot see what was rejected
# or even that anything was there. `./reconnect.sh "$flag"` with $flag unset is
# how that arrives. install-cron.sh and uninstall-cron.sh quote theirs for the
# same reason.
if [ "$#" -gt 0 ]; then
    die "reconnect.sh takes no arguments; got: '$1'. There is nothing to pass -- the network settings live in $CONFIG_FILE and the tuning ones in the RECONNECT_* environment variables (see the README). Use manual-setup/install-cron.sh (or auto-setup.sh) to schedule it."
fi

# --- One run at a time -------------------------------------------------------
# A failing run can take longer than a short cron interval, so the next run can
# start before this one has finished. Both would then drive nmcli at once, and
# both would append a status line, so the day's log gained a second line for the
# one interval. Take the lock without waiting and step aside if another run
# holds it: that run is already handling this interval and will record its
# outcome, so there is nothing for this one to add.
#
# flock comes from util-linux and is not everywhere. Where it is missing the
# lock is skipped and overlapping runs behave as they did before, which is why
# install-cron.sh still warns about intervals shorter than the worst case.
#
# The descriptor is opened inside a guarded group, and a lock file that cannot
# be opened is treated exactly like a missing flock: the lock is skipped and the
# run goes on to record its outcome. The `exec` used to be bare, and `touch`
# above succeeds on a *directory* -- so a `.lock` that was a directory (or any
# other path `>>` cannot open) made `exec 9>>` fail under `set -e`: exit 1, a
# bare "Is a directory" on stderr, and no log line at all, which breaks "each
# run appends exactly one line". The `2>/dev/null` on the group is restored
# when the group ends; the `exec` inside it is what makes descriptor 9 persist.
if command -v flock >/dev/null 2>&1 \
    && mkdir -p "$LOG_DIR" 2>/dev/null \
    && touch "$LOG_DIR/.lock" 2>/dev/null \
    && [ -f "$LOG_DIR/.lock" ] \
    && { exec 9>>"$LOG_DIR/.lock"; } 2>/dev/null; then
    if ! flock -n 9; then
        # Log the skip rather than exiting silently. "Each run appends exactly
        # one line" is relied on when reading a day's log back: a run that
        # vanished without trace is indistinguishable from cron not having
        # fired at all, which is the more alarming of the two explanations.
        status "Skipped (already running)"
        echo "NOTE: another reconnect.sh run is still in progress; skipping." >&2
        exit 0
    fi
fi


# --- Load configuration ------------------------------------------------------
# config.env is *parsed*, never sourced. Sourcing ran it as shell, which broke
# two things: a password containing `$` or a backtick was silently mangled (or
# a command substitution in it was executed), and a stray assignment in the
# file quietly overwrote this script's own variables -- setting LOG_DIR there,
# for instance, defeated RECONNECT_LOG_DIR. Values are now taken literally and
# only the settings below are accepted.
WIFI_SSID=""
WIFI_PASSWORD=""
WIFI_IFACE=""
WIFI_HIDDEN=""

# Strip one layer of matching surrounding quotes and take what is inside
# literally -- no expansion, no escape processing. An unquoted value keeps any
# spaces inside it but loses the ones on either side; quote the value to keep
# those too.
#
# The blanks on *both* sides go before the quotes are looked at, so the
# spaced-out `KEY = "value"` spelling parses the same as `KEY="value"`. The key
# side had always tolerated the spaces, but the value side took them literally,
# so that line quietly yielded the value ` "value"` -- leading space and quotes
# and all -- and left the script hunting for an SSID that did not exist. A wrong
# value accepted in silence is exactly what rejecting unknown keys exists to
# prevent.
#
# Trailing blanks were stripped only on the unquoted branch, which left the same
# bug at the other end of the line and made it invisible: `KEY="value" ` with one
# space after the closing quote did not match the quoted case, fell through, and
# yielded `"value"` with the quotes still attached. Both sides are trimmed first
# now, so the quote check sees the same string either way.
#
# This trim is also what makes a CRLF config file work, and it is the only thing
# that does, so do not narrow it to spaces and tabs. `[:space:]` includes the
# carriage return (POSIX requires it to), so the CR of a CRLF line ending is
# removed here along with any other trailing blank; a CR cannot reach a key,
# because the key is everything left of the first `=`. load_config() used to carry
# a `line="${line%$'\r'}"` labelled "tolerate CRLF files", which read as though
# CRLF support lived there. It did not -- deleting that line changed the outcome
# of none of twelve CRLF fixtures, and left the whole suite green -- so it was a
# line that could only mislead the next person to narrow this one.
config_value() {
    local v="$1"
    v="${v#"${v%%[![:space:]]*}"}"
    v="${v%"${v##*[![:space:]]}"}"
    case "$v" in
        '"'*'"') v="${v:1:${#v}-2}" ;;
        "'"*"'") v="${v:1:${#v}-2}" ;;
    esac
    printf '%s' "$v"
}

# Read KEY=VALUE lines out of $1. Blank lines and whole-line `#` comments are
# skipped; a trailing comment is not, because `#` is a legal password
# character. An unknown key is an error rather than a silent no-op, so a typo
# surfaces immediately instead of leaving a setting mysteriously unapplied.
load_config() {
    local line lineno=0 key value seen=""
    while IFS= read -r line || [ -n "$line" ]; do
        lineno=$((lineno + 1))
        # A CRLF file needs nothing here: config_value() trims `[:space:]` from
        # both ends of the value, and a carriage return is in that class. See its
        # comment above, which is where that reasoning now lives.
        #
        # A UTF-8 byte-order mark sits in front of the first key and is
        # invisible in a terminal, so without this an editor that writes one
        # turned `WIFI_SSID=...` into "unknown setting 'WIFI_SSID'" -- a message
        # whose subject looks exactly right and whose real difference is three
        # bytes nobody can see. That is the same manufactured typo the `export`
        # handling below was fixed for, and the carriage return config_value()
        # trims off a CRLF line is a third of the same kind: a difference the
        # terminal does not draw. (This sentence used to point at "the CRLF strip
        # above", which was a line in this loop until it turned out to have no
        # effect on any input and was removed -- see config_value().) Only the
        # first line can carry a BOM, and stripping
        # it anywhere else would turn a fix for an invisible difference into a
        # filter that hides a visible one.
        [ "$lineno" -ne 1 ] || line="${line#$'\xef\xbb\xbf'}"
        line="${line#"${line%%[![:space:]]*}"}"         # drop leading blanks
        case "$line" in '' | '#'*) continue ;; esac
        # `export` followed by *any* run of blanks, not exactly one space. The
        # single-space form left the extra blanks glued to the front of the key,
        # and the resulting error named a setting that looks perfectly correct:
        # `export  WIFI_SSID=...` died with "unknown setting ' WIFI_SSID'", the
        # difference being one invisible leading space, and a tab was worse. That
        # defeats the whole point of rejecting unknown keys, which is that a typo
        # shows up straight away -- here it manufactured a typo that was not
        # there. `exported=x` is still an ordinary (unknown) key, because the
        # blank after `export` is what makes it a prefix.
        case "$line" in
            export[[:space:]]*)
                line="${line#export}"
                line="${line#"${line%%[![:space:]]*}"}"
                ;;
        esac
        case "$line" in
            *=*) ;;
            # The offending line is deliberately not echoed back. A password
            # line mistyped without the `=` (`WIFI_PASSWORD "s3cret"`) is
            # exactly the line that lands here, and printing it would put the
            # password on stderr -- the one thing remember_error() below goes
            # out of its way to prevent.
            *) die "$CONFIG_FILE line $lineno: expected KEY=VALUE (no '=' on that line)" ;;
        esac
        key="${line%%=*}"
        # Both ends, so the key is trimmed no matter how a blank got in front of
        # it. The trailing side was always stripped; the leading side was not,
        # which is what turned the `export` bug above into a baffling message
        # rather than a merely wrong one. Keeping both makes that invariant hold
        # here, independently of what the prefix handling does.
        key="${key#"${key%%[![:space:]]*}"}"
        key="${key%"${key##*[![:space:]]}"}"
        # A "key" that is not a plain setting name is never echoed back. The
        # missing-'=' error below refuses to print its line because that line
        # is most likely a mistyped password line -- but a password that itself
        # contains '=' (a base64-style one ending in `==`, say) does not land
        # there. `WIFI_PASSWORD "s3cr3tB64/Q=="` has an '=', so everything left
        # of it became the key, and the unknown-setting error printed
        # `unknown setting 'WIFI_PASSWORD "s3cr3tB64/Q'` -- nearly the whole
        # password, on stderr, in the output the bug-report template asks
        # people to paste. A real setting name is letters, digits and `_`, so
        # anything else is reported by line number alone. The empty key is left
        # to the unknown-setting arm, which prints '' and so shows nothing.
        #
        # Ahead of the duplicate check, whose message names the key too.
        case "$key" in
            '') ;;
            [!A-Za-z_]* | *[!A-Za-z0-9_]*)
                die "$CONFIG_FILE line $lineno: unknown setting (the text before the '=' is not a setting name, so it is not shown -- it may be part of a mistyped password line). Valid settings: WIFI_SSID, WIFI_PASSWORD, WIFI_IFACE, WIFI_HIDDEN." ;;
        esac
        value="$(config_value "${line#*=}")"
        # A key set twice was silently accepted and the last line won. That is
        # the same silent-wrong-value outcome rejecting unknown keys exists to
        # prevent, and it is worse here: the file reads as though the first
        # value applies, so a config that plainly says WIFI_SSID="Home" was
        # connecting to whatever a forgotten line further down said instead.
        #
        # Membership is tested with the key wrapped in blanks so a name cannot
        # match inside another one. Only the key and the line number are
        # reported -- never the value -- for the same reason the missing-'='
        # error does not echo its line: the duplicate most worth catching is a
        # second WIFI_PASSWORD.
        #
        # An empty key is not tested at all. `seen` starts empty, so `" $seen "`
        # is two blanks -- and with an empty $key the pattern `*" $key "*` is the
        # same two blanks, so the value matched the accumulator's own initial
        # state and the *first* `=value` line in a file was reported as "'' is
        # set more than once": a claim that contradicts itself, and one that
        # displaced the accurate "unknown setting ''" the arm below produces. The
        # line is malformed either way, so the whole difference is between an
        # error that names the problem and one that sends the reader hunting for
        # a duplicate that is not there.
        if [ -n "$key" ]; then
            case " $seen " in
                *" $key "*) die "$CONFIG_FILE line $lineno: '$key' is set more than once. Remove the duplicate; the file is read top to bottom, so the later line silently wins." ;;
            esac
            seen="$seen $key"
        fi
        case "$key" in
            WIFI_SSID) WIFI_SSID="$value" ;;
            WIFI_PASSWORD) WIFI_PASSWORD="$value" ;;
            WIFI_IFACE) WIFI_IFACE="$value" ;;
            WIFI_HIDDEN) WIFI_HIDDEN="$value" ;;
            *) die "$CONFIG_FILE line $lineno: unknown setting '$key'. Valid settings: WIFI_SSID, WIFI_PASSWORD, WIFI_IFACE, WIFI_HIDDEN." ;;
        esac
    done < "$1"
}

# Checking -f alone was not enough. A config that exists but cannot be read
# passed it and then failed at load_config's redirect, which `set -e` turns into
# an exit with no log line and, under cron, no output either -- the one silent
# failure everything else here is arranged to avoid. Readability is settled
# before the read, so the failure goes through die() and still records FAIL.
# This is reachable in ordinary use: setup tells you to chmod 600 the file, so
# a job installed under a different user than the file's owner lands right here.
[ -e "$CONFIG_FILE" ] \
    || die "Config file not found: $CONFIG_FILE (copy manual-setup/config.env.example to config.env and fill it in, or run ./auto-setup.sh)"
[ -f "$CONFIG_FILE" ] \
    || die "Config file is not a regular file: $CONFIG_FILE"
[ -r "$CONFIG_FILE" ] \
    || die "Config file is not readable by user $(id -un 2>/dev/null || echo '?'): $CONFIG_FILE (check its owner and mode)"
load_config "$CONFIG_FILE"

# Validate through die() rather than bash's "${VAR:?}", so a misconfigured
# install still records FAIL instead of exiting silently. Under cron the job
# redirects to /dev/null, so an unlogged exit would leave no trace at all.
[ -n "$WIFI_SSID" ] || die "WIFI_SSID must be set in $CONFIG_FILE"

# A value that is only blanks passed the check above and then failed much later,
# at the connect, as `could not connect to    :` -- a runtime error standing in
# for a config error, and one whose message shows nothing a reader can see. It
# is a half-finished edit or a stray quoted space in every realistic case.
#
# An SSID genuinely may be all spaces, so this does refuse one legal name. That
# is the right side of the trade: the network is essentially unheard of, and the
# alternative is a failure that names neither the setting nor the problem.
case "$WIFI_SSID" in
    *[![:space:]]*) ;;
    *) die "WIFI_SSID is set to blanks only in $CONFIG_FILE; it needs at least one non-blank character." ;;
esac

# WIFI_PASSWORD is deliberately *not* required here. Once NetworkManager has a
# saved profile for the network, `nmcli connection up` needs no password, so
# insisting on one would force every user to keep their password in plaintext
# -- including the ones SECURITY.md tells to connect once through the desktop
# UI precisely so they do not have to. The check moved into connect(), which
# only fails when there is neither a saved profile nor a password.

# The same guard WIFI_SSID gets above, and for the same reason. Empty stays
# legal -- that is the ordinary "let NetworkManager pick the device" case -- but
# a value of nothing but blanks is *not* empty, so it sailed through every check
# here and reached nmcli as `ifname "   "` on the scan, the rescan and the
# connect. The run then failed with nmcli's own device error, a runtime failure
# standing in for a config error and naming neither the setting nor anything a
# reader can see. Unlike the SSID case this refuses nothing legal: an interface
# name cannot be made of blanks.
case "$WIFI_IFACE" in
    '' | *[![:space:]]*) ;;
    *) die "WIFI_IFACE is set to blanks only in $CONFIG_FILE; give a device name (see 'nmcli device status'), or leave it empty to let NetworkManager pick." ;;
esac

# The value is quoted in the message. Unquoted, a WIFI_HIDDEN of nothing but
# blanks produced `must be yes or no; got:   ` -- a message whose subject is
# invisible, which is the failure shape the blanks-only WIFI_SSID check above
# exists to eliminate. Quoting is enough where the SSID needed a check of its
# own: this message already names the setting and both legal spellings, so the
# only thing missing was showing what actually arrived.
case "${WIFI_HIDDEN,,}" in
    '' | no | false | 0) WIFI_HIDDEN=no ;;
    yes | true | 1) WIFI_HIDDEN=yes ;;
    *) die "WIFI_HIDDEN must be yes or no; got: '$WIFI_HIDDEN'" ;;
esac

# How long to wait (in seconds) for the post-rescan scan to surface the target
# SSID, and how many times to attempt the connect. `nmcli dev wifi rescan` only
# *triggers* a scan and returns immediately, so connecting before the scan has
# populated fails with "No network with SSID '...' found". Waiting for the SSID
# to appear and retrying the connect is what lets an unattended (cron) run
# reconnect on its own instead of logging FAIL.
#
# NMCLI_WAIT_SECS bounds each individual nmcli call. All are overridable via
# env; see the README for how the defaults relate to the cron interval.
SCAN_WAIT_SECS="${RECONNECT_SCAN_WAIT_SECS:-15}"
CONNECT_ATTEMPTS="${RECONNECT_CONNECT_ATTEMPTS:-3}"
NMCLI_WAIT_SECS="${RECONNECT_NMCLI_WAIT_SECS:-20}"

# fits_in_integer() runs before every `-ge`, never after: the comparison is what
# fails on an over-wide value, so checking afterwards would mean the bash
# diagnostic had already been printed. See its own comment for what that cost.
#
# Each rejected value is quoted, for the reason the WIFI_HIDDEN check below
# quotes its own and writes out in full. These four are reached the same way that
# one is -- from the environment, so `RECONNECT_SCAN_WAIT_SECS="$n"` with $n blank
# is how it arrives -- and unquoted they produced `... at most 18 digits; got: `
# with nothing after it: a refusal naming nothing, and under cron the message
# goes to /dev/null, so a hand-run is the only place anyone ever sees it. The
# rule was applied to WIFI_HIDDEN and to the four scripts' argument refusals and
# not here, which is the whole of the difference.
{ is_uint "$SCAN_WAIT_SECS" && fits_in_integer "$SCAN_WAIT_SECS"; } \
    || die "RECONNECT_SCAN_WAIT_SECS must be a non-negative whole number of seconds, at most 18 digits; got: '$SCAN_WAIT_SECS'"
{ is_uint "$CONNECT_ATTEMPTS" && fits_in_integer "$CONNECT_ATTEMPTS" \
    && [ "$CONNECT_ATTEMPTS" -ge 1 ]; } \
    || die "RECONNECT_CONNECT_ATTEMPTS must be a whole number >= 1, at most 18 digits; got: '$CONNECT_ATTEMPTS'"
{ is_uint "$NMCLI_WAIT_SECS" && fits_in_integer "$NMCLI_WAIT_SECS" \
    && [ "$NMCLI_WAIT_SECS" -ge 1 ]; } \
    || die "RECONNECT_NMCLI_WAIT_SECS must be a whole number >= 1, at most 18 digits; got: '$NMCLI_WAIT_SECS'"
{ is_uint "$LOG_RETENTION_DAYS" && fits_in_integer "$LOG_RETENTION_DAYS"; } \
    || die "RECONNECT_LOG_RETENTION_DAYS must be a non-negative whole number of days, at most 18 digits (0 disables pruning); got: '$LOG_RETENTION_DAYS'"

# --- Sanity checks -----------------------------------------------------------
command -v nmcli >/dev/null 2>&1 || die "nmcli not found. Install NetworkManager (e.g. 'sudo apt install network-manager')."

# Every reading of nmcli's output below goes through awk. It is present on any
# ordinary Linux install, but a stripped-down container image is a real place to
# run this, and there the failure would otherwise be a bare "awk: not found"
# from inside a command substitution rather than a stated reason.
command -v awk >/dev/null 2>&1 || die "awk not found. Install one (e.g. 'sudo apt install gawk')."

# `sleep` is checked further down, inside the reconnect path, because that is
# the only path that uses it. See the comment there.
#
# `mkdir`, `touch`, `rm` and `id` are invoked without a preflight and
# deliberately stay that way, because each is guarded where it is called:
# `if ! mkdir`, a `&&` chain, `|| true`, and a `|| echo '?'` fallback. A missing
# one degrades the run instead of ending it, so a check would buy nothing. An
# earlier version of the `sleep` comment called it "the one external command in
# this script that was not checked", which reads as a claim about the whole
# preflight set and was wrong about all four of these.

# `date` is checked much earlier, before the interpreter check, for the reason
# recorded there.

# --- Running nmcli -----------------------------------------------------------
# Every nmcli call goes through here so that none of them inherits the lock.
#
# `exec 9>>` above opens descriptor 9 in this shell and holds the flock on it,
# and an open descriptor is inherited by every child unless it is closed for
# that child. A process that outlived this script would therefore go on holding
# the lock, and every later run would step aside with "Skipped (already
# running)" -- for as long as that process lived, with nothing in the log saying
# why. nmcli is the only child with any reason to reach a daemon, so it is the
# one worth closing for; awk and sleep are bounded by the pipeline and the run
# itself.
#
# `9>&-` is safe whichever way the lock went: where flock is missing descriptor
# 9 was never opened, and closing a descriptor that is not open is not an error.
#
# A wrapper rather than the redirection repeated at each call site: there are
# eleven of them, and one missed later is a leak nothing would notice.
run_nmcli() {
    nmcli "$@" 9>&-
}

# --- Reading nmcli terse output ----------------------------------------------
# In terse (-t) mode nmcli separates fields with ":" and escapes both special
# characters inside a field: ":" becomes "\:" and "\" becomes "\\". Undoing
# that needs a single left-to-right pass -- unescaping the two independently
# would corrupt a value containing a literal backslash, or one containing the
# two-character sequence "\:". Splitting has the same requirement, so tfield()
# walks the line once and returns field `want` already unescaped.
AWK_TERSE='
function tfield(s, want,   i, c, n, cur) {
    n = 1
    cur = ""
    for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (c == "\\" && i < length(s)) {
            i++
            cur = cur substr(s, i, 1)
        } else if (c == ":") {
            if (n == want) return cur
            n++
            cur = ""
        } else {
            cur = cur c
        }
    }
    return (n == want) ? cur : ""
}
'

# --- Determine the currently active Wi-Fi SSID -------------------------------
# Read the SSID from the *active connection profile*, not from the scan list.
# A hidden network is connected but never appears in a scan, so reading the
# scan list made it look permanently disconnected: the script took the
# reconnect path on every single run and logged "Wifi Reconnected" forever.
active_wifi_profile() {
    run_nmcli -t -f NAME,TYPE,DEVICE connection show --active 2>/dev/null \
        | WANT_IFACE="$WIFI_IFACE" awk "$AWK_TERSE"'
            BEGIN { iface = ENVIRON["WANT_IFACE"] }
            {
                type = tfield($0, 2)
                if (type != "802-11-wireless" && type != "wifi") next
                if (iface != "" && tfield($0, 3) != iface) next
                print tfield($0, 1)
                exit
            }'
}

# The SSID a saved profile is configured for. Empty for a non-Wi-Fi profile,
# or on an nmcli too old to filter by property.
#
# The name is passed bare, with no `--` in front of it, and that is deliberate:
# nmcli does not treat `--` as an end-of-options marker here. Its argument
# walker (`next_arg()` in src/nmcli/utils.c) only consumes what
# `nmc_arg_is_option()` recognises, and that returns false for a bare `--`, so
# `connection show -- NAME` looked up a profile literally called `--`, failed
# with "no such connection profile", and this function returned empty for
# *every* profile -- which meant saved_profile_for_ssid() never found one and
# every reconnect fell through to the password form and failed there too (see
# connect_with_password(), which had the same `--` and the worse half of the
# consequence). Checked against NetworkManager 1.10.6 through main; the only
# `--` nmcli understands anywhere is `connection add`'s option/property
# separator. The test suite's nmcli stub used to strip a `-- ` here, which is
# why a green suite never noticed.
#
# The cost of the bare name is the one DECISIONS.md D6 records: this position
# genuinely takes options (`--active`, `--order`), so a profile whose name is a
# prefix of one of those (`-a`, `--act`) is read as the option. That is a
# documented limitation, not something a `--` can buy back.
profile_ssid() {
    run_nmcli -t -f 802-11-wireless.ssid connection show "$1" 2>/dev/null \
        | awk "$AWK_TERSE"'NR == 1 { print tfield($0, 2) }'
}

# Fallback for an nmcli that cannot report the active profile's SSID. Only
# sees networks present in the scan list, which is why it is the fallback.
#
# Scoped to WIFI_IFACE when one is set, the same way active_wifi_profile() is.
# `dev wifi` lists access points across every Wi-Fi device, so on a machine with
# two adapters this fallback could report an SSID that is active on the *other*
# one -- and if that happened to be the target, the run logged "Wifi Good"
# without the pinned interface being connected at all.
scan_list() {
    if [ -n "$WIFI_IFACE" ]; then
        run_nmcli -t -f "$1" dev wifi list ifname "$WIFI_IFACE" 2>/dev/null
    else
        run_nmcli -t -f "$1" dev wifi 2>/dev/null
    fi
}

scanned_ssid() {
    scan_list ACTIVE,SSID \
        | awk "$AWK_TERSE"'tfield($0, 1) == "yes" { print tfield($0, 2); exit }'
}

current_ssid() {
    local profile ssid
    profile="$(active_wifi_profile || true)"
    if [ -n "$profile" ]; then
        ssid="$(profile_ssid "$profile" || true)"
        if [ -n "$ssid" ]; then
            printf '%s\n' "$ssid"
            return 0
        fi
    fi
    scanned_ssid
}

CURRENT="$(current_ssid || true)"

if [ "$CURRENT" = "$WIFI_SSID" ]; then
    # Already on the target network -- nothing to do.
    status "Wifi Good"
    exit 0
fi

# --- Reconnect ---------------------------------------------------------------
# `sleep` paces the scan wait and the gap between connect attempts, and its
# absence *aborts* the run: the scan-wait loop dies under `set -e` from a bare
# "command not found" -- after the lock has been taken and before any status line
# has been written. That is the silent exit every other check here exists to
# prevent, and it would break the one thing reading a day's log relies on: that
# each run appends exactly one line.
#
# It sits here rather than with the nmcli and awk checks above because only this
# path uses it. Up there it fired on every run, including the already-connected
# one that exits a few lines above without ever calling sleep -- so a machine
# that was correctly on the target network logged FAIL and exited 1 instead of
# logging "Wifi Good" and exiting 0. That is the steady-state path and the one a
# monitoring check keys off, and it was being refused over a command it does not
# run. The same rule install-cron.sh applies to its install-only preflights and
# uninstall-cron.sh to its crontab-only ones.
#
# Both uses are conditional even here, so the check is too: a hidden network
# skips the scan wait outright, RECONNECT_SCAN_WAIT_SECS=0 makes it a
# zero-iteration loop, and RECONNECT_CONNECT_ATTEMPTS=1 leaves no gap to pace.
# A run configured that way reaches neither call.
if { [ "$WIFI_HIDDEN" = no ] && [ "$SCAN_WAIT_SECS" -gt 0 ]; } \
    || [ "$CONNECT_ATTEMPTS" -gt 1 ]; then
    command -v sleep >/dev/null 2>&1 || die "sleep not found. Install coreutils."
fi

# Make sure Wi-Fi radio is on (it may have been toggled off).
run_nmcli radio wifi on >/dev/null 2>&1 || true

# Rescan so a network that recently came into range is visible. Ignore errors
# (a scan can be rate-limited if one just happened).
if [ -n "$WIFI_IFACE" ]; then
    run_nmcli dev wifi rescan ifname "$WIFI_IFACE" >/dev/null 2>&1 || true
else
    run_nmcli dev wifi rescan >/dev/null 2>&1 || true
fi

# The rescan above is asynchronous: it returns before results are ready. Poll
# the scan list until the target SSID shows up (or we give up after
# SCAN_WAIT_SECS). If it never appears we fall through and try to connect
# anyway -- a saved profile can still succeed from a stale cache.
#
# The SSID is handed to awk through the environment rather than with -v,
# because -v processes backslash escapes in the value it assigns.
target_visible() {
    scan_list SSID \
        | TARGET_SSID="$WIFI_SSID" awk "$AWK_TERSE"'
            BEGIN { want = ENVIRON["TARGET_SSID"] }
            tfield($0, 1) == want { found = 1; exit }
            END { exit found ? 0 : 1 }'
}

# A hidden network is never in the scan list, so waiting for it would just burn
# SCAN_WAIT_SECS on every run.
if [ "$WIFI_HIDDEN" = no ]; then
    waited=0
    while [ "$waited" -lt "$SCAN_WAIT_SECS" ]; do
        if target_visible; then
            break
        fi
        sleep 1
        waited=$((waited + 1))
    done
fi

# --- Connecting --------------------------------------------------------------
# Prefer bringing up a saved NetworkManager profile: `nmcli connection up`
# takes no password, so the Wi-Fi password never appears in the process list
# (/proc/<pid>/cmdline is world-readable, so anything on an argv is visible to
# every local user via `ps`). The first successful connect saves the profile,
# so every steady-state run after that takes this path.
#
# Profiles are matched on the SSID they are configured for, not on their name.
# NetworkManager appends a suffix when profile names collide ("MyNet 1"), and a
# profile can be renamed by hand; matching on the name missed both cases and
# fell through to the password form on every run -- the exact thing this path
# exists to avoid.
wifi_profile_names() {
    run_nmcli -t -f NAME,TYPE connection show 2>/dev/null \
        | awk "$AWK_TERSE"'
            {
                type = tfield($0, 2)
                if (type == "802-11-wireless" || type == "wifi") print tfield($0, 1)
            }'
}

saved_profile_for_ssid() {
    local name ssid
    # Fast path: NetworkManager names a profile after the SSID unless something
    # forced it not to, so check that one name first. It is right almost every
    # time and costs a single nmcli call, where the scan below costs one per
    # saved Wi-Fi profile.
    if [ "$(profile_ssid "$WIFI_SSID" || true)" = "$WIFI_SSID" ]; then
        printf '%s\n' "$WIFI_SSID"
        return 0
    fi
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        [ "$name" != "$WIFI_SSID" ] || continue      # already ruled out above
        ssid="$(profile_ssid "$name" || true)"
        [ "$ssid" = "$WIFI_SSID" ] || continue
        printf '%s\n' "$name"
        return 0
    done < <(wifi_profile_names)
    return 1
}

# No `--` here either. The profile name follows the `id` selector, which marks
# the next argument as its value, so a name beginning with `-` is taken
# literally on this path -- and `connection up id -- MyNet` would make `--` the
# value of `id` and leave `MyNet` behind as a stray argument nmcli rejects. The
# two bare positionals, profile_ssid() above and connect_with_password() below,
# carried a `--` for a while on the belief that it would do for them what `id`
# does here; it did not, for the reason profile_ssid()'s comment gives.
connect_saved() {
    if [ -n "$WIFI_IFACE" ]; then
        run_nmcli -w "$NMCLI_WAIT_SECS" connection up id "$1" ifname "$WIFI_IFACE"
    else
        run_nmcli -w "$NMCLI_WAIT_SECS" connection up id "$1"
    fi
}

# Fallback for the very first connect, before any profile exists. This is the
# one path that still puts the password on a command line; it runs once per
# machine in normal use.
connect_with_password() {
    local -a cmd
    # The SSID is passed bare. It used to be preceded by `--`, meant to stop an
    # SSID beginning with `-` being read as an option -- but nmcli's `dev wifi
    # connect` takes its first argument as the SSID unconditionally
    # (do_device_wifi_connect() in src/nmcli/devices.c: "Get the first
    # compulsory argument (SSID or BSSID)"), so `--` *was* the SSID and the real
    # one was refused as "invalid extra argument". Every password connect
    # therefore failed, on every NetworkManager release from 1.10 to main. The
    # keyword arguments appended below -- password, hidden, ifname -- each mark
    # their own value. What an SSID beginning with `-` costs on this path is
    # only that `--ask` or `--show-secrets` (or a dashed prefix of either) would
    # be read as nmcli's own flag;
    # DECISIONS.md D6 records it.
    cmd=(run_nmcli -w "$NMCLI_WAIT_SECS" dev wifi connect "$WIFI_SSID" password "$WIFI_PASSWORD")
    if [ "$WIFI_HIDDEN" = yes ]; then
        cmd+=(hidden yes)
    fi
    if [ -n "$WIFI_IFACE" ]; then
        cmd+=(ifname "$WIFI_IFACE")
    fi
    "${cmd[@]}"
}

# nmcli's own diagnostic from the last failed attempt. Without this a failed
# connect printed nothing at all on a hand-run -- the most common failure was
# also the least diagnosable, and the README's "run it by hand to see the
# reason" was untrue. The password is scrubbed out before the message is kept,
# so a future nmcli echoing its arguments back cannot leak it to a log or a
# terminal.
LAST_ERROR=""
remember_error() {
    local msg="$1"
    if [ -n "$WIFI_PASSWORD" ]; then
        msg="${msg//"$WIFI_PASSWORD"/***}"
    fi
    LAST_ERROR="$msg"
}

# Try the saved profile first and only fall back to the password form if it is
# missing or fails, so the password stays off the command line whenever the
# saved profile can do the job.
connect() {
    local out
    if [ -n "$SAVED_PROFILE" ]; then
        if out="$(connect_saved "$SAVED_PROFILE" 2>&1)"; then
            return 0
        fi
        remember_error "$out"
    fi
    if [ -z "$WIFI_PASSWORD" ]; then
        if [ -z "$SAVED_PROFILE" ]; then
            remember_error "no saved NetworkManager profile is configured for SSID '$WIFI_SSID', and WIFI_PASSWORD is not set in $CONFIG_FILE. Set WIFI_PASSWORD, or connect to the network once through the desktop UI to create the profile."
        fi
        return 1
    fi
    if out="$(connect_with_password 2>&1)"; then
        return 0
    fi
    remember_error "$out"
    return 1
}

# Resolved once, not once per attempt. saved_profile_for_ssid()'s slow path
# costs an nmcli call for every saved Wi-Fi profile on the machine, and connect()
# used to re-run the whole lookup on each retry -- so a failing run on a laptop
# with a long list of saved networks paid for that scan CONNECT_ATTEMPTS times
# over. The set of saved profiles cannot change between attempts in any way that
# matters here: the only thing that would create one is a connect that succeeded,
# and a successful connect leaves the loop.
SAVED_PROFILE="$(saved_profile_for_ssid || true)"

# Try to connect a few times: even once the SSID is visible, a single attempt
# can fail transiently (association timeout, authentication handshake races).
# Only after every attempt fails do we record FAIL.
attempt=1
while [ "$attempt" -le "$CONNECT_ATTEMPTS" ]; do
    if connect; then
        status "Wifi Reconnected"
        exit 0
    fi
    if [ "$attempt" -lt "$CONNECT_ATTEMPTS" ]; then
        sleep 2
    fi
    attempt=$((attempt + 1))
done

status "FAIL"
if [ -n "$LAST_ERROR" ]; then
    printf 'ERROR: could not connect to %s: %s\n' "$WIFI_SSID" "$LAST_ERROR" >&2
else
    printf 'ERROR: could not connect to %s (nmcli reported no reason).\n' "$WIFI_SSID" >&2
fi
exit 1
