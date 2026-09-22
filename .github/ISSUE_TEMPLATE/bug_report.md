---
name: Bug report
about: Something does not work the way the README says it should
title: ''
labels: bug
assignees: ''
---

**Please do not paste your Wi-Fi password, or the contents of `config.env`,
into a public issue.** Redact the SSID too if it identifies you.

## What happened

<!-- What you expected, and what you got instead. -->

## Log lines

<!--
The relevant lines from logs/YYYY-MM-DD.log, e.g.

  [14:05:00] Wifi Good
  [14:10:01] FAIL
-->

```
```

## Output of running it by hand

<!--
Cron sends stderr to /dev/null, so the reason for a failure only shows up on a
hand-run. Please include it:

  ./reconnect.sh

If it works by hand but fails from cron, say so explicitly -- that is usually
polkit, and the README's "Notes & troubleshooting" section covers it.
-->

```
```

## Environment

- Distribution and version:
- `bash --version` (first line):
- `nmcli --version`:
- Installed via `./manual-setup/install-cron.sh` (or `./auto-setup.sh`), or run by hand?
- Interval, if not the default 5 minutes:
- Any `RECONNECT_*` overrides set (`crontab -l` will show the ones on the job):

## Network

- Hidden network (`WIFI_HIDDEN="yes"`)? 
- Was `WIFI_PASSWORD` set, or are you relying on a saved NetworkManager profile?
- Does `nmcli connection up id "<your profile>"` work when you run it yourself?
