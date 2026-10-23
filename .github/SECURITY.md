# Security Policy

## Reporting a vulnerability

Please **do not** open a public issue for a security problem.

Report it through GitHub's private vulnerability reporting: go to the
[Security tab](https://github.com/ArisMGGR/gen-InternetReconnector/security/advisories/new)
and open a draft advisory. That keeps the report private until a fix is out.

This is a small hobby project maintained in spare time — expect a response
within a couple of weeks rather than a couple of hours.

## Supported versions

Only the current `main` branch is supported. Fixes land there and go out in the
next release; older tags are not backported to.

Until the first tagged release exists, `main` is the only thing there is —
please report against it.

## What this tool does with your password

Worth understanding before you file a report:

- If you set `WIFI_PASSWORD`, your Wi-Fi password is stored in `config.env`, in
  plaintext, on your own machine. Keep it at mode `600` (`chmod 600 config.env`).
  It is gitignored. Re-running `auto-setup.sh` over an existing config also
  keeps the previous one as `config.env.bak`, which holds the same password; it
  is set to mode `600` and gitignored too, and it is yours to delete.
- `WIFI_PASSWORD` is optional. If NetworkManager already has a saved profile for
  the SSID, `reconnect.sh` uses that profile and never needs the password, so you
  can leave the setting empty and keep the password out of `config.env`
  altogether.
- NetworkManager stores the password in its own connection profile once you
  connect successfully — exactly as it would if you had connected through the
  desktop UI. This tool does not change how NetworkManager stores secrets.
- `reconnect.sh` prefers `nmcli connection up`, which takes no password, so the
  password does not appear in the process list on ordinary runs. Profiles are
  matched on the SSID they are configured for rather than on their name, so a
  profile NetworkManager renamed (`MyNet 1`) is still found and still avoids the
  password path.
- If `WIFI_PASSWORD` is set, there are two cases where it is passed to `nmcli`
  as a command-line argument, which is briefly visible to other local users via
  `ps`:
  - **The first connect on a machine**, before a NetworkManager profile for the
    SSID exists. There is nothing to bring up, so the password form is the only
    way through. In normal use this happens once.
  - **Any attempt where bringing up the saved profile fails.** `reconnect.sh`
    tries `nmcli connection up` first, and falls back to the password form when
    that call returns non-zero — on every attempt, for as long as the failure
    lasts. This is not only a first-run condition. In particular, the polkit
    behaviour described under "Notes & troubleshooting" in the
    [README](../README.md) makes `connection up` fail on *every* scheduled run,
    so on an affected machine the password reaches an argv at every cron
    interval, indefinitely.

  If either matters in your threat model, connect once through the desktop UI
  and leave `WIFI_PASSWORD` empty — the script then has no password to fall back
  to and will only ever use the saved profile. It will log `FAIL` instead of
  falling back, which is the intended trade.
- `config.env` is parsed as plain `KEY=VALUE` text, not sourced as a shell
  script, so a value in it is never executed.

## Out of scope

- Anyone with read access to your user account can read `config.env`. That is
  inherent to storing a password you must be able to use unattended. Leaving
  `WIFI_PASSWORD` empty and relying on the saved NetworkManager profile moves
  the secret to NetworkManager's own store, but does not remove it from the
  machine.
- Failed-connect diagnostics printed to stderr have the configured password
  scrubbed out, but they are `nmcli`'s own text and are not otherwise filtered.
- This tool checks Wi-Fi *association*, not internet reachability, and makes no
  attempt to detect captive portals or hostile access points. See the
  Limitations section of the [README](../README.md).
