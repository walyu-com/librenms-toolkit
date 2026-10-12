# librenms-toolkit

Companion tools for a [LibreNMS](https://www.librenms.org/) server managing Cisco switches:

| Component | Type | Purpose |
|---|---|---|
| [NetCmd](netcmd/) | Standalone web app (Python, port 8090) | Send the same CLI commands to many Cisco devices (SSH / Telnet), with per-device history and outputs |
| [CiscoEox](plugins/CiscoEox/) | LibreNMS local plugin | Cisco PSIRT advisories (openVuln API) and hardware / software End-of-Life dates on each device page |
| [Comment](plugins/Comment/) | LibreNMS local plugin | Device notes with Markdown, simple HTML, line breaks, inline editor and a common first line |
| [Netcmd](plugins/Netcmd/) | LibreNMS local plugin | Menu entry and device page links to NetCmd |

Developed for Ubuntu 26.04 with the current LibreNMS (Laravel 12, PHP 8.5).

![NetCmd](docs/netcmd.png)

## Installation

Each component ships a self-contained installer (run as root on the LibreNMS server). An existing
installation is backed up to `/root` before being replaced.

```bash
sudo bash netcmd/install-netcmd.sh
sudo bash plugins/CiscoEox/install-ciscoeox.sh
sudo bash plugins/Comment/install-comment.sh
sudo bash plugins/Netcmd/install-netcmd-plugin.sh
```

The source files next to each installer are the same files the installer writes; they are provided
for review.

Local plugins live in `/opt/librenms/app/Plugins/<Name>/`. This folder is ignored by git in
LibreNMS, so the plugins never block the LibreNMS daily update (`daily.sh`). To remove a plugin:

```bash
sudo mv /opt/librenms/app/Plugins/<Name> /root/<Name>.removed
```

## NetCmd

- Device list from the LibreNMS API (`/api/v0/devices`), filtered by OS (default `ios,iosxe`), with
  LibreNMS device groups as filter, sort by name or IP, preselection with `/?ip=<address>`.
- Commands sent as typed with Netmiko, in parallel; `enable` handling (login password or a specific
  enable password).
- Any device prompt (exec, config, config-xxx) ends a command; `[confirm]`, `[yes/no]` and
  `... [default]?` questions too. An empty line in the command list sends Enter (default answer).
  NetCmd never answers a question on its own.
- Status per device: `ok`, `potential error` (lines starting with `%`), `cmd_error` (known IOS
  errors, timeout), `conn_error`.
- History in SQLite (runs, per-device outputs), text export. Passwords are never stored.
- Settings page: links from device names to LibreNMS, `telnet://` and `ssh://` links, group badges,
  custom logo (browser tab and title bar).
- Configuration: `/etc/netcmd/netcmd.env` (LibreNMS URL and API token, OS filter, timeouts, port).

NetCmd has no authentication of its own: restrict access to port 8090 (firewall) to the admin
networks.

## CiscoEox

- Advisories from the Cisco PSIRT openVuln API for the OS and version known by LibreNMS (free
  Cisco account and an application registered at <https://apiconsole.cisco.com>, grant type
  Client Credentials). The API matches on the version only, not on the configuration: an advisory
  may not apply to a device where the affected feature is disabled.
- "Disable scope" per advisory: Local (this device) or Global (all devices); disabled advisories are
  greyed out and moved to the end of the list.
- Hardware and software lifecycle tables (End-of-Sale, End of Security Support, Last Date of
  Support, bulletin URL) with "Rescan hardware" / "Rescan IOS" buttons that add the PIDs and
  release trains present in LibreNMS. Dates come from the public Cisco EoL bulletins; the Cisco
  EoX API requires a Smart Net Total Care or PSS contract and is not used.
- Device pages read a cache only; the cache is refreshed every 6 hours by
  `/etc/cron.d/librenms-ciscoeox` (`bin/refresh.php`) or by the "Refresh advisories now" button.

## Comment

- Renders the standard LibreNMS device notes with Markdown, simple HTML (links, bold, lists,
  tables...) and line breaks; attributes, scripts and unsafe links are removed.
- Inline editor (saved through the LibreNMS notes route and permissions), configurable height.
- "Common first line" shown on every device, with placeholders `{ip}`, `{sysname}`, `{name}`, `{id}`.
- Menu entry listing every device with notes.

## License

GPL-3.0 (see [LICENSE](LICENSE)), as LibreNMS.
