<!--
Thanks for the pull request. CONTRIBUTING.md has the house style; the short
version is that comments explain why rather than what, every exit path in
reconnect.sh writes exactly one log line, and config.env is parsed, never
sourced.
-->

## What this changes, and why

<!-- The reasoning matters more than the diff here. If this fixes a bug, say
     what the bug was -- that explanation usually belongs in a comment next to
     the fix as well. -->

## How it was tested

- [ ] `./tests/run-tests.sh` passes
- [ ] `shellcheck --shell=bash --severity=style reconnect.sh manual-setup/install-cron.sh manual-setup/uninstall-cron.sh auto-setup.sh tests/run-tests.sh` is clean

If this touches connect behaviour, the test suite stubs `nmcli` and cannot
cover it. Say what you ran against a real NetworkManager and what the log lines
were:

<!--
  e.g. disconnected Wi-Fi, waited for the cron run, got:
    [14:10:01] Wifi Reconnected
-->

## Checklist

- [ ] New behaviour is documented in the README
- [ ] No Wi-Fi password can reach a log file or an error message, nor a command
      line other than the documented password-form connect in `reconnect.sh`
      (see SECURITY.md)
- [ ] New tests cover the change, where it is testable without NetworkManager
- [ ] If this invalidates the reasoning behind a [DECISIONS.md](../tests/DECISIONS.md)
      entry, that entry is updated in the same pull request
